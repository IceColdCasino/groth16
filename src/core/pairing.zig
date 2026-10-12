const std = @import("std");
const field = @import("field.zig");
const curve = @import("curve.zig");

// ============================================================================
// BN254 Tower Fields: Fq6 = Fq2[v]/(v^3 - ξ), Fq12 = Fq6[w]/(w^2 - v)
// ============================================================================

pub const FqElement = field.FqElement;
pub const Fq2Element = field.Fq2Element;
pub const Fq6Element = struct {
    c0: Fq2Element, // coefficient of 1
    c1: Fq2Element, // coefficient of v
    c2: Fq2Element, // coefficient of v^2
};

pub const Fq12Element = struct {
    c0: Fq6Element, // coefficient of 1
    c1: Fq6Element, // coefficient of w
};

// ξ = 9 + u ∈ Fq2
fn xi() Fq2Element {
    return .{
        .a = field.fq_toMont(field.fq_from_u64(9)),
        .b = field.fq_one(),
    };
}

// ============================================================================
// Fq6 Arithmetic
// ============================================================================

pub fn fq6_zero() Fq6Element {
    return .{
        .c0 = field.fq2_zero(),
        .c1 = field.fq2_zero(),
        .c2 = field.fq2_zero(),
    };
}

pub fn fq6_one() Fq6Element {
    return .{
        .c0 = .{ .a = field.fq_one(), .b = field.fq_zero() },
        .c1 = field.fq2_zero(),
        .c2 = field.fq2_zero(),
    };
}

pub fn fq6_add(a: Fq6Element, b: Fq6Element) Fq6Element {
    return .{
        .c0 = field.fq2_add(a.c0, b.c0),
        .c1 = field.fq2_add(a.c1, b.c1),
        .c2 = field.fq2_add(a.c2, b.c2),
    };
}

pub fn fq6_sub(a: Fq6Element, b: Fq6Element) Fq6Element {
    return .{
        .c0 = field.fq2_sub(a.c0, b.c0),
        .c1 = field.fq2_sub(a.c1, b.c1),
        .c2 = field.fq2_sub(a.c2, b.c2),
    };
}

pub fn fq6_mul(a: Fq6Element, b: Fq6Element) Fq6Element {
    // (a0 + a1*v + a2*v^2) * (b0 + b1*v + b2*v^2)
    // c0 = a0*b0 + ξ*(a1*b2 + a2*b1)
    // c1 = a0*b1 + a1*b0 + ξ*a2*b2
    // c2 = a0*b2 + a1*b1 + a2*b0
    const a0b0 = field.fq2_mul(a.c0, b.c0);
    const a0b1 = field.fq2_mul(a.c0, b.c1);
    const a0b2 = field.fq2_mul(a.c0, b.c2);
    const a1b0 = field.fq2_mul(a.c1, b.c0);
    const a1b1 = field.fq2_mul(a.c1, b.c1);
    const a1b2 = field.fq2_mul(a.c1, b.c2);
    const a2b0 = field.fq2_mul(a.c2, b.c0);
    const a2b1 = field.fq2_mul(a.c2, b.c1);
    const a2b2 = field.fq2_mul(a.c2, b.c2);

    const xi_val = xi();

    const t0 = field.fq2_add(a1b2, a2b1);
    const t0_xi = field.fq2_mul(t0, xi_val);
    const r0 = field.fq2_add(a0b0, t0_xi);

    const t1 = field.fq2_add(a0b1, a1b0);
    const a2b2_xi = field.fq2_mul(a2b2, xi_val);
    const r1 = field.fq2_add(t1, a2b2_xi);

    const t2 = field.fq2_add(a0b2, a1b1);
    const r2 = field.fq2_add(t2, a2b0);

    return .{ .c0 = r0, .c1 = r1, .c2 = r2 };
}

pub fn fq6_sqr(a: Fq6Element) Fq6Element {
    // (a0 + a1*v + a2*v^2)^2
    // c0 = a0^2 + 2*a1*a2*ξ
    // c1 = 2*a0*a1 + a2^2*ξ
    // c2 = 2*a0*a2 + a1^2
    const a0_sqr = field.fq2_sqr(a.c0);
    const a1_sqr = field.fq2_sqr(a.c1);
    const a2_sqr = field.fq2_sqr(a.c2);

    const two_a0_a1 = field.fq2_mul(field.fq2_add(a.c0, a.c0), a.c1);
    const two_a1_a2 = field.fq2_mul(field.fq2_add(a.c1, a.c1), a.c2);
    const two_a0_a2 = field.fq2_mul(field.fq2_add(a.c0, a.c0), a.c2);

    const xi_val = xi();
    const r0 = field.fq2_add(a0_sqr, field.fq2_mul(two_a1_a2, xi_val));
    const r1 = field.fq2_add(two_a0_a1, field.fq2_mul(a2_sqr, xi_val));
    const r2 = field.fq2_add(two_a0_a2, a1_sqr);

    return .{ .c0 = r0, .c1 = r1, .c2 = r2 };
}

pub fn fq6_inv(a: Fq6Element) Fq6Element {
    // Use Fq6 inversion algorithm
    // t0 = c0^2 - ξ*c1*c2
    // t1 = ξ*c2^2 - c0*c1
    // t2 = c1^2 - c0*c2
    // t3 = inv(t0*c0 + ξ*(t1*c2 + t2*c1))
    const a0_sqr = field.fq2_sqr(a.c0);
    const a1_a2 = field.fq2_mul(a.c1, a.c2);
    const a2_sqr = field.fq2_sqr(a.c2);
    const a0_a1 = field.fq2_mul(a.c0, a.c1);
    const a1_sqr = field.fq2_sqr(a.c1);
    const a0_a2 = field.fq2_mul(a.c0, a.c2);

    const xi_val = xi();
    const t0 = field.fq2_sub(a0_sqr, field.fq2_mul(xi_val, a1_a2));
    const t1 = field.fq2_sub(field.fq2_mul(xi_val, a2_sqr), a0_a1);
    const t2 = field.fq2_sub(a1_sqr, a0_a2);

    const denom = field.fq2_add(
        field.fq2_mul(t0, a.c0),
        field.fq2_mul(xi_val, field.fq2_add(field.fq2_mul(t1, a.c2), field.fq2_mul(t2, a.c1))),
    );
    const inv_denom = field.fq2_inv(denom);

    return .{
        .c0 = field.fq2_mul(t0, inv_denom),
        .c1 = field.fq2_mul(t1, inv_denom),
        .c2 = field.fq2_mul(t2, inv_denom),
    };
}

pub fn fq6_neg(a: Fq6Element) Fq6Element {
    return .{
        .c0 = field.fq2_neg(a.c0),
        .c1 = field.fq2_neg(a.c1),
        .c2 = field.fq2_neg(a.c2),
    };
}

pub fn fq6_eq(a: Fq6Element, b: Fq6Element) bool {
    return field.fq2_eq(a.c0, b.c0) and field.fq2_eq(a.c1, b.c1) and field.fq2_eq(a.c2, b.c2);
}

// ============================================================================
// Fq12 Arithmetic
// ============================================================================

pub fn fq12_zero() Fq12Element {
    return .{
        .c0 = fq6_zero(),
        .c1 = fq6_zero(),
    };
}

