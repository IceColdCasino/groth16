//! BN254 G1/G2 in Jacobian coordinates. a = 0, so the addition formulas do not use b.
const std = @import("std");
const ff = @import("ff.zig");
const Fq = ff.Fq;
const Fq2 = ff.Fq2;

pub const FrMod = ff.Fr.mod_limbs;
pub const FrMinusOne = [4]u64{
    0x43e1f593f0000000,
    0x2833e84879b97091,
    0xb85045b68181585d,
    0x30644e72e131a029,
};
const FrHalf = [4]u64{
    0xa1f0fac9f8000000,
    0x9419f4243cdcb848,
    0xdc2822db40c0ac2e,
    0x183227397098d014,
};

pub const G1 = Group(Fq);
pub const G2 = Group(Fq2);

pub fn g1Generator() G1.Aff {
    return .{ .x = Fq.fromInt(1), .y = Fq.fromInt(2) };
}

pub fn g1B() Fq {
    return Fq.fromInt(3);
}

pub fn g2Generator() G2.Aff {
    return .{
        .x = .{
            .c0 = Fq.fromStd(.{ 0x46debd5cd992f6ed, 0x674322d4f75edadd, 0x426a00665e5c4479, 0x1800deef121f1e76 }),
            .c1 = Fq.fromStd(.{ 0x97e485b7aef312c2, 0xf1aa493335a9e712, 0x7260bfb731fb5d25, 0x198e9393920d483a }),
        },
        .y = .{
            .c0 = Fq.fromStd(.{ 0x4ce6cc0166fa7daa, 0xe3d1e7690c43d37b, 0x4aab71808dcb408f, 0x12c85ea5db8c6deb }),
            .c1 = Fq.fromStd(.{ 0x55acdadcd122975b, 0xbc4b313370b38ef3, 0xec9e99ad690c3395, 0x090689d0585ff075 }),
        },
    };
}

pub fn g2B() Fq2 {
    return .{
        .c0 = Fq.fromStd(.{ 0x3267e6dc24a138e5, 0xb5b4c5e559dbefa3, 0x81be18991be06ac3, 0x2b149d40ceb8aaae }),
        .c1 = Fq.fromStd(.{ 0xe4a2bd0685c315d2, 0xa74fa084e52d1852, 0xcd2cafadeed8fdf4, 0x009713b03af0fed4 }),
    };
}

pub fn scaleG1(base: G1.Aff, k: [4]u64) G1.Jac {
    return mulScalar(Fq, base, k);
}

pub fn scaleG2(base: G2.Aff, k: [4]u64) G2.Jac {
    return mulScalar(Fq2, base, k);
}

pub fn loadG1(bytes: []const u8, index: usize) G1.Aff {
    const o = index * G1.point_len;
    return .{
        .x = .{ .limbs = ff.loadLimbs(bytes[o .. o + 32]) },
        .y = .{ .limbs = ff.loadLimbs(bytes[o + 32 .. o + 64]) },
    };
}

pub fn loadG2(bytes: []const u8, index: usize) G2.Aff {
    const o = index * G2.point_len;
    return .{
        .x = .{
            .c0 = .{ .limbs = ff.loadLimbs(bytes[o .. o + 32]) },
            .c1 = .{ .limbs = ff.loadLimbs(bytes[o + 32 .. o + 64]) },
        },
        .y = .{
            .c0 = .{ .limbs = ff.loadLimbs(bytes[o + 64 .. o + 96]) },
            .c1 = .{ .limbs = ff.loadLimbs(bytes[o + 96 .. o + 128]) },
        },
    };
}

