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
    var a = try allocator.alloc(field.FrElement, n);
    var b = try allocator.alloc(field.FrElement, n);
    var c = try allocator.alloc(field.FrElement, n);
    defer { allocator.free(a); allocator.free(b); allocator.free(c); }
    
    for (0..n) |i| {
        a[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
        b[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
        c[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
    }
    
    // CPU reference
    const n_mont = field.fr_toMont(field.fr_from_u64(@intCast(n)));
    const inv_n = field.fr_inv(n_mont);
    const g = fft.getOmegaN(n * 2);
    
    const a_cpu = try allocator.dupe(field.FrElement, a);
    const b_cpu = try allocator.dupe(field.FrElement, b);
    const c_cpu = try allocator.dupe(field.FrElement, c);
    defer { allocator.free(a_cpu); allocator.free(b_cpu); allocator.free(c_cpu); }
    
    var power = field.fr_one();
    for (0..n) |i| {
        const g_i = power;
        a_cpu[i] = field.fr_mul(field.fr_mul(a_cpu[i], inv_n), g_i);
        b_cpu[i] = field.fr_mul(field.fr_mul(b_cpu[i], inv_n), g_i);
        c_cpu[i] = field.fr_mul(field.fr_mul(c_cpu[i], inv_n), g_i);
        power = field.fr_mul(power, g);
    }
    
    // GPU
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();
    
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;
    var a_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer a_buf.release();
    var b_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer b_buf.release();
    var c_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer c_buf.release();
    
    @memcpy(@as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(a));
    @memcpy(@as([*]u8, @ptrCast(b_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(b));
    @memcpy(@as([*]u8, @ptrCast(c_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(c));
    
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
    
    try prover.ifftScaleShift(a_buf, b_buf, c_buf, g_buf, inv_n_buf, n);
    
    const a_gpu = try allocator.alloc(field.FrElement, n);
    const b_gpu = try allocator.alloc(field.FrElement, n);
    const c_gpu = try allocator.alloc(field.FrElement, n);
    defer { allocator.free(a_gpu); allocator.free(b_gpu); allocator.free(c_gpu); }
    
    @memcpy(std.mem.sliceAsBytes(a_gpu), @as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size]);
    @memcpy(std.mem.sliceAsBytes(b_gpu), @as([*]u8, @ptrCast(b_buf.contents().?))[0..buf_size]);
    @memcpy(std.mem.sliceAsBytes(c_gpu), @as([*]u8, @ptrCast(c_buf.contents().?))[0..buf_size]);
    
    var ma: usize = 0;
    var mb: usize = 0;
    var mc: usize = 0;
    var first_mismatch: usize = n;
    for (0..n) |i| {
        if (!field.fr_eq(a_cpu[i], a_gpu[i])) {
            if (ma == 0 and first_mismatch == n) first_mismatch = i;
            ma += 1;
        }
        if (!field.fr_eq(b_cpu[i], b_gpu[i])) mb += 1;
        if (!field.fr_eq(c_cpu[i], c_gpu[i])) mc += 1;
    }
    std.debug.print("n={d}: a={d} b={d} c={d} first_mismatch={d}\n", .{n, ma, mb, mc, first_mismatch});
}
