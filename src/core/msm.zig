const std = @import("std");
const field = @import("field.zig");
const curve = @import("curve.zig");

// ============================================================================
// G1 Multi-Scalar Multiplication (CPU)
// ============================================================================

pub fn msm_g1(
    allocator: std.mem.Allocator,
    points: []const curve.G1PointAffine,
    scalars: []const field.FrElement,
) !curve.G1Point {
    std.debug.assert(points.len == scalars.len);

    if (points.len < 500) {
        return msm_g1_small(points, scalars);
    }

    return msm_g1_pippenger(allocator, points, scalars);
}

pub fn msm_g1_small(points: []const curve.G1PointAffine, scalars: []const field.FrElement) curve.G1Point {
    var result = curve.g1_zero();
    for (points, scalars) |pt, scalar| {
        if (field.fq_is_zero(pt.x) and field.fq_is_zero(pt.y)) continue;
        const mul_result = curve.g1_mul_affine(pt, scalar);
        result = curve.g1_add(result, mul_result);
    }
    return result;
}

pub fn msm_g2(
    allocator: std.mem.Allocator,
    points: []const curve.G2PointAffine,
    scalars: []const field.FrElement,
) !curve.G2Point {
    std.debug.assert(points.len == scalars.len);

    if (points.len < 500) {
        return msm_g2_small(points, scalars);
    }

    return msm_g2_pippenger(allocator, points, scalars);
}

pub fn msm_g2_small(points: []const curve.G2PointAffine, scalars: []const field.FrElement) curve.G2Point {
    var result = curve.g2_zero();
    for (points, scalars) |pt, scalar| {
        if (field.fq2_is_zero(pt.x) and field.fq2_is_zero(pt.y)) continue;
        const proj = curve.g2_affine_to_projective(pt);
        const mul_result = curve.g2_mul(proj, scalar);
        result = curve.g2_add(result, mul_result);
    }
    return result;
}

const PippengerContextG2 = struct {
    points: []const curve.G2PointAffine,
    scalars: []const field.FrElement,
    window_sums: []curve.G2Point,
    window_size: usize,
    window_mask: u64,
    start_window: usize,
    end_window: usize,
};