fn Group(comptime F: type) type {
    return struct {
        pub const point_len: usize = 2 * F.encoded_len;

        pub const Aff = struct {
            x: F = .{},
            y: F = .{},

            pub fn isZero(self: Aff) bool {
                return self.x.isZero() and self.y.isZero();
            }

            pub fn neg(self: Aff) Aff {
                return .{ .x = self.x, .y = self.y.neg() };
            }

            pub fn onCurve(self: Aff, b: F) bool {
                if (self.isZero()) return true;
                return self.y.sqr().eql(self.x.sqr().mul(self.x).add(b));
            }

            pub fn store(self: Aff, dst: []u8) void {
                if (self.isZero()) {
                    @memset(dst[0..point_len], 0);
                    return;
                }
                self.x.store(dst[0..F.encoded_len]);
                self.y.store(dst[F.encoded_len..point_len]);
            }
        };

        pub const Jac = struct {
            x: F = .{},
            y: F = .{},
            z: F = .{},

            pub fn isId(self: Jac) bool {
                return self.z.isZero();
            }

            pub fn fromAffine(p: Aff) Jac {
                if (p.isZero()) return .{};
                return .{ .x = p.x, .y = p.y, .z = F.one() };
            }

            pub fn dbl(self: *Jac) void {
                // Field multiply is inlined, so this body contains many comptime loops.
                @setEvalBranchQuota(100_000);
                if (self.z.isZero()) return;
                const x1 = self.x;
                const y1 = self.y;
                const z1 = self.z;
                const a = x1.sqr();
                const b = y1.sqr();
                const c = b.sqr();
                const d = x1.add(b).sqr().sub(a).sub(c).mul2();
                const e = a.mul2().add(a);
                const f = e.sqr();
                const x3 = f.sub(d.mul2());
                const y3 = e.mul(d.sub(x3)).sub(c.mul2().mul2().mul2());
                const z3 = y1.mul2().mul(z1);
                self.* = .{ .x = x3, .y = y3, .z = z3 };
            }

            pub fn addAffine(self: *Jac, p: Aff) void {
                @setEvalBranchQuota(100_000);
                if (p.isZero()) return;
                if (self.z.isZero()) {
                    self.* = fromAffine(p);
                    return;
                }
                const z1z1 = self.z.sqr();
                const uu2 = p.x.mul(z1z1);
                const s2 = p.y.mul(self.z).mul(z1z1);
                const h = uu2.sub(self.x);
                const sdiff = s2.sub(self.y);
                if (h.isZero()) {
                    if (sdiff.isZero()) self.dbl() else self.* = .{};
                    return;
                }
                const hh = h.sqr();
                const i = hh.mul2().mul2();
                const j = h.mul(i);
                const r = sdiff.mul2();
                const v = self.x.mul(i);
                const x3 = r.sqr().sub(j).sub(v.mul2());
                const y3 = r.mul(v.sub(x3)).sub(self.y.mul2().mul(j));
                const z3 = self.z.add(h).sqr().sub(z1z1).sub(hh);
                self.* = .{ .x = x3, .y = y3, .z = z3 };
            }

            pub fn addJac(self: *Jac, o: *const Jac) void {
                @setEvalBranchQuota(100_000);
                if (o.z.isZero()) return;
                if (self.z.isZero()) {
                    self.* = o.*;
                    return;
                }
                const z1z1 = self.z.sqr();
                const z2z2 = o.z.sqr();
                const uu1 = self.x.mul(z2z2);
                const uu2 = o.x.mul(z1z1);
                const s1 = self.y.mul(o.z).mul(z2z2);
                const s2 = o.y.mul(self.z).mul(z1z1);
                const h = uu2.sub(uu1);
                const sdiff = s2.sub(s1);
                if (h.isZero()) {
                    if (sdiff.isZero()) self.dbl() else self.* = .{};
                    return;
                }
                const hh = h.sqr();
                const i = hh.mul2().mul2();
                const j = h.mul(i);
                const r = sdiff.mul2();
                const v = uu1.mul(i);
                const x3 = r.sqr().sub(j).sub(v.mul2());
                const y3 = r.mul(v.sub(x3)).sub(s1.mul2().mul(j));
                const z3 = self.z.add(o.z).sqr().sub(z1z1).sub(z2z2).mul(h);
                self.* = .{ .x = x3, .y = y3, .z = z3 };
            }

            pub fn addMul(self: *Jac, base: Aff, k: [4]u64) void {
                if (base.isZero() or isZeroScalar(k)) return;
                if (isOneScalar(k)) {
                    self.addAffine(base);
                    return;
                }
                if (isNegOneScalar(k)) {
                    self.addAffine(base.neg());
                    return;
                }
                var p = mulScalar(F, base, k);
                self.addJac(&p);
            }

            pub fn toAffine(self: Jac) Aff {
                if (self.z.isZero()) return .{};
                const zinv = self.z.inv();
                const z2 = zinv.sqr();
                return .{
                    .x = self.x.mul(z2),
                    .y = self.y.mul(z2.mul(zinv)),
                };
            }
        };

        pub fn storeJacMany(pts: []const Jac, dst: []u8) void {
            std.debug.assert(dst.len == pts.len * point_len);
            const chunk_n: usize = 1024;
            var off: usize = 0;
            while (off < pts.len) : (off += chunk_n) {
                const n = @min(chunk_n, pts.len - off);
                storeJacChunk(pts[off..][0..n], dst[off * point_len ..][0 .. n * point_len]);
            }
        }

        fn storeJacChunk(pts: []const Jac, dst: []u8) void {
            // libc malloc is thread-safe. These buffers are too big for the main stack when inlined into hashH.
            const idxs = std.heap.c_allocator.alloc(usize, pts.len) catch unreachable;
            defer std.heap.c_allocator.free(idxs);
            const zs = std.heap.c_allocator.alloc(F, pts.len) catch unreachable;
            defer std.heap.c_allocator.free(zs);
            var n: usize = 0;
            for (pts, 0..) |p, i| {
                if (p.z.isZero()) {
                    @memset(dst[i * point_len ..][0..point_len], 0);
                } else {
                    idxs[n] = i;
                    zs[n] = p.z;
                    n += 1;
                }
            }
            batchInv(zs[0..n]);
            for (zs[0..n], idxs[0..n]) |zinv, i| {
                const z2 = zinv.sqr();
                const x = pts[i].x.mul(z2);
                const y = pts[i].y.mul(z2.mul(zinv));
                x.store(dst[i * point_len ..][0..F.encoded_len]);
                y.store(dst[i * point_len + F.encoded_len ..][0..F.encoded_len]);
            }
        }

        fn batchInv(xs: []F) void {
            if (xs.len == 0) return;
            // Prefix products live in a fresh buffer so `xs` stays intact until the back-substitution.
            // Heap, not a 1024-wide stack array: ReleaseFast inlines this into hashH and the frame
            // overruns the main stack.
            const accs = std.heap.c_allocator.alloc(F, xs.len) catch unreachable;
            defer std.heap.c_allocator.free(accs);
            accs[0] = xs[0];
            var i: usize = 1;
            while (i < xs.len) : (i += 1) accs[i] = accs[i - 1].mul(xs[i]);
            var inv = accs[xs.len - 1].inv();
            i = xs.len;
            while (i > 1) {
                i -= 1;
                const this = inv.mul(accs[i - 1]);
                inv = inv.mul(xs[i]);
                xs[i] = this;
            }
            xs[0] = inv;
        }
    };
}

