const std = @import("std");
const field = @import("field.zig");
const parser = @import("parser.zig");
const msm = @import("msm.zig");

// ============================================================================
// G1 Curve (BN254 over Fq, projective xyzz coordinates)
// ============================================================================

pub const FqElement = field.FqElement;
pub const Fq2Element = field.Fq2Element;
pub const FrElement = field.FrElement;

pub const G1Point = struct {
    x: FqElement,
    y: FqElement,
    zz: FqElement,
    zzz: FqElement,
};

pub const G1PointAffine = struct {
    x: FqElement,
    y: FqElement,
};

pub fn g1_zero() G1Point {
    return .{
        .x = field.fq_one(),
        .y = field.fq_one(),
        .zz = field.fq_zero(),
        .zzz = field.fq_zero(),
    };
}

pub fn g1_is_zero(p: G1Point) bool {
    return field.fq_is_zero(p.zz);
}

pub fn g1_eq(a: G1Point, b: G1Point) bool {
    if (g1_is_zero(a) and g1_is_zero(b)) return true;
    if (g1_is_zero(a) or g1_is_zero(b)) return false;

    const lhs_x = field.fq_mul(a.x, b.zz);
    const rhs_x = field.fq_mul(b.x, a.zz);
    const lhs_y = field.fq_mul(a.y, b.zzz);
    const rhs_y = field.fq_mul(b.y, a.zzz);

    return field.fq_eq(lhs_x, rhs_x) and field.fq_eq(lhs_y, rhs_y);
}

pub fn g1_normalize(p: G1Point) G1PointAffine {
    if (g1_is_zero(p)) return .{ .x = field.fq_zero(), .y = field.fq_zero() };
    const zz_inv = field.fq_inv(p.zz);
    const zzz_inv = field.fq_inv(p.zzz);
    return .{
        .x = field.fq_mul(p.x, zz_inv),
        .y = field.fq_mul(p.y, zzz_inv),
    };
}

pub fn g1_affine_to_projective(affine: G1PointAffine) G1Point {
    if (field.fq_is_zero(affine.x) and field.fq_is_zero(affine.y)) return g1_zero();
    return .{
        .x = affine.x,
        .y = affine.y,
        .zz = field.fq_one(),
        .zzz = field.fq_one(),
    };
}

pub fn g1_add(a: G1Point, b: G1Point) G1Point {
    if (g1_is_zero(a)) return b;
    if (g1_is_zero(b)) return a;

    const U1 = field.fq_mul(a.x, b.zz);
    const U2 = field.fq_mul(b.x, a.zz);
    const S1 = field.fq_mul(a.y, b.zzz);
    const S2 = field.fq_mul(b.y, a.zzz);

    const P = field.fq_sub(U2, U1);
    const R = field.fq_sub(S2, S1);

    if (field.fq_is_zero(P) and field.fq_is_zero(R)) {
        return g1_dbl(a);
    }

    const PP = field.fq_sqr(P);
    const PPP = field.fq_mul(P, PP);
    const Q = field.fq_mul(U1, PP);

    const R2 = field.fq_sqr(R);
    const t1 = field.fq_sub(R2, PPP);
    const t2 = field.fq_sub(t1, Q);
    const x3 = field.fq_sub(t2, Q);

    const QmX3 = field.fq_sub(Q, x3);
    const R_QmX3 = field.fq_mul(R, QmX3);
    const S1_PPP = field.fq_mul(S1, PPP);
    const y3 = field.fq_sub(R_QmX3, S1_PPP);

    const ZZ1_ZZ2 = field.fq_mul(a.zz, b.zz);
    const zz3 = field.fq_mul(ZZ1_ZZ2, PP);

    const ZZZ1_ZZZ2 = field.fq_mul(a.zzz, b.zzz);
    const zzz3 = field.fq_mul(ZZZ1_ZZZ2, PPP);

    return .{
        .x = x3,
        .y = y3,
        .zz = zz3,
        .zzz = zzz3,
    };
}

