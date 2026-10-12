//! G1 scalar multiplication split across CPU threads and the Metal GPU.
const std = @import("std");
const curve = @import("curve.zig");
const ff = @import("ff.zig");
const gpu = @import("metal.zig");

var g1_gpu_point_ns: u64 = 0;

const CpuJob = struct {
    points: []const u8,
    scalars: []const u8,
    out: []u8,

    fn run(self: *CpuJob) void {
        cpuRange(self.points, self.scalars, self.out);
    }
};

pub fn mulSame(alloc: std.mem.Allocator, io: std.Io, points: []const u8, scalar: [4]u64, out: []u8) !void {
    const n = points.len / 64;
    if (n == 0) return;
    var scalars = try alloc.alloc(u8, n * 32);
    defer alloc.free(scalars);
    var raw: [32]u8 = undefined;
    inline for (0..4) |i| std.mem.writeInt(u64, raw[i * 8 ..][0..8], scalar[i], .little);
    var i: usize = 0;
    while (i < n) : (i += 1) @memcpy(scalars[i * 32 ..][0..32], &raw);
    try mulMany(alloc, io, points, scalars, out, 0);
}

/// How many points the GPU should take. Zero means the CPU does the whole batch.
/// `cpu_extra` is other CPU work, counted in scalar multiplications, that runs
/// before the CPU's share of this batch and beside the GPU.
pub fn choose(alloc: std.mem.Allocator, io: std.Io, points: []const u8, scalars: []const u8, cpu_extra: usize) !usize {
    const n = points.len / 64;
    if (n < 2048 or !gpu.init(io) or !gpuAgrees()) return 0;
    const probe: usize = @min(n, 16384);
    const cpu_ns = timeCpu(io, points[0 .. probe * 64], scalars[0 .. probe * 32]);
    const gpu_out = try alloc.alloc(u8, probe * 64);
    defer alloc.free(gpu_out);
    const gpu_start = std.Io.Clock.Timestamp.now(io, .awake);
    if (!gpu.g1Many(points[0 .. probe * 64], scalars[0 .. probe * 32], gpu_out)) return 0;
    const gpu_ns = nanos(gpu_start.durationTo(.now(io, .awake)).raw.nanoseconds);
    const check = try alloc.alloc(u8, probe * 64);
    defer alloc.free(check);
    cpuRange(points[0 .. probe * 64], scalars[0 .. probe * 32], check);
    if (!std.mem.eql(u8, gpu_out, check)) {
        std.debug.print("Metal disagreed with the CPU, using CPU cores only\n", .{});
        return 0;
    }
    const gpu_n = gpuCount(n, cpu_extra, cpu_ns, gpu_ns, threadCount(), probe);
    if (probe > 0) g1_gpu_point_ns = gpu_ns / probe;
    std.debug.print("probe {d}: one CPU thread {d} ms, Metal {d} ms\n", .{ probe, cpu_ns / 1_000_000, gpu_ns / 1_000_000 });
    std.debug.print("scalar muls {d} on Metal, {d} on {d} CPU threads\n", .{ gpu_n, n - gpu_n, threadCount() });
    return gpu_n;
}

pub fn gpuPart(points: []const u8, scalars: []const u8, out: []u8) bool {
    return gpu.g1Many(points, scalars, out);
}

pub fn cpuPart(points: []const u8, scalars: []const u8, out: []u8) void {
    cpuAll(points, scalars, out);
}

/// `cpu_extra` is other CPU work, in units of one scalar multiplication, that runs
/// beside the GPU. The split leaves the CPU that much less of this batch.
pub fn mulMany(alloc: std.mem.Allocator, io: std.Io, points: []const u8, scalars: []const u8, out: []u8, cpu_extra: usize) !void {
    const n = points.len / 64;
    if (n == 0) return;
    const gpu_n = try choose(alloc, io, points, scalars, cpu_extra);
    if (gpu_n == 0) {
        cpuAll(points, scalars, out);
        return;
    }
    const GpuArgs = struct {
        points: []const u8,
        scalars: []const u8,
        out: []u8,
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = gpu.g1Many(self.points, self.scalars, self.out);
        }
    };
    var args = GpuArgs{
        .points = points[0 .. gpu_n * 64],
        .scalars = scalars[0 .. gpu_n * 32],
        .out = out[0 .. gpu_n * 64],
    };
    const gpu_thread = try std.Thread.spawn(.{}, GpuArgs.run, .{&args});
    cpuParallel(points[gpu_n * 64 ..], scalars[gpu_n * 32 ..], out[gpu_n * 64 ..], threadCount());
    gpu_thread.join();
    if (!args.ok) cpuRange(points[0 .. gpu_n * 64], scalars[0 .. gpu_n * 32], out[0 .. gpu_n * 64]);
}

