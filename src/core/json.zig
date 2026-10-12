const std = @import("std");
const field = @import("field.zig");
const curve = @import("curve.zig");

pub const Proof = struct {
    pi_a: curve.G1Point,
    pi_b: curve.G2Point,
    pi_c: curve.G1Point,
};

// ============================================================================
// Hex helpers
// ============================================================================

fn hexDigit(n: u4) u8 {
    return if (n < 10) '0' + @as(u8, n) else 'a' + @as(u8, n - 10);
}

fn hexValue(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => error.InvalidHex,
    };
}

fn hexByte(hi: u8, lo: u8) !u8 {
    return (@as(u8, try hexValue(hi)) << 4) | @as(u8, try hexValue(lo));
}

/// Convert a [4]u64 element to a big-endian hex string WITHOUT leading zeros.
fn elementToHex(elem: [4]u64, allocator: std.mem.Allocator) ![]u8 {
    var bytes: [32]u8 = undefined;
    for (0..4) |i| {
        const limb = elem[3 - i];
        for (0..8) |j| {
            bytes[i * 8 + j] = @truncate(limb >> @intCast(56 - j * 8));
        }
    }

    var start: usize = 0;
    while (start < 32 and bytes[start] == 0) : (start += 1) {}
    if (start == 32) return try allocator.dupe(u8, "0");

    const hex_len = (32 - start) * 2;
    const hex = try allocator.alloc(u8, hex_len);
    for (0..32 - start) |i| {
        const byte = bytes[start + i];
        hex[i * 2] = hexDigit(@truncate(byte >> 4));
        hex[i * 2 + 1] = hexDigit(@truncate(byte & 0xF));
    }
    return hex;
}

/// Parse a hex string (no 0x prefix) back to a [4]u64 element (normal form).
fn hexToElement(hex: []const u8) ![4]u64 {
    if (hex.len == 0 or hex.len > 64) return error.InvalidHex;

    var padded: [64]u8 = undefined;
    @memset(&padded, '0');
    @memcpy(padded[64 - hex.len ..], hex);

    var bytes: [32]u8 = undefined;
    for (0..32) |i| {
        bytes[i] = try hexByte(padded[i * 2], padded[i * 2 + 1]);
    }

    var elem: [4]u64 = undefined;
    for (0..4) |i| {
        var limb: u64 = 0;
        for (0..8) |j| {
            limb = (limb << 8) | bytes[i * 8 + j];
        }
        elem[3 - i] = limb;
    }
    return elem;
}

/// Parse a decimal string back to a [4]u64 element (normal form).
fn decimalToElement(dec: []const u8) ![4]u64 {
    if (dec.len == 0) return error.InvalidDecimal;
    var result = [_]u64{ 0, 0, 0, 0 };
    for (dec) |c| {
        if (c < '0' or c > '9') return error.InvalidDecimal;
        const digit = c - '0';

        // result = result * 10
        var carry: u128 = 0;
        for (0..4) |i| {
            const prod = @as(u128, result[i]) * 10 + carry;
            result[i] = @truncate(prod);
            carry = prod >> 64;
        }
        if (carry != 0) return error.DecimalTooLarge;

        // result = result + digit
        var add_carry: u64 = digit;
        for (0..4) |i| {
            const sum = @as(u128, result[i]) + add_carry;
            result[i] = @truncate(sum);
            add_carry = @intCast(sum >> 64);
        }
        if (add_carry != 0) return error.DecimalTooLarge;
    }
    return result;
}

// ============================================================================
// JSON helpers
// ============================================================================

fn splitQuotedStrings(allocator: std.mem.Allocator, content: []const u8) ![][]u8 {
    var result = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit();
    }

    var i: usize = 0;
    while (i < content.len) {
        while (i < content.len and content[i] != '"') : (i += 1) {}
        if (i >= content.len) break;
        i += 1; // skip opening quote
        const start = i;
        while (i < content.len and content[i] != '"') : (i += 1) {}
        if (i >= content.len) break;
        const item = try allocator.dupe(u8, content[start..i]);
        try result.append(item);
        i += 1; // skip closing quote
    }
    return result.toOwnedSlice();
}

fn splitArrayElements(allocator: std.mem.Allocator, content: []const u8) ![][]u8 {
    var result = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit();
    }

    var depth: usize = 0;
    var start: ?usize = null;
    for (content, 0..) |c, i| {
        if (c == '[') {
            if (depth == 0) start = i;
            depth += 1;
        } else if (c == ']') {
            depth -= 1;
            if (depth == 0) {
                if (start) |s| {
                    const trimmed = std.mem.trim(u8, content[s + 1 .. i], " \t\n\r");
                    const item = try allocator.dupe(u8, trimmed);
                    try result.append(item);
                }
                start = null;
            }
        }
    }
    return result.toOwnedSlice();
}