pub fn fq12_one() Fq12Element {
    return .{
        .c0 = fq6_one(),
        .c1 = fq6_zero(),
    };
}

pub fn fq12_is_one(a: Fq12Element) bool {
    return fq6_eq(a.c0, fq6_one()) and fq6_eq(a.c1, fq6_zero());
}

pub fn fq12_add(a: Fq12Element, b: Fq12Element) Fq12Element {
    return .{
        .c0 = fq6_add(a.c0, b.c0),
        .c1 = fq6_add(a.c1, b.c1),
    };
}

pub fn fq12_sub(a: Fq12Element, b: Fq12Element) Fq12Element {
    return .{
        .c0 = fq6_sub(a.c0, b.c0),
        .c1 = fq6_sub(a.c1, b.c1),
    };
}

pub fn fq12_mul(a: Fq12Element, b: Fq12Element) Fq12Element {
    // (a0 + a1*w) * (b0 + b1*w) = (a0*b0 + v*a1*b1) + (a0*b1 + a1*b0)*w
    const a0b0 = fq6_mul(a.c0, b.c0);
    const a1b1 = fq6_mul(a.c1, b.c1);
    const a0b1 = fq6_mul(a.c0, b.c1);
    const a1b0 = fq6_mul(a.c1, b.c0);

    // v = Fq6Element{ c0: 0, c1: 1, c2: 0 }
    const v_a1b1 = fq6_mul_v(a1b1);
    const r0 = fq6_add(a0b0, v_a1b1);
    const r1 = fq6_add(a0b1, a1b0);

    return .{ .c0 = r0, .c1 = r1 };
}

// Multiply Fq6 element by v (i.e., v * x)
fn fq6_mul_v(a: Fq6Element) Fq6Element {
    // v * (c0 + c1*v + c2*v^2) = c0*v + c1*v^2 + c2*v^3 = c0*v + c1*v^2 + c2*ξ
    const xi_val = xi();
    return .{
        .c0 = field.fq2_mul(a.c2, xi_val),
        .c1 = a.c0,
        .c2 = a.c1,
    };
}

pub fn fq12_sqr(a: Fq12Element) Fq12Element {
    // (a0 + a1*w)^2 = (a0^2 + v*a1^2) + 2*a0*a1*w
    const a0_sqr = fq6_sqr(a.c0);
    const a1_sqr = fq6_sqr(a.c1);
    const v_a1_sqr = fq6_mul_v(a1_sqr);
    const r0 = fq6_add(a0_sqr, v_a1_sqr);
    const a0a1 = fq6_mul(a.c0, a.c1);
    const r1 = fq6_add(a0a1, a0a1);

    return .{ .c0 = r0, .c1 = r1 };
}

pub fn fq12_inv(a: Fq12Element) Fq12Element {
    // (a0 + a1*w)^(-1) = (a0 - a1*w) / (a0^2 - v*a1^2)
    const denom = fq6_sub(fq6_sqr(a.c0), fq6_mul_v(fq6_sqr(a.c1)));
    const inv_denom = fq6_inv(denom);
    return .{
        .c0 = fq6_mul(a.c0, inv_denom),
        .c1 = fq6_neg(fq6_mul(a.c1, inv_denom)),
    };
}

pub fn fq12_neg(a: Fq12Element) Fq12Element {
    return .{
        .c0 = fq6_neg(a.c0),
        .c1 = fq6_neg(a.c1),
    };
}

pub fn fq12_eq(a: Fq12Element, b: Fq12Element) bool {
    return fq6_eq(a.c0, b.c0) and fq6_eq(a.c1, b.c1);
}

// ============================================================================
// Sparse multiplication: Fq6 by (c0 + c1*v)
// ============================================================================

fn fq6_mul_by_01(a: Fq6Element, c0: Fq2Element, c1: Fq2Element) Fq6Element {
    const aa = field.fq2_mul(a.c0, c0);
    const bb = field.fq2_mul(a.c1, c1);

    var t1 = c1;
    {
        const tmp = field.fq2_add(a.c1, a.c2);
        t1 = field.fq2_mul(t1, tmp);
        t1 = field.fq2_sub(t1, bb);
        t1 = field.fq2_mul(t1, xi());
        t1 = field.fq2_add(t1, aa);
    }

    var t3 = c0;
    {
        const tmp = field.fq2_add(a.c0, a.c2);
        t3 = field.fq2_mul(t3, tmp);
        t3 = field.fq2_sub(t3, aa);
        t3 = field.fq2_add(t3, bb);
    }

    var t2 = field.fq2_add(c0, c1);
    {
        const tmp = field.fq2_add(a.c0, a.c1);
        t2 = field.fq2_mul(t2, tmp);
        t2 = field.fq2_sub(t2, aa);
        t2 = field.fq2_sub(t2, bb);
    }

    return .{ .c0 = t1, .c1 = t2, .c2 = t3 };
}

// ============================================================================
// Sparse multiplication: Fq12 by (c0 + c3*w + c4*w*v)
// ============================================================================

fn fq12_mul_by_034(f: Fq12Element, c0: Fq2Element, c3: Fq2Element, c4: Fq2Element) Fq12Element {
    const a0 = field.fq2_mul(f.c0.c0, c0);
    const a1 = field.fq2_mul(f.c0.c1, c0);
    const a2 = field.fq2_mul(f.c0.c2, c0);
    const a = Fq6Element{ .c0 = a0, .c1 = a1, .c2 = a2 };

    var b = fq6_mul_by_01(f.c1, c3, c4);

    const c0_plus_c3 = field.fq2_add(c0, c3);
    var e = fq6_add(f.c0, f.c1);
    e = fq6_mul_by_01(e, c0_plus_c3, c4);

    const new_c1 = fq6_sub(e, fq6_add(a, b));

    b = fq6_mul_v(b);

    const new_c0 = fq6_add(b, a);

    return .{ .c0 = new_c0, .c1 = new_c1 };
}

// ============================================================================
// Fq12 Conjugation (Frobenius p^6) = a^(p^6)
// For BN254: a^(p^6) = c0 - c1*w = conjugate(a)
// ============================================================================

pub fn fq12_conjugate(a: Fq12Element) Fq12Element {
    return .{
        .c0 = a.c0,
        .c1 = fq6_neg(a.c1),
    };
}

// ============================================================================
// Fq12 Exponentiation by large exponents
// ============================================================================

pub fn fq12_pow(base: Fq12Element, exponent_words: []const u64) Fq12Element {
    var result = fq12_one();
    var found_first = false;

    for (exponent_words) |word| {
        var bit_mask: u64 = 1 << 63;
        while (bit_mask != 0) : (bit_mask >>= 1) {
            if (found_first) {
                result = fq12_sqr(result);
            }
            if ((word & bit_mask) != 0) {
                if (!found_first) {
                    result = base;
                    found_first = true;
                } else {
                    result = fq12_mul(result, base);
                }
            }
        }
    }

    return result;
}

// ============================================================================
// Constants for final exponentiation
// ============================================================================

// p^2 (508 bits) in big-endian u64 words
const p_sq_words = [_]u64{
    0x0925c4b8763cbf9c,
    0x599a6f7c0348d21c,
    0xb00b855116375606,
    0x26edfa5c34c6b38d,
    0x04689e957a1242c8,
    0x4a50189c6d96cadc,
    0xa602072d09eac101,
    0x3b5458a2275d69b1,
};

