const std = @import("std");
const field = @import("cpu").field;
const curve = @import("cpu").curve;
const rs = @import("rapidsnark_test_api");

// ============================================================================
// TDD G1 Curve Tests — compare our Zig implementation against rapidsnark
// ============================================================================

test "TDD: g1_mul(1*G) matches rapidsnark" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const s1 = field.fr_toMont(field.fr_from_u64(1));

    const expected = rs.g1MulRapidsnark(g_affine, s1);
    const actual = curve.g1_mul(g, s1);

    try std.testing.expect(curve.g1_eq(expected, actual));
}

test "TDD: g1_mul(2*G) matches rapidsnark" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const scalar = field.fr_from_u64(2);
    const scalar_mont = field.fr_toMont(scalar);

    // Expected: rapidsnark
    const expected = rs.g1MulRapidsnark(g_affine, scalar_mont);

    // Actual: our Zig (projective base)
    const actual = curve.g1_mul(g, scalar_mont);

    try std.testing.expect(curve.g1_eq(expected, actual));
}

test "TDD: g1_add(G, G) matches rapidsnark (equals 2G)" {
    const g = curve.g1_generator();

    // Expected: rapidsnark G+G
    const expected = rs.g1AddRapidsnark(g, g);

    // Actual: our Zig G+G
    const actual = curve.g1_add(g, g);

    try std.testing.expect(curve.g1_eq(expected, actual));
}

test "TDD: g1_dbl(G) matches rapidsnark (equals 2G)" {
    const g = curve.g1_generator();

    // Expected: rapidsnark dbl(G)
    const expected = rs.g1DblRapidsnark(g);

    // Actual: our Zig dbl(G)
    const actual = curve.g1_dbl(g);

    try std.testing.expect(curve.g1_eq(expected, actual));
}

test "TDD: g1_mul with large scalar matches rapidsnark" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const scalar = field.FrElement{ 0xdeadbeefcafebabe, 0x123456789abcdef0, 0xfedcba0987654321, 0x0a0b0c0d0e0f0102 };
    const scalar_mont = field.fr_toMont(scalar);

    const expected = rs.g1MulRapidsnark(g_affine, scalar_mont);
    const actual = curve.g1_mul(g, scalar_mont);

    try std.testing.expect(curve.g1_eq(expected, actual));
}

test "TDD: g1_add(G, 2G) matches rapidsnark (equals 3G)" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const two = field.fr_from_u64(2);
    const two_mont = field.fr_toMont(two);

    // Expected: rapidsnark G + 2G
    const g2_rs = rs.g1MulRapidsnark(g_affine, two_mont);
    const expected = rs.g1AddRapidsnark(g, g2_rs);

    // Actual: our Zig G + 2G
    const g2 = curve.g1_mul(g, two_mont);
    const actual = curve.g1_add(g, g2);

    try std.testing.expect(curve.g1_eq(expected, actual));
}

test "TDD: g1_add of two distinct points matches rapidsnark" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };

    const s1 = field.fr_toMont(field.fr_from_u64(3));
    const s2 = field.fr_toMont(field.fr_from_u64(5));

    const p1 = rs.g1MulRapidsnark(g_affine, s1);
    const p2 = rs.g1MulRapidsnark(g_affine, s2);

    const expected = rs.g1AddRapidsnark(p1, p2);
    const actual = curve.g1_add(p1, p2);

    try std.testing.expect(curve.g1_eq(expected, actual));
}

test "TDD: g1_dbl of 2G matches rapidsnark (equals 4G)" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const two_mont = field.fr_toMont(field.fr_from_u64(2));

    const g2 = rs.g1MulRapidsnark(g_affine, two_mont);

    // Expected: rapidsnark dbl(2G)
    const expected = rs.g1DblRapidsnark(g2);

    // Actual: our Zig dbl(2G)
    const actual = curve.g1_dbl(g2);

    try std.testing.expect(curve.g1_eq(expected, actual));
}
