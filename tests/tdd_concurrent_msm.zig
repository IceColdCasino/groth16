const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const metal = gpu.metal;
const field = cpu.field;
const curve = cpu.curve;
const msm = cpu.msm;
const testdata = @import("rapidsnark_testdata");

// ============================================================================
// Serial vs Concurrent G1+G2 MSM Test
// ============================================================================
// This test isolates whether concurrent G1+G2 dispatch produces different
// raw MSM results than serial dispatch, using identical inputs.

test "serial vs concurrent G1+G2 MSM produces identical results" {
    if (@import("builtin").os.tag != .macos) return;

    const allocator = std.testing.allocator;

    // Load test circuit data
    var zkey = try cpu.parser.parseZkey(allocator, testdata.ZKEY);
    defer zkey.deinit(allocator);
    var wtns = try cpu.parser.parseWitness(allocator, testdata.WTNS);
    defer wtns.deinit(allocator);

    const nVars = zkey.header.nVars;
    const fr_bytes = @sizeOf(field.FrElement);

    // Parse G1 points_a (sec5) and G2 points_b2 (sec7)
    const sec5 = zkey.getSection(5).?;
    const points_a_bytes = sec5[0 .. nVars * 64];
    const sec7 = zkey.getSection(7).?;
    const points_b2_bytes = sec7[0 .. nVars * 128];
    const witness_bytes = wtns.data[0 .. nVars * fr_bytes];

    // Preprocess sorted windows (same for all runs)
    const sorted = try gpu.preprocessSortedWindows(allocator, witness_bytes, 8);
    defer sorted.deinit(allocator);

    // Initialize Metal prover with multiple queues
    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();

    // =========================================================================
    // Run 1: Serial G1 then G2 (baseline)
    // =========================================================================
    std.debug.print("\n=== Serial Run ===\n", .{});

    // Serial G1 MSM
    const g1_serial_windows = try prover.msmG1_v5(points_a_bytes, sorted);
    defer allocator.free(g1_serial_windows);
    const g1_serial_result = metal.accumulateG1(g1_serial_windows);
    std.debug.print("G1 serial result: ok\n", .{});

    // Prepare G2 SoA buffers
    const n_points = points_b2_bytes.len / @sizeOf(gpu.G2PointAffine);
    const fq_size = @sizeOf([4]u64); // 32 bytes per FqElement
    const fq2_size = @sizeOf([8]u64); // 64 bytes per Fq2Element
    const coord_size = n_points * fq_size;

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

    const points_b2_typed = std.mem.bytesAsSlice(cpu.curve.G2PointAffine, points_b2_bytes);
    for (0..n_points) |i| {
        const src = i * @sizeOf(gpu.G2PointAffine);
        const dst = i * fq_size;
        @memcpy(x_c0[dst..][0..fq_size], points_b2_bytes[src + 0 * fq2_size ..][0..fq_size]);
        @memcpy(x_c1[dst..][0..fq_size], points_b2_bytes[src + 0 * fq2_size + fq_size ..][0..fq_size]);
        @memcpy(y_c0[dst..][0..fq_size], points_b2_bytes[src + 1 * fq2_size ..][0..fq_size]);
        @memcpy(y_c1[dst..][0..fq_size], points_b2_bytes[src + 1 * fq2_size + fq_size ..][0..fq_size]);
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

    // Serial G2 MSM on queue_2
    const g2_serial_windows = try prover.msmG2_v6_soA(
        x_c0, x_c1, y_c0, y_c1, neg_y_c0, neg_y_c1,
        sorted, g2_config, prover.command_queue_2,
    );
    defer allocator.free(g2_serial_windows);
    const g2_serial_result = metal.accumulateG2(g2_serial_windows);
    std.debug.print("G2 serial result: ok\n", .{});

    // =========================================================================
    // Run 2: Concurrent G1 + G2 (both dispatched, then both waited)
    // =========================================================================
    std.debug.print("\n=== Concurrent Run ===\n", .{});

    // Dispatch G1 async on queue_2
    const g1_job = metal.MetalProver.MSMJob{
        .points = points_a_bytes,
        .sorted = sorted,
    };
    const g1_jobs = &[_]metal.MetalProver.MSMJob{g1_job};
    var g1_handle = try prover.msmG1_v5_batch_async(g1_jobs, prover.command_queue_2);

    // Dispatch G2 async on queue_3
    var g2_handle = try prover.msmG2_v6_soA_async(
        x_c0, x_c1, y_c0, y_c1, neg_y_c0, neg_y_c1,
        sorted, g2_config, prover.command_queue_3,
    );

    // Wait for both to complete
    const g1_concurrent_windows = try g1_handle.waitAndDownload();
    defer {
        for (g1_concurrent_windows) |r| allocator.free(r);
        allocator.free(g1_concurrent_windows);
        g1_handle.deinit();
    }
    const g1_concurrent_result = metal.accumulateG1(g1_concurrent_windows[0]);
    std.debug.print("G1 concurrent result: ok\n", .{});

    const g2_concurrent_windows = try g2_handle.waitAndDownload();
    defer allocator.free(g2_concurrent_windows);
    g2_handle.deinit();
    const g2_concurrent_result = metal.accumulateG2(g2_concurrent_windows);
    std.debug.print("G2 concurrent result: ok\n", .{});

    // =========================================================================
    // Compare results
    // =========================================================================
    const g1_match = curve.g1_eq(g1_serial_result, g1_concurrent_result);
    const g2_match = curve.g2_eq(g2_serial_result, g2_concurrent_result);

    if (!g1_match) {
        std.debug.print("\n*** MISMATCH: G1 serial != G1 concurrent ***\n", .{});
    }
    if (!g2_match) {
        std.debug.print("\n*** MISMATCH: G2 serial != G2 concurrent ***\n", .{});
    }

    try std.testing.expect(g1_match);
    try std.testing.expect(g2_match);

    std.debug.print("\n=== PASS: Serial and concurrent MSM produce identical results ===\n", .{});
}
