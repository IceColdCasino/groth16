#extension GL_GOOGLE_include_directive : require

#include "field.glsl"

// ============================================================================
// BN254 G1 Curve Operations (projective xyzz coordinates)
// ============================================================================
// G1 is defined over Fq with equation y^2 = x^3 + 3 (a = 0, b = 3).
// We use the xyzz projective representation from EFD.
// Point at infinity: zz = 0, zzz = 0 (x and y are set to 1 conventionally)
// ============================================================================

struct G1Point {
    FqElement x;
    FqElement y;
    FqElement zz;
    FqElement zzz;
};

struct G1PointAffine {
    FqElement x;
    FqElement y;
};

// Forward declaration
G1Point g1_dbl(G1Point p1);

// ---------------------------------------------------------------------------
// Point predicates / constructors
// ---------------------------------------------------------------------------

bool g1_is_zero(G1Point p) {
    return (p.zz.v[0] == 0UL && p.zz.v[1] == 0UL &&
            p.zz.v[2] == 0UL && p.zz.v[3] == 0UL);
}

G1Point g1_zero() {
    G1Point p;
    p.x   = fq_from_u64(1UL);
    p.y   = fq_from_u64(1UL);
    p.zz  = fq_from_u64(0UL);
    p.zzz = fq_from_u64(0UL);
    return p;
}

G1Point g1_affine_to_projective(G1PointAffine a) {
    // Check for the point at infinity (x = 0, y = 0 in affine coordinates)
    if (a.x.v[0] == 0UL && a.x.v[1] == 0UL && a.x.v[2] == 0UL && a.x.v[3] == 0UL &&
        a.y.v[0] == 0UL && a.y.v[1] == 0UL && a.y.v[2] == 0UL && a.y.v[3] == 0UL) {
        return g1_zero();
    }
    G1Point p;
    p.x   = a.x;
    p.y   = a.y;
    p.zz  = fq_montgomery_one();
    p.zzz = fq_montgomery_one();
    return p;
}

// ---------------------------------------------------------------------------
// G1 mixed addition: projective + affine (xyzz)
// https://www.hyperelliptic.org/EFD/g1p/auto-shortw-xyzz.html#addition-add-2008-s
// ---------------------------------------------------------------------------

G1Point g1_add_affine(G1Point p1, G1PointAffine p2) {
    if (g1_is_zero(p1)) return g1_affine_to_projective(p2);

    bool p2_is_zero = (p2.x.v[0] == 0UL && p2.x.v[1] == 0UL && p2.x.v[2] == 0UL && p2.x.v[3] == 0UL &&
                       p2.y.v[0] == 0UL && p2.y.v[1] == 0UL && p2.y.v[2] == 0UL && p2.y.v[3] == 0UL);
    if (p2_is_zero) return p1;

    FqElement U1 = p1.x;
    FqElement U2 = fq_mul(p2.x, p1.zz);
    FqElement S1 = p1.y;
    FqElement S2 = fq_mul(p2.y, p1.zzz);

    FqElement P = fq_sub(U2, U1);
    FqElement R = fq_sub(S2, S1);

    bool P_is_zero = (P.v[0] == 0UL && P.v[1] == 0UL && P.v[2] == 0UL && P.v[3] == 0UL);
    bool R_is_zero = (R.v[0] == 0UL && R.v[1] == 0UL && R.v[2] == 0UL && R.v[3] == 0UL);
    if (P_is_zero && R_is_zero) {
        return g1_dbl(p1);
    }

    FqElement PP = fq_mul(P, P);
    FqElement PPP = fq_mul(P, PP);
    FqElement Q = fq_mul(U1, PP);

    G1Point p3;

    FqElement R2 = fq_mul(R, R);
    FqElement t1  = fq_sub(R2, PPP);
    FqElement t2  = fq_sub(t1, Q);
    p3.x = fq_sub(t2, Q);

    FqElement QmX3 = fq_sub(Q, p3.x);
    FqElement R_QmX3 = fq_mul(R, QmX3);
    FqElement S1_PPP = fq_mul(S1, PPP);
    p3.y = fq_sub(R_QmX3, S1_PPP);

    p3.zz = fq_mul(p1.zz, PP);
    p3.zzz = fq_mul(p1.zzz, PPP);

    return p3;
}

