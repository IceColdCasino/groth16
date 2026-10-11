const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const metal = gpu.metal;
const field = cpu.field;
const curve = cpu.curve;

// ============================================================================
// Comprehensive Metal Per-Kernel TDD Tests
// Each test runs a specific Metal kernel and compares with CPU computation.
// ============================================================================

fn g1AffineToBytes(pt: curve.G1PointAffine) [64]u8 {
    var bytes: [64]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], pt.x[0], .little);
    std.mem.writeInt(u64, bytes[8..16], pt.x[1], .little);
    std.mem.writeInt(u64, bytes[16..24], pt.x[2], .little);
    std.mem.writeInt(u64, bytes[24..32], pt.x[3], .little);
    std.mem.writeInt(u64, bytes[32..40], pt.y[0], .little);
    std.mem.writeInt(u64, bytes[40..48], pt.y[1], .little);
    std.mem.writeInt(u64, bytes[48..56], pt.y[2], .little);
    std.mem.writeInt(u64, bytes[56..64], pt.y[3], .little);
    return bytes;
}

fn g1ProjectiveToBytes(pt: curve.G1Point) [128]u8 {
    var bytes: [128]u8 = undefined;
    for (0..4) |i| {
        std.mem.writeInt(u64, bytes[i * 8 ..][0..8], pt.x[i], .little);
    }
    for (0..4) |i| {
        std.mem.writeInt(u64, bytes[32 + i * 8 ..][0..8], pt.y[i], .little);
    }
    for (0..4) |i| {
        std.mem.writeInt(u64, bytes[64 + i * 8 ..][0..8], pt.zz[i], .little);
    }
    for (0..4) |i| {
        std.mem.writeInt(u64, bytes[96 + i * 8 ..][0..8], pt.zzz[i], .little);
    }
    return bytes;
}

fn g2AffineToBytes(pt: curve.G2PointAffine) [128]u8 {
    var bytes: [128]u8 = undefined;
    // x = [a0, a1, a2, a3, b0, b1, b2, b3]
    for (0..4) |i| {
        std.mem.writeInt(u64, bytes[i * 8 ..][0..8], pt.x.a[i], .little);
    }
    for (0..4) |i| {
        std.mem.writeInt(u64, bytes[32 + i * 8 ..][0..8], pt.x.b[i], .little);
    }
    // y = [a0, a1, a2, a3, b0, b1, b2, b3]
    for (0..4) |i| {
        std.mem.writeInt(u64, bytes[64 + i * 8 ..][0..8], pt.y.a[i], .little);
    }
    for (0..4) |i| {
        std.mem.writeInt(u64, bytes[96 + i * 8 ..][0..8], pt.y.b[i], .little);
    }
    return bytes;
}

fn metalG1PointToCpu(pt: gpu.G1Point) curve.G1Point {
    return .{
        .x = pt.x,
        .y = pt.y,
        .zz = pt.zz,
        .zzz = pt.zzz,
    };
}

fn metalG2PointToCpu(pt: gpu.G2Point) curve.G2Point {
    return .{
        .x = .{ .a = pt.x[0..4].*, .b = pt.x[4..8].* },
        .y = .{ .a = pt.y[0..4].*, .b = pt.y[4..8].* },
        .zz = .{ .a = pt.zz[0..4].*, .b = pt.zz[4..8].* },
        .zzz = .{ .a = pt.zzz[0..4].*, .b = pt.zzz[4..8].* },
    };
}

// ---------------------------------------------------------------------------
// g1_add
// ---------------------------------------------------------------------------

