const std = @import("std");

pub const e_jerk_gpu = @import("e_jerk_gpu");

pub const metal = @import("metal.zig");

pub const vulkan_enabled = @import("build_options").vulkan;

pub const vulkan = if (vulkan_enabled)
    @import("vulkan.zig")
else
    @import("vulkan_off.zig");

pub const GpuCapabilities = e_jerk_gpu.GpuCapabilities;
pub const AutoSelector = e_jerk_gpu.AutoSelector;
pub const Backend = e_jerk_gpu.Backend;

pub const MAX_GPU_BUFFER_SIZE: usize = 64 * 1024 * 1024;
pub const MIN_GPU_SIZE: usize = 128 * 1024;

// Embedded shader imports
pub const EMBEDDED_METAL_SHADER = if (@import("builtin").os.tag == .macos)
    @import("metal_shader").EMBEDDED_METAL_SHADER
else
    "";

/// GPU-aligned config struct for MSM — must match Metal shader layout
pub const MSMConfig = extern struct {
    n_points: u32,      // num_scalars
    n_windows: u32,     // num_windows
    window_size: u32,   // window_size
    n_buckets: u32,     // n_buckets
};

/// G1 projective point (xyzz), 128 bytes — layout must match Metal shader
pub const G1Point = extern struct {
    x: [4]u64,
    y: [4]u64,
    zz: [4]u64,
    zzz: [4]u64,
};

/// G2 projective point (xyzz over Fq2), 256 bytes
pub const G2Point = extern struct {
    x: [8]u64,
    y: [8]u64,
    zz: [8]u64,
    zzz: [8]u64,
};

/// G1 affine point, 64 bytes
pub const G1PointAffine = extern struct {
    x: [4]u64,
    y: [4]u64,
};

/// G2 affine point, 128 bytes
pub const G2PointAffine = extern struct {
    x: [8]u64,
    y: [8]u64,
};

/// Proof output from GPU (legacy / used by benchmarks)
pub const ProofResult = extern struct {
    pi_a_x: [4]u64,
    pi_a_y: [4]u64,
    pi_b_x: [8]u64,
    pi_b_y: [8]u64,
    pi_c_x: [4]u64,
    pi_c_y: [4]u64,
};

/// Prover configuration for backend selection
pub const ProverConfig = extern struct {
    n_vars: u32,
    n_public: u32,
    domain_size: u32,
    n_points: u32,
    bits_per_chunk: u32,
    n_chunks: u32,
    flags: u32,
    _pad: [2]u32 = .{0, 0},
};

/// Select optimal backend for a proving workload based on circuit size.
/// Returns .cpu for small circuits (< 100K constraints).
/// Returns .metal for macOS with larger circuits.
/// Uses the e_jerk_gpu.AutoSelector pattern.
pub fn selectBackend(n_vars: u32, domain_size: u32) Backend {
    const is_macos = @import("builtin").os.tag == .macos;

    // Estimate workload size: each constraint involves ~256 bytes of data
    const data_size = @as(usize, n_vars) * 256 + @as(usize, domain_size) * 32;

    const workload = e_jerk_gpu.WorkloadInfo{
        .data_size = data_size,
        .compute_intensity = 0.95, // MSM and FFT are very compute intensive
        .parallelizable = true,
        .memory_bound = false,
        .batch_size = 1,
        .custom_bias = 0,
    };

    const config = e_jerk_gpu.AutoSelectConfig{
        .min_gpu_size = 100_000, // ~100K constraints threshold
        .max_gpu_size = MAX_GPU_BUFFER_SIZE,
        .gpu_bias = 0,
        .preferred_gpu_backend = if (is_macos) .metal else .cpu,
    };

    const result = e_jerk_gpu.AutoSelector.initWithConfig(config).select(workload);
    return result.backend;
}

