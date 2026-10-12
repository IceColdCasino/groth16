// BN254 G1 scalar multiplication.
// Fq coordinates are Montgomery, 4×u64 little-endian, matching the Zig field code.
#include <metal_stdlib>
using namespace metal;

struct Params {
    ulong fq[4];
    ulong fq_n0;
    ulong one[4];
    ulong fr[4];
    ulong fr_half[4];
};

struct Fe {
    ulong v[4];
};

struct Jac {
    Fe x;
    Fe y;
    Fe z;
};

static void wideMul(ulong a, ulong b, thread ulong &lo, thread ulong &hi) {
    ulong a0 = a & 0xffffffffull;
    ulong a1 = a >> 32;
    ulong b0 = b & 0xffffffffull;
    ulong b1 = b >> 32;
    ulong p0 = a0 * b0;
    ulong p1 = a0 * b1;
    ulong p2 = a1 * b0;
    ulong p3 = a1 * b1;
    ulong mid = (p0 >> 32) + (p1 & 0xffffffffull) + (p2 & 0xffffffffull);
    lo = (p0 & 0xffffffffull) | (mid << 32);
    hi = p3 + (p1 >> 32) + (p2 >> 32) + (mid >> 32);
}

static void add3(ulong a, ulong b, ulong c, thread ulong &lo, thread ulong &hi) {
    ulong s = a + b;
    ulong c0 = s < a ? 1 : 0;
    ulong s2 = s + c;
    ulong c1 = s2 < c ? 1 : 0;
    lo = s2;
    hi = c0 + c1;
}

static bool gteC(thread const ulong a[4], constant const ulong b[4]) {
    for (int i = 3; i >= 0; i--) {
        if (a[i] > b[i]) return true;
        if (a[i] < b[i]) return false;
    }
    return true;
}

static bool gteT(thread const ulong a[4], thread const ulong b[4]) {
    for (int i = 3; i >= 0; i--) {
        if (a[i] > b[i]) return true;
        if (a[i] < b[i]) return false;
    }
    return true;
}

static void subMod(constant const ulong a[4], thread const ulong b[4], thread ulong o[4]) {
    ulong aa[4];
    for (int i = 0; i < 4; i++) aa[i] = a[i];
    ulong borrow = 0;
    for (int i = 0; i < 4; i++) {
        ulong d0 = aa[i] - b[i];
        ulong b0 = aa[i] < b[i] ? 1 : 0;
        ulong d1 = d0 - borrow;
        ulong b1 = d0 < borrow ? 1 : 0;
        o[i] = d1;
        borrow = b0 | b1;
    }
}

static void subC(thread const ulong a[4], constant const ulong b[4], thread ulong o[4]) {
    ulong borrow = 0;
    for (int i = 0; i < 4; i++) {
        ulong d0 = a[i] - b[i];
        ulong b0 = a[i] < b[i] ? 1 : 0;
        ulong d1 = d0 - borrow;
        ulong b1 = d0 < borrow ? 1 : 0;
        o[i] = d1;
        borrow = b0 | b1;
    }
}

static void subT(thread const ulong a[4], thread const ulong b[4], thread ulong o[4]) {
    ulong borrow = 0;
    for (int i = 0; i < 4; i++) {
        ulong d0 = a[i] - b[i];
        ulong b0 = a[i] < b[i] ? 1 : 0;
        ulong d1 = d0 - borrow;
        ulong b1 = d0 < borrow ? 1 : 0;
        o[i] = d1;
        borrow = b0 | b1;
    }
}