// ---------------------------------------------------------------------------
// G1 addition: projective + projective (xyzz)
// https://www.hyperelliptic.org/EFD/g1p/auto-shortw-xyzz.html#addition-add-2008-s
// ---------------------------------------------------------------------------

G1Point g1_add(G1Point p1, G1Point p2) {
    if (g1_is_zero(p1)) return p2;
    if (g1_is_zero(p2)) return p1;

    FqElement U1 = fq_mul(p1.x, p2.zz);
    FqElement U2 = fq_mul(p2.x, p1.zz);
    FqElement S1 = fq_mul(p1.y, p2.zzz);
    FqElement S2 = fq_mul(p2.y, p1.zzz);

    FqElement P = fq_sub(U2, U1);
    FqElement R = fq_sub(S2, S1);

    bool P_is_zero = (P.v[0] == 0UL && P.v[1] == 0UL && P.v[2] == 0UL && P.v[3] == 0UL);
    bool R_is_zero = (R.v[0] == 0UL && R.v[1] == 0UL && R.v[2] == 0UL && R.v[3] == 0UL);
    if (P_is_zero && R_is_zero) {
        return g1_dbl(p1);
    }

    FqElement PP = fq_mul(P, P);
    FqElement PPP = fq_mul(P, PP);
    FqElement Q = fq_mul(U1, PP);

    G1Point p3;

    FqElement R2 = fq_mul(R, R);
    FqElement t1  = fq_sub(R2, PPP);
    FqElement t2  = fq_sub(t1, Q);
    p3.x = fq_sub(t2, Q);

    FqElement QmX3 = fq_sub(Q, p3.x);
    FqElement R_QmX3 = fq_mul(R, QmX3);
    FqElement S1_PPP = fq_mul(S1, PPP);
    p3.y = fq_sub(R_QmX3, S1_PPP);

    FqElement ZZ1_ZZ2 = fq_mul(p1.zz, p2.zz);
    p3.zz = fq_mul(ZZ1_ZZ2, PP);

    FqElement ZZZ1_ZZZ2 = fq_mul(p1.zzz, p2.zzz);
    p3.zzz = fq_mul(ZZZ1_ZZZ2, PPP);

    return p3;
}

// ---------------------------------------------------------------------------
// G1 doubling: 2*P (xyzz)
// https://www.hyperelliptic.org/EFD/g1p/auto-shortw-xyzz.html#doubling-dbl-2008-s
// ---------------------------------------------------------------------------

G1Point g1_dbl(G1Point p1) {
    if (g1_is_zero(p1)) return p1;

    FqElement U = fq_add(p1.y, p1.y);
    FqElement V = fq_mul(U, U);
    FqElement W = fq_mul(U, V);
    FqElement S = fq_mul(p1.x, V);

    FqElement M = fq_mul(p1.x, p1.x);
    FqElement M2 = fq_add(M, M);
    M = fq_add(M, M2);

    G1Point p3;

    FqElement M_sq = fq_mul(M, M);
    p3.x = fq_sub(M_sq, S);
    p3.x = fq_sub(p3.x, S);

    FqElement SmX3 = fq_sub(S, p3.x);
    FqElement M_SmX3 = fq_mul(M, SmX3);
    FqElement W_Y1 = fq_mul(W, p1.y);
    p3.y = fq_sub(M_SmX3, W_Y1);

    p3.zz = fq_mul(V, p1.zz);
    p3.zzz = fq_mul(W, p1.zzz);

    return p3;
}

// ============================================================================
// BN254 G2 Curve Operations (projective xyzz over Fq2)
// ============================================================================

struct G2Point {
    Fq2Element x;
    Fq2Element y;
    Fq2Element zz;
    Fq2Element zzz;
};

struct G2PointAffine {
    Fq2Element x;
    Fq2Element y;
};

void g2_zero(out G2Point out_p) {
    out_p.x   = Fq2Element(fq_from_u64(1UL), fq_from_u64(0UL));
    out_p.y   = Fq2Element(fq_from_u64(1UL), fq_from_u64(0UL));
    out_p.zz  = Fq2Element(fq_from_u64(0UL), fq_from_u64(0UL));
    out_p.zzz = Fq2Element(fq_from_u64(0UL), fq_from_u64(0UL));
}

bool g2_is_zero(G2Point p) {
    return (p.zz.a.v[0] == 0UL && p.zz.a.v[1] == 0UL && p.zz.a.v[2] == 0UL && p.zz.a.v[3] == 0UL &&
            p.zz.b.v[0] == 0UL && p.zz.b.v[1] == 0UL && p.zz.b.v[2] == 0UL && p.zz.b.v[3] == 0UL);
}

