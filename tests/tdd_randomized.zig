const std = @import("std");
const cpu = @import("cpu");
const testdata = @import("rapidsnark_testdata");

// ============================================================================
// Randomized Proof Tests (Groth16 r, s randomization)
// ============================================================================

test "cpu prover produces valid proof with random r, s" {
    const allocator = std.testing.allocator;

    // Generate random r, s scalars
    const r = cpu.random.fr_random();
    const s = cpu.random.fr_random();
    try std.testing.expect(!cpu.field.fr_is_zero(r));
    try std.testing.expect(!cpu.field.fr_is_zero(s));

    // Run CPU prover with explicit randomization
    var our_result = try cpu.prover.prove(allocator, testdata.ZKEY, testdata.WTNS, .{
        .r = r,
        .s = s,
    });
    defer our_result.deinit(allocator);

    // Verify the proof
    const verified = try cpu.verifier.verify(allocator, testdata.VK, our_result.proof_json, our_result.public_json);
    if (!verified) {
        std.debug.print("\n=== CPU Randomized Proof Verification FAILED ===\n", .{});
    }
    try std.testing.expect(verified);
}

test "metal prover produces valid proof with random r, s" {
    if (@import("builtin").os.tag != .macos) return;

    const allocator = std.testing.allocator;
    const gpu = @import("gpu");

    // 1. Generate random r, s
    const r = cpu.random.fr_random();
    const s = cpu.random.fr_random();
    try std.testing.expect(!cpu.field.fr_is_zero(r));
    try std.testing.expect(!cpu.field.fr_is_zero(s));

    // 2. Write temp files for Metal prover
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "circuit_final.zkey", .data = testdata.ZKEY });
    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "witness.wtns", .data = testdata.WTNS });

    const zkey_path_z = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "circuit_final.zkey", allocator);
    defer allocator.free(zkey_path_z);
    const zkey_path = std.mem.sliceTo(zkey_path_z, 0);
    const wtns_path_z = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "witness.wtns", allocator);
    defer allocator.free(wtns_path_z);
    const wtns_path = std.mem.sliceTo(wtns_path_z, 0);

    // 3. Call Metal prover with explicit randomization
    var metal_result = try gpu.metal.proveOnGpu(zkey_path, wtns_path, .{
        .r = r,
        .s = s,
    });
    defer metal_result.deinit();

    // 4. Verify the proof
    const metal_verified = try cpu.verifier.verify(allocator, testdata.VK, metal_result.proof, metal_result.public_signals);
    if (!metal_verified) {
        std.debug.print("\n=== Metal Randomized Proof Verification FAILED ===\n", .{});
    }
    try std.testing.expect(metal_verified);
}

test "cpu and metal provers match with same random r, s" {
    if (@import("builtin").os.tag != .macos) return;

    const allocator = std.testing.allocator;
    const gpu = @import("gpu");

    // 1. Generate random r, s (same for both provers)
    const r = cpu.random.fr_random();
    const s = cpu.random.fr_random();
    try std.testing.expect(!cpu.field.fr_is_zero(r));
    try std.testing.expect(!cpu.field.fr_is_zero(s));

    // 2. Run CPU prover with explicit randomization
    var cpu_result = try cpu.prover.prove(allocator, testdata.ZKEY, testdata.WTNS, .{
        .r = r,
        .s = s,
    });
    defer cpu_result.deinit(allocator);

    // 3. Write temp files for Metal prover
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "circuit_final.zkey", .data = testdata.ZKEY });
    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "witness.wtns", .data = testdata.WTNS });

    const zkey_path_z = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "circuit_final.zkey", allocator);
    defer allocator.free(zkey_path_z);
    const zkey_path = std.mem.sliceTo(zkey_path_z, 0);
    const wtns_path_z = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "witness.wtns", allocator);
    defer allocator.free(wtns_path_z);
    const wtns_path = std.mem.sliceTo(wtns_path_z, 0);

    // 4. Run Metal prover with the SAME randomization
    var metal_result = try gpu.metal.proveOnGpu(zkey_path, wtns_path, .{
        .r = r,
        .s = s,
    });
    defer metal_result.deinit();

    // 5. Parse both proofs and compare pi_a, pi_b, pi_c
    const cpu_proof = try cpu.verifier.parseProof(allocator, cpu_result.proof_json);
    const metal_proof = try cpu.verifier.parseProof(allocator, metal_result.proof);

    try std.testing.expect(cpu.curve.g1_eq(cpu_proof.pi_a, metal_proof.pi_a));
    try std.testing.expect(cpu.curve.g2_eq(cpu_proof.pi_b, metal_proof.pi_b));
    try std.testing.expect(cpu.curve.g1_eq(cpu_proof.pi_c, metal_proof.pi_c));
}
