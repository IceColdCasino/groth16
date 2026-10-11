const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const mtl = @import("zig-metal");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const n: u32 = 2097152; // share_partials domain size
    
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
    
    // CPU reference: IFFT -> scale -> shift -> bit-reverse -> FFT
    const log_n = std.math.log2(n);
    const n_mont = field.fr_toMont(field.fr_from_u64(@intCast(n)));
    const inv_n = field.fr_inv(n_mont);
    const g = fft.getOmegaN(n * 2);
    
    const a_cpu = try allocator.dupe(field.FrElement, a);
    const b_cpu = try allocator.dupe(field.FrElement, b);
    const c_cpu = try allocator.dupe(field.FrElement, c);
    defer { allocator.free(a_cpu); allocator.free(b_cpu); allocator.free(c_cpu); }
    
    fft.bitReverseFr(a_cpu, n);
    fft.bitReverseFr(b_cpu, n);
    fft.bitReverseFr(c_cpu, n);
    
    // IFFT
    for (0..3) |buf_idx| {
        var buf = if (buf_idx == 0) a_cpu else if (buf_idx == 1) b_cpu else c_cpu;
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
                    const t = field.fr_mul(buf[group_start + j + half_m], w);
                    const u = buf[group_start + j];
                    buf[group_start + j] = field.fr_add(u, t);
                    buf[group_start + j + half_m] = field.fr_sub(u, t);
                    w = field.fr_mul(w, w_m);
                }
            }
        }
        // scale
        for (0..n) |i| buf[i] = field.fr_mul(buf[i], inv_n);
        // shift
        var power = field.fr_one();
        for (0..n) |i| {
            buf[i] = field.fr_mul(buf[i], power);
            power = field.fr_mul(power, g);
        }
        // bit-reverse
        fft.bitReverseFr(buf, n);
        // forward FFT
        s = 1;
        while (s <= log_n) : (s += 1) {
            const m = @as(u32, 1) << @as(u5, @intCast(s));
            const half_m = m >> 1;
            const w_m = fft.getTwiddle(n, n >> @as(u5, @intCast(s)));
            var group_start: u32 = 0;
            while (group_start < n) : (group_start += m) {
                var w = field.fr_one();
                var j: u32 = 0;
                while (j < half_m) : (j += 1) {
                    const t = field.fr_mul(buf[group_start + j + half_m], w);
                    const u = buf[group_start + j];
                    buf[group_start + j] = field.fr_add(u, t);
                    buf[group_start + j + half_m] = field.fr_sub(u, t);
                    w = field.fr_mul(w, w_m);
                }
            }
        }
    }
    
    // GPU path using calculateHGpu-style pipeline
    var prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();
    try prover.warmTwiddles(n);
    const tw_inv = try prover.getTwiddles(n, true);
    const tw_fwd = try prover.getTwiddles(n, false);
    
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;
    
    var a_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer a_buf.release();
    var b_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer b_buf.release();
    var c_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer c_buf.release();
    
    const a_br = try allocator.dupe(field.FrElement, a);
    const b_br = try allocator.dupe(field.FrElement, b);
    const c_br = try allocator.dupe(field.FrElement, c);
    defer { allocator.free(a_br); allocator.free(b_br); allocator.free(c_br); }
    fft.bitReverseFr(a_br, n);
    fft.bitReverseFr(b_br, n);
    fft.bitReverseFr(c_br, n);
    
    @memcpy(@as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(a_br));
    @memcpy(@as([*]u8, @ptrCast(b_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(b_br));
    @memcpy(@as([*]u8, @ptrCast(c_buf.contents().?))[0..buf_size], std.mem.sliceAsBytes(c_br));
    
    const data_bufs = [3]mtl.MTLBuffer{ a_buf, b_buf, c_buf };
    
    // IFFT
    try prover.fftFr4StepBatched3(data_bufs, tw_inv, a_buf, data_bufs, n, log_n);
    
    // scale+shift
    var g_cpu = try allocator.alloc(field.FrElement, n);
    defer allocator.free(g_cpu);
    var power = field.fr_one();
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
    
    // bit-reverse
    var tmp_buf = prover.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer tmp_buf.release();
    try prover.bitReverseGpu(a_buf, tmp_buf, n);
    @memcpy(@as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size], @as([*]u8, @ptrCast(tmp_buf.contents().?))[0..buf_size]);
    try prover.bitReverseGpu(b_buf, tmp_buf, n);
    @memcpy(@as([*]u8, @ptrCast(b_buf.contents().?))[0..buf_size], @as([*]u8, @ptrCast(tmp_buf.contents().?))[0..buf_size]);
    try prover.bitReverseGpu(c_buf, tmp_buf, n);
    @memcpy(@as([*]u8, @ptrCast(c_buf.contents().?))[0..buf_size], @as([*]u8, @ptrCast(tmp_buf.contents().?))[0..buf_size]);
    
    // forward FFT
    try prover.fftFr4StepBatched3(data_bufs, tw_fwd, a_buf, data_bufs, n, log_n);
    
    // download and compare
    const a_gpu = try allocator.alloc(field.FrElement, n);
    const b_gpu = try allocator.alloc(field.FrElement, n);
    const c_gpu = try allocator.alloc(field.FrElement, n);
    defer { allocator.free(a_gpu); allocator.free(b_gpu); allocator.free(c_gpu); }
    
    @memcpy(std.mem.sliceAsBytes(a_gpu), @as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size]);
    @memcpy(std.mem.sliceAsBytes(b_gpu), @as([*]u8, @ptrCast(b_buf.contents().?))[0..buf_size]);
    @memcpy(std.mem.sliceAsBytes(c_gpu), @as([*]u8, @ptrCast(c_buf.contents().?))[0..buf_size]);
    
    var mismatch_a: usize = 0;
    var mismatch_b: usize = 0;
    var mismatch_c: usize = 0;
    for (0..n) |i| {
        if (!field.fr_eq(a_cpu[i], a_gpu[i])) mismatch_a += 1;
        if (!field.fr_eq(b_cpu[i], b_gpu[i])) mismatch_b += 1;
        if (!field.fr_eq(c_cpu[i], c_gpu[i])) mismatch_c += 1;
    }
    std.debug.print("n={d}: a_mismatches={d} b_mismatches={d} c_mismatches={d}\n", .{n, mismatch_a, mismatch_b, mismatch_c});
    
    if (mismatch_a > 0 or mismatch_b > 0 or mismatch_c > 0) {
        return error.TestFailed;
    }
}
