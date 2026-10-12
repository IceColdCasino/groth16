const std = @import("std");
const field = @import("cpu").field;
const curve = @import("cpu").curve;

fn sc(v: u64) field.FrElement {
    return field.fr_from_u64(v);
}

test "TDD: g1_mul(1*G)" {
    const g = curve.g1_generator();
    const actual = curve.g1_mul(g, sc(1));
    try std.testing.expect(curve.g1_eq(actual, g));
}

test "TDD: g1_mul(2*G)" {
    const g = curve.g1_generator();
    const doubled = curve.g1_mul(g, sc(2));
    try std.testing.expect(curve.g1_eq(doubled, curve.g1_add(g, g)));
    try std.testing.expect(curve.g1_eq(doubled, curve.g1_dbl(g)));
}

test "TDD: g1_add(G, G) equals 2G" {
    const g = curve.g1_generator();
    const added = curve.g1_add(g, g);
    try std.testing.expect(curve.g1_eq(added, curve.g1_mul(g, sc(2))));
}

test "TDD: g1_dbl(G) equals 2G" {
    const g = curve.g1_generator();
    const doubled = curve.g1_dbl(g);
    try std.testing.expect(curve.g1_eq(doubled, curve.g1_mul(g, sc(2))));
}

test "TDD: g1_mul with large scalar" {
    const g = curve.g1_generator();
    const scalar = field.FrElement{ 0xdeadbeefcafebabe, 0x123456789abcdef0, 0xfedcba0987654321, 0x0a0b0c0d0e0f0102 };
    const once = curve.g1_mul(g, scalar);
    const twice = curve.g1_add(once, once);
    try std.testing.expect(curve.g1_eq(twice, curve.g1_mul(g, field.fr_add(scalar, scalar))));
    try std.testing.expect(!curve.g1_eq(once, g));
}

test "TDD: g1_add(G, 2G) equals 3G" {
    const g = curve.g1_generator();
    const g2 = curve.g1_mul(g, sc(2));
    const sum = curve.g1_add(g, g2);
    try std.testing.expect(curve.g1_eq(sum, curve.g1_mul(g, sc(3))));
}

test "TDD: g1_add of two distinct points" {
    const g = curve.g1_generator();
    const p1 = curve.g1_mul(g, sc(3));
    const p2 = curve.g1_mul(g, sc(5));
    const sum = curve.g1_add(p1, p2);
    try std.testing.expect(curve.g1_eq(sum, curve.g1_mul(g, sc(8))));
}

test "TDD: g1_dbl of 2G equals 4G" {
    const g = curve.g1_generator();
    const g2 = curve.g1_mul(g, sc(2));
    const doubled = curve.g1_dbl(g2);
    try std.testing.expect(curve.g1_eq(doubled, curve.g1_mul(g, sc(4))));
}