void g2_affine_to_projective(G2PointAffine a, out G2Point out_p) {
    if (a.x.a.v[0] == 0UL && a.x.a.v[1] == 0UL && a.x.a.v[2] == 0UL && a.x.a.v[3] == 0UL &&
        a.x.b.v[0] == 0UL && a.x.b.v[1] == 0UL && a.x.b.v[2] == 0UL && a.x.b.v[3] == 0UL &&
        a.y.a.v[0] == 0UL && a.y.a.v[1] == 0UL && a.y.a.v[2] == 0UL && a.y.a.v[3] == 0UL &&
        a.y.b.v[0] == 0UL && a.y.b.v[1] == 0UL && a.y.b.v[2] == 0UL && a.y.b.v[3] == 0UL) {
        g2_zero(out_p);
        return;
    }
    out_p.x   = a.x;
    out_p.y   = a.y;
    out_p.zz  = Fq2Element(fq_montgomery_one(), fq_from_u64(0UL));
    out_p.zzz = Fq2Element(fq_montgomery_one(), fq_from_u64(0UL));
}

void g2_dbl(in G2Point p1, out G2Point out_p) {
    if (g2_is_zero(p1)) {
        out_p = p1;
        return;
    }

    Fq2Element U = fq2_add(p1.y, p1.y);
    Fq2Element V = fq2_mul(U, U);
    Fq2Element W = fq2_mul(U, V);
    Fq2Element S = fq2_mul(p1.x, V);

    Fq2Element M = fq2_mul(p1.x, p1.x);
    Fq2Element M2 = fq2_add(M, M);
    M = fq2_add(M, M2);

    Fq2Element M_sq = fq2_mul(M, M);
    out_p.x = fq2_sub(M_sq, S);
    out_p.x = fq2_sub(out_p.x, S);

    Fq2Element SmX3 = fq2_sub(S, out_p.x);
    Fq2Element M_SmX3 = fq2_mul(M, SmX3);
    Fq2Element W_Y1 = fq2_mul(W, p1.y);
    out_p.y = fq2_sub(M_SmX3, W_Y1);

    out_p.zz = fq2_mul(V, p1.zz);
    out_p.zzz = fq2_mul(W, p1.zzz);
}

void g2_add(in G2Point p1, in G2Point p2, out G2Point out_p) {
    if (g2_is_zero(p1)) {
        out_p = p2;
        return;
    }
    if (g2_is_zero(p2)) {
        out_p = p1;
        return;
    }

    Fq2Element U1 = fq2_mul(p1.x, p2.zz);
    Fq2Element U2 = fq2_mul(p2.x, p1.zz);
    Fq2Element S1 = fq2_mul(p1.y, p2.zzz);
    Fq2Element S2 = fq2_mul(p2.y, p1.zzz);

    Fq2Element P = fq2_sub(U2, U1);
    Fq2Element R = fq2_sub(S2, S1);

    bool P_is_zero = fq2_is_zero(P);
    bool R_is_zero = fq2_is_zero(R);
    if (P_is_zero && R_is_zero) {
        g2_dbl(p1, out_p);
        return;
    }

    Fq2Element PP = fq2_mul(P, P);
    Fq2Element PPP = fq2_mul(P, PP);
    Fq2Element Q = fq2_mul(U1, PP);

    Fq2Element R2 = fq2_mul(R, R);
    Fq2Element t1  = fq2_sub(R2, PPP);
    Fq2Element t2  = fq2_sub(t1, Q);
    out_p.x = fq2_sub(t2, Q);

    Fq2Element QmX3 = fq2_sub(Q, out_p.x);
    Fq2Element R_QmX3 = fq2_mul(R, QmX3);
    Fq2Element S1_PPP = fq2_mul(S1, PPP);
    out_p.y = fq2_sub(R_QmX3, S1_PPP);

    Fq2Element ZZ1_ZZ2 = fq2_mul(p1.zz, p2.zz);
    out_p.zz = fq2_mul(ZZ1_ZZ2, PP);

    Fq2Element ZZZ1_ZZZ2 = fq2_mul(p1.zzz, p2.zzz);
    out_p.zzz = fq2_mul(ZZZ1_ZZZ2, PPP);
}
