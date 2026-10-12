const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const metal = gpu.metal;
const field = cpu.field;
const curve = cpu.curve;
const msm = cpu.msm;

// The production Metal prover splits G2 at 1<<16 points and, on circuits the
// size of shuffle_1_deck_52 (nVars=188480, domain=262144), starts the H MSM
// on command_queue_2 while the G2 tail is still on that queue. The checked-in
// Metal tests use the 1003-variable testdata circuit, so neither path runs.

const table_len: usize = 16;
const g2_chunk: usize = 1 << 16;

// Header values from the casino shuffle zkeys. The GPU FFT buffer is sized
// exactly to the 8-deck domain, and that circuit's G2 tail is the largest
// MSM the prover ships.
const shuffle_1_deck_domain: u32 = 262144;
const shuffle_8_deck_domain: u32 = 4194304;
const shuffle_8_deck_nvars: usize = 2250988;

test "domains of 4096 or fewer use the CPU prover" {
    try std.testing.expect(metal.prefersCpu(1));
    try std.testing.expect(metal.prefersCpu(4096));
    try std.testing.expect(!metal.prefersCpu(8192));
    try std.testing.expect(!metal.prefersCpu(shuffle_1_deck_domain));
}

fn g2Table() [table_len]curve.G2PointAffine {
    var proj = curve.g2_generator();
    var table: [table_len]curve.G2PointAffine = undefined;
    for (&table) |*slot| {
        slot.* = curve.g2_normalize(proj);
        proj = curve.g2_dbl(proj);
    }
    return table;
}

fn g1Table() [table_len]curve.G1PointAffine {
    var proj = curve.g1_generator();
    var table: [table_len]curve.G1PointAffine = undefined;
    for (&table) |*slot| {
        slot.* = curve.g1_normalize(proj);
        proj = curve.g1_dbl(proj);
    }
    return table;
}

fn fillScalars(scalars: []field.FrElement) void {
    for (scalars, 0..) |*s, i| s.* = field.fr_from_u64(@intCast(i + 1));
}

fn closedFormG2(table: [table_len]curve.G2PointAffine, n: usize) curve.G2Point {
    var sums: [table_len]u64 = @splat(0);
    for (0..n) |i| sums[i % table_len] += @intCast(i + 1);
    var acc = curve.g2_zero();
    for (table, sums) |pt, sum| {
        if (sum == 0) continue;
        const term = curve.g2_mul(curve.g2_affine_to_projective(pt), field.fr_from_u64(sum));
        acc = curve.g2_add(acc, term);
    }
    return acc;
}

fn closedFormG1(table: [table_len]curve.G1PointAffine, n: usize) curve.G1Point {
    var sums: [table_len]u64 = @splat(0);
    for (0..n) |i| sums[i % table_len] += @intCast(i + 1);
    var acc = curve.g1_zero();
    for (table, sums) |pt, sum| {
        if (sum == 0) continue;
        const term = curve.g1_mul(curve.g1_affine_to_projective(pt), field.fr_from_u64(sum));
        acc = curve.g1_add(acc, term);
    }
    return acc;
}

fn assignG2(points: []curve.G2PointAffine, table: [table_len]curve.G2PointAffine) void {
    for (points, 0..) |*pt, i| pt.* = table[i % table_len];
}

fn assignG1(points: []curve.G1PointAffine, table: [table_len]curve.G1PointAffine) void {
    for (points, 0..) |*pt, i| pt.* = table[i % table_len];
}

const G2Soa = struct {
    x_c0: []u8,
    x_c1: []u8,
    y_c0: []u8,
    y_c1: []u8,
    neg_y_c0: []u8,
    neg_y_c1: []u8,

    fn deinit(self: G2Soa, allocator: std.mem.Allocator) void {
        allocator.free(self.x_c0);
        allocator.free(self.x_c1);
        allocator.free(self.y_c0);
        allocator.free(self.y_c1);
        allocator.free(self.neg_y_c0);
        allocator.free(self.neg_y_c1);
    }
};