// λ = (p^4 - p^2 + 1) / n (761 bits) in big-endian u64 words
const lambda_words = [_]u64{
    0x01baaa710b0759ad,
    0x331ec15183177faf,
    0x6c0eb522d5b12278,
    0x4e529a5861876f6b,
    0x3b1b1355d189227d,
    0x79581e16f3fd90c6,
    0x6b887d56d5095f23,
    0xaaa441e3954bcf8a,
    0xdcc7b44c87cdbacf,
    0xf1154e7e1da014fd,
    0x5abf5cc4f49c36d4,
    0xe81bb482ccdf42b1,
};

// n (group order) in big-endian u64 words for fq12_pow
const fr_q_be_words = [_]u64{
    0x30644e72e131a029,
    0xb85045b68181585d,
    0x2833e84879b97091,
    0x43e1f593f0000001,
};

// Full exponent for final exponentiation: (p^12 - 1) / n (2790 bits)
const final_exp_words = [_]u64{
    0x0000002f4b6dc970,
    0x20fddadf107d20bc,
    0x842d43bf6369b1ff,
    0x6a1c71015f3f7be2,
    0xe1e30a73bb94fec0,
    0xdaf15466b2383a5d,
    0x3ec3d15ad524d8f7,
    0x0c54efee1bd8c3b2,
    0x1377e563a09a1b70,
    0x5887e72eceaddea3,
    0x790364a61f676baa,
    0xf977870e88d5c6c8,
    0xfef0781361e443ae,
    0x77f5b63a2a226448,
    0x7f2940a8b1ddb3d1,
    0x5062cd0fb2015dfc,
    0x6668449aed3cc48a,
    0x82d0d602d268c7da,
    0xab6a41294c0cc4eb,
    0xe5664568dfc50e16,
    0x48a45a4a1e3a5195,
    0x846a3ed011a337a0,
    0x2088ec80e0ebae87,
    0x55cfe107acf3aafb,
    0x40494e406f804216,
    0xbb10cf430b0f3785,
    0x6b42db8dc5514724,
    0xee93dfb10826f0dd,
    0x4a0364b9580291d2,
    0xcd65664814fde37c,
    0xa80bb4ea44eacc5e,
    0x641bbadf423f9a2c,
    0xbf813b8d145da900,
    0x29baee7ddadda71c,
    0x7f3811c410526294,
    0x5bba1668c3be69a3,
    0xc230974d83561841,
    0xd766f9c9d570bb7f,
    0xbe04c7e8a6c3c760,
    0xc0de81def35692da,
    0x361102b6b9b2b918,
    0x837fa97896e84abb,
    0x40a4efb7e54523a4,
    0x86964b64ca86f120,
};

// ============================================================================
// Homogeneous Projective G2 Point Operations (matching ark-ec)
// ============================================================================

const G2HomProjective = struct {
    x: Fq2Element,
    y: Fq2Element,
    z: Fq2Element,
};

const G12Point = struct {
    x: Fq12Element,
    y: Fq12Element,
};

fn fq2_from_u64(v: u64) Fq2Element {
    return .{
        .a = field.fq_toMont(field.fq_from_u64(v)),
        .b = field.fq_zero(),
    };
}

fn fq12_from_u64(v: u64) Fq12Element {
    const fq2_val = Fq2Element{ .a = field.fq_toMont(field.fq_from_u64(v)), .b = field.fq_zero() };
    return .{
        .c0 = .{ .c0 = fq2_val, .c1 = field.fq2_zero(), .c2 = field.fq2_zero() },
        .c1 = fq6_zero(),
    };
}

fn g2_hom_is_zero(r: G2HomProjective) bool {
    return field.fq2_is_zero(r.z);
}

fn g2_hom_dbl_with_line(r: *G2HomProjective, p: curve.G1PointAffine) struct { c0: Fq2Element, c3: Fq2Element, c4: Fq2Element } {
    _ = p;
    if (g2_hom_is_zero(r.*)) {
        return .{ .c0 = field.fq2_one(), .c3 = field.fq2_zero(), .c4 = field.fq2_zero() };
    }

    const two_inv = field.fq_inv(field.fq_toMont(field.fq_from_u64(2)));
    const two_inv_fq2 = Fq2Element{ .a = two_inv, .b = field.fq_zero() };

    const b2 = field.fq2_mul(fq2_from_u64(3), field.fq2_inv(xi())); // b2 = 3/ξ

    var a = field.fq2_mul(r.x, r.y);
    a = field.fq2_mul(a, two_inv_fq2); // a = X*Y/2

    const b = field.fq2_sqr(r.y); // b = Y^2
    const c = field.fq2_sqr(r.z); // c = Z^2

    const e = field.fq2_mul(b2, field.fq2_add(field.fq2_add(c, c), c)); // e = b2 * (2*C + C) = 3*b2*C
    const f = field.fq2_add(field.fq2_add(e, e), e); // f = 3*e = 9*b2*C

    var g = field.fq2_add(b, f);
    g = field.fq2_mul(g, two_inv_fq2); // g = (b + f)/2

    const h = field.fq2_sub(field.fq2_sqr(field.fq2_add(r.y, r.z)), field.fq2_add(b, c)); // h = (Y+Z)^2 - (B+C) = 2*Y*Z
    const i = field.fq2_sub(e, b); // i = e - b = 3*b2*C - Y^2
    const j = field.fq2_sqr(r.x); // j = X^2
    const e_sq = field.fq2_sqr(e); // e^2

    // Update r
    const x_new = field.fq2_mul(a, field.fq2_sub(b, f)); // X_new = a * (b - f)
    const y_new = field.fq2_sub(field.fq2_sqr(g), field.fq2_add(field.fq2_add(e_sq, e_sq), e_sq)); // Y_new = g^2 - 3*e^2
    const z_new = field.fq2_mul(b, h); // Z_new = b * h = Y^2 * 2*Y*Z

    r.* = .{ .x = x_new, .y = y_new, .z = z_new };

    // Coefficients for D-type twist: (-h, 3j, i) (raw, without p.x/p.y multiplication)
    const c0 = field.fq2_neg(h);
    const c3 = field.fq2_mul(fq2_from_u64(3), j);
    const c4 = i;

    return .{ .c0 = c0, .c3 = c3, .c4 = c4 };
}

