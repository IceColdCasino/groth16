const std = @import("std");
const builtin = @import("builtin");
const field = @import("field.zig");

fn secureRandomBytes(buf: []u8) void {
    if (builtin.is_test) {
        std.testing.io.random(buf);
    } else {
        switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos => {
                std.c.arc4random_buf(buf.ptr, buf.len);
            },
            .linux, .freebsd => {
                var total_read: usize = 0;
                while (total_read < buf.len) {
                    const rc = std.c.getrandom(buf.ptr + total_read, buf.len - total_read, 0);
                    if (rc < 0) @panic("getrandom failed");
                    total_read += @intCast(rc);
                }
            },
            else => @compileError("unsupported OS for secure random"),
        }
    }
}

fn elementLessThan(a: [4]u64, b: [4]u64) bool {
    for (0..4) |i| {
        const idx = 3 - i;
        if (a[idx] < b[idx]) return true;
        if (a[idx] > b[idx]) return false;
    }
    return false; // equal
}

pub fn fr_random() field.FrElement {
    const r = field.FrElement{ 0x43e1f593f0000001, 0x2833e84879b97091, 0xb85045b68181585d, 0x30644e72e131a029 };
    var result: field.FrElement = undefined;

    while (true) {
        var bytes: [32]u8 = undefined;
        secureRandomBytes(&bytes);

        for (0..4) |i| {
            var limb: u64 = 0;
            for (0..8) |j| {
                limb |= @as(u64, bytes[i * 8 + j]) << @intCast(j * 8);
            }
            result[i] = limb;
        }

        if (elementLessThan(result, r)) {
            return result;
        }
    }
}

pub fn fq_random() field.FqElement {
    const q = field.FqElement{ 0x3c208c16d87cfd47, 0x97816a916871ca8d, 0xb85045b68181585d, 0x30644e72e131a029 };
    var result: field.FqElement = undefined;

    while (true) {
        var bytes: [32]u8 = undefined;
        secureRandomBytes(&bytes);

        for (0..4) |i| {
            var limb: u64 = 0;
            for (0..8) |j| {
                limb |= @as(u64, bytes[i * 8 + j]) << @intCast(j * 8);
            }
            result[i] = limb;
        }

        if (elementLessThan(result, q)) {
            return result;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "fr_random in field" {
    const r = fr_random();
    try std.testing.expect(!field.fr_is_zero(r));
    const one = field.fr_one();
    const prod = field.fr_mul(r, one);
    try std.testing.expect(field.fr_eq(prod, r));
}
