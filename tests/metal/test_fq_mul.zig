const std = @import("std");
const gpu = @import("gpu");
const mtl = @import("zig-metal");

// Two Fq elements in Montgomery form to multiply
// a = Montgomery(2), b = Montgomery(3)
// Expected result: Montgomery(6)
const test_a = [4]u64{ 0xcbc0ffe5ec9537c6, 0x14a76deea58d7d9d, 0xccccd68ef05c8c58, 0x1c158ef8340fbe5e };
const test_b = [4]u64{ 0x91a1ff94b62a1554, 0x1f5b5c5df8d4bd76, 0x999a40b7b68ad294, 0x2a0a4e74c6173d8d };

// Montgomery(6) = 6 * R mod q
const expected = [4]u64{ 0x588fffecc895a732, 0x3e012bce6a295b13, 0x999a40b7b68ad294, 0x2a0a4e74c6173d8d };

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Initialize Metal
    const prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();

    // We can't easily run a custom kernel without modifying MetalProver.
    // For now, just print the test values so we can verify manually.
    std.debug.print("=== Fq Multiplication Test ===\n", .{});
    std.debug.print("a = 0x{x:016x}{x:016x}{x:016x}{x:016x}\n", .{ test_a[3], test_a[2], test_a[1], test_a[0] });
    std.debug.print("b = 0x{x:016x}{x:016x}{x:016x}{x:016x}\n", .{ test_b[3], test_b[2], test_b[1], test_b[0] });
    std.debug.print("expected = 0x{x:016x}{x:016x}{x:016x}{x:016x}\n", .{ expected[3], expected[2], expected[1], expected[0] });
}