fn isZeroScalar(k: [4]u64) bool {
    return k[0] == 0 and k[1] == 0 and k[2] == 0 and k[3] == 0;
}

fn isOneScalar(k: [4]u64) bool {
    return k[0] == 1 and k[1] == 0 and k[2] == 0 and k[3] == 0;
}

fn isNegOneScalar(k: [4]u64) bool {
    return std.mem.eql(u64, &k, &FrMinusOne);
}

fn gtHalf(k: [4]u64) bool {
    return !ff.gte(FrHalf, k);
}

fn bitAt(k: [4]u64, i: u16) u1 {
    const limb: u6 = @intCast(i / 64);
    const sh: u6 = @intCast(i % 64);
    return @intCast((k[limb] >> sh) & 1);
}

fn highestBit(k: [4]u64) ?u16 {
    var i: usize = 4;
    while (i > 0) {
        i -= 1;
        if (k[i] != 0) return @intCast(i * 64 + 63 - @clz(k[i]));
    }
    return null;
}

fn mulScalar(comptime F: type, base: Group(F).Aff, k_in: [4]u64) Group(F).Jac {
    if (base.isZero()) return .{};
    var k = k_in;
    if (ff.gte(k, FrMod)) k = ff.subLimbs(k, FrMod);
    var flip = false;
    if (gtHalf(k)) {
        k = ff.subLimbs(FrMod, k);
        flip = true;
    }
    const hb = highestBit(k) orelse return .{};
    var acc = if (hb < 48) mulBinary(F, base, k, hb) else mulGlv(F, base, k) orelse mulWindow(F, base, k, hb);
    if (flip) acc.y = acc.y.neg();
    return acc;
}