pub fn g1_add_affine(p: G1Point, affine: G1PointAffine) G1Point {
    if (g1_is_zero(p)) return g1_affine_to_projective(affine);

    const U1 = p.x;
    const U2 = field.fq_mul(affine.x, p.zz);
    const S1 = p.y;
    const S2 = field.fq_mul(affine.y, p.zzz);

    const P = field.fq_sub(U2, U1);
    const R = field.fq_sub(S2, S1);

    if (field.fq_is_zero(P) and field.fq_is_zero(R)) {
        return g1_dbl(p);
    }

    const PP = field.fq_sqr(P);
    const PPP = field.fq_mul(P, PP);
    const Q = field.fq_mul(U1, PP);

    const R2 = field.fq_sqr(R);
    const t1 = field.fq_sub(R2, PPP);
    const t2 = field.fq_sub(t1, Q);
    const x3 = field.fq_sub(t2, Q);

    const QmX3 = field.fq_sub(Q, x3);
    const R_QmX3 = field.fq_mul(R, QmX3);
    const S1_PPP = field.fq_mul(S1, PPP);
    const y3 = field.fq_sub(R_QmX3, S1_PPP);

    const zz3 = field.fq_mul(p.zz, PP);
    const zzz3 = field.fq_mul(p.zzz, PPP);

    return .{
        .x = x3,
        .y = y3,
        .zz = zz3,
        .zzz = zzz3,
    };
}

pub fn g1_dbl(p: G1Point) G1Point {
    if (g1_is_zero(p)) return p;

    const U = field.fq_add(p.y, p.y);
    const V = field.fq_sqr(U);
    const W = field.fq_mul(U, V);
    const S = field.fq_mul(p.x, V);

    const M = field.fq_sqr(p.x);
    const M2 = field.fq_add(M, M);
    const M3 = field.fq_add(M, M2);

    const M_sq = field.fq_sqr(M3);
    const x3_1 = field.fq_sub(M_sq, S);
    const x3 = field.fq_sub(x3_1, S);

    const SmX3 = field.fq_sub(S, x3);
    const M_SmX3 = field.fq_mul(M3, SmX3);
    const W_Y1 = field.fq_mul(W, p.y);
    const y3 = field.fq_sub(M_SmX3, W_Y1);

    const zz3 = field.fq_mul(V, p.zz);
    const zzz3 = field.fq_mul(W, p.zzz);

    return .{
        .x = x3,
        .y = y3,
        .zz = zz3,
        .zzz = zzz3,
    };
}

pub fn g1_neg(p: G1Point) G1Point {
    return .{
        .x = p.x,
        .y = field.fq_neg(p.y),
        .zz = p.zz,
        .zzz = p.zzz,
    };
}

pub fn g1_mul(base: G1Point, scalar: FrElement) G1Point {
    var result = g1_zero();
    var found_first = false;

    for (0..4) |word_idx| {
        const word = scalar[3 - word_idx];
        var bit_mask: u64 = 1 << 63;
        while (bit_mask != 0) : (bit_mask >>= 1) {
            if (found_first) {
                result = g1_dbl(result);
            }
            if ((word & bit_mask) != 0) {
                if (!found_first) {
                    result = base;
                    found_first = true;
                } else {
                    result = g1_add(result, base);
                }
            }
        }
    }

    return result;
}

pub fn g1_mul_affine(base: G1PointAffine, scalar: FrElement) G1Point {
    const proj = g1_affine_to_projective(base);
    return g1_mul(proj, scalar);
}

pub fn g1_generator() G1Point {
    const x = field.fq_one();
    const y = field.fq_add(field.fq_one(), field.fq_one());
    return .{
        .x = x,
        .y = y,
        .zz = field.fq_one(),
        .zzz = field.fq_one(),
    };
}

// ============================================================================
// G2 Curve (BN254 over Fq2, projective xyzz coordinates)
// ============================================================================

pub const G2Point = struct {
    x: Fq2Element,
    y: Fq2Element,
    zz: Fq2Element,
    zzz: Fq2Element,
};

pub const G2PointAffine = struct {
    x: Fq2Element,
    y: Fq2Element,
};

pub fn g2_zero() G2Point {
    return .{
        .x = .{ .a = field.fq_one(), .b = field.fq_zero() },
        .y = .{ .a = field.fq_one(), .b = field.fq_zero() },
        .zz = .{ .a = field.fq_zero(), .b = field.fq_zero() },
        .zzz = .{ .a = field.fq_zero(), .b = field.fq_zero() },
    };
}

pub fn g2_is_zero(p: G2Point) bool {
    return field.fq2_is_zero(p.zz);
}

