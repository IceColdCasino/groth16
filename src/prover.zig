const std = @import("std");
const parser = @import("parser.zig");
const field = @import("field.zig");
const curve = @import("curve.zig");
const fft = @import("fft.zig");
const msm = @import("msm.zig");
const json = @import("json.zig");
const random = @import("random.zig");
const qap = @import("gpu/qap.zig");
const verifier = @import("verifier.zig");
const pairing = @import("pairing.zig");

pub const ProverError = error{
    InvalidZkey,
    InvalidWitness,
    MissingSection,
    InvalidZkeyHeader,
    OutOfMemory,
    DomainTooLarge,
    FileTooShort,
    InvalidMagic,
    InvalidVersion,
    InvalidSectionSize,
    MissingHeaderSection,
    HeaderTooShort,
    FieldTooLarge,
    MissingCoefficientsSection,
    MissingDataSection,
    InvalidWtns,
    InvalidWitnessLength,
};

pub const ProofResult = struct {
    proof_json: []u8,
    public_json: []u8,

    pub fn deinit(self: *ProofResult, allocator: std.mem.Allocator) void {
        allocator.free(self.proof_json);
        allocator.free(self.public_json);
    }
};

// ============================================================================
// Point parsing helpers
// ============================================================================

pub fn readFq(bytes: []const u8) field.FqElement {
    var result: field.FqElement = undefined;
    for (0..4) |i| {
        result[i] = std.mem.readInt(u64, bytes[i * 8 ..][0..8], .little);
    }
    return result;
}

pub fn readG1(bytes: []const u8) curve.G1PointAffine {
    // Zkey stores G1 points in Montgomery form
    return .{
        .x = readFq(bytes[0..32]),
        .y = readFq(bytes[32..64]),
    };
}

pub fn readG2(bytes: []const u8) curve.G2PointAffine {
    // Zkey stores G2 points in Montgomery form
    return .{
        .x = .{ .a = readFq(bytes[0..32]), .b = readFq(bytes[32..64]) },
        .y = .{ .a = readFq(bytes[64..96]), .b = readFq(bytes[96..128]) },
    };
}

pub fn parseG1Points(allocator: std.mem.Allocator, zkey: parser.Zkey, section_id: u32, n_points: u32) ![]curve.G1PointAffine {
    const section = zkey.getSection(section_id) orelse return error.MissingSection;
    const expected_size = @as(usize, n_points) * 64;
    if (section.len < expected_size) return error.InvalidZkey;

    const points = try allocator.alloc(curve.G1PointAffine, n_points);
    for (0..n_points) |i| {
        const offset = i * 64;
        points[i] = readG1(section[offset..]);
    }
    return points;
}

pub fn parseG2Points(allocator: std.mem.Allocator, zkey: parser.Zkey, section_id: u32, n_points: u32) ![]curve.G2PointAffine {
    const section = zkey.getSection(section_id) orelse return error.MissingSection;
    const expected_size = @as(usize, n_points) * 128;
    if (section.len < expected_size) return error.InvalidZkey;

    const points = try allocator.alloc(curve.G2PointAffine, n_points);
    for (0..n_points) |i| {
        const offset = i * 128;
        points[i] = readG2(section[offset..]);
    }
    return points;
}

// ============================================================================
// Verification key parsing
// ============================================================================

const VerificationKey = struct {
    alpha1: curve.G1PointAffine,
    beta1: curve.G1PointAffine,
    beta2: curve.G2PointAffine,
    delta1: curve.G1PointAffine,
    delta2: curve.G2PointAffine,
};

fn parseVerificationKey(zkey: parser.Zkey) !VerificationKey {
    const section2 = zkey.getSection(2) orelse return error.MissingSection;
    const n8q = zkey.header.n8;
    const n8r = zkey.header.n8r;
    const vk_offset = 20 + n8q + n8r;
    // VK layout: alpha1(2*n8q) + beta1(2*n8q) + beta2(4*n8q) + gamma2(4*n8q) + delta1(2*n8q) + delta2(4*n8q)
    const vk_total_size = n8q * 2 + n8q * 2 + n8q * 4 + n8q * 4 + n8q * 2 + n8q * 4;
    if (section2.len < vk_offset + vk_total_size) return error.InvalidZkeyHeader;

    const vk_data = section2[vk_offset..];

    return VerificationKey{
        .alpha1 = readG1(vk_data[0 .. n8q * 2]),
        .beta1 = readG1(vk_data[n8q * 2 .. n8q * 4]),
        .beta2 = readG2(vk_data[n8q * 4 .. n8q * 8]),
        .delta1 = readG1(vk_data[n8q * 12 .. n8q * 14]),
        .delta2 = readG2(vk_data[n8q * 14 .. n8q * 18]),
    };
}

