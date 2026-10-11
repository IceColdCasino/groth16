const std = @import("std");
const field = @import("cpu").field;
const curve = @import("cpu").curve;

// ============================================================================
// Rapidsnark FFI wrappers
// ============================================================================
//
// rapidsnark's C++ class RawFr::Element is just 32 bytes of raw limbs:
//   struct Element { uint64_t v[4]; };
//
// Our Zig FrElement is [4]u64 = 32 bytes, so it maps 1:1.  No packing needed.

// --- Fr Field ---
pub extern "C" fn rapidsnark_fr_mul(a: *const anyopaque, b: *const anyopaque, out: *anyopaque) void;
pub extern "C" fn rapidsnark_fr_add(a: *const anyopaque, b: *const anyopaque, out: *anyopaque) void;
pub extern "C" fn rapidsnark_fr_sub(a: *const anyopaque, b: *const anyopaque, out: *anyopaque) void;
pub extern "C" fn rapidsnark_fr_fromMontgomery(in: *const anyopaque, out: *anyopaque) void;
pub extern "C" fn rapidsnark_fr_toMontgomery(in: *const anyopaque, out: *anyopaque) void;

// --- Fq Field ---
pub extern "C" fn rapidsnark_fq_mul(a: *const anyopaque, b: *const anyopaque, out: *anyopaque) void;
pub extern "C" fn rapidsnark_fq_add(a: *const anyopaque, b: *const anyopaque, out: *anyopaque) void;

// --- G1 ---
pub extern "C" fn rapidsnark_g1_mul(point: *const anyopaque, scalar: *const anyopaque, out: *anyopaque) void;
pub extern "C" fn rapidsnark_g1_add(a: *const anyopaque, b: *const anyopaque, out: *anyopaque) void;
pub extern "C" fn rapidsnark_g1_dbl(p: *const anyopaque, out: *anyopaque) void;

// --- G2 ---
pub extern "C" fn rapidsnark_g2_mul(point: *const anyopaque, scalar: *const anyopaque, out: *anyopaque) void;
pub extern "C" fn rapidsnark_g2_add(a: *const anyopaque, b: *const anyopaque, out: *anyopaque) void;
pub extern "C" fn rapidsnark_g2_dbl(p: *const anyopaque, out: *anyopaque) void;

// --- FFT ---
pub extern "C" fn rapidsnark_fft_fr(data: *anyopaque, domain_size: u32) void;
pub extern "C" fn rapidsnark_ifft_fr(data: *anyopaque, domain_size: u32) void;
pub extern "C" fn rapidsnark_fft_shift(data: *anyopaque, domain_size: u32) void;

// --- MSM ---
pub extern "C" fn rapidsnark_msm_g1(
    points: *const anyopaque,
    scalars: *const anyopaque,
    n_points: u32,
    scalar_size_bytes: u32,
    out: *anyopaque,
) void;

pub extern "C" fn rapidsnark_msm_g2(
    points: *const anyopaque,
    scalars: *const anyopaque,
    n_points: u32,
    scalar_size_bytes: u32,
    out: *anyopaque,
) void;

// ============================================================================
// Helper wrappers that call rapidsnark and return Zig-native types
// ============================================================================

pub fn frMulRapidsnark(a: field.FrElement, b: field.FrElement) field.FrElement {
    var out: field.FrElement = undefined;
    rapidsnark_fr_mul(&a, &b, &out);
    return out;
}

pub fn frAddRapidsnark(a: field.FrElement, b: field.FrElement) field.FrElement {
    var out: field.FrElement = undefined;
    rapidsnark_fr_add(&a, &b, &out);
    return out;
}

pub fn frSubRapidsnark(a: field.FrElement, b: field.FrElement) field.FrElement {
    var out: field.FrElement = undefined;
    rapidsnark_fr_sub(&a, &b, &out);
    return out;
}

pub fn frFromMontRapidsnark(in: field.FrElement) field.FrElement {
    var out: field.FrElement = undefined;
    rapidsnark_fr_fromMontgomery(&in, &out);
    return out;
}

pub fn frToMontRapidsnark(in: field.FrElement) field.FrElement {
    var out: field.FrElement = undefined;
    rapidsnark_fr_toMontgomery(&in, &out);
    return out;
}

pub fn g1MulRapidsnark(point: curve.G1PointAffine, scalar: field.FrElement) curve.G1Point {
    var out: curve.G1Point = undefined;
    rapidsnark_g1_mul(&point, &scalar, &out);
    return out;
}

pub fn g1AddRapidsnark(a: curve.G1Point, b: curve.G1Point) curve.G1Point {
    var out: curve.G1Point = undefined;
    rapidsnark_g1_add(&a, &b, &out);
    return out;
}

pub fn g1DblRapidsnark(p: curve.G1Point) curve.G1Point {
    var out: curve.G1Point = undefined;
    rapidsnark_g1_dbl(&p, &out);
    return out;
}

pub fn g2MulRapidsnark(point: curve.G2PointAffine, scalar: field.FrElement) curve.G2Point {
    var out: curve.G2Point = undefined;
    rapidsnark_g2_mul(&point, &scalar, &out);
    return out;
}

pub fn g2AddRapidsnark(a: curve.G2Point, b: curve.G2Point) curve.G2Point {
    var out: curve.G2Point = undefined;
    rapidsnark_g2_add(&a, &b, &out);
    return out;
}

pub fn g2DblRapidsnark(p: curve.G2Point) curve.G2Point {
    var out: curve.G2Point = undefined;
    rapidsnark_g2_dbl(&p, &out);
    return out;
}

pub fn msmG1Rapidsnark(_allocator: std.mem.Allocator, points: []const curve.G1PointAffine, scalars: []const field.FrElement, out: *curve.G1Point) void {
    _ = _allocator;
    rapidsnark_msm_g1(
        points.ptr,
        scalars.ptr,
        @intCast(points.len),
        @sizeOf(field.FrElement),
        out,
    );
}

pub fn msmG2Rapidsnark(_allocator: std.mem.Allocator, points: []const curve.G2PointAffine, scalars: []const field.FrElement, out: *curve.G2Point) void {
    _ = _allocator;
    rapidsnark_msm_g2(
        points.ptr,
        scalars.ptr,
        @intCast(points.len),
        @sizeOf(field.FrElement),
        out,
    );
}
