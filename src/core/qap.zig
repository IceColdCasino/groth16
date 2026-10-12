const std = @import("std");

// ============================================================================
// BN254 Fr Field Arithmetic (ported from field.metal)
// ============================================================================

pub const FrElement = [4]u64;

const FR_Q: FrElement = .{
    0x43e1f593f0000001,
    0x2833e84879b97091,
    0xb85045b68181585d,
    0x30644e72e131a029,
};

const FR_NP: u64 = 0xc2e1f593efffffff;
const FR_R2: FrElement = .{ 0x1bb8e645ae216da7, 0x53fe3ab1e35c59e3, 0x8c49833d53bb8085, 0x0216d0b17f4e44a5 };

fn fr_cmp(a: FrElement, b: FrElement) i32 {
    var i: i32 = 3;
    while (i >= 0) : (i -= 1) {
        const ai = a[@intCast(i)];
        const bi = b[@intCast(i)];
        if (ai > bi) return 1;
        if (ai < bi) return -1;
    }
    return 0;
}

fn fr_add(a: FrElement, b: FrElement) FrElement {
    var carry: u64 = 0;
    var r: FrElement = undefined;
    for (0..4) |i| {
        const sum, const c1 = @addWithOverflow(a[i], b[i]);
        const sum2, const c2 = @addWithOverflow(sum, carry);
        r[i] = sum2;
        carry = c1 + c2;
    }

    if (carry != 0 or fr_cmp(r, FR_Q) >= 0) {
        var borrow: u64 = 0;
        var diff: FrElement = undefined;
        for (0..4) |i| {
            const total_sub, const c1 = @addWithOverflow(FR_Q[i], borrow);
            const d, const c2 = @subWithOverflow(r[i], total_sub);
            diff[i] = d;
            borrow = c1 | c2;
        }
        return diff;
    }
    return r;
}

fn fr_sub(a: FrElement, b: FrElement) FrElement {
    var borrow: u64 = 0;
    var r: FrElement = undefined;
    for (0..4) |i| {
        const total_sub, const c1 = @addWithOverflow(b[i], borrow);
        const diff, const c2 = @subWithOverflow(a[i], total_sub);
        r[i] = diff;
        borrow = c1 | c2;
    }

    if (borrow != 0) {
        var carry: u64 = 0;
        var sum: FrElement = undefined;
        for (0..4) |i| {
            const s, const c1 = @addWithOverflow(r[i], FR_Q[i]);
            const s2, const c2 = @addWithOverflow(s, carry);
            sum[i] = s2;
            carry = c1 + c2;
        }
        return sum;
    }
    return r;
}

fn fr_mul(a: FrElement, b: FrElement) FrElement {
    var t = [5]u64{ 0, 0, 0, 0, 0 };

    for (0..4) |i| {
        // t += a * b[i]
        var carry: u64 = 0;
        for (0..4) |j| {
            const prod: u128 = @as(u128, a[j]) * @as(u128, b[i]);
            const acc: u128 = prod + @as(u128, t[j]) + @as(u128, carry);
            t[j] = @truncate(acc);
            carry = @intCast(acc >> 64);
        }
        t[4] +%= carry;

        // Montgomery reduction: t += q * m where m = t[0] * np
        const m = t[0] *% FR_NP;

        carry = 0;
        for (0..4) |j| {
            const prod: u128 = @as(u128, FR_Q[j]) * @as(u128, m);
            const acc: u128 = prod + @as(u128, t[j]) + @as(u128, carry);
            t[j] = @truncate(acc);
            carry = @intCast(acc >> 64);
        }
        t[4] +%= carry;

        // Shift right by one limb
        for (0..4) |j| {
            t[j] = t[j + 1];
        }
        t[4] = 0;
    }

    var r = FrElement{ t[0], t[1], t[2], t[3] };

    if (fr_cmp(r, FR_Q) >= 0) {
        r = fr_sub(r, FR_Q);
    }
    return r;
}

fn fr_toMont(a: FrElement) FrElement {
    return fr_mul(a, FR_R2);
}

// ============================================================================
// ZKey / Witness binary parsing
// ============================================================================