/// Preprocess scalars into signed-digit window indices for GPU MSM.
/// Output layout is (window, point) for contiguous per-window access.
/// Caller must free the returned slice.
pub fn preprocessSignedWindows(allocator: std.mem.Allocator, scalars: []const u8, window_size: u32) ![]i32 {
    const n_points = scalars.len / 32;
    const n_windows = @divExact(256, window_size);
    const n_buckets: i32 = @intCast(@as(u32, 1) << @intCast(window_size - 1));
    var result = try allocator.alloc(i32, n_points * n_windows);

    // Determine if all windows fit within a single byte (true for window_size=4,8)
    const all_single_byte = blk: {
        var w: usize = 0;
        while (w < n_windows) : (w += 1) {
            const bit_start: u32 = @intCast(w * window_size);
            const shift: u32 = bit_start % 8;
            if (shift + window_size > 8) break :blk false;
        }
        break :blk true;
    };

    if (all_single_byte and n_points >= 4) {
        const simd_len = (n_points / 4) * 4;
        var p: usize = 0;
        while (p < simd_len) : (p += 4) {
            var carry = @Vector(4, i32){ 0, 0, 0, 0 };
            for (0..n_windows) |w| {
                const bit_start: u32 = @intCast(w * window_size);
                const byte_start: usize = bit_start / 8;
                const shift: u32 = bit_start % 8;
                const mask = (@as(u64, 1) << @intCast(window_size)) - 1;

                const mask_splat = @as(@Vector(4, u64), @splat(mask));
                const shift_splat = @as(@Vector(4, u6), @splat(@intCast(shift)));

                const vals_u64 = @Vector(4, u64){
                    scalars[p * 32 + byte_start],
                    scalars[(p + 1) * 32 + byte_start],
                    scalars[(p + 2) * 32 + byte_start],
                    scalars[(p + 3) * 32 + byte_start],
                };
                const shifted = vals_u64 >> shift_splat;
                const window_vals = shifted & mask_splat;

                const vals_i32 = @Vector(4, i32){
                    @intCast(window_vals[0]),
                    @intCast(window_vals[1]),
                    @intCast(window_vals[2]),
                    @intCast(window_vals[3]),
                };
                var bucket_indices = vals_i32 + carry;
                const n_buckets_splat = @as(@Vector(4, i32), @splat(n_buckets));
                const n_buckets_2x_splat = @as(@Vector(4, i32), @splat(n_buckets * 2));
                const needs_reduce = bucket_indices >= n_buckets_splat;
                bucket_indices = @select(i32, needs_reduce, bucket_indices - n_buckets_2x_splat, bucket_indices);
                carry = @select(i32, needs_reduce, @as(@Vector(4, i32), @splat(1)), @as(@Vector(4, i32), @splat(0)));

                const arr: [4]i32 = @bitCast(bucket_indices);
                result[w * n_points + p + 0] = arr[0];
                result[w * n_points + p + 1] = arr[1];
                result[w * n_points + p + 2] = arr[2];
                result[w * n_points + p + 3] = arr[3];
            }
        }

        // Scalar fallback for remainder points
        while (p < n_points) : (p += 1) {
            var carry_scalar: i32 = 0;
            for (0..n_windows) |w| {
                const bit_start: u32 = @intCast(w * window_size);
                const byte_start: usize = bit_start / 8;
                const shift: u32 = bit_start % 8;
                const mask = (@as(u64, 1) << @intCast(window_size)) - 1;
                const val = (@as(u64, scalars[p * 32 + byte_start]) >> @intCast(shift)) & mask;

                var bucket_index: i32 = @as(i32, @intCast(val)) + carry_scalar;
                if (bucket_index >= n_buckets) {
                    bucket_index -= n_buckets * 2;
                    carry_scalar = 1;
                } else {
                    carry_scalar = 0;
                }
                result[w * n_points + p] = bucket_index;
            }
        }
    } else {
        // Original scalar path for cross-byte windows or very small inputs
        for (0..n_points) |p| {
            var carry: i32 = 0;
            for (0..n_windows) |w| {
                const bit_start: u32 = @intCast(w * window_size);
                const byte_start: usize = bit_start / 8;
                const shift: u32 = bit_start % 8;

                var val: u64 = 0;
                if (shift + window_size <= 8) {
                    const mask = (@as(u64, 1) << @intCast(window_size)) - 1;
                    val = (@as(u64, scalars[p * 32 + byte_start]) >> @intCast(shift)) & mask;
                } else {
                    const low_bits: u32 = 8 - shift;
                    const high_bits: u32 = window_size - low_bits;
                    const low_mask = (@as(u64, 1) << @intCast(low_bits)) - 1;
                    const high_mask = (@as(u64, 1) << @intCast(high_bits)) - 1;
                    val = (@as(u64, scalars[p * 32 + byte_start]) >> @intCast(shift)) & low_mask;
                    if (byte_start + 1 < 32) {
                        val |= (@as(u64, scalars[p * 32 + byte_start + 1]) & high_mask) << @intCast(low_bits);
                    }
                }

                var bucket_index: i32 = @as(i32, @intCast(val)) + carry;
                if (bucket_index >= n_buckets) {
                    bucket_index -= n_buckets * 2;
                    carry = 1;
                } else {
                    carry = 0;
                }
                result[w * n_points + p] = bucket_index;
            }
        }
    }

    return result;
}