fn gpuAgrees() bool {
    var p: [64]u8 = undefined;
    curve.g1Generator().store(&p);
    var s: [32]u8 = undefined;
    std.mem.writeInt(u64, s[0..8], 3, .little);
    @memset(s[8..], 0);
    var gpu_out: [64]u8 = undefined;
    if (!gpu.g1Many(&p, &s, &gpu_out)) return false;
    var cpu_out: [64]u8 = undefined;
    const jac = curve.scaleG1(curve.g1Generator(), .{ 3, 0, 0, 0 });
    var one = [_]curve.G1.Jac{jac};
    curve.G1.storeJacMany(&one, &cpu_out);
    if (!std.mem.eql(u8, &gpu_out, &cpu_out)) {
        std.debug.print("Metal generator check failed, using CPU cores only\n", .{});
        return false;
    }
    return true;
}

fn gpuCount(n: usize, cpu_extra: usize, cpu_ns: u64, gpu_ns: u64, threads: usize, probe: usize) usize {
    if (gpu_ns == 0 or cpu_ns == 0 or threads == 0) return n / 2;
    const g = @as(f64, @floatFromInt(cpu_ns)) / @as(f64, @floatFromInt(gpu_ns));
    const hard: f64 = @floatFromInt(n);
    const extra: f64 = @floatFromInt(cpu_extra);
    const t: f64 = @floatFromInt(threads);
    const denom = hard * (t / g + 1.0);
    if (denom == 0) return n / 2;
    var frac = (extra + hard) / denom;
    if (frac < 0.05) frac = 0.05;
    if (frac > 1) frac = 1;
    var gpu_n: usize = @intFromFloat(frac * hard);
    const floor = @min(probe, @max(n / 5, 1));
    if (gpu_n < floor) gpu_n = floor;
    if (gpu_n > n - floor) gpu_n = n - floor;
    if (gpu_n == 0 or gpu_n >= n) gpu_n = n / 2;
    return gpu_n;
}

fn timeCpu(io: std.Io, points: []const u8, scalars: []const u8) u64 {
    const out = std.heap.c_allocator.alloc(u8, points.len) catch return 1;
    defer std.heap.c_allocator.free(out);
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    cpuRange(points, scalars, out);
    return nanos(start.durationTo(.now(io, .awake)).raw.nanoseconds);
}

fn nanos(ns: i96) u64 {
    if (ns <= 0) return 1;
    return @intCast(ns);
}

fn cpuAll(points: []const u8, scalars: []const u8, out: []u8) void {
    cpuParallel(points, scalars, out, threadCount());
}

fn cpuParallel(points: []const u8, scalars: []const u8, out: []u8, nthreads: usize) void {
    const n = points.len / 64;
    if (n == 0) return;
    const nt = @min(@max(nthreads, 1), n);
    if (nt == 1) {
        cpuRange(points, scalars, out);
        return;
    }
    var threads: [32]std.Thread = undefined;
    var jobs: [32]CpuJob = undefined;
    const use = @min(nt, 32);
    var cursor: usize = 0;
    var nspawn: usize = 0;
    const base = n / use;
    var extra = n % use;
    for (0..use) |i| {
        const count = base + @as(usize, if (extra > 0) 1 else 0);
        if (extra > 0) extra -= 1;
        jobs[i] = .{
            .points = points[cursor * 64 .. (cursor + count) * 64],
            .scalars = scalars[cursor * 32 .. (cursor + count) * 32],
            .out = out[cursor * 64 .. (cursor + count) * 64],
        };
        if (std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, CpuJob.run, .{&jobs[i]})) |t| {
            threads[nspawn] = t;
            nspawn += 1;
        } else |_| {
            cpuRange(jobs[i].points, jobs[i].scalars, jobs[i].out);
        }
        cursor += count;
    }
    for (threads[0..nspawn]) |t| t.join();
}

