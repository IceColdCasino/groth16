const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const mtl = @import("zig-metal");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    // Test n=2^21 (share_partials domain size)
    const n: u32 = 1 << 21;
    std.debug.print("=== GPU FFT roundtrip test n={d} ===\n", .{n});
    try testGpuRoundtrip(allocator, n);
    std.debug.print("All tests passed!\n", .{});
}

fn testGpuRoundtrip(allocator: std.mem.Allocator, n: u32) !void {
    var prng = std.Random.DefaultPrng.init(42);
    var original = try allocator.alloc(field.FrElement, n);
    defer allocator.free(original);
    for (0..n) |i| {
        original[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
    }
    
    // CPU reference: IFFT -> divide by n -> shift -> bit-reverse -> FFT
    var data_cpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_cpu);
    data_cpu[0] = data_cpu[0];
    fft.ifft_fr(data_cpu, n);
    
    const n_mont = field.fr_toMont(field.fr_from_u64(@intCast(n)));
    const inv_n = field.fr_inv(n_mont);
    for (0..n) |i| {
        data_cpu[i] = field.fr_mul(data_cpu[i], inv_n);
    }
    
    const g = fft.getOmegaN(n * 2); // 2n-th root for coset shift
    var power = field.fr_one();
    for (0..n) |i| {
        data_cpu[i] = field.fr_mul(data_cpu[i], power);
        power = field.fr_mul(power, g);
    }
    
    fft.bitReverseFr(data_cpu, n);
    data_cpu[0] = data_cpu[0];
    fft.fft_fr(data_cpu, n);
    
    // GPU path
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();
    
    try prover.warmTwiddles(n);
    const twiddles_inv = try prover.getTwiddles(n, true);
    const twiddles_fwd = try prover.getTwiddles(n, false);
    
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;
    
    // CPU bit-reverse and upload
    var data_gpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_gpu);
    data_gpu[0] = data_gpu[0];
    fft.bitReverseFr(data_gpu, n);
    
    var a_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer a_buf.release();
    @memcpy(@as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(data_gpu));
    
    // IFFT on GPU
    const log_n = std.math.log2(n);
    try prover.fftFr4Step(a_buf, twiddles_inv, a_buf, a_buf, n, log_n);
    
    // GPU: divide by n + shift
    var g_cpu = try allocator.alloc(field.FrElement, n);
    defer allocator.free(g_cpu);
    power = field.fr_one();
    for (0..n) |i| {
        g_cpu[i] = power;
        power = field.fr_mul(power, g);
    }
    var g_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer g_buf.release();
    @memcpy(@as([*]u8, @ptrCast(g_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(g_cpu));
    
    var inv_n_buf = prover.device.newBufferWithLengthOptions(fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer inv_n_buf.release();
    @memcpy(@as([*]u8, @ptrCast(inv_n_buf.contents().?))[0..fr_size], std.mem.sliceAsBytes(&[_]field.FrElement{inv_n}));
    
    try prover.ifftScaleShift(a_buf, a_buf, a_buf, g_buf, inv_n_buf, n);
    
    // GPU: bit-reverse
    var temp_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer temp_buf.release();
    try prover.bitReverseGpu(a_buf, temp_buf, n);
    @memcpy(@as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size], @as([*]u8, @ptrCast(temp_buf.contents().?))[0..buf_size]);
    
    // Forward FFT on GPU
    try prover.fftFr4Step(a_buf, twiddles_fwd, a_buf, a_buf, n, log_n);
    
    // Download
    @memcpy(std.mem.sliceAsBytes(data_gpu), @as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size]);
    
    // Compare
    var mismatch_count: usize = 0;
    for (0..n) |i| {
        if (!field.fr_eq(data_cpu[i], data_gpu[i])) {
            if (mismatch_count < 5) {
                std.debug.print("Mismatch at {d}: cpu={x} gpu={x}\n", .{i, data_cpu[i][0], data_gpu[i][0]});
            }
            mismatch_count += 1;
        }
    }
    if (mismatch_count > 0) {
        std.debug.print("Total mismatches: {d}/{d}\n", .{mismatch_count, n});
        return error.TestFailed;
    }
    std.debug.print("GPU roundtrip matches CPU for n={d}\n", .{n});
}
