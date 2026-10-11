const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const metal = gpu.metal;
const field = cpu.field;
const curve = cpu.curve;
const msm = cpu.msm;
const testdata = @import("rapidsnark_testdata");

// ============================================================================
// TDD Metal G2 MSM Tests — compare Metal msmG2_v6 against CPU msm_g2_small
// ============================================================================

test "TDD: Metal msmG2_v6 pi_b matches CPU msm_g2_small" {
    if (@import("builtin").os.tag != .macos) return;

    const allocator = std.testing.allocator;

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

    const g2_config = gpu.MSMConfig{
        .n_points = @intCast(nVars),
        .n_windows = 32,
        .window_size = 8,
        .n_buckets = 256,
    };

    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();

    const gpu_windows = try prover.msmG2_v6(points_b2_bytes, negated_points_b2_bytes, sorted, g2_config);
    defer allocator.free(gpu_windows);
    const gpu_pi_b = metal.accumulateG2(gpu_windows);

    if (!curve.g2_eq(cpu_pi_b, gpu_pi_b)) {
        std.debug.print("Metal G2 MSM mismatch for pi_b\n", .{});
    }
    try std.testing.expect(curve.g2_eq(cpu_pi_b, gpu_pi_b));
}
