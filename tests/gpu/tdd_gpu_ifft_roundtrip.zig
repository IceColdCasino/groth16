const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const mtl = @import("zig-metal");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    std.debug.print("=== GPU IFFT roundtrip test ===\n", .{});
    try testGpuIfftRoundtrip(allocator, 1024);
    try testGpuIfftRoundtrip(allocator, 16384);
    std.debug.print("All tests passed!\n", .{});
}

fn testGpuIfftRoundtrip(allocator: std.mem.Allocator, n: u32) !void {
    // Generate random test data in Montgomery form
    var original = try allocator.alloc(field.FrElement, n);
    defer allocator.free(original);
    var prng = std.Random.DefaultPrng.init(42);
    for (0..n) |i| {
        original[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
    }
    
    // CPU FFT
    var data_cpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_cpu);
    data_cpu[0] = data_cpu[0];
    fft.fft_fr(data_cpu, n);
    
    // GPU IFFT on CPU FFT result
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();
    
    // For GPU IFFT, we need to bit-reverse the CPU FFT output
    var data_gpu = try allocator.dupe(field.FrElement, data_cpu);
    defer allocator.free(data_gpu);
    fft.bitReverseFr(data_gpu, n);
    
    // Upload to GPU
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;
    var data_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer data_buf.release();
    @memcpy(@as([*]u8, @ptrCast(data_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(data_gpu));
    
    // Upload inverse twiddles
    var twiddles = try allocator.alloc(field.FrElement, n / 2);
    defer allocator.free(twiddles);
    for (0..n / 2) |i| {
        twiddles[i] = fft.getTwiddleInv(n, @intCast(i));
    }
    var twiddles_buf = prover.device.newBufferWithLengthOptions(twiddles.len * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer twiddles_buf.release();
    @memcpy(@as([*]u8, @ptrCast(twiddles_buf.contents().?))[0..twiddles.len * fr_size], std.mem.sliceAsBytes(twiddles));
    
    // Run GPU IFFT (hierarchical)
    const log_n = std.math.log2(n);
    try prover.fftFr4Step(data_buf, twiddles_buf, data_buf, data_buf, n, log_n);
    
    // Download
    @memcpy(std.mem.sliceAsBytes(data_gpu), @as([*]u8, @ptrCast(data_buf.contents().?))[0..buf_size]);
    
    // Divide by n (GPU IFFT doesn't do this)
    const n_mont = field.fr_toMont(field.fr_from_u64(@intCast(n)));
    const inverse_n = field.fr_inv(n_mont);
    for (0..n) |i| {
        data_gpu[i] = field.fr_mul(data_gpu[i], inverse_n);
    }
    
    // Compare with original
    var mismatch_count: usize = 0;
    for (0..n) |i| {
        if (!field.fr_eq(original[i], data_gpu[i])) {
            if (mismatch_count < 5) {
                std.debug.print("Roundtrip mismatch at {d}: original={x} gpu={x}\n", .{i, original[i][0], data_gpu[i][0]});
            }
            mismatch_count += 1;
        }
    }
    if (mismatch_count > 0) {
        std.debug.print("Total mismatches for n={d}: {d}/{d}\n", .{n, mismatch_count, n});
        return error.TestFailed;
    }
    std.debug.print("GPU IFFT roundtrip OK for n={d}\n", .{n});
}
