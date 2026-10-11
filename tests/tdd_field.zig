const std = @import("std");
const field = @import("cpu").field;
const rs = @import("rapidsnark_test_api");

// ============================================================================
// TDD Field Arithmetic Tests — compare our Zig implementation against
// rapidsnark C++ ground truth, element-by-element.
// ============================================================================

test "TDD: fr_mul matches rapidsnark" {
    // Start with normal-form values
    const a_norm = field.fr_from_u64(3);
    const b_norm = field.fr_from_u64(5);

    // Convert to Montgomery form (both should agree)
    const a_mont = rs.frToMontRapidsnark(a_norm);
    const b_mont = rs.frToMontRapidsnark(b_norm);
    const a_mont_ours = field.fr_toMont(a_norm);
    const b_mont_ours = field.fr_toMont(b_norm);

    try std.testing.expectEqual(a_mont, a_mont_ours);
    try std.testing.expectEqual(b_mont, b_mont_ours);

    // Multiply in Montgomery form
    const expected_mont = rs.frMulRapidsnark(a_mont, b_mont);
    const actual_mont = field.fr_mul(a_mont_ours, b_mont_ours);

    try std.testing.expectEqual(expected_mont, actual_mont);
}

test "TDD: fr_add matches rapidsnark" {
    const a_norm = field.fr_from_u64(7);
    const b_norm = field.fr_from_u64(11);

    const a_mont = rs.frToMontRapidsnark(a_norm);
    const b_mont = rs.frToMontRapidsnark(b_norm);

    const expected = rs.frAddRapidsnark(a_mont, b_mont);
    const actual = field.fr_add(a_mont, b_mont);

    try std.testing.expectEqual(expected, actual);
}

test "TDD: fr_sub matches rapidsnark" {
    const a_norm = field.fr_from_u64(11);
    const b_norm = field.fr_from_u64(7);

    const a_mont = rs.frToMontRapidsnark(a_norm);
    const b_mont = rs.frToMontRapidsnark(b_norm);

    const expected = rs.frSubRapidsnark(a_mont, b_mont);
    const actual = field.fr_sub(a_mont, b_mont);

    try std.testing.expectEqual(expected, actual);
}

test "TDD: fr_toMont / fr_fromMont roundtrip matches rapidsnark" {
    const val = field.fr_from_u64(42);

    // Montgomery conversion
    const expected_mont = rs.frToMontRapidsnark(val);
    const actual_mont = field.fr_toMont(val);
    try std.testing.expectEqual(expected_mont, actual_mont);

    // Back to normal form
    const expected_back = rs.frFromMontRapidsnark(expected_mont);
    const actual_back = field.fr_fromMont(actual_mont);
    try std.testing.expectEqual(expected_back, actual_back);
}

test "TDD: fr_mul with large values matches rapidsnark" {
    const a_norm = field.FrElement{ 0x43e1f593f0000001, 0x2833e84879b97091, 0xb85045b68181585d, 0x30644e72e131a029 };
    const b_norm = field.FrElement{ 0x123456789abcdef0, 0x0fedcba987654321, 0xdeadbeefcafebabe, 0x0102030405060708 };

    const a_mont = rs.frToMontRapidsnark(a_norm);
    const b_mont = rs.frToMontRapidsnark(b_norm);

    const expected = rs.frMulRapidsnark(a_mont, b_mont);
    const actual = field.fr_mul(a_mont, b_mont);

    try std.testing.expectEqual(expected, actual);
}
