const std = @import("std");
const field = @import("field.zig");
const curve = @import("curve.zig");
const pairing = @import("pairing.zig");
const msm = @import("msm.zig");

// ============================================================================
// Decimal string parsing (snarkJS outputs decimal, not hex)
// ============================================================================

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
// JSON string helpers (mirroring json.zig patterns)
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
    for (content, 0..) |c, idx| {
        if (c == '[') {
            if (depth == 0) start = idx;
            depth += 1;
        } else if (c == ']') {
            depth -= 1;
            if (depth == 0) {
                if (start) |s| {
                    const trimmed = std.mem.trim(u8, content[s + 1 .. idx], " \t\n\r");
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

// ============================================================================
// Point parsing from decimal JSON
// ============================================================================

fn parseG1Decimal(allocator: std.mem.Allocator, content: []const u8) !curve.G1PointAffine {
    const parts = try splitQuotedStrings(allocator, content);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    if (parts.len != 3) return error.InvalidFormat;

    if (std.mem.eql(u8, parts[2], "0")) {
        return curve.G1PointAffine{ .x = field.fq_zero(), .y = field.fq_zero() };
    }

    const x = field.fq_toMont(try decimalToElement(parts[0]));
    const y = field.fq_toMont(try decimalToElement(parts[1]));
    return curve.G1PointAffine{ .x = x, .y = y };
}

fn parseFq2Decimal(allocator: std.mem.Allocator, content: []const u8) !field.Fq2Element {
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

fn parseG2Decimal(allocator: std.mem.Allocator, content: []const u8) !curve.G2PointAffine {
    const parts = try splitArrayElements(allocator, content);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    if (parts.len != 3) return error.InvalidFormat;

    const z = try parseFq2Decimal(allocator, parts[2]);
    if (field.fq2_is_zero(z)) {
        return curve.G2PointAffine{ .x = field.fq2_zero(), .y = field.fq2_zero() };
    }

    const x = try parseFq2Decimal(allocator, parts[0]);
    const y = try parseFq2Decimal(allocator, parts[1]);
    return curve.G2PointAffine{ .x = x, .y = y };
}

// ============================================================================
// Proof / Public / VK parsing
// ============================================================================

pub const Proof = struct {
    pi_a: curve.G1Point,
    pi_b: curve.G2Point,
    pi_c: curve.G1Point,
};

fn findFieldStart(json_str: []const u8, field_name: []const u8) ?usize {
    const key = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field_name}) catch return null;
    defer std.heap.page_allocator.free(key);
    const start = std.mem.indexOf(u8, json_str, key) orelse return null;
    var i = start + key.len;
    // Skip whitespace and colon
    while (i < json_str.len and (json_str[i] == ' ' or json_str[i] == '\t' or json_str[i] == '\n' or json_str[i] == '\r' or json_str[i] == ':')) : (i += 1) {}
    if (i >= json_str.len or json_str[i] != '[') return null;
    return i + 1; // return position after '['
}

pub fn parseProof(allocator: std.mem.Allocator, json_str: []const u8) !Proof {
    const pi_a_content_start = findFieldStart(json_str, "pi_a") orelse return error.InvalidJson;
    const pi_a_end = findMatchingBracket(json_str, pi_a_content_start) orelse return error.InvalidJson;
    const pi_a_affine = try parseG1Decimal(allocator, json_str[pi_a_content_start..pi_a_end]);

    const pi_b_content_start = findFieldStart(json_str, "pi_b") orelse return error.InvalidJson;
    const pi_b_end = findMatchingBracket(json_str, pi_b_content_start) orelse return error.InvalidJson;
    const pi_b_affine = try parseG2Decimal(allocator, json_str[pi_b_content_start..pi_b_end]);

    const pi_c_content_start = findFieldStart(json_str, "pi_c") orelse return error.InvalidJson;
    const pi_c_end = findMatchingBracket(json_str, pi_c_content_start) orelse return error.InvalidJson;
    const pi_c_affine = try parseG1Decimal(allocator, json_str[pi_c_content_start..pi_c_end]);

    return Proof{
        .pi_a = curve.g1_affine_to_projective(pi_a_affine),
        .pi_b = curve.g2_affine_to_projective(pi_b_affine),
        .pi_c = curve.g1_affine_to_projective(pi_c_affine),
    };
}

pub fn parsePublicSignals(allocator: std.mem.Allocator, json_str: []const u8) ![]field.FrElement {
    const elements = try splitQuotedStrings(allocator, json_str);
    defer {
        for (elements) |e| allocator.free(e);
        allocator.free(elements);
    }

    var result = try allocator.alloc(field.FrElement, elements.len);
    errdefer allocator.free(result);

    for (elements, 0..) |elem, i| {
        result[i] = try decimalToElement(elem);
    }

    return result;
}

pub const VerificationKey = struct {
    alpha1: curve.G1PointAffine,
    beta2: curve.G2PointAffine,
    gamma2: curve.G2PointAffine,
    delta2: curve.G2PointAffine,
    ic: []curve.G1PointAffine,

    pub fn deinit(self: VerificationKey, allocator: std.mem.Allocator) void {
        allocator.free(self.ic);
    }
};

fn findFieldArrayStart(vk_json: []const u8, field_name: []const u8) ?usize {
    const key = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field_name}) catch return null;
    defer std.heap.page_allocator.free(key);
    const start = std.mem.indexOf(u8, vk_json, key) orelse return null;
    var i = start + key.len;
    // Skip whitespace and colon
    while (i < vk_json.len and (vk_json[i] == ' ' or vk_json[i] == '\t' or vk_json[i] == '\n' or vk_json[i] == '\r' or vk_json[i] == ':')) : (i += 1) {}
    if (i >= vk_json.len or vk_json[i] != '[') return null;
    return i + 1; // return position after '['
}

fn parseVKFieldG1(allocator: std.mem.Allocator, vk_json: []const u8, field_name: []const u8) !curve.G1PointAffine {
    const content_start = findFieldArrayStart(vk_json, field_name) orelse return error.InvalidJson;
    const end = findMatchingBracket(vk_json, content_start) orelse return error.InvalidJson;
    return try parseG1Decimal(allocator, vk_json[content_start..end]);
}

fn parseVKFieldG2(allocator: std.mem.Allocator, vk_json: []const u8, field_name: []const u8) !curve.G2PointAffine {
    const content_start = findFieldArrayStart(vk_json, field_name) orelse return error.InvalidJson;
    const end = findMatchingBracket(vk_json, content_start) orelse return error.InvalidJson;
    return try parseG2Decimal(allocator, vk_json[content_start..end]);
}

pub fn parseVerificationKey(allocator: std.mem.Allocator, vk_json: []const u8) !VerificationKey {
    const alpha1 = try parseVKFieldG1(allocator, vk_json, "vk_alpha_1");
    const beta2 = try parseVKFieldG2(allocator, vk_json, "vk_beta_2");
    const gamma2 = try parseVKFieldG2(allocator, vk_json, "vk_gamma_2");
    const delta2 = try parseVKFieldG2(allocator, vk_json, "vk_delta_2");

    // Parse IC array
    const ic_content_start = findFieldArrayStart(vk_json, "IC") orelse return error.InvalidJson;
    const ic_end = findMatchingBracket(vk_json, ic_content_start) orelse return error.InvalidJson;
    const ic_content = vk_json[ic_content_start..ic_end];

    const ic_parts = try splitArrayElements(allocator, ic_content);
    defer {
        for (ic_parts) |p| allocator.free(p);
        allocator.free(ic_parts);
    }

    var ic = try allocator.alloc(curve.G1PointAffine, ic_parts.len);
    errdefer allocator.free(ic);

    for (ic_parts, 0..) |part, i| {
        ic[i] = try parseG1Decimal(allocator, part);
    }

    return VerificationKey{
        .alpha1 = alpha1,
        .beta2 = beta2,
        .gamma2 = gamma2,
        .delta2 = delta2,
        .ic = ic,
    };
}

// ============================================================================
// Verification
// ============================================================================

pub fn verify(
    allocator: std.mem.Allocator,
    vk_json: []const u8,
    proof_json: []const u8,
    public_json: []const u8,
) !bool {
    const vk = try parseVerificationKey(allocator, vk_json);
    defer vk.deinit(allocator);

    const proof = try parseProof(allocator, proof_json);
    const public_signals = try parsePublicSignals(allocator, public_json);
    defer allocator.free(public_signals);

    const n_public = public_signals.len;
    if (vk.ic.len != n_public + 1) return error.PublicInputMismatch;

    // Compute public_combo = IC[0] + sum(public[i] * IC[i+1])
    var public_combo: curve.G1Point = undefined;
    if (n_public == 0) {
        public_combo = curve.g1_affine_to_projective(vk.ic[0]);
    } else {
        const ic_points = vk.ic[1..];
        const msm_result = try msm.msm_g1(allocator, ic_points, public_signals);
        public_combo = curve.g1_add(msm_result, curve.g1_affine_to_projective(vk.ic[0]));
    }

    // Pairing check: e(A, B) == e(alpha, beta) * e(public_combo, gamma) * e(C, delta)
    const lhs = pairing.ate_pairing(proof.pi_a, proof.pi_b);
    const rhs1 = pairing.ate_pairing(curve.g1_affine_to_projective(vk.alpha1), curve.g2_affine_to_projective(vk.beta2));
    const rhs2 = pairing.ate_pairing(public_combo, curve.g2_affine_to_projective(vk.gamma2));
    const rhs3 = pairing.ate_pairing(proof.pi_c, curve.g2_affine_to_projective(vk.delta2));

    const rhs = pairing.fq12_mul(pairing.fq12_mul(rhs1, rhs2), rhs3);


    return pairing.fq12_eq(lhs, rhs);
}

// ============================================================================
// Tests
// ============================================================================

test "decimal parsing known value" {
    // vk_alpha_1 x from verification_key.json
    const val = try decimalToElement("20491192805390485299153009773594534940189261866228447918068658471970481763042");
    // Sanity check: value is non-zero and fits
    try std.testing.expect(val[0] != 0 or val[1] != 0 or val[2] != 0 or val[3] != 0);

    // Verify it matches the hex equivalent
    const hex_val = field.fq_toMont(val);
    const norm = field.fq_fromMont(hex_val);
    try std.testing.expect(field.fq_eq(norm, val));
}

test "parse verification key" {
    const testdata = @import("testdata");
    const vk = try parseVerificationKey(std.testing.allocator, testdata.VK);
    defer vk.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), vk.ic.len);
}