fn pippengerG2Worker(ctx: PippengerContextG2) void {
    const bucket_count = @as(usize, 1) << @intCast(ctx.window_size);
    var buckets = std.heap.c_allocator.alloc(curve.G2Point, bucket_count) catch return;
    defer std.heap.c_allocator.free(buckets);

    var w: usize = ctx.start_window;
    while (w < ctx.end_window) : (w += 1) {
        for (buckets) |*b| {
            b.* = curve.g2_zero();
        }

        const bit_offset = w * ctx.window_size;
        const word_idx = bit_offset / 64;
        const bit_in_word = bit_offset % 64;

        if (word_idx < 4) {
            const simd_len = (ctx.scalars.len / 4) * 4;

            if (bit_in_word + ctx.window_size <= 64) {
                // SIMD path: window fits in single word
                const shift_splat = @as(@Vector(4, u6), @splat(@intCast(bit_in_word)));
                const mask_splat = @as(@Vector(4, u64), @splat(ctx.window_mask));

                    var i: usize = 0;
                    while (i < simd_len) : (i += 4) {
                        const words_vec = @Vector(4, u64){
                            ctx.scalars[i][word_idx],
                            ctx.scalars[i + 1][word_idx],
                            ctx.scalars[i + 2][word_idx],
                            ctx.scalars[i + 3][word_idx],
                        };
                        const shifted = words_vec >> shift_splat;
                    const window_vals = shifted & mask_splat;

                    const window_arr: [4]u64 = @bitCast(window_vals);
                    for (window_arr, 0..) |window_val, j| {
                        if (window_val != 0) {
                            const pt = ctx.points[i + j];
                            if (!(field.fq2_is_zero(pt.x) and field.fq2_is_zero(pt.y))) {
                                const proj = curve.g2_affine_to_projective(pt);
                                buckets[window_val] = curve.g2_add(buckets[window_val], proj);
                            }
                        }
                    }
                }

                // Scalar fallback for remainder
                while (i < ctx.scalars.len) : (i += 1) {
                    const pt = ctx.points[i];
                    if (field.fq2_is_zero(pt.x) and field.fq2_is_zero(pt.y)) continue;
                    const word = ctx.scalars[i][word_idx];
                    const window_val = (word >> @intCast(bit_in_word)) & ctx.window_mask;
                    if (window_val != 0) {
                        const proj = curve.g2_affine_to_projective(pt);
                        buckets[window_val] = curve.g2_add(buckets[window_val], proj);
                    }
                }
            } else {
                // SIMD path: window crosses word boundary
                const low_bits = 64 - bit_in_word;
                const low_mask = (@as(u64, 1) << @intCast(low_bits)) - 1;
                const shift_splat = @as(@Vector(4, u6), @splat(@intCast(bit_in_word)));
                const low_mask_splat = @as(@Vector(4, u64), @splat(low_mask));
                const high_bits = ctx.window_size - low_bits;
                const high_mask = (@as(u64, 1) << @intCast(high_bits)) - 1;
                const high_mask_splat = @as(@Vector(4, u64), @splat(high_mask));
                const low_bits_splat = @as(@Vector(4, u6), @splat(@intCast(low_bits)));

                if (word_idx + 1 < 4) {
                    var i: usize = 0;
                    while (i < simd_len) : (i += 4) {
                        const words_vec = @Vector(4, u64){
                            ctx.scalars[i][word_idx],
                            ctx.scalars[i + 1][word_idx],
                            ctx.scalars[i + 2][word_idx],
                            ctx.scalars[i + 3][word_idx],
                        };
                        const next_words_vec = @Vector(4, u64){
                            ctx.scalars[i][word_idx + 1],
                            ctx.scalars[i + 1][word_idx + 1],
                            ctx.scalars[i + 2][word_idx + 1],
                            ctx.scalars[i + 3][word_idx + 1],
                        };
                        const low_part = (words_vec >> shift_splat) & low_mask_splat;
                        const high_part = (next_words_vec & high_mask_splat) << low_bits_splat;
                        const window_vals = low_part | high_part;

                        const window_arr: [4]u64 = @bitCast(window_vals);
                        for (window_arr, 0..) |window_val, j| {
                            if (window_val != 0) {
                                const pt = ctx.points[i + j];
                                if (!(field.fq2_is_zero(pt.x) and field.fq2_is_zero(pt.y))) {
                                    const proj = curve.g2_affine_to_projective(pt);
                                    buckets[window_val] = curve.g2_add(buckets[window_val], proj);
                                }
                            }
                        }
                    }

                    // Scalar fallback for remainder
                    while (i < ctx.scalars.len) : (i += 1) {
                        const pt = ctx.points[i];
                        if (field.fq2_is_zero(pt.x) and field.fq2_is_zero(pt.y)) continue;
                        const word = ctx.scalars[i][word_idx];
                        var window_val = (word >> @intCast(bit_in_word)) & low_mask;
                        window_val |= (ctx.scalars[i][word_idx + 1] & high_mask) << @intCast(low_bits);
                        if (window_val != 0) {
                            const proj = curve.g2_affine_to_projective(pt);
                            buckets[window_val] = curve.g2_add(buckets[window_val], proj);
                        }
                    }
                } else {
                    // word_idx + 1 >= 4, window crosses boundary but no next word
                    var i: usize = 0;
                    while (i < simd_len) : (i += 4) {
                        const words_vec = @Vector(4, u64){
                            ctx.scalars[i][word_idx],
                            ctx.scalars[i + 1][word_idx],
                            ctx.scalars[i + 2][word_idx],
                            ctx.scalars[i + 3][word_idx],
                        };
                        const window_vals = (words_vec >> shift_splat) & low_mask_splat;

                        const window_arr: [4]u64 = @bitCast(window_vals);
                        for (window_arr, 0..) |window_val, j| {
                            if (window_val != 0) {
                                const pt = ctx.points[i + j];
                                if (!(field.fq2_is_zero(pt.x) and field.fq2_is_zero(pt.y))) {
                                    const proj = curve.g2_affine_to_projective(pt);
                                    buckets[window_val] = curve.g2_add(buckets[window_val], proj);
                                }
                            }
                        }
                    }

                    while (i < ctx.scalars.len) : (i += 1) {
                        const pt = ctx.points[i];
                        if (field.fq2_is_zero(pt.x) and field.fq2_is_zero(pt.y)) continue;
                        const word = ctx.scalars[i][word_idx];
                        const window_val = (word >> @intCast(bit_in_word)) & low_mask;
                        if (window_val != 0) {
                            const proj = curve.g2_affine_to_projective(pt);
                            buckets[window_val] = curve.g2_add(buckets[window_val], proj);
                        }
                    }
                }
            }
        }

        var acc = curve.g2_zero();
        var sum = curve.g2_zero();
        var i: usize = bucket_count - 1;
        while (i > 0) : (i -= 1) {
            acc = curve.g2_add(acc, buckets[i]);
            sum = curve.g2_add(sum, acc);
        }
        ctx.window_sums[w] = sum;
    }
}

