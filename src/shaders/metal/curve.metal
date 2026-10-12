#include <metal_stdlib>
#include "field.metal"
using namespace metal;

// ============================================================================
// BN254 G1 Curve Operations (projective xyzz coordinates)
// ============================================================================
//
// G1 is defined over Fq with equation y^2 = x^3 + 3  (a = 0, b = 3).
// We use the xyzz projective representation from EFD:
//   https://www.hyperelliptic.org/EFD/g1p/auto-shortw-xyzz.html
//
// Point at infinity: zz = 0, zzz = 0  (x and y are set to 1 conventionally)
//
// ============================================================================

typedef struct {
    FqElement x;
    FqElement y;
    FqElement zz;
    FqElement zzz;
} G1Point;

typedef struct {
    FqElement x;
    FqElement y;
} G1PointAffine;

// Forward declarations
inline G1Point g1_dbl(const G1Point p1);
inline G1Point g1_neg(const G1Point p);

// ---------------------------------------------------------------------------
// Point predicates / constructors
// ---------------------------------------------------------------------------

inline bool g1_is_zero(const G1Point p) {
    return (p.zz.v[0] == 0 && p.zz.v[1] == 0 &&
            p.zz.v[2] == 0 && p.zz.v[3] == 0);
}

inline G1Point g1_zero(void) {
    G1Point p;
    p.x   = fq_from_u64(1);
    p.y   = fq_from_u64(1);
    p.zz  = fq_from_u64(0);
    p.zzz = fq_from_u64(0);
    return p;
}

