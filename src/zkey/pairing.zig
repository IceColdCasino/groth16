//! Optimal ate pairing on BN254, in the same tower snarkjs uses for `vk_alphabeta_12`.
//! Fp2 = Fp[u]/(u^2+1), Fp6 = Fp2[v]/(v^3-(9+u)), Fp12 = Fp6[w]/(w^2-v).
const std = @import("std");
const ff = @import("ff.zig");
const curve = @import("curve.zig");

const Fq = ff.Fq;
const Fp2 = ff.Fq2;

const ate_loop: u128 = 29793968203157093288;
const final_z: u64 = 4965661367192848881;

fn fq(comptime s: []const u8) Fq {
    return Fq.fromStd(decLimbs(s));
}

fn fq2(comptime a: []const u8, comptime b: []const u8) Fp2 {
    return .{ .c0 = fq(a), .c1 = fq(b) };
}

fn decLimbs(comptime s: []const u8) [4]u64 {
    @setEvalBranchQuota(20_000);
    var acc = [4]u64{ 0, 0, 0, 0 };
    for (s) |ch| {
        var carry: u128 = ch - '0';
        inline for (0..4) |i| {
            carry += @as(u128, acc[i]) * 10;
            acc[i] = @truncate(carry);
            carry >>= 64;
        }
    }
    return acc;
}

const xi = fq2("9", "1");
const twist_b = fq2(
    "19485874751759354771024239261021720505790618469301721065564631296452457478373",
    "266929791119991161246907387137283842545076965332900288569378510910307636690",
);
const mul_by_qx = fq2(
    "21575463638280843010398324269430826099269044274347216827212613867836435027261",
    "10307601595873709700152284273816112264069230130616436755625194854815875713954",
);
const mul_by_qy = fq2(
    "2821565182194536844548159561693502659359617185244120367078079554186484126554",
    "3505843767911556378687030309984248845540243509899259641013678093033130930403",
);

fn twoInv() Fp2 {
    return .{ .c0 = Fq.fromInt(2).inv(), .c1 = .{} };
}

fn xiMul(a: Fp2) Fp2 {
    return a.mul(xi);
}

fn conj2(a: Fp2) Fp2 {
    return .{ .c0 = a.c0, .c1 = a.c1.neg() };
}

fn mul1(a: Fp2, k: Fq) Fp2 {
    return .{ .c0 = a.c0.mul(k), .c1 = a.c1.mul(k) };
}

pub const Fp6 = struct {
    a: Fp2 = .{},
    b: Fp2 = .{},
    c: Fp2 = .{},

    fn add(x: Fp6, y: Fp6) Fp6 {
        return .{ .a = x.a.add(y.a), .b = x.b.add(y.b), .c = x.c.add(y.c) };
    }
    fn sub(x: Fp6, y: Fp6) Fp6 {
        return .{ .a = x.a.sub(y.a), .b = x.b.sub(y.b), .c = x.c.sub(y.c) };
    }
    fn neg(x: Fp6) Fp6 {
        return .{ .a = x.a.neg(), .b = x.b.neg(), .c = x.c.neg() };
    }
    fn mul(x: Fp6, y: Fp6) Fp6 {
        @setEvalBranchQuota(1_000_000);
        const a0b0 = x.a.mul(y.a);
        const a1b1 = x.b.mul(y.b);
        const a2b2 = x.c.mul(y.c);
        return .{
            .a = a0b0.add(xiMul(x.b.mul(y.c).add(x.c.mul(y.b)))),
            .b = x.a.mul(y.b).add(x.b.mul(y.a)).add(xiMul(a2b2)),
            .c = x.a.mul(y.c).add(a1b1).add(x.c.mul(y.a)),
        };
    }
    fn mulByV(x: Fp6) Fp6 {
        return .{ .a = xiMul(x.c), .b = x.a, .c = x.b };
    }
    fn inv(x: Fp6) Fp6 {
        @setEvalBranchQuota(1_000_000);
        const t0 = x.a.sqr();
        const t1 = x.b.sqr();
        const t2 = x.c.sqr();
        const t3 = x.a.mul(x.b);
        const t4 = x.a.mul(x.c);
        const t5 = x.b.mul(x.c);
        const s0 = t0.sub(xiMul(t5));
        const s1 = xiMul(t2).sub(t3);
        const s2 = t1.sub(t4);
        const norm = x.a.mul(s0).add(xiMul(x.c.mul(s1).add(x.b.mul(s2)))).inv();
        return .{ .a = s0.mul(norm), .b = s1.mul(norm), .c = s2.mul(norm) };
    }
};

