//! BN254 base field Fq and scalar field Fr, Montgomery form, 4×u64 little-endian.
const std = @import("std");

pub const Fq = Field(.{
    0x3c208c16d87cfd47,
    0x97816a916871ca8d,
    0xb85045b68181585d,
    0x30644e72e131a029,
});

pub const Fr = Field(.{
    0x43e1f593f0000001,
    0x2833e84879b97091,
    0xb85045b68181585d,
    0x30644e72e131a029,
});

pub const Fq2 = struct {
    c0: Fq = .{},
    c1: Fq = .{},

    pub const encoded_len: usize = 64;

    pub fn zero() Fq2 {
        return .{};
    }

    pub fn one() Fq2 {
        return .{ .c0 = Fq.one() };
    }

    pub inline fn isZero(self: Fq2) bool {
        return self.c0.isZero() and self.c1.isZero();
    }

    pub fn eql(a: Fq2, b: Fq2) bool {
        return a.c0.eql(b.c0) and a.c1.eql(b.c1);
    }

    pub inline fn add(a: Fq2, b: Fq2) Fq2 {
        return .{ .c0 = a.c0.add(b.c0), .c1 = a.c1.add(b.c1) };
    }

    pub inline fn sub(a: Fq2, b: Fq2) Fq2 {
        return .{ .c0 = a.c0.sub(b.c0), .c1 = a.c1.sub(b.c1) };
    }

    pub inline fn neg(a: Fq2) Fq2 {
        return .{ .c0 = a.c0.neg(), .c1 = a.c1.neg() };
    }

    pub inline fn mul2(a: Fq2) Fq2 {
        return a.add(a);
    }

    pub inline fn mul(a: Fq2, b: Fq2) Fq2 {
        // (a0 + a1 u)(b0 + b1 u) with u^2 = -1.
        const a0b0 = a.c0.mul(b.c0);
        const a1b1 = a.c1.mul(b.c1);
        const a0b1 = a.c0.mul(b.c1);
        const a1b0 = a.c1.mul(b.c0);
        return .{
            .c0 = a0b0.sub(a1b1),
            .c1 = a0b1.add(a1b0),
        };
    }

    pub inline fn sqr(a: Fq2) Fq2 {
        const a0s = a.c0.sqr();
        const a1s = a.c1.sqr();
        return .{
            .c0 = a0s.sub(a1s),
            .c1 = a.c0.mul(a.c1).mul2(),
        };
    }

    pub fn inv(a: Fq2) Fq2 {
        // 1/(a0+a1 u) = (a0-a1 u) / (a0^2+a1^2)
        const denom = a.c0.sqr().add(a.c1.sqr()).inv();
        return .{
            .c0 = a.c0.mul(denom),
            .c1 = a.c1.neg().mul(denom),
        };
    }

    pub fn store(self: Fq2, dst: []u8) void {
        self.c0.store(dst[0..32]);
        self.c1.store(dst[32..64]);
    }
};

