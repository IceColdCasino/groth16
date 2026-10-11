const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const mtl = @import("zig-metal");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const n: u32 = 1024;
    
    // Test GPU IFFT with OLD on-the-fly twiddles vs NEW cached twiddles
    std.debug.print("Testing GPU IFFT n={d} with on-the-fly twiddles...\n", .{n});
    try testGpuIfftOldStyle(allocator, n);
    std.debug.print("Old style: OK\n", .{});
}

fn testGpuIfftOldStyle(allocator: std.mem.Allocator, n: u32) !void {
    var prng = std.Random.DefaultPrng.init(42);
    var original = try allocator.alloc(field.FrElement, n);
    defer allocator.free(original);
    for (0..n) |i| {
        original[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
    }
    
    // CPU reference
    var data_cpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_cpu);
    data_cpu[0] = data_cpu[0];
    fft.ifft_fr(data_cpu, n);
    const n_mont = field.fr_toMont(field.fr_from_u64(@intCast(n)));
    const inv_n = field.fr_inv(n_mont);
    for (0..n) |i| data_cpu[i] = field.fr_mul(data_cpu[i], inv_n);
    
    // GPU path with on-the-fly twiddles (OLD style)
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();
    
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;
    var data_gpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_gpu);
    data_gpu[0] = data_gpu[0];
    fft.bitReverseFr(data_gpu, n);
    
    var a_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer a_buf.release();
    @memcpy(@as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(data_gpu));
    
    // Upload on-the-fly inverse twiddles
    var twiddles = try allocator.alloc(field.FrElement, n / 2);
    defer allocator.free(twiddles);
    for (0..n / 2) |i| {
        twiddles[i] = fft.getTwiddleInv(n, @intCast(i));
    }
    var tw_buf = prover.device.newBufferWithLengthOptions(twiddles.len * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer tw_buf.release();
    @memcpy(@as([*]u8, @ptrCast(tw_buf.contents().?))[0..twiddles.len * fr_size], std.mem.sliceAsBytes(twiddles));
    
    const log_n = std.math.log2(n);
    try prover.fftFr4Step(a_buf, tw_buf, a_buf, a_buf, n, log_n);
    
    @memcpy(std.mem.sliceAsBytes(data_gpu), @as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size]);
    for (0..n) |i| data_gpu[i] = field.fr_mul(data_gpu[i], inv_n);
    
    var mismatch_count: usize = 0;
    for (0..n) |i| {
        if (!field.fr_eq(data_cpu[i], data_gpu[i])) {
            mismatch_count += 1;
        }
    }
    if (mismatch_count > 0) {
        std.debug.print("mismatches={d}\n", .{mismatch_count});
        return error.TestFailed;
    }
}