pub fn msm_g2_pippenger(
    allocator: std.mem.Allocator,
    points: []const curve.G2PointAffine,
    scalars: []const field.FrElement,
) !curve.G2Point {
    const window_size: usize = 8;
    const scalar_bits = 256;
    const num_windows = (scalar_bits + window_size - 1) / window_size;
    const window_mask: u64 = (1 << window_size) - 1;

    const window_sums = try allocator.alloc(curve.G2Point, num_windows);
    defer allocator.free(window_sums);

    for (window_sums) |*ws| {
        ws.* = curve.g2_zero();
    }

    const num_cpus = @max(1, std.Thread.getCpuCount() catch 1);
    const windows_per_thread = @max(1, num_windows / num_cpus);
    const num_threads = @min(num_cpus, num_windows);

    var threads: []std.Thread = &[_]std.Thread{};
    var threads_needs_free = false;
    defer if (threads_needs_free) allocator.free(threads);

    if (allocator.alloc(std.Thread, num_threads)) |t| {
        threads = t;
        threads_needs_free = true;

        var ti: usize = 0;
        while (ti < num_threads) : (ti += 1) {
            const start_window = ti * windows_per_thread;
            const end_window = if (ti == num_threads - 1) num_windows else (ti + 1) * windows_per_thread;

            const ctx = PippengerContextG2{
                .points = points,
                .scalars = scalars,
                .window_sums = window_sums,
                .window_size = window_size,
                .window_mask = window_mask,
                .start_window = start_window,
                .end_window = end_window,
            };

            threads[ti] = std.Thread.spawn(.{}, pippengerG2Worker, .{ctx}) catch {
                pippengerG2Worker(ctx);
                continue;
            };
        }

        for (threads) |thread| {
            thread.join();
        }
    } else |_| {
        pippengerG2Worker(.{
            .points = points,
            .scalars = scalars,
            .window_sums = window_sums,
            .window_size = window_size,
            .window_mask = window_mask,
            .start_window = 0,
            .end_window = num_windows,
        });
    }

    var result = curve.g2_zero();
    var w2: usize = num_windows;
    while (w2 > 0) : (w2 -= 1) {
        var d: usize = 0;
        while (d < window_size) : (d += 1) {
            result = curve.g2_dbl(result);
        }
        result = curve.g2_add(result, window_sums[w2 - 1]);
    }

    return result;
}

const PippengerContextG1 = struct {
    points: []const curve.G1PointAffine,
    scalars: []const field.FrElement,
    window_sums: []curve.G1Point,
    window_size: usize,
    window_mask: u64,
    start_window: usize,
    end_window: usize,
};

