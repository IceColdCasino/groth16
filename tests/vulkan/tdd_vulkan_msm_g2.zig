const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const vulkan = gpu.vulkan;
const field = cpu.field;
const curve = cpu.curve;
const msm = cpu.msm;
const testdata = @import("testdata");

// ============================================================================
// TDD Vulkan G2 MSM Tests — compare Vulkan msmG2_v6 against CPU msm_g2_small
// ============================================================================

test "TDD: Vulkan msmG2_v6 pi_b matches CPU msm_g2_small" {
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

    // Parse G2 points from zkey section 7
    const points_b2 = try cpu.prover.parseG2Points(allocator, zkey, 7, nVars);
    defer allocator.free(points_b2);

    // Parse witness scalars
    const witness_fr = try allocator.alloc(field.FrElement, nVars);
    defer allocator.free(witness_fr);
    @memcpy(std.mem.sliceAsBytes(witness_fr), wtns.data[0 .. nVars * fr_bytes]);

    // CPU reference
    const cpu_pi_b = msm.msm_g2_small(points_b2, witness_fr);

    // GPU version
    const sec7 = zkey.getSection(7).?;
    const points_b2_bytes = sec7[0 .. nVars * 128];
    const witness_bytes = wtns.data[0 .. nVars * fr_bytes];

    // Preprocess sorted windows
    const sorted = try gpu.preprocessSortedWindows(allocator, witness_bytes, 8);
    defer sorted.deinit(allocator);

    // Create negated points
    const negated_points_b2 = try allocator.alloc(cpu.curve.G2PointAffine, nVars);
    defer allocator.free(negated_points_b2);
    for (0..nVars) |i| {
        negated_points_b2[i] = .{
            .x = points_b2[i].x,
            .y = cpu.field.fq2_neg(points_b2[i].y),
        };
    }
    const negated_points_b2_bytes = std.mem.sliceAsBytes(negated_points_b2);

    // Transpose to SoA
    const fq_size = @sizeOf([4]u64);
    const x_c0 = try allocator.alloc(u8, nVars * fq_size);
    defer allocator.free(x_c0);
    const x_c1 = try allocator.alloc(u8, nVars * fq_size);
    defer allocator.free(x_c1);
    const y_c0 = try allocator.alloc(u8, nVars * fq_size);
    defer allocator.free(y_c0);
    const y_c1 = try allocator.alloc(u8, nVars * fq_size);
    defer allocator.free(y_c1);
    const neg_y_c0 = try allocator.alloc(u8, nVars * fq_size);
    defer allocator.free(neg_y_c0);
    const neg_y_c1 = try allocator.alloc(u8, nVars * fq_size);
    defer allocator.free(neg_y_c1);

    for (0..nVars) |i| {
        const pos_src = i * @sizeOf(cpu.curve.G2PointAffine);
        const neg_src = i * @sizeOf(cpu.curve.G2PointAffine);
        const dst_offset = i * fq_size;
        @memcpy(x_c0[dst_offset..][0..fq_size], points_b2_bytes[pos_src + 0 * fq_size ..][0..fq_size]);
        @memcpy(x_c1[dst_offset..][0..fq_size], points_b2_bytes[pos_src + 1 * fq_size ..][0..fq_size]);
        @memcpy(y_c0[dst_offset..][0..fq_size], points_b2_bytes[pos_src + 2 * fq_size ..][0..fq_size]);
        @memcpy(y_c1[dst_offset..][0..fq_size], points_b2_bytes[pos_src + 3 * fq_size ..][0..fq_size]);
        @memcpy(neg_y_c0[dst_offset..][0..fq_size], negated_points_b2_bytes[neg_src + 2 * fq_size ..][0..fq_size]);
        @memcpy(neg_y_c1[dst_offset..][0..fq_size], negated_points_b2_bytes[neg_src + 3 * fq_size ..][0..fq_size]);
    }

    const g2_config = gpu.MSMConfig{
        .n_points = @intCast(nVars),
        .n_windows = 32,
        .window_size = 8,
        .n_buckets = 256,
    };

    const gpu_windows = try prover.msmG2_v6(x_c0, x_c1, y_c0, y_c1, neg_y_c0, neg_y_c1, g2_config, sorted.bucket_offsets, sorted.sorted_indices);
    defer allocator.free(gpu_windows);
    const gpu_pi_b = vulkan.accumulateG2(gpu_windows);

    if (!curve.g2_eq(cpu_pi_b, gpu_pi_b)) {
        std.debug.print("Vulkan G2 MSM mismatch for pi_b\n", .{});
    }
    try std.testing.expect(curve.g2_eq(cpu_pi_b, gpu_pi_b));
}
