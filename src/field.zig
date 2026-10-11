const std = @import("std");

// ============================================================================
// BN254 Fr (Scalar Field)
// ============================================================================

pub const FrElement = [4]u64;

pub const fr_q = FrElement{ 0x43e1f593f0000001, 0x2833e84879b97091, 0xb85045b68181585d, 0x30644e72e131a029 };
const fr_np: u64 = 0xc2e1f593efffffff;
const fr_r2 = FrElement{ 0x1bb8e645ae216da7, 0x53fe3ab1e35c59e3, 0x8c49833d53bb8085, 0x0216d0b17f4e44a5 };
const fr_one_mont = FrElement{ 0xac96341c4ffffffb, 0x36fc76959f60cd29, 0x666ea36f7879462e, 0x0e0a77c19a07df2f };

pub fn fr_zero() FrElement {
    return [_]u64{ 0, 0, 0, 0 };
}

pub fn fr_one() FrElement {
    return fr_one_mont;
}

pub fn fr_from_u64(v: u64) FrElement {
    return [_]u64{ v, 0, 0, 0 };
}

pub fn fr_toMont(a: FrElement) FrElement {
    return fr_mul(a, fr_r2);
}

pub fn fr_fromMont(a: FrElement) FrElement {
    var t: [5]u64 = .{ a[0], a[1], a[2], a[3], 0 };

    for (0..4) |_| {
        const m = t[0] *% fr_np;

        var carry: u64 = 0;
        for (0..4) |j| {
            const prod = @as(u128, fr_q[j]) * @as(u128, m);
            const acc = prod + t[j] + carry;
            t[j] = @truncate(acc);
            carry = @intCast(acc >> 64);
        }

        const sum = @as(u128, t[4]) + carry;
        t[4] = @truncate(sum);

        for (0..4) |k| {
            t[k] = t[k + 1];
        }
        t[4] = 0;
    }

    var r = FrElement{ t[0], t[1], t[2], t[3] };

    if (fr_cmp(r, fr_q) >= 0) {
        r = fr_sub(r, fr_q);
    }
    return r;
}

fn fr_cmp(a: FrElement, b: FrElement) i32 {
    for (0..4) |i| {
        const idx = 3 - i;
        if (a[idx] > b[idx]) return 1;
        if (a[idx] < b[idx]) return -1;
    }
    return 0;
}

pub fn fr_eq(a: FrElement, b: FrElement) bool {
    return fr_cmp(a, b) == 0;
}

pub fn fr_is_zero(a: FrElement) bool {
    return fr_eq(a, fr_zero());
}

pub fn fr_add(a: FrElement, b: FrElement) FrElement {
    var carry: u64 = 0;
    var r: FrElement = undefined;
    for (0..4) |i| {
        const sum1 = a[i] +% b[i];
        const c1: u64 = @intFromBool(sum1 < a[i]);
        const sum2 = sum1 +% carry;
        const c2: u64 = @intFromBool(sum2 < sum1);
        r[i] = sum2;
        carry = c1 + c2;
    }

    if (carry != 0 or fr_cmp(r, fr_q) >= 0) {
        var borrow: u64 = 0;
        var diff: FrElement = undefined;
        for (0..4) |i| {
            const total_sub = fr_q[i] +% borrow;
            const c1: u64 = @intFromBool(total_sub < fr_q[i]);
            const d = r[i] -% total_sub;
            const c2: u64 = @intFromBool(d > r[i]);
            diff[i] = d;
            borrow = c1 | c2;
        }
        return diff;
    }
    return r;
}

pub fn fr_sub(a: FrElement, b: FrElement) FrElement {
    var borrow: u64 = 0;
    var r: FrElement = undefined;
    for (0..4) |i| {
        const total_sub = b[i] +% borrow;
        const c1: u64 = @intFromBool(total_sub < b[i]);
        const diff = a[i] -% total_sub;
        const c2: u64 = @intFromBool(diff > a[i]);
        r[i] = diff;
        borrow = c1 | c2;
    }

    if (borrow != 0) {
        var carry: u64 = 0;
        var sum: FrElement = undefined;
        for (0..4) |i| {
            const s1 = r[i] +% fr_q[i];
            const c1: u64 = @intFromBool(s1 < r[i]);
            const s2 = s1 +% carry;
            const c2: u64 = @intFromBool(s2 < s1);
            sum[i] = s2;
            carry = c1 + c2;
        }
        return sum;
    }
    return r;
}