fn g2_hom_add_with_line(r: *G2HomProjective, q: curve.G2PointAffine, p: curve.G1PointAffine) struct { c0: Fq2Element, c3: Fq2Element, c4: Fq2Element } {
    _ = p;
    if (g2_hom_is_zero(r.*)) {
        r.* = .{ .x = q.x, .y = q.y, .z = field.fq2_one() };
        return .{ .c0 = field.fq2_one(), .c3 = field.fq2_zero(), .c4 = field.fq2_zero() };
    }

    // From ark-ec bn/g2.rs
    const theta = field.fq2_sub(r.y, field.fq2_mul(q.y, r.z)); // theta = Y1 - Y2*Z1
    const lambda = field.fq2_sub(r.x, field.fq2_mul(q.x, r.z)); // lambda = X1 - X2*Z1
    const c = field.fq2_sqr(theta); // c = theta^2
    const d = field.fq2_sqr(lambda); // d = lambda^2
    const e = field.fq2_mul(lambda, d); // e = lambda * d
    const f = field.fq2_mul(r.z, c); // f = Z1 * c
    const g = field.fq2_mul(r.x, d); // g = X1 * d
    const h = field.fq2_sub(field.fq2_add(e, f), field.fq2_add(g, g)); // h = e + f - 2*g

    // Update r
    const x_new = field.fq2_mul(lambda, h); // X_new = lambda * h
    const y_new = field.fq2_sub(field.fq2_mul(theta, field.fq2_sub(g, h)), field.fq2_mul(e, r.y)); // Y_new = theta * (g - h) - e * Y1
    const z_new = field.fq2_mul(r.z, e); // Z_new = Z1 * e

    r.* = .{ .x = x_new, .y = y_new, .z = z_new };

    const j = field.fq2_sub(field.fq2_mul(theta, q.x), field.fq2_mul(lambda, q.y)); // j = theta * X2 - lambda * Y2

    // Coefficients for D-type twist: (lambda, -theta, j) (raw, without p.x/p.y multiplication)
    const c0 = lambda;
    const c3 = field.fq2_neg(theta);
    const c4 = j;

    return .{ .c0 = c0, .c3 = c3, .c4 = c4 };
}

// ============================================================================
// G1/G2 to Affine Conversion
// ============================================================================

pub fn g1_to_affine(p: curve.G1Point) curve.G1PointAffine {
    if (curve.g1_is_zero(p)) {
        return .{ .x = field.fq_zero(), .y = field.fq_zero() };
    }
    const zz_inv = field.fq_inv(p.zz);
    const zzz_inv = field.fq_inv(p.zzz);
    return .{
        .x = field.fq_mul(p.x, zz_inv),
        .y = field.fq_mul(p.y, zzz_inv),
    };
}

pub fn g2_to_affine(p: curve.G2Point) curve.G2PointAffine {
    if (curve.g2_is_zero(p)) {
        return .{ .x = field.fq2_zero(), .y = field.fq2_zero() };
    }
    const zz_inv = field.fq2_inv(p.zz);
    const zzz_inv = field.fq2_inv(p.zzz);
    return .{
        .x = field.fq2_mul(p.x, zz_inv),
        .y = field.fq2_mul(p.y, zzz_inv),
    };
}

// Embed G1 point into Fq12
fn g1_cast_to_fq12(pt: curve.G1PointAffine) G12Point {
    const x_fq2 = Fq2Element{ .a = pt.x, .b = field.fq_zero() };
    const y_fq2 = Fq2Element{ .a = pt.y, .b = field.fq_zero() };
    return .{
        .x = .{
            .c0 = .{ .c0 = x_fq2, .c1 = field.fq2_zero(), .c2 = field.fq2_zero() },
            .c1 = fq6_zero(),
        },
        .y = .{
            .c0 = .{ .c0 = y_fq2, .c1 = field.fq2_zero(), .c2 = field.fq2_zero() },
            .c1 = fq6_zero(),
        },
    };
}

// G12 point doubling
fn g12_dbl(p: G12Point) G12Point {
    if (g12_is_zero(p)) return p;

    const three = fq12_from_u64(3);
    const two = fq12_from_u64(2);

    const x_sqr = fq12_sqr(p.x);
    const numerator = fq12_mul(three, x_sqr);
    const denominator = fq12_mul(two, p.y);
    const slope = fq12_mul(numerator, fq12_inv(denominator));

    const slope_sqr = fq12_sqr(slope);
    const two_x = fq12_add(p.x, p.x);
    const x3 = fq12_sub(slope_sqr, two_x);

    const x_diff = fq12_sub(p.x, x3);
    const slope_x_diff = fq12_mul(slope, x_diff);
    const y3 = fq12_sub(slope_x_diff, p.y);

    return .{ .x = x3, .y = y3 };
}

// G12 point addition
fn g12_add(a: G12Point, b: G12Point) G12Point {
    if (g12_is_zero(a)) return b;
    if (g12_is_zero(b)) return a;

    if (fq12_eq(a.x, b.x)) {
        if (fq12_eq(a.y, b.y)) {
            return g12_dbl(a);
        } else {
            return .{ .x = fq12_zero(), .y = fq12_zero() };
        }
    }

    const y_diff = fq12_sub(b.y, a.y);
    const x_diff = fq12_sub(b.x, a.x);
    const slope = fq12_mul(y_diff, fq12_inv(x_diff));

    const slope_sqr = fq12_sqr(slope);
    const x3_1 = fq12_sub(slope_sqr, a.x);
    const x3 = fq12_sub(x3_1, b.x);

    const x_diff_a = fq12_sub(a.x, x3);
    const slope_x_diff = fq12_mul(slope, x_diff_a);
    const y3 = fq12_sub(slope_x_diff, a.y);

    return .{ .x = x3, .y = y3 };
}

// G12 point negation
fn g12_neg(p: G12Point) G12Point {
    return .{ .x = p.x, .y = fq12_neg(p.y) };
}

// Check if G12 point is zero (infinity)
fn g12_is_zero(p: G12Point) bool {
    return fq12_eq(p.x, fq12_zero()) and fq12_eq(p.y, fq12_zero());
}

fn g12_is_on_curve(p: G12Point) bool {
    if (g12_is_zero(p)) return true;
    const x3 = fq12_mul(fq12_sqr(p.x), p.x);
    // b12 = 3/ξ^2 for D-type twist
    const xi_val = xi();
    const xi_sq = field.fq2_sqr(xi_val);
    const b12_fq2 = field.fq2_mul(field.Fq2Element{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_zero() }, field.fq2_inv(xi_sq));
    const b12 = Fq12Element{
        .c0 = .{ .c0 = b12_fq2, .c1 = field.fq2_zero(), .c2 = field.fq2_zero() },
        .c1 = fq6_zero(),
    };
    const lhs = fq12_sqr(p.y);
    const rhs = fq12_add(x3, b12);
    return fq12_eq(lhs, rhs);
}

// D-type twist: ψ(x', y') = (x'/v, y'/(v·w))
// In Fq6[v]/(v^3 - ξ): 1/v = v^2/ξ
// In Fq12[w]/(w^2 - v): 1/(v·w) = v·w/ξ
// So: x = x'·v^2/ξ, y = y'·v·w/ξ
fn g2_twist_to_fq12(pt: curve.G2PointAffine) G12Point {
    const xi_val = xi();
    const xi_inv = field.fq2_inv(xi_val);
    const x_scaled = field.fq2_mul(pt.x, xi_inv);
    const y_scaled = field.fq2_mul(pt.y, xi_inv);
    return .{
        .x = .{
            .c0 = .{ .c0 = field.fq2_zero(), .c1 = field.fq2_zero(), .c2 = x_scaled },
            .c1 = fq6_zero(),
        },
        .y = .{
            .c0 = fq6_zero(),
            .c1 = .{ .c0 = field.fq2_zero(), .c1 = y_scaled, .c2 = field.fq2_zero() },
        },
    };
}

// ============================================================================
// Miller Loop for BN254 Ate Pairing
// ============================================================================

