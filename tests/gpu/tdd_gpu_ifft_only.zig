const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const mtl = @import("zig-metal");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    // Test just GPU IFFT for multiple sizes
    for ([_]u32{ 1024, 2048, 4096, 16384, 65536, 524288, 2097152 }) |n| {
        std.debug.print("Testing IFFT n={d}... ", .{n});
        testGpuIfftOnly(allocator, n) catch |err| {
            std.debug.print("FAILED: {s}\n", .{@errorName(err)});
            continue;
        };
        std.debug.print("OK\n", .{});
    }
}

fn testGpuIfftOnly(allocator: std.mem.Allocator, n: u32) !void {
    var prng = std.Random.DefaultPrng.init(42);
    var original = try allocator.alloc(field.FrElement, n);
    defer allocator.free(original);
    for (0..n) |i| {
        original[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
    }
    
    // CPU reference: ifft_fr already divides by n internally
    var data_cpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_cpu);
    data_cpu[0] = data_cpu[0];
    fft.ifft_fr(data_cpu, n);
    const n_mont = field.fr_toMont(field.fr_from_u64(@intCast(n)));
    const inv_n = field.fr_inv(n_mont);
    
    // GPU path
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();
    try prover.warmTwiddles(n);
    const tw_inv = try prover.getTwiddles(n, true);
    
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
    
    // Divide by n on CPU (same as old code)
    @memcpy(std.mem.sliceAsBytes(data_gpu), @as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size]);
    for (0..n) |i| data_gpu[i] = field.fr_mul(data_gpu[i], inv_n);
    
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