fn cpuRange(points: []const u8, scalars: []const u8, out: []u8) void {
    const n = points.len / 64;
    const jacs = std.heap.c_allocator.alloc(curve.G1.Jac, n) catch {
        for (0..n) |i| {
            const p = curve.loadG1(points, i);
            const k = ff.loadLimbs(scalars[i * 32 ..][0..32]);
            var one = [_]curve.G1.Jac{curve.scaleG1(p, k)};
            curve.G1.storeJacMany(&one, out[i * 64 ..][0..64]);
        }
        return;
    };
    defer std.heap.c_allocator.free(jacs);
    for (0..n) |i| {
        const p = curve.loadG1(points, i);
        const k = ff.loadLimbs(scalars[i * 32 ..][0..32]);
        jacs[i] = curve.scaleG1(p, k);
    }
    curve.G1.storeJacMany(jacs, out);
}

pub fn g1GpuNs(n: usize) u64 {
    return g1_gpu_point_ns * @as(u64, @intCast(n));
}

pub const G2In = struct {
    p1: []u8,
    p2: []u8,
    ks: []u8,

    pub fn deinit(self: G2In, alloc: std.mem.Allocator) void {
        alloc.free(self.p1);
        alloc.free(self.p2);
        alloc.free(self.ks);
    }
};

/// How many G2 multiplications Metal should run after it finishes the G1 batch.
/// `g1_ns` is the estimated GPU time for that G1 batch. Zero means the CPUs do every G2 mul.
pub fn planG2(alloc: std.mem.Allocator, io: std.Io, points: []const u8, scalars: []const u8, g1_ns: u64) !usize {
    const n = points.len / 128;
    if (n < 2048 or !gpu.init(io)) return 0;
    const probe: usize = @min(n, 4096);
    const prep = try prepareG2(alloc, points[0 .. probe * 128], scalars[0 .. probe * 32]) orelse return 0;
    defer prep.deinit(alloc);
    var warm: [192]u8 = undefined;
    if (!gpu.g2Many(prep.p1[0..128], prep.p2[0..128], prep.ks[0..32], &warm)) return 0;
    const gpu_jac = try alloc.alloc(u8, probe * 192);
    defer alloc.free(gpu_jac);
    const gpu_out = try alloc.alloc(u8, probe * 128);
    defer alloc.free(gpu_out);
    const gpu_start = std.Io.Clock.Timestamp.now(io, .awake);
    if (!gpu.g2Many(prep.p1, prep.p2, prep.ks, gpu_jac)) return 0;
    const gpu_ns = nanos(gpu_start.durationTo(.now(io, .awake)).raw.nanoseconds);
    g2ToAffine(gpu_jac, gpu_out);
    const cpu_out = try alloc.alloc(u8, probe * 128);
    defer alloc.free(cpu_out);
    const cpu_start = std.Io.Clock.Timestamp.now(io, .awake);
    g2Range(points[0 .. probe * 128], scalars[0 .. probe * 32], cpu_out);
    const cpu_ns = nanos(cpu_start.durationTo(.now(io, .awake)).raw.nanoseconds);
    if (!std.mem.eql(u8, gpu_out, cpu_out)) {
        std.debug.print("Metal G2 disagreed with the CPU, G2 stays on the CPUs\n", .{});
        return 0;
    }
    const gpu_n = g2Share(n, cpu_ns, gpu_ns, threadCount(), g1_ns, probe);
    std.debug.print("G2 probe {d}: one CPU thread {d} ms, Metal {d} ms\n", .{ probe, cpu_ns / 1_000_000, gpu_ns / 1_000_000 });
    std.debug.print("G2 scalar muls {d} on Metal, {d} on {d} CPU threads\n", .{ gpu_n, n - gpu_n, threadCount() });
    return gpu_n;
}