test "metal: g1_add matches CPU" {
    if (@import("builtin").os.tag != .macos) return;
    const allocator = std.testing.allocator;

    const g = curve.g1_generator();
    const g_affine = curve.G1PointAffine{ .x = g.x, .y = g.y };
    const two = field.fr_toMont(field.fr_from_u64(2));
    const g2 = curve.g1_mul(g, two);
    const g2_affine = curve.G1PointAffine{ .x = g2.x, .y = g2.y };

    const a_bytes = g1AffineToBytes(g_affine);
    const b_bytes = g1AffineToBytes(g2_affine);

    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();

    const metal_result = try prover.testG1AddAffine(&a_bytes, &b_bytes);
    const metal_pt = metalG1PointToCpu(metal_result);

    const cpu_pa = curve.g1_affine_to_projective(g_affine);
    const cpu_pb = curve.g1_affine_to_projective(g2_affine);
    const cpu_result = curve.g1_add(cpu_pa, cpu_pb);

    try std.testing.expect(curve.g1_eq(metal_pt, cpu_result));
}

// ---------------------------------------------------------------------------
// g1_dbl
// ---------------------------------------------------------------------------

test "metal: g1_dbl matches CPU" {
    if (@import("builtin").os.tag != .macos) return;
    const allocator = std.testing.allocator;

    const g = curve.g1_generator();
    const g_proj = curve.g1_affine_to_projective(curve.G1PointAffine{ .x = g.x, .y = g.y });
    const g_bytes = g1ProjectiveToBytes(g_proj);

    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();

    const metal_result = try prover.testG1Dbl(&g_bytes);
    const metal_pt = metalG1PointToCpu(metal_result);

    const cpu_result = curve.g1_dbl(g_proj);

    try std.testing.expect(curve.g1_eq(metal_pt, cpu_result));
}

// ---------------------------------------------------------------------------
// g2_add
// ---------------------------------------------------------------------------

test "metal: g2_add matches CPU" {
    if (@import("builtin").os.tag != .macos) return;
    const allocator = std.testing.allocator;

    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const two = field.fr_toMont(field.fr_from_u64(2));
    const g2_2 = curve.g2_mul(g2, two);
    const g2_2_affine = curve.G2PointAffine{ .x = g2_2.x, .y = g2_2.y };

    const a_bytes = g2AffineToBytes(g2_affine);
    const b_bytes = g2AffineToBytes(g2_2_affine);

    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();

    const metal_result = try prover.testG2AddInline(&a_bytes, &b_bytes);
    const metal_pt = metalG2PointToCpu(metal_result);

    const cpu_pa = curve.g2_affine_to_projective(g2_affine);
    const cpu_pb = curve.g2_affine_to_projective(g2_2_affine);
    const cpu_result = curve.g2_add(cpu_pa, cpu_pb);

    try std.testing.expect(curve.g2_eq(metal_pt, cpu_result));
}

// ---------------------------------------------------------------------------
// g2_dbl
// ---------------------------------------------------------------------------

test "metal: g2_dbl matches CPU" {
    if (@import("builtin").os.tag != .macos) return;
    const allocator = std.testing.allocator;

    const g2 = curve.g2_generator();
    const g2_affine = curve.G2PointAffine{ .x = g2.x, .y = g2.y };
    const g2_bytes = g2AffineToBytes(g2_affine);

    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();

    const metal_result = try prover.testG2Dbl(&g2_bytes);
    const metal_pt = metalG2PointToCpu(metal_result);

    const cpu_pa = curve.g2_affine_to_projective(g2_affine);
    const cpu_result = curve.g2_dbl(cpu_pa);

    try std.testing.expect(curve.g2_eq(metal_pt, cpu_result));
}

// ---------------------------------------------------------------------------
// fq_mul (field multiplication — same limb pattern as fr_mul)
// ---------------------------------------------------------------------------

test "metal: fq_mul matches CPU" {
    if (@import("builtin").os.tag != .macos) return;
    const allocator = std.testing.allocator;

    const a = field.fr_toMont(field.fr_from_u64(123456789));
    const b = field.fr_toMont(field.fr_from_u64(987654321));

    var prover = try metal.MetalProver.init(allocator);
    defer prover.deinit();

    const metal_result = try prover.testFqOp("test_fq_mul", a, b);

    const cpu_result = field.fq_mul(a, b);

    try std.testing.expect(field.fq_eq(metal_result, cpu_result));
}
