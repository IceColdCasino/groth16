const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const mtl = @import("zig-metal");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const n: u32 = 1024;
    
    var prng = std.Random.DefaultPrng.init(42);
    var original = try allocator.alloc(field.FrElement, n);
    defer allocator.free(original);
    for (0..n) |i| {
        original[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
    }
    
    // CPU path step by step
    const data_cpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_cpu);
    fft.bitReverseFr(data_cpu, n);
    
    // CPU step 1: IFFT butterflies
    const cpu_after_ifft = try allocator.dupe(field.FrElement, data_cpu);
    defer allocator.free(cpu_after_ifft);
    const log_n = std.math.log2(n);
    var s: u32 = 1;
    while (s <= log_n) : (s += 1) {
        const m = @as(u32, 1) << @as(u5, @intCast(s));
        const half_m = m >> 1;
        const w_m = fft.getTwiddleInv(n, n >> @as(u5, @intCast(s)));
        var group_start: u32 = 0;
        while (group_start < n) : (group_start += m) {
            var w = field.fr_one();
            var j: u32 = 0;
            while (j < half_m) : (j += 1) {
                const t = field.fr_mul(cpu_after_ifft[group_start + j + half_m], w);
                const u = cpu_after_ifft[group_start + j];
                cpu_after_ifft[group_start + j] = field.fr_add(u, t);
                cpu_after_ifft[group_start + j + half_m] = field.fr_sub(u, t);
                w = field.fr_mul(w, w_m);
            }
        }
    }
    
    // CPU step 2: scale by inv_n and shift by g^i
    const n_mont = field.fr_toMont(field.fr_from_u64(@intCast(n)));
    const inv_n = field.fr_inv(n_mont);
    const g = fft.getOmegaN(n * 2);
    var power = field.fr_one();
    var cpu_after_shift = try allocator.dupe(field.FrElement, cpu_after_ifft);
    defer allocator.free(cpu_after_shift);
    for (0..n) |i| {
        cpu_after_shift[i] = field.fr_mul(cpu_after_shift[i], inv_n);
        cpu_after_shift[i] = field.fr_mul(cpu_after_shift[i], power);
        power = field.fr_mul(power, g);
    }
    
    // CPU step 3: bit-reverse
    const cpu_after_br = try allocator.dupe(field.FrElement, cpu_after_shift);
    defer allocator.free(cpu_after_br);
    fft.bitReverseFr(cpu_after_br, n);
    
    // CPU step 4: FFT butterflies
    const cpu_after_fft = try allocator.dupe(field.FrElement, cpu_after_br);
    defer allocator.free(cpu_after_fft);
    s = 1;
    while (s <= log_n) : (s += 1) {
        const m = @as(u32, 1) << @as(u5, @intCast(s));
        const half_m = m >> 1;
        const w_m = fft.getTwiddle(n, n >> @as(u5, @intCast(s)));
        var group_start2: u32 = 0;
        while (group_start2 < n) : (group_start2 += m) {
            var w = field.fr_one();
            var j: u32 = 0;
            while (j < half_m) : (j += 1) {
                const t = field.fr_mul(cpu_after_fft[group_start2 + j + half_m], w);
                const u = cpu_after_fft[group_start2 + j];
                cpu_after_fft[group_start2 + j] = field.fr_add(u, t);
                cpu_after_fft[group_start2 + j + half_m] = field.fr_sub(u, t);
                w = field.fr_mul(w, w_m);
            }
        }
    }
    
    // GPU path step by step
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();
    try prover.warmTwiddles(n);
    const tw_inv = try prover.getTwiddles(n, true);
    const tw_fwd = try prover.getTwiddles(n, false);
    
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;
    const data_gpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_gpu);
    fft.bitReverseFr(data_gpu, n);
    
    var a_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer a_buf.release();
    @memcpy(@as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(data_gpu));
    
    // GPU step 1: IFFT
    try prover.fftFr4Step(a_buf, tw_inv, a_buf, a_buf, n, log_n);
    const gpu_after_ifft = try allocator.alloc(field.FrElement, n);
    defer allocator.free(gpu_after_ifft);
    @memcpy(std.mem.sliceAsBytes(gpu_after_ifft), @as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size]);
    
    var mismatches_ifft: usize = 0;
    for (0..n) |i| {
        if (!field.fr_eq(cpu_after_ifft[i], gpu_after_ifft[i])) mismatches_ifft += 1;
    }
    std.debug.print("After IFFT: mismatches={d}\n", .{mismatches_ifft});
    
    // GPU step 2: scale + shift
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
    
    // CPU: scale+shift manually (ifftScaleShift kernel is for 3 buffers)
    var gpu_after_ifft_mut = try allocator.dupe(field.FrElement, gpu_after_ifft);
    defer allocator.free(gpu_after_ifft_mut);
    for (0..n) |i| {
        gpu_after_ifft_mut[i] = field.fr_mul(gpu_after_ifft_mut[i], inv_n);
        gpu_after_ifft_mut[i] = field.fr_mul(gpu_after_ifft_mut[i], g_cpu[i]);
    }
    @memcpy(@as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(gpu_after_ifft_mut));
    const gpu_after_shift = try allocator.alloc(field.FrElement, n);
    defer allocator.free(gpu_after_shift);
    @memcpy(std.mem.sliceAsBytes(gpu_after_shift), @as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size]);
    
    var mismatches_shift: usize = 0;
    for (0..n) |i| {
        if (!field.fr_eq(cpu_after_shift[i], gpu_after_shift[i])) mismatches_shift += 1;
    }
    std.debug.print("After scale+shift: mismatches={d}\n", .{mismatches_shift});
    
    // GPU step 3: bit-reverse
    var tmp_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer tmp_buf.release();
    try prover.bitReverseGpu(a_buf, tmp_buf, n);
    const gpu_after_br = try allocator.alloc(field.FrElement, n);
    defer allocator.free(gpu_after_br);
    @memcpy(std.mem.sliceAsBytes(gpu_after_br), @as([*]u8, @ptrCast(tmp_buf.contents().?))[0..buf_size]);
    
    var mismatches_br: usize = 0;
    for (0..n) |i| {
        if (!field.fr_eq(cpu_after_br[i], gpu_after_br[i])) mismatches_br += 1;
    }
    std.debug.print("After bit-reverse: mismatches={d}\n", .{mismatches_br});
    
    // GPU step 4: FFT
    @memcpy(@as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size], @as([*]u8, @ptrCast(tmp_buf.contents().?))[0..buf_size]);
    try prover.fftFr4Step(a_buf, tw_fwd, a_buf, a_buf, n, log_n);
    const gpu_after_fft = try allocator.alloc(field.FrElement, n);
    defer allocator.free(gpu_after_fft);
    @memcpy(std.mem.sliceAsBytes(gpu_after_fft), @as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size]);
    
    var mismatches_fft: usize = 0;
    for (0..n) |i| {
        if (!field.fr_eq(cpu_after_fft[i], gpu_after_fft[i])) mismatches_fft += 1;
    }
    std.debug.print("After FFT: mismatches={d}\n", .{mismatches_fft});
}