pub fn prepareG2(alloc: std.mem.Allocator, points: []const u8, scalars: []const u8) !?G2In {
    const n = points.len / 128;
    const p1 = try alloc.alloc(u8, n * 128);
    errdefer alloc.free(p1);
    const p2 = try alloc.alloc(u8, n * 128);
    errdefer alloc.free(p2);
    const ks = try alloc.alloc(u8, n * 32);
    errdefer alloc.free(ks);
    if (!prepareParallel(points, scalars, p1, p2, ks)) {
        alloc.free(p1);
        alloc.free(p2);
        alloc.free(ks);
        return null;
    }
    return .{ .p1 = p1, .p2 = p2, .ks = ks };
}

pub fn g2Part(p1: []const u8, p2: []const u8, ks: []const u8, out: []u8) bool {
    const n = out.len / 128;
    if (n == 0) return true;
    const jac = std.heap.c_allocator.alloc(u8, n * 192) catch return false;
    defer std.heap.c_allocator.free(jac);
    if (!gpu.g2Many(p1, p2, ks, jac)) return false;
    g2ToAffine(jac, out);
    return true;
}

fn g2ToAffine(jac_bytes: []const u8, out: []u8) void {
    const n = jac_bytes.len / 192;
    const jacs = std.heap.c_allocator.alloc(curve.G2.Jac, n) catch return;
    defer std.heap.c_allocator.free(jacs);
    for (0..n) |i| {
        const o = i * 192;
        jacs[i] = .{
            .x = .{ .c0 = .{ .limbs = ff.loadLimbs(jac_bytes[o..][0..32]) }, .c1 = .{ .limbs = ff.loadLimbs(jac_bytes[o + 32 ..][0..32]) } },
            .y = .{ .c0 = .{ .limbs = ff.loadLimbs(jac_bytes[o + 64 ..][0..32]) }, .c1 = .{ .limbs = ff.loadLimbs(jac_bytes[o + 96 ..][0..32]) } },
            .z = .{ .c0 = .{ .limbs = ff.loadLimbs(jac_bytes[o + 128 ..][0..32]) }, .c1 = .{ .limbs = ff.loadLimbs(jac_bytes[o + 160 ..][0..32]) } },
        };
    }
    curve.G2.storeJacMany(jacs, out);
}

pub fn g2Cpu(points: []const u8, scalars: []const u8, out: []u8) void {
    const n = points.len / 128;
    if (n == 0) return;
    g2Parallel(points, scalars, out, threadCount());
}

fn g2Share(n: usize, cpu_ns: u64, gpu_ns: u64, threads: usize, g1_ns: u64, probe: usize) usize {
    if (probe == 0 or threads == 0 or cpu_ns == 0 or gpu_ns == 0) return 0;
    const nn: u128 = n;
    const cpu_all: u128 = @as(u128, cpu_ns) * nn / probe / threads;
    const gpu_all: u128 = @as(u128, gpu_ns) * nn / probe;
    const g1: u128 = g1_ns;
    if (cpu_all <= g1) return 0;
    const gpu_n: usize = @intCast(nn * (cpu_all - g1) / (cpu_all + gpu_all));
    if (gpu_n < 2048) return 0;
    if (gpu_n >= n) return n - @min(n, 2048);
    return gpu_n;
}

