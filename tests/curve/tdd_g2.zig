const std = @import("std");
const field = @import("cpu").field;
const curve = @import("cpu").curve;

fn sc(v: u64) field.FrElement {
    return field.fr_from_u64(v);
}

test "TDD: g2_mul(2*G2)" {
    const g2 = curve.g2_generator();
    const doubled = curve.g2_mul(g2, sc(2));
    try std.testing.expect(curve.g2_eq(doubled, curve.g2_add(g2, g2)));
    try std.testing.expect(curve.g2_eq(doubled, curve.g2_dbl(g2)));
}

test "TDD: g2_add(G2, G2) equals 2G2" {
    const g2 = curve.g2_generator();
    const added = curve.g2_add(g2, g2);
    try std.testing.expect(curve.g2_eq(added, curve.g2_mul(g2, sc(2))));
}

test "TDD: g2_dbl(G2) equals 2G2" {
    const g2 = curve.g2_generator();
    const doubled = curve.g2_dbl(g2);
    try std.testing.expect(curve.g2_eq(doubled, curve.g2_mul(g2, sc(2))));
}

test "TDD: g2_mul with large scalar" {
    const g2 = curve.g2_generator();
    const scalar = field.FrElement{ 0xdeadbeefcafebabe, 0x123456789abcdef0, 0xfedcba0987654321, 0x0a0b0c0d0e0f0102 };
    const once = curve.g2_mul(g2, scalar);
    const twice = curve.g2_add(once, once);
    try std.testing.expect(curve.g2_eq(twice, curve.g2_mul(g2, field.fr_add(scalar, scalar))));
    try std.testing.expect(!curve.g2_eq(once, g2));
}

test "TDD: g2_add(G2, 2G2) equals 3G2" {
    const g2 = curve.g2_generator();
    const g2_2 = curve.g2_mul(g2, sc(2));
    const sum = curve.g2_add(g2, g2_2);
    try std.testing.expect(curve.g2_eq(sum, curve.g2_mul(g2, sc(3))));
}

test "TDD: g2_add of two distinct points" {
    const g2 = curve.g2_generator();
    const p1 = curve.g2_mul(g2, sc(3));
    const p2 = curve.g2_mul(g2, sc(5));
    const sum = curve.g2_add(p1, p2);
    try std.testing.expect(curve.g2_eq(sum, curve.g2_mul(g2, sc(8))));
}

test "TDD: g2_dbl of 2G2 equals 4G2" {
    const g2 = curve.g2_generator();
    const g2_2 = curve.g2_mul(g2, sc(2));
    const doubled = curve.g2_dbl(g2_2);
    try std.testing.expect(curve.g2_eq(doubled, curve.g2_mul(g2, sc(4))));
}
