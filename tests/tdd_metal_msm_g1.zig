const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const metal = gpu.metal;
const field = cpu.field;
const curve = cpu.curve;
const msm = cpu.msm;
const testdata = @import("rapidsnark_testdata");

// ============================================================================
// TDD Metal G1 MSM Tests — compare Metal msmG1_v5 against CPU msm_g1_pippenger
// ============================================================================

test "TDD: Metal msmG1_v5 pi_a matches CPU msm_g1_pippenger" {
    if (@import("builtin").os.tag != .macos) return;

    const allocator = std.testing.allocator;

    var zkey = try cpu.parser.parseZkey(allocator, testdata.ZKEY);
    defer zkey.deinit(allocator);
    var wtns = try cpu.parser.parseWitness(allocator, testdata.WTNS);
    defer wtns.deinit(allocator);

    const nVars = zkey.header.nVars;
    const fr_bytes = @sizeOf(field.FrElement);

    // Parse G1 points from zkey section 5 (same as CPU prover)
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

    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();

    const gpu_windows = try prover.msmG1_v5(points_a_bytes, sorted);
    defer allocator.free(gpu_windows);
    const gpu_pi_a = metal.accumulateG1(gpu_windows);

    if (!curve.g1_eq(cpu_pi_a, gpu_pi_a)) {
        std.debug.print("Metal G1 MSM mismatch:\n", .{});
    }
    try std.testing.expect(curve.g1_eq(cpu_pi_a, gpu_pi_a));
}

test "TDD: Metal msmG1_v5 pib1 matches CPU msm_g1_pippenger" {
    if (@import("builtin").os.tag != .macos) return;

    const allocator = std.testing.allocator;

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

    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();

    const gpu_windows = try prover.msmG1_v5(points_b1_bytes, sorted);
    defer allocator.free(gpu_windows);
    const gpu_pib1 = metal.accumulateG1(gpu_windows);

    if (!curve.g1_eq(cpu_pib1, gpu_pib1)) {
        std.debug.print("Metal G1 MSM mismatch for pib1\n", .{});
    }
    try std.testing.expect(curve.g1_eq(cpu_pib1, gpu_pib1));
}

test "TDD: Metal msmG1_v5 points_h matches CPU msm_g1_pippenger" {
    if (@import("builtin").os.tag != .macos) return;

    const allocator = std.testing.allocator;

    var zkey = try cpu.parser.parseZkey(allocator, testdata.ZKEY);
    defer zkey.deinit(allocator);

    const domainSize = zkey.header.domainSize;
    const _n8r = zkey.header.n8r;
    _ = _n8r;

    // Build QAP and calculate H (same as Metal prover)
    const qap = try cpu.qap.buildQap(allocator, testdata.ZKEY, testdata.WTNS);
    defer {
        allocator.free(qap.a);
        allocator.free(qap.b);
        allocator.free(qap.c);
        allocator.free(qap.points_h);
    }

    // QAP result already contains []FrElement - use directly
    const h_coeffs = try cpu.prover.calculateH(allocator, qap.a, qap.b, qap.c, domainSize);
    defer allocator.free(h_coeffs);

    var wtns = try cpu.parser.parseWitness(allocator, testdata.WTNS);
    defer wtns.deinit(allocator);

    // Parse points_h from zkey section 9
    const points_h = try cpu.prover.parseG1Points(allocator, zkey, 9, domainSize);
    defer allocator.free(points_h);

    // CPU reference
    const cpu_pih = try msm.msm_g1_pippenger(allocator, points_h, h_coeffs);

    // GPU version
    const sec9 = zkey.getSection(9).?;
    const points_h_bytes = sec9[0 .. domainSize * 64];
    const h_bytes = std.mem.sliceAsBytes(h_coeffs);

    const sorted_h = try gpu.preprocessSortedWindows(allocator, h_bytes, 8);
    defer sorted_h.deinit(allocator);

    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();

    const gpu_windows = try prover.msmG1_v5(points_h_bytes, sorted_h);
    defer allocator.free(gpu_windows);
    const gpu_pih = metal.accumulateG1(gpu_windows);

    if (!curve.g1_eq(cpu_pih, gpu_pih)) {
        std.debug.print("Metal G1 MSM mismatch for points_h\n", .{});
    }
    try std.testing.expect(curve.g1_eq(cpu_pih, gpu_pih));
}