/// Cube root of unity in Fq. φ(x, y) = (βx, y) is the GLV endomorphism.
const endo_beta = Fq.fromStd(.{
    0xe4bd44e5607cfd48,
    0xc28f069fbb966e3d,
    0x5e6dd9e7e0acccb0,
    0x30644e72e131a029,
});

const C128 = struct { neg: bool, lo: u64, hi: u64 };

const GlvBasis = struct { n11: C128, n12: C128, n21: C128, n22: C128 };

const n_big_a = C128{ .neg = true, .lo = 0x0be4e1541221250b, .hi = 0x6f4d8248eeb859fd };
const n_big_b = C128{ .neg = true, .lo = 0x8211bbeb7d4f1128, .hi = 0x6f4d8248eeb859fc };
const n_small = C128{ .neg = false, .lo = 0x89d3256894d213e3, .hi = 0 };

// Arkworks bn254 GLV bases. `neg` is the sign of the lattice coefficient.
const g1_basis = GlvBasis{
    .n11 = n_big_b,
    .n12 = .{ .neg = false, .lo = n_small.lo, .hi = 0 },
    .n21 = .{ .neg = true, .lo = n_small.lo, .hi = 0 },
    .n22 = n_big_a,
};
const g2_basis = GlvBasis{
    .n11 = n_big_a,
    .n12 = .{ .neg = true, .lo = n_small.lo, .hi = 0 },
    .n21 = n_small,
    .n22 = n_big_b,
};

const Wide = struct { neg: bool, d: [6]u64 };

const Split = struct { neg1: bool, k1: [2]u64, neg2: bool, k2: [2]u64 };

fn endoAff(comptime F: type, p: Group(F).Aff) Group(F).Aff {
    if (F == Fq) return .{ .x = p.x.mul(endo_beta), .y = p.y };
    const x: Fq2 = p.x;
    return .{
        .x = .{ .c0 = x.c0.mul(endo_beta), .c1 = x.c1.mul(endo_beta) },
        .y = p.y,
    };
}

pub const G2GlvIn = struct {
    p1: [128]u8,
    p2: [128]u8,
    scalar: [32]u8,
};

/// Points and the 128-bit scalars for the G2 GLV kernel. Signs are folded into the points.
pub fn prepareG2Glv(base: G2.Aff, k_in: [4]u64) ?G2GlvIn {
    var out = std.mem.zeroes(G2GlvIn);
    if (base.isZero() or isZeroScalar(k_in)) return out;
    var k = k_in;
    var p = base;
    if (ff.gte(k, FrMod)) k = ff.subLimbs(k, FrMod);
    if (gtHalf(k)) {
        k = ff.subLimbs(FrMod, k);
        p = p.neg();
    }
    if (highestBit(k) == null) return out;
    const s = glvSplit(true, k) orelse return null;
    var b1 = p;
    var b2 = endoAff(Fq2, p);
    if (s.neg1) b1 = b1.neg();
    if (s.neg2) b2 = b2.neg();
    b1.store(&out.p1);
    b2.store(&out.p2);
    inline for (0..2) |i| {
        std.mem.writeInt(u64, out.scalar[i * 8 ..][0..8], s.k1[i], .little);
        std.mem.writeInt(u64, out.scalar[16 + i * 8 ..][0..8], s.k2[i], .little);
    }
    return out;
}

