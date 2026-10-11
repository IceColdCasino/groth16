const std = @import("std");
const field = @import("cpu").field;
const curve = @import("cpu").curve;
const msm = @import("cpu").msm;
const rs = @import("rapidsnark_test_api");

// ============================================================================
// TDD G1 MSM Tests — compare our Zig CPU MSM against rapidsnark
// ============================================================================

fn normG1(p: curve.G1Point) curve.G1PointAffine {
    const n = curve.g1_normalize(p);
    return .{ .x = n.x, .y = n.y };
}

test "TDD: msm_g1 2 points matches rapidsnark" {
    // Two points: G and 2G
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const g2 = curve.g1_mul(g, field.fr_toMont(field.fr_from_u64(2)));
    const g2_affine = normG1(g2);

    const points = &[_]curve.G1PointAffine{ g_affine, g2_affine };

    // Scalars: 1 and 1 → result should be G + 2G = 3G
    const s1 = field.fr_toMont(field.fr_from_u64(1));
    const scalars = &[_]field.FrElement{ s1, s1 };

    // Expected via rapidsnark MSM
    var expected: curve.G1Point = undefined;
    rs.msmG1Rapidsnark(std.testing.allocator, points, scalars, &expected);

    // Actual via our Zig CPU MSM (Pippenger, matches rapidsnark algorithm)
    const actual = try msm.msm_g1_pippenger(std.testing.allocator, points, scalars);

    try std.testing.expect(curve.g1_eq(expected, actual));
}

test "TDD: msm_g1 3 points (1G, 2G, 3G) with scalars (1,1,1) matches rapidsnark" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const two = field.fr_toMont(field.fr_from_u64(2));
    const three = field.fr_toMont(field.fr_from_u64(3));
    const g2 = curve.g1_mul(g, two);
    const g2_affine = normG1(g2);
    const g3 = curve.g1_mul(g, three);
    const g3_affine = normG1(g3);

    const points = &[_]curve.G1PointAffine{ g_affine, g2_affine, g3_affine };
    const s1 = field.fr_toMont(field.fr_from_u64(1));
    const scalars = &[_]field.FrElement{ s1, s1, s1 };

    var expected: curve.G1Point = undefined;
    rs.msmG1Rapidsnark(std.testing.allocator, points, scalars, &expected);

    const actual = try msm.msm_g1_pippenger(std.testing.allocator, points, scalars);

    try std.testing.expect(curve.g1_eq(expected, actual));
}

test "TDD: msm_g1 with non-trivial scalars matches rapidsnark" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const g2 = curve.g1_mul(g, field.fr_toMont(field.fr_from_u64(2)));
    const g2_affine = normG1(g2);

    const points = &[_]curve.G1PointAffine{ g_affine, g2_affine };

    // Scalars: 3 and 5 → result = 3*G + 5*2G = 3G + 10G = 13G
    const s3 = field.fr_toMont(field.fr_from_u64(3));
    const s5 = field.fr_toMont(field.fr_from_u64(5));
    const scalars = &[_]field.FrElement{ s3, s5 };

    var expected: curve.G1Point = undefined;
    rs.msmG1Rapidsnark(std.testing.allocator, points, scalars, &expected);

    const actual = try msm.msm_g1_pippenger(std.testing.allocator, points, scalars);

    try std.testing.expect(curve.g1_eq(expected, actual));
}

test "TDD: msm_g1 with zero scalar matches rapidsnark" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };

    const points = &[_]curve.G1PointAffine{ g_affine };
    const s0 = field.fr_toMont(field.fr_from_u64(0));
    const scalars = &[_]field.FrElement{ s0 };

    var expected: curve.G1Point = undefined;
    rs.msmG1Rapidsnark(std.testing.allocator, points, scalars, &expected);

    const actual = try msm.msm_g1_pippenger(std.testing.allocator, points, scalars);

    try std.testing.expect(curve.g1_eq(expected, actual));
}

test "TDD: msm_g1 with large scalars matches rapidsnark" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const g2 = curve.g1_mul(g, field.fr_toMont(field.fr_from_u64(2)));
    const g2_affine = normG1(g2);

    const points = &[_]curve.G1PointAffine{ g_affine, g2_affine };

    const s_large_1 = field.fr_toMont(field.FrElement{ 0xdeadbeefcafebabe, 0x123456789abcdef0, 0xfedcba0987654321, 0x0a0b0c0d0e0f0102 });
    const s_large_2 = field.fr_toMont(field.FrElement{ 0xbeefdeadabecafeb, 0x0fedcba987654321, 0x123456789abcdef0, 0x02010f0e0d0c0b0a });
    const scalars = &[_]field.FrElement{ s_large_1, s_large_2 };

    var expected: curve.G1Point = undefined;
    rs.msmG1Rapidsnark(std.testing.allocator, points, scalars, &expected);

    const actual = try msm.msm_g1_pippenger(std.testing.allocator, points, scalars);

    try std.testing.expect(curve.g1_eq(expected, actual));
}
