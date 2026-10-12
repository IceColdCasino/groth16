const std = @import("std");
const field = @import("cpu").field;

// Field arithmetic checks against small integers and the field laws.

test "TDD: fr_mul" {
    const a = field.fr_toMont(field.fr_from_u64(3));
    const b = field.fr_toMont(field.fr_from_u64(5));
    const product = field.fr_fromMont(field.fr_mul(a, b));
    try std.testing.expect(field.fr_eq(product, field.fr_from_u64(15)));
}

test "TDD: fr_add" {
    const a = field.fr_toMont(field.fr_from_u64(7));
    const b = field.fr_toMont(field.fr_from_u64(11));
    const sum = field.fr_fromMont(field.fr_add(a, b));
    try std.testing.expect(field.fr_eq(sum, field.fr_from_u64(18)));
}

test "TDD: fr_sub" {
    const a = field.fr_toMont(field.fr_from_u64(11));
    const b = field.fr_toMont(field.fr_from_u64(7));
    const diff = field.fr_fromMont(field.fr_sub(a, b));
    try std.testing.expect(field.fr_eq(diff, field.fr_from_u64(4)));
}

test "TDD: fr_toMont / fr_fromMont roundtrip" {
    const val = field.fr_from_u64(42);
    const mont = field.fr_toMont(val);
    const back = field.fr_fromMont(mont);
    try std.testing.expect(field.fr_eq(back, val));
}

test "TDD: fr_mul with large values" {
    const a_norm = field.FrElement{ 0x123456789abcdef0, 0x0fedcba987654321, 0x1111111111111111, 0x0102030405060708 };
    const b_norm = field.FrElement{ 0x0fedcba987654321, 0x123456789abcdef0, 0x2222222222222222, 0x0807060504030201 };
    const c_norm = field.fr_from_u64(9);

    const a = field.fr_toMont(a_norm);
    const b = field.fr_toMont(b_norm);
    const c = field.fr_toMont(c_norm);

    try std.testing.expect(field.fr_eq(field.fr_fromMont(a), a_norm));
    try std.testing.expect(field.fr_eq(field.fr_mul(a, b), field.fr_mul(b, a)));

    const left = field.fr_mul(field.fr_add(a, b), c);
    const right = field.fr_add(field.fr_mul(a, c), field.fr_mul(b, c));
    try std.testing.expect(field.fr_eq(left, right));
}
