const std = @import("std");
const field = @import("cpu").field;
const curve = @import("cpu").curve;
const rs = @import("rapidsnark_test_api");

// ============================================================================
// TDD G2 Curve Tests — compare our Zig implementation against rapidsnark
// ============================================================================

test "TDD: g2_mul(2*G2) matches rapidsnark" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const scalar = field.fr_toMont(field.fr_from_u64(2));

    const expected = rs.g2MulRapidsnark(g2_affine, scalar);
    const actual = curve.g2_mul(g2, scalar);

    try std.testing.expect(curve.g2_eq(expected, actual));
}

test "TDD: g2_add(G2, G2) matches rapidsnark (equals 2G2)" {
    const g2 = curve.g2_generator();

    const expected = rs.g2AddRapidsnark(g2, g2);
    const actual = curve.g2_add(g2, g2);

    try std.testing.expect(curve.g2_eq(expected, actual));
}

test "TDD: g2_dbl(G2) matches rapidsnark (equals 2G2)" {
    const g2 = curve.g2_generator();

    const expected = rs.g2DblRapidsnark(g2);
    const actual = curve.g2_dbl(g2);

    try std.testing.expect(curve.g2_eq(expected, actual));
}

test "TDD: g2_mul with large scalar matches rapidsnark" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const scalar = field.FrElement{ 0xdeadbeefcafebabe, 0x123456789abcdef0, 0xfedcba0987654321, 0x0a0b0c0d0e0f0102 };
    const scalar_mont = field.fr_toMont(scalar);

    const expected = rs.g2MulRapidsnark(g2_affine, scalar_mont);
    const actual = curve.g2_mul(g2, scalar_mont);

    try std.testing.expect(curve.g2_eq(expected, actual));
}

test "TDD: g2_add(G2, 2G2) matches rapidsnark (equals 3G2)" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const two = field.fr_toMont(field.fr_from_u64(2));

    const g2_2_rs = rs.g2MulRapidsnark(g2_affine, two);
    const expected = rs.g2AddRapidsnark(g2, g2_2_rs);

    const g2_2 = curve.g2_mul(g2, two);
    const actual = curve.g2_add(g2, g2_2);

    try std.testing.expect(curve.g2_eq(expected, actual));
}

test "TDD: g2_add of two distinct points matches rapidsnark" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };

    const s1 = field.fr_toMont(field.fr_from_u64(3));
    const s2 = field.fr_toMont(field.fr_from_u64(5));

    const p1 = rs.g2MulRapidsnark(g2_affine, s1);
    const p2 = rs.g2MulRapidsnark(g2_affine, s2);

    const expected = rs.g2AddRapidsnark(p1, p2);
    const actual = curve.g2_add(p1, p2);

    try std.testing.expect(curve.g2_eq(expected, actual));
}

test "TDD: g2_dbl of 2G2 matches rapidsnark (equals 4G2)" {
    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const two = field.fr_toMont(field.fr_from_u64(2));

    const g2_2 = rs.g2MulRapidsnark(g2_affine, two);
    const expected = rs.g2DblRapidsnark(g2_2);
    const actual = curve.g2_dbl(g2_2);

    try std.testing.expect(curve.g2_eq(expected, actual));
}