fn transposeG2(allocator: std.mem.Allocator, points: []const curve.G2PointAffine) !G2Soa {
    const fq_size: usize = 32;
    const n = points.len;
    var soa = G2Soa{
        .x_c0 = try allocator.alloc(u8, n * fq_size),
        .x_c1 = try allocator.alloc(u8, n * fq_size),
        .y_c0 = try allocator.alloc(u8, n * fq_size),
        .y_c1 = try allocator.alloc(u8, n * fq_size),
        .neg_y_c0 = try allocator.alloc(u8, n * fq_size),
        .neg_y_c1 = try allocator.alloc(u8, n * fq_size),
    };
    errdefer soa.deinit(allocator);
    for (points, 0..) |pt, i| {
        const dst = i * fq_size;
        const neg_y = field.fq2_neg(pt.y);
        @memcpy(soa.x_c0[dst..][0..fq_size], std.mem.asBytes(&pt.x.a));
        @memcpy(soa.x_c1[dst..][0..fq_size], std.mem.asBytes(&pt.x.b));
        @memcpy(soa.y_c0[dst..][0..fq_size], std.mem.asBytes(&pt.y.a));
        @memcpy(soa.y_c1[dst..][0..fq_size], std.mem.asBytes(&pt.y.b));
        @memcpy(soa.neg_y_c0[dst..][0..fq_size], std.mem.asBytes(&neg_y.a));
        @memcpy(soa.neg_y_c1[dst..][0..fq_size], std.mem.asBytes(&neg_y.b));
    }
    return soa;
}

fn metalG2(
    prover: *metal.MetalProver,
    allocator: std.mem.Allocator,
    soa: G2Soa,
    byte_off: usize,
    byte_len: usize,
    scalars: []const u8,
    queue: anytype,
) !curve.G2Point {
    const sorted = try gpu.preprocessSortedWindows(allocator, scalars, 8);
    defer sorted.deinit(allocator);
    const n_points = byte_len / 32;
    const config = gpu.MSMConfig{
        .n_points = @intCast(n_points),
        .n_windows = 32,
        .window_size = 8,
        .n_buckets = 256,
    };
    const windows = try prover.msmG2_v6_soA(
        soa.x_c0[byte_off..][0..byte_len],
        soa.x_c1[byte_off..][0..byte_len],
        soa.y_c0[byte_off..][0..byte_len],
        soa.y_c1[byte_off..][0..byte_len],
        soa.neg_y_c0[byte_off..][0..byte_len],
        soa.neg_y_c1[byte_off..][0..byte_len],
        sorted,
        config,
        queue,
    );
    defer allocator.free(windows);
    return metal.accumulateG2(windows);
}

fn g1PointBytes(allocator: std.mem.Allocator, points: []const curve.G1PointAffine) ![]u8 {
    const bytes = try allocator.alloc(u8, points.len * 64);
    for (points, 0..) |pt, i| {
        const dst = bytes[i * 64 ..][0..64];
        @memcpy(dst[0..32], std.mem.asBytes(&pt.x));
        @memcpy(dst[32..64], std.mem.asBytes(&pt.y));
    }
    return bytes;
}

fn metalG1(
    prover: *metal.MetalProver,
    allocator: std.mem.Allocator,
    points: []const u8,
    scalars: []const u8,
    queue: anytype,
) !curve.G1Point {
    const sorted = try gpu.preprocessSortedWindows(allocator, scalars, 8);
    defer sorted.deinit(allocator);
    const jobs = &[_]metal.MetalProver.MSMJob{
        .{ .points = points, .sorted = sorted },
    };
    const windows = try prover.msmG1_v5_batch(jobs, queue);
    defer {
        for (windows) |w| allocator.free(w);
        allocator.free(windows);
    }
    return metal.accumulateG1(windows[0]);
}

test "gpu path: short G2 MSM matches the closed form on CPU and Metal" {
    if (@import("builtin").os.tag != .macos) return;
    const allocator = std.testing.allocator;
    const n: usize = 128;
    const table = g2Table();
    const expected = closedFormG2(table, n);

    const points = try allocator.alloc(curve.G2PointAffine, n);
    defer allocator.free(points);
    assignG2(points, table);
    const scalars = try allocator.alloc(field.FrElement, n);
    defer allocator.free(scalars);
    fillScalars(scalars);

    const cpu_pi = try msm.msm_g2(allocator, points, scalars);
    try std.testing.expect(curve.g2_eq(expected, cpu_pi));

    const soa = try transposeG2(allocator, points);
    defer soa.deinit(allocator);
    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();
    const gpu_pi = try metalG2(prover, allocator, soa, 0, n * 32, std.mem.sliceAsBytes(scalars), prover.command_queue_2);
    try std.testing.expect(curve.g2_eq(expected, gpu_pi));
}

