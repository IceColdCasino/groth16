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

    const n: u32 = 1024;
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;

    std.debug.print("=== Direct fftTile1024 test (n={d}) ===\n", .{n});

    // Create random test data and bit-reverse it
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

    // Create twiddles buffer
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

    std.debug.print("Before: data[0]={x} data[1]={x} data[512]={x}\n", .{ data[0][0], data[1][0], data[512][0] });

    const max_threads = metal.fft_tile_1024_pipeline.maxTotalThreadsPerThreadgroup();
    std.debug.print("fft_tile_1024_pipeline maxTotalThreadsPerThreadgroup: {d}\n", .{max_threads});

    try metal.fftTile1024(gpu_buf, tw_buf, n);

    const result = try allocator.alloc(field.FrElement, n);
    @memcpy(std.mem.sliceAsBytes(result), ptr[0..buf_size]);

    std.debug.print("After:  result[0]={x} result[1]={x} result[512]={x}\n", .{ result[0][0], result[1][0], result[512][0] });

    // Compare against CPU reference
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
        std.debug.print("PASS: fftTile1024 matches CPU reference\n", .{});
    } else {
        std.debug.print("FAIL: fftTile1024 does NOT match CPU reference\n", .{});
    }
}
