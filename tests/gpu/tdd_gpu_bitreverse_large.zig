const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const mtl = @import("zig-metal");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const n: u32 = 2097152;
    
    var prng = std.Random.DefaultPrng.init(42);
    var original = try allocator.alloc(field.FrElement, n);
    defer allocator.free(original);
    for (0..n) |i| {
        original[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
    }
    
    // CPU reference
    const data_cpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_cpu);
    fft.bitReverseFr(data_cpu, n);
    
    // GPU
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();
    
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;
    var in_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer in_buf.release();
    var out_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer out_buf.release();
    
    @memcpy(@as([*]u8, @ptrCast(in_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(original));
    
    try prover.bitReverseGpu(in_buf, out_buf, n);
    
    const data_gpu = try allocator.alloc(field.FrElement, n);
    defer allocator.free(data_gpu);
    @memcpy(std.mem.sliceAsBytes(data_gpu), @as([*]u8, @ptrCast(out_buf.contents().?))[0..buf_size]);
    
    var mismatch_count: usize = 0;
    for (0..n) |i| {
        if (!field.fr_eq(data_cpu[i], data_gpu[i])) {
            mismatch_count += 1;
        }
    }
    std.debug.print("n={d}: bitReverseGpu mismatches={d}\n", .{n, mismatch_count});
}