pub const Fp12 = struct {
    c0: Fp6 = .{},
    c1: Fp6 = .{},

    pub fn one() Fp12 {
        return .{ .c0 = .{ .a = Fp2.one() } };
    }

    fn mul(x: Fp12, y: Fp12) Fp12 {
        const ac = x.c0.mul(y.c0);
        const bd = x.c1.mul(y.c1);
        return .{
            .c0 = ac.add(bd.mulByV()),
            .c1 = x.c0.add(x.c1).mul(y.c0.add(y.c1)).sub(ac).sub(bd),
        };
    }

    fn sqr(x: Fp12) Fp12 {
        return x.mul(x);
    }

    fn conj(x: Fp12) Fp12 {
        return .{ .c0 = x.c0, .c1 = x.c1.neg() };
    }

    fn inv(x: Fp12) Fp12 {
        const norm = x.c0.mul(x.c0).sub(x.c1.mul(x.c1).mulByV()).inv();
        return .{ .c0 = x.c0.mul(norm), .c1 = x.c1.neg().mul(norm) };
    }
};

const Line = struct { ell0: Fp2, vw: Fp2, vv: Fp2 };

const Jac = struct { x: Fp2, y: Fp2, z: Fp2 };

fn dblLine(r: *Jac) Line {
    @setEvalBranchQuota(1_000_000);
    const half = twoInv();
    const x1 = r.x;
    const y1 = r.y;
    const z1 = r.z;
    const a = x1.mul(y1.mul(half));
    const b = y1.sqr();
    const c = z1.sqr();
    const d = c.add(c).add(c);
    const e = twist_b.mul(d);
    const f = e.add(e).add(e);
    const g = b.add(f).mul(half);
    const h = y1.add(z1).sqr().sub(b.add(c));
    const i = e.sub(b);
    const j = x1.sqr();
    const e2 = e.sqr();
    r.x = a.mul(b.sub(f));
    r.y = g.sqr().sub(e2.add(e2).add(e2));
    r.z = b.mul(h);
    return .{
        .ell0 = xiMul(i),
        .vw = h.neg(),
        .vv = j.add(j).add(j),
    };
}

fn addLine(r: *Jac, q: Jac) Line {
    @setEvalBranchQuota(1_000_000);
    const x1 = r.x;
    const y1 = r.y;
    const z1 = r.z;
    const d = x1.sub(q.x.mul(z1));
    const e = y1.sub(q.y.mul(z1));
    const f = d.sqr();
    const g = e.sqr();
    const h = d.mul(f);
    const i = x1.mul(f);
    const j = h.add(z1.mul(g)).sub(i.add(i));
    r.x = d.mul(j);
    r.y = e.mul(i.sub(j)).sub(h.mul(y1));
    r.z = z1.mul(h);
    return .{
        .ell0 = xiMul(e.mul(q.x).sub(d.mul(q.y))),
        .vw = d,
        .vv = e.neg(),
    };
}

fn mulLine(z: Fp12, line: Line, px: Fq, py: Fq) Fp12 {
    return mulBy024(z, .{
        .ell0 = line.ell0,
        .vw = mul1(line.vw, py),
        .vv = mul1(line.vv, px),
    });
}

