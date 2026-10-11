const std = @import("std");
const field = @import("cpu").field;
const rs = @import("rapidsnark_test_api");
const fft = @import("cpu").fft;

// ============================================================================
// TDD FFT Tests — compare our Zig FFT against rapidsnark
// ============================================================================

fn frArrEql(a: []const field.FrElement, b: []const field.FrElement) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!field.fr_eq(x, y)) return false;
    }
    return true;
}

test "TDD: fft_fr 4-point matches rapidsnark" {
    var data = [_]field.FrElement{
        field.fr_toMont(field.fr_from_u64(1)),
        field.fr_toMont(field.fr_from_u64(2)),
        field.fr_toMont(field.fr_from_u64(3)),
        field.fr_toMont(field.fr_from_u64(4)),
    };
    var expected = data;

    rs.rapidsnark_fft_fr(&expected, 4);
    fft.fft_fr(&data, 4);

    try std.testing.expect(frArrEql(&data, &expected));
}

test "TDD: fft_fr 8-point matches rapidsnark" {
    var data = [_]field.FrElement{
        field.fr_toMont(field.fr_from_u64(1)),
        field.fr_toMont(field.fr_from_u64(2)),
        field.fr_toMont(field.fr_from_u64(3)),
        field.fr_toMont(field.fr_from_u64(4)),
        field.fr_toMont(field.fr_from_u64(5)),
        field.fr_toMont(field.fr_from_u64(6)),
        field.fr_toMont(field.fr_from_u64(7)),
        field.fr_toMont(field.fr_from_u64(8)),
    };
    var expected = data;

    rs.rapidsnark_fft_fr(&expected, 8);
    fft.fft_fr(&data, 8);

    try std.testing.expect(frArrEql(&data, &expected));
}

test "TDD: ifft_fr 4-point matches rapidsnark" {
    var data = [_]field.FrElement{
        field.fr_toMont(field.fr_from_u64(1)),
        field.fr_toMont(field.fr_from_u64(2)),
        field.fr_toMont(field.fr_from_u64(3)),
        field.fr_toMont(field.fr_from_u64(4)),
    };
    var expected = data;

    rs.rapidsnark_ifft_fr(&expected, 4);
    fft.ifft_fr(&data, 4);

    try std.testing.expect(frArrEql(&data, &expected));
}

test "TDD: ifft_fr 8-point matches rapidsnark" {
    var data = [_]field.FrElement{
        field.fr_toMont(field.fr_from_u64(1)),
        field.fr_toMont(field.fr_from_u64(2)),
        field.fr_toMont(field.fr_from_u64(3)),
        field.fr_toMont(field.fr_from_u64(4)),
        field.fr_toMont(field.fr_from_u64(5)),
        field.fr_toMont(field.fr_from_u64(6)),
        field.fr_toMont(field.fr_from_u64(7)),
        field.fr_toMont(field.fr_from_u64(8)),
    };
    var expected = data;

    rs.rapidsnark_ifft_fr(&expected, 8);
    fft.ifft_fr(&data, 8);

    try std.testing.expect(frArrEql(&data, &expected));
}

test "TDD: fft shift 1024-point matches rapidsnark" {
    // Allocate arrays of 1024 elements (actual circuit domain size)
    const n: u32 = 1024;
    var data = try std.testing.allocator.alloc(field.FrElement, n);
    defer std.testing.allocator.free(data);
    var expected = try std.testing.allocator.alloc(field.FrElement, n);
    defer std.testing.allocator.free(expected);

    for (0..n) |i| {
        data[i] = field.fr_toMont(field.fr_from_u64(@intCast(i + 1)));
        expected[i] = data[i];
    }

    rs.rapidsnark_fft_shift(expected.ptr, n);
    fft.shiftCoefficients(data, n, fft.FR_OMEGA_2048);

    try std.testing.expect(frArrEql(data, expected));
}

test "TDD: fft roundtrip matches rapidsnark" {
    var data = [_]field.FrElement{
        field.fr_toMont(field.fr_from_u64(1)),
        field.fr_toMont(field.fr_from_u64(2)),
        field.fr_toMont(field.fr_from_u64(3)),
        field.fr_toMont(field.fr_from_u64(4)),
    };
    const copy = data;

    // Zig roundtrip
    fft.fft_fr(&data, 4);
    fft.ifft_fr(&data, 4);

    // Rapidsnark roundtrip
    var rs_data = copy;
    rs.rapidsnark_fft_fr(&rs_data, 4);
    rs.rapidsnark_ifft_fr(&rs_data, 4);

    try std.testing.expect(frArrEql(&data, &rs_data));
    // Both should recover original
    try std.testing.expect(frArrEql(&data, &copy));
}
