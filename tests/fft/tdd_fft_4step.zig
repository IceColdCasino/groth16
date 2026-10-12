const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const mtl = @import("zig-metal");
const builtin = @import("builtin");

const field = cpu.field;
const fft = cpu.fft;

const TEST_LOG_N = 20;
const TEST_N = 1 << TEST_LOG_N;

fn makeTestData(allocator: std.mem.Allocator, n: u32) ![]field.FrElement {
    const data = try allocator.alloc(field.FrElement, n);
    var prng = std.Random.DefaultPrng.init(42);
    for (0..n) |i| {
        data[i] = field.fr_from_u64(prng.random().int(u64));
        data[i] = field.fr_toMont(data[i]);
    }
    return data;
}

fn testFftFr4Step(allocator: std.mem.Allocator, metal: *gpu.metal.MetalProver) !bool {
    const n = TEST_N;
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;

    const data = try makeTestData(allocator, n);
    const expected = try allocator.alloc(field.FrElement, n);
    @memcpy(std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(data));

    // CPU reference: full FFT (includes internal bit-reversal)
    fft.fft_fr(expected, n);

    // GPU: bit-reverse on CPU, then tile stages 1-10 + global stages 11-20
    const gpu_input = try allocator.alloc(field.FrElement, n);
    @memcpy(std.mem.sliceAsBytes(gpu_input), std.mem.sliceAsBytes(data));
    fft.bitReverseFr(gpu_input, n);

    const gpu_buf = metal.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer gpu_buf.release();
    const dummy_buf = metal.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer dummy_buf.release();

    const ptr: [*]u8 = @ptrCast(gpu_buf.contents().?);
    @memcpy(ptr[0..buf_size], std.mem.sliceAsBytes(gpu_input));

    var twiddles = try allocator.alloc(field.FrElement, n / 2);
    for (0..n / 2) |i| {
        twiddles[i] = fft.getTwiddle(n, @intCast(i));
    }
    const tw_buf = metal.device.newBufferWithLengthOptions(twiddles.len * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer tw_buf.release();
    const tw_ptr: [*]u8 = @ptrCast(tw_buf.contents().?);
    @memcpy(tw_ptr[0..twiddles.len * fr_size], std.mem.sliceAsBytes(twiddles));

    try metal.fftFr4Step(gpu_buf, tw_buf, dummy_buf, dummy_buf, n, TEST_LOG_N);

    const gpu_result = try allocator.alloc(field.FrElement, n);
    @memcpy(std.mem.sliceAsBytes(gpu_result), ptr[0..buf_size]);

    var pass = true;
    for (0..n) |i| {
        if (!field.fr_eq(gpu_result[i], expected[i])) {
            std.debug.print("fftFr4Step mismatch at {d}: gpu={x} expected={x}\n", .{ i, gpu_result[i][0], expected[i][0] });
            pass = false;
            break;
        }
    }
    return pass;
}

fn testFftFr4StepBatched3(allocator: std.mem.Allocator, metal: *gpu.metal.MetalProver) !bool {
    const n = TEST_N;
    const fr_size = @sizeOf(field.FrElement);
    const buf_size = n * fr_size;

    var data_bufs: [3][]field.FrElement = undefined;
    var expected_bufs: [3][]field.FrElement = undefined;
    var gpu_mtl_bufs: [3]mtl.MTLBuffer = undefined;

    for (0..3) |b| {
        data_bufs[b] = try makeTestData(allocator, n);
        expected_bufs[b] = try allocator.alloc(field.FrElement, n);
        @memcpy(std.mem.sliceAsBytes(expected_bufs[b]), std.mem.sliceAsBytes(data_bufs[b]));
        fft.fft_fr(expected_bufs[b], n);

        const gpu_input = try allocator.alloc(field.FrElement, n);
        @memcpy(std.mem.sliceAsBytes(gpu_input), std.mem.sliceAsBytes(data_bufs[b]));
        fft.bitReverseFr(gpu_input, n);

        gpu_mtl_bufs[b] = metal.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        const p: [*]u8 = @ptrCast(gpu_mtl_bufs[b].contents().?);
        @memcpy(p[0..buf_size], std.mem.sliceAsBytes(gpu_input));
    }
    defer for (gpu_mtl_bufs) |buf| buf.release();

    var twiddles = try allocator.alloc(field.FrElement, n / 2);
    for (0..n / 2) |i| {
        twiddles[i] = fft.getTwiddle(n, @intCast(i));
    }
    const tw_buf = metal.device.newBufferWithLengthOptions(twiddles.len * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer tw_buf.release();
    const tw_ptr: [*]u8 = @ptrCast(tw_buf.contents().?);
    @memcpy(tw_ptr[0..twiddles.len * fr_size], std.mem.sliceAsBytes(twiddles));

    const dummy_buf = metal.device.newBufferWithLengthOptions(buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
    defer dummy_buf.release();

    try metal.fftFr4StepBatched3(gpu_mtl_bufs, tw_buf, dummy_buf, .{ dummy_buf, dummy_buf, dummy_buf }, n, TEST_LOG_N);

    var pass = true;
    for (0..3) |b| {
        const gpu_result = try allocator.alloc(field.FrElement, n);
        const out_ptr: [*]u8 = @ptrCast(gpu_mtl_bufs[b].contents().?);
        @memcpy(std.mem.sliceAsBytes(gpu_result), out_ptr[0..buf_size]);

        for (0..n) |i| {
            if (!field.fr_eq(gpu_result[i], expected_bufs[b][i])) {
                std.debug.print("fftFr4StepBatched3 buffer {d} mismatch at {d}: gpu={x} expected={x}\n", .{ b, i, gpu_result[i][0], expected_bufs[b][i][0] });
                pass = false;
                break;
            }
        }
        if (!pass) break;
    }
    return pass;
}

pub fn main() !void {
    if (builtin.os.tag != .macos) {
        std.debug.print("Skipping: macOS only\n", .{});
        return;
    }

    const allocator = std.heap.c_allocator;
    const metal = try gpu.metal.MetalProver.init(allocator);
    defer metal.deinit();

    std.debug.print("=== Hierarchical FFT TDD Tests (n=2^{d}) ===\n", .{TEST_LOG_N});

    std.debug.print("1. fftFr4Step (tile + global stages)... ", .{});
    const t1 = try testFftFr4Step(allocator, metal);
    if (t1) {
        std.debug.print("PASS\n", .{});
    } else {
        std.debug.print("FAIL\n", .{});
    }

    std.debug.print("2. fftFr4StepBatched3 (3 buffers)... ", .{});
    const t2 = try testFftFr4StepBatched3(allocator, metal);
    if (t2) {
        std.debug.print("PASS\n", .{});
    } else {
        std.debug.print("FAIL\n", .{});
    }

    if (t1 and t2) {
        std.debug.print("\nAll tests PASSED!\n", .{});
    } else {
        std.debug.print("\nSome tests FAILED!\n", .{});
        std.process.exit(1);
    }
}