static Fe feAdd(Fe a, Fe b, constant Params &P) {
    Fe r;
    ulong carry = 0;
    for (int i = 0; i < 4; i++) {
        ulong s = a.v[i] + b.v[i];
        ulong c0 = s < a.v[i] ? 1 : 0;
        ulong s2 = s + carry;
        ulong c1 = s2 < carry ? 1 : 0;
        r.v[i] = s2;
        carry = c0 + c1;
    }
    if (carry == 0) {
        if (gteC(r.v, P.fq)) {
            ulong t[4];
            subC(r.v, P.fq, t);
            for (int i = 0; i < 4; i++) r.v[i] = t[i];
        }
        return r;
    }
    ulong neg[4];
    ulong nc = 1;
    for (int i = 0; i < 4; i++) {
        ulong s = ~P.fq[i] + nc;
        nc = s < nc ? 1 : 0;
        neg[i] = s;
    }
    ulong c = 0;
    ulong out[4];
    for (int i = 0; i < 4; i++) {
        ulong lo, hi;
        add3(neg[i], r.v[i], c, lo, hi);
        out[i] = lo;
        c = hi;
    }
    ulong extra = c;
    if (extra != 0 || gteC(out, P.fq)) {
        ulong t[4];
        subC(out, P.fq, t);
        for (int i = 0; i < 4; i++) out[i] = t[i];
    }
    for (int i = 0; i < 4; i++) r.v[i] = out[i];
    return r;
}

static Fe feSub(Fe a, Fe b, constant Params &P) {
    Fe r;
    if (gteT(a.v, b.v)) {
        subT(a.v, b.v, r.v);
        return r;
    }
    ulong d[4];
    subT(b.v, a.v, d);
    subMod(P.fq, d, r.v);
    return r;
}

static Fe feNeg(Fe a, constant Params &P) {
    Fe z;
    z.v[0] = z.v[1] = z.v[2] = z.v[3] = 0;
    if ((a.v[0] | a.v[1] | a.v[2] | a.v[3]) == 0) return z;
    Fe r;
    subMod(P.fq, a.v, r.v);
    return r;
}

static Fe feMul(Fe a, Fe b, constant Params &P) {
    ulong t[8];
    for (int i = 0; i < 8; i++) t[i] = 0;
    for (int i = 0; i < 4; i++) {
        ulong C1 = 0;
        ulong C2 = 0;
        for (int j = 0; j < 4; j++) {
            ulong P0, P1;
            wideMul(a.v[i], b.v[j], P0, P1);
            ulong lo, h1;
            add3(t[i + j], P0, C1, lo, h1);
            ulong hi, h2;
            add3(P1, C2, h1, hi, h2);
            t[i + j] = lo;
            C1 = hi;
            C2 = h2;
        }
        t[i + 4] = t[i + 4] + C1;
    }
    for (int i = 0; i < 4; i++) {
        ulong m = t[i] * P.fq_n0;
        ulong C1 = 0;
        ulong C2 = 0;
        for (int j = 0; j < 4; j++) {
            ulong P0, P1;
            wideMul(m, P.fq[j], P0, P1);
            ulong lo, h1;
            add3(t[i + j], P0, C1, lo, h1);
            ulong hi, h2;
            add3(P1, C2, h1, hi, h2);
            t[i + j] = lo;
            C1 = hi;
            C2 = h2;
        }
        ulong prop = C1;
        ulong prop_hi = C2;
        int k = i + 4;
        while ((prop != 0 || prop_hi != 0) && k < 8) {
            ulong s = t[k] + prop;
            ulong c0 = s < t[k] ? 1 : 0;
            t[k] = s;
            ulong next = prop_hi + c0;
            prop_hi = next < prop_hi ? 1 : 0;
            prop = next;
            k++;
        }
    }
    Fe r;
    for (int i = 0; i < 4; i++) r.v[i] = t[i + 4];
    if (gteC(r.v, P.fq)) {
        ulong o[4];
        subC(r.v, P.fq, o);
        for (int i = 0; i < 4; i++) r.v[i] = o[i];
    }
    return r;
}

static Fe feSqr(Fe a, constant Params &P) {
    return feMul(a, a, P);
}

static bool feIs0(Fe a) {
    return (a.v[0] | a.v[1] | a.v[2] | a.v[3]) == 0;
}

static Fe feLoad(device const ulong *p) {
    Fe r;
    for (int i = 0; i < 4; i++) r.v[i] = p[i];
    return r;
}

static void feStore(Fe a, device ulong *p) {
    for (int i = 0; i < 4; i++) p[i] = a.v[i];
}

static Fe feOne(constant Params &P) {
    Fe r;
    for (int i = 0; i < 4; i++) r.v[i] = P.one[i];
    return r;
}

