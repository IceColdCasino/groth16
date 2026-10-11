const std = @import("std");
const field = @import("../field.zig");
const curve = @import("../curve.zig");
const json = @import("../json.zig");
const parser = @import("../parser.zig");

pub const ProofResult = struct {
    proof_json: []u8,
    public_json: []u8,

    pub fn deinit(self: *ProofResult, allocator: std.mem.Allocator) void {
        allocator.free(self.proof_json);
        allocator.free(self.public_json);
    }
};

fn readFq(bytes: []const u8) field.FqElement {
    var result: field.FqElement = undefined;
    for (0..4) |i| {
        result[i] = std.mem.readInt(u64, bytes[i * 8 ..][0..8], .little);
    }
    return result;
}

fn readG1Affine(bytes: []const u8) curve.G1PointAffine {
    return .{
        .x = readFq(bytes[0..32]),
        .y = readFq(bytes[32..64]),
    };
}

fn readG2Affine(bytes: []const u8) curve.G2PointAffine {
    return .{
        .x = .{ .a = readFq(bytes[0..32]), .b = readFq(bytes[32..64]) },
        .y = .{ .a = readFq(bytes[64..96]), .b = readFq(bytes[96..128]) },
    };
}

pub fn assembleProof(
    allocator: std.mem.Allocator,
    zkey_data: []const u8,
    wtns_data: []const u8,
    pi_a: curve.G1Point,
    pi_b: curve.G2Point,
    pib1: curve.G1Point,
    pi_c: curve.G1Point,
    pih: curve.G1Point,
    r: field.FrElement,
    s: field.FrElement,
) !ProofResult {
    // 1. Parse zkey for VK points
    var zkey = try parser.parseZkey(allocator, zkey_data);
    defer zkey.deinit(allocator);

    const sec2 = zkey.getSection(2) orelse return error.MissingSection;
    const n8q = zkey.header.n8;
    const n8r = zkey.header.n8r;
    const nPublic = zkey.header.nPublic;

    // Header fields before VK points:
    // n8q(4) + q(n8q) + n8r(4) + r(n8r) + nVars(4) + nPublic(4) + domainSize(4)
    const vk_offset = 20 + n8q + n8r;
    const vk_total_size = n8q * 2 + n8q * 2 + n8q * 4 + n8q * 4 + n8q * 2 + n8q * 4;
    if (sec2.len < vk_offset + vk_total_size) return error.InvalidZkeyHeader;

    const vk_data = sec2[vk_offset..];

    // Read VK points: alpha1, beta1, beta2, (skip gamma2), delta1, delta2
    const alpha1 = readG1Affine(vk_data[0 .. n8q * 2]);
    const beta1 = readG1Affine(vk_data[n8q * 2 .. n8q * 4]);
    const beta2 = readG2Affine(vk_data[n8q * 4 .. n8q * 8]);
    // gamma2 occupies n8q * 8 .. n8q * 12, not needed for proof assembly
    const delta1 = readG1Affine(vk_data[n8q * 12 .. n8q * 14]);
    const delta2 = readG2Affine(vk_data[n8q * 14 .. n8q * 18]);

    // Use provided r, s (caller controls randomization — CPU prover uses r=s=0)

    // 3. Randomization
    // pi_a = pi_a + alpha1 + r*delta1
    var pi_a_final = pi_a;
    pi_a_final = curve.g1_add(pi_a_final, curve.g1_affine_to_projective(alpha1));
    pi_a_final = curve.g1_add(pi_a_final, curve.g1_mul(curve.g1_affine_to_projective(delta1), r));

    // pi_b = pi_b + beta2 + s*delta2
    var pi_b_final = pi_b;
    pi_b_final = curve.g2_add(pi_b_final, curve.g2_affine_to_projective(beta2));
    pi_b_final = curve.g2_add(pi_b_final, curve.g2_mul(curve.g2_affine_to_projective(delta2), s));

    // pib1 = pib1 + beta1 + s*delta1
    var pib1_final = pib1;
    pib1_final = curve.g1_add(pib1_final, curve.g1_affine_to_projective(beta1));
    pib1_final = curve.g1_add(pib1_final, curve.g1_mul(curve.g1_affine_to_projective(delta1), s));

    // pi_c = pi_c + pih + s*pi_a + r*pib1 - r*s*delta1
    // NOTE: must use randomized pi_a_final and pib1_final, not the raw MSM results
    var pi_c_final = pi_c;
    pi_c_final = curve.g1_add(pi_c_final, pih);
    const s_pi_a = curve.g1_mul(pi_a_final, s);
    pi_c_final = curve.g1_add(pi_c_final, s_pi_a);
    const r_pib1 = curve.g1_mul(pib1_final, r);
    pi_c_final = curve.g1_add(pi_c_final, r_pib1);

    const r_mont = field.fr_toMont(r);
    const s_mont = field.fr_toMont(s);
    const rs_mont = field.fr_mul(r_mont, s_mont);
    const rs = field.fr_fromMont(rs_mont);
    const rs_delta1 = curve.g1_mul(curve.g1_affine_to_projective(delta1), rs);
    pi_c_final = curve.g1_add(pi_c_final, curve.g1_neg(rs_delta1));

    // 4. Assemble proof
    const proof = json.Proof{
        .pi_a = pi_a_final,
        .pi_b = pi_b_final,
        .pi_c = pi_c_final,
    };
    const proof_json = try json.proofToString(allocator, proof);

    // 5. Extract public signals
    var wtns = try parser.parseWitness(allocator, wtns_data);
    defer wtns.deinit(allocator);

    const n_witness_elems = wtns.data.len / @sizeOf(field.FrElement);
    const witness_fr = try allocator.alloc(field.FrElement, n_witness_elems);
    defer allocator.free(witness_fr);
    @memcpy(std.mem.sliceAsBytes(witness_fr), wtns.data);
    if (witness_fr.len < nPublic + 1) return error.InvalidWitness;
    const public_signals = witness_fr[1 .. nPublic + 1];
    const public_json = try json.publicToString(allocator, public_signals);

    return ProofResult{
        .proof_json = proof_json,
        .public_json = public_json,
    };
}

test "assemble proof compiles and runs" {
    const testdata = @import("rapidsnark_testdata");

    const pi_a = curve.g1_zero();
    const pi_b = curve.g2_zero();
    const pib1 = curve.g1_zero();
    const pi_c = curve.g1_zero();
    const pih = curve.g1_zero();

    const r = field.fr_zero();
    const s = field.fr_zero();
    var result = try assembleProof(std.testing.allocator, testdata.ZKEY, testdata.WTNS, pi_a, pi_b, pib1, pi_c, pih, r, s);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.proof_json, "pi_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.proof_json, "pi_b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.proof_json, "pi_c") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.proof_json, "protocol") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.public_json, "[") != null);
}