pub fn miller_loop(p: curve.G1Point, q: curve.G2Point) Fq12Element {
    const p_affine = curve.g1_normalize(p);

    const q_affine = curve.g2_normalize(q);

    // Ate loop count NAF (non-adjacent form)
    // Matches ark-bn254 0.5.0
    const ate_loop_count: [65]i8 = .{
        0, 0, 0, 1, 0, 1, 0, -1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, 0, -1, 0, 0, 0, 1, 0, -1, 0, 0, 0,
        0, -1, 0, 0, 1, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, -1, 0, 0, -1, 0, 1, 0, -1, 0, 0, 0, -1, 0,
        -1, 0, 0, 0, 1, 0, 1, 1,
    };

    const neg_q = curve.G2PointAffine{
        .x = q_affine.x,
        .y = field.fq2_neg(q_affine.y),
    };

    // Initialize r in homogeneous projective coordinates
    var r = G2HomProjective{
        .x = q_affine.x,
        .y = q_affine.y,
        .z = field.fq2_one(),
    };

    var f = fq12_one();

    // Main loop: matches ark-ec structure
    // Loop from i = 64 down to 1
    // For i = 64: no squaring, just apply first coefficients
    // For i < 64: square first, then apply coefficients
    var i: usize = 64;
    while (i >= 1) : (i -= 1) {
        if (i != 64) {
            f = fq12_sqr(f);
        }

        // Doubling step
        const coeffs_dbl = g2_hom_dbl_with_line(&r, p_affine);
        const c0_dbl = field.fq2_mul(coeffs_dbl.c0, Fq2Element{ .a = p_affine.y, .b = field.fq_zero() });
        const c3_dbl = field.fq2_mul(coeffs_dbl.c3, Fq2Element{ .a = p_affine.x, .b = field.fq_zero() });
        f = fq12_mul_by_034(f, c0_dbl, c3_dbl, coeffs_dbl.c4);

        const bit = ate_loop_count[i - 1];
        if (bit == 1) {
            // Addition step
            const coeffs_add = g2_hom_add_with_line(&r, q_affine, p_affine);
            const c0_add = field.fq2_mul(coeffs_add.c0, Fq2Element{ .a = p_affine.y, .b = field.fq_zero() });
            const c3_add = field.fq2_mul(coeffs_add.c3, Fq2Element{ .a = p_affine.x, .b = field.fq_zero() });
            f = fq12_mul_by_034(f, c0_add, c3_add, coeffs_add.c4);
        } else if (bit == -1) {
            // Subtraction step (add -Q)
            const coeffs_sub = g2_hom_add_with_line(&r, neg_q, p_affine);
            const c0_sub = field.fq2_mul(coeffs_sub.c0, Fq2Element{ .a = p_affine.y, .b = field.fq_zero() });
            const c3_sub = field.fq2_mul(coeffs_sub.c3, Fq2Element{ .a = p_affine.x, .b = field.fq_zero() });
            f = fq12_mul_by_034(f, c0_sub, c3_sub, coeffs_sub.c4);
        }
    }

    // Final adjustments for optimal ate pairing
    const twist_mul_by_q_x = field.Fq2Element{
        .a = FqElement{ 0xb5773b104563ab30, 0x347f91c8a9aa6454, 0x7a007127242e0991, 0x1956bcd8118214ec },
        .b = FqElement{ 0x6e849f1ea0aa4757, 0xaa1c7b6d89f89141, 0xb6e713cdfae0ca3a, 0x26694fbb4e82ebc3 },
    };
    const twist_mul_by_q_y = field.Fq2Element{
        .a = FqElement{ 0xe4bbdd0c2936b629, 0xbb30f162e133bacb, 0x31a9d1b6f9645366, 0x253570bea500f8dd },
        .b = FqElement{ 0xa1d77ce45ffe77c7, 0x07affd117826d1db, 0x6d16bd27bb7edc6b, 0x2c87200285defecc },
    };

    const q1_fq2 = curve.G2PointAffine{
        .x = field.fq2_mul(
            field.Fq2Element{ .a = q_affine.x.a, .b = field.fq_neg(q_affine.x.b) },
            twist_mul_by_q_x,
        ),
        .y = field.fq2_mul(
            field.Fq2Element{ .a = q_affine.y.a, .b = field.fq_neg(q_affine.y.b) },
            twist_mul_by_q_y,
        ),
    };

    const q2_temp_fq2 = curve.G2PointAffine{
        .x = field.fq2_mul(
            field.Fq2Element{ .a = q1_fq2.x.a, .b = field.fq_neg(q1_fq2.x.b) },
            twist_mul_by_q_x,
        ),
        .y = field.fq2_mul(
            field.Fq2Element{ .a = q1_fq2.y.a, .b = field.fq_neg(q1_fq2.y.b) },
            twist_mul_by_q_y,
        ),
    };
    const q2_fq2 = curve.G2PointAffine{
        .x = q2_temp_fq2.x,
        .y = field.fq2_neg(q2_temp_fq2.y),
    };

    // First final line
    const coeffs1 = g2_hom_add_with_line(&r, q1_fq2, p_affine);
    const c0_1 = field.fq2_mul(coeffs1.c0, Fq2Element{ .a = p_affine.y, .b = field.fq_zero() });
    const c3_1 = field.fq2_mul(coeffs1.c3, Fq2Element{ .a = p_affine.x, .b = field.fq_zero() });
    f = fq12_mul_by_034(f, c0_1, c3_1, coeffs1.c4);

    // Second final line
    const coeffs2 = g2_hom_add_with_line(&r, q2_fq2, p_affine);
    const c0_2 = field.fq2_mul(coeffs2.c0, Fq2Element{ .a = p_affine.y, .b = field.fq_zero() });
    const c3_2 = field.fq2_mul(coeffs2.c3, Fq2Element{ .a = p_affine.x, .b = field.fq_zero() });
    f = fq12_mul_by_034(f, c0_2, c3_2, coeffs2.c4);

    return f;
}

// ============================================================================
// Final Exponentiation
// ============================================================================

pub fn final_exponentiation(f: Fq12Element) Fq12Element {
    // Full final exponentiation: f^((p^12 - 1) / n)
    return fq12_pow(f, &final_exp_words);
}

// ============================================================================
// Full Ate Pairing
// ============================================================================

pub fn ate_pairing(p: curve.G1Point, q: curve.G2Point) Fq12Element {
    if (curve.g1_is_zero(p) or curve.g2_is_zero(q)) {
        return fq12_one();
    }
    const f = miller_loop(p, q);
    return final_exponentiation(f);
}

// ============================================================================
// Tests
// ============================================================================