static void dbl(thread Jac &A, constant Params &P) {
    if (feIs0(A.z)) return;
    Fe x1 = A.x;
    Fe y1 = A.y;
    Fe z1 = A.z;
    Fe a = feSqr(x1, P);
    Fe b = feSqr(y1, P);
    Fe c = feSqr(b, P);
    Fe xb = feAdd(x1, b, P);
    Fe d = feSub(feSub(feSqr(xb, P), a, P), c, P);
    d = feAdd(d, d, P);
    Fe e = feAdd(feAdd(a, a, P), a, P);
    Fe f = feSqr(e, P);
    Fe x3 = feSub(f, feAdd(d, d, P), P);
    Fe eightC = feAdd(feAdd(c, c, P), feAdd(c, c, P), P);
    eightC = feAdd(eightC, eightC, P);
    Fe y3 = feSub(feMul(e, feSub(d, x3, P), P), eightC, P);
    Fe y2 = feAdd(y1, y1, P);
    Fe z3 = feMul(y2, z1, P);
    A.x = x3;
    A.y = y3;
    A.z = z3;
}

static void addAff(thread Jac &A, Fe px, Fe py, constant Params &P) {
    if (feIs0(px) && feIs0(py)) return;
    if (feIs0(A.z)) {
        A.x = px;
        A.y = py;
        A.z = feOne(P);
        return;
    }
    Fe z1z1 = feSqr(A.z, P);
    Fe uu2 = feMul(px, z1z1, P);
    Fe s2 = feMul(feMul(py, A.z, P), z1z1, P);
    Fe h = feSub(uu2, A.x, P);
    Fe sdiff = feSub(s2, A.y, P);
    if (feIs0(h)) {
        if (feIs0(sdiff)) {
            dbl(A, P);
        } else {
            A.x.v[0] = A.x.v[1] = A.x.v[2] = A.x.v[3] = 0;
            A.y.v[0] = A.y.v[1] = A.y.v[2] = A.y.v[3] = 0;
            A.z.v[0] = A.z.v[1] = A.z.v[2] = A.z.v[3] = 0;
        }
        return;
    }
    Fe hh = feSqr(h, P);
    Fe ii = feAdd(feAdd(hh, hh, P), feAdd(hh, hh, P), P);
    Fe j = feMul(h, ii, P);
    Fe rr = feAdd(sdiff, sdiff, P);
    Fe v = feMul(A.x, ii, P);
    Fe x3 = feSub(feSub(feSqr(rr, P), j, P), feAdd(v, v, P), P);
    Fe y3 = feSub(feMul(rr, feSub(v, x3, P), P), feMul(feAdd(A.y, A.y, P), j, P), P);
    Fe zsum = feAdd(A.z, h, P);
    Fe z3 = feSub(feSub(feSqr(zsum, P), z1z1, P), hh, P);
    A.x = x3;
    A.y = y3;
    A.z = z3;
}

static void addJac(thread Jac &A, thread Jac &B, constant Params &P) {
    if (feIs0(B.z)) return;
    if (feIs0(A.z)) {
        A = B;
        return;
    }
    Fe z1z1 = feSqr(A.z, P);
    Fe z2z2 = feSqr(B.z, P);
    Fe u1 = feMul(A.x, z2z2, P);
    Fe u2 = feMul(B.x, z1z1, P);
    Fe s1 = feMul(feMul(A.y, B.z, P), z2z2, P);
    Fe s2 = feMul(feMul(B.y, A.z, P), z1z1, P);
    Fe h = feSub(u2, u1, P);
    Fe sd = feSub(s2, s1, P);
    if (feIs0(h)) {
        if (feIs0(sd)) dbl(A, P);
        else {
            A.z.v[0] = A.z.v[1] = A.z.v[2] = A.z.v[3] = 0;
        }
        return;
    }
    Fe hh = feSqr(h, P);
    Fe ii = feAdd(feAdd(hh, hh, P), feAdd(hh, hh, P), P);
    Fe j = feMul(h, ii, P);
    Fe rr = feAdd(sd, sd, P);
    Fe v = feMul(u1, ii, P);
    Fe x3 = feSub(feSub(feSqr(rr, P), j, P), feAdd(v, v, P), P);
    Fe y3 = feSub(feMul(rr, feSub(v, x3, P), P), feMul(feAdd(s1, s1, P), j, P), P);
    Fe zs = feAdd(A.z, B.z, P);
    Fe z3 = feMul(feSub(feSub(feSqr(zs, P), z1z1, P), z2z2, P), h, P);
    A.x = x3;
    A.y = y3;
    A.z = z3;
}

