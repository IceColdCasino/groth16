const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const testdata = @import("rapidsnark_testdata");

// ============================================================================
// TDD calculateH Tests — compare Metal calculateHGpu against CPU calculateH
// ============================================================================

test "TDD: calculateHGpu matches CPU calculateH" {
    const allocator = std.testing.allocator;

    const qap = try cpu.qap.buildQap(allocator, testdata.ZKEY, testdata.WTNS);
    defer {
        allocator.free(qap.a);
        allocator.free(qap.b);
        allocator.free(qap.c);
        allocator.free(qap.points_h);
    }

    const domainSize = qap.domain_size;
    const n8r: u32 = 32;

    // CPU reference - qap.a/b/c are already []FrElement
    const h_cpu = try cpu.prover.calculateH(allocator, qap.a, qap.b, qap.c, domainSize);
    defer allocator.free(h_cpu);

    // GPU version (uses GPU FFT for large domains, CPU fallback for small)
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();
    const h_gpu = try prover.calculateHGpu(allocator, qap.a, qap.b, qap.c, domainSize, n8r);
    defer allocator.free(h_gpu);

    try std.testing.expectEqual(h_cpu.len, h_gpu.len);
    for (h_cpu, h_gpu, 0..) |c_elem, g_elem, i| {
        if (!field.fr_eq(c_elem, g_elem)) {
            std.debug.print("H mismatch at [{d}]\n", .{i});
            break;
        }
    }
    for (h_cpu, h_gpu) |c_elem, g_elem| {
        try std.testing.expect(field.fr_eq(c_elem, g_elem));
    }
}