fn pippengerG1Worker(ctx: PippengerContextG1) void {
    const bucket_count = @as(usize, 1) << @intCast(ctx.window_size);
    var buckets = std.heap.c_allocator.alloc(curve.G1Point, bucket_count) catch return;
    defer std.heap.c_allocator.free(buckets);

    var w: usize = ctx.start_window;
    while (w < ctx.end_window) : (w += 1) {
        for (buckets) |*b| {
            b.* = curve.g1_zero();
        }

        const bit_offset = w * ctx.window_size;
        const word_idx = bit_offset / 64;
        const bit_in_word = bit_offset % 64;

        if (word_idx < 4) {
            const simd_len = (ctx.scalars.len / 4) * 4;

            if (bit_in_word + ctx.window_size <= 64) {
                // SIMD path: window fits in single word
                const shift_splat = @as(@Vector(4, u6), @splat(@intCast(bit_in_word)));
                const mask_splat = @as(@Vector(4, u64), @splat(ctx.window_mask));

                    var i: usize = 0;
                    while (i < simd_len) : (i += 4) {
                        const words_vec = @Vector(4, u64){
                            ctx.scalars[i][word_idx],
                            ctx.scalars[i + 1][word_idx],
                            ctx.scalars[i + 2][word_idx],
                            ctx.scalars[i + 3][word_idx],
                        };
                        const shifted = words_vec >> shift_splat;
                    const window_vals = shifted & mask_splat;

                    const window_arr: [4]u64 = @bitCast(window_vals);
                    for (window_arr, 0..) |window_val, j| {
                        if (window_val != 0) {
                            const pt = ctx.points[i + j];
                            if (!(field.fq_is_zero(pt.x) and field.fq_is_zero(pt.y))) {
                                const proj = curve.g1_affine_to_projective(pt);
                                buckets[window_val] = curve.g1_add(buckets[window_val], proj);
                            }
                        }
                    }
                }

                // Scalar fallback for remainder
                while (i < ctx.scalars.len) : (i += 1) {
                    const pt = ctx.points[i];
                    if (field.fq_is_zero(pt.x) and field.fq_is_zero(pt.y)) continue;
                    const word = ctx.scalars[i][word_idx];
                    const window_val = (word >> @intCast(bit_in_word)) & ctx.window_mask;
                    if (window_val != 0) {
                        const proj = curve.g1_affine_to_projective(pt);
                        buckets[window_val] = curve.g1_add(buckets[window_val], proj);
                    }
                }
            } else {
                // SIMD path: window crosses word boundary
                const low_bits = 64 - bit_in_word;
                const low_mask = (@as(u64, 1) << @intCast(low_bits)) - 1;
                const shift_splat = @as(@Vector(4, u6), @splat(@intCast(bit_in_word)));
                const low_mask_splat = @as(@Vector(4, u64), @splat(low_mask));
                const high_bits = ctx.window_size - low_bits;
                const high_mask = (@as(u64, 1) << @intCast(high_bits)) - 1;
                const high_mask_splat = @as(@Vector(4, u64), @splat(high_mask));
                const low_bits_splat = @as(@Vector(4, u6), @splat(@intCast(low_bits)));

                if (word_idx + 1 < 4) {
                    var i: usize = 0;
                    while (i < simd_len) : (i += 4) {
                        const words_vec = @Vector(4, u64){
                            ctx.scalars[i][word_idx],
                            ctx.scalars[i + 1][word_idx],
                            ctx.scalars[i + 2][word_idx],
                            ctx.scalars[i + 3][word_idx],
                        };
                        const next_words_vec = @Vector(4, u64){
                            ctx.scalars[i][word_idx + 1],
                            ctx.scalars[i + 1][word_idx + 1],
                            ctx.scalars[i + 2][word_idx + 1],
                            ctx.scalars[i + 3][word_idx + 1],
                        };
                        const low_part = (words_vec >> shift_splat) & low_mask_splat;
                        const high_part = (next_words_vec & high_mask_splat) << low_bits_splat;
                        const window_vals = low_part | high_part;

                        const window_arr: [4]u64 = @bitCast(window_vals);
                        for (window_arr, 0..) |window_val, j| {
                            if (window_val != 0) {
                                const pt = ctx.points[i + j];
                                if (!(field.fq_is_zero(pt.x) and field.fq_is_zero(pt.y))) {
                                    const proj = curve.g1_affine_to_projective(pt);
                                    buckets[window_val] = curve.g1_add(buckets[window_val], proj);
                                }
                            }
                        }
                    }

                    // Scalar fallback for remainder
                    while (i < ctx.scalars.len) : (i += 1) {
                        const pt = ctx.points[i];
                        if (field.fq_is_zero(pt.x) and field.fq_is_zero(pt.y)) continue;
                        const word = ctx.scalars[i][word_idx];
                        var window_val = (word >> @intCast(bit_in_word)) & low_mask;
                        window_val |= (ctx.scalars[i][word_idx + 1] & high_mask) << @intCast(low_bits);
                        if (window_val != 0) {
                            const proj = curve.g1_affine_to_projective(pt);
                            buckets[window_val] = curve.g1_add(buckets[window_val], proj);
                        }
                    }
                } else {
                    // word_idx + 1 >= 4, window crosses boundary but no next word
                    var i: usize = 0;
                    while (i < simd_len) : (i += 4) {
                        const words_vec = @Vector(4, u64){
                            ctx.scalars[i][word_idx],
                            ctx.scalars[i + 1][word_idx],
                            ctx.scalars[i + 2][word_idx],
                            ctx.scalars[i + 3][word_idx],
                        };
                        const window_vals = (words_vec >> shift_splat) & low_mask_splat;

                        const window_arr: [4]u64 = @bitCast(window_vals);
                        for (window_arr, 0..) |window_val, j| {
                            if (window_val != 0) {
                                const pt = ctx.points[i + j];
                                if (!(field.fq_is_zero(pt.x) and field.fq_is_zero(pt.y))) {
                                    const proj = curve.g1_affine_to_projective(pt);
                                    buckets[window_val] = curve.g1_add(buckets[window_val], proj);
                                }
                            }
                        }
                    }

                    while (i < ctx.scalars.len) : (i += 1) {
                        const pt = ctx.points[i];
                        if (field.fq_is_zero(pt.x) and field.fq_is_zero(pt.y)) continue;
                        const word = ctx.scalars[i][word_idx];
                        const window_val = (word >> @intCast(bit_in_word)) & low_mask;
                        if (window_val != 0) {
                            const proj = curve.g1_affine_to_projective(pt);
                            buckets[window_val] = curve.g1_add(buckets[window_val], proj);
                        }
                    }
                }
            }
        }

        var acc = curve.g1_zero();
        var sum = curve.g1_zero();
        var i: usize = bucket_count - 1;
        while (i > 0) : (i -= 1) {
            acc = curve.g1_add(acc, buckets[i]);
            sum = curve.g1_add(sum, acc);
        }
        ctx.window_sums[w] = sum;
    }
}