fn readU32LE(buf: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, buf[offset..][0..4], .little);
}

fn readU64LE(buf: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, buf[offset..][0..8], .little);
}

pub const ZkeyInfo = struct {
    n_vars: u32,
    n_public: u32,
    domain_size: u32,
    n8r: u32,
    sec4_offset: usize,
    sec4_size: usize,
    sec9_offset: usize,
    sec9_size: usize,
};

pub fn parseZkey(buf: []const u8) !ZkeyInfo {
    if (buf.len < 12 or !std.mem.eql(u8, buf[0..4], "zkey")) {
        return error.InvalidZkey;
    }
    const version = readU32LE(buf, 4);
    _ = version;
    const n_sections = readU32LE(buf, 8);

    var sec4_offset: usize = 0;
    var sec4_size: usize = 0;
    var sec9_offset: usize = 0;
    var sec9_size: usize = 0;

    var offset: usize = 12;
    for (0..n_sections) |_| {
        if (offset + 12 > buf.len) return error.InvalidZkey;
        const s_type = readU32LE(buf, offset);
        const s_size = readU64LE(buf, offset + 4);
        offset += 12;
        if (offset + s_size > buf.len) return error.InvalidZkey;
        if (s_type == 4) {
            sec4_offset = offset;
            sec4_size = @intCast(s_size);
        } else if (s_type == 9) {
            sec9_offset = offset;
            sec9_size = @intCast(s_size);
        }
        offset += @intCast(s_size);
    }

    // Section 1: protocol
    // We already know it's groth16 from the caller or we can check
    // Skip to section 2

    // Find section 2 to read header
    var hoff: usize = 12;
    for (0..n_sections) |_| {
        if (hoff + 12 > buf.len) return error.InvalidZkey;
        const s_type = readU32LE(buf, hoff);
        const s_size = readU64LE(buf, hoff + 4);
        hoff += 12;
        if (s_type == 2) {
            break;
        }
        hoff += @intCast(s_size);
    }

    if (hoff + 12 > buf.len) return error.MissingSection;

    var soff = hoff;
    const n8q = readU32LE(buf, soff);
    soff += 4 + n8q;
    if (soff + 4 > buf.len) return error.InvalidZkey;
    const n8r = readU32LE(buf, soff);
    soff += 4 + n8r;
    if (soff + 12 > buf.len) return error.InvalidZkey;
    const n_vars = readU32LE(buf, soff);
    soff += 4;
    const n_public = readU32LE(buf, soff);
    soff += 4;
    const domain_size = readU32LE(buf, soff);

    if (sec4_offset == 0 or sec9_offset == 0) {
        return error.MissingSection;
    }

    return ZkeyInfo{
        .n_vars = n_vars,
        .n_public = n_public,
        .domain_size = domain_size,
        .n8r = n8r,
        .sec4_offset = sec4_offset,
        .sec4_size = sec4_size,
        .sec9_offset = sec9_offset,
        .sec9_size = sec9_size,
    };
}

const WtnsInfo = struct {
    n_vars: u32,
    data: []const u8,
};

fn parseWtns(buf: []const u8) !WtnsInfo {
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

    return WtnsInfo{
        .n_vars = n_vars,
        .data = buf[sec2_offset..sec2_offset + sec2_size],
    };
}

// ============================================================================
// QAP Construction
// ============================================================================

pub const QapResult = struct {
    a: []FrElement,
    b: []FrElement,
    c: []FrElement,
    domain_size: u32,
    points_h: []u8,
};