fn findMatchingBracket(s: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < s.len) : (i += 1) {
        if (s[i] == '[') {
            depth += 1;
        } else if (s[i] == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn parseG1(allocator: std.mem.Allocator, content: []const u8) !curve.G1Point {
    const parts = try splitQuotedStrings(allocator, content);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    if (parts.len != 3) return error.InvalidFormat;

    if (std.mem.eql(u8, parts[2], "0")) {
        return curve.g1_zero();
    }

    const x = field.fq_toMont(try decimalToElement(parts[0]));
    const y = field.fq_toMont(try decimalToElement(parts[1]));
    return curve.g1_affine_to_projective(.{ .x = x, .y = y });
}

fn parseFq2(allocator: std.mem.Allocator, content: []const u8) !field.Fq2Element {
    const parts = try splitQuotedStrings(allocator, content);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    if (parts.len != 2) return error.InvalidFormat;
    return .{
        .a = field.fq_toMont(try decimalToElement(parts[0])),
        .b = field.fq_toMont(try decimalToElement(parts[1])),
    };
}

fn parseG2(allocator: std.mem.Allocator, content: []const u8) !curve.G2Point {
    const parts = try splitArrayElements(allocator, content);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    if (parts.len != 3) return error.InvalidFormat;

    const z = try parseFq2(allocator, parts[2]);
    if (field.fq2_is_zero(z)) {
        return curve.g2_zero();
    }

    const x = try parseFq2(allocator, parts[0]);
    const y = try parseFq2(allocator, parts[1]);
    return curve.g2_affine_to_projective(.{ .x = x, .y = y });
}

// ============================================================================
// Public API
// ============================================================================

/// Convert projective G1 point to affine coordinates.
fn g1_to_affine(p: curve.G1Point) curve.G1PointAffine {
    if (curve.g1_is_zero(p)) {
        return .{ .x = field.fq_zero(), .y = field.fq_zero() };
    }
    const zz_inv = field.fq_inv(p.zz);
    const zzz_inv = field.fq_inv(p.zzz);
    const x = field.fq_mul(p.x, zz_inv);
    const y = field.fq_mul(p.y, zzz_inv);
    return .{ .x = x, .y = y };
}

/// Convert projective G2 point to affine coordinates.
fn g2_to_affine(p: curve.G2Point) curve.G2PointAffine {
    if (curve.g2_is_zero(p)) {
        return .{ .x = field.fq2_zero(), .y = field.fq2_zero() };
    }
    const zz_inv = field.fq2_inv(p.zz);
    const zzz_inv = field.fq2_inv(p.zzz);
    const x = field.fq2_mul(p.x, zz_inv);
    const y = field.fq2_mul(p.y, zzz_inv);
    return .{ .x = x, .y = y };
}

pub fn proofToString(allocator: std.mem.Allocator, proof: Proof) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"pi_a\":[");

    if (curve.g1_is_zero(proof.pi_a)) {
        try list.appendSlice(allocator, "\"1\",\"1\",\"0\"");
    } else {
        const affine = g1_to_affine(proof.pi_a);
        const x_norm = field.fq_fromMont(affine.x);
        const y_norm = field.fq_fromMont(affine.y);
        const x_dec = try elementToDecimal(x_norm, allocator);
        defer allocator.free(x_dec);
        const y_dec = try elementToDecimal(y_norm, allocator);
        defer allocator.free(y_dec);
        try list.print(allocator, "\"{s}\",\"{s}\",\"1\"", .{ x_dec, y_dec });
    }

    try list.appendSlice(allocator, "],\"pi_b\":[");

    if (curve.g2_is_zero(proof.pi_b)) {
        try list.appendSlice(allocator, "[\"1\",\"0\"],[\"1\",\"0\"],[\"0\",\"0\"]");
    } else {
        const affine = g2_to_affine(proof.pi_b);
        const xa_norm = field.fq_fromMont(affine.x.a);
        const xb_norm = field.fq_fromMont(affine.x.b);
        const ya_norm = field.fq_fromMont(affine.y.a);
        const yb_norm = field.fq_fromMont(affine.y.b);

        const xa_dec = try elementToDecimal(xa_norm, allocator);
        defer allocator.free(xa_dec);
        const xb_dec = try elementToDecimal(xb_norm, allocator);
        defer allocator.free(xb_dec);
        const ya_dec = try elementToDecimal(ya_norm, allocator);
        defer allocator.free(ya_dec);
        const yb_dec = try elementToDecimal(yb_norm, allocator);
        defer allocator.free(yb_dec);

        try list.print(allocator, "[\"{s}\",\"{s}\"],[\"{s}\",\"{s}\"],[\"1\",\"0\"]", .{ xa_dec, xb_dec, ya_dec, yb_dec });
    }

    try list.appendSlice(allocator, "],\"pi_c\":[");

    if (curve.g1_is_zero(proof.pi_c)) {
        try list.appendSlice(allocator, "\"1\",\"1\",\"0\"");
    } else {
        const affine = g1_to_affine(proof.pi_c);
        const x_norm = field.fq_fromMont(affine.x);
        const y_norm = field.fq_fromMont(affine.y);
        const x_dec = try elementToDecimal(x_norm, allocator);
        defer allocator.free(x_dec);
        const y_dec = try elementToDecimal(y_norm, allocator);
        defer allocator.free(y_dec);
        try list.print(allocator, "\"{s}\",\"{s}\",\"1\"", .{ x_dec, y_dec });
    }

    try list.appendSlice(allocator, "],\"protocol\":\"groth16\"}");

    return list.toOwnedSlice(allocator);
}