test "parse proof decimal" {
    const proof_data = @embedFile("../../testdata/proofs/proof.json");
    const proof = try parseProof(std.testing.allocator, proof_data);
    _ = proof;
}

test "parse public signals" {
    const public_data = @embedFile("../../testdata/proofs/public.json");
    const signals = try parsePublicSignals(std.testing.allocator, public_data);
    defer std.testing.allocator.free(signals);
    try std.testing.expectEqual(@as(usize, 1), signals.len);
}

test "verify known proof" {
    const testdata = @import("testdata");
    const proof_data = @embedFile("../../testdata/proofs/proof.json");
    const public_data = @embedFile("../../testdata/proofs/public.json");

    const result = try verify(std.testing.allocator, testdata.VK, proof_data, public_data);
    try std.testing.expect(result);
}

test "verify alternate known proof" {
    const testdata = @import("testdata");
    const proof_data = @embedFile("../../testdata/proofs/known_proof.json");
    const public_data = @embedFile("../../testdata/proofs/known_public.json");

    const result = try verify(std.testing.allocator, testdata.VK, proof_data, public_data);
    try std.testing.expect(result);
}

test "verify ref proof r0 s0" {
    const testdata = @import("testdata");
    const proof_data = @embedFile("../../testdata/proofs/ref_proof_r0_s0.json");
    const public_data = @embedFile("../../testdata/proofs/ref_public_r0_s0.json");

    const result = try verify(std.testing.allocator, testdata.VK, proof_data, public_data);
    try std.testing.expect(result);
}

test "verify known proof 2" {
    const testdata = @import("testdata");
    const proof_data = @embedFile("../../testdata/proofs/known_proof2.json");
    const public_data = @embedFile("../../testdata/proofs/known_public2.json");

    const result = try verify(std.testing.allocator, testdata.VK, proof_data, public_data);
    try std.testing.expect(result);
}