test "gpu path: Metal G2 MSM matches the closed form past the 64k split" {
    if (@import("builtin").os.tag != .macos) return;
    const allocator = std.testing.allocator;
    // shuffle_1_deck_52 leaves 122944 points on Metal. Stay in that band.
    const n: usize = 70000;
    const table = g2Table();
    const expected = closedFormG2(table, n);

    const points = try allocator.alloc(curve.G2PointAffine, n);
    defer allocator.free(points);
    assignG2(points, table);
    const scalars = try allocator.alloc(field.FrElement, n);
    defer allocator.free(scalars);
    fillScalars(scalars);

    const soa = try transposeG2(allocator, points);
    defer soa.deinit(allocator);
    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();
    const gpu_pi = try metalG2(prover, allocator, soa, 0, n * 32, std.mem.sliceAsBytes(scalars), prover.command_queue_2);
    try std.testing.expect(curve.g2_eq(expected, gpu_pi));
}

fn expectHybridG2(allocator: std.mem.Allocator, n: usize) !void {
    const table = g2Table();
    const expected = closedFormG2(table, n);

    const points = try allocator.alloc(curve.G2PointAffine, n);
    defer allocator.free(points);
    assignG2(points, table);
    const scalars = try allocator.alloc(field.FrElement, n);
    defer allocator.free(scalars);
    fillScalars(scalars);

    const cpu_prefix = try msm.msm_g2(allocator, points[0..g2_chunk], scalars[0..g2_chunk]);
    const soa = try transposeG2(allocator, points);
    defer soa.deinit(allocator);
    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();
    const scalar_bytes = std.mem.sliceAsBytes(scalars);
    const gpu_tail = try metalG2(
        prover,
        allocator,
        soa,
        g2_chunk * 32,
        (n - g2_chunk) * 32,
        scalar_bytes[g2_chunk * 32 ..],
        prover.command_queue_2,
    );
    const hybrid = curve.g2_add(cpu_prefix, gpu_tail);
    try std.testing.expect(curve.g2_eq(expected, hybrid));
}

test "gpu path: CPU 64k prefix plus Metal tail matches the full G2 MSM" {
    if (@import("builtin").os.tag != .macos) return;
    // Not a multiple of 4, so the signed-window SIMD remainder path runs.
    try expectHybridG2(std.testing.allocator, g2_chunk + 7);
}

test "gpu path: hybrid G2 matches the closed form at the 8-deck shuffle size" {
    if (@import("builtin").os.tag != .macos) return;
    // shuffle_8_deck_52_main: 2250988 G2 points, Metal takes the tail past 65536.
    try expectHybridG2(std.testing.allocator, shuffle_8_deck_nvars);
}

const QueueOverlap = struct {
    prover: *metal.MetalProver,
    allocator: std.mem.Allocator,
    g2_soa: G2Soa,
    g2_scalars: []const u8,
    g2_queue: @TypeOf(@as(metal.MetalProver, undefined).command_queue_2),
    g1_points: []const u8,
    g1_scalars: []const u8,
    g1_queue: @TypeOf(@as(metal.MetalProver, undefined).command_queue_2),
    g2: curve.G2Point = curve.g2_zero(),
    g1: curve.G1Point = curve.g1_zero(),
    g2_err: ?anyerror = null,
    g1_err: ?anyerror = null,

    fn runG2(ctx: *@This()) void {
        ctx.g2 = metalG2(ctx.prover, ctx.allocator, ctx.g2_soa, 0, ctx.g2_soa.x_c0.len, ctx.g2_scalars, ctx.g2_queue) catch |e| {
            ctx.g2_err = e;
            return;
        };
    }

    fn runG1(ctx: *@This()) void {
        ctx.g1 = metalG1(ctx.prover, ctx.allocator, ctx.g1_points, ctx.g1_scalars, ctx.g1_queue) catch |e| {
            ctx.g1_err = e;
            return;
        };
    }
};

