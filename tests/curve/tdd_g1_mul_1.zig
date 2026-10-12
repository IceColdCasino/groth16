const std = @import("std");
const field = @import("cpu").field;
const curve = @import("cpu").curve;

test "g1_mul with mont(1)" {
    const g = curve.g1_generator();
    const s1 = field.fr_from_u64(1);
    const actual = curve.g1_mul(g, s1);
    try std.testing.expect(curve.g1_eq(actual, g));
}