pub fn buildQapWithInfo(
    allocator: std.mem.Allocator,
    zkey_buf: []const u8,
    wtns_buf: []const u8,
    zkey: ZkeyInfo,
) !QapResult {
    const wtns = try parseWtns(wtns_buf);

    if (zkey.n_vars != wtns.n_vars) {
        return error.InvalidWitnessLength;
    }

    const domain_size = zkey.domain_size;
    const n8r = zkey.n8r;

    // One allocation for every a/b partial. Thread 0's slices are the result;
    // the rest are freed after the merge. c is written in full, so it is not zeroed.
    const coef_size: usize = 12 + @as(usize, n8r);
    if (zkey.sec4_size < 4) return error.InvalidZkey;
    const n_coefs = (zkey.sec4_size - 4) / coef_size;
    // One thread. Splitting the coefficient adds across cores allocates a full
    // a/b partial per thread and fights the GPU for memory.
    const n_threads: usize = 1;

    const a = try allocator.alloc(FrElement, domain_size);
    errdefer allocator.free(a);
    const b = try allocator.alloc(FrElement, domain_size);
    errdefer allocator.free(b);
    const c = try allocator.alloc(FrElement, domain_size);
    errdefer allocator.free(c);
    const extra = try allocator.alloc(FrElement, domain_size * 2 * (n_threads - 1));
    defer allocator.free(extra);

    const zero = FrElement{ 0, 0, 0, 0 };
    @memset(a, zero);
    @memset(b, zero);
    @memset(extra, zero);

    const sec4_data = zkey_buf[zkey.sec4_offset .. zkey.sec4_offset + zkey.sec4_size];
    const witness_data = wtns.data;

    const CoefJob = struct {
        sec4: []const u8,
        witness: []const u8,
        n8r: usize,
        coef_size: usize,
        n_vars: u32,
        domain_size: u32,
        start: usize,
        end: usize,
        a: []FrElement,
        b: []FrElement,
        ok: bool = true,

        fn run(job: *@This()) void {
            var coef_offset = 4 + job.start * job.coef_size;
            for (job.start..job.end) |_| {
                if (coef_offset + job.coef_size > job.sec4.len) {
                    job.ok = false;
                    return;
                }
                const m = std.mem.readInt(u32, job.sec4[coef_offset..][0..4], .little);
                const c_idx = std.mem.readInt(u32, job.sec4[coef_offset + 4 ..][0..4], .little);
                const s = std.mem.readInt(u32, job.sec4[coef_offset + 8 ..][0..4], .little);
                if (s >= job.n_vars or c_idx >= job.domain_size) {
                    job.ok = false;
                    return;
                }
                const witness_bytes = job.witness[@as(usize, s) * job.n8r ..][0..job.n8r];
                const coef_bytes = job.sec4[coef_offset + 12 ..][0..job.n8r];
                var witness_elem: FrElement = undefined;
                var coef_elem: FrElement = undefined;
                @memcpy(std.mem.asBytes(&witness_elem), witness_bytes[0..@sizeOf(FrElement)]);
                @memcpy(std.mem.asBytes(&coef_elem), coef_bytes[0..@sizeOf(FrElement)]);
                // Witness is normal form, coefficient is Montgomery. fr_mul accepts that pair.
                const aux = fr_mul(witness_elem, coef_elem);
                const ab = if (m == 0) job.a else job.b;
                ab[c_idx] = fr_add(ab[c_idx], aux);
                coef_offset += job.coef_size;
            }
        }
    };

    var jobs = try allocator.alloc(CoefJob, n_threads);
    defer allocator.free(jobs);
    var threads = try allocator.alloc(std.Thread, n_threads);
    defer allocator.free(threads);
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();

    const chunk = (n_coefs + n_threads - 1) / n_threads;
    for (0..n_threads) |t| {
        const start = t * chunk;
        const end = @min(n_coefs, start + chunk);
        const a_slice = if (t == 0) a else extra[(t - 1) * 2 * domain_size ..][0..domain_size];
        const b_slice = if (t == 0) b else extra[(t - 1) * 2 * domain_size + domain_size ..][0..domain_size];
        jobs[t] = .{
            .sec4 = sec4_data,
            .witness = witness_data,
            .n8r = n8r,
            .coef_size = coef_size,
            .n_vars = wtns.n_vars,
            .domain_size = domain_size,
            .start = start,
            .end = end,
            .a = a_slice,
            .b = b_slice,
        };
        if (t + 1 == n_threads) {
            CoefJob.run(&jobs[t]);
        } else if (std.Thread.spawn(.{}, CoefJob.run, .{&jobs[t]})) |thread| {
            threads[spawned] = thread;
            spawned += 1;
        } else |_| {
            CoefJob.run(&jobs[t]);
        }
    }
    for (threads[0..spawned]) |t| t.join();
    spawned = 0;
    for (jobs) |job| if (!job.ok) return error.InvalidZkey;

    if (n_threads > 1) {
        const Merge = struct {
            a: []FrElement,
            b: []FrElement,
            extra: []FrElement,
            domain: usize,
            n_threads: usize,
            start: usize,
            end: usize,
            fn run(m: @This()) void {
                for (m.start..m.end) |i| {
                    var acc_a = m.a[i];
                    var acc_b = m.b[i];
                    for (1..m.n_threads) |t| {
                        const base = (t - 1) * 2 * m.domain;
                        acc_a = fr_add(acc_a, m.extra[base + i]);
                        acc_b = fr_add(acc_b, m.extra[base + m.domain + i]);
                    }
                    m.a[i] = acc_a;
                    m.b[i] = acc_b;
                }
            }
        };
        const stripe = (domain_size + n_threads - 1) / n_threads;
        for (0..n_threads) |t| {
            const start = t * stripe;
            const end = @min(domain_size, start + stripe);
            const merge = Merge{
                .a = a,
                .b = b,
                .extra = extra,
                .domain = domain_size,
                .n_threads = n_threads,
                .start = start,
                .end = end,
            };
            if (t + 1 == n_threads) {
                Merge.run(merge);
            } else if (std.Thread.spawn(.{}, Merge.run, .{merge})) |thread| {
                threads[spawned] = thread;
                spawned += 1;
            } else |_| {
                Merge.run(merge);
            }
        }
        for (threads[0..spawned]) |t| t.join();
        spawned = 0;
    }

    {
        const Mul = struct {
            a: []const FrElement,
            b: []const FrElement,
            c: []FrElement,
            start: usize,
            end: usize,
            fn run(m: @This()) void {
                for (m.start..m.end) |i| m.c[i] = fr_mul(m.a[i], m.b[i]);
            }
        };
        const stripe = (domain_size + n_threads - 1) / n_threads;
        for (0..n_threads) |t| {
            const start = t * stripe;
            const end = @min(domain_size, start + stripe);
            const mul = Mul{ .a = a, .b = b, .c = c, .start = start, .end = end };
            if (t + 1 == n_threads) {
                Mul.run(mul);
            } else if (std.Thread.spawn(.{}, Mul.run, .{mul})) |thread| {
                threads[spawned] = thread;
                spawned += 1;
            } else |_| {
                Mul.run(mul);
            }
        }
        for (threads[0..spawned]) |t| t.join();
        spawned = 0;
    }

    // Section 9 stays in the zkey buffer. Callers free this empty slice as a no-op.
    const points_h: []u8 = &.{};

    return QapResult{
        .a = a,
        .b = b,
        .c = c,
        .domain_size = domain_size,
        .points_h = points_h,
    };
}

