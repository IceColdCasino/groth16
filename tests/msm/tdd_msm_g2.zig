const std = @import("std");
const field = @import("cpu").field;
const curve = @import("cpu").curve;
const msm = @import("cpu").msm;

fn normG2(p: curve.G2Point) curve.G2PointAffine {
    const n = curve.g2_normalize(p);
    return .{ .x = n.x, .y = n.y };
}

fn sc(v: u64) field.FrElement {
    return field.fr_from_u64(v);
}

test "TDD: msm_g2 2 points" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const g2_2 = curve.g2_mul(g2, sc(2));
    const points = &[_]curve.G2PointAffine{ g2_affine, normG2(g2_2) };
    const scalars = &[_]field.FrElement{ sc(1), sc(1) };

    const actual = msm.msm_g2_small(points, scalars);
    try std.testing.expect(curve.g2_eq(actual, curve.g2_mul(g2, sc(3))));
}

test "TDD: msm_g2 3 points with scalars (1,1,1)" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const g2_2 = curve.g2_mul(g2, sc(2));
    const g2_3 = curve.g2_mul(g2, sc(3));
    const points = &[_]curve.G2PointAffine{ g2_affine, normG2(g2_2), normG2(g2_3) };
    const scalars = &[_]field.FrElement{ sc(1), sc(1), sc(1) };

    const actual = msm.msm_g2_small(points, scalars);
    try std.testing.expect(curve.g2_eq(actual, curve.g2_mul(g2, sc(6))));
}

test "TDD: msm_g2 with non-trivial scalars" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const g2_2 = curve.g2_mul(g2, sc(2));
    const points = &[_]curve.G2PointAffine{ g2_affine, normG2(g2_2) };
    const scalars = &[_]field.FrElement{ sc(3), sc(5) };

    const actual = msm.msm_g2_small(points, scalars);
    try std.testing.expect(curve.g2_eq(actual, curve.g2_mul(g2, sc(13))));
}

test "TDD: msm_g2 with zero scalar" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const points = &[_]curve.G2PointAffine{g2_affine};
    const scalars = &[_]field.FrElement{sc(0)};

    const actual = msm.msm_g2_small(points, scalars);
    try std.testing.expect(curve.g2_is_zero(actual));
}

test "TDD: msm_g2 with large scalars" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const g2_2 = curve.g2_mul(g2, sc(2));
    const points = &[_]curve.G2PointAffine{ g2_affine, normG2(g2_2) };

    const s1 = field.FrElement{ 0xdeadbeefcafebabe, 0x123456789abcdef0, 0xfedcba0987654321, 0x0a0b0c0d0e0f0102 };
    const s2 = field.FrElement{ 0xbeefdeadabecafeb, 0x0fedcba987654321, 0x123456789abcdef0, 0x02010f0e0d0c0b0a };
    const scalars = &[_]field.FrElement{ s1, s2 };

    const actual = msm.msm_g2_small(points, scalars);
    const expected = curve.g2_add(curve.g2_mul(g2, s1), curve.g2_mul(g2_2, s2));
    try std.testing.expect(curve.g2_eq(actual, expected));
}
