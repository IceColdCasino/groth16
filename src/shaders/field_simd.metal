// ============================================================================
// BN254 SIMD Field Arithmetic (Fr and Fq)
// ============================================================================
//
// Vectorized 4-lane field operations using Metal's ulong4 SIMD types.
// Each lane operates on an independent field element.
//
// ============================================================================

#include <metal_stdlib>
#include "field.metal"
using namespace metal;

// SIMD 4-element Fr: interleaved limb layout
// v0 = {elem0.limb0, elem1.limb0, elem2.limb0, elem3.limb0}
typedef struct {
    ulong4 v0;
    ulong4 v1;
    ulong4 v2;
    ulong4 v3;
} FrElement4;

typedef struct {
    ulong4 v0;
    ulong4 v1;
    ulong4 v2;
    ulong4 v3;
} FqElement4;

// ---------------------------------------------------------------------------
// 128-bit multiply for ulong4 lanes (low 64 + high 64 of 64x64 product)
// Uses 32-bit split: a = a1<<32 + a0, b = b1<<32 + b0
// a*b = a1*b1<<64 + (a1*b0 + a0*b1)<<32 + a0*b0
// ---------------------------------------------------------------------------
inline void mul128_4(ulong4 a, ulong4 b, thread ulong4& lo, thread ulong4& hi) {
    uint4 a0 = uint4(a);
    uint4 a1 = uint4(a >> 32);
    uint4 b0 = uint4(b);
    uint4 b1 = uint4(b >> 32);

    uint4 p00 = a0 * b0;           // low 32x32
    uint4 p01 = a0 * b1;           // cross
    uint4 p10 = a1 * b0;           // cross
    uint4 p11 = a1 * b1;           // high 32x32

    // mid = p01 + p10, with carry
    uint4 mid = p01 + p10;
    uint4 mid_carry = select(uint4(0), uint4(1), mid < p01);

    // lo64 = p00 + (mid << 32), with carry into high
    uint4 mid_lo_shifted = uint4((ulong4(mid) << 32));
    uint4 lo_lo = p00 + mid_lo_shifted;
    uint4 lo_carry = select(uint4(0), uint4(1), lo_lo < p00);

    // Combine into 64-bit lo
    lo = ulong4(lo_lo) | (ulong4(mid) << 32);

    // hi64 = p11 + (mid >> 32) + mid_carry + lo_carry
    uint4 mid_hi_shifted = uint4((ulong4(mid) >> 32));
    uint4 hi_sum = p11 + mid_hi_shifted + mid_carry + lo_carry;
    hi = ulong4(hi_sum);
}

inline void add128_4(ulong4 a_lo, ulong4 a_hi, ulong4 b_lo, ulong4 b_hi,
                     thread ulong4& r_lo, thread ulong4& r_hi) {
    ulong4 lo = a_lo + b_lo;
    ulong4 hi = a_hi + b_hi + select(ulong4(0), ulong4(1), lo < a_lo);
    r_lo = lo;
    r_hi = hi;
}

inline void add128_u64_4(ulong4 a_lo, ulong4 a_hi, ulong4 b,
                           thread ulong4& r_lo, thread ulong4& r_hi) {
    ulong4 lo = a_lo + b;
    ulong4 hi = a_hi + select(ulong4(0), ulong4(1), lo < a_lo);
    r_lo = lo;
    r_hi = hi;
}