fn mulBy024(z: Fp12, line: Line) Fp12 {
    @setEvalBranchQuota(1_000_000);
    const z0 = z.c0.a;
    const z1 = z.c0.b;
    const z2 = z.c0.c;
    const z3 = z.c1.a;
    const z4 = z.c1.b;
    const z5 = z.c1.c;
    const x0 = line.ell0;
    const x2 = line.vv;
    const x4 = line.vw;

    const d0 = z0.mul(x0);
    const d2 = z2.mul(x2);
    const d4 = z4.mul(x4);
    const t2 = z0.add(z4);
    const t1 = z0.add(z2);
    const s0 = z1.add(z3).add(z5);

    var s1 = z1.mul(x2);
    var t3 = s1.add(d4);
    const nz0 = xiMul(t3).add(d0);

    t3 = z5.mul(x4);
    s1 = s1.add(t3);
    t3 = t3.add(d2);
    var t4 = xiMul(t3);
    t3 = z1.mul(x0);
    s1 = s1.add(t3);
    const nz1 = t4.add(t3);

    var t0 = x0.add(x2);
    t3 = t1.mul(t0).sub(d0.add(d2));
    t4 = z3.mul(x4);
    s1 = s1.add(t4);
    t0 = z2.add(z4);
    const nz2 = t3.add(t4);

    const t1b = x2.add(x4);
    t3 = t0.mul(t1b).sub(d2.add(d4));
    t4 = xiMul(t3);
    t3 = z3.mul(x0);
    s1 = s1.add(t3);
    const nz3 = t4.add(t3);

    t3 = z5.mul(x2);
    s1 = s1.add(t3);
    t4 = xiMul(t3);
    t0 = x0.add(x4);
    t3 = t2.mul(t0).sub(d0.add(d4));
    const nz4 = t4.add(t3);

    t0 = x0.add(x2).add(x4);
    const nz5 = s0.mul(t0).sub(s1);
    return .{
        .c0 = .{ .a = nz0, .b = nz1, .c = nz2 },
        .c1 = .{ .a = nz3, .b = nz4, .c = nz5 },
    };
}

fn mulByQ(p: Jac) Jac {
    return .{
        .x = conj2(p.x).mul(mul_by_qx),
        .y = conj2(p.y).mul(mul_by_qy),
        .z = conj2(p.z),
    };
}

/// Frobenius coefficients F12[1][n] and F6[1..2][n] from the snarkjs BN128 pairing.
fn f12Hi(n: usize) Fp2 {
    return switch (n) {
        0 => Fp2.one(),
        1 => fq2("8376118865763821496583973867626364092589906065868298776909617916018768340080", "16469823323077808223889137241176536799009286646108169935659301613961712198316"),
        2 => fq2("21888242871839275220042445260109153167277707414472061641714758635765020556617", "0"),
        3 => fq2("11697423496358154304825782922584725312912383441159505038794027105778954184319", "303847389135065887422783454877609941456349188919719272345083954437860409601"),
        4 => fq2("21888242871839275220042445260109153167277707414472061641714758635765020556616", "0"),
        5 => fq2("3321304630594332808241809054958361220322477375291206261884409189760185844239", "5722266937896532885780051958958348231143373700109372999374820235121374419868"),
        6 => fq2("21888242871839275222246405745257275088696311157297823662689037894645226208582", "0"),
        7 => fq2("13512124006075453725662431877630910996106405091429524885779419978626457868503", "5418419548761466998357268504080738289687024511189653727029736280683514010267"),
        8 => fq2("2203960485148121921418603742825762020974279258880205651966", "0"),
        9 => fq2("10190819375481120917420622822672549775783927716138318623895010788866272024264", "21584395482704209334823622290379665147239961968378104390343953940207365798982"),
        10 => fq2("2203960485148121921418603742825762020974279258880205651967", "0"),
        11 => fq2("18566938241244942414004596690298913868373833782006617400804628704885040364344", "16165975933942742336466353786298926857552937457188450663314217659523851788715"),
        else => unreachable,
    };
}

