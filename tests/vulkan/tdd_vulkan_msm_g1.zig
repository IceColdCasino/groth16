const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const vulkan = gpu.vulkan;
const field = cpu.field;
const curve = cpu.curve;
const msm = cpu.msm;
const testdata = @import("testdata");

// ============================================================================
// TDD Vulkan G1 MSM Tests — compare Vulkan msmG1_v5 against CPU msm_g1_pippenger
// ============================================================================

test "TDD: Vulkan msmG1_v5 pi_a matches CPU msm_g1_pippenger" {
    const allocator = std.testing.allocator;

    var prover = vulkan.VulkanProver.init(allocator) catch |e| {
        if (e == error.VulkanNotFound or e == error.NoVulkanDevice or e == error.NoComputeQueue) {
            return;
        }
        return e;
    };
    defer prover.deinit();

    var zkey = try cpu.parser.parseZkey(allocator, testdata.ZKEY);
    defer zkey.deinit(allocator);
    var wtns = try cpu.parser.parseWitness(allocator, testdata.WTNS);
    defer wtns.deinit(allocator);

    const nVars = zkey.header.nVars;
    const fr_bytes = @sizeOf(field.FrElement);

    // Parse G1 points from zkey section 5
    const points_a = try cpu.prover.parseG1Points(allocator, zkey, 5, nVars);
    defer allocator.free(points_a);

    // Parse witness scalars
    const witness_fr = try allocator.alloc(field.FrElement, nVars);
    defer allocator.free(witness_fr);
    @memcpy(std.mem.sliceAsBytes(witness_fr), wtns.data[0 .. nVars * fr_bytes]);

    // CPU reference
    const cpu_pi_a = try msm.msm_g1_pippenger(allocator, points_a, witness_fr);

    // GPU version
    const sec5 = zkey.getSection(5).?;
    const points_a_bytes = sec5[0 .. nVars * 64];
    const witness_bytes = wtns.data[0 .. nVars * fr_bytes];

    const sorted = try gpu.preprocessSortedWindows(allocator, witness_bytes, 8);
    defer sorted.deinit(allocator);

    // Transpose points to SoA (x, y, neg_y)
    const x_data = try allocator.alloc(u8, nVars * 32);
    defer allocator.free(x_data);
    const y_data = try allocator.alloc(u8, nVars * 32);
    defer allocator.free(y_data);
    const neg_y_data = try allocator.alloc(u8, nVars * 32);
    defer allocator.free(neg_y_data);

    for (0..nVars) |i| {
        const offset = i * 64;
        @memcpy(x_data[i * 32 ..][0..32], points_a_bytes[offset + 0 ..][0..32]);
        @memcpy(y_data[i * 32 ..][0..32], points_a_bytes[offset + 32 ..][0..32]);
        const y_elem: *const cpu.field.FqElement = @ptrCast(@alignCast(&y_data[i * 32]));
        const neg_y = cpu.field.fq_neg(y_elem.*);
        @memcpy(neg_y_data[i * 32 ..][0..32], std.mem.sliceAsBytes(&[1]cpu.field.FqElement{neg_y}));
    }

    const g1_config = gpu.MSMConfig{
        .n_points = @intCast(nVars),
        .n_windows = 32,
        .window_size = 8,
        .n_buckets = 256,
    };

    const gpu_windows = try prover.msmG1_v5(x_data, y_data, neg_y_data, g1_config, sorted.bucket_offsets, sorted.sorted_indices);
    defer allocator.free(gpu_windows);
    const gpu_pi_a = vulkan.accumulateG1(gpu_windows);

    if (!curve.g1_eq(cpu_pi_a, gpu_pi_a)) {
        std.debug.print("Vulkan G1 MSM mismatch for pi_a\n", .{});
    }
    try std.testing.expect(curve.g1_eq(cpu_pi_a, gpu_pi_a));
}

test "TDD: Vulkan msmG1_v5 pib1 matches CPU msm_g1_pippenger" {
    const allocator = std.testing.allocator;

    var prover = vulkan.VulkanProver.init(allocator) catch |e| {
        if (e == error.VulkanNotFound or e == error.NoVulkanDevice or e == error.NoComputeQueue) {
            return;
        }
        return e;
    };
    defer prover.deinit();

    var zkey = try cpu.parser.parseZkey(allocator, testdata.ZKEY);
    defer zkey.deinit(allocator);
    var wtns = try cpu.parser.parseWitness(allocator, testdata.WTNS);
    defer wtns.deinit(allocator);

    const nVars = zkey.header.nVars;
    const fr_bytes = @sizeOf(field.FrElement);

    const points_b1 = try cpu.prover.parseG1Points(allocator, zkey, 6, nVars);
    defer allocator.free(points_b1);

    const witness_fr = try allocator.alloc(field.FrElement, nVars);
    defer allocator.free(witness_fr);
    @memcpy(std.mem.sliceAsBytes(witness_fr), wtns.data[0 .. nVars * fr_bytes]);

    const cpu_pib1 = try msm.msm_g1_pippenger(allocator, points_b1, witness_fr);

    const sec6 = zkey.getSection(6).?;
    const points_b1_bytes = sec6[0 .. nVars * 64];
    const witness_bytes = wtns.data[0 .. nVars * fr_bytes];

    const sorted = try gpu.preprocessSortedWindows(allocator, witness_bytes, 8);
    defer sorted.deinit(allocator);

    const x_data = try allocator.alloc(u8, nVars * 32);
    defer allocator.free(x_data);
    const y_data = try allocator.alloc(u8, nVars * 32);
    defer allocator.free(y_data);
    const neg_y_data = try allocator.alloc(u8, nVars * 32);
    defer allocator.free(neg_y_data);

    for (0..nVars) |i| {
        const offset = i * 64;
        @memcpy(x_data[i * 32 ..][0..32], points_b1_bytes[offset + 0 ..][0..32]);
        @memcpy(y_data[i * 32 ..][0..32], points_b1_bytes[offset + 32 ..][0..32]);
        const y_elem: *const cpu.field.FqElement = @ptrCast(@alignCast(&y_data[i * 32]));
        const neg_y = cpu.field.fq_neg(y_elem.*);
        @memcpy(neg_y_data[i * 32 ..][0..32], std.mem.sliceAsBytes(&[1]cpu.field.FqElement{neg_y}));
    }

    const g1_config = gpu.MSMConfig{
        .n_points = @intCast(nVars),
        .n_windows = 32,
        .window_size = 8,
        .n_buckets = 256,
    };

    const gpu_windows = try prover.msmG1_v5(x_data, y_data, neg_y_data, g1_config, sorted.bucket_offsets, sorted.sorted_indices);
    defer allocator.free(gpu_windows);
    const gpu_pib1 = vulkan.accumulateG1(gpu_windows);

    if (!curve.g1_eq(cpu_pib1, gpu_pib1)) {
        std.debug.print("Vulkan G1 MSM mismatch for pib1\n", .{});
    }
    try std.testing.expect(curve.g1_eq(cpu_pib1, gpu_pib1));
}