static Fe feInv(Fe a, constant Params &P) {
    // a^(p-2). Exponent is fq - 2.
    ulong exp[4];
    for (int i = 0; i < 4; i++) exp[i] = P.fq[i];
    ulong borrow = 2;
    for (int i = 0; i < 4; i++) {
        ulong d = exp[i] - borrow;
        ulong b = exp[i] < borrow ? 1 : 0;
        exp[i] = d;
        borrow = b;
    }
    Fe result = feOne(P);
    Fe base = a;
    for (int li = 0; li < 4; li++) {
        ulong e = exp[li];
        for (int bit = 0; bit < 64; bit++) {
            if ((e & 1ull) == 1ull) result = feMul(result, base, P);
            base = feSqr(base, P);
            e >>= 1;
        }
    }
    return result;
}

static void toAffine(thread Jac &A, thread Fe &ox, thread Fe &oy, constant Params &P) {
    if (feIs0(A.z)) {
        ox.v[0] = ox.v[1] = ox.v[2] = ox.v[3] = 0;
        oy.v[0] = oy.v[1] = oy.v[2] = oy.v[3] = 0;
        return;
    }
    Fe zinv = feInv(A.z, P);
    Fe z2 = feSqr(zinv, P);
    ox = feMul(A.x, z2, P);
    oy = feMul(A.y, feMul(z2, zinv, P), P);
}

static int highestBit(thread const ulong k[4]) {
    for (int i = 3; i >= 0; i--) {
        if (k[i] != 0) return i * 64 + 63 - clz(k[i]);
    }
    return -1;
}

static ulong bitAt(thread const ulong k[4], int i) {
    return (k[i / 64] >> (i % 64)) & 1ull;
}

static void normalizeScalar(thread ulong k[4], thread bool &flip, constant Params &P) {
    flip = false;
    if (gteC(k, P.fr)) {
        ulong t[4];
        subC(k, P.fr, t);
        for (int i = 0; i < 4; i++) k[i] = t[i];
    }
    bool above_half = false;
    if (gteC(k, P.fr_half)) {
        for (int i = 0; i < 4; i++) {
            if (k[i] != P.fr_half[i]) above_half = true;
        }
    }
    if (above_half) {
        ulong t[4];
        // fr - k
        subMod(P.fr, k, t);
        for (int i = 0; i < 4; i++) k[i] = t[i];
        flip = true;
    }
}

static void mulPoint(Fe px, Fe py, thread const ulong scalar[4], thread Fe &ox, thread Fe &oy, constant Params &P) {
    if ((feIs0(px) && feIs0(py)) || (scalar[0] | scalar[1] | scalar[2] | scalar[3]) == 0) {
        ox.v[0] = ox.v[1] = ox.v[2] = ox.v[3] = 0;
        oy.v[0] = oy.v[1] = oy.v[2] = oy.v[3] = 0;
        return;
    }
    ulong k[4];
    for (int i = 0; i < 4; i++) k[i] = scalar[i];
    bool flip = false;
    normalizeScalar(k, flip, P);
    int hb = highestBit(k);
    if (hb < 0) {
        ox.v[0] = ox.v[1] = ox.v[2] = ox.v[3] = 0;
        oy.v[0] = oy.v[1] = oy.v[2] = oy.v[3] = 0;
        return;
    }
    Jac table[16];
    for (int i = 0; i < 4; i++) {
        table[0].x.v[i] = 0;
        table[0].y.v[i] = 0;
        table[0].z.v[i] = 0;
    }
    table[1].x = px;
    table[1].y = py;
    table[1].z = feOne(P);
    for (int i = 2; i < 16; i++) {
        table[i] = table[i - 1];
        addAff(table[i], px, py, P);
    }
    Jac acc;
    for (int i = 0; i < 4; i++) {
        acc.x.v[i] = 0;
        acc.y.v[i] = 0;
        acc.z.v[i] = 0;
    }
    bool started = false;
    int bit = hb;
    while (bit >= 0) {
        int n = 4;
        if (bit + 1 < 4) n = bit + 1;
        ulong nib = 0;
        for (int step = 0; step < n; step++) {
            nib = (nib << 1) | bitAt(k, bit - step);
        }
        if (!started) {
            if (nib != 0) {
                acc = table[nib];
                started = true;
            }
        } else {
            for (int d = 0; d < n; d++) dbl(acc, P);
            if (nib != 0) addJac(acc, table[nib], P);
        }
        bit -= n;
    }
    if (flip) acc.y = feNeg(acc.y, P);
    toAffine(acc, ox, oy, P);
}