fn mulGlv(comptime F: type, base: Group(F).Aff, k: [4]u64) ?Group(F).Jac {
    const G = Group(F);
    const s = glvSplit(F == Fq2, k) orelse return null;
    var b1 = base;
    var b2 = endoAff(F, base);
    if (s.neg1) b1 = b1.neg();
    if (s.neg2) b2 = b2.neg();
    var both = G.Jac.fromAffine(b1);
    both.addAffine(b2);
    var acc: G.Jac = .{};
    var bit: i32 = 127;
    while (bit >= 0) : (bit -= 1) {
        const limb: usize = @intCast(@divFloor(bit, 64));
        const sh: u6 = @intCast(@mod(bit, 64));
        const a: u1 = @intCast((s.k1[limb] >> sh) & 1);
        const c: u1 = @intCast((s.k2[limb] >> sh) & 1);
        if (acc.isId() and a == 0 and c == 0) continue;
        acc.dbl();
        if (a == 1 and c == 1) acc.addJac(&both) else if (a == 1) acc.addAffine(b1) else if (c == 1) acc.addAffine(b2);
    }
    return acc;
}

fn glvSplit(g2: bool, k: [4]u64) ?Split {
    const basis = if (g2) g2_basis else g1_basis;
    const b1q = roundDiv(mulK(k, basis.n22));
    const b2q = roundDiv(mulK(k, .{ .neg = !basis.n12.neg, .lo = basis.n12.lo, .hi = basis.n12.hi }));
    const b1 = addWide(mulWideC(b1q, basis.n11), mulWideC(b2q, basis.n21));
    const b2 = addWide(mulWideC(b1q, basis.n12), mulWideC(b2q, basis.n22));
    const k1 = addWide(wideFrom4(k), .{ .neg = !b1.neg, .d = b1.d });
    const k2 = Wide{ .neg = !b2.neg, .d = b2.d };
    const a = norm(k1);
    const c = norm(k2);
    if (a.d[2] != 0 or a.d[3] != 0 or a.d[4] != 0 or a.d[5] != 0) return null;
    if (c.d[2] != 0 or c.d[3] != 0 or c.d[4] != 0 or c.d[5] != 0) return null;
    return .{
        .neg1 = a.neg,
        .k1 = .{ a.d[0], a.d[1] },
        .neg2 = c.neg,
        .k2 = .{ c.d[0], c.d[1] },
    };
}

fn wideFrom4(k: [4]u64) Wide {
    return .{ .neg = false, .d = .{ k[0], k[1], k[2], k[3], 0, 0 } };
}

fn magZero(d: [6]u64) bool {
    inline for (0..6) |i| if (d[i] != 0) return false;
    return true;
}

fn norm(w: Wide) Wide {
    if (magZero(w.d)) return .{ .neg = false, .d = w.d };
    return w;
}

fn mulK(k: [4]u64, c: C128) Wide {
    const d = mul4by2(k, c.lo, c.hi);
    return .{ .neg = c.neg and !magZero(d), .d = d };
}

fn mul4by2(a: [4]u64, b0: u64, b1: u64) [6]u64 {
    var o = [6]u64{ 0, 0, 0, 0, 0, 0 };
    inline for (.{ b0, b1 }, 0..) |b, bi| {
        var carry: u128 = 0;
        inline for (0..4) |i| {
            carry += @as(u128, o[bi + i]) + @as(u128, a[i]) * @as(u128, b);
            o[bi + i] = @truncate(carry);
            carry >>= 64;
        }
        o[bi + 4] = @truncate(carry);
    }
    return o;
}

fn mulWideC(a: Wide, c: C128) Wide {
    const d = mul4by2(.{ a.d[0], a.d[1], a.d[2], a.d[3] }, c.lo, c.hi);
    const z = magZero(d);
    return .{ .neg = (a.neg != c.neg) and !z, .d = d };
}

