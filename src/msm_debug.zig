const std = @import("std");
const parser = @import("./parser.zig");
const field = @import("./field.zig");
const curve = @import("./curve.zig");
const msm = @import("./msm.zig");

const c = @cImport({
    @cInclude("stdio.h");
});

fn readFileToBuffer(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = c.fopen(path_z.ptr, "rb");
    if (file == null) return error.FileNotFound;
    defer _ = c.fclose(file);
    _ = c.fseek(file, 0, c.SEEK_END);
    const size = c.ftell(file);
    _ = c.fseek(file, 0, c.SEEK_SET);
    const buf = try allocator.alloc(u8, @intCast(size));
    _ = c.fread(buf.ptr, 1, @intCast(size), file);
    return buf;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    const zkey_data = try readFileToBuffer("../rapidsnark/testdata/circuit_final.zkey", allocator);
    defer allocator.free(zkey_data);
    const witness_data = try readFileToBuffer("../rapidsnark/testdata/witness.wtns", allocator);
    defer allocator.free(witness_data);
    
    var zkey = try parser.parseZkey(allocator, zkey_data);
    defer zkey.deinit(allocator);
    var wtns = try parser.parseWitness(allocator, witness_data);
    defer wtns.deinit(allocator);
    
    const nVars = zkey.header.nVars;
    const nPublic = zkey.header.nPublic;
    const domainSize = zkey.header.domainSize;
    const n8q = zkey.header.n8;
    const n8r = zkey.header.n8r;
    
    const witness_fr = try allocator.alloc(field.FrElement, nVars);
    defer allocator.free(witness_fr);
    @memcpy(std.mem.sliceAsBytes(witness_fr), wtns.data[0..nVars * 32]);
    
    const sec5 = zkey.getSection(5).?;
    var points_a = try allocator.alloc(curve.G1PointAffine, nVars);
    defer allocator.free(points_a);
    for (0..nVars) |i| {
        points_a[i] = readG1(sec5[i*64..][0..64]);
    }
    
    const sec6 = zkey.getSection(6).?;
    var points_b1 = try allocator.alloc(curve.G1PointAffine, nVars);
    defer allocator.free(points_b1);
    for (0..nVars) |i| {
        points_b1[i] = readG1(sec6[i*64..][0..64]);
    }
    
    const sec7 = zkey.getSection(7).?;
    var points_b2 = try allocator.alloc(curve.G2PointAffine, nVars);
    defer allocator.free(points_b2);
    for (0..nVars) |i| {
        points_b2[i] = readG2(sec7[i*128..][0..128]);
    }
    
    const n_private = nVars - nPublic - 1;
    var points_c: []curve.G1PointAffine = &[_]curve.G1PointAffine{};
    if (n_private > 0) {
        const sec8 = zkey.getSection(8);
        if (sec8 != null and sec8.?.len >= n_private * 64) {
            points_c = try allocator.alloc(curve.G1PointAffine, n_private);
            for (0..n_private) |i| {
                points_c[i] = readG1(sec8.?[i*64..][0..64]);
            }
        }
    }
    defer if (points_c.len > 0) allocator.free(points_c);
    
    const sec9 = zkey.getSection(9).?;
    var points_h = try allocator.alloc(curve.G1PointAffine, domainSize);
    defer allocator.free(points_h);
    for (0..domainSize) |i| {
        points_h[i] = readG1(sec9[i*64..][0..64]);
    }
    
    const qap = @import("./gpu/qap.zig");
    const qap_result = try qap.buildQap(allocator, zkey_data, witness_data);
    defer {
        allocator.free(qap_result.a);
        allocator.free(qap_result.b);
        allocator.free(qap_result.c);
        allocator.free(qap_result.points_h);
    }
    
    const fft_mod = @import("./fft.zig");
    // QAP result already contains []FrElement - use directly
    const a_fr = qap_result.a;
    const b_fr = qap_result.b;
    const c_fr = qap_result.c;
    
    fft_mod.ifft_fr(a_fr, domainSize);
    fft_mod.ifft_fr(b_fr, domainSize);
    fft_mod.ifft_fr(c_fr, domainSize);
    
    const n = domainSize;
    const n2 = 2 * n;
    var ab = try allocator.alloc(field.FrElement, n2);
    defer allocator.free(ab);
    @memset(ab, field.fr_zero());
    for (0..n) |i| {
        for (0..n) |j| {
            ab[i + j] = field.fr_add(ab[i + j], field.fr_mul(a_fr[i], b_fr[j]));
        }
    }
    for (0..n) |i| {
        ab[i] = field.fr_sub(ab[i], c_fr[i]);
    }
    
    const h_coeffs = try allocator.alloc(field.FrElement, n);
    defer allocator.free(h_coeffs);
    @memcpy(h_coeffs, ab[n..n2]);
    for (h_coeffs) |*coeff| {
        coeff.* = field.fr_fromMont(coeff.*);
    }
    
    const cpu_pi_a = try msm.msm_g1(allocator, points_a, witness_fr);
    
    const cpu_pib1 = try msm.msm_g1(allocator, points_b1, witness_fr);
    
    const cpu_pi_b = msmG2(points_b2, witness_fr);
    
    const pi_c_scalars = witness_fr[nPublic + 1 .. nVars];
    const cpu_pi_c = if (n_private > 0 and points_c.len > 0)
        try msm.msm_g1(allocator, points_c, pi_c_scalars)
    else
        curve.g1_zero();
    
    const cpu_pih = try msm.msm_g1(allocator, points_h, h_coeffs);
    
    const vk_offset = 20 + n8q + n8r;
    const sec2 = zkey.getSection(2).?;
    const vk_data = sec2[vk_offset..];
    
    var pi_a = cpu_pi_a;
    pi_a = curve.g1_add(pi_a, curve.g1_affine_to_projective(readG1(vk_data[0..64])));
    
    var pib1 = cpu_pib1;
    pib1 = curve.g1_add(pib1, curve.g1_affine_to_projective(readG1(vk_data[n8q*2..][0..64])));
    
    var pi_b = cpu_pi_b;
    pi_b = curve.g2_add(pi_b, curve.g2_affine_to_projective(readG2(vk_data[n8q*4..][0..128])));
    
    var pi_c = cpu_pi_c;
    pi_c = curve.g1_add(pi_c, cpu_pih);
    pi_c = curve.g1_add(pi_c, curve.g1_mul(pi_a, field.fr_zero()));
    pi_c = curve.g1_add(pi_c, curve.g1_mul(pib1, field.fr_zero()));
    
    printG1("pi_a", pi_a);
    printG1("pib1", pib1);
    printG2("pi_b", pi_b);
    printG1("pi_c", pi_c);
}

