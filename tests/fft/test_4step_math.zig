const std = @import("std");
const cpu = @import("cpu");

const field = cpu.field;
const fft = cpu.fft;

test "4-step math verification" {
    const n: u32 = 16; // 4x4 matrix for easy verification
    const N1: u32 = 4;
    const N2: u32 = 4;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create simple test data
    var data = try allocator.alloc(field.FrElement, n);
    for (0..n) |i| {
        data[i] = field.fr_from_u64(@intCast(i + 1));
        data[i] = field.fr_toMont(data[i]);
    }

    // CPU reference: standard FFT
    const expected = try allocator.alloc(field.FrElement, n);
    @memcpy(std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(data));
    fft.fft_fr(expected, n);

    // 4-step FFT on CPU
    var result = try allocator.alloc(field.FrElement, n);
    @memcpy(std.mem.sliceAsBytes(result), std.mem.sliceAsBytes(data));

    // Step 1: Row FFTs (N1 FFTs of size N2)
    for (0..N1) |row| {
        var row_data = try allocator.alloc(field.FrElement, N2);
        for (0..N2) |col| {
            row_data[col] = result[row * N2 + col];
        }
        fft.fft_fr(row_data, N2);
        for (0..N2) |col| {
            result[row * N2 + col] = row_data[col];
        }
    }

    // Step 2: Twiddle multiply
    for (0..N1) |row| {
        for (0..N2) |col| {
            const twiddle = fft.getTwiddle(n, @intCast(row * col));
            result[row * N2 + col] = field.fr_mul(result[row * N2 + col], twiddle);
        }
    }

    // Step 3: Transpose
    var transposed = try allocator.alloc(field.FrElement, n);
    for (0..N1) |row| {
        for (0..N2) |col| {
            transposed[col * N1 + row] = result[row * N2 + col];
        }
    }

    // Step 4: Column FFTs (N2 FFTs of size N1 on transposed data)
    for (0..N2) |row| {
        var row_data = try allocator.alloc(field.FrElement, N1);
        for (0..N1) |col| {
            row_data[col] = transposed[row * N1 + col];
        }
        fft.fft_fr(row_data, N1);
        for (0..N1) |col| {
            transposed[row * N1 + col] = row_data[col];
        }
    }

    // Step 5: Transpose back
    for (0..N2) |row| {
        for (0..N1) |col| {
            result[col * N2 + row] = transposed[row * N1 + col];
        }
    }

    // Compare
    var pass = true;
    for (0..n) |i| {
        if (!field.fr_eq(result[i], expected[i])) {
            std.debug.print("Mismatch at {d}: 4-step={x} expected={x}\n", .{ i, result[i][0], expected[i][0] });
            pass = false;
        }
    }

    // Debug: print first few elements of both results
    std.debug.print("\nExpected (standard FFT): ", .{});
    for (0..4) |i| {
        std.debug.print("{x} ", .{expected[i][0]});
    }
    std.debug.print("\n4-step result:         ", .{});
    for (0..4) |i| {
        std.debug.print("{x} ", .{result[i][0]});
    }
    std.debug.print("\n", .{});

    try std.testing.expect(pass);
}