test "twisted g2 on curve" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{
        .x = g2.x,
        .y = g2.y,
    };
    const g2_fq12 = g2_twist_to_fq12(g2_affine);

    // Verify x^2 for D-type twist: x = x'·v^2/ξ, so x^2 = x'^2·v/ξ
    const xi_val = xi();
    const xi_inv = field.fq2_inv(xi_val);


    const x_sqr = fq12_sqr(g2_fq12.x);
    const g2_x_sq = field.fq2_sqr(g2_affine.x);
    const expected_x_sq_coeff = field.fq2_mul(g2_x_sq, xi_inv);
    const expected_x_sqr = Fq12Element{
        .c0 = .{ .c0 = field.fq2_zero(), .c1 = expected_x_sq_coeff, .c2 = field.fq2_zero() },
        .c1 = fq6_zero(),
    };
    try std.testing.expect(fq12_eq(x_sqr, expected_x_sqr));

    const x3 = fq12_mul(x_sqr, g2_fq12.x);
    // b12 = 3/ξ^2 for D-type twist
    const xi_sq = field.fq2_sqr(xi_val);
    const b12_fq2 = field.fq2_mul(field.Fq2Element{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_zero() }, field.fq2_inv(xi_sq));
    const b12 = Fq12Element{
        .c0 = .{ .c0 = b12_fq2, .c1 = field.fq2_zero(), .c2 = field.fq2_zero() },
        .c1 = fq6_zero(),
    };
    const lhs = fq12_sqr(g2_fq12.y);
    const rhs = fq12_add(x3, b12);
    try std.testing.expect(fq12_eq(lhs, rhs));
}

test "fq6_sqr sparse" {
    const xi_inv = field.fq2_inv(xi());
    const x_prime = field.Fq2Element{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(7)) };
    const x_scaled = field.fq2_mul(x_prime, xi_inv);

    const a = Fq6Element{
        .c0 = field.fq2_zero(),
        .c1 = field.fq2_zero(),
        .c2 = x_scaled,
    };

    const sqr = fq6_sqr(a);
    const mul = fq6_mul(a, a);

    // Verify sqr == mul
    try std.testing.expect(fq6_eq(sqr, mul));

    // For a = {0, 0, x_scaled}, a^2 should be {0, x_scaled^2 * xi, 0}
    const x_scaled_sq = field.fq2_sqr(x_scaled);
    const expected_c1 = field.fq2_mul(x_scaled_sq, xi());
    const expected = Fq6Element{
        .c0 = field.fq2_zero(),
        .c1 = expected_c1,
        .c2 = field.fq2_zero(),
    };
    try std.testing.expect(fq6_eq(sqr, expected));
}

test "fq6_mul" {
    const a = Fq6Element{
        .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(1)), .b = field.fq_toMont(field.fq_from_u64(2)) },
        .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
        .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
    };
    const b = Fq6Element{
        .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(2)), .b = field.fq_toMont(field.fq_from_u64(3)) },
        .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(4)), .b = field.fq_toMont(field.fq_from_u64(5)) },
        .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(6)), .b = field.fq_toMont(field.fq_from_u64(7)) },
    };
    const c = Fq6Element{
        .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
        .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
        .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(7)), .b = field.fq_toMont(field.fq_from_u64(8)) },
    };

    const ab = fq6_mul(a, b);
    const bc = fq6_mul(b, c);
    const ab_c = fq6_mul(ab, c);
    const a_bc = fq6_mul(a, bc);
    try std.testing.expect(fq6_eq(ab_c, a_bc));
}

test "fq6_inv" {
    const a = Fq6Element{
        .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(1)), .b = field.fq_toMont(field.fq_from_u64(2)) },
        .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
        .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
    };
    const inv = fq6_inv(a);
    const one = fq6_one();
    const prod = fq6_mul(a, inv);
    try std.testing.expect(fq6_eq(prod, one));
}

test "fq12_mul_identity" {
    const a = Fq12Element{
        .c0 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(1)), .b = field.fq_toMont(field.fq_from_u64(2)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
        },
        .c1 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(7)), .b = field.fq_toMont(field.fq_from_u64(8)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(9)), .b = field.fq_toMont(field.fq_from_u64(10)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(11)), .b = field.fq_toMont(field.fq_from_u64(12)) },
        },
    };
    const b = fq12_one();
    const c = fq12_mul(a, b);
    try std.testing.expect(fq12_eq(c, a));
}

test "fq12_sqr" {
    const a = Fq12Element{
        .c0 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(1)), .b = field.fq_toMont(field.fq_from_u64(2)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
        },
        .c1 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(7)), .b = field.fq_toMont(field.fq_from_u64(8)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(9)), .b = field.fq_toMont(field.fq_from_u64(10)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(11)), .b = field.fq_toMont(field.fq_from_u64(12)) },
        },
    };
    const sqr = fq12_sqr(a);
    const mul = fq12_mul(a, a);
    try std.testing.expect(fq12_eq(sqr, mul));
}

test "fq12_mul_associative" {
    const a = Fq12Element{
        .c0 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(1)), .b = field.fq_toMont(field.fq_from_u64(2)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
        },
        .c1 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(7)), .b = field.fq_toMont(field.fq_from_u64(8)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(9)), .b = field.fq_toMont(field.fq_from_u64(10)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(11)), .b = field.fq_toMont(field.fq_from_u64(12)) },
        },
    };
    const b = Fq12Element{
        .c0 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(2)), .b = field.fq_toMont(field.fq_from_u64(3)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(4)), .b = field.fq_toMont(field.fq_from_u64(5)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(6)), .b = field.fq_toMont(field.fq_from_u64(7)) },
        },
        .c1 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(8)), .b = field.fq_toMont(field.fq_from_u64(9)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(10)), .b = field.fq_toMont(field.fq_from_u64(11)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(12)), .b = field.fq_toMont(field.fq_from_u64(13)) },
        },
    };
    const c = Fq12Element{
        .c0 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(7)), .b = field.fq_toMont(field.fq_from_u64(8)) },
        },
        .c1 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(9)), .b = field.fq_toMont(field.fq_from_u64(10)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(11)), .b = field.fq_toMont(field.fq_from_u64(12)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(13)), .b = field.fq_toMont(field.fq_from_u64(14)) },
        },
    };
    const ab = fq12_mul(a, b);
    const bc = fq12_mul(b, c);
    const ab_c = fq12_mul(ab, c);
    const a_bc = fq12_mul(a, bc);
    try std.testing.expect(fq12_eq(ab_c, a_bc));
}

test "fq12_mul_distributive" {
    const a = Fq12Element{
        .c0 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(1)), .b = field.fq_toMont(field.fq_from_u64(2)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
        },
        .c1 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(7)), .b = field.fq_toMont(field.fq_from_u64(8)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(9)), .b = field.fq_toMont(field.fq_from_u64(10)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(11)), .b = field.fq_toMont(field.fq_from_u64(12)) },
        },
    };
    const b = Fq12Element{
        .c0 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(2)), .b = field.fq_toMont(field.fq_from_u64(3)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(4)), .b = field.fq_toMont(field.fq_from_u64(5)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(6)), .b = field.fq_toMont(field.fq_from_u64(7)) },
        },
        .c1 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(8)), .b = field.fq_toMont(field.fq_from_u64(9)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(10)), .b = field.fq_toMont(field.fq_from_u64(11)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(12)), .b = field.fq_toMont(field.fq_from_u64(13)) },
        },
    };
    const c = Fq12Element{
        .c0 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(7)), .b = field.fq_toMont(field.fq_from_u64(8)) },
        },
        .c1 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(9)), .b = field.fq_toMont(field.fq_from_u64(10)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(11)), .b = field.fq_toMont(field.fq_from_u64(12)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(13)), .b = field.fq_toMont(field.fq_from_u64(14)) },
        },
    };
    const b_plus_c = fq12_add(b, c);
    const a_bpc = fq12_mul(a, b_plus_c);
    const ab = fq12_mul(a, b);
    const ac = fq12_mul(a, c);
    const ab_ac = fq12_add(ab, ac);
    try std.testing.expect(fq12_eq(a_bpc, ab_ac));
}