/// Preprocessed sorted-bucket data for v5 MSM.
/// Uses signed-digit preprocessing (same as v4), then sorts points by
/// signed bucket so each GPU thread gets a contiguous range.
pub const SortedWindows = struct {
    bucket_offsets: []u32,
    sorted_indices: []u32,

    pub fn deinit(self: SortedWindows, allocator: std.mem.Allocator) void {
        allocator.free(self.bucket_offsets);
        allocator.free(self.sorted_indices);
    }
};

/// Preprocess scalars into signed-digit window indices, then sort points
/// by signed bucket for each window.
///
/// GPU bucket mapping (2*half_buckets buckets total):
///   +1 → gpu_bucket 0,  +2 → gpu_bucket 1,  ...,  +half_buckets → gpu_bucket half_buckets-1
///   -1 → gpu_bucket half_buckets,  -2 → gpu_bucket half_buckets+1,  ...,  -half_buckets → gpu_bucket 2*half_buckets-1
///
/// Separating positive and negative buckets eliminates the need to re-read
/// signed bucket data in the GPU kernel (removes a massive memory-bandwidth
/// bottleneck and branch divergence).
pub fn preprocessSortedWindows(allocator: std.mem.Allocator, scalars: []const u8, window_size: u32) !SortedWindows {
    const signed_windows = try preprocessSignedWindows(allocator, scalars, window_size);
    defer allocator.free(signed_windows);
    const n_points = scalars.len / 32;
    const n_windows = @divExact(256, window_size);
    const num_buckets: usize = @intCast(@as(u32, 1) << @intCast(window_size));
    const half_buckets = num_buckets / 2;

    // bucket_offsets: n_windows * (num_buckets + 1) entries
    var bucket_offsets = try allocator.alloc(u32, n_windows * (num_buckets + 1));

    // First pass: count per bucket per window
    var counts = try allocator.alloc(u32, n_windows * num_buckets);
    defer allocator.free(counts);
    @memset(counts, 0);

    for (0..n_points) |p| {
        for (0..n_windows) |w| {
            const bucket_idx = signed_windows[w * n_points + p];
            if (bucket_idx != 0) {
                // Map signed bucket to GPU bucket:
                // positive: 0..half_buckets-1 for +1..+half_buckets
                // negative: half_buckets..num_buckets-1 for -1..-half_buckets
                const gpu_bucket: usize = if (bucket_idx > 0)
                    @intCast(bucket_idx - 1)
                else
                    half_buckets + @as(usize, @intCast(-bucket_idx - 1));
                counts[w * num_buckets + gpu_bucket] += 1;
            }
        }
    }

    // Build prefix sums (offsets) — absolute offsets into sorted_indices
    var cumulative: u32 = 0;
    for (0..n_windows) |w| {
        bucket_offsets[w * (num_buckets + 1)] = cumulative;
        for (1..num_buckets + 1) |b| {
            bucket_offsets[w * (num_buckets + 1) + b] = bucket_offsets[w * (num_buckets + 1) + b - 1] + counts[w * num_buckets + b - 1];
        }
        // After this window, add its total count to cumulative
        cumulative = bucket_offsets[w * (num_buckets + 1) + num_buckets];
    }

    // Compute total size
    var total_sorted: usize = 0;
    for (counts) |c| {
        total_sorted += c;
    }
    var sorted_indices = try allocator.alloc(u32, total_sorted);

    // Second pass: scatter point indices
    var write_pos = try allocator.alloc(u32, n_windows * num_buckets);
    defer allocator.free(write_pos);
    for (0..n_windows) |w| {
        for (0..num_buckets) |b| {
            write_pos[w * num_buckets + b] = bucket_offsets[w * (num_buckets + 1) + b];
        }
    }

    for (0..n_points) |p| {
        for (0..n_windows) |w| {
            const bucket_idx = signed_windows[w * n_points + p];
            if (bucket_idx != 0) {
                const gpu_bucket: usize = if (bucket_idx > 0)
                    @intCast(bucket_idx - 1)
                else
                    half_buckets + @as(usize, @intCast(-bucket_idx - 1));
                const pos = write_pos[w * num_buckets + gpu_bucket];
                sorted_indices[pos] = @intCast(p);
                write_pos[w * num_buckets + gpu_bucket] += 1;
            }
        }
    }

    return SortedWindows{
        .bucket_offsets = bucket_offsets,
        .sorted_indices = sorted_indices,
    };
}