fn Field(comptime modulus: [4]u64) type {
    const n0 = montNegInv(modulus[0]);
    const r2 = pow2Mod(512, modulus);
    return struct {
        limbs: [4]u64 = .{ 0, 0, 0, 0 },

        pub const encoded_len: usize = 32;
        pub const mod_limbs = modulus;
        pub const r2_std = r2;
        pub const mont_n0: u64 = n0;

        const Self = @This();

        pub fn zero() Self {
            return .{};
        }

        pub fn one() Self {
            return fromStd(.{ 1, 0, 0, 0 });
        }

        pub fn fromInt(v: u64) Self {
            return fromStd(.{ v, 0, 0, 0 });
        }

        pub fn fromStd(s: [4]u64) Self {
            return .{ .limbs = montMul(s, r2) };
        }

        pub fn toStd(self: Self) [4]u64 {
            return montMul(self.limbs, .{ 1, 0, 0, 0 });
        }

        pub inline fn isZero(self: Self) bool {
            return self.limbs[0] == 0 and self.limbs[1] == 0 and self.limbs[2] == 0 and self.limbs[3] == 0;
        }

        pub fn eql(a: Self, b: Self) bool {
            return std.mem.eql(u64, &a.limbs, &b.limbs);
        }

        pub inline fn add(a: Self, b: Self) Self {
            return .{ .limbs = addMod(a.limbs, b.limbs) };
        }

        pub inline fn sub(a: Self, b: Self) Self {
            return .{ .limbs = subMod(a.limbs, b.limbs) };
        }

        pub inline fn neg(a: Self) Self {
            if (a.isZero()) return a;
            return .{ .limbs = subLimbs(modulus, a.limbs) };
        }

        pub inline fn mul2(a: Self) Self {
            return a.add(a);
        }

        pub inline fn mul(a: Self, b: Self) Self {
            return .{ .limbs = montMul(a.limbs, b.limbs) };
        }

        pub inline fn sqr(a: Self) Self {
            return a.mul(a);
        }

        pub fn inv(self: Self) Self {
            var exp = modulus;
            exp = subLimbs(exp, .{ 2, 0, 0, 0 });
            return self.pow(exp);
        }

        pub fn pow(self: Self, exp: [4]u64) Self {
            @setEvalBranchQuota(1_000_000);
            var result = one();
            var base = self;
            var li: usize = 0;
            while (li < 4) : (li += 1) {
                var e = exp[li];
                var bit: usize = 0;
                while (bit < 64) : (bit += 1) {
                    if ((e & 1) == 1) result = result.mul(base);
                    base = base.sqr();
                    e >>= 1;
                }
            }
            return result;
        }

        pub fn store(self: Self, dst: []u8) void {
            inline for (0..4) |i| {
                std.mem.writeInt(u64, dst[i * 8 ..][0..8], self.limbs[i], .little);
            }
        }

        pub fn storeStd(self: Self, dst: []u8) void {
            const s = self.toStd();
            inline for (0..4) |i| {
                std.mem.writeInt(u64, dst[i * 8 ..][0..8], s[i], .little);
            }
        }

        inline fn addMod(a: [4]u64, b: [4]u64) [4]u64 {
            var r: [4]u64 = undefined;
            var c: u128 = 0;
            inline for (0..4) |i| {
                c = @as(u128, a[i]) + b[i] + (c >> 64);
                r[i] = @truncate(c);
            }
            return subWide(@intCast(c >> 64), r);
        }

        inline fn subMod(a: [4]u64, b: [4]u64) [4]u64 {
            if (gte(a, b)) return subLimbs(a, b);
            return subLimbs(modulus, subLimbs(b, a));
        }

        inline fn montMul(a: [4]u64, b: [4]u64) [4]u64 {
            @setEvalBranchQuota(1_000_000);
            var t = [8]u64{ 0, 0, 0, 0, 0, 0, 0, 0 };
            inline for (0..4) |i| {
                var carry: u128 = 0;
                inline for (0..4) |j| {
                    carry = @as(u128, t[i + j]) + @as(u128, a[i]) * @as(u128, b[j]) + (carry >> 64);
                    t[i + j] = @truncate(carry);
                }
                const summed = @as(u128, t[i + 4]) + (carry >> 64);
                t[i + 4] = @truncate(summed);
            }
            inline for (0..4) |i| {
                const m: u64 = t[i] *% n0;
                var carry: u128 = 0;
                inline for (0..4) |j| {
                    carry = @as(u128, t[i + j]) + @as(u128, m) * @as(u128, modulus[j]) + (carry >> 64);
                    t[i + j] = @truncate(carry);
                }
                var k: usize = i + 4;
                carry >>= 64;
                while (carry != 0 and k < 8) : (k += 1) {
                    const summed = @as(u128, t[k]) + carry;
                    t[k] = @truncate(summed);
                    carry = summed >> 64;
                }
            }
            var r = [4]u64{ t[4], t[5], t[6], t[7] };
            if (gte(r, modulus)) r = subLimbs(r, modulus);
            return r;
        }

        inline fn subWide(hi: u64, r_in: [4]u64) [4]u64 {
            if (hi == 0) {
                if (gte(r_in, modulus)) return subLimbs(r_in, modulus);
                return r_in;
            }
            var neg_mod: [4]u64 = undefined;
            var carry: u64 = 1;
            inline for (0..4) |i| {
                const s = @addWithOverflow(~modulus[i], carry);
                neg_mod[i] = s[0];
                carry = s[1];
            }
            var out: [4]u64 = undefined;
            var c: u128 = 0;
            inline for (0..4) |i| {
                c = @as(u128, neg_mod[i]) + r_in[i] + (c >> 64);
                out[i] = @truncate(c);
            }
            var extra: u64 = hi - 1;
            extra += @intCast(c >> 64);
            if (extra != 0 or gte(out, modulus)) out = subLimbs(out, modulus);
            return out;
        }
    };
}