test "fq12_inv" {
    const a = Fq12Element{
        .c0 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(1)), .b = field.fq_toMont(field.fq_from_u64(2)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
        },
        .c1 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(7)), .b = field.fq_toMont(field.fq_from_u64(8)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(9)), .b = field.fq_toMont(field.fq_from_u64(10)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(11)), .b = field.fq_toMont(field.fq_from_u64(12)) },
        },
    };
    const inv = fq12_inv(a);
    const one = fq12_one();
    const prod = fq12_mul(a, inv);
    try std.testing.expect(fq12_eq(prod, one));
}

test "fq12_pow" {
    const a = Fq12Element{
        .c0 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(2)), .b = field.fq_zero() },
            .c1 = field.fq2_zero(),
            .c2 = field.fq2_zero(),
        },
        .c1 = fq6_zero(),
    };
    const pow3 = fq12_pow(a, &[_]u64{3});
    const expected = fq12_mul(fq12_sqr(a), a);
    try std.testing.expect(fq12_eq(pow3, expected));
}

test "fq6_mul_by_01" {
    const a = Fq6Element{
        .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(1)), .b = field.fq_toMont(field.fq_from_u64(2)) },
        .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
        .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
    };
    const c0 = Fq2Element{ .a = field.fq_toMont(field.fq_from_u64(7)), .b = field.fq_toMont(field.fq_from_u64(8)) };
    const c1 = Fq2Element{ .a = field.fq_toMont(field.fq_from_u64(9)), .b = field.fq_toMont(field.fq_from_u64(10)) };

    const sparse = Fq6Element{ .c0 = c0, .c1 = c1, .c2 = field.fq2_zero() };
    const expected = fq6_mul(a, sparse);
    const actual = fq6_mul_by_01(a, c0, c1);

    try std.testing.expect(fq6_eq(expected, actual));
}

test "fq12_mul_by_034" {
    const a = Fq12Element{
        .c0 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(1)), .b = field.fq_toMont(field.fq_from_u64(2)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(3)), .b = field.fq_toMont(field.fq_from_u64(4)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(5)), .b = field.fq_toMont(field.fq_from_u64(6)) },
        },
        .c1 = .{
            .c0 = .{ .a = field.fq_toMont(field.fq_from_u64(7)), .b = field.fq_toMont(field.fq_from_u64(8)) },
            .c1 = .{ .a = field.fq_toMont(field.fq_from_u64(9)), .b = field.fq_toMont(field.fq_from_u64(10)) },
            .c2 = .{ .a = field.fq_toMont(field.fq_from_u64(11)), .b = field.fq_toMont(field.fq_from_u64(12)) },
        },
    };
    const c0 = Fq2Element{ .a = field.fq_toMont(field.fq_from_u64(13)), .b = field.fq_toMont(field.fq_from_u64(14)) };
    const c3 = Fq2Element{ .a = field.fq_toMont(field.fq_from_u64(15)), .b = field.fq_toMont(field.fq_from_u64(16)) };
    const c4 = Fq2Element{ .a = field.fq_toMont(field.fq_from_u64(17)), .b = field.fq_toMont(field.fq_from_u64(18)) };

    const sparse = Fq12Element{
        .c0 = .{ .c0 = c0, .c1 = field.fq2_zero(), .c2 = field.fq2_zero() },
        .c1 = .{ .c0 = c3, .c1 = c4, .c2 = field.fq2_zero() },
    };

    const expected = fq12_mul(a, sparse);
    const actual = fq12_mul_by_034(a, c0, c3, c4);

    try std.testing.expect(fq12_eq(expected, actual));
}




test "g2_mul by 2" {
    const g2 = curve.g2_generator();
    const two_g2 = curve.g2_mul(g2, curve.FrElement{ 2, 0, 0, 0 });
    const expected = curve.g2_add(g2, g2);
    try std.testing.expect(curve.g2_eq(two_g2, expected));
}

test "pairing infinity" {
    const g1 = curve.g1_generator();
    const g2 = curve.g2_generator();
    
    // e(infinity, G2) = 1
    const inf_g1 = curve.g1_zero();
    const result1 = ate_pairing(inf_g1, g2);
    try std.testing.expect(fq12_eq(result1, fq12_one()));
    
    // e(G1, infinity) = 1
    const inf_g2 = curve.g2_zero();
    const result2 = ate_pairing(g1, inf_g2);
    try std.testing.expect(fq12_eq(result2, fq12_one()));
}