/// Preprocess scalars into unsigned window indices, then sort points
/// by unsigned bucket for each window.
///
/// Used for G2 MSM where signed-digit representation is not needed.
/// GPU bucket mapping: window_value 1..num_buckets → gpu_bucket 0..num_buckets-1
/// window_value 0 is skipped (no bucket).
pub fn preprocessUnsignedSortedWindows(allocator: std.mem.Allocator, scalars: []const u8, window_size: u32) !SortedWindows {
    const n_points = scalars.len / 32;
    const n_windows = @divExact(256, window_size);
    const num_buckets: usize = @intCast((@as(u32, 1) << @intCast(window_size)) - 1);

    // bucket_offsets: n_windows * (num_buckets + 1) entries
    var bucket_offsets = try allocator.alloc(u32, n_windows * (num_buckets + 1));

    // First pass: count per bucket per window
    var counts = try allocator.alloc(u32, n_windows * num_buckets);
    defer allocator.free(counts);
    @memset(counts, 0);

    for (0..n_points) |p| {
        for (0..n_windows) |w| {
            const bit_start: u32 = @intCast(w * window_size);
            const byte_start: usize = bit_start / 8;
            const shift: u32 = bit_start % 8;

            var val: u64 = 0;
            if (shift + window_size <= 8) {
                const mask = (@as(u64, 1) << @intCast(window_size)) - 1;
                val = (@as(u64, scalars[p * 32 + byte_start]) >> @intCast(shift)) & mask;
            } else {
                const low_bits: u32 = 8 - shift;
                const high_bits: u32 = window_size - low_bits;
                const low_mask = (@as(u64, 1) << @intCast(low_bits)) - 1;
                const high_mask = (@as(u64, 1) << @intCast(high_bits)) - 1;
                val = (@as(u64, scalars[p * 32 + byte_start]) >> @intCast(shift)) & low_mask;
                if (byte_start + 1 < 32) {
                    val |= (@as(u64, scalars[p * 32 + byte_start + 1]) & high_mask) << @intCast(low_bits);
                }
            }

            if (val != 0) {
                const gpu_bucket = val - 1;
                counts[w * num_buckets + gpu_bucket] += 1;
            }
        }
    }

    // Build prefix sums (offsets) — absolute offsets into sorted_indices
    var cumulative: u32 = 0;
    for (0..n_windows) |w| {
        bucket_offsets[w * (num_buckets + 1)] = cumulative;
        for (1..num_buckets + 1) |b| {
            bucket_offsets[w * (num_buckets + 1) + b] = bucket_offsets[w * (num_buckets + 1) + b - 1] + counts[w * num_buckets + b - 1];
        }
        cumulative = bucket_offsets[w * (num_buckets + 1) + num_buckets];
    }

    // Compute total size
    var total_sorted: usize = 0;
    for (counts) |c| {
        total_sorted += c;
    }
    var sorted_indices = try allocator.alloc(u32, total_sorted);

    // Second pass: scatter point indices
    var write_pos = try allocator.alloc(u32, n_windows * num_buckets);
    defer allocator.free(write_pos);
    for (0..n_windows) |w| {
        for (0..num_buckets) |b| {
            write_pos[w * num_buckets + b] = bucket_offsets[w * (num_buckets + 1) + b];
        }
    }

    for (0..n_points) |p| {
        for (0..n_windows) |w| {
            const bit_start: u32 = @intCast(w * window_size);
            const byte_start: usize = bit_start / 8;
            const shift: u32 = bit_start % 8;

            var val: u64 = 0;
            if (shift + window_size <= 8) {
                const mask = (@as(u64, 1) << @intCast(window_size)) - 1;
                val = (@as(u64, scalars[p * 32 + byte_start]) >> @intCast(shift)) & mask;
            } else {
                const low_bits: u32 = 8 - shift;
                const high_bits: u32 = window_size - low_bits;
                const low_mask = (@as(u64, 1) << @intCast(low_bits)) - 1;
                const high_mask = (@as(u64, 1) << @intCast(high_bits)) - 1;
                val = (@as(u64, scalars[p * 32 + byte_start]) >> @intCast(shift)) & low_mask;
                if (byte_start + 1 < 32) {
                    val |= (@as(u64, scalars[p * 32 + byte_start + 1]) & high_mask) << @intCast(low_bits);
                }
            }

            if (val != 0) {
                const gpu_bucket = val - 1;
                const pos = write_pos[w * num_buckets + gpu_bucket];
                sorted_indices[pos] = @intCast(p);
                write_pos[w * num_buckets + gpu_bucket] += 1;
            }
        }
    }

    return SortedWindows{
        .bucket_offsets = bucket_offsets,
        .sorted_indices = sorted_indices,
    };
}

/// Attempt to initialize the Metal prover backend.
/// Lazily imports the Metal module so the Objective-C runtime is only
/// required when this function is actually called.
pub fn initMetalProver(allocator: std.mem.Allocator) !void {
    if (@import("builtin").os.tag != .macos) {
        return error.BackendNotAvailable;
    }
    const m = @import("metal.zig");
    const prover = try m.MetalProver.init(allocator);
    prover.deinit();
}