kernel void g1_mul_same(
    device const ulong *points [[buffer(0)]],
    device ulong *out [[buffer(1)]],
    constant ulong *scalar [[buffer(2)]],
    constant Params &P [[buffer(3)]],
    uint gid [[thread_position_in_grid]]) {
    ulong k[4];
    for (int i = 0; i < 4; i++) k[i] = scalar[i];
    device const ulong *in = points + gid * 8;
    Fe px = feLoad(in);
    Fe py = feLoad(in + 4);
    Fe ox, oy;
    mulPoint(px, py, k, ox, oy, P);
    feStore(ox, out + gid * 8);
    feStore(oy, out + gid * 8 + 4);
}

kernel void g1_mul_many(
    device const ulong *points [[buffer(0)]],
    device ulong *out [[buffer(1)]],
    device const ulong *scalars [[buffer(2)]],
    constant Params &P [[buffer(3)]],
    uint gid [[thread_position_in_grid]]) {
    device const ulong *in = points + gid * 8;
    device const ulong *sc = scalars + gid * 4;
    ulong k[4];
    for (int i = 0; i < 4; i++) k[i] = sc[i];
    Fe px = feLoad(in);
    Fe py = feLoad(in + 4);
    Fe ox, oy;
    mulPoint(px, py, k, ox, oy, P);
    feStore(ox, out + gid * 8);
    feStore(oy, out + gid * 8 + 4);
}

// G2 is the same Jacobian arithmetic over Fq2, u^2 = -1.
// The host decomposes the scalar and passes φ-adjusted points, so each thread
// only runs the 128-bit joint double-and-add.

struct Fe2 {
    Fe c0;
    Fe c1;
};

struct Jac2 {
    Fe2 x;
    Fe2 y;
    Fe2 z;
};

static bool fe2Is0(Fe2 a) {
    return feIs0(a.c0) && feIs0(a.c1);
}

static Fe2 fe2Add(Fe2 a, Fe2 b, constant Params &P) {
    Fe2 r;
    r.c0 = feAdd(a.c0, b.c0, P);
    r.c1 = feAdd(a.c1, b.c1, P);
    return r;
}

static Fe2 fe2Sub(Fe2 a, Fe2 b, constant Params &P) {
    Fe2 r;
    r.c0 = feSub(a.c0, b.c0, P);
    r.c1 = feSub(a.c1, b.c1, P);
    return r;
}

__attribute__((noinline)) static Fe2 fe2Mul(Fe2 a, Fe2 b, constant Params &P) {
    Fe a0b0 = feMul(a.c0, b.c0, P);
    Fe a1b1 = feMul(a.c1, b.c1, P);
    Fe a0b1 = feMul(a.c0, b.c1, P);
    Fe a1b0 = feMul(a.c1, b.c0, P);
    Fe2 r;
    r.c0 = feSub(a0b0, a1b1, P);
    r.c1 = feAdd(a0b1, a1b0, P);
    return r;
}

__attribute__((noinline)) static Fe2 fe2Sqr(Fe2 a, constant Params &P) {
    Fe a0s = feSqr(a.c0, P);
    Fe a1s = feSqr(a.c1, P);
    Fe prod = feMul(a.c0, a.c1, P);
    Fe2 r;
    r.c0 = feSub(a0s, a1s, P);
    r.c1 = feAdd(prod, prod, P);
    return r;
}

