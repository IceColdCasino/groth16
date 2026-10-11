const std = @import("std");
const gpu = @import("gpu");

// Test add128 with overflow: 
// a = {lo: 0xFFFFFFFFFFFFFFFE, hi: 0xFFFFFFFFFFFFFFFF}
// b = {lo: 0, hi: 0xFFFFFFFFFFFFFFFF}
// Expected: lo = 0xFFFFFFFFFFFFFFFE, hi = 0xFFFFFFFFFFFFFFFE (but with carry to next bit!)
// 
// In 128-bit: a = 0xFFFFFFFFFFFFFFFF_FFFFFFFFFFFFFFFE
//             b = 0xFFFFFFFFFFFFFFFF_0000000000000000
//         a+b = 0x1FFFFFFFFFFFFFFFF_FFFFFFFFFFFFFFFE (129 bits)
// 
// But add128 returns 128 bits, so hi = 0xFFFFFFFFFFFFFFFE (wrong! should account for overflow)

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();

    std.debug.print("=== Metal add128 overflow test ===\n", .{});
    std.debug.print("Testing if Metal supports __uint128_t...\n", .{});

    // We can't directly test add128 from Zig, but we can infer from fq_mul behavior.
    // Let's test a simpler case: fq_add with values that overflow 64-bit limbs.
    
    // a = q - 1 (max value before reduction)
    // b = 1
    // Expected: a + b = q, which reduces to 0
    
    const q_minus_1 = [4]u64{ 0x3c208c16d87cfd46, 0x97816a916871ca8d, 0xb85045b68181585d, 0x30644e72e131a029 };
    const one = [4]u64{ 1, 0, 0, 0 };
    const expected_zero = [4]u64{ 0, 0, 0, 0 };

    const result = try prover.testFqOp("test_fq_add", q_minus_1, one);

    std.debug.print("q-1 + 1 = {x}{x}{x}{x}\n", .{result[3], result[2], result[1], result[0]});
    std.debug.print("Expected: 0000000000000000000000000000000000000000000000000000000000000000\n", .{});

    const match = std.mem.eql(u64, &result, &expected_zero);
    if (match) {
        std.debug.print("PASS: fq_add handles overflow correctly!\n", .{});
    } else {
        std.debug.print("FAIL: fq_add overflow handling is broken!\n", .{});
    }
}
