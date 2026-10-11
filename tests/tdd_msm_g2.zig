const std = @import("std");
const field = @import("cpu").field;
const curve = @import("cpu").curve;
const msm = @import("cpu").msm;
const rs = @import("rapidsnark_test_api");

// ============================================================================
// TDD G2 MSM Tests — compare our Zig CPU G2 MSM against rapidsnark
// ============================================================================

fn normG2(p: curve.G2Point) curve.G2PointAffine {
    const n = curve.g2_normalize(p);
    return .{ .x = n.x, .y = n.y };
}

test "TDD: msm_g2 2 points matches rapidsnark" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const g2_2 = curve.g2_mul(g2, field.fr_toMont(field.fr_from_u64(2)));
    const g2_2_affine = normG2(g2_2);

    const points = &[_]curve.G2PointAffine{ g2_affine, g2_2_affine };

    const s1 = field.fr_toMont(field.fr_from_u64(1));
    const scalars = &[_]field.FrElement{ s1, s1 };

    var expected: curve.G2Point = undefined;
    rs.msmG2Rapidsnark(std.testing.allocator, points, scalars, &expected);

    const actual = msm.msm_g2_small(points, scalars);

    try std.testing.expect(curve.g2_eq(expected, actual));
}

test "TDD: msm_g2 3 points with scalars (1,1,1) matches rapidsnark" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const two = field.fr_toMont(field.fr_from_u64(2));
    const three = field.fr_toMont(field.fr_from_u64(3));
    const g2_2 = curve.g2_mul(g2, two);
    const g2_2_affine = normG2(g2_2);
    const g2_3 = curve.g2_mul(g2, three);
    const g2_3_affine = normG2(g2_3);

    const points = &[_]curve.G2PointAffine{ g2_affine, g2_2_affine, g2_3_affine };
    const s1 = field.fr_toMont(field.fr_from_u64(1));
    const scalars = &[_]field.FrElement{ s1, s1, s1 };

    var expected: curve.G2Point = undefined;
    rs.msmG2Rapidsnark(std.testing.allocator, points, scalars, &expected);

    const actual = msm.msm_g2_small(points, scalars);

    try std.testing.expect(curve.g2_eq(expected, actual));
}

test "TDD: msm_g2 with non-trivial scalars matches rapidsnark" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const g2_2 = curve.g2_mul(g2, field.fr_toMont(field.fr_from_u64(2)));
    const g2_2_affine = normG2(g2_2);

    const points = &[_]curve.G2PointAffine{ g2_affine, g2_2_affine };

    const s3 = field.fr_toMont(field.fr_from_u64(3));
    const s5 = field.fr_toMont(field.fr_from_u64(5));
    const scalars = &[_]field.FrElement{ s3, s5 };

    var expected: curve.G2Point = undefined;
    rs.msmG2Rapidsnark(std.testing.allocator, points, scalars, &expected);

    const actual = msm.msm_g2_small(points, scalars);

    try std.testing.expect(curve.g2_eq(expected, actual));
}

test "TDD: msm_g2 with zero scalar matches rapidsnark" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };

    const points = &[_]curve.G2PointAffine{ g2_affine };
    const s0 = field.fr_toMont(field.fr_from_u64(0));
    const scalars = &[_]field.FrElement{ s0 };

    var expected: curve.G2Point = undefined;
    rs.msmG2Rapidsnark(std.testing.allocator, points, scalars, &expected);

    const actual = msm.msm_g2_small(points, scalars);

    try std.testing.expect(curve.g2_eq(expected, actual));
}

test "TDD: msm_g2 with large scalars matches rapidsnark" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const g2_2 = curve.g2_mul(g2, field.fr_toMont(field.fr_from_u64(2)));
    const g2_2_affine = normG2(g2_2);

    const points = &[_]curve.G2PointAffine{ g2_affine, g2_2_affine };

    const s_large_1 = field.fr_toMont(field.FrElement{ 0xdeadbeefcafebabe, 0x123456789abcdef0, 0xfedcba0987654321, 0x0a0b0c0d0e0f0102 });
    const s_large_2 = field.fr_toMont(field.FrElement{ 0xbeefdeadabecafeb, 0x0fedcba987654321, 0x123456789abcdef0, 0x02010f0e0d0c0b0a });
    const scalars = &[_]field.FrElement{ s_large_1, s_large_2 };

    var expected: curve.G2Point = undefined;
    rs.msmG2Rapidsnark(std.testing.allocator, points, scalars, &expected);

    const actual = msm.msm_g2_small(points, scalars);

    try std.testing.expect(curve.g2_eq(expected, actual));
}