inline G1Point g1_affine_to_projective(const G1PointAffine a) {
    // Check for the point at infinity (x = 0, y = 0 in affine coordinates)
    if (a.x.v[0] == 0 && a.x.v[1] == 0 && a.x.v[2] == 0 && a.x.v[3] == 0 &&
        a.y.v[0] == 0 && a.y.v[1] == 0 && a.y.v[2] == 0 && a.y.v[3] == 0) {
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
// G1 mixed addition:  projective + affine (xyzz)
//
// Faster than projective+projective because affine point has zz=zzz=1.
// https://www.hyperelliptic.org/EFD/g1p/auto-shortw-xyzz.html#addition-add-2008-s
// ---------------------------------------------------------------------------
inline G1Point g1_add_affine(const G1Point p1, const G1PointAffine p2) {
    if (g1_is_zero(p1)) return g1_affine_to_projective(p2);

    // Check if p2 is the point at infinity (x=0, y=0 in affine coordinates)
    bool p2_is_zero = (p2.x.v[0] == 0 && p2.x.v[1] == 0 && p2.x.v[2] == 0 && p2.x.v[3] == 0 &&
                       p2.y.v[0] == 0 && p2.y.v[1] == 0 && p2.y.v[2] == 0 && p2.y.v[3] == 0);
    if (p2_is_zero) return p1;

    // U1 = X1*1  (since ZZ2 = 1 for affine)
    FqElement U1 = p1.x;
    // U2 = X2*ZZ1
    FqElement U2 = fq_mul(p2.x, p1.zz);
    // S1 = Y1*1  (since ZZZ2 = 1 for affine)
    FqElement S1 = p1.y;
    // S2 = Y2*ZZZ1
    FqElement S2 = fq_mul(p2.y, p1.zzz);

    // P = U2 - U1
    FqElement P = fq_sub(U2, U1);
    // R = S2 - S1
    FqElement R = fq_sub(S2, S1);

    bool P_is_zero = (P.v[0] == 0 && P.v[1] == 0 && P.v[2] == 0 && P.v[3] == 0);
    bool R_is_zero = (R.v[0] == 0 && R.v[1] == 0 && R.v[2] == 0 && R.v[3] == 0);
    if (P_is_zero && R_is_zero) {
        return g1_dbl(p1);
    }

    // PP = P^2
    FqElement PP = fq_mul(P, P);
    // PPP = P*PP
    FqElement PPP = fq_mul(P, PP);
    // Q = U1*PP
    FqElement Q = fq_mul(U1, PP);

    G1Point p3;

    // X3 = R^2 - PPP - 2*Q
    FqElement R2 = fq_mul(R, R);
    FqElement t1  = fq_sub(R2, PPP);
    FqElement t2  = fq_sub(t1, Q);
    p3.x = fq_sub(t2, Q);

    // Y3 = R*(Q - X3) - S1*PPP
    FqElement QmX3 = fq_sub(Q, p3.x);
    FqElement R_QmX3 = fq_mul(R, QmX3);
    FqElement S1_PPP = fq_mul(S1, PPP);
    p3.y = fq_sub(R_QmX3, S1_PPP);

    // ZZ3 = ZZ1*PP  (since ZZ2 = 1)
    p3.zz = fq_mul(p1.zz, PP);

    // ZZZ3 = ZZZ1*PPP  (since ZZZ2 = 1)
    p3.zzz = fq_mul(p1.zzz, PPP);

    return p3;
}

// ---------------------------------------------------------------------------
// G1 addition:  projective + projective (xyzz)
//
// https://www.hyperelliptic.org/EFD/g1p/auto-shortw-xyzz.html#addition-add-2008-s
// ---------------------------------------------------------------------------

inline G1Point g1_add(const G1Point p1, const G1Point p2) {
    if (g1_is_zero(p1)) return p2;
    if (g1_is_zero(p2)) return p1;

    // U1 = X1*ZZ2
    FqElement U1 = fq_mul(p1.x, p2.zz);
    // U2 = X2*ZZ1
    FqElement U2 = fq_mul(p2.x, p1.zz);
    // S1 = Y1*ZZZ2
    FqElement S1 = fq_mul(p1.y, p2.zzz);
    // S2 = Y2*ZZZ1
    FqElement S2 = fq_mul(p2.y, p1.zzz);

    // P = U2 - U1
    FqElement P = fq_sub(U2, U1);
    // R = S2 - S1
    FqElement R = fq_sub(S2, S1);

    bool P_is_zero = (P.v[0] == 0 && P.v[1] == 0 && P.v[2] == 0 && P.v[3] == 0);
    bool R_is_zero = (R.v[0] == 0 && R.v[1] == 0 && R.v[2] == 0 && R.v[3] == 0);
    if (P_is_zero && R_is_zero) {
        return g1_dbl(p1);
    }

    // PP = P^2
    FqElement PP = fq_mul(P, P);
    // PPP = P*PP
    FqElement PPP = fq_mul(P, PP);
    // Q = U1*PP
    FqElement Q = fq_mul(U1, PP);

    G1Point p3;

    // X3 = R^2 - PPP - 2*Q
    FqElement R2 = fq_mul(R, R);
    FqElement t1  = fq_sub(R2, PPP);
    FqElement t2  = fq_sub(t1, Q);
    p3.x = fq_sub(t2, Q);

    // Y3 = R*(Q - X3) - S1*PPP
    FqElement QmX3 = fq_sub(Q, p3.x);
    FqElement R_QmX3 = fq_mul(R, QmX3);
    FqElement S1_PPP = fq_mul(S1, PPP);
    p3.y = fq_sub(R_QmX3, S1_PPP);

    // ZZ3 = ZZ1*ZZ2*PP
    FqElement ZZ1_ZZ2 = fq_mul(p1.zz, p2.zz);
    p3.zz = fq_mul(ZZ1_ZZ2, PP);

    // ZZZ3 = ZZZ1*ZZZ2*PPP
    FqElement ZZZ1_ZZZ2 = fq_mul(p1.zzz, p2.zzz);
    p3.zzz = fq_mul(ZZZ1_ZZZ2, PPP);

    return p3;
}

// ---------------------------------------------------------------------------
// G1 doubling:  2*P  (xyzz)
//
// https://www.hyperelliptic.org/EFD/g1p/auto-shortw-xyzz.html#doubling-dbl-2008-s
// ---------------------------------------------------------------------------

inline G1Point g1_dbl(const G1Point p1) {
    if (g1_is_zero(p1)) return p1;

    // U = 2*Y1
    FqElement U = fq_add(p1.y, p1.y);
    // V = U^2
    FqElement V = fq_mul(U, U);
    // W = U*V
    FqElement W = fq_mul(U, V);
    // S = X1*V
    FqElement S = fq_mul(p1.x, V);

    // M = 3*X1^2 + a*ZZ1^2
    // For BN254, a = 0, so M = 3*X1^2
    FqElement M = fq_mul(p1.x, p1.x);
    FqElement M2 = fq_add(M, M);
    M = fq_add(M, M2);            // 3*X1^2

    G1Point p3;

    // X3 = M^2 - 2*S
    FqElement M_sq = fq_mul(M, M);
    p3.x = fq_sub(M_sq, S);
    p3.x = fq_sub(p3.x, S);

    // Y3 = M*(S - X3) - W*Y1
    FqElement SmX3 = fq_sub(S, p3.x);
    FqElement M_SmX3 = fq_mul(M, SmX3);
    FqElement W_Y1 = fq_mul(W, p1.y);
    p3.y = fq_sub(M_SmX3, W_Y1);

    // ZZ3 = V*ZZ1
    p3.zz = fq_mul(V, p1.zz);

    // ZZZ3 = W*ZZZ1
    p3.zzz = fq_mul(W, p1.zzz);

    return p3;
}

// ---------------------------------------------------------------------------
// G1 negation: -(X, Y, ZZ, ZZZ) = (X, -Y, ZZ, ZZZ)
// ---------------------------------------------------------------------------
inline G1Point g1_neg(const G1Point p) {
    G1Point r;
    r.x   = p.x;
    r.y   = fq_sub(fq_from_u64(0), p.y);
    r.zz  = p.zz;
    r.zzz = p.zzz;
    return r;
}

// ---------------------------------------------------------------------------
// G1 subtraction: P - Q = P + (-Q)
// ---------------------------------------------------------------------------
inline G1Point g1_sub(const G1Point p1, const G1Point p2) {
    return g1_add(p1, g1_neg(p2));
}

// ============================================================================
// BN254 G2 Curve Operations (projective xyzz over Fq2)
// ============================================================================
//
// IMPORTANT: Metal's GPU backend compiler crashes when returning structs
// larger than ~128 bytes by value from functions called in compute kernels.
// All G2 operations MUST use output pointers instead of return-by-value.
// See: XPC_ERROR_CONNECTION_INTERRUPTED with 256-byte G2Point returns.
//
// ============================================================================

typedef struct {
    Fq2Element x;
    Fq2Element y;
    Fq2Element zz;
    Fq2Element zzz;
} G2Point;

typedef struct {
    Fq2Element x;
    Fq2Element y;
} G2PointAffine;

__attribute__((noinline))
inline void g2_dbl(const thread G2Point* p1, thread G2Point* out);

inline bool g2_is_zero(const thread G2Point* p) {
    return (p->zz.a.v[0] == 0 && p->zz.a.v[1] == 0 && p->zz.a.v[2] == 0 && p->zz.a.v[3] == 0 &&
            p->zz.b.v[0] == 0 && p->zz.b.v[1] == 0 && p->zz.b.v[2] == 0 && p->zz.b.v[3] == 0);
}

__attribute__((noinline))
inline void g2_zero(thread G2Point* out) {
    out->x   = Fq2Element{ fq_from_u64(1), fq_from_u64(0) };
    out->y   = Fq2Element{ fq_from_u64(1), fq_from_u64(0) };
    out->zz  = Fq2Element{ fq_from_u64(0), fq_from_u64(0) };
    out->zzz = Fq2Element{ fq_from_u64(0), fq_from_u64(0) };
}

__attribute__((noinline))
inline void g2_affine_to_projective(const thread G2PointAffine* a, thread G2Point* out) {
    // Check for the point at infinity (x = 0, y = 0 in affine coordinates)
    if (a->x.a.v[0] == 0 && a->x.a.v[1] == 0 && a->x.a.v[2] == 0 && a->x.a.v[3] == 0 &&
        a->x.b.v[0] == 0 && a->x.b.v[1] == 0 && a->x.b.v[2] == 0 && a->x.b.v[3] == 0 &&
        a->y.a.v[0] == 0 && a->y.a.v[1] == 0 && a->y.a.v[2] == 0 && a->y.a.v[3] == 0 &&
        a->y.b.v[0] == 0 && a->y.b.v[1] == 0 && a->y.b.v[2] == 0 && a->y.b.v[3] == 0) {
        g2_zero(out);
        return;
    }
    out->x   = a->x;
    out->y   = a->y;
    out->zz  = Fq2Element{ fq_montgomery_one(), fq_from_u64(0) };
    out->zzz = Fq2Element{ fq_montgomery_one(), fq_from_u64(0) };
}

inline void g2_add(const thread G2Point* p1, const thread G2Point* p2, thread G2Point* out) {
    if (g2_is_zero(p1)) {
        *out = *p2;
        return;
    }
    if (g2_is_zero(p2)) {
        *out = *p1;
        return;
    }

    Fq2Element U1 = fq2_mul(p1->x, p2->zz);
    Fq2Element U2 = fq2_mul(p2->x, p1->zz);
    Fq2Element S1 = fq2_mul(p1->y, p2->zzz);
    Fq2Element S2 = fq2_mul(p2->y, p1->zzz);

    Fq2Element P = fq2_sub(U2, U1);
    Fq2Element R = fq2_sub(S2, S1);

    bool P_is_zero = fq2_is_zero(P);
    bool R_is_zero = fq2_is_zero(R);
    if (P_is_zero && R_is_zero) {
        g2_dbl(p1, out);
        return;
    }

    Fq2Element PP = fq2_mul(P, P);
    Fq2Element PPP = fq2_mul(P, PP);
    Fq2Element Q = fq2_mul(U1, PP);

    Fq2Element R2 = fq2_mul(R, R);
    Fq2Element t1  = fq2_sub(R2, PPP);
    Fq2Element t2  = fq2_sub(t1, Q);
    out->x = fq2_sub(t2, Q);

    Fq2Element QmX3 = fq2_sub(Q, out->x);
    Fq2Element R_QmX3 = fq2_mul(R, QmX3);
    Fq2Element S1_PPP = fq2_mul(S1, PPP);
    out->y = fq2_sub(R_QmX3, S1_PPP);

    Fq2Element ZZ1_ZZ2 = fq2_mul(p1->zz, p2->zz);
    out->zz = fq2_mul(ZZ1_ZZ2, PP);

    Fq2Element ZZZ1_ZZZ2 = fq2_mul(p1->zzz, p2->zzz);
    out->zzz = fq2_mul(ZZZ1_ZZZ2, PPP);
}

__attribute__((noinline))
inline void g2_dbl(const thread G2Point* p1, thread G2Point* out) {
    if (g2_is_zero(p1)) {
        *out = *p1;
        return;
    }

    Fq2Element U = fq2_add(p1->y, p1->y);
    Fq2Element V = fq2_mul(U, U);
    Fq2Element W = fq2_mul(U, V);
    Fq2Element S = fq2_mul(p1->x, V);

    Fq2Element M = fq2_mul(p1->x, p1->x);
    Fq2Element M2 = fq2_add(M, M);
    M = fq2_add(M, M2);

    Fq2Element M_sq = fq2_mul(M, M);
    out->x = fq2_sub(M_sq, S);
    out->x = fq2_sub(out->x, S);

    Fq2Element SmX3 = fq2_sub(S, out->x);
    Fq2Element M_SmX3 = fq2_mul(M, SmX3);
    Fq2Element W_Y1 = fq2_mul(W, p1->y);
    out->y = fq2_sub(M_SmX3, W_Y1);

    out->zz = fq2_mul(V, p1->zz);
    out->zzz = fq2_mul(W, p1->zzz);
}
