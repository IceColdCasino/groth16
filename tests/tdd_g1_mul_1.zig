const std = @import("std");
const field = @import("cpu").field;
const curve = @import("cpu").curve;
const rs = @import("rapidsnark_test_api");

test "g1_mul with mont(1)" {
    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const s1 = field.fr_toMont(field.fr_from_u64(1));
    
    const expected = rs.g1MulRapidsnark(g_affine, s1);
    const actual = curve.g1_mul(g, s1);
    
    try std.testing.expect(curve.g1_eq(expected, actual));
}
