const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const mtl = @import("zig-metal");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    // Test multiple sizes
    for ([_]u32{ 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152 }) |n| {
        std.debug.print("Testing n={d}... ", .{n});
        testGpuRoundtrip(allocator, n) catch |err| {
            std.debug.print("FAILED: {s}\n", .{@errorName(err)});
            continue;
        };
        std.debug.print("OK\n", .{});
    }
}

fn testGpuRoundtrip(allocator: std.mem.Allocator, n: u32) !void {
    var prng = std.Random.DefaultPrng.init(42);
    var original = try allocator.alloc(field.FrElement, n);
    defer allocator.free(original);
    for (0..n) |i| {
        original[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
    }
    
    // CPU reference: ifft_fr already divides by n
    var data_cpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_cpu);
    data_cpu[0] = data_cpu[0];
    fft.ifft_fr(data_cpu, n);
    const n_mont = field.fr_toMont(field.fr_from_u64(@intCast(n)));
    const inv_n = field.fr_inv(n_mont);
    const g = fft.getOmegaN(n * 2);
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
    const tw_inv = try prover.getTwiddles(n, true);
    const tw_fwd = try prover.getTwiddles(n, false);
    
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;
    var data_gpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_gpu);
    data_gpu[0] = data_gpu[0];
    fft.bitReverseFr(data_gpu, n);
    
    var a_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer a_buf.release();
    @memcpy(@as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(data_gpu));
    
    const log_n = std.math.log2(n);
    try prover.fftFr4Step(a_buf, tw_inv, a_buf, a_buf, n, log_n);
    
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
    
    var tmp_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer tmp_buf.release();
    try prover.bitReverseGpu(a_buf, tmp_buf, n);
    @memcpy(@as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size], @as([*]u8, @ptrCast(tmp_buf.contents().?))[0..buf_size]);
    
    try prover.fftFr4Step(a_buf, tw_fwd, a_buf, a_buf, n, log_n);
    
    @memcpy(std.mem.sliceAsBytes(data_gpu), @as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size]);
    
    var mismatch_count: usize = 0;
    for (0..n) |i| {
        if (!field.fr_eq(data_cpu[i], data_gpu[i])) {
            mismatch_count += 1;
        }
    }
    if (mismatch_count > 0) {
        std.debug.print("mismatches={d} ", .{mismatch_count});
        return error.TestFailed;
    }
}
