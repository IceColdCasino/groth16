const std = @import("std");

// Import the CPU module to pull in all its tests.
const cpu = @import("cpu");
const testdata = @import("testdata");

const c = @import("c");

test "print cwd" {
    var buf: [1024]u8 = undefined;
    const cwd = c.getcwd(&buf, 1024);
    std.debug.print("CWD: {s}\n", .{cwd});
    // Write testdata to temp file for fopen check
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "circuit_final.zkey", .data = testdata.ZKEY });
    const file = c.fopen("circuit_final.zkey", "rb");
    if (file != null) {
        std.debug.print("FILE OPENED OK\n", .{});
        _ = c.fclose(file);
    } else {
        std.debug.print("FILE OPEN FAILED\n", .{});
    }
}

// Force inclusion of tests from all CPU submodules.
test {
    _ = cpu;
    _ = cpu.prover;
    _ = cpu.verifier;
    _ = cpu.parser;
    _ = cpu.field;
    _ = cpu.curve;
    _ = cpu.fft;
    _ = cpu.msm;
    _ = cpu.json;
    _ = cpu.random;
    _ = cpu.pairing;
    _ = cpu.qap;
    _ = cpu.assembler;
    _ = @import("field/tdd_field.zig");
    _ = @import("curve/tdd_g1.zig");
    _ = @import("curve/tdd_g2.zig");
    _ = @import("msm/tdd_msm_g1.zig");
    _ = @import("msm/tdd_msm_g2.zig");
    _ = @import("fft/tdd_fft.zig");
    _ = @import("fft/tdd_fft_tile.zig");
    _ = @import("curve/check_sizes.zig");
    _ = @import("metal/tdd_metal_calculateh.zig");
    _ = @import("metal/tdd_metal_msm_g1.zig");
    _ = @import("metal/tdd_metal_msm_g2.zig");
    _ = @import("metal/tdd_metal.zig");
    _ = @import("vulkan/tdd_vulkan_msm_g1.zig");
    _ = @import("vulkan/tdd_vulkan_msm_g2.zig");
    _ = @import("msm/tdd_randomized.zig");
    _ = @import("msm/tdd_concurrent_msm.zig");
    _ = @import("prove/tdd_proof_serial_vs_concurrent.zig");
}



test "print medium circuit info" {
    // The medium zkey is a local benchmark fixture and is not in the repo.
    if (std.c.access("benchmarks/circuits/medium/circuit_final.zkey", 0) != 0) return error.SkipZigTest;

    const zkey_data = try cpu.readFileToBuffer("benchmarks/circuits/medium/circuit_final.zkey", std.testing.allocator);
    defer std.testing.allocator.free(zkey_data);
    var zkey = try cpu.parser.parseZkey(std.testing.allocator, zkey_data);
    defer zkey.deinit(std.testing.allocator);
    
    std.debug.print("Medium circuit: domainSize={d}, nVars={d}, nPublic={d}\n", .{
        zkey.header.domainSize,
        zkey.header.nVars,
        zkey.header.nPublic,
    });
}

fn checkIsRootOfUnity(omega: cpu.field.FrElement, n: u32) !void {
    var r = omega;
    var i = n;
    while (i > 1) {
        r = cpu.field.fr_sqr(r);
        i >>= 1;
    }
    try std.testing.expect(cpu.field.fr_eq(r, cpu.field.fr_one()));
}

test "omega values are proper roots of unity and chain correctly" {
    // Verify squaring chain: omega_{2n}^2 == omega_n
    try std.testing.expect(cpu.field.fr_eq(
        cpu.field.fr_mul(cpu.fft.FR_OMEGA_4096, cpu.fft.FR_OMEGA_4096),
        cpu.fft.FR_OMEGA_2048));
    try std.testing.expect(cpu.field.fr_eq(
        cpu.field.fr_mul(cpu.fft.FR_OMEGA_8192, cpu.fft.FR_OMEGA_8192),
        cpu.fft.FR_OMEGA_4096));
    try std.testing.expect(cpu.field.fr_eq(
        cpu.field.fr_mul(cpu.fft.FR_OMEGA_16384, cpu.fft.FR_OMEGA_16384),
        cpu.fft.FR_OMEGA_8192));
    try std.testing.expect(cpu.field.fr_eq(
        cpu.field.fr_mul(cpu.fft.FR_OMEGA_32768, cpu.fft.FR_OMEGA_32768),
        cpu.fft.FR_OMEGA_16384));

    // Verify each is a primitive root: omega^n == 1
    try checkIsRootOfUnity(cpu.fft.FR_OMEGA_2048, 2048);
    try checkIsRootOfUnity(cpu.fft.FR_OMEGA_4096, 4096);
    try checkIsRootOfUnity(cpu.fft.FR_OMEGA_8192, 8192);
    try checkIsRootOfUnity(cpu.fft.FR_OMEGA_16384, 16384);
    try checkIsRootOfUnity(cpu.fft.FR_OMEGA_32768, 32768);
}
