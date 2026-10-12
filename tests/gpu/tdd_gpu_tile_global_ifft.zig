const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;
const gpu = @import("gpu");
const mtl = @import("zig-metal");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const n: u32 = 2048;
    
    var prng = std.Random.DefaultPrng.init(42);
    var original = try allocator.alloc(field.FrElement, n);
    defer allocator.free(original);
    for (0..n) |i| {
        original[i] = field.fr_toMont(field.fr_from_u64(prng.random().int(u64)));
    }
    
    // CPU: run IFFT manually
    var data_cpu = try allocator.dupe(field.FrElement, original);
    defer allocator.free(data_cpu);
    data_cpu[0] = data_cpu[0];
    fft.bitReverseFr(data_cpu, n);
    
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
                const t = field.fr_mul(data_cpu[group_start + j + half_m], w);
                const u = data_cpu[group_start + j];
                data_cpu[group_start + j] = field.fr_add(u, t);
                data_cpu[group_start + j + half_m] = field.fr_sub(u, t);
                w = field.fr_mul(w, w_m);
            }
        }
    }
    
    // GPU: tile stages (1-10) then global stage (11)
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
    
    try prover.fftTile1024(a_buf, tw_inv, n);
    try prover.fftGlobalStage(a_buf, tw_inv, n, 11);
    
    @memcpy(std.mem.sliceAsBytes(data_gpu), @as([*]u8, @ptrCast(a_buf.contents().?))[0..buf_size]);
    
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
        std.debug.print("mismatches={d}\n", .{mismatch_count});
        return error.TestFailed;
    }
    std.debug.print("Tile+Global IFFT matches CPU for n={d}\n", .{n});
}