pub fn fr_mul(a: FrElement, b: FrElement) FrElement {
    var t = [5]u64{ 0, 0, 0, 0, 0 };

    for (0..4) |i| {
        var carry: u64 = 0;
        for (0..4) |j| {
            const prod: u128 = @as(u128, a[j]) * @as(u128, b[i]);
            const acc: u128 = prod + @as(u128, t[j]) + @as(u128, carry);
            t[j] = @truncate(acc);
            carry = @intCast(acc >> 64);
        }
        t[4] +%= carry;

        const m = t[0] *% fr_np;

        carry = 0;
        for (0..4) |j| {
            const prod: u128 = @as(u128, fr_q[j]) * @as(u128, m);
            const acc: u128 = prod + @as(u128, t[j]) + @as(u128, carry);
            t[j] = @truncate(acc);
            carry = @intCast(acc >> 64);
        }
        t[4] +%= carry;

        for (0..4) |j| {
            t[j] = t[j + 1];
        }
        t[4] = 0;
    }

    var r = FrElement{ t[0], t[1], t[2], t[3] };

    if (fr_cmp(r, fr_q) >= 0) {
        r = fr_sub(r, fr_q);
    }
    return r;
}

pub fn fr_sqr(a: FrElement) FrElement {
    return fr_mul(a, a);
}

pub fn fr_inv(a: FrElement) FrElement {
    // Fermat's little theorem: a^(r-2) mod r
    // Square-and-multiply with Montgomery multiplication
    const r_minus_2 = FrElement{ 0x43e1f593efffffff, 0x2833e84879b97091, 0xb85045b68181585d, 0x30644e72e131a029 };

    var result = fr_one();
    var found_first = false;

    for (0..4) |word_idx| {
        const word = r_minus_2[3 - word_idx];
        var bit_mask: u64 = 1 << 63;
        while (bit_mask != 0) : (bit_mask >>= 1) {
            if (found_first) {
                result = fr_sqr(result);
            }
            if ((word & bit_mask) != 0) {
                if (!found_first) {
                    result = a;
                    found_first = true;
                } else {
                    result = fr_mul(result, a);
                }
            }
        }
    }

    return result;
}

pub fn fr_neg(a: FrElement) FrElement {
    if (fr_is_zero(a)) return fr_zero();
    return fr_sub(fr_q, a);
}

// ============================================================================
// BN254 Fq (Base Field)
// ============================================================================

pub const FqElement = [4]u64;

const fq_q = FqElement{ 0x3c208c16d87cfd47, 0x97816a916871ca8d, 0xb85045b68181585d, 0x30644e72e131a029 };
const fq_np: u64 = 0x87d20782e4866389;
const fq_r2 = FqElement{ 0xf32cfc5b538afa89, 0xb5e71911d44501fb, 0x47ab1eff0a417ff6, 0x06d89f71cab8351f };
const fq_one_mont = FqElement{ 0xd35d438dc58f0d9d, 0x0a78eb28f5c70b3d, 0x666ea36f7879462c, 0x0e0a77c19a07df2f };

pub fn fq_zero() FqElement {
    return [_]u64{ 0, 0, 0, 0 };
}

pub fn fq_one() FqElement {
    return fq_one_mont;
}

pub fn fq_from_u64(v: u64) FqElement {
    return [_]u64{ v, 0, 0, 0 };
}

pub fn fq_toMont(a: FqElement) FqElement {
    return fq_mul(a, fq_r2);
}

