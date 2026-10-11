const std = @import("std");
const gpu = @import("gpu");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();

    std.debug.print("=== Metal mul128 direct test ===\n", .{});

    const a = [4]u64{ 0x45520880f6fce4b4, 0, 0, 0 };
    const b = [4]u64{ 0x45520880f6fce4b4, 0, 0, 0 };

    const result = try prover.testFqOp("test_mul128", a, b);

    std.debug.print("a = {x}\n", .{a[0]});
    std.debug.print("b = {x}\n", .{b[0]});
    std.debug.print("result lo = {x}\n", .{result[0]});
    std.debug.print("result hi = {x}\n", .{result[1]});

    const expected_lo: u64 = 0x44caf55cfeb11e90;
    const expected_hi: u64 = 0x12c552def80addb3;

    const lo_ok = result[0] == expected_lo;
    const hi_ok = result[1] == expected_hi;
    if (lo_ok and hi_ok) {
        std.debug.print("PASS: mul128 is correct!\n", .{});
    } else {
        std.debug.print("FAIL: mul128 is broken! lo_ok={}, hi_ok={}\n", .{lo_ok, hi_ok});
    }
}
