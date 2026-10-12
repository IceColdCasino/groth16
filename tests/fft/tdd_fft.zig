const std = @import("std");
const field = @import("cpu").field;
const fft = @import("cpu").fft;

fn frArrEql(a: []const field.FrElement, b: []const field.FrElement) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!field.fr_eq(x, y)) return false;
    }
    return true;
}

fn montSeq(comptime n: usize) [n]field.FrElement {
    var data: [n]field.FrElement = undefined;
    for (0..n) |i| {
        data[i] = field.fr_toMont(field.fr_from_u64(@intCast(i + 1)));
    }
    return data;
}

test "TDD: fft_fr 4-point roundtrip" {
    var data = montSeq(4);
    const original = data;
    fft.fft_fr(&data, 4);
    try std.testing.expect(!frArrEql(&data, &original));
    fft.ifft_fr(&data, 4);
    try std.testing.expect(frArrEql(&data, &original));
}

test "TDD: fft_fr 8-point roundtrip" {
    var data = montSeq(8);
    const original = data;
    fft.fft_fr(&data, 8);
    try std.testing.expect(!frArrEql(&data, &original));
    fft.ifft_fr(&data, 8);
    try std.testing.expect(frArrEql(&data, &original));
}

test "TDD: ifft_fr 4-point roundtrip" {
    var data = montSeq(4);
    const original = data;
    fft.ifft_fr(&data, 4);
    fft.fft_fr(&data, 4);
    try std.testing.expect(frArrEql(&data, &original));
}

test "TDD: ifft_fr 8-point roundtrip" {
    var data = montSeq(8);
    const original = data;
    fft.ifft_fr(&data, 8);
    fft.fft_fr(&data, 8);
    try std.testing.expect(frArrEql(&data, &original));
}

test "TDD: fft shift 1024-point" {
    const n: u32 = 1024;
    var data = try std.testing.allocator.alloc(field.FrElement, n);
    defer std.testing.allocator.free(data);
    var original = try std.testing.allocator.alloc(field.FrElement, n);
    defer std.testing.allocator.free(original);

    for (0..n) |i| {
        data[i] = field.fr_toMont(field.fr_from_u64(@intCast(i + 1)));
        original[i] = data[i];
    }

    const g = fft.FR_OMEGA_2048;
    fft.shiftCoefficients(data, n, g);

    var power = field.fr_one();
    for (0..n) |i| {
        const expected = field.fr_mul(original[i], power);
        try std.testing.expect(field.fr_eq(data[i], expected));
        power = field.fr_mul(power, g);
    }
}

test "TDD: fft roundtrip" {
    var data = montSeq(4);
    const original = data;
    fft.fft_fr(&data, 4);
    fft.ifft_fr(&data, 4);
    try std.testing.expect(frArrEql(&data, &original));
}