pub fn fq_fromMont(a: FqElement) FqElement {
    var t: [5]u64 = .{ a[0], a[1], a[2], a[3], 0 };

    for (0..4) |_| {
        const m = t[0] *% fq_np;

        var carry: u64 = 0;
        for (0..4) |j| {
            const prod = @as(u128, fq_q[j]) * @as(u128, m);
            const acc = prod + t[j] + carry;
            t[j] = @truncate(acc);
            carry = @intCast(acc >> 64);
        }

        const sum = @as(u128, t[4]) + carry;
        t[4] = @truncate(sum);

        for (0..4) |k| {
            t[k] = t[k + 1];
        }
        t[4] = 0;
    }

    var r = FqElement{ t[0], t[1], t[2], t[3] };

    if (fq_cmp(r, fq_q) >= 0) {
        r = fq_sub(r, fq_q);
    }
    return r;
}

fn fq_cmp(a: FqElement, b: FqElement) i32 {
    for (0..4) |i| {
        const idx = 3 - i;
        if (a[idx] > b[idx]) return 1;
        if (a[idx] < b[idx]) return -1;
    }
    return 0;
}

pub fn fq_eq(a: FqElement, b: FqElement) bool {
    return fq_cmp(a, b) == 0;
}

pub fn fq_is_zero(a: FqElement) bool {
    return fq_eq(a, fq_zero());
}

pub fn fq_add(a: FqElement, b: FqElement) FqElement {
    var carry: u64 = 0;
    var r: FqElement = undefined;
    for (0..4) |i| {
        const sum1 = a[i] +% b[i];
        const c1: u64 = @intFromBool(sum1 < a[i]);
        const sum2 = sum1 +% carry;
        const c2: u64 = @intFromBool(sum2 < sum1);
        r[i] = sum2;
        carry = c1 + c2;
    }

    if (carry != 0 or fq_cmp(r, fq_q) >= 0) {
        var borrow: u64 = 0;
        var diff: FqElement = undefined;
        for (0..4) |i| {
            const total_sub = fq_q[i] +% borrow;
            const c1: u64 = @intFromBool(total_sub < fq_q[i]);
            const d = r[i] -% total_sub;
            const c2: u64 = @intFromBool(d > r[i]);
            diff[i] = d;
            borrow = c1 | c2;
        }
        return diff;
    }
    return r;
}

pub fn fq_sub(a: FqElement, b: FqElement) FqElement {
    var borrow: u64 = 0;
    var r: FqElement = undefined;
    for (0..4) |i| {
        const total_sub = b[i] +% borrow;
        const c1: u64 = @intFromBool(total_sub < b[i]);
        const diff = a[i] -% total_sub;
        const c2: u64 = @intFromBool(diff > a[i]);
        r[i] = diff;
        borrow = c1 | c2;
    }

    if (borrow != 0) {
        var carry: u64 = 0;
        var sum: FqElement = undefined;
        for (0..4) |i| {
            const s1 = r[i] +% fq_q[i];
            const c1: u64 = @intFromBool(s1 < r[i]);
            const s2 = s1 +% carry;
            const c2: u64 = @intFromBool(s2 < s1);
            sum[i] = s2;
            carry = c1 + c2;
        }
        return sum;
    }
    return r;
}

fn fq_to_u256(a: FqElement) u256 {
    return @as(u256, a[0]) |
        (@as(u256, a[1]) << 64) |
        (@as(u256, a[2]) << 128) |
        (@as(u256, a[3]) << 192);
}

fn u256_to_fq(a: u256) FqElement {
    return FqElement{
        @truncate(a),
        @truncate(a >> 64),
        @truncate(a >> 128),
        @truncate(a >> 192),
    };
}

const fq_r_inv = FqElement{ 0xdc5ba0056db1194e, 0x090ef5a9e111ec87, 0xc8260de4aeb85d5d, 0x15ebf95182c5551c };

pub fn fq_mul(a: FqElement, b: FqElement) FqElement {
    var t = [5]u64{ 0, 0, 0, 0, 0 };

    for (0..4) |i| {
        var carry: u64 = 0;
        for (0..4) |j| {
            const prod: u128 = @as(u128, a[j]) * @as(u128, b[i]);
            const acc: u128 = prod + @as(u128, t[j]) + @as(u128, carry);
            t[j] = @truncate(acc);
            carry = @intCast(acc >> 64);
        }
        t[4] +%= carry;

        const m = t[0] *% fq_np;

        carry = 0;
        for (0..4) |j| {
            const prod: u128 = @as(u128, fq_q[j]) * @as(u128, m);
            const acc: u128 = prod + @as(u128, t[j]) + @as(u128, carry);
            t[j] = @truncate(acc);
            carry = @intCast(acc >> 64);
        }
        t[4] +%= carry;

        for (0..4) |j| {
            t[j] = t[j + 1];
        }
        t[4] = 0;
    }

    var r = FqElement{ t[0], t[1], t[2], t[3] };

    if (fq_cmp(r, fq_q) >= 0) {
        r = fq_sub(r, fq_q);
    }
    return r;
}