static Fe2 fe2One(constant Params &P) {
    Fe2 r;
    r.c0 = feOne(P);
    r.c1.v[0] = r.c1.v[1] = r.c1.v[2] = r.c1.v[3] = 0;
    return r;
}

static Fe2 fe2Load(device const ulong *p) {
    Fe2 r;
    r.c0 = feLoad(p);
    r.c1 = feLoad(p + 4);
    return r;
}

static void fe2Store(Fe2 a, device ulong *p) {
    feStore(a.c0, p);
    feStore(a.c1, p + 4);
}

static void jac2Zero(thread Jac2 &A) {
    for (int i = 0; i < 4; i++) {
        A.x.c0.v[i] = A.x.c1.v[i] = 0;
        A.y.c0.v[i] = A.y.c1.v[i] = 0;
        A.z.c0.v[i] = A.z.c1.v[i] = 0;
    }
}

__attribute__((noinline)) static void dbl2(thread Jac2 &A, constant Params &P) {
    if (fe2Is0(A.z)) return;
    Fe2 x1 = A.x;
    Fe2 y1 = A.y;
    Fe2 z1 = A.z;
    Fe2 a = fe2Sqr(x1, P);
    Fe2 b = fe2Sqr(y1, P);
    Fe2 c = fe2Sqr(b, P);
    Fe2 xb = fe2Add(x1, b, P);
    Fe2 d = fe2Sub(fe2Sub(fe2Sqr(xb, P), a, P), c, P);
    d = fe2Add(d, d, P);
    Fe2 e = fe2Add(fe2Add(a, a, P), a, P);
    Fe2 f = fe2Sqr(e, P);
    Fe2 x3 = fe2Sub(f, fe2Add(d, d, P), P);
    Fe2 eightC = fe2Add(fe2Add(c, c, P), fe2Add(c, c, P), P);
    eightC = fe2Add(eightC, eightC, P);
    Fe2 y3 = fe2Sub(fe2Mul(e, fe2Sub(d, x3, P), P), eightC, P);
    Fe2 z3 = fe2Mul(fe2Add(y1, y1, P), z1, P);
    A.x = x3;
    A.y = y3;
    A.z = z3;
}

__attribute__((noinline)) static void addAff2(thread Jac2 &A, Fe2 px, Fe2 py, constant Params &P) {
    if (fe2Is0(px) && fe2Is0(py)) return;
    if (fe2Is0(A.z)) {
        A.x = px;
        A.y = py;
        A.z = fe2One(P);
        return;
    }
    Fe2 z1z1 = fe2Sqr(A.z, P);
    Fe2 uu2 = fe2Mul(px, z1z1, P);
    Fe2 s2 = fe2Mul(fe2Mul(py, A.z, P), z1z1, P);
    Fe2 h = fe2Sub(uu2, A.x, P);
    Fe2 sdiff = fe2Sub(s2, A.y, P);
    if (fe2Is0(h)) {
        if (fe2Is0(sdiff)) dbl2(A, P);
        else jac2Zero(A);
        return;
    }
    Fe2 hh = fe2Sqr(h, P);
    Fe2 ii = fe2Add(fe2Add(hh, hh, P), fe2Add(hh, hh, P), P);
    Fe2 j = fe2Mul(h, ii, P);
    Fe2 rr = fe2Add(sdiff, sdiff, P);
    Fe2 v = fe2Mul(A.x, ii, P);
    Fe2 x3 = fe2Sub(fe2Sub(fe2Sqr(rr, P), j, P), fe2Add(v, v, P), P);
    Fe2 y3 = fe2Sub(fe2Mul(rr, fe2Sub(v, x3, P), P), fe2Mul(fe2Add(A.y, A.y, P), j, P), P);
    Fe2 zsum = fe2Add(A.z, h, P);
    Fe2 z3 = fe2Sub(fe2Sub(fe2Sqr(zsum, P), z1z1, P), hh, P);
    A.x = x3;
    A.y = y3;
    A.z = z3;
}