fn addWide(a: Wide, b: Wide) Wide {
    if (a.neg == b.neg) {
        const d = addMag(a.d, b.d);
        return .{ .neg = a.neg and !magZero(d), .d = d };
    }
    if (cmpMag(a.d, b.d) >= 0) {
        const d = subMag(a.d, b.d);
        return .{ .neg = a.neg and !magZero(d), .d = d };
    }
    const d = subMag(b.d, a.d);
    return .{ .neg = b.neg and !magZero(d), .d = d };
}

fn addMag(a: [6]u64, b: [6]u64) [6]u64 {
    var o: [6]u64 = undefined;
    var c: u128 = 0;
    inline for (0..6) |i| {
        c = @as(u128, a[i]) + b[i] + (c >> 64);
        o[i] = @truncate(c);
    }
    return o;
}

fn subMag(a: [6]u64, b: [6]u64) [6]u64 {
    var o: [6]u64 = undefined;
    var borrow: u64 = 0;
    inline for (0..6) |i| {
        const s1 = @subWithOverflow(a[i], b[i]);
        const s2 = @subWithOverflow(s1[0], borrow);
        o[i] = s2[0];
        borrow = s1[1] | s2[1];
    }
    return o;
}

fn cmpMag(a: [6]u64, b: [6]u64) i2 {
    var i: usize = 6;
    while (i > 0) {
        i -= 1;
        if (a[i] > b[i]) return 1;
        if (a[i] < b[i]) return -1;
    }
    return 0;
}

fn roundDiv(num_in: Wide) Wide {
    const num = norm(num_in);
    const parts = udivmod(num.d, FrMod);
    var q = parts.q;
    var r = parts.r;
    if (!num.neg) {
        if (twiceGt(r, FrMod)) inc4(&q);
        return .{ .neg = false, .d = .{ q[0], q[1], q[2], q[3], 0, 0 } };
    }
    if (r[0] == 0 and r[1] == 0 and r[2] == 0 and r[3] == 0) {
        return .{ .neg = q[0] != 0 or q[1] != 0 or q[2] != 0 or q[3] != 0, .d = .{ q[0], q[1], q[2], q[3], 0, 0 } };
    }
    inc4(&q);
    r = ff.subLimbs(FrMod, r);
    var neg = true;
    if (twiceGt(r, FrMod)) {
        dec4(&q);
        if (q[0] == 0 and q[1] == 0 and q[2] == 0 and q[3] == 0) neg = false;
    }
    return .{ .neg = neg, .d = .{ q[0], q[1], q[2], q[3], 0, 0 } };
}

fn udivmod(num: [6]u64, den: [4]u64) struct { q: [4]u64, r: [4]u64 } {
    var rem = [5]u64{ 0, 0, 0, 0, 0 };
    var q = [4]u64{ 0, 0, 0, 0 };
    var b: i32 = 383;
    while (b > 0) : (b -= 1) {
        const limb: usize = @intCast(@divFloor(b, 64));
        const sh: u6 = @intCast(@mod(b, 64));
        if ((num[limb] >> sh) & 1 == 1) break;
    }
    while (b >= 0) : (b -= 1) {
        var carry: u64 = 0;
        inline for (0..5) |i| {
            const next = rem[i] >> 63;
            rem[i] = (rem[i] << 1) | carry;
            carry = next;
        }
        var qc: u64 = 0;
        inline for (0..4) |i| {
            const next = q[i] >> 63;
            q[i] = (q[i] << 1) | qc;
            qc = next;
        }
        const limb: usize = @intCast(@divFloor(b, 64));
        const sh: u6 = @intCast(@mod(b, 64));
        if ((num[limb] >> sh) & 1 == 1) rem[0] |= 1;
        const low = [4]u64{ rem[0], rem[1], rem[2], rem[3] };
        if (rem[4] != 0 or ff.gte(low, den)) {
            var borrow: u64 = 0;
            inline for (0..4) |i| {
                const s1 = @subWithOverflow(rem[i], den[i]);
                const s2 = @subWithOverflow(s1[0], borrow);
                rem[i] = s2[0];
                borrow = s1[1] | s2[1];
            }
            rem[4] -|= borrow;
            q[0] |= 1;
        }
    }
    return .{ .q = q, .r = .{ rem[0], rem[1], rem[2], rem[3] } };
}

