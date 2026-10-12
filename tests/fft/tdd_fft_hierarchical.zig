const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const mtl = @import("zig-metal");
const builtin = @import("builtin");

const field = cpu.field;
const fft = cpu.fft;

fn makeTestData(allocator: std.mem.Allocator, n: u32) ![]field.FrElement {
    const data = try allocator.alloc(field.FrElement, n);
    var prng = std.Random.DefaultPrng.init(42);
    for (0..n) |i| {
        data[i] = field.fr_from_u64(prng.random().int(u64));
        data[i] = field.fr_toMont(data[i]);
    }
    return data;
}

pub fn main() !void {
    if (builtin.os.tag != .macos) {
        std.debug.print("Skipping: macOS only\n", .{});
        return;
    }

    const allocator = std.heap.c_allocator;
    const metal = try gpu.metal.MetalProver.init(allocator);
    defer metal.deinit();

    // Test n=2048 = 2^11: tile stages 1-10 + global stage 11
    const n: u32 = 2048;
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;

    std.debug.print("=== Hierarchical FFT test n={d} ===\n", .{n});

    const data = try makeTestData(allocator, n);
    const cpu_input = try allocator.alloc(field.FrElement, n);
    @memcpy(std.mem.sliceAsBytes(cpu_input), std.mem.sliceAsBytes(data));
    fft.bitReverseFr(cpu_input, n);

    const gpu_buf = metal.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse {
        std.debug.print("Buffer creation failed\n", .{});
        return;
    };
    defer gpu_buf.release();

    const ptr: [*]u8 = @ptrCast(gpu_buf.contents().?);
    @memcpy(ptr[0..buf_size], std.mem.sliceAsBytes(cpu_input));

    var twiddles = try allocator.alloc(field.FrElement, n / 2);
    for (0..n / 2) |i| {
        twiddles[i] = fft.getTwiddle(n, @intCast(i));
    }
    const tw_buf = metal.device.newBufferWithLengthOptions(twiddles.len * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse {
        std.debug.print("Twiddles buffer creation failed\n", .{});
        return;
    };
    defer tw_buf.release();
    const tw_ptr: [*]u8 = @ptrCast(tw_buf.contents().?);
    @memcpy(tw_ptr[0..twiddles.len * fr_size], std.mem.sliceAsBytes(twiddles));

    // Tile stages 1-10
    try metal.fftTile1024(gpu_buf, tw_buf, n);

    // Global stage 11
    try metal.fftGlobalStage(gpu_buf, tw_buf, n, 11);

    const result = try allocator.alloc(field.FrElement, n);
    @memcpy(std.mem.sliceAsBytes(result), ptr[0..buf_size]);

    // CPU reference
    const expected = try allocator.alloc(field.FrElement, n);
    @memcpy(std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(data));
    fft.fft_fr(expected, n);

    var correct = true;
    for (0..n) |i| {
        if (!field.fr_eq(result[i], expected[i])) {
            correct = false;
            std.debug.print("Mismatch at {d}: gpu={x} expected={x}\n", .{ i, result[i][0], expected[i][0] });
            break;
        }
    }

    if (correct) {
        std.debug.print("PASS: Hierarchical FFT matches CPU for n={d}\n", .{n});
    } else {
        std.debug.print("FAIL: Hierarchical FFT does NOT match CPU for n={d}\n", .{n});
    }
}