pub inline fn gte(a: [4]u64, b: [4]u64) bool {
    var i: usize = 4;
    while (i > 0) {
        i -= 1;
        if (a[i] > b[i]) return true;
        if (a[i] < b[i]) return false;
    }
    return true;
}

pub inline fn subLimbs(a: [4]u64, b: [4]u64) [4]u64 {
    var r: [4]u64 = undefined;
    var borrow: u64 = 0;
    inline for (0..4) |i| {
        const d = @subWithOverflow(a[i], b[i]);
        const d2 = @subWithOverflow(d[0], borrow);
        r[i] = d2[0];
        borrow = d[1] | d2[1];
    }
    return r;
}

pub fn loadLimbs(src: []const u8) [4]u64 {
    var limbs: [4]u64 = undefined;
    inline for (0..4) |i| {
        limbs[i] = std.mem.readInt(u64, src[i * 8 ..][0..8], .little);
    }
    return limbs;
}

fn montNegInv(comptime q0: u64) u64 {
    var x: u64 = 1;
    inline for (0..6) |_| {
        x *%= 2 -% (q0 *% x);
    }
    return 0 -% x;
}

fn pow2Mod(comptime exp: u32, comptime mod: [4]u64) [4]u64 {
    @setEvalBranchQuota(100_000);
    var a = [4]u64{ 1, 0, 0, 0 };
    var i: u32 = 0;
    while (i < exp) : (i += 1) {
        var r: [4]u64 = undefined;
        var c: u64 = 0;
        inline for (0..4) |li| {
            const top: u64 = a[li] >> 63;
            r[li] = (a[li] << 1) | c;
            c = top;
        }
        if (c != 0 or gte(r, mod)) {
            if (c == 0) {
                r = subLimbs(r, mod);
            } else {
                var neg: [4]u64 = undefined;
                var carry: u64 = 1;
                inline for (0..4) |li| {
                    const s = @addWithOverflow(~mod[li], carry);
                    neg[li] = s[0];
                    carry = s[1];
                }
                var out: [4]u64 = undefined;
                var acc: u128 = 0;
                inline for (0..4) |li| {
                    acc = @as(u128, neg[li]) + r[li] + (acc >> 64);
                    out[li] = @truncate(acc);
                }
                r = out;
            }
        }
        a = r;
    }
    return a;
}

test "fq roundtrip and arithmetic" {
    const a = Fq.fromInt(3);
    const b = Fq.fromInt(5);
    try std.testing.expect(a.mul(b).eql(Fq.fromInt(15)));
    try std.testing.expect(a.toStd()[0] == 3);
    const big = Fq.fromStd(.{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x0fffffffffffffff });
    try std.testing.expect(std.mem.eql(u64, &big.toStd(), &.{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x0fffffffffffffff }));
    const m1 = Fq.fromStd(subLimbs(Fq.mod_limbs, .{ 1, 0, 0, 0 }));
    try std.testing.expect(m1.add(Fq.one()).isZero());
    try std.testing.expect(m1.mul(m1).eql(Fq.one()));
    try std.testing.expect(Fq.fromInt(7).mul(Fq.fromInt(7).inv()).eql(Fq.one()));
}

test "fr coefficient times R^2" {
    const m_r2 = Fr.fromStd(Fr.r2_std);
    const encoded = Fr.fromInt(1).mul(m_r2).toStd();
    try std.testing.expect(std.mem.eql(u64, &encoded, &Fr.r2_std));
}

test "fq2 square" {
    const a = Fq2{ .c0 = Fq.one(), .c1 = Fq.one() };
    const s = a.sqr();
    try std.testing.expect(s.c0.isZero());
    try std.testing.expect(s.c1.eql(Fq.fromInt(2)));
    try std.testing.expect(a.mul(a.inv()).eql(Fq2.one()));
}