fn overlapQueues(same_queue: bool) !void {
    const allocator = std.heap.c_allocator;
    const n_g2: usize = 65536;
    const n_g1: usize = 32768;
    const g2_table = g2Table();
    const g1_table = g1Table();
    const expect_g2 = closedFormG2(g2_table, n_g2);
    const expect_g1 = closedFormG1(g1_table, n_g1);

    const g2_points = try allocator.alloc(curve.G2PointAffine, n_g2);
    defer allocator.free(g2_points);
    assignG2(g2_points, g2_table);
    const g2_scalars = try allocator.alloc(field.FrElement, n_g2);
    defer allocator.free(g2_scalars);
    fillScalars(g2_scalars);
    const soa = try transposeG2(allocator, g2_points);
    defer soa.deinit(allocator);

    const g1_points_aff = try allocator.alloc(curve.G1PointAffine, n_g1);
    defer allocator.free(g1_points_aff);
    assignG1(g1_points_aff, g1_table);
    const g1_scalars = try allocator.alloc(field.FrElement, n_g1);
    defer allocator.free(g1_scalars);
    fillScalars(g1_scalars);
    const g1_bytes = try g1PointBytes(allocator, g1_points_aff);
    defer allocator.free(g1_bytes);

    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();

    const serial_g2 = try metalG2(prover, allocator, soa, 0, n_g2 * 32, std.mem.sliceAsBytes(g2_scalars), prover.command_queue_2);
    const serial_g1 = try metalG1(prover, allocator, g1_bytes, std.mem.sliceAsBytes(g1_scalars), prover.command_queue_2);
    try std.testing.expect(curve.g2_eq(expect_g2, serial_g2));
    try std.testing.expect(curve.g1_eq(expect_g1, serial_g1));

    var ctx = QueueOverlap{
        .prover = prover,
        .allocator = allocator,
        .g2_soa = soa,
        .g2_scalars = std.mem.sliceAsBytes(g2_scalars),
        .g2_queue = prover.command_queue_2,
        .g1_points = g1_bytes,
        .g1_scalars = std.mem.sliceAsBytes(g1_scalars),
        .g1_queue = if (same_queue) prover.command_queue_2 else prover.command_queue,
    };
    const g2_thread = try std.Thread.spawn(.{}, QueueOverlap.runG2, .{&ctx});
    const g1_thread = try std.Thread.spawn(.{}, QueueOverlap.runG1, .{&ctx});
    g2_thread.join();
    g1_thread.join();
    if (ctx.g2_err) |e| return e;
    if (ctx.g1_err) |e| return e;
    try std.testing.expect(curve.g2_eq(serial_g2, ctx.g2));
    try std.testing.expect(curve.g1_eq(serial_g1, ctx.g1));
}

test "gpu path: G1 MSM submitted on G2's queue while G2 is in flight matches serial" {
    if (@import("builtin").os.tag != .macos) return;
    try overlapQueues(true);
}

test "gpu path: G1 MSM on a second queue while G2 is in flight matches serial" {
    if (@import("builtin").os.tag != .macos) return;
    try overlapQueues(false);
}

fn expectH(domain: u32) !void {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(domain);
    const a = try allocator.alloc(field.FrElement, domain);
    defer allocator.free(a);
    const b = try allocator.alloc(field.FrElement, domain);
    defer allocator.free(b);
    const c = try allocator.alloc(field.FrElement, domain);
    defer allocator.free(c);
    for (0..domain) |i| {
        a[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
        b[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
        c[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
    }

    const h_cpu = try cpu.prover.calculateH(allocator, a, b, c, domain);
    defer allocator.free(h_cpu);
    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();
    const h_gpu = try prover.calculateHGpu(allocator, a, b, c, domain, 32);
    defer allocator.free(h_gpu);

    try std.testing.expectEqual(h_cpu.len, h_gpu.len);
    for (h_cpu, h_gpu, 0..) |cpu_elem, gpu_elem, i| {
        if (!field.fr_eq(cpu_elem, gpu_elem)) {
            std.debug.print("calculateH mismatch at domain {d} index {d}\n", .{ domain, i });
            return error.HMismatch;
        }
    }
}

test "gpu path: calculateHGpu matches CPU at the Metal FFT threshold" {
    if (@import("builtin").os.tag != .macos) return;
    try expectH(4096);
}

test "gpu path: calculateHGpu matches CPU at the 1-deck shuffle domain" {
    if (@import("builtin").os.tag != .macos) return;
    // shuffle_1_deck_52 domainSize. The testdata H check is 1024, which stays on the CPU FFT.
    try expectH(shuffle_1_deck_domain);
}

test "gpu path: calculateHGpu matches CPU at the 8-deck shuffle domain" {
    if (@import("builtin").os.tag != .macos) return;
    // shuffle_8_deck_52 domainSize, equal to the prover's max FFT buffer (1 << 22).
    try expectH(shuffle_8_deck_domain);
}