// ---------------------------------------------------------------------------
// SIMD Fr: Montgomery multiplication (CIOS, 4-limb, 4 elements in parallel)
// ---------------------------------------------------------------------------
inline FrElement4 fr_mul4(const FrElement4 a, const FrElement4 b) {
    ulong4 t0 = ulong4(0);
    ulong4 t1 = ulong4(0);
    ulong4 t2 = ulong4(0);
    ulong4 t3 = ulong4(0);
    ulong4 t4 = ulong4(0);

    ulong4 np = ulong4(FR_NP);
    FrElement q = fr_load_q();
    ulong4 q0 = ulong4(q.v[0]);
    ulong4 q1 = ulong4(q.v[1]);
    ulong4 q2 = ulong4(q.v[2]);
    ulong4 q3 = ulong4(q.v[3]);

    for (int i = 0; i < 4; i++) {
        // t += a * b[i]
        ulong4 bi = (i == 0) ? b.v0 : (i == 1) ? b.v1 : (i == 2) ? b.v2 : b.v3;
        ulong4 carry = ulong4(0);
        ulong4 mul_lo, mul_hi;

        // j = 0
        mul128_4(a.v0, bi, mul_lo, mul_hi);
        ulong4 acc_lo = t0 + mul_lo;
        ulong4 acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t0);
        ulong4 acc_lo2 = acc_lo + carry;
        ulong4 acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t0 = acc_lo2;
        carry = acc_hi2;

        // j = 1
        mul128_4(a.v1, bi, mul_lo, mul_hi);
        acc_lo = t1 + mul_lo;
        acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t1);
        acc_lo2 = acc_lo + carry;
        acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t1 = acc_lo2;
        carry = acc_hi2;

        // j = 2
        mul128_4(a.v2, bi, mul_lo, mul_hi);
        acc_lo = t2 + mul_lo;
        acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t2);
        acc_lo2 = acc_lo + carry;
        acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t2 = acc_lo2;
        carry = acc_hi2;

        // j = 3
        mul128_4(a.v3, bi, mul_lo, mul_hi);
        acc_lo = t3 + mul_lo;
        acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t3);
        acc_lo2 = acc_lo + carry;
        acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t3 = acc_lo2;
        carry = acc_hi2;

        ulong4 sum = t4 + carry;
        t4 = sum;

        // Montgomery reduction: m = t0 * np
        ulong4 m = t0 * np;

        // t += q * m
        carry = ulong4(0);

        // j = 0
        mul128_4(q0, m, mul_lo, mul_hi);
        acc_lo = t0 + mul_lo;
        acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t0);
        acc_lo2 = acc_lo + carry;
        acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t0 = acc_lo2;
        carry = acc_hi2;

        // j = 1
        mul128_4(q1, m, mul_lo, mul_hi);
        acc_lo = t1 + mul_lo;
        acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t1);
        acc_lo2 = acc_lo + carry;
        acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t1 = acc_lo2;
        carry = acc_hi2;

        // j = 2
        mul128_4(q2, m, mul_lo, mul_hi);
        acc_lo = t2 + mul_lo;
        acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t2);
        acc_lo2 = acc_lo + carry;
        acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t2 = acc_lo2;
        carry = acc_hi2;

        // j = 3
        mul128_4(q3, m, mul_lo, mul_hi);
        acc_lo = t3 + mul_lo;
        acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t3);
        acc_lo2 = acc_lo + carry;
        acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t3 = acc_lo2;
        carry = acc_hi2;

        sum = t4 + carry;
        t4 = sum;

        // Shift right by one limb
        t0 = t1; t1 = t2; t2 = t3; t3 = t4; t4 = ulong4(0);
    }

    FrElement4 r;
    r.v0 = t0; r.v1 = t1; r.v2 = t2; r.v3 = t3;

    // Final reduction: if r >= q, subtract q (done per-lane with scalar code)
    FrElement4 result;
    for (int lane = 0; lane < 4; lane++) {
        FrElement r_scalar = {r.v0[lane], r.v1[lane], r.v2[lane], r.v3[lane]};
        FrElement q_scalar = q;
        if (fr_cmp(r_scalar, q_scalar) >= 0) {
            r_scalar = fr_sub(r_scalar, q_scalar);
        }
        result.v0[lane] = r_scalar.v[0];
        result.v1[lane] = r_scalar.v[1];
        result.v2[lane] = r_scalar.v[2];
        result.v3[lane] = r_scalar.v[3];
    }
    return result;
}

// ---------------------------------------------------------------------------
// SIMD Fr: subtraction with conditional add of modulus (4 elements in parallel)
// ---------------------------------------------------------------------------
inline FrElement4 fr_sub4(const FrElement4 a, const FrElement4 b) {
    ulong4 borrow = ulong4(0);

    ulong4 ts0 = b.v0 + borrow;
    ulong4 c10 = select(ulong4(0), ulong4(1), ts0 < b.v0);
    ulong4 d0 = a.v0 - ts0;
    ulong4 c20 = select(ulong4(0), ulong4(1), d0 > a.v0);
    ulong4 r0 = d0;
    borrow = c10 | c20;

    ulong4 ts1 = b.v1 + borrow;
    ulong4 c11 = select(ulong4(0), ulong4(1), ts1 < b.v1);
    ulong4 d1 = a.v1 - ts1;
    ulong4 c21 = select(ulong4(0), ulong4(1), d1 > a.v1);
    ulong4 r1 = d1;
    borrow = c11 | c21;

    ulong4 ts2 = b.v2 + borrow;
    ulong4 c12 = select(ulong4(0), ulong4(1), ts2 < b.v2);
    ulong4 d2 = a.v2 - ts2;
    ulong4 c22 = select(ulong4(0), ulong4(1), d2 > a.v2);
    ulong4 r2 = d2;
    borrow = c12 | c22;

    ulong4 ts3 = b.v3 + borrow;
    ulong4 c13 = select(ulong4(0), ulong4(1), ts3 < b.v3);
    ulong4 d3 = a.v3 - ts3;
    ulong4 c23 = select(ulong4(0), ulong4(1), d3 > a.v3);
    ulong4 r3 = d3;
    borrow = c13 | c23;

    // If borrow, add modulus (per-lane with scalar code)
    FrElement4 result;
    FrElement q = fr_load_q();
    for (int lane = 0; lane < 4; lane++) {
        FrElement r_scalar = {r0[lane], r1[lane], r2[lane], r3[lane]};
        if (borrow[lane] != 0) {
            r_scalar = fr_add(r_scalar, q);
        }
        result.v0[lane] = r_scalar.v[0];
        result.v1[lane] = r_scalar.v[1];
        result.v2[lane] = r_scalar.v[2];
        result.v3[lane] = r_scalar.v[3];
    }
    return result;
}