pub fn msm_g1_pippenger(
    allocator: std.mem.Allocator,
    points: []const curve.G1PointAffine,
    scalars: []const field.FrElement,
) !curve.G1Point {
    const window_size: usize = 8;
    const scalar_bits = 256;
    const num_windows = (scalar_bits + window_size - 1) / window_size;
    const window_mask: u64 = (1 << window_size) - 1;

    const window_sums = try allocator.alloc(curve.G1Point, num_windows);
    defer allocator.free(window_sums);

    for (window_sums) |*ws| {
        ws.* = curve.g1_zero();
    }

    // Parallelize window processing across available CPU cores
    const num_cpus = @max(1, std.Thread.getCpuCount() catch 1);
    const windows_per_thread = @max(1, num_windows / num_cpus);
    const num_threads = @min(num_cpus, num_windows);

    var threads: []std.Thread = &[_]std.Thread{};
    var threads_needs_free = false;
    defer if (threads_needs_free) allocator.free(threads);

    if (allocator.alloc(std.Thread, num_threads)) |t| {
        threads = t;
        threads_needs_free = true;

        var ti: usize = 0;
        while (ti < num_threads) : (ti += 1) {
            const start_window = ti * windows_per_thread;
            const end_window = if (ti == num_threads - 1) num_windows else (ti + 1) * windows_per_thread;

            const ctx = PippengerContextG1{
                .points = points,
                .scalars = scalars,
                .window_sums = window_sums,
                .window_size = window_size,
                .window_mask = window_mask,
                .start_window = start_window,
                .end_window = end_window,
            };

            threads[ti] = std.Thread.spawn(.{}, pippengerG1Worker, .{ctx}) catch {
                pippengerG1Worker(ctx);
                continue;
            };
        }

        for (threads) |thread| {
            thread.join();
        }
    } else |_| {
        pippengerG1Worker(.{
            .points = points,
            .scalars = scalars,
            .window_sums = window_sums,
            .window_size = window_size,
            .window_mask = window_mask,
            .start_window = 0,
            .end_window = num_windows,
        });
    }

    var result = curve.g1_zero();
    var w2: usize = num_windows;
    while (w2 > 0) : (w2 -= 1) {
        var d: usize = 0;
        while (d < window_size) : (d += 1) {
            result = curve.g1_dbl(result);
        }
        result = curve.g1_add(result, window_sums[w2 - 1]);
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "msm 3 points" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const points = &[_]curve.G1PointAffine{ g_affine, g_affine, g_affine };
    const scalars = &[_]field.FrElement{
        field.fr_from_u64(1),
        field.fr_from_u64(2),
        field.fr_from_u64(3),
    };
    const result = try msm_g1(std.testing.allocator, points, scalars);
    const expected = curve.g1_mul(g, field.fr_from_u64(6));
    try std.testing.expect(curve.g1_eq(result, expected));
}

test "msm small path direct" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const points = &[_]curve.G1PointAffine{ g_affine, g_affine, g_affine };
    const scalars = &[_]field.FrElement{
        field.fr_from_u64(1),
        field.fr_from_u64(2),
        field.fr_from_u64(3),
    };
    const result = msm_g1_small(points, scalars);
    const expected = curve.g1_mul(g, field.fr_from_u64(6));
    try std.testing.expect(curve.g1_eq(result, expected));
}