fn prepareParallel(points: []const u8, scalars: []const u8, p1: []u8, p2: []u8, ks: []u8) bool {
    const n = points.len / 128;
    if (n == 0) return true;
    const nt = @min(@max(threadCount(), 1), n);
    if (nt == 1) return prepareRange(points, scalars, p1, p2, ks);
    const Prep = struct {
        points: []const u8,
        scalars: []const u8,
        p1: []u8,
        p2: []u8,
        ks: []u8,
        ok: bool = true,
        fn run(self: *@This()) void {
            self.ok = prepareRange(self.points, self.scalars, self.p1, self.p2, self.ks);
        }
    };
    var jobs: [32]Prep = undefined;
    var threads: [32]std.Thread = undefined;
    const use = @min(nt, 32);
    var cursor: usize = 0;
    var nspawn: usize = 0;
    const base = n / use;
    var extra = n % use;
    for (0..use) |i| {
        const count = base + @as(usize, if (extra > 0) 1 else 0);
        if (extra > 0) extra -= 1;
        jobs[i] = .{
            .points = points[cursor * 128 .. (cursor + count) * 128],
            .scalars = scalars[cursor * 32 .. (cursor + count) * 32],
            .p1 = p1[cursor * 128 .. (cursor + count) * 128],
            .p2 = p2[cursor * 128 .. (cursor + count) * 128],
            .ks = ks[cursor * 32 .. (cursor + count) * 32],
        };
        if (std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, Prep.run, .{&jobs[i]})) |t| {
            threads[nspawn] = t;
            nspawn += 1;
        } else |_| jobs[i].ok = prepareRange(jobs[i].points, jobs[i].scalars, jobs[i].p1, jobs[i].p2, jobs[i].ks);
        cursor += count;
    }
    for (threads[0..nspawn]) |t| t.join();
    for (jobs[0..use]) |job| if (!job.ok) return false;
    return true;
}

fn prepareRange(points: []const u8, scalars: []const u8, p1: []u8, p2: []u8, ks: []u8) bool {
    const n = points.len / 128;
    for (0..n) |i| {
        const p = curve.loadG2(points, i);
        const k = ff.loadLimbs(scalars[i * 32 ..][0..32]);
        const got = curve.prepareG2Glv(p, k) orelse return false;
        @memcpy(p1[i * 128 ..][0..128], &got.p1);
        @memcpy(p2[i * 128 ..][0..128], &got.p2);
        @memcpy(ks[i * 32 ..][0..32], &got.scalar);
    }
    return true;
}

fn g2Parallel(points: []const u8, scalars: []const u8, out: []u8, nthreads: usize) void {
    const n = points.len / 128;
    const nt = @min(@max(nthreads, 1), n);
    if (nt == 1) {
        g2Range(points, scalars, out);
        return;
    }
    const Job = struct {
        points: []const u8,
        scalars: []const u8,
        out: []u8,
        fn run(self: *@This()) void {
            g2Range(self.points, self.scalars, self.out);
        }
    };
    var jobs: [32]Job = undefined;
    var threads: [32]std.Thread = undefined;
    const use = @min(nt, 32);
    var cursor: usize = 0;
    var nspawn: usize = 0;
    const base = n / use;
    var extra = n % use;
    for (0..use) |i| {
        const count = base + @as(usize, if (extra > 0) 1 else 0);
        if (extra > 0) extra -= 1;
        jobs[i] = .{
            .points = points[cursor * 128 .. (cursor + count) * 128],
            .scalars = scalars[cursor * 32 .. (cursor + count) * 32],
            .out = out[cursor * 128 .. (cursor + count) * 128],
        };
        if (std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, Job.run, .{&jobs[i]})) |t| {
            threads[nspawn] = t;
            nspawn += 1;
        } else |_| g2Range(jobs[i].points, jobs[i].scalars, jobs[i].out);
        cursor += count;
    }
    for (threads[0..nspawn]) |t| t.join();
}

fn g2Range(points: []const u8, scalars: []const u8, out: []u8) void {
    const n = points.len / 128;
    const jacs = std.heap.c_allocator.alloc(curve.G2.Jac, n) catch {
        for (0..n) |i| {
            const p = curve.loadG2(points, i);
            const k = ff.loadLimbs(scalars[i * 32 ..][0..32]);
            var one = [_]curve.G2.Jac{curve.scaleG2(p, k)};
            curve.G2.storeJacMany(&one, out[i * 128 ..][0..128]);
        }
        return;
    };
    defer std.heap.c_allocator.free(jacs);
    for (0..n) |i| {
        const p = curve.loadG2(points, i);
        const k = ff.loadLimbs(scalars[i * 32 ..][0..32]);
        jacs[i] = curve.scaleG2(p, k);
    }
    curve.G2.storeJacMany(jacs, out);
}

fn threadCount() usize {
    const cpu = std.Thread.getCpuCount() catch 1;
    var n = cpu;
    if (std.c.getenv("ZKEY_THREADS")) |raw| {
        n = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch cpu;
    }
    if (n == 0) n = 1;
    return n;
}
