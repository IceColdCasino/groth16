const std = @import("std");
const field = @import("field.zig");

// ============================================================================
// BN254 Fr FFT (Cooley-Tukey iterative, in-place)
// ============================================================================

fn parallelBitReverse(a: []field.FrElement, n: u32, log_n: u32) void {
    const num_threads = 16;
    const chunk_size = n / num_threads;
    var threads: [16]std.Thread = undefined;
    var thread_idx: usize = 0;
    while (thread_idx < num_threads) : (thread_idx += 1) {
        const start = thread_idx * chunk_size;
        const end = if (thread_idx == num_threads - 1) n else (thread_idx + 1) * chunk_size;
        threads[thread_idx] = std.Thread.spawn(.{}, struct {
            fn run(a_local: []field.FrElement, start_local: usize, end_local: usize, log_n_local: u32) void {
                var i: u32 = @intCast(start_local);
                const end_u32: u32 = @intCast(end_local);
                while (i < end_u32) : (i += 1) {
                    const j = bitReverse(i, log_n_local);
                    if (i < j) {
                        const tmp = a_local[i];
                        a_local[i] = a_local[j];
                        a_local[j] = tmp;
                    }
                }
            }
        }.run, .{ a, start, end, log_n }) catch unreachable;
    }
    for (0..num_threads) |t| {
        threads[t].join();
    }
}

fn parallelButterfly(a: []field.FrElement, n: u32, m: u32, half_m: u32, w_m: field.FrElement) void {
    const num_groups = n / m;
    if (num_groups >= 2 and n >= 4096) {
        const num_threads = @min(num_groups, 16);
        const groups_per_thread = num_groups / num_threads;
        var threads: [16]std.Thread = undefined;
        var thread_idx: usize = 0;
        while (thread_idx < num_threads) : (thread_idx += 1) {
            const start_group = thread_idx * groups_per_thread;
            const end_group = if (thread_idx == num_threads - 1) num_groups else (thread_idx + 1) * groups_per_thread;
            threads[thread_idx] = std.Thread.spawn(.{}, struct {
                fn run(a_local: []field.FrElement, start: usize, end: usize, m_local: u32, half_m_local: u32, w_m_local: field.FrElement) void {
                    var g: u32 = @intCast(start);
                    const end_u32: u32 = @intCast(end);
                    while (g < end_u32) : (g += 1) {
                        const group_start = g * m_local;
                        var w = field.fr_one();
                        var j: u32 = 0;
                        while (j < half_m_local) : (j += 1) {
                            const t = field.fr_mul(a_local[group_start + j + half_m_local], w);
                            const u = a_local[group_start + j];
                            a_local[group_start + j] = field.fr_add(u, t);
                            a_local[group_start + j + half_m_local] = field.fr_sub(u, t);
                            w = field.fr_mul(w, w_m_local);
                        }
                    }
                }
            }.run, .{ a, start_group, end_group, m, half_m, w_m }) catch unreachable;
        }
        for (0..num_threads) |t| {
            threads[t].join();
        }
    } else {
        var group_start: u32 = 0;
        while (group_start < n) : (group_start += m) {
            var w = field.fr_one();
            var j: u32 = 0;
            while (j < half_m) : (j += 1) {
                const t = field.fr_mul(a[group_start + j + half_m], w);
                const u = a[group_start + j];
                a[group_start + j] = field.fr_add(u, t);
                a[group_start + j + half_m] = field.fr_sub(u, t);
                w = field.fr_mul(w, w_m);
            }
        }
    }
}

fn parallelScale(a: []field.FrElement, n: u32, scalar: field.FrElement) void {
    const num_threads = 16;
    const chunk_size = n / num_threads;
    var threads: [16]std.Thread = undefined;
    var thread_idx: usize = 0;
    while (thread_idx < num_threads) : (thread_idx += 1) {
        const start = thread_idx * chunk_size;
        const end = if (thread_idx == num_threads - 1) n else (thread_idx + 1) * chunk_size;
        threads[thread_idx] = std.Thread.spawn(.{}, struct {
            fn run(a_local: []field.FrElement, start_local: usize, end_local: usize, scalar_local: field.FrElement) void {
                var i: u32 = @intCast(start_local);
                const end_u32: u32 = @intCast(end_local);
                while (i < end_u32) : (i += 1) {
                    a_local[i] = field.fr_mul(a_local[i], scalar_local);
                }
            }
        }.run, .{ a, start, end, scalar }) catch unreachable;
    }
    for (0..num_threads) |t| {
        threads[t].join();
    }
}