pub fn fq_sqr(a: FqElement) FqElement {
    return fq_mul(a, a);
}

pub fn fq_inv(a: FqElement) FqElement {
    // Fermat's little theorem: a^(q-2) mod q.
    // All operations use Montgomery multiplication, so the result is in
    // Montgomery form: if a = Montgomery(x), then fq_inv(a) = Montgomery(x^(-1)).
    const q_minus_2 = FqElement{ 0x3c208c16d87cfd45, 0x97816a916871ca8d, 0xb85045b68181585d, 0x30644e72e131a029 };

    var result = fq_one();
    var found_first = false;

    for (0..4) |word_idx| {
        const word = q_minus_2[3 - word_idx];
        var bit_mask: u64 = 1 << 63;
        while (bit_mask != 0) : (bit_mask >>= 1) {
            if (found_first) {
                result = fq_sqr(result);
            }
            if ((word & bit_mask) != 0) {
                if (!found_first) {
                    result = a;
                    found_first = true;
                } else {
                    result = fq_mul(result, a);
                }
            }
        }
    }

    return result;
}

pub fn fq_neg(a: FqElement) FqElement {
    if (fq_is_zero(a)) return fq_zero();
    return fq_sub(fq_q, a);
}

// ============================================================================
// BN254 Fq2 (Quadratic Extension Fq[i] / (i^2 + 1))
// ============================================================================

pub const Fq2Element = struct {
    a: FqElement, // real part
    b: FqElement, // imaginary part
};

pub fn fq2_zero() Fq2Element {
    return .{
        .a = fq_zero(),
        .b = fq_zero(),
    };
}

pub fn fq2_one() Fq2Element {
    return .{
        .a = fq_one(),
        .b = fq_zero(),
    };
}

pub fn fq2_add(a: Fq2Element, b: Fq2Element) Fq2Element {
    return .{
        .a = fq_add(a.a, b.a),
        .b = fq_add(a.b, b.b),
    };
}

pub fn fq2_sub(a: Fq2Element, b: Fq2Element) Fq2Element {
    return .{
        .a = fq_sub(a.a, b.a),
        .b = fq_sub(a.b, b.b),
    };
}

pub fn fq2_mul(a: Fq2Element, b: Fq2Element) Fq2Element {
    const ac = fq_mul(a.a, b.a);
    const bd = fq_mul(a.b, b.b);
    const ad = fq_mul(a.a, b.b);
    const bc = fq_mul(a.b, b.a);
    return .{
        .a = fq_sub(ac, bd),
        .b = fq_add(ad, bc),
    };
}

pub fn fq2_sqr(a: Fq2Element) Fq2Element {
    const ab = fq_mul(a.a, a.b);
    const a_plus_b = fq_add(a.a, a.b);
    const a_minus_b = fq_sub(a.a, a.b);
    return .{
        .a = fq_mul(a_plus_b, a_minus_b),
        .b = fq_add(ab, ab),
    };
}

pub fn fq2_inv(a: Fq2Element) Fq2Element {
    const a_sq = fq_sqr(a.a);
    const b_sq = fq_sqr(a.b);
    const denom = fq_add(a_sq, b_sq);
    const inv_denom = fq_inv(denom);
    return .{
        .a = fq_mul(a.a, inv_denom),
        .b = fq_neg(fq_mul(a.b, inv_denom)),
    };
}

pub fn fq2_neg(a: Fq2Element) Fq2Element {
    return .{
        .a = fq_neg(a.a),
        .b = fq_neg(a.b),
    };
}

