const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;

pub fn main() !void {
    const n: u32 = 1024;
    
    std.debug.print("=== Twiddle comparison for n={d} ===\n", .{n});
    
    // Check a few twiddle values
    for ([_]u32{ 0, 1, 256, 512, 768 }) |k| {
        const fwd = fft.getTwiddle(n, k);
        const inv = fft.getTwiddleInv(n, k);
        const inv_expected = field.fr_inv(fwd);
        const match = field.fr_eq(inv, inv_expected);
        std.debug.print("k={d}: fwd={x} inv={x} inv_expected={x} match={}\n", .{k, fwd[0], inv[0], inv_expected[0], match});
    }
    
    // Verify that inv twiddles are actually different from fwd twiddles
    var all_same = true;
    for (0..n / 2) |i| {
        const fwd = fft.getTwiddle(n, @intCast(i));
        const inv = fft.getTwiddleInv(n, @intCast(i));
        if (!field.fr_eq(fwd, inv)) {
            all_same = false;
            std.debug.print("First difference at i={d}: fwd={x} inv={x}\n", .{i, fwd[0], inv[0]});
            break;
        }
    }
    if (all_same) {
        std.debug.print("WARNING: all twiddles are the same!\n", .{});
    } else {
        std.debug.print("Forward and inverse twiddles differ (as expected)\n", .{});
    }
    
    // Verify IFFT roundtrip on CPU
    var prng = std.Random.DefaultPrng.init(42);
    var data = try std.heap.c_allocator.alloc(field.FrElement, n);
    defer std.heap.c_allocator.free(data);
    for (0..n) |i| {
        data[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
    }
    const original = try std.heap.c_allocator.dupe(field.FrElement, data);
    defer std.heap.c_allocator.free(original);
    
    data[0] = data[0];
    fft.fft_fr(data, n);
    fft.ifft_fr(data, n);
    
    var match_count: usize = 0;
    for (0..n) |i| {
        if (field.fr_eq(original[i], data[i])) match_count += 1;
    }
    std.debug.print("CPU FFT+IFFT roundtrip: {d}/{d} match\n", .{match_count, n});
}
