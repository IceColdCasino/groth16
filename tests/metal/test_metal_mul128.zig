const std = @import("std");
const gpu = @import("gpu");

// Test mul128 on Metal: 0xFFFFFFFFFFFFFFFF * 0xFFFFFFFFFFFFFFFF
// Expected: lo=0x0000000000000001, hi=0xFFFFFFFFFFFFFFFE

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();

    std.debug.print("=== Metal mul128 test ===\n", .{});

    const a = [4]u64{ 0xffffffffffffffff, 0, 0, 0 };
    const b = [4]u64{ 0xffffffffffffffff, 0, 0, 0 };
    const expected_lo = 0x0000000000000001;
    const expected_hi = 0xfffffffffffffffe;

    const result = try prover.testFqOp("test_mul128", a, b);

    std.debug.print("a = {x}\n", .{a[0]});
    std.debug.print("b = {x}\n", .{b[0]});
    std.debug.print("result lo = {x}\n", .{result[0]});
    std.debug.print("result hi = {x}\n", .{result[1]});
    std.debug.print("expected lo = {x}\n", .{expected_lo});
    std.debug.print("expected hi = {x}\n", .{expected_hi});

    const lo_ok = result[0] == expected_lo;
    const hi_ok = result[1] == expected_hi;
    if (lo_ok and hi_ok) {
        std.debug.print("PASS: mul128 is correct!\n", .{});
    } else {
        std.debug.print("FAIL: mul128 is broken! lo_ok={}, hi_ok={}\n", .{lo_ok, hi_ok});
    }
}
