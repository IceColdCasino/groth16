const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const mtl = @import("zig-metal");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    std.debug.print("=== Detailed n=4 IFFT trace ===\n", .{});
    try testDetailed(allocator);
}

fn testDetailed(allocator: std.mem.Allocator) !void {
    const n: u32 = 4;
    
    // Simple test data: [1, 0, 0, 0] in Montgomery form
    var original = try allocator.alloc(field.FrElement, n);
    defer allocator.free(original);
    original[0] = field.fr_one();
    original[1] = field.fr_zero();
    original[2] = field.fr_zero();
    original[3] = field.fr_zero();
    
    std.debug.print("Original: ", .{});
    for (0..n) |i| std.debug.print("{x} ", .{original[i][0]});
    std.debug.print("\n", .{});
    
    // CPU FFT
    var data_cpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_cpu);
    data_cpu[0] = data_cpu[0];
    fft.fft_fr(data_cpu, n);
    std.debug.print("CPU FFT:  ", .{});
    for (0..n) |i| std.debug.print("{x} ", .{data_cpu[i][0]});
    std.debug.print("\n", .{});
    
    // CPU IFFT
    var data_cpu_ifft = try allocator.dupe(field.FrElement, data_cpu);
    defer allocator.free(data_cpu_ifft);
    data_cpu_ifft[0] = data_cpu_ifft[0];
    fft.ifft_fr(data_cpu_ifft, n);
    std.debug.print("CPU IFFT: ", .{});
    for (0..n) |i| std.debug.print("{x} ", .{data_cpu_ifft[i][0]});
    std.debug.print("\n", .{});
    
    // GPU IFFT on CPU FFT result
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();
    
    var data_gpu = try allocator.dupe(field.FrElement, data_cpu);
    defer allocator.free(data_gpu);
    fft.bitReverseFr(data_gpu, n);
    
    std.debug.print("GPU input (bit-reversed CPU FFT): ", .{});
    for (0..n) |i| std.debug.print("{x} ", .{data_gpu[i][0]});
    std.debug.print("\n", .{});
    
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;
    var data_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer data_buf.release();
    @memcpy(@as([*]u8, @ptrCast(data_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(data_gpu));
    
    var twiddles = try allocator.alloc(field.FrElement, n / 2);
    defer allocator.free(twiddles);
    for (0..n / 2) |i| {
        twiddles[i] = fft.getTwiddleInv(n, @intCast(i));
    }
    std.debug.print("Inverse twiddles: ", .{});
    for (0..n/2) |i| std.debug.print("{x} ", .{twiddles[i][0]});
    std.debug.print("\n", .{});
    
    var twiddles_buf = prover.device.newBufferWithLengthOptions(twiddles.len * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer twiddles_buf.release();
    @memcpy(@as([*]u8, @ptrCast(twiddles_buf.contents().?))[0..twiddles.len * fr_size], std.mem.sliceAsBytes(twiddles));
    
    const log_n = std.math.log2(n);
    try prover.fftFr4Step(data_buf, twiddles_buf, data_buf, data_buf, n, log_n);
    
    @memcpy(std.mem.sliceAsBytes(data_gpu), @as([*]u8, @ptrCast(data_buf.contents().?))[0..buf_size]);
    
    std.debug.print("GPU IFFT (before divide by n): ", .{});
    for (0..n) |i| std.debug.print("{x} ", .{data_gpu[i][0]});
    std.debug.print("\n", .{});
    
    const n_mont = field.fr_toMont(field.fr_from_u64(@intCast(n)));
    const inverse_n = field.fr_inv(n_mont);
    for (0..n) |i| {
        data_gpu[i] = field.fr_mul(data_gpu[i], inverse_n);
    }
    
    std.debug.print("GPU IFFT (after divide by n):  ", .{});
    for (0..n) |i| std.debug.print("{x} ", .{data_gpu[i][0]});
    std.debug.print("\n", .{});
    
    std.debug.print("Expected (original):             ", .{});
    for (0..n) |i| std.debug.print("{x} ", .{original[i][0]});
    std.debug.print("\n", .{});
}