fn readG1(bytes: []const u8) curve.G1PointAffine {
    var x: field.FqElement = undefined;
    var y: field.FqElement = undefined;
    for (0..4) |i| {
        x[i] = std.mem.readInt(u64, bytes[i*8..][0..8], .little);
        y[i] = std.mem.readInt(u64, bytes[32+i*8..][0..8], .little);
    }
    return .{ .x = x, .y = y };
}

fn readG2(bytes: []const u8) curve.G2PointAffine {
    const xa = readFq(bytes[0..32]);
    const xb = readFq(bytes[32..64]);
    const ya = readFq(bytes[64..96]);
    const yb = readFq(bytes[96..128]);
    return .{
        .x = .{ .a = xa, .b = xb },
        .y = .{ .a = ya, .b = yb },
    };
}

fn readFq(bytes: []const u8) field.FqElement {
    var r: field.FqElement = undefined;
    for (0..4) |i| {
        r[i] = std.mem.readInt(u64, bytes[i*8..][0..8], .little);
    }
    return r;
}

fn msmG2(points: []const curve.G2PointAffine, scalars: []const field.FrElement) curve.G2Point {
    var result = curve.g2_zero();
    for (points, scalars) |pt, scalar| {
        const proj = curve.g2_affine_to_projective(pt);
        const mul_result = curve.g2_mul(proj, scalar);
        result = curve.g2_add(result, mul_result);
    }
    return result;
}

fn printFq(_name: []const u8, _limbs: field.FqElement) void {
    _ = _name;
    _ = _limbs;
}

fn printFr(_name: []const u8, _limbs: field.FrElement) void {
    _ = _name;
    _ = _limbs;
}

fn printG1(_name: []const u8, _p: curve.G1Point) void {
    _ = _name;
    _ = _p;
}

fn printG2(_name: []const u8, _p: curve.G2Point) void {
    _ = _name;
    _ = _p;
}
