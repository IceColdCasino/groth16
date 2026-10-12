const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const testdata = @import("testdata");

// ============================================================================
// Full Proof Serial vs Concurrent Comparison Test
// ============================================================================
// This test runs the complete Metal prover twice with identical inputs:
// 1. Serial G1 then G2 (baseline)
// 2. Concurrent G1 + G2 dispatch
// Then compares the resulting proof components to identify where divergence occurs.

test "serial vs concurrent full proof comparison" {
    if (@import("builtin").os.tag != .macos) return;

    const allocator = std.testing.allocator;

    // Parse inputs
    var zkey = try cpu.parser.parseZkey(allocator, testdata.ZKEY);
    defer zkey.deinit(allocator);
    var wtns = try cpu.parser.parseWitness(allocator, testdata.WTNS);
    defer wtns.deinit(allocator);

    const nVars = zkey.header.nVars;
    const n_public = zkey.header.nPublic;
    const fr_bytes = @sizeOf(cpu.field.FrElement);

    // Build QAP (same for both runs)
    const qap_result = try cpu.qap.buildQap(allocator, testdata.ZKEY, testdata.WTNS);
    defer {
        allocator.free(qap_result.a);
        allocator.free(qap_result.b);
        allocator.free(qap_result.c);
        allocator.free(qap_result.points_h);
    }

    // Extract points (same for both) — use actual section sizes
    const sec5 = zkey.getSection(5).?;
    const points_a = sec5;
    const sec6 = zkey.getSection(6).?;
    const points_b1 = sec6;
    const sec7 = zkey.getSection(7).?;
    const points_b2 = sec7;
    const sec8 = zkey.getSection(8); // May not exist for all circuits
    const points_c = if (sec8) |s| s else &[_]u8{};
    const sec9 = zkey.getSection(9).?;
    const points_h = sec9;

    // Extract witness scalars
    const witness_bytes = wtns.data[0 .. nVars * fr_bytes];

    // Preprocess sorted windows (same for all MSMs)
    const sorted_full = try gpu.preprocessSortedWindows(allocator, witness_bytes, 8);
    defer sorted_full.deinit(allocator);

    var sorted_private: ?gpu.SortedWindows = null;
    defer if (sorted_private) |s| s.deinit(allocator);

    const n_private = nVars - n_public - 1;
    if (n_private > 0) {
        const private_scalars = witness_bytes[(n_public + 1) * fr_bytes .. nVars * fr_bytes];
        sorted_private = try gpu.preprocessSortedWindows(allocator, private_scalars, 8);
    }

    // Random scalars for proof randomization
    const r_scalar = cpu.random.fr_random();
    const s_scalar = cpu.random.fr_random();

    // Initialize Metal prover
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();

    // =========================================================================
    // Run 1: SERIAL - G1 then G2
    // =========================================================================
    std.debug.print("\n=== Serial Proof Run ===\n", .{});

    // G1 MSMs (pi_a, pib1, pi_c)
    var g1_jobs: [3]gpu.metal.MetalProver.MSMJob = undefined;
    g1_jobs[0] = .{ .points = points_a, .sorted = sorted_full };
    g1_jobs[1] = .{ .points = points_b1, .sorted = sorted_full };
    var g1_jobs_slice: []gpu.metal.MetalProver.MSMJob = g1_jobs[0..2];
    if (n_private > 0 and sorted_private != null and points_c.len > 0) {
        g1_jobs[2] = .{ .points = points_c, .sorted = sorted_private.? };
        g1_jobs_slice = g1_jobs[0..3];
    }

    const g1_serial = try prover.msmG1_v5_batch(g1_jobs_slice, prover.command_queue_2);
    defer {
        for (g1_serial) |res| allocator.free(res);
        allocator.free(g1_serial);
    }
    const pi_a_serial = gpu.metal.accumulateG1(g1_serial[0]);
    const pib1_serial = gpu.metal.accumulateG1(g1_serial[1]);
    const pi_c_serial = if (g1_serial.len > 2) gpu.metal.accumulateG1(g1_serial[2]) else cpu.curve.g1_zero();

    // G2 MSM (pi_b) - serial after G1
    const n_points_b2 = points_b2.len / @sizeOf(gpu.G2PointAffine);
    const fq_size = @sizeOf([4]u64);
    const fq2_size = @sizeOf([8]u64);
    const coord_size = n_points_b2 * fq_size;

    const x_c0 = try allocator.alloc(u8, coord_size);
    defer allocator.free(x_c0);
    const x_c1 = try allocator.alloc(u8, coord_size);
    defer allocator.free(x_c1);
    const y_c0 = try allocator.alloc(u8, coord_size);
    defer allocator.free(y_c0);
    const y_c1 = try allocator.alloc(u8, coord_size);
    defer allocator.free(y_c1);
    const neg_y_c0 = try allocator.alloc(u8, coord_size);
    defer allocator.free(neg_y_c0);
    const neg_y_c1 = try allocator.alloc(u8, coord_size);
    defer allocator.free(neg_y_c1);

    const points_b2_typed = std.mem.bytesAsSlice(cpu.curve.G2PointAffine, points_b2);
    for (0..n_points_b2) |i| {
        const src = i * @sizeOf(gpu.G2PointAffine);
        const dst = i * fq_size;
        @memcpy(x_c0[dst..][0..fq_size], points_b2[src + 0 * fq2_size ..][0..fq_size]);
        @memcpy(x_c1[dst..][0..fq_size], points_b2[src + 0 * fq2_size + fq_size ..][0..fq_size]);
        @memcpy(y_c0[dst..][0..fq_size], points_b2[src + 1 * fq2_size ..][0..fq_size]);
        @memcpy(y_c1[dst..][0..fq_size], points_b2[src + 1 * fq2_size + fq_size ..][0..fq_size]);
        const neg_y = cpu.field.fq2_neg(points_b2_typed[i].y);
        @memcpy(neg_y_c0[dst..][0..fq_size], std.mem.asBytes(&neg_y.a));
        @memcpy(neg_y_c1[dst..][0..fq_size], std.mem.asBytes(&neg_y.b));
    }

    const g2_config = gpu.MSMConfig{
        .n_points = @intCast(nVars),
        .n_windows = 32,
        .window_size = 8,
        .n_buckets = 256,
    };

    const g2_serial = try prover.msmG2_v6_soA(x_c0, x_c1, y_c0, y_c1, neg_y_c0, neg_y_c1, sorted_full, g2_config, prover.command_queue_2);
    defer allocator.free(g2_serial);
    const pi_b_serial = gpu.metal.accumulateG2(g2_serial);

    // H-MSM (pih) - serial
    const c_fr = std.mem.bytesAsSlice(cpu.field.FrElement, qap_result.c);
    const h_serial = try allocator.alloc(cpu.field.FrElement, c_fr.len);
    defer allocator.free(h_serial);
    @memcpy(h_serial, c_fr);
    cpu.fft.fft_fr(h_serial, @intCast(h_serial.len));
    const sorted_h = try gpu.preprocessSortedWindows(allocator, std.mem.sliceAsBytes(h_serial), 8);
    defer sorted_h.deinit(allocator);
    const h_jobs = &[_]gpu.metal.MetalProver.MSMJob{
        .{ .points = points_h, .sorted = sorted_h },
    };
    const pih_results_serial = try prover.msmG1_v5_batch(h_jobs, prover.command_queue_2);
    defer {
        for (pih_results_serial) |res| allocator.free(res);
        allocator.free(pih_results_serial);
    }
    const pih_serial = gpu.metal.accumulateG1(pih_results_serial[0]);

    std.debug.print("Serial: pi_a ok, pib1 ok, pi_b ok, pi_c ok, pih ok\n", .{});

    // =========================================================================
    // Run 2: CONCURRENT - G1 + G2 dispatched simultaneously
    // =========================================================================
    std.debug.print("\n=== Concurrent Proof Run ===\n", .{});

    // Dispatch G1 async on queue_2
    var g1_handle = try prover.msmG1_v5_batch_async(g1_jobs_slice, prover.command_queue_2);

    // Dispatch G2 async on queue_3
    var g2_handle = try prover.msmG2_v6_soA_async(x_c0, x_c1, y_c0, y_c1, neg_y_c0, neg_y_c1, sorted_full, g2_config, prover.command_queue_3);

    // H-MSM on queue_2 (serial with respect to G1+G2, but in background thread)
    const sorted_h_concurrent = try gpu.preprocessSortedWindows(allocator, std.mem.sliceAsBytes(h_serial), 8);
    defer sorted_h_concurrent.deinit(allocator);
    const h_jobs_concurrent = &[_]gpu.metal.MetalProver.MSMJob{
        .{ .points = points_h, .sorted = sorted_h_concurrent },
    };
    const pih_results_concurrent = try prover.msmG1_v5_batch(h_jobs_concurrent, prover.command_queue_2);
    defer {
        for (pih_results_concurrent) |res| allocator.free(res);
        allocator.free(pih_results_concurrent);
    }
    const pih_concurrent = gpu.metal.accumulateG1(pih_results_concurrent[0]);

    // Wait for G1 and G2 to finish
    const g1_concurrent = try g1_handle.waitAndDownload();
    defer {
        for (g1_concurrent) |res| allocator.free(res);
        allocator.free(g1_concurrent);
        g1_handle.deinit();
    }
    const pi_a_concurrent = gpu.metal.accumulateG1(g1_concurrent[0]);
    const pib1_concurrent = gpu.metal.accumulateG1(g1_concurrent[1]);
    const pi_c_concurrent = if (g1_concurrent.len > 2) gpu.metal.accumulateG1(g1_concurrent[2]) else cpu.curve.g1_zero();

    const g2_concurrent = try g2_handle.waitAndDownload();
    defer allocator.free(g2_concurrent);
    g2_handle.deinit();
    const pi_b_concurrent = gpu.metal.accumulateG2(g2_concurrent);

    std.debug.print("Concurrent: pi_a ok, pib1 ok, pi_b ok, pi_c ok, pih ok\n", .{});

    // =========================================================================
    // Compare all proof components
    // =========================================================================
    std.debug.print("\n=== Comparison ===\n", .{});

    const pi_a_match = cpu.curve.g1_eq(pi_a_serial, pi_a_concurrent);
    const pib1_match = cpu.curve.g1_eq(pib1_serial, pib1_concurrent);
    const pi_c_match = cpu.curve.g1_eq(pi_c_serial, pi_c_concurrent);
    const pih_match = cpu.curve.g1_eq(pih_serial, pih_concurrent);
    const pi_b_match = cpu.curve.g2_eq(pi_b_serial, pi_b_concurrent);

    if (!pi_a_match) std.debug.print("*** MISMATCH: pi_a ***\n", .{});
    if (!pib1_match) std.debug.print("*** MISMATCH: pib1 ***\n", .{});
    if (!pi_c_match) std.debug.print("*** MISMATCH: pi_c ***\n", .{});
    if (!pih_match) std.debug.print("*** MISMATCH: pih ***\n", .{});
    if (!pi_b_match) std.debug.print("*** MISMATCH: pi_b ***\n", .{});

    // Now assemble proofs and compare final JSON
    var asm_serial = try cpu.assembler.assembleProof(allocator, testdata.ZKEY, testdata.WTNS, pi_a_serial, pi_b_serial, pib1_serial, pi_c_serial, pih_serial, r_scalar, s_scalar);
    defer asm_serial.deinit(allocator);

    var asm_concurrent = try cpu.assembler.assembleProof(allocator, testdata.ZKEY, testdata.WTNS, pi_a_concurrent, pi_b_concurrent, pib1_concurrent, pi_c_concurrent, pih_concurrent, r_scalar, s_scalar);
    defer asm_concurrent.deinit(allocator);

    const proof_match = std.mem.eql(u8, asm_serial.proof_json, asm_concurrent.proof_json);
    if (!proof_match) {
        std.debug.print("\n*** MISMATCH: Final proof JSON differs ***\n", .{});
        // Find first differing byte
        const min_len = @min(asm_serial.proof_json.len, asm_concurrent.proof_json.len);
        for (0..min_len) |i| {
            if (asm_serial.proof_json[i] != asm_concurrent.proof_json[i]) {
                std.debug.print("First difference at byte {d}: serial='{c}' vs concurrent='{c}'\n", .{ i, asm_serial.proof_json[i], asm_concurrent.proof_json[i] });
                // Show context
                const start = if (i > 20) i - 20 else 0;
                const end = @min(i + 20, min_len);
                std.debug.print("Serial context:    '{s}'\n", .{asm_serial.proof_json[start..end]});
                std.debug.print("Concurrent context: '{s}'\n", .{asm_concurrent.proof_json[start..end]});
                break;
            }
        }
    }

    // Also compare public signals
    const public_match = std.mem.eql(u8, asm_serial.public_json, asm_concurrent.public_json);
    if (!public_match) {
        std.debug.print("\n*** MISMATCH: Public signals differ ***\n", .{});
    }

    try std.testing.expect(pi_a_match);
    try std.testing.expect(pib1_match);
    try std.testing.expect(pi_c_match);
    try std.testing.expect(pih_match);
    try std.testing.expect(pi_b_match);
    try std.testing.expect(proof_match);
    try std.testing.expect(public_match);

    std.debug.print("\n=== PASS: Serial and concurrent produce identical proofs ===\n", .{});
}
