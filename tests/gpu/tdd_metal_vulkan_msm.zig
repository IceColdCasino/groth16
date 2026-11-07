const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const field = cpu.field;
const curve = cpu.curve;
const testdata = @import("testdata");

test "Metal and Vulkan msmG1_v5 agree" {
    const allocator = std.testing.allocator;
    var zkey = try cpu.parser.parseZkey(allocator, testdata.ZKEY);
    defer zkey.deinit(allocator);
    var wtns = try cpu.parser.parseWitness(allocator, testdata.WTNS);
    defer wtns.deinit(allocator);

    const n_vars = zkey.header.nVars;
    const sec5 = zkey.getSection(5).?;
    const points = sec5[0 .. n_vars * 64];
    const scalars = wtns.data[0 .. n_vars * @sizeOf(field.FrElement)];
    const sorted = try gpu.preprocessSortedWindows(allocator, scalars, 8);
    defer sorted.deinit(allocator);

    var metal_prover = try gpu.metal.MetalProver.init(allocator);
    defer metal_prover.deinit();
    var vulkan_prover = try gpu.vulkan.VulkanProver.init(allocator);
    defer vulkan_prover.deinit();

    const metal_windows = try metal_prover.msmG1_v5(points, sorted);
    defer allocator.free(metal_windows);

    const fq: usize = 32;
    const x_data = try allocator.alloc(u8, n_vars * fq);
    defer allocator.free(x_data);
    const y_data = try allocator.alloc(u8, n_vars * fq);
    defer allocator.free(y_data);
    const neg_y_data = try allocator.alloc(u8, n_vars * fq);
    defer allocator.free(neg_y_data);
    const typed = std.mem.bytesAsSlice(cpu.curve.G1PointAffine, points);
    for (typed, 0..) |pt, i| {
        @memcpy(x_data[i * fq ..][0..fq], std.mem.asBytes(&pt.x));
        @memcpy(y_data[i * fq ..][0..fq], std.mem.asBytes(&pt.y));
        const neg_y = field.fq_neg(pt.y);
        @memcpy(neg_y_data[i * fq ..][0..fq], std.mem.asBytes(&neg_y));
    }
    const config = gpu.MSMConfig{
        .n_points = @intCast(n_vars),
        .n_windows = 32,
        .window_size = 8,
        .n_buckets = 256,
    };
    const vulkan_windows = try vulkan_prover.msmG1_v5(x_data, y_data, neg_y_data, config, sorted.bucket_offsets, sorted.sorted_indices);
    defer allocator.free(vulkan_windows);

    const metal_point = gpu.metal.accumulateG1(metal_windows);
    const vulkan_point = gpu.vulkan.accumulateG1(vulkan_windows);
    try std.testing.expect(curve.g1_eq(metal_point, vulkan_point));
}

test "Metal and Vulkan msmG2_v6 agree" {
    const allocator = std.testing.allocator;
    var zkey = try cpu.parser.parseZkey(allocator, testdata.ZKEY);
    defer zkey.deinit(allocator);
    var wtns = try cpu.parser.parseWitness(allocator, testdata.WTNS);
    defer wtns.deinit(allocator);

    const n_vars = zkey.header.nVars;
    const points_b2 = try cpu.prover.parseG2Points(allocator, zkey, 7, n_vars);
    defer allocator.free(points_b2);
    const sec7 = zkey.getSection(7).?;
    const points = sec7[0 .. n_vars * 128];
    const scalars = wtns.data[0 .. n_vars * @sizeOf(field.FrElement)];
    const sorted = try gpu.preprocessSortedWindows(allocator, scalars, 8);
    defer sorted.deinit(allocator);

    const negated = try allocator.alloc(cpu.curve.G2PointAffine, n_vars);
    defer allocator.free(negated);
    for (points_b2, negated) |pt, *neg| {
        neg.* = .{ .x = pt.x, .y = field.fq2_neg(pt.y) };
    }

    const config = gpu.MSMConfig{
        .n_points = @intCast(n_vars),
        .n_windows = 32,
        .window_size = 8,
        .n_buckets = 256,
    };

    var metal_prover = try gpu.metal.MetalProver.init(allocator);
    defer metal_prover.deinit();
    var vulkan_prover = try gpu.vulkan.VulkanProver.init(allocator);
    defer vulkan_prover.deinit();

    const metal_windows = try metal_prover.msmG2_v6(points, std.mem.sliceAsBytes(negated), sorted, config);
    defer allocator.free(metal_windows);

    const fq: usize = 32;
    const x_c0 = try allocator.alloc(u8, n_vars * fq);
    defer allocator.free(x_c0);
    const x_c1 = try allocator.alloc(u8, n_vars * fq);
    defer allocator.free(x_c1);
    const y_c0 = try allocator.alloc(u8, n_vars * fq);
    defer allocator.free(y_c0);
    const y_c1 = try allocator.alloc(u8, n_vars * fq);
    defer allocator.free(y_c1);
    const neg_y_c0 = try allocator.alloc(u8, n_vars * fq);
    defer allocator.free(neg_y_c0);
    const neg_y_c1 = try allocator.alloc(u8, n_vars * fq);
    defer allocator.free(neg_y_c1);
    const neg_bytes = std.mem.sliceAsBytes(negated);
    for (0..n_vars) |i| {
        const src = i * @sizeOf(cpu.curve.G2PointAffine);
        const dst = i * fq;
        @memcpy(x_c0[dst..][0..fq], points[src + 0 * fq ..][0..fq]);
        @memcpy(x_c1[dst..][0..fq], points[src + 1 * fq ..][0..fq]);
        @memcpy(y_c0[dst..][0..fq], points[src + 2 * fq ..][0..fq]);
        @memcpy(y_c1[dst..][0..fq], points[src + 3 * fq ..][0..fq]);
        @memcpy(neg_y_c0[dst..][0..fq], neg_bytes[src + 2 * fq ..][0..fq]);
        @memcpy(neg_y_c1[dst..][0..fq], neg_bytes[src + 3 * fq ..][0..fq]);
    }
    const vulkan_windows = try vulkan_prover.msmG2_v6(x_c0, x_c1, y_c0, y_c1, neg_y_c0, neg_y_c1, config, sorted.bucket_offsets, sorted.sorted_indices);
    defer allocator.free(vulkan_windows);

    const metal_point = gpu.metal.accumulateG2(metal_windows);
    const vulkan_point = gpu.vulkan.accumulateG2(vulkan_windows);
    try std.testing.expect(curve.g2_eq(metal_point, vulkan_point));
}