pub fn fq2_eq(a: Fq2Element, b: Fq2Element) bool {
    return fq_eq(a.a, b.a) and fq_eq(a.b, b.b);
}

pub fn fq2_is_zero(a: Fq2Element) bool {
    return fq_is_zero(a.a) and fq_is_zero(a.b);
}

// ============================================================================
// Tests
// ============================================================================

test "fr_add" {
    const a = fr_from_u64(1);
    const b = fr_from_u64(2);
    const c = fr_add(a, b);
    try std.testing.expect(fr_eq(c, fr_from_u64(3)));
}

test "fr_mul_montgomery" {
    const a = fr_toMont(fr_from_u64(2));
    const b = fr_toMont(fr_from_u64(3));
    const c = fr_mul(a, b);
    const result = fr_fromMont(c);
    try std.testing.expect(fr_eq(result, fr_from_u64(6)));
}

test "fr_inv" {
    const a = fr_toMont(fr_from_u64(3));
    const inv = fr_inv(a);
    const one = fr_toMont(fr_from_u64(1));
    const prod = fr_mul(a, inv);
    try std.testing.expect(fr_eq(prod, one));
}

test "fr_sub" {
    const a = fr_from_u64(5);
    const b = fr_from_u64(3);
    const c = fr_sub(a, b);
    try std.testing.expect(fr_eq(c, fr_from_u64(2)));
}

test "fr_neg" {
    const a = fr_from_u64(5);
    const neg_a = fr_neg(a);
    const sum = fr_add(a, neg_a);
    try std.testing.expect(fr_eq(sum, fr_zero()));
}

test "fr_toMont/fr_fromMont roundtrip" {
    // Test that fr_toMont(1) gives the expected Montgomery representation of 1
    const one = fr_from_u64(1);
    const one_mont = fr_toMont(one);
    // R mod q = 0x0e0a77c19a07df2f666ea36f7879462e36fc76959f60cd29ac96341c4ffffffb
    const expected_one_mont = FrElement{ 0xac96341c4ffffffb, 0x36fc76959f60cd29, 0x666ea36f7879462e, 0x0e0a77c19a07df2f };
    try std.testing.expect(fr_eq(one_mont, expected_one_mont));

    // Test that fr_fromMont gives back 1
    const back = fr_fromMont(one_mont);
    try std.testing.expect(fr_eq(back, one));
}

test "fq_add" {
    const a = fq_from_u64(1);
    const b = fq_from_u64(2);
    const c = fq_add(a, b);
    try std.testing.expect(fq_eq(c, fq_from_u64(3)));
}

test "fq_mul_montgomery" {
    const a = fq_toMont(fq_from_u64(2));
    const b = fq_toMont(fq_from_u64(3));
    const c = fq_mul(a, b);
    const result = fq_fromMont(c);
    try std.testing.expect(fq_eq(result, fq_from_u64(6)));
}

test "fq_mul 16_mont" {
    // 16_mont in Fq field (little-endian limbs)
    const a = FqElement{ 0x45520880f6fce4b4, 0x49890849baa989a8, 0x85a9201d818f014a, 0x1f16424e1bb7724f };
    const expected = FqElement{ 0xfbdb0f2afaec667a, 0xad825aed9626b0ff, 0x276f48b709e2a0fc, 0xd791464ef86e357 };

    const result = fq_mul(a, a);
    try std.testing.expect(fq_eq(result, expected));
}

test "fq_inv" {
    const a = fq_toMont(fq_from_u64(3));
    const inv = fq_inv(a);
    const one = fq_toMont(fq_from_u64(1));
    const prod = fq_mul(a, inv);
    try std.testing.expect(fq_eq(prod, one));
}