pub fn buildQap(
    allocator: std.mem.Allocator,
    zkey_buf: []const u8,
    wtns_buf: []const u8,
) !QapResult {
    const zkey = try parseZkey(zkey_buf);
    return buildQapWithInfo(allocator, zkey_buf, wtns_buf, zkey);
}

// ============================================================================
// Unit tests for Fr arithmetic (against known values / properties)
// ============================================================================

test "fr_add: zero + zero = zero" {
    const zero = FrElement{ 0, 0, 0, 0 };
    const r = fr_add(zero, zero);
    try std.testing.expectEqual(zero, r);
}

test "fr_mul: zero * anything = zero" {
    const zero = FrElement{ 0, 0, 0, 0 };
    const x = FrElement{ 1, 2, 3, 4 };
    const r = fr_mul(zero, x);
    try std.testing.expectEqual(zero, r);
}

test "fr_add: commutative" {
    const a = FrElement{ 0x1234567890abcdef, 0xfedcba0987654321, 0xaaaaaaaa55555555, 0x1111111122222222 };
    const b = FrElement{ 0xfedcba0987654321, 0x1234567890abcdef, 0x55555555aaaaaaaa, 0x2222222211111111 };
    const r1 = fr_add(a, b);
    const r2 = fr_add(b, a);
    try std.testing.expectEqual(r1, r2);
}