fn f6(row: usize, n: usize) Fp2 {
    if (row == 0) return Fp2.one();
    if (row == 1) return switch (n) {
        0 => Fp2.one(),
        1 => fq2("21575463638280843010398324269430826099269044274347216827212613867836435027261", "10307601595873709700152284273816112264069230130616436755625194854815875713954"),
        2 => fq2("21888242871839275220042445260109153167277707414472061641714758635765020556616", "0"),
        3 => fq2("3772000881919853776433695186713858239009073593817195771773381919316419345261", "2236595495967245188281701248203181795121068902605861227855261137820944008926"),
        4 => fq2("2203960485148121921418603742825762020974279258880205651966", "0"),
        5 => fq2("18429021223477853657660792034369865839114504446431234726392080002137598044644", "9344045779998320333812420223237981029506012124075525679208581902008406485703"),
        else => unreachable,
    };
    return switch (n) {
        0 => Fp2.one(),
        1 => fq2("2581911344467009335267311115468803099551665605076196740867805258568234346338", "19937756971775647987995932169929341994314640652964949448313374472400716661030"),
        2 => fq2("2203960485148121921418603742825762020974279258880205651966", "0"),
        3 => fq2("5324479202449903542726783395506214481928257762400643279780343368557297135718", "16208900380737693084919495127334387981393726419856888799917914180988844123039"),
        4 => fq2("21888242871839275220042445260109153167277707414472061641714758635765020556616", "0"),
        5 => fq2("13981852324922362344252311234282257507216387789820983642040889267519694726527", "7629828391165209371577384193250820201684255241773809077146787135900891633097"),
        else => unreachable,
    };
}

fn frobCoef(n: usize, i: usize) Fp2 {
    const hi: Fp2 = if (i < 3) Fp2.one() else f12Hi(n % 12);
    return hi.mul(f6(i % 3, n % 6));
}

fn frobenius(x: Fp12, n: usize) Fp12 {
    var comps = [6]Fp2{ x.c0.a, x.c0.b, x.c0.c, x.c1.a, x.c1.b, x.c1.c };
    for (&comps, 0..) |*c, i| {
        const v: Fp2 = if (n % 2 == 1) conj2(c.*) else c.*;
        c.* = v.mul(frobCoef(n, i));
    }
    return .{
        .c0 = .{ .a = comps[0], .b = comps[1], .c = comps[2] },
        .c1 = .{ .a = comps[3], .b = comps[4], .c = comps[5] },
    };
}

fn cyclotomicSquare(z: Fp12) Fp12 {
    @setEvalBranchQuota(1_000_000);
    const x0 = z.c0.a;
    const x4 = z.c0.b;
    const x3 = z.c0.c;
    const x2 = z.c1.a;
    const x1 = z.c1.b;
    const x5 = z.c1.c;

    const tmp_a = x0.mul(x1);
    const t0 = x0.add(x1).mul(x0.add(xiMul(x1))).sub(tmp_a.add(xiMul(tmp_a)));
    const t1 = tmp_a.add(tmp_a);

    const tmp_b = x2.mul(x3);
    const t2 = x2.add(x3).mul(x2.add(xiMul(x3))).sub(tmp_b.add(xiMul(tmp_b)));
    const t3 = tmp_b.add(tmp_b);

    const tmp_c = x4.mul(x5);
    const t4 = x4.add(x5).mul(x4.add(xiMul(x5))).sub(tmp_c.add(xiMul(tmp_c)));
    const t5 = tmp_c.add(tmp_c);

    var r0 = t0.sub(x0);
    r0 = r0.add(r0);
    r0 = t0.add(r0);
    var r1 = t1.add(x1);
    r1 = r1.add(r1);
    r1 = t1.add(r1);

    const xi_t5 = xiMul(t5);
    var r2 = xi_t5.add(x2);
    r2 = r2.add(r2);
    r2 = xi_t5.add(r2);
    var r3 = t4.sub(x3);
    r3 = r3.add(r3);
    r3 = t4.add(r3);

    var r4 = t2.sub(x4);
    r4 = r4.add(r4);
    r4 = t2.add(r4);
    var r5 = t3.add(x5);
    r5 = r5.add(r5);
    r5 = t3.add(r5);

    return .{
        .c0 = .{ .a = r0, .b = r4, .c = r3 },
        .c1 = .{ .a = r2, .b = r1, .c = r5 },
    };
}