test "fq_mul with large values" {
    // a = 0x16e43f7b184b033227a64f5a87a6e209ac39ec9be136c7ef32ae8ff3d84d0bda mod q
    const a = FqElement{ 0x32ae8ff3d84d0bda, 0xac39ec9be136c7ef, 0x27a64f5a87a6e209, 0x16e43f7b184b0332 };
    // b = 0x2770813d3c9fb89d25c864b4a3bb6f3e1c58308eabc2d0df25c02c7cf5e28296 mod q
    const b = FqElement{ 0x25c02c7cf5e28296, 0x1c58308eabc2d0df, 0x25c864b4a3bb6f3e, 0x2770813d3c9fb89d };
    // expected = Montgomery((a * b) mod q) = 0x161cbbe44eed9d5b2bfa8f36cc444275848d7eff0578184192d4256f19a26940
    const expected = FqElement{ 0x92d4256f19a26940, 0x848d7eff05781841, 0x2bfa8f36cc444275, 0x161cbbe44eed9d5b };
    const result = fq_mul(a, b);
    try std.testing.expect(fq_cmp(result, expected) == 0);
}

test "fq_inv with large values" {
    // a = 0x16e43f7b184b033227a64f5a87a6e209ac39ec9be136c7ef32ae8ff3d84d0bda mod q
    const a = FqElement{ 0x32ae8ff3d84d0bda, 0xac39ec9be136c7ef, 0x27a64f5a87a6e209, 0x16e43f7b184b0332 };
    const inv = fq_inv(a);
    const prod = fq_mul(a, inv);
    try std.testing.expect(fq_eq(prod, fq_one()));
}

test "fq2_mul" {
    const a = Fq2Element{ .a = fq_toMont(fq_from_u64(1)), .b = fq_toMont(fq_from_u64(2)) };
    const b = Fq2Element{ .a = fq_toMont(fq_from_u64(3)), .b = fq_toMont(fq_from_u64(4)) };
    const c = fq2_mul(a, b);
    // (1+2i)(3+4i) = -5 + 10i in Montgomery form
    const expected_a = fq_neg(fq_toMont(fq_from_u64(5)));
    const expected_b = fq_toMont(fq_from_u64(10));
    try std.testing.expect(fq_eq(c.a, expected_a));
    try std.testing.expect(fq_eq(c.b, expected_b));
}

test "fq2_inv" {
    const a = Fq2Element{ .a = fq_toMont(fq_from_u64(1)), .b = fq_toMont(fq_from_u64(1)) };
    const inv = fq2_inv(a);
    const one = Fq2Element{ .a = fq_one(), .b = fq_zero() };
    const prod = fq2_mul(a, inv);
    try std.testing.expect(fq2_eq(prod, one));
}

test "fr_mul with large values" {
    // a = 0x16e43f7b184b033227a64f5a87a6e209ac39ec9be136c7ef32ae8ff3d84d0bda
    const a = FrElement{ 0x32ae8ff3d84d0bda, 0xac39ec9be136c7ef, 0x27a64f5a87a6e209, 0x16e43f7b184b0332 };
    // b = 0x2770813d3c9fb89d25c864b4a3bb6f3e1c58308eabc2d0df25c02c7cf5e28296
    const b = FrElement{ 0x25c02c7cf5e28296, 0x1c58308eabc2d0df, 0x25c864b4a3bb6f3e, 0x2770813d3c9fb89d };
    // expected = 0x94f2d985fdf0cc6c32718486a6f65060904d328e7eb9145f51940de482bfc65
    const expected = FrElement{ 0xf51940de482bfc65, 0x0904d328e7eb9145, 0xc32718486a6f6506, 0x094f2d985fdf0cc6 };
    const result = fr_mul(a, b);
    try std.testing.expect(fr_cmp(result, expected) == 0);
}

test "fr_fromMont with large value" {
    const a = FrElement{ 0x32ae8ff3d84d0bda, 0xac39ec9be136c7ef, 0x27a64f5a87a6e209, 0x16e43f7b184b0332 };
    const expected = FrElement{ 0x437d50fc364a6add, 0xf6327dc1f7b0969a, 0xd6d330c61bd98a9d, 0xab3eccb5ac26a9e };
    const result = fr_fromMont(a);
    try std.testing.expect(fr_cmp(result, expected) == 0);
}

test "fr_inv of 2_mont" {
    const two_mont = fr_toMont(fr_from_u64(2));
    const two_inv_mont = fr_inv(two_mont);
    // Check that 2_mont * two_inv_mont = 1_mont
    const product = fr_mul(two_mont, two_inv_mont);
    try std.testing.expect(fr_eq(product, fr_one()));
}