pub fn g2_eq(a: G2Point, b: G2Point) bool {
    if (g2_is_zero(a) and g2_is_zero(b)) return true;
    if (g2_is_zero(a) or g2_is_zero(b)) return false;

    const lhs_x = field.fq2_mul(a.x, b.zz);
    const rhs_x = field.fq2_mul(b.x, a.zz);
    const lhs_y = field.fq2_mul(a.y, b.zzz);
    const rhs_y = field.fq2_mul(b.y, a.zzz);

    return field.fq2_eq(lhs_x, rhs_x) and field.fq2_eq(lhs_y, rhs_y);
}

pub fn g2_normalize(p: G2Point) G2PointAffine {
    if (g2_is_zero(p)) return .{ .x = field.fq2_zero(), .y = field.fq2_zero() };
    const zz_inv = field.fq2_inv(p.zz);
    const zzz_inv = field.fq2_inv(p.zzz);
    return .{
        .x = field.fq2_mul(p.x, zz_inv),
        .y = field.fq2_mul(p.y, zzz_inv),
    };
}

pub fn g2_affine_to_projective(affine: G2PointAffine) G2Point {
    if (field.fq2_is_zero(affine.x) and field.fq2_is_zero(affine.y)) return g2_zero();
    return .{
        .x = affine.x,
        .y = affine.y,
        .zz = .{ .a = field.fq_one(), .b = field.fq_zero() },
        .zzz = .{ .a = field.fq_one(), .b = field.fq_zero() },
    };
}

pub fn g2_add(a: G2Point, b: G2Point) G2Point {
    if (g2_is_zero(a)) return b;
    if (g2_is_zero(b)) return a;

    const U1 = field.fq2_mul(a.x, b.zz);
    const U2 = field.fq2_mul(b.x, a.zz);
    const S1 = field.fq2_mul(a.y, b.zzz);
    const S2 = field.fq2_mul(b.y, a.zzz);

    const P = field.fq2_sub(U2, U1);
    const R = field.fq2_sub(S2, S1);

    if (field.fq2_is_zero(P) and field.fq2_is_zero(R)) {
        return g2_dbl(a);
    }

    const PP = field.fq2_sqr(P);
    const PPP = field.fq2_mul(P, PP);
    const Q = field.fq2_mul(U1, PP);

    const R2 = field.fq2_sqr(R);
    const t1 = field.fq2_sub(R2, PPP);
    const t2 = field.fq2_sub(t1, Q);
    const x3 = field.fq2_sub(t2, Q);

    const QmX3 = field.fq2_sub(Q, x3);
    const R_QmX3 = field.fq2_mul(R, QmX3);
    const S1_PPP = field.fq2_mul(S1, PPP);
    const y3 = field.fq2_sub(R_QmX3, S1_PPP);

    const ZZ1_ZZ2 = field.fq2_mul(a.zz, b.zz);
    const zz3 = field.fq2_mul(ZZ1_ZZ2, PP);

    const ZZZ1_ZZZ2 = field.fq2_mul(a.zzz, b.zzz);
    const zzz3 = field.fq2_mul(ZZZ1_ZZZ2, PPP);

    return .{
        .x = x3,
        .y = y3,
        .zz = zz3,
        .zzz = zzz3,
    };
}

pub fn g2_dbl(p: G2Point) G2Point {
    if (g2_is_zero(p)) return p;

    const U = field.fq2_add(p.y, p.y);
    const V = field.fq2_sqr(U);
    const W = field.fq2_mul(U, V);
    const S = field.fq2_mul(p.x, V);

    const M = field.fq2_sqr(p.x);
    const M2 = field.fq2_add(M, M);
    const M3 = field.fq2_add(M, M2);

    const M_sq = field.fq2_sqr(M3);
    const x3_1 = field.fq2_sub(M_sq, S);
    const x3 = field.fq2_sub(x3_1, S);

    const SmX3 = field.fq2_sub(S, x3);
    const M_SmX3 = field.fq2_mul(M3, SmX3);
    const W_Y1 = field.fq2_mul(W, p.y);
    const y3 = field.fq2_sub(M_SmX3, W_Y1);

    const zz3 = field.fq2_mul(V, p.zz);
    const zzz3 = field.fq2_mul(W, p.zzz);

    return .{
        .x = x3,
        .y = y3,
        .zz = zz3,
        .zzz = zzz3,
    };
}