fn cyclotomicExpZ(x: Fp12) Fp12 {
    var e: i128 = final_z;
    var naf_buf: [96]i8 = undefined;
    var n: usize = 0;
    while (e > 0) {
        if (@mod(e, 2) != 0) {
            const z: i8 = @intCast(2 - @mod(e, 4));
            naf_buf[n] = z;
            e -= z;
        } else {
            naf_buf[n] = 0;
        }
        n += 1;
        e = @divFloor(e, 2);
    }
    const inv_x = x.conj();
    var res = Fp12.one();
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (i + 1 != n) res = cyclotomicSquare(res);
        if (naf_buf[i] == 1) res = res.mul(x) else if (naf_buf[i] == -1) res = res.mul(inv_x);
    }
    return res;
}

fn finalExp(elt: Fp12) Fp12 {
    const a_conj = elt.conj();
    const b = elt.inv();
    const c = a_conj.mul(b);
    const first = frobenius(c, 2).mul(c);

    const neg_z = struct {
        fn apply(v: Fp12) Fp12 {
            return cyclotomicExpZ(v).conj();
        }
    };
    const a = neg_z.apply(first);
    const b2 = cyclotomicSquare(a);
    const c2 = cyclotomicSquare(b2);
    const d = c2.mul(b2);
    const e = neg_z.apply(d);
    const f = cyclotomicSquare(e);
    const g = neg_z.apply(f);
    const h = d.conj();
    const i = g.conj();
    const j = i.mul(e);
    const k = j.mul(h);
    const l = k.mul(b2);
    const m = k.mul(e);
    const nn = m.mul(first);
    const o = frobenius(l, 1);
    const p = o.mul(nn);
    const q = frobenius(k, 2);
    const r = q.mul(p);
    const s = first.conj();
    const t = s.mul(l);
    return frobenius(t, 3).mul(r);
}

fn ateBits() struct { bits: [80]u1, len: usize } {
    var bits: [80]u1 = std.mem.zeroes([80]u1);
    var e = ate_loop;
    var n: usize = 0;
    while (e > 0) : (e >>= 1) {
        bits[n] = @intCast(e & 1);
        n += 1;
    }
    return .{ .bits = bits, .len = n };
}

pub fn pairing(p: curve.G1.Aff, q: curve.G2.Aff) Fp12 {
    if (p.isZero() or q.isZero()) return Fp12.one();
    const bits = ateBits();
    var r = Jac{ .x = q.x, .y = q.y, .z = Fp2.one() };
    const q_aff = r;
    var f = Fp12.one();
    var i: usize = bits.len - 1;
    while (i > 0) {
        i -= 1;
        f = f.sqr();
        f = mulLine(f, dblLine(&r), p.x, p.y);
        if (bits.bits[i] == 1) f = mulLine(f, addLine(&r, q_aff), p.x, p.y);
    }
    const q1 = mulByQ(q_aff);
    var q2 = mulByQ(q1);
    q2.y = q2.y.neg();
    f = mulLine(f, addLine(&r, q1), p.x, p.y);
    f = mulLine(f, addLine(&r, q2), p.x, p.y);
    return finalExp(f);
}