/// Convert a 256-bit big integer (as [4]u64 LE limbs) to a decimal string.
fn elementToDecimal(elem: [4]u64, allocator: std.mem.Allocator) ![]u8 {
    // Simple approach: repeatedly divide by 10
    var limbs = elem;
    var digits = std.array_list.Managed(u8).init(allocator);
    errdefer digits.deinit();

    while (!isZeroLimbs(limbs)) {
        var remainder: u64 = 0;
        var i: usize = 4;
        while (i > 0) {
            i -= 1;
            // current = remainder * 2^64 + limbs[i]
            const current = limbs[i];
            if (remainder > 0) {
                // Use u128 to avoid overflow
                const big = (@as(u128, remainder) << 64) + current;
                limbs[i] = @truncate(big / 10);
                remainder = @truncate(big % 10);
            } else {
                limbs[i] = current / 10;
                remainder = current % 10;
            }
        }
        try digits.append(@as(u8, @intCast(remainder)) + '0');
    }

    if (digits.items.len == 0) {
        try digits.append('0');
    }

    // Reverse digits
    var i: usize = 0;
    var j = digits.items.len;
    while (i < j) {
        j -= 1;
        const tmp = digits.items[i];
        digits.items[i] = digits.items[j];
        digits.items[j] = tmp;
        i += 1;
    }

    return digits.toOwnedSlice();
}

fn isZeroLimbs(limbs: [4]u64) bool {
    return limbs[0] == 0 and limbs[1] == 0 and limbs[2] == 0 and limbs[3] == 0;
}

pub fn publicToString(allocator: std.mem.Allocator, signals: []const field.FrElement) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.append(allocator, '[');
    for (signals, 0..) |sig, i| {
        const decimal = try elementToDecimal(sig, allocator);
        defer allocator.free(decimal);
        if (i > 0) try list.append(allocator, ',');
        try list.print(allocator, "\"{s}\"", .{decimal});
    }
    try list.append(allocator, ']');

    return list.toOwnedSlice(allocator);
}

pub fn parseProof(allocator: std.mem.Allocator, json_str: []const u8) !Proof {
    const pi_a_start = std.mem.indexOf(u8, json_str, "\"pi_a\":[") orelse return error.InvalidJson;
    const pi_a_content_start = pi_a_start + "\"pi_a\":[".len;
    const pi_a_end = findMatchingBracket(json_str, pi_a_content_start) orelse return error.InvalidJson;
    const pi_a = try parseG1(allocator, json_str[pi_a_content_start..pi_a_end]);

    const pi_b_start = std.mem.indexOf(u8, json_str, "\"pi_b\":[") orelse return error.InvalidJson;
    const pi_b_content_start = pi_b_start + "\"pi_b\":[".len;
    const pi_b_end = findMatchingBracket(json_str, pi_b_content_start) orelse return error.InvalidJson;
    const pi_b = try parseG2(allocator, json_str[pi_b_content_start..pi_b_end]);

    const pi_c_start = std.mem.indexOf(u8, json_str, "\"pi_c\":[") orelse return error.InvalidJson;
    const pi_c_content_start = pi_c_start + "\"pi_c\":[".len;
    const pi_c_end = findMatchingBracket(json_str, pi_c_content_start) orelse return error.InvalidJson;
    const pi_c = try parseG1(allocator, json_str[pi_c_content_start..pi_c_end]);

    return Proof{ .pi_a = pi_a, .pi_b = pi_b, .pi_c = pi_c };
}

// ============================================================================
// Tests
// ============================================================================

test "proof roundtrip" {
    const g1 = curve.g1_generator();
    const g2 = curve.g2_generator();
    const proof = Proof{ .pi_a = g1, .pi_b = g2, .pi_c = g1 };
    const json_str = try proofToString(std.testing.allocator, proof);
    defer std.testing.allocator.free(json_str);
    const parsed = try parseProof(std.testing.allocator, json_str);
    try std.testing.expect(curve.g1_eq(parsed.pi_a, g1));
    try std.testing.expect(curve.g2_eq(parsed.pi_b, g2));
}

test "public signals" {
    const signals = &[_]field.FrElement{ field.fr_from_u64(1), field.fr_from_u64(2) };
    const json_str = try publicToString(std.testing.allocator, signals);
    defer std.testing.allocator.free(json_str);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "1") != null);
}