// ============================================================================
// G2 MSM (simple O(n) scalar multiplication and addition)
// ============================================================================

fn msmG2(allocator: std.mem.Allocator, points: []const curve.G2PointAffine, scalars: []const field.FrElement) !curve.G2Point {
    return try msm.msm_g2(allocator, points, scalars);
}

// ============================================================================
// H polynomial computation (naive O(n^2) multiplication)
// ============================================================================

/// Compute D = A*B - C evaluated on the coset, matching rapidsnark's approach.
/// The zkey stores `pointsH` as the Lagrange basis for the coset, so we return
/// evaluations (not coefficients) for direct MSM with pointsH.
pub fn calculateH(
    allocator: std.mem.Allocator,
    a_eval: []const field.FrElement,
    b_eval: []const field.FrElement,
    c_eval: []const field.FrElement,
    domain_size: u32,
) ![]field.FrElement {
    if (domain_size == 0) {
        return &[_]field.FrElement{};
    }

    // 1. Convert from evaluation form to coefficient form via IFFT (Montgomery)
    const a = try allocator.dupe(field.FrElement, a_eval);
    const b = try allocator.dupe(field.FrElement, b_eval);
    const c = try allocator.dupe(field.FrElement, c_eval);
    defer allocator.free(a);
    defer allocator.free(b);
    defer allocator.free(c);

    fft.ifft_fr(a, domain_size);
    fft.ifft_fr(b, domain_size);
    fft.ifft_fr(c, domain_size);

    // 2. Shift coefficients to coset domain by multiplying with g^i
    // where g is the 2n-th primitive root of unity
    const g = switch (domain_size) {
        1024 => fft.FR_OMEGA_2048,
        2048 => fft.FR_OMEGA_4096,
        4096 => fft.FR_OMEGA_8192,
        8192 => fft.FR_OMEGA_16384,
        16384 => fft.FR_OMEGA_32768,
        32768 => fft.FR_OMEGA_65536,
        65536 => fft.FR_OMEGA_131072,
        131072 => fft.FR_OMEGA_262144,
        262144 => fft.FR_OMEGA_524288,
        524288 => fft.FR_OMEGA_1048576,
        1048576 => fft.FR_OMEGA_2097152,
        2097152 => fft.FR_OMEGA_4194304,
        4194304 => fft.FR_OMEGA_8388608,
        else => {
            std.debug.assert(@popCount(domain_size) == 1);
            std.debug.panic("Unsupported domain size for coset shift: {d}", .{domain_size});
        },
    };
    fft.shiftCoefficients(a, domain_size, g);
    fft.shiftCoefficients(b, domain_size, g);
    fft.shiftCoefficients(c, domain_size, g);

    // 3. FFT back to evaluation form on the coset (Montgomery)
    fft.fft_fr(a, domain_size);
    fft.fft_fr(b, domain_size);
    fft.fft_fr(c, domain_size);


    // 4. Pointwise multiply/subtract: D[i] = A[i]*B[i] - C[i] (Montgomery)
    // pointsH in the zkey already includes the Z(x) = -2 factor from the trusted setup,
    // so we use A*B - C directly without dividing by -2.
    const h = try allocator.alloc(field.FrElement, domain_size);
    for (0..domain_size) |i| {
        const ab = field.fr_mul(a[i], b[i]);
        h[i] = field.fr_sub(ab, c[i]);
        // Convert to normal form for MSM (matches rapidsnark's fromMontgomery)
        h[i] = field.fr_fromMont(h[i]);
    }

    return h;
}

// ============================================================================
// Main prove function
// ============================================================================

pub const ProveOptions = struct {
    r: ?field.FrElement = null,
    s: ?field.FrElement = null,
};