pub fn fft_fr(a: []field.FrElement, n: u32) void {
    std.debug.assert(@popCount(n) == 1);
    std.debug.assert(a.len >= n);

    const log_n = @ctz(n);

    if (n >= 65536) {
        parallelBitReverse(a, n, log_n);
    } else {
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const j = bitReverse(i, log_n);
            if (i < j) {
                const tmp = a[i];
                a[i] = a[j];
                a[j] = tmp;
            }
        }
    }

    var s: u32 = 1;
    while (s <= log_n) : (s += 1) {
        const m = @as(u32, 1) << @as(u5, @intCast(s));
        const half_m = m >> 1;
        const w_m = getTwiddle(n, n >> @as(u5, @intCast(s)));
        parallelButterfly(a, n, m, half_m, w_m);
    }
}

pub fn ifft_fr(a: []field.FrElement, n: u32) void {
    std.debug.assert(@popCount(n) == 1);
    std.debug.assert(a.len >= n);

    const log_n = @ctz(n);

    if (n >= 65536) {
        parallelBitReverse(a, n, log_n);
    } else {
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const j = bitReverse(i, log_n);
            if (i < j) {
                const tmp = a[i];
                a[i] = a[j];
                a[j] = tmp;
            }
        }
    }

    var s: u32 = 1;
    while (s <= log_n) : (s += 1) {
        const m = @as(u32, 1) << @as(u5, @intCast(s));
        const half_m = m >> 1;
        const w_m = getTwiddleInv(n, n >> @as(u5, @intCast(s)));
        parallelButterfly(a, n, m, half_m, w_m);
    }

    const n_mont = field.fr_toMont(field.fr_from_u64(n));
    const n_inv = field.fr_inv(n_mont);

    if (n >= 65536) {
        parallelScale(a, n, n_inv);
    } else {
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            a[i] = field.fr_mul(a[i], n_inv);
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub fn bitReverse(x: u32, bits: u32) u32 {
    var r: u32 = 0;
    var b: u32 = 0;
    while (b < bits) : (b += 1) {
        r = (r << 1) | ((x >> @as(u5, @intCast(b))) & 1);
    }
    return r;
}

/// Bit-reverse a slice of FrElement in-place.
pub fn bitReverseFr(a: []field.FrElement, n: u32) void {
    std.debug.assert(@popCount(n) == 1);
    const log_n = @ctz(n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const j = bitReverse(i, log_n);
        if (i < j) {
            const tmp = a[i];
            a[i] = a[j];
            a[j] = tmp;
        }
    }
}

// BN254 Fr primitive roots of unity in Montgomery form
// Normal values: 5^((q-1)/n) mod q
// Montgomery form: omega * R mod q

const FR_OMEGA_1024 = field.FrElement{ 0x1ef4b3b4280c1184, 0xcf7ad4c2ae5e2a2c, 0xb8063b6cc5a36518, 0x2348c4b965dfc08c };

pub const FR_OMEGA_2048 = field.FrElement{ 0x48e72189ae4fcfb2, 0x0a03fb3c8df85a07, 0xff4d8a35ea9b2e0a, 0x28a98c2ecd9c1d77 };

pub const FR_OMEGA_4096 = field.FrElement{ 0x1dd4522fb3ecdbd3, 0x68222a93d055f3ad, 0xbe9c7d66b3d555e8, 0x1b92f6b86194f846 };

pub const FR_OMEGA_8192 = field.FrElement{ 0x894cdcbe79a04ed6, 0x956cde6a44d30787, 0x59a1b62bd7dbc15f, 0x12ebe4109a806f4e };

pub const FR_OMEGA_16384 = field.FrElement{ 0xba13a0c74d05eab8, 0x2e015d6311ab3116, 0xb503922c8ca5a05a, 0x06be15d7fee394da };

pub const FR_OMEGA_32768 = field.FrElement{ 0x804ef7055bfdb854, 0x7aa76b7140ceeaf2, 0xfcc95a68b2fe89cb, 0x1d461c35f1c406c7 };

pub const FR_OMEGA_65536 = field.FrElement{ 0xba13a0c74d05eab8, 0x2e015d6311ab3116, 0xb503922c8ca5a05a, 0x06be15d7fee394da };

pub const FR_OMEGA_131072 = field.FrElement{ 0x894cdcbe79a04ed6, 0x956cde6a44d30787, 0x59a1b62bd7dbc15f, 0x12ebe4109a806f4e };

pub const FR_OMEGA_262144 = field.FrElement{ 0x1dd4522fb3ecdbd3, 0x68222a93d055f3ad, 0xbe9c7d66b3d555e8, 0x1b92f6b86194f846 };

pub const FR_OMEGA_524288 = field.FrElement{ 0x049ea3b7e6a27a36, 0xefebe603053edbbc, 0x8424b45a3ace9ed4, 0x287c8390a688795e };

pub const FR_OMEGA_1048576 = field.FrElement{ 0xda32d465aa8d931a, 0x2669f68561808f9c, 0x247bab46e4c8b085, 0x0d3b668781d6021a };

pub const FR_OMEGA_2097152 = field.FrElement{ 0x27ea2192f5322f3c, 0xb11884e9658fe9a7, 0x3a8623bca053c069, 0x128ff3f025e139a6 };

pub const FR_OMEGA_4194304 = field.FrElement{ 0x9b8e226ebcef1af2, 0x9e45f1abdf406b60, 0x538dd257d5a7bb3d, 0x0a3893037882a3bc };

pub const FR_OMEGA_8388608 = field.FrElement{ 0x6e482404c09e9100, 0x0d7591c7590025b2, 0xa40227793a5ebe11, 0x0164a6c3c1a94ca8 };

/// Multiply polynomial coefficients by g^i to shift evaluation domain to coset.
/// Assumes `a` is in coefficient form (e.g. after IFFT) and in Montgomery form.
/// `g` is the 2n-th primitive root of unity in Montgomery form.
pub fn shiftCoefficients(a: []field.FrElement, n: u32, g: field.FrElement) void {
    std.debug.assert(@popCount(n) == 1);
    std.debug.assert(a.len >= n);

    var power = field.fr_one();
    for (0..n) |i| {
        a[i] = field.fr_mul(a[i], power);
        power = field.fr_mul(power, g);
    }
}

pub fn getOmegaN(n: u32) field.FrElement {
    std.debug.assert(n > 0 and @popCount(n) == 1 and n <= 8388608);

    // For n > 1024, return precomputed root directly
    if (n == 8388608) return FR_OMEGA_8388608;
    if (n == 4194304) return FR_OMEGA_4194304;
    if (n == 2097152) return FR_OMEGA_2097152;
    if (n == 1048576) return FR_OMEGA_1048576;
    if (n == 524288) return FR_OMEGA_524288;
    if (n == 262144) return FR_OMEGA_262144;
    if (n == 131072) return FR_OMEGA_131072;
    if (n == 65536) return FR_OMEGA_65536;
    if (n == 32768) return FR_OMEGA_32768;
    if (n == 16384) return FR_OMEGA_16384;
    if (n == 8192) return FR_OMEGA_8192;
    if (n == 4096) return FR_OMEGA_4096;
    if (n == 2048) return FR_OMEGA_2048;

    // For n <= 1024, compute from FR_OMEGA_1024
    const exp: u32 = 1024 / n;
    var result = field.fr_one();
    var base = FR_OMEGA_1024;
    var e = exp;
    var first = true;
    while (e > 0) : (e >>= 1) {
        if (e & 1 != 0) {
            if (first) {
                result = base;
                first = false;
            } else {
                result = field.fr_mul(result, base);
            }
        }
        base = field.fr_sqr(base);
    }
    return result;
}

pub fn getTwiddle(n: u32, k: u32) field.FrElement {
    const omega_n = getOmegaN(n);
    var result = field.fr_one();
    var base = omega_n;
    var e = k;
    var first = true;
    while (e > 0) : (e >>= 1) {
        if (e & 1 != 0) {
            if (first) {
                result = base;
                first = false;
            } else {
                result = field.fr_mul(result, base);
            }
        }
        base = field.fr_sqr(base);
    }
    return result;
}

pub fn getTwiddleInv(n: u32, k: u32) field.FrElement {
    return field.fr_inv(getTwiddle(n, k));
}

// ============================================================================
// Tests
// ============================================================================

test "fft roundtrip" {
    var data = [_]field.FrElement{
        field.fr_toMont(field.fr_from_u64(1)),
        field.fr_toMont(field.fr_from_u64(2)),
        field.fr_toMont(field.fr_from_u64(3)),
        field.fr_toMont(field.fr_from_u64(4)),
    };
    const copy = data;
    fft_fr(&data, 4);
    ifft_fr(&data, 4);
    for (data, copy) |d, c| {
        try std.testing.expect(field.fr_eq(d, c));
    }
}

test "2048-th root is square of 1024-th root" {
    const g_sqr = field.fr_mul(FR_OMEGA_2048, FR_OMEGA_2048);
    try std.testing.expect(field.fr_eq(g_sqr, FR_OMEGA_1024));
}

test "fft ifft 8-point roundtrip" {
    var data = [_]field.FrElement{
        field.fr_toMont(field.fr_from_u64(1)),
        field.fr_toMont(field.fr_from_u64(2)),
        field.fr_toMont(field.fr_from_u64(3)),
        field.fr_toMont(field.fr_from_u64(4)),
        field.fr_toMont(field.fr_from_u64(5)),
        field.fr_toMont(field.fr_from_u64(6)),
        field.fr_toMont(field.fr_from_u64(7)),
        field.fr_toMont(field.fr_from_u64(8)),
    };
    const copy = data;
    fft_fr(&data, 8);
    ifft_fr(&data, 8);
    for (data, copy) |d, c| {
        try std.testing.expect(field.fr_eq(d, c));
    }
}

test "fft ifft 8192-point roundtrip" {
    const n: u32 = 8192;
    var data = try std.testing.allocator.alloc(field.FrElement, n);
    defer std.testing.allocator.free(data);
    
    for (0..n) |i| {
        data[i] = field.fr_toMont(field.fr_from_u64(@intCast(i + 1)));
    }
    
    const copy = try std.testing.allocator.dupe(field.FrElement, data);
    defer std.testing.allocator.free(copy);
    
    fft_fr(data, n);
    ifft_fr(data, n);
    
    for (data, copy) |d, c| {
        try std.testing.expect(field.fr_eq(d, c));
    }
}

test "fft ifft 1024-point roundtrip with qap data" {
    const testdata = @import("rapidsnark_testdata");
    // Use gpu/qap to build QAP
    const qap = @import("gpu/qap.zig");
    const qap_result = try qap.buildQap(std.testing.allocator, testdata.ZKEY, testdata.WTNS);
    defer {
        std.testing.allocator.free(qap_result.a);
        std.testing.allocator.free(qap_result.b);
        std.testing.allocator.free(qap_result.c);
        std.testing.allocator.free(qap_result.points_h);
    }

    const domain_size = qap_result.domain_size;

    // Copy QAP a into aligned slice
    const a = try std.testing.allocator.alloc(field.FrElement, domain_size);
    defer std.testing.allocator.free(a);
    @memcpy(std.mem.sliceAsBytes(a), qap_result.a);

    const copy = try std.testing.allocator.dupe(field.FrElement, a);
    defer std.testing.allocator.free(copy);

    fft_fr(a, domain_size);
    ifft_fr(a, domain_size);

    for (a, copy) |d, c| {
        try std.testing.expect(field.fr_eq(d, c));
    }
}



test "check omega chain" {
    const g1 = field.fr_mul(FR_OMEGA_2048, FR_OMEGA_2048);
    try std.testing.expect(field.fr_eq(g1, FR_OMEGA_1024));
    
    const g2 = field.fr_mul(FR_OMEGA_4096, FR_OMEGA_4096);
    try std.testing.expect(field.fr_eq(g2, FR_OMEGA_2048));
    
    const g3 = field.fr_mul(FR_OMEGA_8192, FR_OMEGA_8192);
    try std.testing.expect(field.fr_eq(g3, FR_OMEGA_4096));
    
    const g4 = field.fr_mul(FR_OMEGA_16384, FR_OMEGA_16384);
    const is_ok = field.fr_eq(g4, FR_OMEGA_8192);
    std.debug.print("omega_16384^2 == omega_8192? {}\n", .{is_ok});
    try std.testing.expect(is_ok);
}