__attribute__((noinline)) static void addJac2(thread Jac2 &A, thread Jac2 &B, constant Params &P) {
    if (fe2Is0(B.z)) return;
    if (fe2Is0(A.z)) {
        A = B;
        return;
    }
    Fe2 z1z1 = fe2Sqr(A.z, P);
    Fe2 z2z2 = fe2Sqr(B.z, P);
    Fe2 u1 = fe2Mul(A.x, z2z2, P);
    Fe2 u2 = fe2Mul(B.x, z1z1, P);
    Fe2 s1 = fe2Mul(fe2Mul(A.y, B.z, P), z2z2, P);
    Fe2 s2 = fe2Mul(fe2Mul(B.y, A.z, P), z1z1, P);
    Fe2 h = fe2Sub(u2, u1, P);
    Fe2 sd = fe2Sub(s2, s1, P);
    if (fe2Is0(h)) {
        if (fe2Is0(sd)) dbl2(A, P);
        else jac2Zero(A);
        return;
    }
    Fe2 hh = fe2Sqr(h, P);
    Fe2 ii = fe2Add(fe2Add(hh, hh, P), fe2Add(hh, hh, P), P);
    Fe2 j = fe2Mul(h, ii, P);
    Fe2 rr = fe2Add(sd, sd, P);
    Fe2 v = fe2Mul(u1, ii, P);
    Fe2 x3 = fe2Sub(fe2Sub(fe2Sqr(rr, P), j, P), fe2Add(v, v, P), P);
    Fe2 y3 = fe2Sub(fe2Mul(rr, fe2Sub(v, x3, P), P), fe2Mul(fe2Add(s1, s1, P), j, P), P);
    Fe2 zs = fe2Add(A.z, B.z, P);
    Fe2 z3 = fe2Mul(fe2Sub(fe2Sub(fe2Sqr(zs, P), z1z1, P), z2z2, P), h, P);
    A.x = x3;
    A.y = y3;
    A.z = z3;
}

static void fe2StoreJac(thread Jac2 &A, device ulong *p) {
    fe2Store(A.x, p);
    fe2Store(A.y, p + 8);
    fe2Store(A.z, p + 16);
}

kernel void g2_glv_many(
    device const ulong *p1 [[buffer(0)]],
    device ulong *out [[buffer(1)]],
    device const ulong *p2 [[buffer(2)]],
    device const ulong *ks [[buffer(3)]],
    constant Params &P [[buffer(4)]],
    uint gid [[thread_position_in_grid]]) {
    device const ulong *in1 = p1 + gid * 16;
    device const ulong *in2 = p2 + gid * 16;
    device const ulong *sc = ks + gid * 4;
    ulong k1[2] = {sc[0], sc[1]};
    ulong k2[2] = {sc[2], sc[3]};
    Fe2 b1x = fe2Load(in1);
    Fe2 b1y = fe2Load(in1 + 8);
    Fe2 b2x = fe2Load(in2);
    Fe2 b2y = fe2Load(in2 + 8);
    device ulong *dst = out + gid * 24;
    if (((k1[0] | k1[1] | k2[0] | k2[1]) == 0) || (fe2Is0(b1x) && fe2Is0(b1y))) {
        for (int i = 0; i < 24; i++) dst[i] = 0;
        return;
    }
    Jac2 both;
    jac2Zero(both);
    addAff2(both, b1x, b1y, P);
    addAff2(both, b2x, b2y, P);
    Jac2 acc;
    jac2Zero(acc);
#pragma clang loop unroll(disable)
    for (int bit = 127; bit >= 0; bit--) {
        ulong a = (k1[bit / 64] >> (bit % 64)) & 1ull;
        ulong c = (k2[bit / 64] >> (bit % 64)) & 1ull;
        if (fe2Is0(acc.z) && a == 0 && c == 0) continue;
        dbl2(acc, P);
        if (a == 1 && c == 1) addJac2(acc, both, P);
        else if (a == 1) addAff2(acc, b1x, b1y, P);
        else if (c == 1) addAff2(acc, b2x, b2y, P);
    }
    fe2StoreJac(acc, dst);
}