test "miller loop debug" {
    const p1 = curve.g1_generator();
    const p2 = curve.g2_generator();
    const p_affine = curve.g1_normalize(p1);
    const q_affine = curve.g2_normalize(p2);

    var r = G2HomProjective{
        .x = q_affine.x,
        .y = q_affine.y,
        .z = field.fq2_one(),
    };
    var f = fq12_one();

    const ate_loop_count = [_]i8{
        0, 0, 0, 1, 0, 1, 0, -1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, 0, -1, 0, 0, 0, 1, 0, -1, 0, 0, 0,
        0, -1, 0, 0, 1, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, -1, 0, 0, -1, 0, 1, 0, -1, 0, 0, 0, -1, 0,
        -1, 0, 0, 0, 1, 0, 1, 1,
    };

    const neg_q = curve.G2PointAffine{
        .x = q_affine.x,
        .y = field.fq2_neg(q_affine.y),
    };

    var i: usize = 64;
    while (i >= 1) : (i -= 1) {
        if (i != 64) {
            f = fq12_sqr(f);
        }

        const coeffs_dbl = g2_hom_dbl_with_line(&r, p_affine);
        const c0_dbl = field.fq2_mul(coeffs_dbl.c0, Fq2Element{ .a = p_affine.y, .b = field.fq_zero() });
        const c3_dbl = field.fq2_mul(coeffs_dbl.c3, Fq2Element{ .a = p_affine.x, .b = field.fq_zero() });
        f = fq12_mul_by_034(f, c0_dbl, c3_dbl, coeffs_dbl.c4);

        const bit = ate_loop_count[i - 1];
        if (bit == 1) {
            const coeffs_add = g2_hom_add_with_line(&r, q_affine, p_affine);
            const c0_add = field.fq2_mul(coeffs_add.c0, Fq2Element{ .a = p_affine.y, .b = field.fq_zero() });
            const c3_add = field.fq2_mul(coeffs_add.c3, Fq2Element{ .a = p_affine.x, .b = field.fq_zero() });
            f = fq12_mul_by_034(f, c0_add, c3_add, coeffs_add.c4);
        } else if (bit == -1) {
            const coeffs_sub = g2_hom_add_with_line(&r, neg_q, p_affine);
            const c0_sub = field.fq2_mul(coeffs_sub.c0, Fq2Element{ .a = p_affine.y, .b = field.fq_zero() });
            const c3_sub = field.fq2_mul(coeffs_sub.c3, Fq2Element{ .a = p_affine.x, .b = field.fq_zero() });
            f = fq12_mul_by_034(f, c0_sub, c3_sub, coeffs_sub.c4);
        }

        if (i == 64 or i == 63 or i == 62 or i <= 3) {
        }
    }

    const twist_mul_by_q_x = field.Fq2Element{
        .a = FqElement{ 0xb5773b104563ab30, 0x347f91c8a9aa6454, 0x7a007127242e0991, 0x1956bcd8118214ec },
        .b = FqElement{ 0x6e849f1ea0aa4757, 0xaa1c7b6d89f89141, 0xb6e713cdfae0ca3a, 0x26694fbb4e82ebc3 },
    };
    const twist_mul_by_q_y = field.Fq2Element{
        .a = FqElement{ 0xe4bbdd0c2936b629, 0xbb30f162e133bacb, 0x31a9d1b6f9645366, 0x253570bea500f8dd },
        .b = FqElement{ 0xa1d77ce45ffe77c7, 0x07affd117826d1db, 0x6d16bd27bb7edc6b, 0x2c87200285defecc },
    };

    const q1_fq2 = curve.G2PointAffine{
        .x = field.fq2_mul(
            field.Fq2Element{ .a = q_affine.x.a, .b = field.fq_neg(q_affine.x.b) },
            twist_mul_by_q_x,
        ),
        .y = field.fq2_mul(
            field.Fq2Element{ .a = q_affine.y.a, .b = field.fq_neg(q_affine.y.b) },
            twist_mul_by_q_y,
        ),
    };

    const q2_temp_fq2 = curve.G2PointAffine{
        .x = field.fq2_mul(
            field.Fq2Element{ .a = q1_fq2.x.a, .b = field.fq_neg(q1_fq2.x.b) },
            twist_mul_by_q_x,
        ),
        .y = field.fq2_mul(
            field.Fq2Element{ .a = q1_fq2.y.a, .b = field.fq_neg(q1_fq2.y.b) },
            twist_mul_by_q_y,
        ),
    };
    const q2_fq2 = curve.G2PointAffine{
        .x = q2_temp_fq2.x,
        .y = field.fq2_neg(q2_temp_fq2.y),
    };

    const coeffs1 = g2_hom_add_with_line(&r, q1_fq2, p_affine);
    const c0_1 = field.fq2_mul(coeffs1.c0, Fq2Element{ .a = p_affine.y, .b = field.fq_zero() });
    const c3_1 = field.fq2_mul(coeffs1.c3, Fq2Element{ .a = p_affine.x, .b = field.fq_zero() });
    f = fq12_mul_by_034(f, c0_1, c3_1, coeffs1.c4);

    const coeffs2 = g2_hom_add_with_line(&r, q2_fq2, p_affine);
    const c0_2 = field.fq2_mul(coeffs2.c0, Fq2Element{ .a = p_affine.y, .b = field.fq_zero() });
    const c3_2 = field.fq2_mul(coeffs2.c3, Fq2Element{ .a = p_affine.x, .b = field.fq_zero() });
    f = fq12_mul_by_034(f, c0_2, c3_2, coeffs2.c4);


    try std.testing.expect(!fq12_eq(f, fq12_zero()));
    try std.testing.expect(!fq12_eq(f, fq12_one()));

    const final_result = final_exponentiation(f);

    try std.testing.expect(!fq12_eq(final_result, fq12_zero()));
    try std.testing.expect(!fq12_eq(final_result, fq12_one()));
}

test "line coefficients debug" {
    const p1 = curve.g1_generator();
    const p2 = curve.g2_generator();
    const p_affine = curve.g1_normalize(p1);
    const q_affine = curve.g2_normalize(p2);

    var r = G2HomProjective{
        .x = q_affine.x,
        .y = q_affine.y,
        .z = field.fq2_one(),
    };

    // First doubling (i=64, no squaring)
    
    _ = g2_hom_dbl_with_line(&r, p_affine);

    // First addition (bit=1)
    _ = g2_hom_add_with_line(&r, q_affine, p_affine);

    // Second doubling (i=63, square first)
    _ = g2_hom_dbl_with_line(&r, p_affine);
}

test "raw coefficient comparison" {
    const p1 = curve.g1_generator();
    const p2 = curve.g2_generator();
    const p_affine = curve.g1_normalize(p1);
    const q_affine = curve.g2_normalize(p2);

    var r = G2HomProjective{
        .x = q_affine.x,
        .y = q_affine.y,
        .z = field.fq2_one(),
    };

    const coeffs_dbl = g2_hom_dbl_with_line(&r, p_affine);

    // Now apply to f=1 and compare with expected
    const f = fq12_one();
    const result = fq12_mul_by_034(f, coeffs_dbl.c0, coeffs_dbl.c3, coeffs_dbl.c4);

    // Also compute using full multiplication for comparison
    const sparse = Fq12Element{
        .c0 = .{ .c0 = coeffs_dbl.c0, .c1 = field.fq2_zero(), .c2 = field.fq2_zero() },
        .c1 = .{ .c0 = coeffs_dbl.c3, .c1 = coeffs_dbl.c4, .c2 = field.fq2_zero() },
    };
    const full_result = fq12_mul(f, sparse);

    try std.testing.expect(fq12_eq(result, full_result));
}

test "fq12_pow p_sq" {
    const base = fq12_from_u64(3);
    const pow_result = fq12_pow(base, &p_sq_words);
    // 3 is in Fp, so 3^(p^2) = 3
    try std.testing.expect(fq12_eq(pow_result, base));
}

test "fq12_pow identity" {
    const one = fq12_one();
    const result = fq12_pow(one, &final_exp_words);
    try std.testing.expect(fq12_eq(result, one));
}

test "final exponentiation subgroup" {
    // For any f, final_exponentiation(f) should have order dividing n
    const f = fq12_from_u64(2);
    const f_final = final_exponentiation(f);
    const f_final_to_n = fq12_pow(f_final, &fr_q_be_words);
    try std.testing.expect(fq12_eq(f_final_to_n, fq12_one()));
}

test "pairing generator" {
    const p1 = curve.g1_generator();
    const p2 = curve.g2_generator();

    _ = miller_loop(p1, p2);

    const result = ate_pairing(p1, p2);

    // Check result is in the subgroup of order n
    const result_to_n = fq12_pow(result, &fr_q_be_words);
    try std.testing.expect(fq12_eq(result_to_n, fq12_one()));

    // Bilinearity test: e(2*G2, G1) should equal e(G2, G1)^2
    const two_p2 = curve.g2_mul(p2, curve.FrElement{ 2, 0, 0, 0 });
    const result_2g2 = ate_pairing(p1, two_p2);

    const result_sq = fq12_sqr(result);

    try std.testing.expect(fq12_eq(result_2g2, result_sq));
}

test "fq12 repeated squaring" {
    // Test fq12_sqr chain: base^(2^100) via repeated squaring vs fq12_pow
    const base = fq12_from_u64(3);
    var expected = base;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        expected = fq12_sqr(expected);
    }

    // Exponent 2^100: bit 100 is 1. In big-endian words: word0=0, word1=1<<36, word2=0
    const exp_words = [_]u64{ 0, 0x1000000000, 0 };
    const result = fq12_pow(base, &exp_words);

    try std.testing.expect(fq12_eq(result, expected));
}


