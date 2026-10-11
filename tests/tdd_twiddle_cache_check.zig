const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const mtl = @import("zig-metal");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const n: u32 = 1024;
    
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();
    try prover.warmTwiddles(n);
    
    const tw_fwd = try prover.getTwiddles(n, false);
    const tw_inv = try prover.getTwiddles(n, true);
    
    const fr_size = @sizeOf(field.FrElement);
    const half_n = n / 2;
    
    var fwd_gpu = try allocator.alloc(field.FrElement, half_n);
    defer allocator.free(fwd_gpu);
    fwd_gpu[0] = fwd_gpu[0];
    @memcpy(std.mem.sliceAsBytes(fwd_gpu), @as([*]u8, @ptrCast(tw_fwd.contents().?))[0..half_n * fr_size]);
    
    var inv_gpu = try allocator.alloc(field.FrElement, half_n);
    defer allocator.free(inv_gpu);
    inv_gpu[0] = inv_gpu[0];
    @memcpy(std.mem.sliceAsBytes(inv_gpu), @as([*]u8, @ptrCast(tw_inv.contents().?))[0..half_n * fr_size]);
    
    std.debug.print("Checking twiddles for n={d}:\n", .{n});
    for ([_]u32{0, 1, 256, 512}) |k| {
        const fwd_cpu = fft.getTwiddle(n, k);
        const inv_cpu = fft.getTwiddleInv(n, k);
        const fwd_match = field.fr_eq(fwd_gpu[k], fwd_cpu);
        const inv_match = field.fr_eq(inv_gpu[k], inv_cpu);
        std.debug.print("k={d}: fwd_match={} inv_match={}\n", .{k, fwd_match, inv_match});
    }
    
    const same = field.fr_eq(fwd_gpu[1], inv_gpu[1]);
    std.debug.print("fwd[1] == inv[1]? {}\n", .{same});
}