fn twiceGt(rem: [4]u64, den: [4]u64) bool {
    var t: [4]u64 = undefined;
    var c: u64 = 0;
    inline for (0..4) |i| {
        const v = (@as(u128, rem[i]) << 1) | c;
        t[i] = @truncate(v);
        c = @intCast(v >> 64);
    }
    if (c != 0) return true;
    return !ff.gte(den, t);
}

fn inc4(a: *[4]u64) void {
    var c: u64 = 1;
    inline for (0..4) |i| {
        const s = @addWithOverflow(a[i], c);
        a[i] = s[0];
        c = s[1];
    }
}

fn dec4(a: *[4]u64) void {
    var borrow: u64 = 1;
    inline for (0..4) |i| {
        const s = @subWithOverflow(a[i], borrow);
        a[i] = s[0];
        borrow = s[1];
    }
}

fn mulBinary(comptime F: type, base: Group(F).Aff, k: [4]u64, hb: u16) Group(F).Jac {
    const G = Group(F);
    var acc = G.Jac.fromAffine(base);
    var b: i32 = @as(i32, hb) - 1;
    while (b >= 0) : (b -= 1) {
        acc.dbl();
        if (bitAt(k, @intCast(b)) == 1) acc.addAffine(base);
    }
    return acc;
}

fn mulWindow(comptime F: type, base: Group(F).Aff, k: [4]u64, hb: u16) Group(F).Jac {
    const G = Group(F);
    var table: [16]G.Jac = undefined;
    table[0] = .{};
    table[1] = G.Jac.fromAffine(base);
    var ti: usize = 2;
    while (ti < 16) : (ti += 1) {
        table[ti] = table[ti - 1];
        table[ti].addAffine(base);
    }
    var bit: i32 = hb;
    var acc: G.Jac = .{};
    var started = false;
    while (bit >= 0) {
        var n: i32 = 4;
        if (bit + 1 < 4) n = bit + 1;
        var nib: u64 = 0;
        var step: i32 = 0;
        while (step < n) : (step += 1) {
            const b: u16 = @intCast(bit - step);
            nib = (nib << 1) | bitAt(k, b);
        }
        if (!started) {
            if (nib != 0) {
                acc = table[@intCast(nib)];
                started = true;
            }
        } else {
            var d: i32 = 0;
            while (d < n) : (d += 1) acc.dbl();
            if (nib != 0) acc.addJac(&table[@intCast(nib)]);
        }
        bit -= n;
    }
    return acc;
}

const two_x = [4]u64{ 0xd3c208c16d87cfd3, 0xd97816a916871ca8, 0x9b85045b68181585, 0x030644e72e131a02 };
const two_y = [4]u64{ 0xff3ebf7a5a18a2c4, 0x68a6a449e3538fc7, 0xe7845f96b2ae9c0a, 0x15ed738c0e0a7c92 };
const three_x = [4]u64{ 0xf2d355961915abf0, 0x9315d84715b8e679, 0xf40232bcb1b6bd15, 0x0769bf9ac56bea3f };
const three_y = [4]u64{ 0xcdf1ff3dd9fe2261, 0x319e63b40b9c5b57, 0x554fdb7c8d086475, 0x2ab799bee0489429 };

