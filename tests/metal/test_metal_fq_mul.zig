const std = @import("std");
const gpu = @import("gpu");

// 16_mont = 16 * R mod q (little-endian limbs)
const sixteen_mont = [4]u64{ 0x45520880f6fce4b4, 0x49890849baa989a8, 0x85a9201d818f014a, 0x1f16424e1bb7724f };

// 256_mont = 256 * R mod q (little-endian limbs)
const expected_256_mont = [4]u64{ 0xfbdb0f2afaec667a, 0xad825aed9626b0ff, 0x276f48b709e2a0fc, 0xd791464ef86e357 };

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();

    std.debug.print("=== Metal fq_mul test: 16_mont * 16_mont ===\n", .{});

    const result = try prover.testFqOp("test_fq_mul", sixteen_mont, sixteen_mont);

    std.debug.print("Input a: {x}{x}{x}{x}\n", .{sixteen_mont[3], sixteen_mont[2], sixteen_mont[1], sixteen_mont[0]});
    std.debug.print("Input b: {x}{x}{x}{x}\n", .{sixteen_mont[3], sixteen_mont[2], sixteen_mont[1], sixteen_mont[0]});
    std.debug.print("Result:  {x}{x}{x}{x}\n", .{result[3], result[2], result[1], result[0]});
    std.debug.print("Expected: {x}{x}{x}{x}\n", .{expected_256_mont[3], expected_256_mont[2], expected_256_mont[1], expected_256_mont[0]});

    const match = std.mem.eql(u64, &result, &expected_256_mont);
    if (match) {
        std.debug.print("PASS: Metal fq_mul matches expected!\n", .{});
    } else {
        std.debug.print("FAIL: Metal fq_mul does NOT match expected!\n", .{});
    }
}
