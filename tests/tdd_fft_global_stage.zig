const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const mtl = @import("zig-metal");
const builtin = @import("builtin");

const field = cpu.field;
const fft = cpu.fft;

pub fn main() !void {
    if (builtin.os.tag != .macos) {
        std.debug.print("Skipping: macOS only\n", .{});
        return;
    }

    const allocator = std.heap.c_allocator;
    const metal = try gpu.metal.MetalProver.init(allocator);
    defer metal.deinit();

    const n: u32 = 4;
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;

    std.debug.print("=== fftGlobalStage test n={d} ===\n", .{n});

    // Simple test: [1, 2, 3, 4] in Montgomery form
    var data = try allocator.alloc(field.FrElement, n);
    data[0] = field.fr_toMont(field.fr_from_u64(1));
    data[1] = field.fr_toMont(field.fr_from_u64(2));
    data[2] = field.fr_toMont(field.fr_from_u64(3));
    data[3] = field.fr_toMont(field.fr_from_u64(4));

    // Bit-reverse
    fft.bitReverseFr(data, n);

    const gpu_buf = metal.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse {
        std.debug.print("Buffer creation failed\n", .{});
        return;
    };
    defer gpu_buf.release();

    const ptr: [*]u8 = @ptrCast(gpu_buf.contents().?);
    @memcpy(ptr[0..buf_size], std.mem.sliceAsBytes(data));

    // Twiddles for n=4
    var twiddles = try allocator.alloc(field.FrElement, n / 2);
    twiddles[0] = fft.getTwiddle(n, 0);
    twiddles[1] = fft.getTwiddle(n, 1);
    const tw_buf = metal.device.newBufferWithLengthOptions(twiddles.len * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse {
        std.debug.print("Twiddles buffer creation failed\n", .{});
        return;
    };
    defer tw_buf.release();
    const tw_ptr: [*]u8 = @ptrCast(tw_buf.contents().?);
    @memcpy(tw_ptr[0..twiddles.len * fr_size], std.mem.sliceAsBytes(twiddles));

    // Stage 1 and 2
    try metal.fftGlobalStage(gpu_buf, tw_buf, n, 1);
    try metal.fftGlobalStage(gpu_buf, tw_buf, n, 2);

    const result = try allocator.alloc(field.FrElement, n);
    @memcpy(std.mem.sliceAsBytes(result), ptr[0..buf_size]);

    // CPU reference
    var expected = try allocator.alloc(field.FrElement, n);
    expected[0] = field.fr_toMont(field.fr_from_u64(1));
    expected[1] = field.fr_toMont(field.fr_from_u64(2));
    expected[2] = field.fr_toMont(field.fr_from_u64(3));
    expected[3] = field.fr_toMont(field.fr_from_u64(4));
    fft.fft_fr(expected, n);

    std.debug.print("GPU:    [{x}, {x}, {x}, {x}]\n", .{ result[0][0], result[1][0], result[2][0], result[3][0] });
    std.debug.print("CPU:    [{x}, {x}, {x}, {x}]\n", .{ expected[0][0], expected[1][0], expected[2][0], expected[3][0] });

    var pass = true;
    for (0..n) |i| {
        if (!field.fr_eq(result[i], expected[i])) {
            pass = false;
            std.debug.print("Mismatch at {d}: gpu={x} expected={x}\n", .{ i, result[i][0], expected[i][0] });
        }
    }

    if (pass) {
        std.debug.print("PASS\n", .{});
    } else {
        std.debug.print("FAIL\n", .{});
    }
}