// ---------------------------------------------------------------------------
// SIMD Fr: convert out of Montgomery form (4 elements in parallel)
// ---------------------------------------------------------------------------
inline FrElement4 fr_from_montgomery4(const FrElement4 a) {
    ulong4 t0 = a.v0;
    ulong4 t1 = a.v1;
    ulong4 t2 = a.v2;
    ulong4 t3 = a.v3;
    ulong4 t4 = ulong4(0);

    ulong4 np = ulong4(FR_NP);
    FrElement q = fr_load_q();
    ulong4 q0 = ulong4(q.v[0]);
    ulong4 q1 = ulong4(q.v[1]);
    ulong4 q2 = ulong4(q.v[2]);
    ulong4 q3 = ulong4(q.v[3]);

    for (int i = 0; i < 4; i++) {
        ulong4 m = t0 * np;

        ulong4 carry = ulong4(0);
        ulong4 mul_lo, mul_hi;

        // j = 0
        mul128_4(q0, m, mul_lo, mul_hi);
        ulong4 acc_lo = t0 + mul_lo;
        ulong4 acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t0);
        ulong4 acc_lo2 = acc_lo + carry;
        ulong4 acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t0 = acc_lo2;
        carry = acc_hi2;

        // j = 1
        mul128_4(q1, m, mul_lo, mul_hi);
        acc_lo = t1 + mul_lo;
        acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t1);
        acc_lo2 = acc_lo + carry;
        acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t1 = acc_lo2;
        carry = acc_hi2;

        // j = 2
        mul128_4(q2, m, mul_lo, mul_hi);
        acc_lo = t2 + mul_lo;
        acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t2);
        acc_lo2 = acc_lo + carry;
        acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t2 = acc_lo2;
        carry = acc_hi2;

        // j = 3
        mul128_4(q3, m, mul_lo, mul_hi);
        acc_lo = t3 + mul_lo;
        acc_hi = mul_hi + select(ulong4(0), ulong4(1), acc_lo < t3);
        acc_lo2 = acc_lo + carry;
        acc_hi2 = acc_hi + select(ulong4(0), ulong4(1), acc_lo2 < acc_lo);
        t3 = acc_lo2;
        carry = acc_hi2;

        ulong4 sum = t4 + carry;
        t4 = sum;

        // Shift right by one limb
        t0 = t1; t1 = t2; t2 = t3; t3 = t4; t4 = ulong4(0);
    }

    FrElement4 r;
    r.v0 = t0; r.v1 = t1; r.v2 = t2; r.v3 = t3;

    // Final reduction per-lane
    FrElement4 result;
    for (int lane = 0; lane < 4; lane++) {
        FrElement r_scalar = {r.v0[lane], r.v1[lane], r.v2[lane], r.v3[lane]};
        if (fr_cmp(r_scalar, q) >= 0) {
            r_scalar = fr_sub(r_scalar, q);
        }
        result.v0[lane] = r_scalar.v[0];
        result.v1[lane] = r_scalar.v[1];
        result.v2[lane] = r_scalar.v[2];
        result.v3[lane] = r_scalar.v[3];
    }
    return result;
}

// ---------------------------------------------------------------------------
// Load/store 4 FrElements from device memory
// ---------------------------------------------------------------------------
inline FrElement4 fr_load4(device const FrElement* ptr, uint idx) {
    FrElement4 r;
    r.v0 = ulong4(ptr[idx].v[0], ptr[idx + 1].v[0], ptr[idx + 2].v[0], ptr[idx + 3].v[0]);
    r.v1 = ulong4(ptr[idx].v[1], ptr[idx + 1].v[1], ptr[idx + 2].v[1], ptr[idx + 3].v[1]);
    r.v2 = ulong4(ptr[idx].v[2], ptr[idx + 1].v[2], ptr[idx + 2].v[2], ptr[idx + 3].v[2]);
    r.v3 = ulong4(ptr[idx].v[3], ptr[idx + 1].v[3], ptr[idx + 2].v[3], ptr[idx + 3].v[3]);
    return r;
}

inline void fr_store4(device FrElement* ptr, uint idx, const FrElement4 val) {
    for (int lane = 0; lane < 4; lane++) {
        ptr[idx + lane].v[0] = val.v0[lane];
        ptr[idx + lane].v[1] = val.v1[lane];
        ptr[idx + lane].v[2] = val.v2[lane];
        ptr[idx + lane].v[3] = val.v3[lane];
    }
}