test "g1 doubling and scalar mul" {
    const g = g1Generator();
    try std.testing.expect(g.onCurve(g1B()));
    var doubled = G1.Jac.fromAffine(g);
    doubled.dbl();
    const d = doubled.toAffine();
    try std.testing.expect(std.mem.eql(u64, &d.x.toStd(), &two_x));
    try std.testing.expect(std.mem.eql(u64, &d.y.toStd(), &two_y));
    try std.testing.expect(d.onCurve(g1B()));

    var summed = G1.Jac.fromAffine(g);
    summed.addAffine(g);
    const s = summed.toAffine();
    try std.testing.expect(s.x.eql(d.x) and s.y.eql(d.y));

    var thr: G1.Jac = .{};
    thr.addMul(g, .{ 3, 0, 0, 0 });
    const t = thr.toAffine();
    try std.testing.expect(std.mem.eql(u64, &t.x.toStd(), &three_x));
    try std.testing.expect(std.mem.eql(u64, &t.y.toStd(), &three_y));

    var neg: G1.Jac = .{};
    neg.addMul(g, FrMinusOne);
    const n = neg.toAffine();
    try std.testing.expect(n.x.eql(g.x));
    try std.testing.expect(n.y.eql(g.y.neg()));

    // Window path (scalar wider than 48 bits) equals binary addition of a known multiple.
    const wide_k = [4]u64{ 0, 1, 0, 0 }; // 2^64
    var wide: G1.Jac = .{};
    wide.addMul(g, wide_k);
    var step = G1.Jac.fromAffine(g);
    var i: usize = 0;
    while (i < 64) : (i += 1) step.dbl();
    const w = wide.toAffine();
    const e = step.toAffine();
    try std.testing.expect(w.x.eql(e.x) and w.y.eql(e.y));
}

test "glv decomposition and scalar mul" {
    const k = [4]u64{ 0x16a0a73150000000, 0xb8114d6d7de87adb, 0xe81ac1e7808072c9, 0x10216f7ba065e00d };
    const s = glvSplit(true, k).?;
    try std.testing.expect(!s.neg1 and s.k1[0] == 3310440911461899254 and s.k1[1] == 0);
    try std.testing.expect(s.neg2 and s.k2[0] == 9273074331112768952 and s.k2[1] == 2673403253723678889);

    const one = glvSplit(false, .{ 1, 0, 0, 0 }).?;
    try std.testing.expect(!one.neg1 and one.k1[0] == 1 and one.k1[1] == 0);
    try std.testing.expect(!one.neg2 and one.k2[0] == 0 and one.k2[1] == 0);

    const g1 = g1Generator();
    const lam1 = [4]u64{ 0xb8ca0b2d36636f23, 0xcc37a73fec2bc5e9, 0x048b6e193fd84104, 0x30644e72e131a029 };
    const phi1 = endoAff(Fq, g1);
    const lam1p = mulBinary(Fq, g1, lam1, 253).toAffine();
    try std.testing.expect(phi1.x.eql(lam1p.x) and phi1.y.eql(lam1p.y));

    const g2 = g2Generator();
    const lam2 = [4]u64{ 0x8b17ea66b99c90dd, 0x5bfc41088d8daaa7, 0xb3c4d79d41a91758, 0 };
    const phi2 = endoAff(Fq2, g2);
    const lam2p = mulBinary(Fq2, g2, lam2, 191).toAffine();
    try std.testing.expect(phi2.x.eql(lam2p.x) and phi2.y.eql(lam2p.y));

    const samples = [_][4]u64{
        .{ 0, 1, 0, 0 },
        .{ 0x123456789abcdef0, 0x0fedcba987654321, 0x1111111111111111, 0x2222 },
        lam2,
    };
    for (samples) |scalar| {
        const hb = highestBit(scalar).?;
        const w1 = mulWindow(Fq, g1, scalar, hb).toAffine();
        const g1s = (mulGlv(Fq, g1, scalar) orelse unreachable).toAffine();
        try std.testing.expect(w1.x.eql(g1s.x) and w1.y.eql(g1s.y));
        const w2 = mulWindow(Fq2, g2, scalar, hb).toAffine();
        const g2s = (mulGlv(Fq2, g2, scalar) orelse unreachable).toAffine();
        try std.testing.expect(w2.x.eql(g2s.x) and w2.y.eql(g2s.y));
    }
}

test "g2 generator is on the twist" {
    const g = g2Generator();
    try std.testing.expect(g.onCurve(g2B()));
    var j = G2.Jac.fromAffine(g);
    j.dbl();
    j.addAffine(g);
    try std.testing.expect(j.toAffine().onCurve(g2B()));
}
