const std = @import("std");
const field = @import("cpu").field;
const curve = @import("cpu").curve;
const msm = @import("cpu").msm;

fn normG1(p: curve.G1Point) curve.G1PointAffine {
    const n = curve.g1_normalize(p);
    return .{ .x = n.x, .y = n.y };
}

fn sc(v: u64) field.FrElement {
    return field.fr_from_u64(v);
}

test "TDD: msm_g1 2 points" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const g2 = curve.g1_mul(g, sc(2));
    const points = &[_]curve.G1PointAffine{ g_affine, normG1(g2) };
    const scalars = &[_]field.FrElement{ sc(1), sc(1) };

    const actual = try msm.msm_g1_pippenger(std.testing.allocator, points, scalars);
    try std.testing.expect(curve.g1_eq(actual, curve.g1_mul(g, sc(3))));
}

test "TDD: msm_g1 3 points (1G, 2G, 3G) with scalars (1,1,1)" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const g2 = curve.g1_mul(g, sc(2));
    const g3 = curve.g1_mul(g, sc(3));
    const points = &[_]curve.G1PointAffine{ g_affine, normG1(g2), normG1(g3) };
    const scalars = &[_]field.FrElement{ sc(1), sc(1), sc(1) };

    const actual = try msm.msm_g1_pippenger(std.testing.allocator, points, scalars);
    try std.testing.expect(curve.g1_eq(actual, curve.g1_mul(g, sc(6))));
}

test "TDD: msm_g1 with non-trivial scalars" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const g2 = curve.g1_mul(g, sc(2));
    const points = &[_]curve.G1PointAffine{ g_affine, normG1(g2) };
    const scalars = &[_]field.FrElement{ sc(3), sc(5) };

    const actual = try msm.msm_g1_pippenger(std.testing.allocator, points, scalars);
    try std.testing.expect(curve.g1_eq(actual, curve.g1_mul(g, sc(13))));
}

test "TDD: msm_g1 with zero scalar" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const points = &[_]curve.G1PointAffine{g_affine};
    const scalars = &[_]field.FrElement{sc(0)};

    const actual = try msm.msm_g1_pippenger(std.testing.allocator, points, scalars);
    try std.testing.expect(curve.g1_is_zero(actual));
}

test "TDD: msm_g1 with large scalars" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const g2 = curve.g1_mul(g, sc(2));
    const points = &[_]curve.G1PointAffine{ g_affine, normG1(g2) };

    const s1 = field.FrElement{ 0xdeadbeefcafebabe, 0x123456789abcdef0, 0xfedcba0987654321, 0x0a0b0c0d0e0f0102 };
    const s2 = field.FrElement{ 0xbeefdeadabecafeb, 0x0fedcba987654321, 0x123456789abcdef0, 0x02010f0e0d0c0b0a };
    const scalars = &[_]field.FrElement{ s1, s2 };

    const actual = try msm.msm_g1_pippenger(std.testing.allocator, points, scalars);
    const expected = curve.g1_add(curve.g1_mul(g, s1), curve.g1_mul(g2, s2));
    try std.testing.expect(curve.g1_eq(actual, expected));
}