pub fn g2_neg(p: G2Point) G2Point {
    return .{
        .x = p.x,
        .y = field.fq2_neg(p.y),
        .zz = p.zz,
        .zzz = p.zzz,
    };
}

pub fn g2_mul(base: G2Point, scalar: FrElement) G2Point {
    var result = g2_zero();
    var found_first = false;

    for (0..4) |word_idx| {
        const word = scalar[3 - word_idx];
        var bit_mask: u64 = 1 << 63;
        while (bit_mask != 0) : (bit_mask >>= 1) {
            if (found_first) {
                result = g2_dbl(result);
            }
            if ((word & bit_mask) != 0) {
                if (!found_first) {
                    result = base;
                    found_first = true;
                } else {
                    result = g2_add(result, base);
                }
            }
        }
    }

    return result;
}

pub fn g2_generator() G2Point {
    // BN254 G2 generator in Montgomery form (matches ark-bn254)
    const g2_xa = FqElement{ 0x8e83b5d102bc2026, 0xdceb1935497b0172, 0xfbb8264797811adf, 0x19573841af96503b };
    const g2_xb = FqElement{ 0xafb4737da84c6140, 0x6043dd5a5802d8c4, 0x09e950fc52a02f86, 0x14fef0833aea7b6b };
    const g2_ya = FqElement{ 0x619dfa9d886be9f6, 0xfe7fd297f59e9b78, 0xff9e1a62231b7dfe, 0x28fd7eebae9e4206 };
    const g2_yb = FqElement{ 0x64095b56c71856ee, 0xdc57f922327d3cbb, 0x55f935be33351076, 0x0da4a0e693fd6482 };

    return .{
        .x = .{ .a = g2_xa, .b = g2_xb },
        .y = .{ .a = g2_ya, .b = g2_yb },
        .zz = .{ .a = field.fq_one(), .b = field.fq_zero() },
        .zzz = .{ .a = field.fq_one(), .b = field.fq_zero() },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "g1_add" {
    const pt0 = G1PointAffine{ .x = field.fq_one(), .y = field.fq_add(field.fq_one(), field.fq_one()) };
    const pt0_proj = g1_affine_to_projective(pt0);
    const result = g1_add(pt0_proj, pt0_proj);
    const dbl = g1_dbl(pt0_proj);
    try std.testing.expect(g1_eq(result, dbl));
}

test "g1_dbl equals g1_add same point" {
    const g = g1_generator();
    const two_g = g1_dbl(g);
    const manual = g1_add(g, g);
    try std.testing.expect(g1_eq(two_g, manual));
}

test "g1_affine_to_projective_infinity" {
    const affine = G1PointAffine{ .x = field.fq_zero(), .y = field.fq_zero() };
    const proj = g1_affine_to_projective(affine);
    try std.testing.expect(g1_is_zero(proj));
}

test "g1_mul" {
    const g = g1_generator();
    const scalar = field.fr_from_u64(3);
    const three_g = g1_mul(g, scalar);
    const two_g = g1_dbl(g);
    const manual = g1_add(two_g, g);
    
    
    try std.testing.expect(g1_eq(three_g, manual));
}

test "g1_add_affine" {
    const g = g1_generator();
    const two_g = g1_dbl(g);
    const g_affine = G1PointAffine{ .x = g.x, .y = g.y };
    const two_g_affine = g1_add_affine(g, g_affine);
    try std.testing.expect(g1_eq(two_g, two_g_affine));
}

test "g2_add" {
    const g = g2_generator();
    const two_g = g2_add(g, g);
    const dbl_g = g2_dbl(g);
    try std.testing.expect(g2_eq(two_g, dbl_g));
}

test "g2_mul" {
    const g = g2_generator();
    const scalar = field.fr_from_u64(3);
    const three_g = g2_mul(g, scalar);
    const two_g = g2_dbl(g);
    const manual = g2_add(two_g, g);
    try std.testing.expect(g2_eq(three_g, manual));
}

// Debug: Compare G2 multiplication with Python py_ecc for zkey point 2


// Compare G2 MSM with Python for first 10 points

// Compare G1 MSM with Python for first 50 points































test "g2_affine_to_projective_infinity" {
    const affine = G2PointAffine{ .x = field.fq2_zero(), .y = field.fq2_zero() };
    const proj = g2_affine_to_projective(affine);
    try std.testing.expect(g2_is_zero(proj));
}

