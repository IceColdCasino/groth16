const std = @import("std");
const mod = @import("mod.zig");
const cpu = @import("cpu");
const mtl = @import("zig-metal");

// C stdio for file reading
const c_stdio = @cImport({
    @cInclude("stdio.h");
});

// ============================================================================
// Witness preload cache (global, mutex-protected)
// ============================================================================

fn witnessCacheLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

const WitnessCache = struct {
    mutex: std.atomic.Mutex,
    entries: std.StringHashMap([]u8),

    pub fn init() WitnessCache {
        return .{
            .mutex = .unlocked,
            .entries = std.StringHashMap([]u8).init(std.heap.c_allocator),
        };
    }

    pub fn deinit(self: *WitnessCache) void {
        witnessCacheLock(&self.mutex);
        defer self.mutex.unlock();
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            std.heap.c_allocator.free(entry.value_ptr.*);
            std.heap.c_allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn get(self: *WitnessCache, path: []const u8) ?[]u8 {
        witnessCacheLock(&self.mutex);
        defer self.mutex.unlock();
        const val = self.entries.get(path);
        if (val) |data| {
            _ = self.entries.remove(path);
            return data;
        }
        return null;
    }

    pub fn put(self: *WitnessCache, path: []const u8, data: []u8) !void {
        witnessCacheLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.entries.fetchRemove(path)) |old| {
            std.heap.c_allocator.free(old.value);
            std.heap.c_allocator.free(old.key);
        }
        const key = try std.heap.c_allocator.dupe(u8, path);
        try self.entries.put(key, data);
    }
};

var global_witness_cache = WitnessCache.init();

fn preloadWitness(path: []u8) void {
    defer std.heap.c_allocator.free(path);
    const allocator = std.heap.c_allocator;
    const data = readFileToBuffer(path, allocator) catch |err| {
        std.debug.print("Preload witness failed for {s}: {any}\n", .{ path, err });
        return;
    };
    global_witness_cache.put(path, data) catch |err| {
        std.debug.print("Preload witness cache store failed for {s}: {any}\n", .{ path, err });
        allocator.free(data);
    };
}

// ============================================================================
// ZKey / Witness binary parsing
// ============================================================================

fn readFileToBuffer(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const file = c_stdio.fopen(path_z.ptr, "rb");
    if (file == null) return error.FileNotFound;
    defer _ = c_stdio.fclose(file);

    _ = c_stdio.fseek(file, 0, c_stdio.SEEK_END);
    const size = c_stdio.ftell(file);
    _ = c_stdio.fseek(file, 0, c_stdio.SEEK_SET);

    const buf = try allocator.alloc(u8, @intCast(size));
    const read_size = c_stdio.fread(buf.ptr, 1, @intCast(size), file);
    if (read_size != @as(usize, @intCast(size))) {
        allocator.free(buf);
        return error.ReadFailed;
    }
    return buf;
}

fn readU32LE(buf: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, buf[offset..][0..4], .little);
}

fn readU64LE(buf: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, buf[offset..][0..8], .little);
}

const ZkeySections = struct {
    n_vars: u32,
    n_public: u32,
    domain_size: u32,
    n8q: u32,
    points_a: []const u8,
    points_b1: []const u8,
    points_b2: []const u8,
    points_c: []const u8,
    points_h: []const u8,
};

fn parseZkey(buf: []const u8) !ZkeySections {
    if (buf.len < 12 or !std.mem.eql(u8, buf[0..4], "zkey")) {
        return error.InvalidZkey;
    }
    const version = readU32LE(buf, 4);
    _ = version;
    const n_sections = readU32LE(buf, 8);

    var sections = std.AutoHashMap(u32, struct { offset: usize, size: usize }).init(std.heap.c_allocator);
    defer sections.deinit();

    var offset: usize = 12;
    for (0..n_sections) |_| {
        if (offset + 12 > buf.len) return error.InvalidZkey;
        const s_type = readU32LE(buf, offset);
        const s_size = readU64LE(buf, offset + 4);
        offset += 12;
        if (offset + s_size > buf.len) return error.InvalidZkey;
        try sections.put(s_type, .{ .offset = offset, .size = @intCast(s_size) });
        offset += @intCast(s_size);
    }

    // Section 1: protocol
    const sec1 = sections.get(1) orelse return error.MissingSection;
    if (sec1.size < 4) return error.InvalidZkey;
    const protocol = readU32LE(buf, sec1.offset);
    if (protocol != 1) return error.NotGroth16;

    // Section 2: header
    const sec2 = sections.get(2) orelse return error.MissingSection;
    var hoff = sec2.offset;
    const n8q = readU32LE(buf, hoff);
    hoff += 4 + n8q; // skip qPrime
    const n8r = readU32LE(buf, hoff);
    hoff += 4 + n8r; // skip rPrime
    const n_vars = readU32LE(buf, hoff);
    hoff += 4;
    const n_public = readU32LE(buf, hoff);
    hoff += 4;
    const domain_size = readU32LE(buf, hoff);
    hoff += 4;
    // skip vk points
    hoff += n8q * 2; // alpha1
    hoff += n8q * 2; // beta1
    hoff += n8q * 4; // beta2
    hoff += n8q * 4; // gamma2
    hoff += n8q * 2; // delta1
    hoff += n8q * 4; // delta2

    const sec5 = sections.get(5) orelse return error.MissingSection;
    const sec6 = sections.get(6) orelse return error.MissingSection;
    const sec7 = sections.get(7) orelse return error.MissingSection;
    const sec8 = sections.get(8) orelse return error.MissingSection;
    const sec9 = sections.get(9) orelse return error.MissingSection;

    return ZkeySections{
        .n_vars = n_vars,
        .n_public = n_public,
        .domain_size = domain_size,
        .n8q = n8q,
        .points_a = buf[sec5.offset..sec5.offset + sec5.size],
        .points_b1 = buf[sec6.offset..sec6.offset + sec6.size],
        .points_b2 = buf[sec7.offset..sec7.offset + sec7.size],
        .points_c = buf[sec8.offset..sec8.offset + sec8.size],
        .points_h = buf[sec9.offset..sec9.offset + sec9.size],
    };
}

const WtnsData = struct {
    n_vars: u32,
    data: []const u8,
};

fn parseWtns(buf: []const u8) !WtnsData {
    if (buf.len < 12 or !std.mem.eql(u8, buf[0..4], "wtns")) {
        return error.InvalidWtns;
    }
    const n_sections = readU32LE(buf, 8);

    var offset: usize = 12;
    var sec1_offset: usize = 0;
    var sec1_size: usize = 0;
    var sec2_offset: usize = 0;
    var sec2_size: usize = 0;
    for (0..n_sections) |_| {
        if (offset + 12 > buf.len) return error.InvalidWtns;
        const s_type = readU32LE(buf, offset);
        const s_size = readU64LE(buf, offset + 4);
        offset += 12;
        if (s_type == 1) {
            sec1_offset = offset;
            sec1_size = @intCast(s_size);
        } else if (s_type == 2) {
            sec2_offset = offset;
            sec2_size = @intCast(s_size);
        }
        offset += @intCast(s_size);
    }
    if (sec1_offset == 0 or sec2_offset == 0) return error.MissingSection;

    // Parse header from section 1
    var soff = sec1_offset;
    if (sec1_size < 4) return error.InvalidWtns;
    const n8 = readU32LE(buf, soff);
    soff += 4 + n8;
    if (soff + 4 > sec1_offset + sec1_size) return error.InvalidWtns;
    const n_vars = readU32LE(buf, soff);

    return WtnsData{
        .n_vars = n_vars,
        .data = buf[sec2_offset..sec2_offset + sec2_size],
    };
}

// ============================================================================
// MetalProver
// ============================================================================