pub fn prove(
    allocator: std.mem.Allocator,
    zkey_data: []const u8,
    wtns_data: []const u8,
    options: ProveOptions,
) ProverError!ProofResult {
    // 1. Parse zkey + witness
    var zkey = try parser.parseZkey(allocator, zkey_data);
    defer zkey.deinit(allocator);
    var wtns = try parser.parseWitness(allocator, wtns_data);
    defer wtns.deinit(allocator);

    const nVars = zkey.header.nVars;
    const nPublic = zkey.header.nPublic;
    const domainSize = zkey.header.domainSize;

    if (nVars == 0 or domainSize == 0) {
        return error.InvalidZkey;
    }

    // Derive QAP info from parsed zkey to avoid re-parsing in buildQap
    const sec4 = zkey.getSection(4) orelse return error.MissingSection;
    const sec9 = zkey.getSection(9) orelse return error.MissingSection;
    const qap_info = qap.ZkeyInfo{
        .n_vars = zkey.header.nVars,
        .n_public = zkey.header.nPublic,
        .domain_size = zkey.header.domainSize,
        .n8r = zkey.header.n8r,
        .sec4_offset = @intFromPtr(sec4.ptr) - @intFromPtr(zkey_data.ptr),
        .sec4_size = sec4.len,
        .sec9_offset = @intFromPtr(sec9.ptr) - @intFromPtr(zkey_data.ptr),
        .sec9_size = sec9.len,
    };

    // 2. Build QAP (with pre-parsed info to avoid redundant zkey parsing)
    const qap_result = try qap.buildQapWithInfo(allocator, zkey_data, wtns_data, qap_info);
    defer {
        allocator.free(qap_result.a);
        allocator.free(qap_result.b);
        allocator.free(qap_result.c);
        allocator.free(qap_result.points_h);
    }

    // 3. Extract witness as aligned FrElement slice (normal form)
    const n_witness_elems = wtns.data.len / @sizeOf(field.FrElement);
    const witness_fr = try allocator.alloc(field.FrElement, n_witness_elems);
    defer allocator.free(witness_fr);
    @memcpy(std.mem.sliceAsBytes(witness_fr), wtns.data);
    if (witness_fr.len < nVars) return error.InvalidWitness;

    // 4. Parse points from zkey
    const points_a = try parseG1Points(allocator, zkey, 5, nVars);
    defer allocator.free(points_a);
    const points_b1 = try parseG1Points(allocator, zkey, 6, nVars);
    defer allocator.free(points_b1);
    const points_b2 = try parseG2Points(allocator, zkey, 7, nVars);
    defer allocator.free(points_b2);

    const n_private = if (nVars > nPublic + 1) nVars - nPublic - 1 else 0;
    const points_c = if (n_private > 0)
        try parseG1Points(allocator, zkey, 8, n_private)
    else
        try allocator.alloc(curve.G1PointAffine, 0);
    defer allocator.free(points_c);

    const points_h = try parseG1Points(allocator, zkey, 9, domainSize);
    defer allocator.free(points_h);

    // 5. Parse VK elements
    const vk = try parseVerificationKey(zkey);

    // 6. Compute H polynomial
    // QAP result already contains []FrElement - no copy needed!
    const h_coeffs = try calculateH(allocator, qap_result.a, qap_result.b, qap_result.c, domainSize);
    defer allocator.free(h_coeffs);

    // 7. MSMs on all variables (unrandomized)

    const pi_a_unrand = try msm.msm_g1(allocator, points_a, witness_fr[0..nVars]);
    const pib1_unrand = try msm.msm_g1(allocator, points_b1, witness_fr[0..nVars]);
    const pi_b_unrand = try msmG2(allocator, points_b2, witness_fr[0..nVars]);

    const pi_c_scalars = witness_fr[nPublic + 1 .. nVars];
    const pi_c_unrand = if (n_private > 0)
        try msm.msm_g1(allocator, points_c, pi_c_scalars)
    else
        curve.g1_zero();



    const pih = try msm.msm_g1(allocator, points_h, h_coeffs);


    // Use provided r, s or default to zero for backward compatibility
    const r = options.r orelse field.fr_zero();
    const s = options.s orelse field.fr_zero();
    const r_mont = field.fr_toMont(r);
    const s_mont = field.fr_toMont(s);
    const rs = field.fr_fromMont(field.fr_mul(r_mont, s_mont));

    // 9. Randomize pib1: pib1 = pib1_unrand + beta1 + s*delta1
    var pib1 = pib1_unrand;
    pib1 = curve.g1_add(pib1, curve.g1_affine_to_projective(vk.beta1));
    pib1 = curve.g1_add(pib1, curve.g1_mul_affine(vk.delta1, s));

    // pi_a = msm_a + alpha1 + r*delta1
    var pi_a = pi_a_unrand;
    pi_a = curve.g1_add(pi_a, curve.g1_affine_to_projective(vk.alpha1));
    pi_a = curve.g1_add(pi_a, curve.g1_mul_affine(vk.delta1, r));

    // pi_b = msm_b + beta2 + s*delta2
    var pi_b = pi_b_unrand;
    pi_b = curve.g2_add(pi_b, curve.g2_affine_to_projective(vk.beta2));
    pi_b = curve.g2_add(pi_b, curve.g2_mul(curve.g2_affine_to_projective(vk.delta2), s));

    // pi_c = msm_c + H + s*pi_a + r*pib1 - r*s*delta1
    var pi_c = pi_c_unrand;
    pi_c = curve.g1_add(pi_c, pih);
    pi_c = curve.g1_add(pi_c, curve.g1_mul(pi_a, s));
    pi_c = curve.g1_add(pi_c, curve.g1_mul(pib1, r));
    pi_c = curve.g1_add(pi_c, curve.g1_neg(curve.g1_mul_affine(vk.delta1, rs)));

    // 10. Assemble proof JSON
    const proof = json.Proof{ .pi_a = pi_a, .pi_b = pi_b, .pi_c = pi_c };
    const proof_json = try json.proofToString(allocator, proof);
    errdefer allocator.free(proof_json);

    // 11. Extract public signals
    const public_signals = witness_fr[1 .. nPublic + 1];
    const public_json = try json.publicToString(allocator, public_signals);

    return ProofResult{
        .proof_json = proof_json,
        .public_json = public_json,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "prove small circuit" {
    const testdata = @import("rapidsnark_testdata");
    var result = try prove(std.testing.allocator, testdata.ZKEY, testdata.WTNS, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.proof_json, "pi_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.proof_json, "pi_b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.proof_json, "pi_c") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.proof_json, "protocol") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.public_json, "[") != null);

    // Verify the generated proof
    const verified = try verifier.verify(std.testing.allocator, testdata.VK, result.proof_json, result.public_json);
    if (!verified) {
        std.debug.print("\n=== Verification FAILED ===\n", .{});
        std.debug.print("Proof JSON: {s}\n", .{result.proof_json});
        std.debug.print("Public JSON: {s}\n", .{result.public_json});
    }
    try std.testing.expect(verified);
}

test "compare proof with rapidsnark ref" {
    const testdata = @import("rapidsnark_testdata");
    // Load reference proof with r=s=0
    const ref_proof_data = @embedFile("ref_proof_r0_s0.json");
    
    // Parse reference proof
    const ref_proof = try verifier.parseProof(std.testing.allocator, ref_proof_data);
    
    // Generate our proof
    var our_result = try prove(std.testing.allocator, testdata.ZKEY, testdata.WTNS, .{});
    defer our_result.deinit(std.testing.allocator);
    
    // Parse our proof
    const our_proof = try verifier.parseProof(std.testing.allocator, our_result.proof_json);
    
    
    // Compare pi_a
    try std.testing.expect(curve.g1_eq(ref_proof.pi_a, our_proof.pi_a));
    
    // Compare pi_b
    try std.testing.expect(curve.g2_eq(ref_proof.pi_b, our_proof.pi_b));
    
    // Compare pi_c
    try std.testing.expect(curve.g1_eq(ref_proof.pi_c, our_proof.pi_c));
}

// Note: snarkjs proof verification removed because proof_snarkjs.json and public_snarkjs.json
// are not available in the upstream rapidsnark dependency (they are generated by snarkjs, not rapidsnark).