pub const MetalProver = struct {
    device: mtl.MTLDevice,
    command_queue: mtl.MTLCommandQueue,
    command_queue_2: mtl.MTLCommandQueue,
    command_queue_3: mtl.MTLCommandQueue,
    msm_g2_v6_bucket_reduce_pipeline: mtl.MTLComputePipelineState,
    msm_g2_v6_window_reduce_pipeline: mtl.MTLComputePipelineState,
    msm_g1_v5_bucket_reduce_pipeline: mtl.MTLComputePipelineState,
    msm_g1_v5_window_reduce_pipeline: mtl.MTLComputePipelineState,
    fft_fr_pipeline: mtl.MTLComputePipelineState,
    fft_shift_pipeline: mtl.MTLComputePipelineState,
    fft_pointwise_abc_pipeline: mtl.MTLComputePipelineState,
    fft_ifft_postprocess_pipeline: mtl.MTLComputePipelineState,
    fft_shift_simd_pipeline: mtl.MTLComputePipelineState,
    fft_pointwise_abc_simd_pipeline: mtl.MTLComputePipelineState,
    fft_tile_3buf_pipeline: mtl.MTLComputePipelineState,
    shift_3buf_pipeline: mtl.MTLComputePipelineState,
    pointwise_abc_3buf_pipeline: mtl.MTLComputePipelineState,
    // 4-step NTT pipelines
    fft_tile_1024_pipeline: mtl.MTLComputePipelineState,
    fft_tile_512_pipeline: mtl.MTLComputePipelineState,
    transpose_1024_pipeline: mtl.MTLComputePipelineState,
    twiddle_multiply_1024_pipeline: mtl.MTLComputePipelineState,
    fft_global_stage_pipeline: mtl.MTLComputePipelineState,
    fft_global_stages_batched_pipeline: mtl.MTLComputePipelineState,
    bit_reverse_pipeline: mtl.MTLComputePipelineState,
    ifft_scale_shift_pipeline: mtl.MTLComputePipelineState,
    allocator: std.mem.Allocator,
    threads_per_group: usize,
    capabilities: mod.GpuCapabilities,
    // Pre-allocated FFT buffers (size = max_fft_size, avoids per-call allocation)
    fft_a_buf: mtl.MTLBuffer,
    fft_b_buf: mtl.MTLBuffer,
    fft_c_buf: mtl.MTLBuffer,
    fft_twiddles_buf: mtl.MTLBuffer,
    fft_n_buf: mtl.MTLBuffer,
    fft_stage_buf: mtl.MTLBuffer,
    fft_num_stages_buf: mtl.MTLBuffer,
    fft_tg_buf: mtl.MTLBuffer,
    fft_g_buf: mtl.MTLBuffer,
    fft_g2_buf: mtl.MTLBuffer,
    fft_g3_buf: mtl.MTLBuffer,
    max_fft_size: u32,
    // Pre-computed twiddle caches: domain_size -> GPU buffer
    twiddle_cache_fwd: std.AutoHashMap(u32, mtl.MTLBuffer),
    twiddle_cache_inv: std.AutoHashMap(u32, mtl.MTLBuffer),
    // Pre-computed coset shift powers g^i for i=0..n-1 (g = omega_2n)
    coset_shift_cache: std.AutoHashMap(u32, mtl.MTLBuffer),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const device = mtl.createSystemDefaultDevice() orelse return error.NoMetalDevice;
        errdefer device.release();

        const command_queue = device.newCommandQueue() orelse return error.NoCommandQueue;
        errdefer command_queue.release();

        const command_queue_2 = device.newCommandQueue() orelse return error.NoCommandQueue;
        errdefer command_queue_2.release();

        const command_queue_3 = device.newCommandQueue() orelse return error.NoCommandQueue;
        errdefer command_queue_3.release();

        const source_ns = mtl.NSString.stringWithUTF8String(mod.EMBEDDED_METAL_SHADER.ptr);
        var compile_err: ?*mtl.NSError = null;
        var library = device.newLibraryWithSourceOptionsError(source_ns, null, &compile_err) orelse {
            if (compile_err) |e| {
                const desc = mtl.NSString{ .ptr = mtl.gen.NSError.NSErrorInterfaceMixin_impl.localizedDescription(e) };
                std.debug.print("Metal shader compile error: {s}\n", .{desc.UTF8String()});
            }
            return error.ShaderCompileFailed;
        };
        defer library.release();

        // msm_g2_v6 bucket reduce pipeline (sorted-bucket)
        const func_name_g2_v6_br = mtl.NSString.stringWithUTF8String("msm_g2_v6_bucket_reduce");
        var func_g2_v6_br = library.newFunctionWithName(func_name_g2_v6_br) orelse return error.FunctionNotFound;
        defer func_g2_v6_br.release();
        const msm_g2_v6_bucket_reduce_pipeline = device.newComputePipelineStateWithFunctionError(func_g2_v6_br, null) orelse {
            return error.PipelineCreationFailed;
        };

        // msm_g2_v6 window reduce pipeline
        const func_name_g2_v6_wr = mtl.NSString.stringWithUTF8String("msm_g2_v6_window_reduce");
        var func_g2_v6_wr = library.newFunctionWithName(func_name_g2_v6_wr) orelse return error.FunctionNotFound;
        defer func_g2_v6_wr.release();
        const msm_g2_v6_window_reduce_pipeline = device.newComputePipelineStateWithFunctionError(func_g2_v6_wr, null) orelse {
            return error.PipelineCreationFailed;
        };

        // msm_g1_v5 pipelines
        const func_name_v5_br = mtl.NSString.stringWithUTF8String("msm_g1_v5_bucket_reduce");
        var func_v5_br = library.newFunctionWithName(func_name_v5_br) orelse return error.FunctionNotFound;
        defer func_v5_br.release();
        const msm_g1_v5_bucket_reduce_pipeline = device.newComputePipelineStateWithFunctionError(func_v5_br, null) orelse {
            return error.PipelineCreationFailed;
        };

        const func_name_v5_wr = mtl.NSString.stringWithUTF8String("msm_g1_v5_window_reduce");
        var func_v5_wr = library.newFunctionWithName(func_name_v5_wr) orelse return error.FunctionNotFound;
        defer func_v5_wr.release();
        const msm_g1_v5_window_reduce_pipeline = device.newComputePipelineStateWithFunctionError(func_v5_wr, null) orelse {
            return error.PipelineCreationFailed;
        };

        // fft_fr pipeline
        const func_name_fft = mtl.NSString.stringWithUTF8String("fft_fr");
        var func_fft = library.newFunctionWithName(func_name_fft) orelse return error.FunctionNotFound;
        defer func_fft.release();
        const fft_fr_pipeline = device.newComputePipelineStateWithFunctionError(func_fft, null) orelse {
            return error.PipelineCreationFailed;
        };

        // fft_shift pipeline
        const func_name_shift = mtl.NSString.stringWithUTF8String("fft_shift");
        var func_shift = library.newFunctionWithName(func_name_shift) orelse return error.FunctionNotFound;
        defer func_shift.release();
        const fft_shift_pipeline = device.newComputePipelineStateWithFunctionError(func_shift, null) orelse {
            return error.PipelineCreationFailed;
        };

        // fft_pointwise_abc pipeline
        const func_name_abc = mtl.NSString.stringWithUTF8String("fft_pointwise_abc");
        var func_abc = library.newFunctionWithName(func_name_abc) orelse return error.FunctionNotFound;
        defer func_abc.release();
        const fft_pointwise_abc_pipeline = device.newComputePipelineStateWithFunctionError(func_abc, null) orelse {
            return error.PipelineCreationFailed;
        };

        // fft_ifft_postprocess pipeline
        const func_name_post = mtl.NSString.stringWithUTF8String("fft_ifft_postprocess");
        var func_post = library.newFunctionWithName(func_name_post) orelse return error.FunctionNotFound;
        defer func_post.release();
        const fft_ifft_postprocess_pipeline = device.newComputePipelineStateWithFunctionError(func_post, null) orelse {
            return error.PipelineCreationFailed;
        };

        // fft_shift_simd pipeline
        const func_name_shift_simd = mtl.NSString.stringWithUTF8String("fft_shift_simd");
        var func_shift_simd = library.newFunctionWithName(func_name_shift_simd) orelse return error.FunctionNotFound;
        defer func_shift_simd.release();
        const fft_shift_simd_pipeline = device.newComputePipelineStateWithFunctionError(func_shift_simd, null) orelse {
            return error.PipelineCreationFailed;
        };

        // fft_pointwise_abc_simd pipeline
        const func_name_abc_simd = mtl.NSString.stringWithUTF8String("fft_pointwise_abc_simd");
        var func_abc_simd = library.newFunctionWithName(func_name_abc_simd) orelse return error.FunctionNotFound;
        defer func_abc_simd.release();
        const fft_pointwise_abc_simd_pipeline = device.newComputePipelineStateWithFunctionError(func_abc_simd, null) orelse {
            return error.PipelineCreationFailed;
        };

        // fft_tile_3buf pipeline
        const func_name_fft_tile = mtl.NSString.stringWithUTF8String("fft_tile_3buf");
        var func_fft_tile = library.newFunctionWithName(func_name_fft_tile) orelse return error.FunctionNotFound;
        defer func_fft_tile.release();
        const fft_tile_3buf_pipeline = device.newComputePipelineStateWithFunctionError(func_fft_tile, null) orelse {
            return error.PipelineCreationFailed;
        };

        // shift_3buf pipeline
        const func_name_shift_3buf = mtl.NSString.stringWithUTF8String("shift_3buf");
        var func_shift_3buf = library.newFunctionWithName(func_name_shift_3buf) orelse return error.FunctionNotFound;
        defer func_shift_3buf.release();
        const shift_3buf_pipeline = device.newComputePipelineStateWithFunctionError(func_shift_3buf, null) orelse {
            return error.PipelineCreationFailed;
        };

        // pointwise_abc_3buf pipeline
        const func_name_pointwise = mtl.NSString.stringWithUTF8String("pointwise_abc_3buf");
        var func_pointwise = library.newFunctionWithName(func_name_pointwise) orelse return error.FunctionNotFound;
        defer func_pointwise.release();
        const pointwise_abc_3buf_pipeline = device.newComputePipelineStateWithFunctionError(func_pointwise, null) orelse {
            return error.PipelineCreationFailed;
        };

        // 4-step NTT pipelines
        const func_name_fft_tile_1024 = mtl.NSString.stringWithUTF8String("fft_tile_1024");
        var func_fft_tile_1024 = library.newFunctionWithName(func_name_fft_tile_1024) orelse {
            std.debug.print("Function not found: fft_tile_1024\n", .{});
            return error.FunctionNotFound;
        };
        defer func_fft_tile_1024.release();
        const fft_tile_1024_pipeline = device.newComputePipelineStateWithFunctionError(func_fft_tile_1024, null) orelse {
            return error.PipelineCreationFailed;
        };

        const func_name_fft_tile_512 = mtl.NSString.stringWithUTF8String("fft_tile_512");
        var func_fft_tile_512 = library.newFunctionWithName(func_name_fft_tile_512) orelse {
            std.debug.print("Function not found: fft_tile_512\n", .{});
            return error.FunctionNotFound;
        };
        defer func_fft_tile_512.release();
        const fft_tile_512_pipeline = device.newComputePipelineStateWithFunctionError(func_fft_tile_512, null) orelse {
            return error.PipelineCreationFailed;
        };

        const func_name_transpose = mtl.NSString.stringWithUTF8String("transpose_1024");
        var func_transpose = library.newFunctionWithName(func_name_transpose) orelse {
            std.debug.print("Function not found: transpose_1024\n", .{});
            return error.FunctionNotFound;
        };
        defer func_transpose.release();
        const transpose_1024_pipeline = device.newComputePipelineStateWithFunctionError(func_transpose, null) orelse {
            return error.PipelineCreationFailed;
        };

        const func_name_twiddle = mtl.NSString.stringWithUTF8String("twiddle_multiply_1024");
        var func_twiddle = library.newFunctionWithName(func_name_twiddle) orelse {
            std.debug.print("Function not found: twiddle_multiply_1024\n", .{});
            return error.FunctionNotFound;
        };
        defer func_twiddle.release();
        const twiddle_multiply_1024_pipeline = device.newComputePipelineStateWithFunctionError(func_twiddle, null) orelse {
            return error.PipelineCreationFailed;
        };

        const func_name_fft_global = mtl.NSString.stringWithUTF8String("fft_global_stage");
        var func_fft_global = library.newFunctionWithName(func_name_fft_global) orelse {
            std.debug.print("Function not found: fft_global_stage\n", .{});
            return error.FunctionNotFound;
        };
        defer func_fft_global.release();
        const fft_global_stage_pipeline = device.newComputePipelineStateWithFunctionError(func_fft_global, null) orelse {
            return error.PipelineCreationFailed;
        };

        const func_name_fft_global_batched = mtl.NSString.stringWithUTF8String("fft_global_stages_batched");
        var func_fft_global_batched = library.newFunctionWithName(func_name_fft_global_batched) orelse {
            std.debug.print("Function not found: fft_global_stages_batched\n", .{});
            return error.FunctionNotFound;
        };
        defer func_fft_global_batched.release();
        const fft_global_stages_batched_pipeline = device.newComputePipelineStateWithFunctionError(func_fft_global_batched, null) orelse {
            return error.PipelineCreationFailed;
        };

        const func_name_bit_reverse = mtl.NSString.stringWithUTF8String("bit_reverse");
        var func_bit_reverse = library.newFunctionWithName(func_name_bit_reverse) orelse {
            std.debug.print("Function not found: bit_reverse\n", .{});
            return error.FunctionNotFound;
        };
        defer func_bit_reverse.release();
        const bit_reverse_pipeline = device.newComputePipelineStateWithFunctionError(func_bit_reverse, null) orelse {
            return error.PipelineCreationFailed;
        };

        const func_name_ifft_scale_shift = mtl.NSString.stringWithUTF8String("ifft_scale_shift");
        var func_ifft_scale_shift = library.newFunctionWithName(func_name_ifft_scale_shift) orelse {
            std.debug.print("Function not found: ifft_scale_shift\n", .{});
            return error.FunctionNotFound;
        };
        defer func_ifft_scale_shift.release();
        const ifft_scale_shift_pipeline = device.newComputePipelineStateWithFunctionError(func_ifft_scale_shift, null) orelse {
            return error.PipelineCreationFailed;
        };

        const max_threads = msm_g1_v5_bucket_reduce_pipeline.maxTotalThreadsPerThreadgroup();
        const threads_to_use: usize = @min(256, max_threads);

        const DeviceMixin = mtl.gen.MTLDeviceProtocolMixin(mtl.gen.MTLDevice, "MTLDevice");
        const recommended_memory = DeviceMixin.recommendedMaxWorkingSetSize(device.ptr);
        const max_buffer_len = DeviceMixin.maxBufferLength(device.ptr);

        const capabilities = mod.GpuCapabilities{
            .max_threads_per_group = @intCast(threads_to_use),
            .max_buffer_size = @min(max_buffer_len, recommended_memory / 2),
            .recommended_memory = recommended_memory,
            .is_discrete = DeviceMixin.hasUnifiedMemory(device.ptr) == 0,
            .device_type = if (DeviceMixin.hasUnifiedMemory(device.ptr) != 0) .integrated else .discrete,
        };

        // Pre-allocate FFT buffers for max domain size (2^22)
        const max_fft_size: u32 = 1 << 22;
        const fr_size: usize = @sizeOf(cpu.field.FrElement);
        const max_buf_size = max_fft_size * fr_size;

        const fft_a_buf = device.newBufferWithLengthOptions(max_buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        errdefer fft_a_buf.release();
        const fft_b_buf = device.newBufferWithLengthOptions(max_buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        errdefer fft_b_buf.release();
        const fft_c_buf = device.newBufferWithLengthOptions(max_buf_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        errdefer fft_c_buf.release();
        const fft_twiddles_buf = device.newBufferWithLengthOptions(max_fft_size / 2 * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        errdefer fft_twiddles_buf.release();
        const fft_n_buf = device.newBufferWithLengthOptions(@sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        errdefer fft_n_buf.release();
        const fft_stage_buf = device.newBufferWithLengthOptions(@sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        errdefer fft_stage_buf.release();
        const fft_num_stages_buf = device.newBufferWithLengthOptions(@sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        errdefer fft_num_stages_buf.release();
        const fft_tg_buf = device.newBufferWithLengthOptions(@sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        errdefer fft_tg_buf.release();
        const fft_g_buf = device.newBufferWithLengthOptions(max_fft_size * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        errdefer fft_g_buf.release();
        const fft_g2_buf = device.newBufferWithLengthOptions(max_fft_size * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        errdefer fft_g2_buf.release();
        const fft_g3_buf = device.newBufferWithLengthOptions(max_fft_size * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        errdefer fft_g3_buf.release();

        const self = try allocator.create(Self);
        self.* = .{
            .device = device,
            .command_queue = command_queue,
            .command_queue_2 = command_queue_2,
            .command_queue_3 = command_queue_3,
            .msm_g2_v6_bucket_reduce_pipeline = msm_g2_v6_bucket_reduce_pipeline,
            .msm_g2_v6_window_reduce_pipeline = msm_g2_v6_window_reduce_pipeline,
            .msm_g1_v5_bucket_reduce_pipeline = msm_g1_v5_bucket_reduce_pipeline,
            .msm_g1_v5_window_reduce_pipeline = msm_g1_v5_window_reduce_pipeline,
            .fft_fr_pipeline = fft_fr_pipeline,
            .fft_shift_pipeline = fft_shift_pipeline,
            .fft_pointwise_abc_pipeline = fft_pointwise_abc_pipeline,
            .fft_ifft_postprocess_pipeline = fft_ifft_postprocess_pipeline,
            .fft_shift_simd_pipeline = fft_shift_simd_pipeline,
            .fft_pointwise_abc_simd_pipeline = fft_pointwise_abc_simd_pipeline,
            .fft_tile_3buf_pipeline = fft_tile_3buf_pipeline,
            .shift_3buf_pipeline = shift_3buf_pipeline,
            .pointwise_abc_3buf_pipeline = pointwise_abc_3buf_pipeline,
            .fft_tile_1024_pipeline = fft_tile_1024_pipeline,
            .fft_tile_512_pipeline = fft_tile_512_pipeline,
            .transpose_1024_pipeline = transpose_1024_pipeline,
            .twiddle_multiply_1024_pipeline = twiddle_multiply_1024_pipeline,
            .fft_global_stage_pipeline = fft_global_stage_pipeline,
            .fft_global_stages_batched_pipeline = fft_global_stages_batched_pipeline,
            .bit_reverse_pipeline = bit_reverse_pipeline,
            .ifft_scale_shift_pipeline = ifft_scale_shift_pipeline,
            .allocator = allocator,
            .threads_per_group = threads_to_use,
            .capabilities = capabilities,
            .fft_a_buf = fft_a_buf,
            .fft_b_buf = fft_b_buf,
            .fft_c_buf = fft_c_buf,
            .fft_twiddles_buf = fft_twiddles_buf,
            .fft_n_buf = fft_n_buf,
            .fft_stage_buf = fft_stage_buf,
            .fft_num_stages_buf = fft_num_stages_buf,
            .fft_tg_buf = fft_tg_buf,
            .fft_g_buf = fft_g_buf,
            .fft_g2_buf = fft_g2_buf,
            .fft_g3_buf = fft_g3_buf,
            .max_fft_size = max_fft_size,
            .twiddle_cache_fwd = std.AutoHashMap(u32, mtl.MTLBuffer).init(allocator),
            .twiddle_cache_inv = std.AutoHashMap(u32, mtl.MTLBuffer).init(allocator),
            .coset_shift_cache = std.AutoHashMap(u32, mtl.MTLBuffer).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.msm_g2_v6_bucket_reduce_pipeline.release();
        self.msm_g2_v6_window_reduce_pipeline.release();
        self.msm_g1_v5_bucket_reduce_pipeline.release();
        self.msm_g1_v5_window_reduce_pipeline.release();
        self.fft_fr_pipeline.release();
        self.fft_shift_pipeline.release();
        self.fft_pointwise_abc_pipeline.release();
        self.fft_ifft_postprocess_pipeline.release();
        self.fft_shift_simd_pipeline.release();
        self.fft_pointwise_abc_simd_pipeline.release();
        self.fft_tile_3buf_pipeline.release();
        self.shift_3buf_pipeline.release();
        self.pointwise_abc_3buf_pipeline.release();
        self.fft_tile_1024_pipeline.release();
        self.fft_tile_512_pipeline.release();
        self.transpose_1024_pipeline.release();
        self.twiddle_multiply_1024_pipeline.release();
        self.fft_global_stage_pipeline.release();
        self.fft_global_stages_batched_pipeline.release();
        self.bit_reverse_pipeline.release();
        self.ifft_scale_shift_pipeline.release();
        self.fft_c_buf.release();
        self.fft_twiddles_buf.release();
        self.fft_n_buf.release();
        self.fft_stage_buf.release();
        self.fft_num_stages_buf.release();
        self.fft_tg_buf.release();
        self.fft_g_buf.release();
        self.fft_g2_buf.release();
        self.fft_g3_buf.release();
        var fwd_it = self.twiddle_cache_fwd.iterator();
        while (fwd_it.next()) |entry| {
            entry.value_ptr.*.release();
        }
        self.twiddle_cache_fwd.deinit();
        var inv_it = self.twiddle_cache_inv.iterator();
        while (inv_it.next()) |entry| {
            entry.value_ptr.*.release();
        }
        self.twiddle_cache_inv.deinit();
        var cs_it = self.coset_shift_cache.iterator();
        while (cs_it.next()) |entry| {
            entry.value_ptr.*.release();
        }
        self.coset_shift_cache.deinit();
        self.command_queue.release();
        self.command_queue_2.release();
        self.command_queue_3.release();
        self.device.release();
        self.allocator.destroy(self);
    }

    /// Test g1_dbl on a single point. Returns the doubled point.
    pub fn testG1Dbl(
        self: *Self,
        point: []const u8,
    ) !mod.G1Point {
        var input_buffer = self.device.newBufferWithLengthOptions(
            point.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer input_buffer.release();
        var output_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(mod.G1Point),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer output_buffer.release();

        if (input_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..point.len], point);
        }

        // Get the test_g1_dbl pipeline
        const source_ns = mtl.NSString.stringWithUTF8String(mod.EMBEDDED_METAL_SHADER.ptr);
        var library = self.device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse {
            return error.ShaderCompileFailed;
        };
        defer library.release();
        const func_name = mtl.NSString.stringWithUTF8String("test_g1_dbl");
        var func = library.newFunctionWithName(func_name) orelse return error.FunctionNotFound;
        defer func.release();
        var pipeline = self.device.newComputePipelineStateWithFunctionError(func, null) orelse {
            return error.PipelineCreationFailed;
        };
        defer pipeline.release();

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(pipeline);
        encoder.setBufferOffsetAtIndex(input_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(output_buffer, 0, 1);
        const grid_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        var result: mod.G1Point = undefined;
        if (output_buffer.contents()) |ptr| {
            @memcpy(std.mem.asBytes(&result), @as([*]u8, @ptrCast(ptr))[0..@sizeOf(mod.G1Point)]);
        }
        return result;
    }

    pub const MSMJob = struct {
        points: []const u8,
        sorted: mod.SortedWindows,
    };

    /// Async handle for G1 v5 MSM batch. Owns all GPU buffers until download.
    pub const G1MsmV5AsyncHandle = struct {
        allocator: std.mem.Allocator,
        cmd_buffer: mtl.MTLCommandBuffer,
        num_jobs: usize,
        num_windows: usize,
        x_buffers: []mtl.MTLBuffer,
        y_buffers: []mtl.MTLBuffer,
        neg_y_buffers: []mtl.MTLBuffer,
        config_buffers: []mtl.MTLBuffer,
        offsets_buffers: []mtl.MTLBuffer,
        sorted_idx_buffers: []mtl.MTLBuffer,
        bucket_sums_buffers: []mtl.MTLBuffer,
        result_buffers: []mtl.MTLBuffer,

        pub fn waitUntilScheduled(self: *G1MsmV5AsyncHandle) void {
            self.cmd_buffer.waitUntilScheduled();
        }

        pub fn waitAndDownload(self: *G1MsmV5AsyncHandle) ![][]mod.G1Point {
            self.cmd_buffer.waitUntilCompleted();
            const all_results = try self.allocator.alloc([]mod.G1Point, self.num_jobs);
            for (0..self.num_jobs) |idx| {
                const results = try self.allocator.alloc(mod.G1Point, self.num_windows);
                if (self.result_buffers[idx].contents()) |ptr| {
                    const src: [*]const mod.G1Point = @ptrCast(@alignCast(ptr));
                    @memcpy(results, src[0..self.num_windows]);
                }
                all_results[idx] = results;
            }
            return all_results;
        }

        pub fn deinit(self: *G1MsmV5AsyncHandle) void {
            for (0..self.num_jobs) |idx| {
                self.x_buffers[idx].release();
                self.y_buffers[idx].release();
                self.neg_y_buffers[idx].release();
                self.config_buffers[idx].release();
                self.offsets_buffers[idx].release();
                self.sorted_idx_buffers[idx].release();
                self.bucket_sums_buffers[idx].release();
                self.result_buffers[idx].release();
            }
            self.allocator.free(self.x_buffers);
            self.allocator.free(self.y_buffers);
            self.allocator.free(self.neg_y_buffers);
            self.allocator.free(self.config_buffers);
            self.allocator.free(self.offsets_buffers);
            self.allocator.free(self.sorted_idx_buffers);
            self.allocator.free(self.bucket_sums_buffers);
            self.allocator.free(self.result_buffers);
            // Command buffers are auto-released by Metal; do not call release()
        }
    };

    /// Async handle for G2 v6 MSM.
    pub const G2MsmV6AsyncHandle = struct {
        allocator: std.mem.Allocator,
        cmd_buffer: mtl.MTLCommandBuffer,
        n_windows: usize,
        x_c0_buffer: mtl.MTLBuffer,
        x_c1_buffer: mtl.MTLBuffer,
        y_c0_buffer: mtl.MTLBuffer,
        y_c1_buffer: mtl.MTLBuffer,
        neg_y_c0_buffer: mtl.MTLBuffer,
        neg_y_c1_buffer: mtl.MTLBuffer,
        config_buffer: mtl.MTLBuffer,
        offsets_buffer: mtl.MTLBuffer,
        sorted_idx_buffer: mtl.MTLBuffer,
        bucket_sums_buffer: mtl.MTLBuffer,
        result_buffer: mtl.MTLBuffer,

        pub fn waitAndDownload(self: *G2MsmV6AsyncHandle) ![]mod.G2Point {
            self.cmd_buffer.waitUntilCompleted();
            const results = try self.allocator.alloc(mod.G2Point, self.n_windows);
            if (self.result_buffer.contents()) |ptr| {
                const src: [*]const mod.G2Point = @ptrCast(@alignCast(ptr));
                @memcpy(results, src[0..self.n_windows]);
            }
            return results;
        }

        pub fn deinit(self: *G2MsmV6AsyncHandle) void {
            self.x_c0_buffer.release();
            self.x_c1_buffer.release();
            self.y_c0_buffer.release();
            self.y_c1_buffer.release();
            self.neg_y_c0_buffer.release();
            self.neg_y_c1_buffer.release();
            self.config_buffer.release();
            self.offsets_buffer.release();
            self.sorted_idx_buffer.release();
            self.bucket_sums_buffer.release();
            self.result_buffer.release();
            // Command buffers are auto-released by Metal; do not call release()
        }
    };

    // Async handle for G1 MSM — v5 only (simplified, used for all circuit sizes)
    pub const G1MsmAsyncHandle = G1MsmV5AsyncHandle;

    fn createBuffer(self: *Self, len: usize, name: []const u8) !mtl.MTLBuffer {
        const buf = self.device.newBufferWithLengthOptions(
            len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse {
            std.debug.print("BufferCreationFailed: {s} size={d} bytes\n", .{ name, len });
            return error.BufferCreationFailed;
        };
        return buf;
    }

    /// Async batched v5 MSM: dispatches but does NOT wait.
    pub fn msmG1_v5_batch_async(
        self: *Self,
        jobs: []const MSMJob,
        queue: mtl.MTLCommandQueue,
    ) !G1MsmV5AsyncHandle {
        const num_windows: usize = 32;
        const num_buckets: usize = 256;
        const threads_per_bucket: usize = 64;
        const fq_size = @sizeOf([4]u64); // 32 bytes per FqElement

        // Allocate per-job SoA buffers (ownership transferred to handle)
        const x_buffers = try self.allocator.alloc(mtl.MTLBuffer, jobs.len);
        const y_buffers = try self.allocator.alloc(mtl.MTLBuffer, jobs.len);
        const neg_y_buffers = try self.allocator.alloc(mtl.MTLBuffer, jobs.len);
        const config_buffers = try self.allocator.alloc(mtl.MTLBuffer, jobs.len);
        const offsets_buffers = try self.allocator.alloc(mtl.MTLBuffer, jobs.len);
        const sorted_idx_buffers = try self.allocator.alloc(mtl.MTLBuffer, jobs.len);
        const bucket_sums_buffers = try self.allocator.alloc(mtl.MTLBuffer, jobs.len);
        const result_buffers = try self.allocator.alloc(mtl.MTLBuffer, jobs.len);

        errdefer {
            // Free arrays on error (individual GPU buffers may leak, but errors are fatal)
            self.allocator.free(x_buffers);
            self.allocator.free(y_buffers);
            self.allocator.free(neg_y_buffers);
            self.allocator.free(config_buffers);
            self.allocator.free(offsets_buffers);
            self.allocator.free(sorted_idx_buffers);
            self.allocator.free(bucket_sums_buffers);
            self.allocator.free(result_buffers);
        }

        // Create and populate all buffers
        for (jobs, 0..) |job, idx| {
            const n_points = job.points.len / @sizeOf(mod.G1PointAffine);
            const coord_size = n_points * fq_size;

            x_buffers[idx] = try self.createBuffer(coord_size, "x");
            y_buffers[idx] = try self.createBuffer(coord_size, "y");
            neg_y_buffers[idx] = try self.createBuffer(coord_size, "neg_y");

            // Transpose AoS -> SoA straight into the Metal buffers.
            const x_dst = @as([*]u8, @ptrCast(x_buffers[idx].contents().?))[0..coord_size];
            const y_dst = @as([*]u8, @ptrCast(y_buffers[idx].contents().?))[0..coord_size];
            const neg_y_dst = @as([*]u8, @ptrCast(neg_y_buffers[idx].contents().?))[0..coord_size];
            const points_typed = std.mem.bytesAsSlice(cpu.curve.G1PointAffine, job.points);
            for (0..n_points) |i| {
                const src = i * @sizeOf(mod.G1PointAffine);
                const dst = i * fq_size;
                @memcpy(x_dst[dst..][0..fq_size], job.points[src + 0 * fq_size ..][0..fq_size]);
                @memcpy(y_dst[dst..][0..fq_size], job.points[src + 1 * fq_size ..][0..fq_size]);
                const neg_y_val = cpu.field.fq_neg(points_typed[i].y);
                @memcpy(neg_y_dst[dst..][0..fq_size], std.mem.asBytes(&neg_y_val));
            }

            const config = mod.MSMConfig{
                .n_points = @intCast(job.points.len / 64),
                .n_windows = @intCast(num_windows),
                .window_size = 8,
                .n_buckets = @intCast(num_buckets),
            };
            config_buffers[idx] = try self.createBuffer(@sizeOf(mod.MSMConfig), "config");

            const offsets_size = job.sorted.bucket_offsets.len * @sizeOf(u32);
            offsets_buffers[idx] = try self.createBuffer(offsets_size, "offsets");

            const sorted_idx_size = job.sorted.sorted_indices.len * @sizeOf(u32);
            sorted_idx_buffers[idx] = try self.createBuffer(sorted_idx_size, "sorted_idx");

            const bucket_sums_size = num_windows * num_buckets * @sizeOf(mod.G1Point);
            bucket_sums_buffers[idx] = try self.createBuffer(bucket_sums_size, "bucket_sums");

            const result_size = num_windows * @sizeOf(mod.G1Point);
            result_buffers[idx] = try self.createBuffer(result_size, "result");

            if (config_buffers[idx].contents()) |ptr| {
                @as(*mod.MSMConfig, @ptrCast(@alignCast(ptr))).* = config;
            }
            if (offsets_buffers[idx].contents()) |ptr| {
                @memcpy(@as([*]u8, @ptrCast(ptr))[0..offsets_size], std.mem.sliceAsBytes(job.sorted.bucket_offsets));
            }
            if (sorted_idx_buffers[idx].contents()) |ptr| {
                @memcpy(@as([*]u8, @ptrCast(ptr))[0..sorted_idx_size], std.mem.sliceAsBytes(job.sorted.sorted_indices));
            }
        }

        // Single command buffer and single encoder for all G1 MSM dispatches
        var cmd_buffer = queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;

        // All bucket reduce passes first
        for (jobs, 0..) |_, idx| {
            encoder.setComputePipelineState(self.msm_g1_v5_bucket_reduce_pipeline);
            encoder.setBufferOffsetAtIndex(x_buffers[idx], 0, 0);
            encoder.setBufferOffsetAtIndex(y_buffers[idx], 0, 1);
            encoder.setBufferOffsetAtIndex(neg_y_buffers[idx], 0, 2);
            encoder.setBufferOffsetAtIndex(config_buffers[idx], 0, 3);
            encoder.setBufferOffsetAtIndex(offsets_buffers[idx], 0, 4);
            encoder.setBufferOffsetAtIndex(sorted_idx_buffers[idx], 0, 5);
            encoder.setBufferOffsetAtIndex(bucket_sums_buffers[idx], 0, 6);
            const total_threads = num_windows * num_buckets * threads_per_bucket;
            const grid_size = mtl.MTLSize{ .width = total_threads, .height = 1, .depth = 1 };
            const threadgroup_size = mtl.MTLSize{ .width = threads_per_bucket, .height = 1, .depth = 1 };
            encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        }

        // All window reduce passes
        for (jobs, 0..) |_, idx| {
            encoder.setComputePipelineState(self.msm_g1_v5_window_reduce_pipeline);
            encoder.setBufferOffsetAtIndex(bucket_sums_buffers[idx], 0, 0);
            encoder.setBufferOffsetAtIndex(result_buffers[idx], 0, 1);
            const grid_size = mtl.MTLSize{ .width = num_windows, .height = 1, .depth = 1 };
            const threadgroup_size = mtl.MTLSize{ .width = @min(self.threads_per_group, num_windows), .height = 1, .depth = 1 };
            encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        }

        encoder.endEncoding();
        cmd_buffer.commit();

        return G1MsmV5AsyncHandle{
            .allocator = self.allocator,
            .cmd_buffer = cmd_buffer,
            .num_jobs = jobs.len,
            .num_windows = num_windows,
            .x_buffers = x_buffers,
            .y_buffers = y_buffers,
            .neg_y_buffers = neg_y_buffers,
            .config_buffers = config_buffers,
            .offsets_buffers = offsets_buffers,
            .sorted_idx_buffers = sorted_idx_buffers,
            .bucket_sums_buffers = bucket_sums_buffers,
            .result_buffers = result_buffers,
        };
    }

    /// Batched v5 MSM: run multiple G1 MSMs in a single command buffer.
    /// Uses SoA layout (x, y, neg_y) for better GPU memory coalescing.
    pub fn msmG1_v5_batch(
        self: *Self,
        jobs: []const MSMJob,
        queue: mtl.MTLCommandQueue,
    ) ![][]mod.G1Point {
        var handle = try self.msmG1_v5_batch_async(jobs, queue);
        defer handle.deinit();
        return try handle.waitAndDownload();
    }

    /// Optimized v5 MSM using sorted-bucket preprocessing.
    /// Uses SoA layout (x, y, neg_y) for better GPU memory coalescing.
    /// `sorted` must be the output of `mod.preprocessSortedWindows()`.
    pub fn msmG1_v5(
        self: *Self,
        points: []const u8,
        sorted: mod.SortedWindows,
    ) ![]mod.G1Point {
        const num_windows: usize = 32;
        const num_buckets: usize = 256;
        const fq_size = @sizeOf([4]u64); // 32 bytes per FqElement
        const n_points = points.len / @sizeOf(mod.G1PointAffine);
        const coord_size = n_points * fq_size;

        // Transpose AoS -> SoA on CPU
        const x_data = try self.allocator.alloc(u8, coord_size);
        defer self.allocator.free(x_data);
        const y_data = try self.allocator.alloc(u8, coord_size);
        defer self.allocator.free(y_data);
        const neg_y_data = try self.allocator.alloc(u8, coord_size);
        defer self.allocator.free(neg_y_data);

        const points_typed = std.mem.bytesAsSlice(cpu.curve.G1PointAffine, points);
        for (0..n_points) |i| {
            const src = i * @sizeOf(mod.G1PointAffine);
            const dst = i * fq_size;
            @memcpy(x_data[dst..][0..fq_size], points[src + 0 * fq_size ..][0..fq_size]);
            @memcpy(y_data[dst..][0..fq_size], points[src + 1 * fq_size ..][0..fq_size]);
            const neg_y_val = cpu.field.fq_neg(points_typed[i].y);
            @memcpy(neg_y_data[dst..][0..fq_size], std.mem.asBytes(&neg_y_val));
        }

        var x_buffer = self.device.newBufferWithLengthOptions(
            coord_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer x_buffer.release();

        var y_buffer = self.device.newBufferWithLengthOptions(
            coord_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer y_buffer.release();

        var neg_y_buffer = self.device.newBufferWithLengthOptions(
            coord_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer neg_y_buffer.release();

        const config = mod.MSMConfig{
            .n_points = @intCast(points.len / 64),
            .n_windows = @intCast(num_windows),
            .window_size = 8,
            .n_buckets = @intCast(num_buckets),
        };
        var config_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(mod.MSMConfig),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer config_buffer.release();

        const offsets_size = sorted.bucket_offsets.len * @sizeOf(u32);
        var offsets_buffer = self.device.newBufferWithLengthOptions(
            offsets_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer offsets_buffer.release();

        const sorted_idx_size = sorted.sorted_indices.len * @sizeOf(u32);
        var sorted_idx_buffer = self.device.newBufferWithLengthOptions(
            sorted_idx_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer sorted_idx_buffer.release();

        const bucket_sums_size = num_windows * num_buckets * @sizeOf(mod.G1Point);
        var bucket_sums_buffer = self.device.newBufferWithLengthOptions(
            bucket_sums_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer bucket_sums_buffer.release();

        const result_size = num_windows * @sizeOf(mod.G1Point);
        var result_buffer = self.device.newBufferWithLengthOptions(
            result_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer result_buffer.release();

        if (x_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..coord_size], x_data);
        }
        if (y_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..coord_size], y_data);
        }
        if (neg_y_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..coord_size], neg_y_data);
        }
        if (config_buffer.contents()) |ptr| {
            @as(*mod.MSMConfig, @ptrCast(@alignCast(ptr))).* = config;
        }
        if (offsets_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..offsets_size], std.mem.sliceAsBytes(sorted.bucket_offsets));
        }
        if (sorted_idx_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..sorted_idx_size], std.mem.sliceAsBytes(sorted.sorted_indices));
        }

        // Pass 1+2: Bucket reduce + Window reduce in single command buffer
        {
        const threads_per_bucket: usize = 64;
            var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;

            // Pass 1: Bucket reduce — 64 threads per bucket (524288 threads)
            {
                var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
                encoder.setComputePipelineState(self.msm_g1_v5_bucket_reduce_pipeline);
                encoder.setBufferOffsetAtIndex(x_buffer, 0, 0);
                encoder.setBufferOffsetAtIndex(y_buffer, 0, 1);
                encoder.setBufferOffsetAtIndex(neg_y_buffer, 0, 2);
                encoder.setBufferOffsetAtIndex(config_buffer, 0, 3);
                encoder.setBufferOffsetAtIndex(offsets_buffer, 0, 4);
                encoder.setBufferOffsetAtIndex(sorted_idx_buffer, 0, 5);
                encoder.setBufferOffsetAtIndex(bucket_sums_buffer, 0, 6);
                const total_threads = num_windows * num_buckets * threads_per_bucket;
                const grid_size = mtl.MTLSize{ .width = total_threads, .height = 1, .depth = 1 };
                const threadgroup_size = mtl.MTLSize{ .width = threads_per_bucket, .height = 1, .depth = 1 };
                encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
                encoder.endEncoding();
            }

            // Pass 2: Window reduce — one thread per window (32 threads)
            {
                var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
                encoder.setComputePipelineState(self.msm_g1_v5_window_reduce_pipeline);
                encoder.setBufferOffsetAtIndex(bucket_sums_buffer, 0, 0);
                encoder.setBufferOffsetAtIndex(result_buffer, 0, 1);
                const grid_size = mtl.MTLSize{ .width = num_windows, .height = 1, .depth = 1 };
                const threadgroup_size = mtl.MTLSize{ .width = @min(self.threads_per_group, num_windows), .height = 1, .depth = 1 };
                encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
                encoder.endEncoding();
            }

            cmd_buffer.commit();
            cmd_buffer.waitUntilCompleted();
        }

        const results = try self.allocator.alloc(mod.G1Point, num_windows);
        if (result_buffer.contents()) |ptr| {
            const src: [*]const mod.G1Point = @ptrCast(@alignCast(ptr));
            @memcpy(results, src[0..num_windows]);
        }
        return results;
    }

    /// Test a single field operation (kernel name, 2 inputs, 1 output). Returns the FqElement result.
    pub fn testFqOp(
        self: *Self,
        kernel_name: [*c]const u8,
        a: [4]u64,
        b: [4]u64,
    ) ![4]u64 {
        var a_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf([4]u64),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer a_buffer.release();
        var b_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf([4]u64),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer b_buffer.release();
        var out_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf([4]u64),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer out_buffer.release();

        if (a_buffer.contents()) |ptr| {
            @as(*[4]u64, @ptrCast(@alignCast(ptr))).* = a;
        }
        if (b_buffer.contents()) |ptr| {
            @as(*[4]u64, @ptrCast(@alignCast(ptr))).* = b;
        }

        const source_ns = mtl.NSString.stringWithUTF8String(mod.EMBEDDED_METAL_SHADER.ptr);
        var library = self.device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse {
            return error.ShaderCompileFailed;
        };
        defer library.release();
        const func_name = mtl.NSString.stringWithUTF8String(kernel_name);
        var func = library.newFunctionWithName(func_name) orelse return error.FunctionNotFound;
        defer func.release();
        var pipeline = self.device.newComputePipelineStateWithFunctionError(func, null) orelse {
            return error.PipelineCreationFailed;
        };
        defer pipeline.release();

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(pipeline);
        encoder.setBufferOffsetAtIndex(a_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(b_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(out_buffer, 0, 2);
        const grid_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        var result: [4]u64 = undefined;
        if (out_buffer.contents()) |ptr| {
            result = @as(*const [4]u64, @ptrCast(@alignCast(ptr))).*;
        }
        return result;
    }

    /// Test g1_add on two affine points. Returns the G1Point result.
    pub fn testG1AddAffine(
        self: *Self,
        a: []const u8,
        b: []const u8,
    ) !mod.G1Point {
        var a_buffer = self.device.newBufferWithLengthOptions(
            a.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer a_buffer.release();
        var b_buffer = self.device.newBufferWithLengthOptions(
            b.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer b_buffer.release();
        var out_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(mod.G1Point),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer out_buffer.release();

        if (a_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..a.len], a);
        }
        if (b_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..b.len], b);
        }

        const source_ns = mtl.NSString.stringWithUTF8String(mod.EMBEDDED_METAL_SHADER.ptr);
        var library = self.device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse {
            return error.ShaderCompileFailed;
        };
        defer library.release();
        const func_name = mtl.NSString.stringWithUTF8String("test_g1_add_affine");
        var func = library.newFunctionWithName(func_name) orelse return error.FunctionNotFound;
        defer func.release();
        var pipeline = self.device.newComputePipelineStateWithFunctionError(func, null) orelse {
            return error.PipelineCreationFailed;
        };
        defer pipeline.release();

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(pipeline);
        encoder.setBufferOffsetAtIndex(a_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(b_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(out_buffer, 0, 2);
        const grid_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        var result: mod.G1Point = undefined;
        if (out_buffer.contents()) |ptr| {
            result = @as(*const mod.G1Point, @ptrCast(@alignCast(ptr))).*;
        }
        return result;
    }

    /// Perform MSM on G2 points using v5 multi-thread per bucket.
    /// Returns an array of window results (caller must free).
    /// Perform MSM on G2 points using v6 sorted-bucket Pippenger with SoA layout.
    /// Points are transposed from AoS to SoA on the CPU before upload for better
    /// GPU memory coalescing.
    /// `sorted` must be the output of `mod.preprocessSortedWindows()` with
    /// signed-digit bucket mapping (positive 0..127, negative 128..255).
    /// `negated_points` must be the CPU-pre-negated counterpart of `points`.
    pub fn msmG2_v6(
        self: *Self,
        points: []const u8,
        negated_points: []const u8,
        sorted: mod.SortedWindows,
        config: mod.MSMConfig,
    ) ![]mod.G2Point {
        const n_windows = config.n_windows;
        const n_buckets: usize = @intCast(config.n_buckets);
        const threads_per_bucket: usize = 64;

        const n_points = points.len / @sizeOf(mod.G2PointAffine);
        const fq_size = @sizeOf([4]u64); // 32 bytes (FqElement)

        // Transpose AoS -> SoA on CPU (positive points)
        const x_c0 = try self.allocator.alloc(u8, n_points * fq_size);
        defer self.allocator.free(x_c0);
        const x_c1 = try self.allocator.alloc(u8, n_points * fq_size);
        defer self.allocator.free(x_c1);
        const y_c0 = try self.allocator.alloc(u8, n_points * fq_size);
        defer self.allocator.free(y_c0);
        const y_c1 = try self.allocator.alloc(u8, n_points * fq_size);
        defer self.allocator.free(y_c1);

        // Transpose negated points y only (x is shared)
        const neg_y_c0 = try self.allocator.alloc(u8, n_points * fq_size);
        defer self.allocator.free(neg_y_c0);
        const neg_y_c1 = try self.allocator.alloc(u8, n_points * fq_size);
        defer self.allocator.free(neg_y_c1);

        for (0..n_points) |i| {
            const pos_src = i * @sizeOf(mod.G2PointAffine);
            const neg_src = i * @sizeOf(mod.G2PointAffine);
            const dst_offset = i * fq_size;
            @memcpy(x_c0[dst_offset..][0..fq_size], points[pos_src + 0 * fq_size ..][0..fq_size]);
            @memcpy(x_c1[dst_offset..][0..fq_size], points[pos_src + 1 * fq_size ..][0..fq_size]);
            @memcpy(y_c0[dst_offset..][0..fq_size], points[pos_src + 2 * fq_size ..][0..fq_size]);
            @memcpy(y_c1[dst_offset..][0..fq_size], points[pos_src + 3 * fq_size ..][0..fq_size]);
            @memcpy(neg_y_c0[dst_offset..][0..fq_size], negated_points[neg_src + 2 * fq_size ..][0..fq_size]);
            @memcpy(neg_y_c1[dst_offset..][0..fq_size], negated_points[neg_src + 3 * fq_size ..][0..fq_size]);
        }

        var x_c0_buffer = self.device.newBufferWithLengthOptions(
            x_c0.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer x_c0_buffer.release();

        var x_c1_buffer = self.device.newBufferWithLengthOptions(
            x_c1.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer x_c1_buffer.release();

        var y_c0_buffer = self.device.newBufferWithLengthOptions(
            y_c0.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer y_c0_buffer.release();

        var y_c1_buffer = self.device.newBufferWithLengthOptions(
            y_c1.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer y_c1_buffer.release();

        var neg_y_c0_buffer = self.device.newBufferWithLengthOptions(
            neg_y_c0.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer neg_y_c0_buffer.release();

        var neg_y_c1_buffer = self.device.newBufferWithLengthOptions(
            neg_y_c1.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer neg_y_c1_buffer.release();

        var config_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(mod.MSMConfig),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer config_buffer.release();

        const offsets_size = sorted.bucket_offsets.len * @sizeOf(u32);
        var offsets_buffer = self.device.newBufferWithLengthOptions(
            offsets_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer offsets_buffer.release();

        const sorted_idx_size = sorted.sorted_indices.len * @sizeOf(u32);
        var sorted_idx_buffer = self.device.newBufferWithLengthOptions(
            sorted_idx_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer sorted_idx_buffer.release();

        const bucket_sums_size = n_windows * n_buckets * @sizeOf(mod.G2Point);
        var bucket_sums_buffer = self.device.newBufferWithLengthOptions(
            bucket_sums_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer bucket_sums_buffer.release();

        const result_size = n_windows * @sizeOf(mod.G2Point);
        var result_buffer = self.device.newBufferWithLengthOptions(
            result_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer result_buffer.release();

        if (x_c0_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..x_c0.len], x_c0);
        }
        if (x_c1_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..x_c1.len], x_c1);
        }
        if (y_c0_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..y_c0.len], y_c0);
        }
        if (y_c1_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..y_c1.len], y_c1);
        }
        if (neg_y_c0_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..neg_y_c0.len], neg_y_c0);
        }
        if (neg_y_c1_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..neg_y_c1.len], neg_y_c1);
        }
        if (config_buffer.contents()) |ptr| {
            @as(*mod.MSMConfig, @ptrCast(@alignCast(ptr))).* = config;
        }
        if (offsets_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..offsets_size], std.mem.sliceAsBytes(sorted.bucket_offsets));
        }
        if (sorted_idx_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..sorted_idx_size], std.mem.sliceAsBytes(sorted.sorted_indices));
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;

        // Pass 1: Bucket reduce (SoA)
        {
            var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
            encoder.setComputePipelineState(self.msm_g2_v6_bucket_reduce_pipeline);
            encoder.setBufferOffsetAtIndex(x_c0_buffer, 0, 0);
            encoder.setBufferOffsetAtIndex(x_c1_buffer, 0, 1);
            encoder.setBufferOffsetAtIndex(y_c0_buffer, 0, 2);
            encoder.setBufferOffsetAtIndex(y_c1_buffer, 0, 3);
            encoder.setBufferOffsetAtIndex(config_buffer, 0, 4);
            encoder.setBufferOffsetAtIndex(offsets_buffer, 0, 5);
            encoder.setBufferOffsetAtIndex(sorted_idx_buffer, 0, 6);
            encoder.setBufferOffsetAtIndex(bucket_sums_buffer, 0, 7);
            encoder.setBufferOffsetAtIndex(neg_y_c0_buffer, 0, 8);
            encoder.setBufferOffsetAtIndex(neg_y_c1_buffer, 0, 9);
            const total_threads = n_windows * n_buckets * threads_per_bucket;
            const grid_size = mtl.MTLSize{ .width = total_threads, .height = 1, .depth = 1 };
            const threadgroup_size = mtl.MTLSize{ .width = threads_per_bucket, .height = 1, .depth = 1 };
            encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
            encoder.endEncoding();
        }

        // Pass 2: Window reduce
        {
            var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
            encoder.setComputePipelineState(self.msm_g2_v6_window_reduce_pipeline);
            encoder.setBufferOffsetAtIndex(bucket_sums_buffer, 0, 0);
            encoder.setBufferOffsetAtIndex(config_buffer, 0, 1);
            encoder.setBufferOffsetAtIndex(result_buffer, 0, 2);
            const grid_size = mtl.MTLSize{ .width = n_windows, .height = 1, .depth = 1 };
            const threadgroup_size = mtl.MTLSize{ .width = @min(self.threads_per_group, n_windows), .height = 1, .depth = 1 };
            encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
            encoder.endEncoding();
        }

        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        const results = try self.allocator.alloc(mod.G2Point, n_windows);
        if (result_buffer.contents()) |ptr| {
            const src: [*]const mod.G2Point = @ptrCast(@alignCast(ptr));
            @memcpy(results, src[0..n_windows]);
        }
        return results;
    }

    /// Async G2 v6 SoA MSM: dispatches but does NOT wait.
    pub fn msmG2_v6_soA_async(
        self: *Self,
        x_c0: []const u8,
        x_c1: []const u8,
        y_c0: []const u8,
        y_c1: []const u8,
        neg_y_c0: []const u8,
        neg_y_c1: []const u8,
        sorted: mod.SortedWindows,
        config: mod.MSMConfig,
        queue: mtl.MTLCommandQueue,
    ) !G2MsmV6AsyncHandle {
        const n_windows = config.n_windows;
        const n_buckets: usize = @intCast(config.n_buckets);
        const threads_per_bucket: usize = 64;

        var x_c0_buffer = self.device.newBufferWithLengthOptions(
            x_c0.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        errdefer x_c0_buffer.release();

        var x_c1_buffer = self.device.newBufferWithLengthOptions(
            x_c1.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        errdefer x_c1_buffer.release();

        var y_c0_buffer = self.device.newBufferWithLengthOptions(
            y_c0.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        errdefer y_c0_buffer.release();

        var y_c1_buffer = self.device.newBufferWithLengthOptions(
            y_c1.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        errdefer y_c1_buffer.release();

        var neg_y_c0_buffer = self.device.newBufferWithLengthOptions(
            neg_y_c0.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        errdefer neg_y_c0_buffer.release();

        var neg_y_c1_buffer = self.device.newBufferWithLengthOptions(
            neg_y_c1.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        errdefer neg_y_c1_buffer.release();

        var config_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(mod.MSMConfig),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        errdefer config_buffer.release();

        const offsets_size = sorted.bucket_offsets.len * @sizeOf(u32);
        var offsets_buffer = self.device.newBufferWithLengthOptions(
            offsets_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        errdefer offsets_buffer.release();

        const sorted_idx_size = sorted.sorted_indices.len * @sizeOf(u32);
        var sorted_idx_buffer = self.device.newBufferWithLengthOptions(
            sorted_idx_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        errdefer sorted_idx_buffer.release();

        const bucket_sums_size = n_windows * n_buckets * @sizeOf(mod.G2Point);
        var bucket_sums_buffer = self.device.newBufferWithLengthOptions(
            bucket_sums_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        errdefer bucket_sums_buffer.release();

        const result_size = n_windows * @sizeOf(mod.G2Point);
        var result_buffer = self.device.newBufferWithLengthOptions(
            result_size,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        errdefer result_buffer.release();

        if (x_c0_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..x_c0.len], x_c0);
        }
        if (x_c1_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..x_c1.len], x_c1);
        }
        if (y_c0_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..y_c0.len], y_c0);
        }
        if (y_c1_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..y_c1.len], y_c1);
        }
        if (neg_y_c0_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..neg_y_c0.len], neg_y_c0);
        }
        if (neg_y_c1_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..neg_y_c1.len], neg_y_c1);
        }
        if (config_buffer.contents()) |ptr| {
            @as(*mod.MSMConfig, @ptrCast(@alignCast(ptr))).* = config;
        }
        if (offsets_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..offsets_size], std.mem.sliceAsBytes(sorted.bucket_offsets));
        }
        if (sorted_idx_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..sorted_idx_size], std.mem.sliceAsBytes(sorted.sorted_indices));
        }

        var cmd_buffer = queue.commandBuffer() orelse return error.CommandBufferFailed;

        // Pass 1: Bucket reduce (SoA)
        {
            var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
            encoder.setComputePipelineState(self.msm_g2_v6_bucket_reduce_pipeline);
            encoder.setBufferOffsetAtIndex(x_c0_buffer, 0, 0);
            encoder.setBufferOffsetAtIndex(x_c1_buffer, 0, 1);
            encoder.setBufferOffsetAtIndex(y_c0_buffer, 0, 2);
            encoder.setBufferOffsetAtIndex(y_c1_buffer, 0, 3);
            encoder.setBufferOffsetAtIndex(config_buffer, 0, 4);
            encoder.setBufferOffsetAtIndex(offsets_buffer, 0, 5);
            encoder.setBufferOffsetAtIndex(sorted_idx_buffer, 0, 6);
            encoder.setBufferOffsetAtIndex(bucket_sums_buffer, 0, 7);
            encoder.setBufferOffsetAtIndex(neg_y_c0_buffer, 0, 8);
            encoder.setBufferOffsetAtIndex(neg_y_c1_buffer, 0, 9);
            const total_threads = n_windows * n_buckets * threads_per_bucket;
            const grid_size = mtl.MTLSize{ .width = total_threads, .height = 1, .depth = 1 };
            const threadgroup_size = mtl.MTLSize{ .width = threads_per_bucket, .height = 1, .depth = 1 };
            encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
            encoder.endEncoding();
        }

        // Pass 2: Window reduce
        {
            var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
            encoder.setComputePipelineState(self.msm_g2_v6_window_reduce_pipeline);
            encoder.setBufferOffsetAtIndex(bucket_sums_buffer, 0, 0);
            encoder.setBufferOffsetAtIndex(config_buffer, 0, 1);
            encoder.setBufferOffsetAtIndex(result_buffer, 0, 2);
            const grid_size = mtl.MTLSize{ .width = n_windows, .height = 1, .depth = 1 };
            const threadgroup_size = mtl.MTLSize{ .width = @min(self.threads_per_group, n_windows), .height = 1, .depth = 1 };
            encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
            encoder.endEncoding();
        }

        cmd_buffer.commit();

        return G2MsmV6AsyncHandle{
            .allocator = self.allocator,
            .cmd_buffer = cmd_buffer,
            .n_windows = @intCast(n_windows),
            .x_c0_buffer = x_c0_buffer,
            .x_c1_buffer = x_c1_buffer,
            .y_c0_buffer = y_c0_buffer,
            .y_c1_buffer = y_c1_buffer,
            .neg_y_c0_buffer = neg_y_c0_buffer,
            .neg_y_c1_buffer = neg_y_c1_buffer,
            .config_buffer = config_buffer,
            .offsets_buffer = offsets_buffer,
            .sorted_idx_buffer = sorted_idx_buffer,
            .bucket_sums_buffer = bucket_sums_buffer,
            .result_buffer = result_buffer,
        };
    }

    /// Perform MSM on G2 points using v6 sorted-bucket Pippenger with pre-transposed SoA layout.
    /// `x_c0`, `x_c1`, `y_c0`, `y_c1`, `neg_y_c0`, `neg_y_c1` must be pre-transposed SoA buffers.
    pub fn msmG2_v6_soA(
        self: *Self,
        x_c0: []const u8,
        x_c1: []const u8,
        y_c0: []const u8,
        y_c1: []const u8,
        neg_y_c0: []const u8,
        neg_y_c1: []const u8,
        sorted: mod.SortedWindows,
        config: mod.MSMConfig,
        queue: mtl.MTLCommandQueue,
    ) ![]mod.G2Point {
        var handle = try self.msmG2_v6_soA_async(x_c0, x_c1, y_c0, y_c1, neg_y_c0, neg_y_c1, sorted, config, queue);
        defer handle.deinit();
        return try handle.waitAndDownload();
    }

    /// Test g2_affine_to_projective on an affine point.
    pub fn testG2Affine(
        self: *Self,
        a: []const u8,
    ) !mod.G2Point {
        var a_buffer = self.device.newBufferWithLengthOptions(
            a.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer a_buffer.release();
        var out_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(mod.G2Point),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer out_buffer.release();

        if (a_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..a.len], a);
        }

        const source_ns = mtl.NSString.stringWithUTF8String(mod.EMBEDDED_METAL_SHADER.ptr);
        var library = self.device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse {
            return error.ShaderCompileFailed;
        };
        defer library.release();
        const func_name = mtl.NSString.stringWithUTF8String("test_g2_affine");
        var func = library.newFunctionWithName(func_name) orelse return error.FunctionNotFound;
        defer func.release();
        var pipeline = self.device.newComputePipelineStateWithFunctionError(func, null) orelse {
            return error.PipelineCreationFailed;
        };
        defer pipeline.release();

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(pipeline);
        encoder.setBufferOffsetAtIndex(a_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(out_buffer, 0, 1);
        const grid_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        var result: mod.G2Point = undefined;
        if (out_buffer.contents()) |ptr| {
            result = @as(*const mod.G2Point, @ptrCast(@alignCast(ptr))).*;
        }
        return result;
    }

    /// Test g2_dbl on an affine point using the test kernel.
    pub fn testG2Dbl(
        self: *Self,
        a: []const u8,
    ) !mod.G2Point {
        var a_buffer = self.device.newBufferWithLengthOptions(
            a.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer a_buffer.release();
        var out_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(mod.G2Point),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer out_buffer.release();

        if (a_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..a.len], a);
        }

        const source_ns = mtl.NSString.stringWithUTF8String(mod.EMBEDDED_METAL_SHADER.ptr);
        var library = self.device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse {
            return error.ShaderCompileFailed;
        };
        defer library.release();
        const func_name = mtl.NSString.stringWithUTF8String("test_g2_dbl");
        var func = library.newFunctionWithName(func_name) orelse return error.FunctionNotFound;
        defer func.release();
        var pipeline = self.device.newComputePipelineStateWithFunctionError(func, null) orelse {
            return error.PipelineCreationFailed;
        };
        defer pipeline.release();

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(pipeline);
        encoder.setBufferOffsetAtIndex(a_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(out_buffer, 0, 1);
        const grid_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        var result: mod.G2Point = undefined;
        if (out_buffer.contents()) |ptr| {
            result = @as(*const mod.G2Point, @ptrCast(@alignCast(ptr))).*;
        }
        return result;
    }

    /// Test g2_add on two affine points using the inline test kernel.
    pub fn testG2AddInline(
        self: *Self,
        a: []const u8,
        b: []const u8,
    ) !mod.G2Point {
        var a_buffer = self.device.newBufferWithLengthOptions(
            a.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer a_buffer.release();
        var b_buffer = self.device.newBufferWithLengthOptions(
            b.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer b_buffer.release();
        var out_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(mod.G2Point),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer out_buffer.release();

        if (a_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..a.len], a);
        }
        if (b_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..b.len], b);
        }

        const source_ns = mtl.NSString.stringWithUTF8String(mod.EMBEDDED_METAL_SHADER.ptr);
        var library = self.device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse {
            return error.ShaderCompileFailed;
        };
        defer library.release();
        const func_name = mtl.NSString.stringWithUTF8String("test_g2_add_inline");
        var func = library.newFunctionWithName(func_name) orelse return error.FunctionNotFound;
        defer func.release();
        var pipeline = self.device.newComputePipelineStateWithFunctionError(func, null) orelse {
            return error.PipelineCreationFailed;
        };
        defer pipeline.release();

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(pipeline);
        encoder.setBufferOffsetAtIndex(a_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(b_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(out_buffer, 0, 2);
        const grid_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        var result: mod.G2Point = undefined;
        if (out_buffer.contents()) |ptr| {
            result = @as(*const mod.G2Point, @ptrCast(@alignCast(ptr))).*;
        }
        return result;
    }

    /// Test g2_add on two projective points.
    pub fn testG2AddProjective(
        self: *Self,
        a: []const u8,
        b: []const u8,
    ) !mod.G2Point {
        var a_buffer = self.device.newBufferWithLengthOptions(
            a.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer a_buffer.release();
        var b_buffer = self.device.newBufferWithLengthOptions(
            b.len,
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer b_buffer.release();
        var out_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(mod.G2Point),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer out_buffer.release();

        if (a_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..a.len], a);
        }
        if (b_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..b.len], b);
        }

        const source_ns = mtl.NSString.stringWithUTF8String(mod.EMBEDDED_METAL_SHADER.ptr);
        var library = self.device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse {
            return error.ShaderCompileFailed;
        };
        defer library.release();
        const func_name = mtl.NSString.stringWithUTF8String("test_g2_add_projective");
        var func = library.newFunctionWithName(func_name) orelse return error.FunctionNotFound;
        defer func.release();
        var pipeline = self.device.newComputePipelineStateWithFunctionError(func, null) orelse {
            return error.PipelineCreationFailed;
        };
        defer pipeline.release();

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(pipeline);
        encoder.setBufferOffsetAtIndex(a_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(b_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(out_buffer, 0, 2);
        const grid_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 1, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        var result: mod.G2Point = undefined;
        if (out_buffer.contents()) |ptr| {
            result = @as(*const mod.G2Point, @ptrCast(@alignCast(ptr))).*;
        }
        return result;
    }

    /// Benchmark a kernel that does N iterations of work per thread.
    /// `kernel_name`: Metal kernel name (e.g. "bench_fq_mul")
    /// `iterations`: number of work items done per thread (for reporting)
    /// `num_threads`: total threads to launch
    /// Returns: elapsed time in milliseconds
    pub fn benchmarkKernel(
        self: *Self,
        kernel_name: [*c]const u8,
        a: [4]u64,
        b: [4]u64,
        num_threads: usize,
    ) !f64 {
        var a_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf([4]u64),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer a_buffer.release();
        var b_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf([4]u64),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer b_buffer.release();
        var out_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf([4]u64),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer out_buffer.release();

        if (a_buffer.contents()) |ptr| {
            @as(*[4]u64, @ptrCast(@alignCast(ptr))).* = a;
        }
        if (b_buffer.contents()) |ptr| {
            @as(*[4]u64, @ptrCast(@alignCast(ptr))).* = b;
        }

        const source_ns = mtl.NSString.stringWithUTF8String(mod.EMBEDDED_METAL_SHADER.ptr);
        var library = self.device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse {
            return error.ShaderCompileFailed;
        };
        defer library.release();
        const func_name = mtl.NSString.stringWithUTF8String(kernel_name);
        var func = library.newFunctionWithName(func_name) orelse return error.FunctionNotFound;
        defer func.release();
        var pipeline = self.device.newComputePipelineStateWithFunctionError(func, null) orelse {
            return error.PipelineCreationFailed;
        };
        defer pipeline.release();

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(pipeline);
        encoder.setBufferOffsetAtIndex(a_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(b_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(out_buffer, 0, 2);
        const grid_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = @min(self.threads_per_group, num_threads), .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();

        // Use GPU timestamp to measure actual execution time
        const start = getTimeMs();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
        const end = getTimeMs();

        return end - start;
    }

    /// In-place FFT/iFFT on Fr elements (dispatches metal fft_fr kernel per stage).
    /// `data` must be a GPU buffer already allocated and containing the input data.
    /// After completion, the FFT result is in-place in the same buffer.
    pub fn fftFr(
        self: *Self,
        data_buffer: mtl.MTLBuffer,
        twiddles_buffer: mtl.MTLBuffer,
        inverse_n_buffer: mtl.MTLBuffer,
        log_n: u32,
        inverse: bool,
    ) !void {
        const n: u32 = @intCast(data_buffer.length() / (4 * 8)); // 4 uint64_t limbs per FrElement
        const num_threads: u32 = @intCast(self.threads_per_group);
        const total_stages = log_n + 1;

        const FFTConfig = extern struct {
            n: u32,
            inverse: u32,
            log_n: u32,
            stage: u32,
            num_threads: u32,
        };

        var config_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(FFTConfig),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer config_buffer.release();

        for (0..total_stages) |stage| {
            if (config_buffer.contents()) |ptr| {
                @as(*FFTConfig, @ptrCast(@alignCast(ptr))).* = .{
                    .n = n,
                    .inverse = if (inverse and stage == total_stages - 1) 1 else 0,
                    .log_n = log_n,
                    .stage = @intCast(stage),
                    .num_threads = num_threads,
                };
            }

            var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
            var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
            encoder.setComputePipelineState(self.fft_fr_pipeline);
            encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
            encoder.setBufferOffsetAtIndex(twiddles_buffer, 0, 1);
            encoder.setBufferOffsetAtIndex(config_buffer, 0, 2);
            encoder.setBufferOffsetAtIndex(inverse_n_buffer, 0, 3);

            const grid_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
            const threadgroup_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
            encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
            encoder.endEncoding();
            cmd_buffer.commit();
            cmd_buffer.waitUntilCompleted();
        }
    }

    /// Batched FFT/iFFT: all stages in a single command buffer.
    /// Each stage gets its own config buffer so the GPU sees the correct
    /// stage parameters (critical: do not reuse one buffer across stages).
    pub fn fftFrBatched(
        self: *Self,
        data_buffer: mtl.MTLBuffer,
        twiddles_buffer: mtl.MTLBuffer,
        inverse_n_buffer: mtl.MTLBuffer,
        log_n: u32,
        inverse: bool,
    ) !void {
        const n: u32 = @intCast(data_buffer.length() / (4 * 8));
        const threads_per_group: u32 = @intCast(self.threads_per_group);
        const total_stages = log_n + 1;

        const FFTConfig = extern struct {
            n: u32,
            inverse: u32,
            log_n: u32,
            stage: u32,
            num_threads: u32,
        };

        // One config buffer per stage — GPU must see distinct configs
        var config_buffers: [24]mtl.MTLBuffer = undefined;
        if (total_stages > config_buffers.len) return error.TooManyStages;
        for (0..total_stages) |stage| {
            config_buffers[stage] = self.device.newBufferWithLengthOptions(
                @sizeOf(FFTConfig),
                mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
            ) orelse return error.BufferCreationFailed;
            if (config_buffers[stage].contents()) |ptr| {
                @as(*FFTConfig, @ptrCast(@alignCast(ptr))).* = .{
                    .n = n,
                    .inverse = if (inverse and stage == total_stages - 1) 1 else 0,
                    .log_n = log_n,
                    .stage = @intCast(stage),
                    // Stage 0 (bit-reverse) uses only threads_per_group threads;
                    // stages 1+ use up to 2048 threads for large arrays.
                    .num_threads = if (stage == 0 or n < 4096) threads_per_group else @min(2048, n / 2),
                };
            }
        }
        defer for (0..total_stages) |stage| config_buffers[stage].release();

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;

        const total_threads: u32 = if (n >= 4096)
            @min(2048, n / 2)
        else
            threads_per_group;
        const grid_size = mtl.MTLSize{ .width = total_threads, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = threads_per_group, .height = 1, .depth = 1 };

        for (0..total_stages) |stage| {
            // Stage 0 (bit-reverse) must run in a single threadgroup to avoid
            // cross-threadgroup memory races when threads swap overlapping indices.
            const stage_grid_size = if (stage == 0)
                mtl.MTLSize{ .width = threads_per_group, .height = 1, .depth = 1 }
            else
                grid_size;
            var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
            encoder.setComputePipelineState(self.fft_fr_pipeline);
            encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
            encoder.setBufferOffsetAtIndex(twiddles_buffer, 0, 1);
            encoder.setBufferOffsetAtIndex(config_buffers[stage], 0, 2);
            encoder.setBufferOffsetAtIndex(inverse_n_buffer, 0, 3);
            encoder.dispatchThreadsThreadsPerThreadgroup(stage_grid_size, threadgroup_size);
            encoder.endEncoding();
        }

        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// Run 3 independent FFT/IFFT transforms in a single command buffer.
    /// This amortizes command buffer overhead across 3 transforms.
    pub fn fftFrBatched3(
        self: *Self,
        data_buffers: [3]mtl.MTLBuffer,
        twiddles_buffer: mtl.MTLBuffer,
        inverse_n_buffer: mtl.MTLBuffer,
        log_n: u32,
        inverse: bool,
    ) !void {
        const n: u32 = @intCast(data_buffers[0].length() / (4 * 8));
        const threads_per_group: u32 = @intCast(self.threads_per_group);
        const total_stages = log_n + 1;

        const FFTConfig = extern struct {
            n: u32,
            inverse: u32,
            log_n: u32,
            stage: u32,
            num_threads: u32,
        };

        // One config buffer per stage — GPU must see distinct configs
        var config_buffers: [24]mtl.MTLBuffer = undefined;
        if (total_stages > config_buffers.len) return error.TooManyStages;
        for (0..total_stages) |stage| {
            config_buffers[stage] = self.device.newBufferWithLengthOptions(
                @sizeOf(FFTConfig),
                mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
            ) orelse return error.BufferCreationFailed;
            if (config_buffers[stage].contents()) |ptr| {
                @as(*FFTConfig, @ptrCast(@alignCast(ptr))).* = .{
                    .n = n,
                    .inverse = if (inverse and stage == total_stages - 1) 1 else 0,
                    .log_n = log_n,
                    .stage = @intCast(stage),
                    // Stage 0 (bit-reverse) uses only threads_per_group threads;
                    // stages 1+ use up to 2048 threads for large arrays.
                    .num_threads = if (stage == 0 or n < 4096) threads_per_group else @min(2048, n / 2),
                };
            }
        }
        defer for (0..total_stages) |stage| config_buffers[stage].release();

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;

        const total_threads: u32 = if (n >= 4096)
            @min(2048, n / 2)
        else
            threads_per_group;
        const grid_size = mtl.MTLSize{ .width = total_threads, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = threads_per_group, .height = 1, .depth = 1 };

        for (0..total_stages) |stage| {
            // Stage 0 (bit-reverse) must run in a single threadgroup to avoid
            // cross-threadgroup memory races when threads swap overlapping indices.
            const stage_grid_size = if (stage == 0)
                mtl.MTLSize{ .width = threads_per_group, .height = 1, .depth = 1 }
            else
                grid_size;
            for (data_buffers) |data_buffer| {
                var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
                encoder.setComputePipelineState(self.fft_fr_pipeline);
                encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
                encoder.setBufferOffsetAtIndex(twiddles_buffer, 0, 1);
                encoder.setBufferOffsetAtIndex(config_buffers[stage], 0, 2);
                encoder.setBufferOffsetAtIndex(inverse_n_buffer, 0, 3);
                encoder.dispatchThreadsThreadsPerThreadgroup(stage_grid_size, threadgroup_size);
                encoder.endEncoding();
            }
        }

        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// Elementwise multiply data[i] *= shift_factors[i]
    pub fn fftShift(
        self: *Self,
        data_buffer: mtl.MTLBuffer,
        shift_buffer: mtl.MTLBuffer,
    ) !void {
        const n: u32 = @intCast(data_buffer.length() / (4 * 8));
        const num_threads: u32 = @intCast(self.threads_per_group);

        var n_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(u32),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer n_buffer.release();
        if (n_buffer.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.fft_shift_pipeline);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(shift_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(n_buffer, 0, 2);

        const grid_size = mtl.MTLSize{ .width = n, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// Pointwise: a[i] = a[i]*b[i] - c[i], with fromMontgomery
    pub fn fftPointwiseAbc(
        self: *Self,
        a_buffer: mtl.MTLBuffer,
        b_buffer: mtl.MTLBuffer,
        c_buffer: mtl.MTLBuffer,
    ) !void {
        const n: u32 = @intCast(a_buffer.length() / (4 * 8));
        const num_threads: u32 = @intCast(self.threads_per_group);

        var n_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(u32),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer n_buffer.release();
        if (n_buffer.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.fft_pointwise_abc_pipeline);
        encoder.setBufferOffsetAtIndex(a_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(b_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(c_buffer, 0, 2);
        encoder.setBufferOffsetAtIndex(n_buffer, 0, 3);

        const grid_size = mtl.MTLSize{ .width = n, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    // =========================================================================
    // 4-Step NTT dispatch functions
    // =========================================================================

    /// Single-kernel FFT stages 1-10 using 1024-element tiles in shared memory.
    /// n must be a multiple of 1024.
    pub fn fftTile1024(
        self: *Self,
        data_buffer: mtl.MTLBuffer,
        twiddles_buffer: mtl.MTLBuffer,
        n: u32,
    ) !void {
        const num_tiles = n / 1024;
        const threads_per_group: u32 = 512; // Must not exceed pipeline max (640 on Apple Silicon)

        if (self.fft_n_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.fft_tile_1024_pipeline);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(twiddles_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 2);

        const grid_size = mtl.MTLSize{ .width = num_tiles * threads_per_group, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = threads_per_group, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// Single-kernel FFT stages 1-9 using 512-element tiles in shared memory.
    pub fn fftTile512(
        self: *Self,
        data_buffer: mtl.MTLBuffer,
        twiddles_buffer: mtl.MTLBuffer,
        n: u32,
    ) !void {
        const num_tiles = n / 512;
        const threads_per_group: u32 = 256; // Must not exceed pipeline max (640 on Apple Silicon)

        if (self.fft_n_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.fft_tile_512_pipeline);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(twiddles_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 2);

        const grid_size = mtl.MTLSize{ .width = num_tiles * threads_per_group, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = threads_per_group, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// Transpose a 1024×1024 matrix of FrElement.
    pub fn transpose1024(
        self: *Self,
        input_buffer: mtl.MTLBuffer,
        output_buffer: mtl.MTLBuffer,
        n: u32,
    ) !void {
        const num_tiles = 1024; // 32×32 tiles covering 1024×1024
        const threads_per_tile: u32 = 1024;

        if (self.fft_n_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.transpose_1024_pipeline);
        encoder.setBufferOffsetAtIndex(input_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(output_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 2);

        const grid_size = mtl.MTLSize{ .width = num_tiles * threads_per_tile, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = threads_per_tile, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// Element-wise multiply by precomputed 2D twiddle factors omega^{i*j}.
    pub fn twiddleMultiply1024(
        self: *Self,
        data_buffer: mtl.MTLBuffer,
        twiddles_2d_buffer: mtl.MTLBuffer,
        n: u32,
    ) !void {
        const num_threads: u32 = 256;

        if (self.fft_n_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.twiddle_multiply_1024_pipeline);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(twiddles_2d_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 2);

        const grid_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// Single global-memory stage for stages >= 10.
    pub fn fftGlobalStage(
        self: *Self,
        data_buffer: mtl.MTLBuffer,
        twiddles_buffer: mtl.MTLBuffer,
        n: u32,
        stage: u32,
    ) !void {
        const total_butterflies = n / 2;
        const threads_per_group: u32 = @intCast(self.threads_per_group);

        if (self.fft_n_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }
        if (self.fft_stage_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = stage;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.fft_global_stage_pipeline);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(twiddles_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 2);
        encoder.setBufferOffsetAtIndex(self.fft_stage_buf, 0, 3);

        const grid_size = mtl.MTLSize{ .width = total_butterflies, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = threads_per_group, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// Multiple global-memory stages in a single dispatch.
    /// Reduces command buffer overhead for stages 11+.
    /// Each threadgroup processes a disjoint chunk sized to the last stage.
    pub fn fftGlobalStagesBatched(
        self: *Self,
        data_buffer: mtl.MTLBuffer,
        twiddles_buffer: mtl.MTLBuffer,
        n: u32,
        start_stage: u32,
        num_stages: u32,
    ) !void {
        const threads_per_group: u32 = @intCast(self.threads_per_group);
        const max_stage = start_stage + num_stages - 1;
        const num_chunks = n >> @intCast(max_stage);
        const grid_threads = num_chunks * threads_per_group;

        if (self.fft_n_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }
        if (self.fft_stage_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = start_stage;
        }
        if (self.fft_num_stages_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = num_stages;
        }
        if (self.fft_tg_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = threads_per_group;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.fft_global_stages_batched_pipeline);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(twiddles_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 2);
        encoder.setBufferOffsetAtIndex(self.fft_stage_buf, 0, 3);
        encoder.setBufferOffsetAtIndex(self.fft_num_stages_buf, 0, 4);
        encoder.setBufferOffsetAtIndex(self.fft_tg_buf, 0, 5);

        const grid_size = mtl.MTLSize{ .width = grid_threads, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = threads_per_group, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// h = fromMont(a*b - c), written over `a`.
    pub fn pointwiseH(
        self: *Self,
        a_buf: mtl.MTLBuffer,
        b_buf: mtl.MTLBuffer,
        c_buf: mtl.MTLBuffer,
        n: u32,
    ) !void {
        if (self.fft_n_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }
        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.pointwise_abc_3buf_pipeline);
        encoder.setBufferOffsetAtIndex(a_buf, 0, 0);
        encoder.setBufferOffsetAtIndex(b_buf, 0, 1);
        encoder.setBufferOffsetAtIndex(c_buf, 0, 2);
        encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 3);
        const groups = (n + 255) / 256;
        const grid_size = mtl.MTLSize{ .width = groups * 256, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 256, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// Full 4-step NTT for a single buffer.
    /// For n = 2^20: tile stages 1-10, transpose, twiddle, tile (column NTT), transpose back.
    /// For smaller n that are still >= 1024: adjust tile size.
    pub fn fftFr4Step(
        self: *Self,
        data_buffer: mtl.MTLBuffer,
        twiddles_buffer: mtl.MTLBuffer,
        _: mtl.MTLBuffer,
        _: mtl.MTLBuffer,
        n: u32,
        log_n: u32,
    ) !void {
        // Stages 1-10: tile-based in shared memory (single dispatch)
        if (n >= 1024) {
            try self.fftTile1024(data_buffer, twiddles_buffer, n);
        } else if (n >= 512) {
            try self.fftTile512(data_buffer, twiddles_buffer, n);
        } else {
            // For small n, fall back to per-stage global kernel
            for (1..log_n + 1) |stage| {
                try self.fftGlobalStage(data_buffer, twiddles_buffer, n, @intCast(stage));
            }
            return;
        }

        // For n <= 1024, we're done after the tile FFT.
        if (n <= 1024) return;

        // Stages 11+: batch global stages to reduce dispatch overhead.
        // Dynamic batch size ensures at least 16 chunks per dispatch for parallelism.
        const global_start_stage: u32 = 11;
        const min_chunks_log2: u32 = 4; // 16 chunks minimum
        var current_stage: u32 = global_start_stage;
        const end_stage = log_n + 1;
        while (current_stage < end_stage) {
            const remaining = end_stage - current_stage;
            const max_batch = if (log_n + 1 > current_stage + min_chunks_log2)
                log_n + 1 - current_stage - min_chunks_log2
            else
                1;
            const batch_size = @min(max_batch, remaining, 5);
            try self.fftGlobalStagesBatched(data_buffer, twiddles_buffer, n, current_stage, batch_size);
            current_stage += batch_size;
        }
    }

    /// Batched 4-step NTT for 3 buffers (a, b, c).
    /// Uses separate temp buffers for each to avoid data races.
    pub fn fftFr4StepBatched3(
        self: *Self,
        data_buffers: [3]mtl.MTLBuffer,
        twiddles_buffer: mtl.MTLBuffer,
        _: mtl.MTLBuffer,
        _: [3]mtl.MTLBuffer,
        n: u32,
        log_n: u32,
    ) !void {
        // Step 1: Tile stages 1-10 for all 3 buffers (single dispatch per buffer)
        for (data_buffers) |buf| {
            try self.fftTile1024(buf, twiddles_buffer, n);
        }

        if (n <= 1024) return;

        // Step 2: Global stages 11+ batched to reduce dispatch overhead
        const global_start_stage: u32 = 11;
        const min_chunks_log2: u32 = 4; // 16 chunks minimum
        var current_stage: u32 = global_start_stage;
        const end_stage = log_n + 1;
        while (current_stage < end_stage) {
            const remaining = end_stage - current_stage;
            const max_batch = if (log_n + 1 > current_stage + min_chunks_log2)
                log_n + 1 - current_stage - min_chunks_log2
            else
                1;
            const batch_size = @min(max_batch, remaining, 5);
            for (data_buffers) |buf| {
                try self.fftGlobalStagesBatched(buf, twiddles_buffer, n, current_stage, batch_size);
            }
            current_stage += batch_size;
        }
    }

    // =========================================================================
    // Twiddle cache
    // =========================================================================

    /// Pre-compute and cache twiddle tables for a given domain size.
    /// Uses recurrence relation for O(n) computation instead of O(n log n).
    pub fn warmTwiddles(self: *Self, n: u32) !void {
        if (self.twiddle_cache_fwd.contains(n)) return;
        const fr_size = @sizeOf(cpu.field.FrElement);
        const half_n = n / 2;

        // Forward twiddles
        var fwd_cpu = try self.allocator.alloc(cpu.field.FrElement, half_n);
        defer self.allocator.free(fwd_cpu);
        const omega = cpu.fft.getOmegaN(n);
        fwd_cpu[0] = cpu.field.fr_one();
        for (1..half_n) |i| {
            fwd_cpu[i] = cpu.field.fr_mul(fwd_cpu[i - 1], omega);
        }
        const fwd_buf = self.device.newBufferWithLengthOptions(half_n * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        @memcpy(@as([*]u8, @ptrCast(fwd_buf.contents().?))[0..half_n * fr_size], std.mem.sliceAsBytes(fwd_cpu));
        try self.twiddle_cache_fwd.put(n, fwd_buf);

        // Inverse twiddles
        var inv_cpu = try self.allocator.alloc(cpu.field.FrElement, half_n);
        defer self.allocator.free(inv_cpu);
        const omega_inv = cpu.field.fr_inv(omega);
        inv_cpu[0] = cpu.field.fr_one();
        for (1..half_n) |i| {
            inv_cpu[i] = cpu.field.fr_mul(inv_cpu[i - 1], omega_inv);
        }
        const inv_buf = self.device.newBufferWithLengthOptions(half_n * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        @memcpy(@as([*]u8, @ptrCast(inv_buf.contents().?))[0..half_n * fr_size], std.mem.sliceAsBytes(inv_cpu));
        try self.twiddle_cache_inv.put(n, inv_buf);
    }

    /// Get cached twiddles buffer. Caller must have called warmTwiddles(n) first.
    pub fn getTwiddles(self: *Self, n: u32, inverse: bool) !mtl.MTLBuffer {
        if (inverse) {
            return self.twiddle_cache_inv.get(n) orelse return error.TwiddlesNotWarmed;
        } else {
            return self.twiddle_cache_fwd.get(n) orelse return error.TwiddlesNotWarmed;
        }
    }

    /// Pre-compute and cache coset shift powers g^i for i=0..n-1.
    /// g is the primitive 2n-th root of unity (omega_2n).
    pub fn warmCosetShift(self: *Self, n: u32) !void {
        if (self.coset_shift_cache.contains(n)) return;
        const fr_size = @sizeOf(cpu.field.FrElement);
        const g = cpu.fft.getOmegaN(2 * n);
        var cs_cpu = try self.allocator.alloc(cpu.field.FrElement, n);
        defer self.allocator.free(cs_cpu);
        var power = cpu.field.fr_one();
        for (0..n) |i| {
            cs_cpu[i] = power;
            power = cpu.field.fr_mul(power, g);
        }
        const cs_buf = self.device.newBufferWithLengthOptions(n * fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        @memcpy(@as([*]u8, @ptrCast(cs_buf.contents().?))[0..n * fr_size], std.mem.sliceAsBytes(cs_cpu));
        try self.coset_shift_cache.put(n, cs_buf);
    }

    /// Get cached coset shift buffer. Caller must have called warmCosetShift(n) first.
    pub fn getCosetShift(self: *Self, n: u32) !mtl.MTLBuffer {
        return self.coset_shift_cache.get(n) orelse return error.TwiddlesNotWarmed;
    }

    // =========================================================================
    // Bit-reverse and IFFT postprocess kernels
    // =========================================================================

    /// Out-of-place bit-reverse: input -> output. Caller must copy output back
    /// to input if in-place result is desired (fast CPU memcpy on unified memory).
    pub fn bitReverseGpu(
        self: *Self,
        input_buffer: mtl.MTLBuffer,
        output_buffer: mtl.MTLBuffer,
        n: u32,
    ) !void {
        const log_n = std.math.log2(n);
        if (self.fft_n_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }
        if (self.fft_stage_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = log_n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.bit_reverse_pipeline);
        encoder.setBufferOffsetAtIndex(input_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(output_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 2);
        encoder.setBufferOffsetAtIndex(self.fft_stage_buf, 0, 3);

        const num_threads = (n + 255) / 256;
        const grid_size = mtl.MTLSize{ .width = num_threads * 256, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 256, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// Batch bit-reverse for 3 buffers in a single command buffer.
    /// Uses separate temp buffers for each to avoid data races.
    /// Reduces command buffer overhead from 3 round-trips to 1.
    pub fn bitReverseGpu3(
        self: *Self,
        a_in: mtl.MTLBuffer,
        b_in: mtl.MTLBuffer,
        c_in: mtl.MTLBuffer,
        tmp_a: mtl.MTLBuffer,
        tmp_b: mtl.MTLBuffer,
        tmp_c: mtl.MTLBuffer,
        n: u32,
    ) !void {
        const log_n = std.math.log2(n);
        if (self.fft_n_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }
        if (self.fft_stage_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = log_n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        const num_threads = (n + 255) / 256;
        const grid_size = mtl.MTLSize{ .width = num_threads * 256, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 256, .height = 1, .depth = 1 };

        // Encoder 1: bit-reverse a
        {
            var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
            encoder.setComputePipelineState(self.bit_reverse_pipeline);
            encoder.setBufferOffsetAtIndex(a_in, 0, 0);
            encoder.setBufferOffsetAtIndex(tmp_a, 0, 1);
            encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 2);
            encoder.setBufferOffsetAtIndex(self.fft_stage_buf, 0, 3);
            encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
            encoder.endEncoding();
        }
        // Encoder 2: bit-reverse b
        {
            var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
            encoder.setComputePipelineState(self.bit_reverse_pipeline);
            encoder.setBufferOffsetAtIndex(b_in, 0, 0);
            encoder.setBufferOffsetAtIndex(tmp_b, 0, 1);
            encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 2);
            encoder.setBufferOffsetAtIndex(self.fft_stage_buf, 0, 3);
            encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
            encoder.endEncoding();
        }
        // Encoder 3: bit-reverse c
        {
            var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
            encoder.setComputePipelineState(self.bit_reverse_pipeline);
            encoder.setBufferOffsetAtIndex(c_in, 0, 0);
            encoder.setBufferOffsetAtIndex(tmp_c, 0, 1);
            encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 2);
            encoder.setBufferOffsetAtIndex(self.fft_stage_buf, 0, 3);
            encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
            encoder.endEncoding();
        }

        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    pub fn ifftScaleShift(
        self: *Self,
        a_buf: mtl.MTLBuffer,
        b_buf: mtl.MTLBuffer,
        c_buf: mtl.MTLBuffer,
        g_buf: mtl.MTLBuffer,
        inv_n_buf: mtl.MTLBuffer,
        n: u32,
    ) !void {
        if (self.fft_n_buf.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.ifft_scale_shift_pipeline);
        encoder.setBufferOffsetAtIndex(a_buf, 0, 0);
        encoder.setBufferOffsetAtIndex(b_buf, 0, 1);
        encoder.setBufferOffsetAtIndex(c_buf, 0, 2);
        encoder.setBufferOffsetAtIndex(g_buf, 0, 3);
        encoder.setBufferOffsetAtIndex(inv_n_buf, 0, 4);
        encoder.setBufferOffsetAtIndex(self.fft_n_buf, 0, 5);

        const num_threads = (n + 255) / 256;
        const grid_size = mtl.MTLSize{ .width = num_threads * 256, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 256, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    // =========================================================================
    // End 4-Step NTT
    // =========================================================================

    /// SIMD version of fftShift: processes 4 elements per thread
    pub fn fftShiftSimd(
        self: *Self,
        data_buffer: mtl.MTLBuffer,
        shift_buffer: mtl.MTLBuffer,
    ) !void {
        const n: u32 = @intCast(data_buffer.length() / (4 * 8));
        const num_threads: u32 = @intCast(self.threads_per_group);

        var n_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(u32),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer n_buffer.release();
        if (n_buffer.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.fft_shift_simd_pipeline);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(shift_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(n_buffer, 0, 2);

        const simd_threads = (n / 4 + num_threads - 1) / num_threads;
        const grid_size = mtl.MTLSize{ .width = simd_threads * num_threads, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// SIMD version of fftPointwiseAbc: processes 4 elements per thread
    pub fn fftPointwiseAbcSimd(
        self: *Self,
        a_buffer: mtl.MTLBuffer,
        b_buffer: mtl.MTLBuffer,
        c_buffer: mtl.MTLBuffer,
    ) !void {
        const n: u32 = @intCast(a_buffer.length() / (4 * 8));
        const num_threads: u32 = @intCast(self.threads_per_group);

        var n_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(u32),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer n_buffer.release();
        if (n_buffer.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.fft_pointwise_abc_simd_pipeline);
        encoder.setBufferOffsetAtIndex(a_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(b_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(c_buffer, 0, 2);
        encoder.setBufferOffsetAtIndex(n_buffer, 0, 3);

        const simd_threads = (n / 4 + num_threads - 1) / num_threads;
        const grid_size = mtl.MTLSize{ .width = simd_threads * num_threads, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// rapidsnark-style inverse FFT post-process: after forward FFT,
    /// swap a[i] <-> a[n-i] for i=1..n/2-1 and scale all by inverse_n.
    pub fn fftIfftPostprocess(
        self: *Self,
        data_buffer: mtl.MTLBuffer,
        inverse_n_buffer: mtl.MTLBuffer,
    ) !void {
        const n: u32 = @intCast(data_buffer.length() / (4 * 8));
        const num_threads: u32 = @intCast(self.threads_per_group);

        var n_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(u32),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer n_buffer.release();
        if (n_buffer.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.fft_ifft_postprocess_pipeline);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(inverse_n_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(n_buffer, 0, 2);

        const grid_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();
    }

    /// fftTile3buf — dispatch tile FFT kernel (stages 0-8) for single buffer
    pub fn fftTile3buf(
        self: *Self,
        data: []cpu.field.FrElement,
        n: u32,
    ) !void {
        const TILE_SIZE = 256;
        if (n < TILE_SIZE or n % TILE_SIZE != 0) return error.InvalidDomainSize;

        var data_buffer = self.device.newBufferWithLengthOptions(
            data.len * @sizeOf(cpu.field.FrElement),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer data_buffer.release();

        if (data_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..data.len * @sizeOf(cpu.field.FrElement)], std.mem.sliceAsBytes(data));
        }

        // Precompute twiddles
        const twiddles = try self.allocator.alloc(cpu.field.FrElement, n / 2);
        defer self.allocator.free(twiddles);
        for (0..n / 2) |i| {
            twiddles[i] = cpu.fft.getTwiddle(n, @intCast(i));
        }

        var twiddles_buffer = self.device.newBufferWithLengthOptions(
            twiddles.len * @sizeOf(cpu.field.FrElement),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer twiddles_buffer.release();
        if (twiddles_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..twiddles.len * @sizeOf(cpu.field.FrElement)], std.mem.sliceAsBytes(twiddles));
        }

        var n_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(u32),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer n_buffer.release();
        if (n_buffer.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.fft_tile_3buf_pipeline);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 1); // b alias
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 2); // c alias
        encoder.setBufferOffsetAtIndex(twiddles_buffer, 0, 3);
        encoder.setBufferOffsetAtIndex(n_buffer, 0, 4);

        const num_tiles = n / TILE_SIZE;
        const grid_size = mtl.MTLSize{ .width = num_tiles * 128, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 128, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        if (data_buffer.contents()) |ptr| {
            @memcpy(std.mem.sliceAsBytes(data), @as([*]u8, @ptrCast(ptr))[0..data.len * @sizeOf(cpu.field.FrElement)]);
        }
    }

    /// shift3buf — coset shift for single buffer
    pub fn shift3buf(
        self: *Self,
        data: []cpu.field.FrElement,
        n: u32,
        g: cpu.field.FrElement,
    ) !void {
        var data_buffer = self.device.newBufferWithLengthOptions(
            data.len * @sizeOf(cpu.field.FrElement),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer data_buffer.release();

        if (data_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..data.len * @sizeOf(cpu.field.FrElement)], std.mem.sliceAsBytes(data));
        }

        // Precompute g^i
        const g_powers = try self.allocator.alloc(cpu.field.FrElement, n);
        defer self.allocator.free(g_powers);
        var power = cpu.field.fr_one();
        for (0..n) |i| {
            g_powers[i] = power;
            power = cpu.field.fr_mul(power, g);
        }

        var g_buffer = self.device.newBufferWithLengthOptions(
            g_powers.len * @sizeOf(cpu.field.FrElement),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer g_buffer.release();
        if (g_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..g_powers.len * @sizeOf(cpu.field.FrElement)], std.mem.sliceAsBytes(g_powers));
        }

        var n_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(u32),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer n_buffer.release();
        if (n_buffer.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.shift_3buf_pipeline);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 1); // b alias
        encoder.setBufferOffsetAtIndex(data_buffer, 0, 2); // c alias
        encoder.setBufferOffsetAtIndex(g_buffer, 0, 3);
        encoder.setBufferOffsetAtIndex(n_buffer, 0, 4);

        const num_threads = (n + 3) / 4;
        const grid_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 256, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        if (data_buffer.contents()) |ptr| {
            @memcpy(std.mem.sliceAsBytes(data), @as([*]u8, @ptrCast(ptr))[0..data.len * @sizeOf(cpu.field.FrElement)]);
        }
    }

    /// pointwiseAbc3buf — pointwise multiply/subtract for single output
    pub fn pointwiseAbc3buf(
        self: *Self,
        a: []cpu.field.FrElement,
        b: []cpu.field.FrElement,
        c: []cpu.field.FrElement,
        h: []cpu.field.FrElement,
        n: u32,
    ) !void {
        var a_buffer = self.device.newBufferWithLengthOptions(
            a.len * @sizeOf(cpu.field.FrElement),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer a_buffer.release();
        var b_buffer = self.device.newBufferWithLengthOptions(
            b.len * @sizeOf(cpu.field.FrElement),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer b_buffer.release();
        var c_buffer = self.device.newBufferWithLengthOptions(
            c.len * @sizeOf(cpu.field.FrElement),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer c_buffer.release();

        if (a_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..a.len * @sizeOf(cpu.field.FrElement)], std.mem.sliceAsBytes(a));
        }
        if (b_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..b.len * @sizeOf(cpu.field.FrElement)], std.mem.sliceAsBytes(b));
        }
        if (c_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..c.len * @sizeOf(cpu.field.FrElement)], std.mem.sliceAsBytes(c));
        }

        var n_buffer = self.device.newBufferWithLengthOptions(
            @sizeOf(u32),
            mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache,
        ) orelse return error.BufferCreationFailed;
        defer n_buffer.release();
        if (n_buffer.contents()) |ptr| {
            @as(*u32, @ptrCast(@alignCast(ptr))).* = n;
        }

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;
        encoder.setComputePipelineState(self.pointwise_abc_3buf_pipeline);
        encoder.setBufferOffsetAtIndex(a_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(b_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(c_buffer, 0, 2);
        encoder.setBufferOffsetAtIndex(n_buffer, 0, 3);

        const num_threads = (n + 3) / 4;
        const grid_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = 256, .height = 1, .depth = 1 };
        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        if (a_buffer.contents()) |ptr| {
            @memcpy(std.mem.sliceAsBytes(h), @as([*]u8, @ptrCast(ptr))[0..h.len * @sizeOf(cpu.field.FrElement)]);
        }
    }

    /// Calculate H polynomial on GPU using FFT pipeline.
    /// For small domain sizes (< 4096), falls back to CPU FFT to avoid GPU overhead.
    /// For large domains, the entire IFFT→shift→FFT chain runs on GPU with zero
    /// intermediate CPU round-trips (only 1 upload at start, 1 download at end).
    pub fn calculateHGpu(
        self: *Self,
        allocator: std.mem.Allocator,
        a_fr: []const cpu.field.FrElement,
        b_fr: []const cpu.field.FrElement,
        c_fr: []const cpu.field.FrElement,
        domainSize: u32,
        n8r: u32,
    ) ![]cpu.field.FrElement {
        if (domainSize == 0) return &[_]cpu.field.FrElement{};

        const n = domainSize;
        const fr_size = @as(usize, n8r);

        // For small domains, CPU FFT is still faster (avoids GPU dispatch overhead).
        if (n < 4096) {
            return calculateHGpuCpu(allocator, a_fr, b_fr, c_fr, domainSize, n8r);
        }

        const log_n = std.math.log2(n);
        const buf_size = n * fr_size;

        // Ensure twiddles are cached for this domain size.
        try self.warmTwiddles(n);
        const twiddles_inv = try self.getTwiddles(n, true);
        const twiddles_fwd = try self.getTwiddles(n, false);

        // Upload inputs directly to GPU (no CPU bit-reverse)
        const a_ptr: [*]u8 = @ptrCast(self.fft_a_buf.contents().?);
        const b_ptr: [*]u8 = @ptrCast(self.fft_b_buf.contents().?);
        const c_ptr: [*]u8 = @ptrCast(self.fft_c_buf.contents().?);
        @memcpy(a_ptr[0..buf_size], std.mem.sliceAsBytes(a_fr));
        @memcpy(b_ptr[0..buf_size], std.mem.sliceAsBytes(b_fr));
        @memcpy(c_ptr[0..buf_size], std.mem.sliceAsBytes(c_fr));

        // Bit-reverse writes g/g2/g3. The IFFT reads those buffers, so the
        // result never has to be copied back to a/b/c first.
        try self.bitReverseGpu3(self.fft_a_buf, self.fft_b_buf, self.fft_c_buf, self.fft_g_buf, self.fft_g2_buf, self.fft_g3_buf, n);
        const ifft_bufs = [3]mtl.MTLBuffer{ self.fft_g_buf, self.fft_g2_buf, self.fft_g3_buf };
        try self.fftFr4StepBatched3(ifft_bufs, twiddles_inv, self.fft_g_buf, ifft_bufs, n, log_n);

        try self.warmCosetShift(n);
        const coset_shift_buf = try self.getCosetShift(n);

        var inv_n_buf = self.device.newBufferWithLengthOptions(fr_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer inv_n_buf.release();
        const n_mont = cpu.field.fr_toMont(cpu.field.fr_from_u64(@intCast(n)));
        const inverse_n = cpu.field.fr_inv(n_mont);
        @memcpy(@as([*]u8, @ptrCast(inv_n_buf.contents().?))[0..fr_size], std.mem.sliceAsBytes(&[_]cpu.field.FrElement{inverse_n}));

        try self.ifftScaleShift(self.fft_g_buf, self.fft_g2_buf, self.fft_g3_buf, coset_shift_buf, inv_n_buf, n);

        // Second bit-reverse lands back in a/b/c, which the forward FFT reads.
        try self.bitReverseGpu3(self.fft_g_buf, self.fft_g2_buf, self.fft_g3_buf, self.fft_a_buf, self.fft_b_buf, self.fft_c_buf, n);
        const fft_bufs = [3]mtl.MTLBuffer{ self.fft_a_buf, self.fft_b_buf, self.fft_c_buf };
        try self.fftFr4StepBatched3(fft_bufs, twiddles_fwd, self.fft_a_buf, fft_bufs, n, log_n);
        try self.pointwiseH(self.fft_a_buf, self.fft_b_buf, self.fft_c_buf, n);

        const h = try allocator.alloc(cpu.field.FrElement, n);
        @memcpy(std.mem.sliceAsBytes(h), a_ptr[0..buf_size]);
        return h;
    }
};

// ============================================================================
// proveOnGpu — end-to-end GPU proving pipeline
// ============================================================================

/// CPU fallback for calculateH on small domain sizes.
fn calculateHGpuCpu(
    allocator: std.mem.Allocator,
    a_fr_in: []const cpu.field.FrElement,
    b_fr_in: []const cpu.field.FrElement,
    c_fr_in: []const cpu.field.FrElement,
    domainSize: u32,
    _n8r: u32,
) ![]cpu.field.FrElement {
    _ = _n8r;
    const n = domainSize;

    const a_fr = try allocator.alloc(cpu.field.FrElement, n);
    defer allocator.free(a_fr);
    const b_fr = try allocator.alloc(cpu.field.FrElement, n);
    defer allocator.free(b_fr);
    const c_fr = try allocator.alloc(cpu.field.FrElement, n);
    defer allocator.free(c_fr);

    @memcpy(a_fr, a_fr_in);
    @memcpy(b_fr, b_fr_in);
    @memcpy(c_fr, c_fr_in);

    cpu.fft.ifft_fr(a_fr, domainSize);
    cpu.fft.ifft_fr(b_fr, domainSize);
    cpu.fft.ifft_fr(c_fr, domainSize);

    const g = switch (domainSize) {
        1024 => cpu.fft.FR_OMEGA_2048,
        2048 => cpu.fft.FR_OMEGA_4096,
        4096 => cpu.fft.FR_OMEGA_8192,
        8192 => cpu.fft.FR_OMEGA_16384,
        16384 => cpu.fft.FR_OMEGA_32768,
        32768 => cpu.fft.FR_OMEGA_65536,
        65536 => cpu.fft.FR_OMEGA_131072,
        131072 => cpu.fft.FR_OMEGA_262144,
        262144 => cpu.fft.FR_OMEGA_524288,
        524288 => cpu.fft.FR_OMEGA_1048576,
        1048576 => cpu.fft.FR_OMEGA_2097152,
        2097152 => cpu.fft.FR_OMEGA_4194304,
        4194304 => cpu.fft.FR_OMEGA_8388608,
        else => {
            std.debug.assert(@popCount(domainSize) == 1);
            std.debug.panic("Unsupported domain size for coset shift: {d}", .{domainSize});
        },
    };
    cpu.fft.shiftCoefficients(a_fr, domainSize, g);
    cpu.fft.shiftCoefficients(b_fr, domainSize, g);
    cpu.fft.shiftCoefficients(c_fr, domainSize, g);

    cpu.fft.fft_fr(a_fr, domainSize);
    cpu.fft.fft_fr(b_fr, domainSize);
    cpu.fft.fft_fr(c_fr, domainSize);

    const h = try allocator.alloc(cpu.field.FrElement, n);
    for (0..n) |i| {
        const ab = cpu.field.fr_mul(a_fr[i], b_fr[i]);
        h[i] = cpu.field.fr_sub(ab, c_fr[i]);
        h[i] = cpu.field.fr_fromMont(h[i]);
    }
    return h;
}

pub fn accumulateG1(windows: []const mod.G1Point) cpu.curve.G1Point {
    const num_windows = windows.len;
    const window_size: usize = 8;
    var result = cpu.curve.g1_zero();
    for (0..num_windows) |i| {
        const win_idx = num_windows - 1 - i;
        for (0..window_size) |_| {
            result = cpu.curve.g1_dbl(result);
        }
        const mod_pt = windows[win_idx];
        const win_point = cpu.curve.G1Point{
            .x = mod_pt.x,
            .y = mod_pt.y,
            .zz = mod_pt.zz,
            .zzz = mod_pt.zzz,
        };
        result = cpu.curve.g1_add(result, win_point);
    }
    return result;
}

pub fn accumulateG2(windows: []const mod.G2Point) cpu.curve.G2Point {
    const num_windows = windows.len;
    const window_size: usize = 8;
    var result = cpu.curve.g2_zero();
    for (0..num_windows) |i| {
        const win_idx = num_windows - 1 - i;
        for (0..window_size) |_| {
            result = cpu.curve.g2_dbl(result);
        }
        const mod_pt = windows[win_idx];
        const win_point = cpu.curve.G2Point{
            .x = .{ .a = mod_pt.x[0..4].*, .b = mod_pt.x[4..8].* },
            .y = .{ .a = mod_pt.y[0..4].*, .b = mod_pt.y[4..8].* },
            .zz = .{ .a = mod_pt.zz[0..4].*, .b = mod_pt.zz[4..8].* },
            .zzz = .{ .a = mod_pt.zzz[0..4].*, .b = mod_pt.zzz[4..8].* },
        };
        result = cpu.curve.g2_add(result, win_point);
    }
    return result;
}

pub fn calculateHGpu(
    allocator: std.mem.Allocator,
    a_fr: []const cpu.field.FrElement,
    b_fr: []const cpu.field.FrElement,
    c_fr: []const cpu.field.FrElement,
    domainSize: u32,
    _n8r: u32,
) ![]cpu.field.FrElement {
    _ = _n8r;
    if (domainSize == 0) return &[_]cpu.field.FrElement{};

    const n = domainSize;

    // Copy to mutable buffers for IFFT
    const a_mut = try allocator.alloc(cpu.field.FrElement, n);
    defer allocator.free(a_mut);
    const b_mut = try allocator.alloc(cpu.field.FrElement, n);
    defer allocator.free(b_mut);
    const c_mut = try allocator.alloc(cpu.field.FrElement, n);
    defer allocator.free(c_mut);

    @memcpy(a_mut, a_fr);
    @memcpy(b_mut, b_fr);
    @memcpy(c_mut, c_fr);

    cpu.fft.ifft_fr(a_mut, domainSize);
    cpu.fft.ifft_fr(b_mut, domainSize);
    cpu.fft.ifft_fr(c_mut, domainSize);

    // Shift coefficients to coset domain by multiplying with g^i
    // where g is the 2n-th primitive root of unity (matches CPU/rapidsnark)
    const g = switch (domainSize) {
        1024 => cpu.fft.FR_OMEGA_2048,
        2048 => cpu.fft.FR_OMEGA_4096,
        4096 => cpu.fft.FR_OMEGA_8192,
        8192 => cpu.fft.FR_OMEGA_16384,
        16384 => cpu.fft.FR_OMEGA_32768,
        32768 => cpu.fft.FR_OMEGA_65536,
        65536 => cpu.fft.FR_OMEGA_131072,
        131072 => cpu.fft.FR_OMEGA_262144,
        262144 => cpu.fft.FR_OMEGA_524288,
        524288 => cpu.fft.FR_OMEGA_1048576,
        1048576 => cpu.fft.FR_OMEGA_2097152,
        2097152 => cpu.fft.FR_OMEGA_4194304,
        4194304 => cpu.fft.FR_OMEGA_8388608,
        else => {
            std.debug.assert(@popCount(domainSize) == 1);
            std.debug.panic("Unsupported domain size for coset shift: {d}", .{domainSize});
        },
    };
    cpu.fft.shiftCoefficients(a_mut, domainSize, g);
    cpu.fft.shiftCoefficients(b_mut, domainSize, g);
    cpu.fft.shiftCoefficients(c_mut, domainSize, g);

    // FFT back to evaluation form on the coset (Montgomery)
    cpu.fft.fft_fr(a_mut, domainSize);
    cpu.fft.fft_fr(b_mut, domainSize);
    cpu.fft.fft_fr(c_mut, domainSize);

    // Pointwise multiply/subtract: D[i] = A[i]*B[i] - C[i] (Montgomery)
    // pointsH in the zkey already includes the Z(x) = -2 factor from the trusted setup,
    // so we use A*B - C directly without dividing by -2.
    const h = try allocator.alloc(cpu.field.FrElement, n);
    for (0..n) |i| {
        const ab = cpu.field.fr_mul(a_mut[i], b_mut[i]);
        h[i] = cpu.field.fr_sub(ab, c_mut[i]);
        // Convert to normal form for MSM (matches rapidsnark's fromMontgomery)
        h[i] = cpu.field.fr_fromMont(h[i]);
    }

    return h;
}

pub const ProveOptions = struct {
    r: ?cpu.field.FrElement = null,
    s: ?cpu.field.FrElement = null,
};

fn getTimeMs() f64 {
    const c = @cImport({
        @cInclude("sys/time.h");
    });
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @as(f64, @floatFromInt(tv.tv_sec)) * 1000.0 + @as(f64, @floatFromInt(tv.tv_usec)) / 1000.0;
}

pub fn proveOnGpu(
    zkey_path: []const u8,
    witness_path: []const u8,
    options: ProveOptions,
) !cpu.ProofResult {
    return proveOnGpuInternal(zkey_path, witness_path, null, options, false);
}

pub fn proveOnGpuProfiled(
    zkey_path: []const u8,
    witness_path: []const u8,
    options: ProveOptions,
) !cpu.ProofResult {
    return proveOnGpuInternal(zkey_path, witness_path, null, options, true);
}

pub fn proveOnGpuWithNext(
    zkey_path: []const u8,
    witness_path: []const u8,
    next_witness_path: ?[]const u8,
    options: ProveOptions,
) !cpu.ProofResult {
    return proveOnGpuInternal(zkey_path, witness_path, next_witness_path, options, false);
}

pub fn proveOnGpuProfiledWithNext(
    zkey_path: []const u8,
    witness_path: []const u8,
    next_witness_path: ?[]const u8,
    options: ProveOptions,
) !cpu.ProofResult {
    return proveOnGpuInternal(zkey_path, witness_path, next_witness_path, options, true);
}

/// Count non-infinity G1 points in raw zkey bytes.
/// An infinity point has x=0, y=0 (all-zero bytes in Montgomery form).
fn countNonInfinityG1(points_bytes: []const u8) usize {
    const g1_point_size = 64;
    var count: usize = 0;
    var i: usize = 0;
    while (i + g1_point_size <= points_bytes.len) : (i += g1_point_size) {
        const x_zero = std.mem.allEqual(u8, points_bytes[i..i + 32], 0);
        const y_zero = std.mem.allEqual(u8, points_bytes[i + 32..i + 64], 0);
        if (!x_zero or !y_zero) count += 1;
    }
    return count;
}

/// Count non-infinity G2 points in raw zkey bytes.
fn countNonInfinityG2(points_bytes: []const u8) usize {
    const g2_point_size = 128;
    var count: usize = 0;
    var i: usize = 0;
    while (i + g2_point_size <= points_bytes.len) : (i += g2_point_size) {
        const x_zero = std.mem.allEqual(u8, points_bytes[i..i + 64], 0);
        const y_zero = std.mem.allEqual(u8, points_bytes[i + 64..i + 128], 0);
        if (!x_zero or !y_zero) count += 1;
    }
    return count;
}

fn Aligned(comptime T: type) type {
    return struct {
        slice: []const T,
        owned: ?[]T = null,
    };
}

fn alignedPoints(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !Aligned(T) {
    if (bytes.len % @sizeOf(T) != 0) return error.InvalidZkey;
    if (std.mem.isAligned(@intFromPtr(bytes.ptr), @alignOf(T))) {
        const aligned: []align(@alignOf(T)) const u8 = @alignCast(bytes);
        return .{ .slice = std.mem.bytesAsSlice(T, aligned) };
    }
    const n = bytes.len / @sizeOf(T);
    const owned = try allocator.alloc(T, n);
    @memcpy(std.mem.sliceAsBytes(owned), bytes);
    return .{ .slice = owned, .owned = owned };
}

fn proveOnGpuInternal(
    zkey_path: []const u8,
    witness_path: []const u8,
    next_witness_path: ?[]const u8,
    options: ProveOptions,
    profile: bool,
) !cpu.ProofResult {
    const allocator = std.heap.c_allocator;
    var t0: f64 = undefined;
    var stage_times: [12]f64 = undefined;

    t0 = getTimeMs();

    // 1. Load zkey from cache (avoids re-reading and re-parsing for repeated circuits)
    const cache = cpu.zkey_cache.getGlobalCache();
    var cached = try cache.getOrLoad(zkey_path);
    defer cached.deinit(allocator);
    const zkey_data = cached.data;
    // NOTE: do NOT free zkey_data - owned by cache
    const witness_data = blk: {
        if (global_witness_cache.get(witness_path)) |cached_witness| {
            break :blk cached_witness;
        }
        break :blk try readFileToBuffer(witness_path, allocator);
    };
    defer allocator.free(witness_data);

    // Spawn background thread to preload next witness while GPU runs
    if (next_witness_path) |next_path| {
        const path_copy = try allocator.dupe(u8, next_path);
        if (std.Thread.spawn(.{}, preloadWitness, .{path_copy})) |thread| {
            thread.detach();
        } else |err| {
            allocator.free(path_copy);
            std.debug.print("Failed to spawn witness preload thread: {any}\n", .{err});
        }
    }

    stage_times[0] = getTimeMs() - t0;
    t0 = getTimeMs();

    // 2. Use cached parsed zkey
    const zkey = cached.zkey;

    const nVars = zkey.header.nVars;
    const nPublic = zkey.header.nPublic;
    const domainSize = zkey.header.domainSize;
    const n8q = zkey.header.n8;
    const n8r = zkey.header.n8r;
    stage_times[1] = getTimeMs() - t0;
    t0 = getTimeMs();

    // QAP starts below, overlapped with the G1 MSMs. Stage 3 is filled when it finishes.
    stage_times[2] = 0;

    // 4. Extract witness scalars (normal form)
    var wtns = try cpu.parser.parseWitness(allocator, witness_data);
    defer wtns.deinit(allocator);

    const fr_bytes = @sizeOf(cpu.field.FrElement);
    if (wtns.data.len < nVars * fr_bytes) return error.InvalidWitness;
    
    const witness_bytes = wtns.data[0 .. nVars * fr_bytes];
    const n_private = if (nVars > nPublic + 1) nVars - nPublic - 1 else 0;
    stage_times[3] = getTimeMs() - t0;
    t0 = getTimeMs();

    // 5. Extract points from zkey sections
    const sec5 = zkey.getSection(5) orelse return error.MissingSection;
    const sec6 = zkey.getSection(6) orelse return error.MissingSection;
    const sec7 = zkey.getSection(7) orelse return error.MissingSection;
    const sec8 = zkey.getSection(8);
    const sec9 = zkey.getSection(9) orelse return error.MissingSection;

    const g1_point_size = @as(usize, n8q) * 2;
    const g2_point_size = @as(usize, n8q) * 4;

    const expected_a = @as(usize, nVars) * g1_point_size;
    if (sec5.len < expected_a) return error.InvalidZkey;
    const points_a = sec5[0..expected_a];

    const expected_b1 = @as(usize, nVars) * g1_point_size;
    if (sec6.len < expected_b1) return error.InvalidZkey;
    const points_b1 = sec6[0..expected_b1];

    const expected_b2 = @as(usize, nVars) * g2_point_size;
    if (sec7.len < expected_b2) return error.InvalidZkey;
    const points_b2 = sec7[0..expected_b2];

    const expected_c = @as(usize, n_private) * g1_point_size;
    const points_c = if (n_private > 0 and sec8 != null and sec8.?.len >= expected_c)
        sec8.?[0..expected_c]
    else
        &[_]u8{};

    const expected_h = @as(usize, domainSize) * g1_point_size;
    if (sec9.len < expected_h) return error.InvalidZkey;
    const points_h = sec9[0..expected_h];
    stage_times[4] = getTimeMs() - t0;
    t0 = getTimeMs();

    // Use v6 for ALL circuits — single-kernel with threadgroup memory
    // Use GPU for ALL operations — no CPU fallback
    const use_cpu_msm = false;
    const needs_metal = !use_cpu_msm or domainSize >= 4096;

    // 7. Compute H polynomial (GPU FFT for large domains, CPU for small)
    // Only init Metal if we actually need it for H or MSMs
    var prover: ?*MetalProver = null;
    defer if (prover) |p| p.deinit();

    // QAP build runs on a Zig thread while Metal computes the witness MSMs.
    const QapCtx = struct {
        allocator: std.mem.Allocator,
        zkey_data: []const u8,
        witness_data: []const u8,
        qap_info: cpu.qap.ZkeyInfo,
        result: ?cpu.qap.QapResult = null,
        err: ?anyerror = null,
        done: bool = false,
        elapsed_ms: f64 = 0,

        fn run(ctx: *@This()) void {
            const t = getTimeMs();
            ctx.result = cpu.qap.buildQapWithInfo(ctx.allocator, ctx.zkey_data, ctx.witness_data, ctx.qap_info) catch |e| {
                ctx.err = e;
                ctx.elapsed_ms = getTimeMs() - t;
                @atomicStore(bool, &ctx.done, true, .release);
                return;
            };
            ctx.elapsed_ms = getTimeMs() - t;
            @atomicStore(bool, &ctx.done, true, .release);
        }
    };

    // Zig threads take G2 chunks while Metal is busy. Metal steals the tail
    // after the G1 MSMs by swapping this cursor to the chunk count.
    const CpuG2Ctx = struct {
        points: []const cpu.curve.G2PointAffine,
        scalars: []const cpu.field.FrElement,
        chunk: usize,
        budget: usize,
        next: *usize,
        result: cpu.curve.G2Point = undefined,
        points_done: usize = 0,
        err: ?anyerror = null,
        elapsed_ms: f64 = 0,

        fn run(ctx: *@This()) void {
            const t = getTimeMs();
            ctx.result = cpu.curve.g2_zero();
            const n = ctx.points.len;
            if (ctx.chunk == 0) {
                ctx.elapsed_ms = getTimeMs() - t;
                return;
            }
            const nchunks = (n + ctx.chunk - 1) / ctx.chunk;
            while (true) {
                const i = @atomicRmw(usize, ctx.next, .Add, 1, .acq_rel);
                if (i >= nchunks or i >= ctx.budget) break;
                const start = i * ctx.chunk;
                const end = @min(n, start + ctx.chunk);
                const part = cpu.msm.msm_g2(std.heap.c_allocator, ctx.points[start..end], ctx.scalars[start..end]) catch |e| {
                    ctx.err = e;
                    ctx.elapsed_ms = getTimeMs() - t;
                    return;
                };
                ctx.result = cpu.curve.g2_add(ctx.result, part);
                ctx.points_done += end - start;
            }
            ctx.elapsed_ms = getTimeMs() - t;
        }
    };

    // Context for async H-calculation on background thread (queue 1).
    // Waits until the QAP thread publishes a, b, c.
    const HCalcCtx = struct {
        prover: *MetalProver,
        allocator: std.mem.Allocator,
        qap: *QapCtx,
        domainSize: u32,
        n8r: u32,
        result: ?[]cpu.field.FrElement = null,
        err: ?anyerror = null,

        fn run(ctx: *@This()) void {
            while (!@atomicLoad(bool, &ctx.qap.done, .acquire)) {
                std.Thread.yield() catch {};
            }
            if (ctx.qap.err) |e| {
                ctx.err = e;
                return;
            }
            const qap = ctx.qap.result orelse {
                ctx.err = error.HCalculationFailed;
                return;
            };
            ctx.result = ctx.prover.calculateHGpu(ctx.allocator, qap.a, qap.b, qap.c, ctx.domainSize, ctx.n8r) catch |e| {
                ctx.err = e;
                return;
            };
        }
    };

    // Context for async scalar preprocessing (overlaps with point extraction + Metal init)
    const ScalarPrepCtx = struct {
        allocator: std.mem.Allocator,
        witness_bytes: []const u8,
        private_bytes: ?[]const u8,
        sorted_full: ?mod.SortedWindows = null,
        sorted_private: ?mod.SortedWindows = null,
        err: ?anyerror = null,

        fn run(ctx: *@This()) void {
            ctx.sorted_full = mod.preprocessSortedWindows(ctx.allocator, ctx.witness_bytes, 8) catch |e| { ctx.err = e; return; };
            if (ctx.private_bytes) |priv| {
                ctx.sorted_private = mod.preprocessSortedWindows(ctx.allocator, priv, 8) catch |e| { ctx.err = e; return; };
            }
        }
    };

    // Context for async G2 point preprocessing (SoA transpose + negation)
    const G2PrepCtx = struct {
        points_b2: []const u8,
        allocator: std.mem.Allocator,
        x_c0: ?[]u8 = null,
        x_c1: ?[]u8 = null,
        y_c0: ?[]u8 = null,
        y_c1: ?[]u8 = null,
        neg_y_c0: ?[]u8 = null,
        neg_y_c1: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(ctx: *@This()) void {
            const n_points = ctx.points_b2.len / @sizeOf(cpu.curve.G2PointAffine);
            const fq_size = @sizeOf([4]u64);

            ctx.x_c0 = ctx.allocator.alloc(u8, n_points * fq_size) catch |e| { ctx.err = e; return; };
            ctx.x_c1 = ctx.allocator.alloc(u8, n_points * fq_size) catch |e| { ctx.err = e; return; };
            ctx.y_c0 = ctx.allocator.alloc(u8, n_points * fq_size) catch |e| { ctx.err = e; return; };
            ctx.y_c1 = ctx.allocator.alloc(u8, n_points * fq_size) catch |e| { ctx.err = e; return; };

            const points_b2_typed = std.mem.bytesAsSlice(cpu.curve.G2PointAffine, ctx.points_b2);
            var negated_points_b2 = ctx.allocator.alloc(cpu.curve.G2PointAffine, n_points) catch |e| { ctx.err = e; return; };
            defer ctx.allocator.free(negated_points_b2);
            for (0..n_points) |i| {
                negated_points_b2[i] = .{
                    .x = points_b2_typed[i].x,
                    .y = cpu.field.fq2_neg(points_b2_typed[i].y),
                };
            }

            ctx.neg_y_c0 = ctx.allocator.alloc(u8, n_points * fq_size) catch |e| { ctx.err = e; return; };
            ctx.neg_y_c1 = ctx.allocator.alloc(u8, n_points * fq_size) catch |e| { ctx.err = e; return; };

            const negated_bytes = std.mem.sliceAsBytes(negated_points_b2);

            for (0..n_points) |i| {
                const pos_src = i * @sizeOf(cpu.curve.G2PointAffine);
                const neg_src = i * @sizeOf(cpu.curve.G2PointAffine);
                const dst_offset = i * fq_size;
                @memcpy(ctx.x_c0.?[dst_offset..][0..fq_size], ctx.points_b2[pos_src + 0 * fq_size ..][0..fq_size]);
                @memcpy(ctx.x_c1.?[dst_offset..][0..fq_size], ctx.points_b2[pos_src + 1 * fq_size ..][0..fq_size]);
                @memcpy(ctx.y_c0.?[dst_offset..][0..fq_size], ctx.points_b2[pos_src + 2 * fq_size ..][0..fq_size]);
                @memcpy(ctx.y_c1.?[dst_offset..][0..fq_size], ctx.points_b2[pos_src + 3 * fq_size ..][0..fq_size]);
                @memcpy(ctx.neg_y_c0.?[dst_offset..][0..fq_size], negated_bytes[neg_src + 2 * fq_size ..][0..fq_size]);
                @memcpy(ctx.neg_y_c1.?[dst_offset..][0..fq_size], negated_bytes[neg_src + 3 * fq_size ..][0..fq_size]);
            }
        }
    };

    // Spawn scalar preprocessing thread (overlaps with point extraction + Metal init)
    var scalar_ctx: ScalarPrepCtx = undefined;
    var scalar_thread: ?std.Thread = null;
    {
        const private_bytes = if (n_private > 0)
            wtns.data[(nPublic + 1) * fr_bytes .. nVars * fr_bytes]
        else
            null;
        scalar_ctx = ScalarPrepCtx{
            .allocator = allocator,
            .witness_bytes = witness_bytes,
            .private_bytes = private_bytes,
        };
        scalar_thread = try std.Thread.spawn(.{}, ScalarPrepCtx.run, .{&scalar_ctx});
    }

    var qap_ctx = QapCtx{
        .allocator = allocator,
        .zkey_data = zkey_data,
        .witness_data = witness_data,
        .qap_info = cached.qap_info,
    };
    const qap_thread = try std.Thread.spawn(.{}, QapCtx.run, .{&qap_ctx});
    defer {
        qap_thread.join();
        stage_times[2] = qap_ctx.elapsed_ms;
        if (qap_ctx.result) |qap_result| {
            allocator.free(qap_result.a);
            allocator.free(qap_result.b);
            allocator.free(qap_result.c);
            allocator.free(qap_result.points_h);
        }
    }

    const g2_points = try alignedPoints(cpu.curve.G2PointAffine, allocator, points_b2);
    defer if (g2_points.owned) |buf| allocator.free(buf);
    const g2_scalars = try alignedPoints(cpu.field.FrElement, allocator, witness_bytes);
    defer if (g2_scalars.owned) |buf| allocator.free(buf);
    // One chunk is enough work to hide thread startup and still leave Metal a
    // contiguous tail when the G1 MSMs finish.
    const g2_chunk: usize = 1 << 16;
    // Zig multiplies this many 64k chunks while Metal runs the G1 MSMs, then
    // Metal takes the tail. One chunk fills most of the G1 window on blackjack
    // showdown; further chunks slowed Metal by saturating memory. PROVER_G2_CPU_CHUNKS overrides it.
    const g2_cpu_budget: usize = blk: {
        if (std.c.getenv("PROVER_G2_CPU_CHUNKS")) |raw| {
            const text = std.mem.span(raw);
            if (std.fmt.parseInt(usize, text, 10)) |n| {
                break :blk @max(1, n);
            } else |_| {}
        }
        break :blk 1;
    };
    var g2_next: usize = 0;
    var cpu_g2_ctx = CpuG2Ctx{
        .points = g2_points.slice,
        .scalars = g2_scalars.slice,
        .chunk = g2_chunk,
        .budget = g2_cpu_budget,
        .next = &g2_next,
        .result = cpu.curve.g2_zero(),
    };
    const cpu_g2_thread = try std.Thread.spawn(.{}, CpuG2Ctx.run, .{&cpu_g2_ctx});
    var cpu_g2_joined = false;
    defer if (!cpu_g2_joined) cpu_g2_thread.join();

    var h_ctx: HCalcCtx = undefined;
    var h_thread: ?std.Thread = null;
    var t_h_start: f64 = 0;
    var g2_ctx: G2PrepCtx = undefined;
    var g2_thread: ?std.Thread = null;
    var t_g2_prep_start: f64 = 0;

    if (needs_metal) {
        prover = try MetalProver.init(allocator);
        stage_times[5] = getTimeMs() - t0;
        t0 = getTimeMs();

        // Launch H-calc on queue 1 in background thread
        h_ctx = HCalcCtx{
            .prover = prover.?,
            .allocator = allocator,
            .qap = &qap_ctx,
            .domainSize = domainSize,
            .n8r = n8r,
        };
        t_h_start = getTimeMs();
        h_thread = try std.Thread.spawn(.{}, HCalcCtx.run, .{&h_ctx});

        // Launch G2 point preprocessing in background thread (overlaps with G1 MSMs)
        g2_ctx = G2PrepCtx{
            .points_b2 = points_b2,
            .allocator = allocator,
        };
        t_g2_prep_start = getTimeMs();
        g2_thread = try std.Thread.spawn(.{}, G2PrepCtx.run, .{&g2_ctx});
    } else {
        stage_times[5] = 0;
        h_ctx = HCalcCtx{
            .prover = undefined,
            .allocator = allocator,
            .qap = &qap_ctx,
            .domainSize = domainSize,
            .n8r = n8r,
        };
        while (!@atomicLoad(bool, &qap_ctx.done, .acquire)) {
            std.Thread.yield() catch {};
        }
        if (qap_ctx.err) |e| return e;
        const qap_ready = qap_ctx.result orelse return error.HCalculationFailed;
        h_ctx.result = try calculateHGpuCpu(allocator, qap_ready.a, qap_ready.b, qap_ready.c, domainSize, n8r);
    }
    defer {
        if (h_thread) |thread| thread.join();
    }

    // 8. Join scalar preprocessing thread (ran in background during point extraction + Metal init)
    var sorted_full: ?mod.SortedWindows = null;
    var sorted_private: ?mod.SortedWindows = null;
    var sorted_h: ?mod.SortedWindows = null;
    defer if (sorted_full) |s| s.deinit(allocator);
    defer if (sorted_private) |s| s.deinit(allocator);
    defer if (sorted_h) |s| s.deinit(allocator);

    if (scalar_thread) |thread| {
        thread.join();
        scalar_thread = null;
    }
    if (scalar_ctx.err) |e| return e;
    sorted_full = scalar_ctx.sorted_full;
    sorted_private = scalar_ctx.sorted_private;
    stage_times[7] = getTimeMs() - t0;
    t0 = getTimeMs();

    // 9. Run MSMs — GPU-only via v6 single-kernel path
    // Overlap: run witness-dependent G1 MSMs on queue 2 while H-calc runs on queue 1
    //          and G2 MSM + H-MSM run on queue 3

    var pi_a: cpu.curve.G1Point = undefined;
    var pib1: cpu.curve.G1Point = undefined;
    var pi_c: cpu.curve.G1Point = cpu.curve.g1_zero();
    var pih: cpu.curve.G1Point = undefined;
    var pi_b: cpu.curve.G2Point = undefined;

    stage_times[7] = 0; // Init Metal already counted in stage 5

    if (needs_metal) {
        // Context for queue 3 thread: H-MSM (after H-calc finishes on queue 1)
        const Queue3Ctx = struct {
            prover: *MetalProver,
            allocator: std.mem.Allocator,
            h_thread_ptr: *?std.Thread,
            h_ctx_ptr: *HCalcCtx,
            points_h: []const u8,
            nVars: u32,
            t_h_start: f64,
            pih: ?cpu.curve.G1Point = null,
            h_calc_ms: f64 = 0,
            err: ?anyerror = null,

            fn run(ctx: *@This()) void {
                // Join H-calc thread and run H-MSM on queue 2
                if (ctx.h_thread_ptr.*) |thread| {
                    thread.join();
                    ctx.h_thread_ptr.* = null;
                }
                if (ctx.h_ctx_ptr.err) |e| { ctx.err = e; return; }
                ctx.h_calc_ms = getTimeMs() - ctx.t_h_start;
                const h_coeffs = ctx.h_ctx_ptr.result orelse { ctx.err = error.HCalculationFailed; return; };
                defer ctx.allocator.free(h_coeffs);

                const h_bytes = std.mem.sliceAsBytes(h_coeffs);
                const sorted_h_local = mod.preprocessSortedWindows(ctx.allocator, h_bytes, 8) catch |e| { ctx.err = e; return; };
                defer sorted_h_local.deinit(ctx.allocator);

                const h_jobs = &[_]MetalProver.MSMJob{
                    .{ .points = ctx.points_h, .sorted = sorted_h_local },
                };
                const pih_results = ctx.prover.msmG1_v5_batch(h_jobs, ctx.prover.command_queue_2) catch |e| { ctx.err = e; return; };
                defer {
                    for (pih_results) |r| ctx.allocator.free(r);
                    ctx.allocator.free(pih_results);
                }
                ctx.pih = accumulateG1(pih_results[0]);
            }
        };

        var q3_ctx = Queue3Ctx{
            .prover = prover.?,
            .allocator = allocator,
            .h_thread_ptr = &h_thread,
            .h_ctx_ptr = &h_ctx,
            .points_h = points_h,
            .nVars = nVars,
            .t_h_start = t_h_start,
        };
        const q3_thread = try std.Thread.spawn(.{}, Queue3Ctx.run, .{&q3_ctx});
        var q3_joined = false;
        defer if (!q3_joined) q3_thread.join();

        // 9a. Run non-H G1 MSMs on queue 2 (concurrently with H-calc on queue 1)
        const g1_nonh_jobs = if (n_private > 0 and sorted_private != null)
            &[_]MetalProver.MSMJob{
                .{ .points = points_a, .sorted = sorted_full.? },
                .{ .points = points_b1, .sorted = sorted_full.? },
                .{ .points = points_c, .sorted = sorted_private.? },
            }
        else
            &[_]MetalProver.MSMJob{
                .{ .points = points_a, .sorted = sorted_full.? },
                .{ .points = points_b1, .sorted = sorted_full.? },
            };

        // G1 MSMs on queue 2 while Zig threads own G2 chunks and H-calc uses queue 1.
        // G2 stays off a second GPU queue: that dispatch produced invalid proofs.
        const t_g1 = getTimeMs();
        const g1_nonh_results = try prover.?.msmG1_v5_batch(g1_nonh_jobs, prover.?.command_queue_2);
        const g1_ms = getTimeMs() - t_g1;
        defer {
            for (g1_nonh_results) |res| allocator.free(res);
            allocator.free(g1_nonh_results);
        }

        // Prep overlapped the G1 MSMs. Metal takes whatever G2 chunks Zig has not claimed.
        if (g2_thread) |thread| {
            thread.join();
            g2_thread = null;
        }
        if (g2_ctx.err) |e| return e;

        const n_g2 = g2_points.slice.len;
        const metal_start = @min(n_g2, g2_cpu_budget * g2_chunk);
        const metal_points = n_g2 - metal_start;
        var gpu_b = cpu.curve.g2_zero();
        var metal_g2_ms: f64 = 0;
        if (metal_points > 0) {
            const t_metal_g2 = getTimeMs();
            const fq_size = @sizeOf([4]u64);
            const byte_off = metal_start * fq_size;
            const byte_len = metal_points * fq_size;
            const fr_size = @sizeOf(cpu.field.FrElement);
            const scalar_suffix = witness_bytes[metal_start * fr_size .. n_g2 * fr_size];
            const sorted_suffix = try mod.preprocessSortedWindows(allocator, scalar_suffix, 8);
            defer sorted_suffix.deinit(allocator);
            const g2_config = mod.MSMConfig{
                .n_points = @intCast(metal_points),
                .n_windows = 32,
                .window_size = 8,
                .n_buckets = 256,
            };
            var g2_handle = try prover.?.msmG2_v6_soA_async(
                g2_ctx.x_c0.?[byte_off..][0..byte_len],
                g2_ctx.x_c1.?[byte_off..][0..byte_len],
                g2_ctx.y_c0.?[byte_off..][0..byte_len],
                g2_ctx.y_c1.?[byte_off..][0..byte_len],
                g2_ctx.neg_y_c0.?[byte_off..][0..byte_len],
                g2_ctx.neg_y_c1.?[byte_off..][0..byte_len],
                sorted_suffix,
                g2_config,
                prover.?.command_queue_2,
            );
            // Zig finishes its last claimed chunk while Metal multiplies the tail.
            cpu_g2_thread.join();
            cpu_g2_joined = true;
            if (cpu_g2_ctx.err) |e| return e;
            const pi_b_windows = try g2_handle.waitAndDownload();
            defer allocator.free(pi_b_windows);
            g2_handle.deinit();
            gpu_b = accumulateG2(pi_b_windows);
            metal_g2_ms = getTimeMs() - t_metal_g2;
        } else {
            cpu_g2_thread.join();
            cpu_g2_joined = true;
            if (cpu_g2_ctx.err) |e| return e;
        }
        pi_b = cpu.curve.g2_add(cpu_g2_ctx.result, gpu_b);
        std.debug.print(
            "hybrid G2: zig {d} pts in {d:.0} ms, metal {d} pts in {d:.0} ms, G1 {d:.0} ms\n",
            .{ cpu_g2_ctx.points_done, cpu_g2_ctx.elapsed_ms, metal_points, metal_g2_ms, g1_ms },
        );

        // Wait for queue 3 thread (H-MSM on queue_2) to finish
        q3_thread.join();
        q3_joined = true;
        if (q3_ctx.err) |e| return e;
        stage_times[6] = q3_ctx.h_calc_ms;

        defer {
            if (g2_ctx.x_c0) |buf| allocator.free(buf);
            if (g2_ctx.x_c1) |buf| allocator.free(buf);
            if (g2_ctx.y_c0) |buf| allocator.free(buf);
            if (g2_ctx.y_c1) |buf| allocator.free(buf);
            if (g2_ctx.neg_y_c0) |buf| allocator.free(buf);
            if (g2_ctx.neg_y_c1) |buf| allocator.free(buf);
        }

        // Accumulate window results
        const t_acc = getTimeMs();
        pi_a = accumulateG1(g1_nonh_results[0]);
        pib1 = accumulateG1(g1_nonh_results[1]);
        if (n_private > 0 and g1_nonh_results.len > 2) pi_c = accumulateG1(g1_nonh_results[2]);
        pih = q3_ctx.pih.?;
        const acc_ms = getTimeMs() - t_acc;
        stage_times[8] = getTimeMs() - t0;
        std.debug.print("MSM breakdown: accumulate={d:.2}ms, total={d:.2}ms, qap={d:.0}ms, H={d:.0}ms\n", .{ acc_ms, stage_times[8], qap_ctx.elapsed_ms, q3_ctx.h_calc_ms });
        t0 = getTimeMs();
    } else {
        // CPU fallback path (sequential)
        const h_coeffs = h_ctx.result orelse return error.HCalculationFailed;
        defer allocator.free(h_coeffs);

        const h_bytes = std.mem.sliceAsBytes(h_coeffs);
        sorted_h = try mod.preprocessSortedWindows(allocator, h_bytes, 8);

        // CPU MSM path not implemented in this function — needs_metal is always true
        return error.CPUMSMNotImplemented;
    }

    // 10. Proof accumulation already done above
    stage_times[9] = getTimeMs() - t0;
    t0 = getTimeMs();

    // 11. Assemble proof
    const r = options.r orelse cpu.field.fr_zero();
    const s = options.s orelse cpu.field.fr_zero();
    var asm_result = try cpu.assembler.assembleProof(allocator, zkey_data, witness_data, pi_a, pi_b, pib1, pi_c, pih, r, s);
    defer asm_result.deinit(allocator);
    stage_times[10] = getTimeMs() - t0;
    t0 = getTimeMs();

    // 12. Convert to cpu.ProofResult format
    const proof = try allocator.dupe(u8, asm_result.proof_json);
    const public = try allocator.dupe(u8, asm_result.public_json);
    stage_times[11] = getTimeMs() - t0;

    stage_times[2] = qap_ctx.elapsed_ms;

    if (profile) {
        const labels = [_][]const u8{
            "1. Read files",
            "2. Parse zkey",
            "3. Build QAP",
            "4. Extract witness",
            "5. Extract points",
            "6. Init Metal",
            "7. Calculate H",
            "8. Preprocess scalars",
            "9. MSMs",
            "10. Accumulate",
            "11. Assemble proof",
            "12. Convert result",
        };
        std.debug.print("\n=== Metal Prover Stage Breakdown (ms) ===\n", .{});
        var total: f64 = 0;
        for (labels, stage_times, 0..) |label, t, i| {
            std.debug.print("  [{d:>2}] {s:<22} {d:>8.2} ms\n", .{i+1, label, t});
            total += t;
        }
        std.debug.print("  Total: {d:.2} ms\n", .{total});
    }

    return cpu.ProofResult{
        .proof = proof,
        .public_signals = public,
    };
}
