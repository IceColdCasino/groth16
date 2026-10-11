#include <metal_stdlib>
using namespace metal;

// ============================================================================
// BN254 Field Arithmetic (Fr and Fq)
// ============================================================================
//
// Straight-line 4-limb uint64_t arithmetic for BN254 curve parameters.
// No GMP dependencies — all operations use Metal builtins and explicit
// carry/borrow chains.
//
// Fr: scalar field (r)
// Fq: base field (p)
//
// ============================================================================

typedef struct {
    uint64_t v[4];
} FrElement;

typedef struct {
    uint64_t v[4];
} FqElement;

// BN254 Fr modulus:
// 21888242871839275222246405745257275088548364400416034343698204186575808495617
constant uint64_t FR_Q[4] = {
    0x43e1f593f0000001ULL,
    0x2833e84879b97091ULL,
    0xb85045b68181585dULL,
    0x30644e72e131a029ULL
};

// Montgomery R' = -q^(-1) mod 2^64  for Fr
constant uint64_t FR_NP = 0xc2e1f593efffffffULL;

// BN254 Fq modulus:
// 21888242871839275222246405745257275088696322657263627729636899242517737986881
constant uint64_t FQ_Q[4] = {
    0x3c208c16d87cfd47ULL,
    0x97816a916871ca8dULL,
    0xb85045b68181585dULL,
    0x30644e72e131a029ULL
};

// Montgomery R' = -q^(-1) mod 2^64  for Fq
constant uint64_t FQ_NP = 0x87d20782e4866389ULL;

// 128-bit helper for intermediate multiplication results
typedef struct {
    uint64_t lo;
    uint64_t hi;
} uint128_t;

// ---------------------------------------------------------------------------
// 128-bit primitives
// ---------------------------------------------------------------------------

// Use native 64-bit multiply for much better GPU performance.
// Metal provides mulhi() for the high 64 bits of a 128-bit product.
inline uint128_t mul128(uint64_t a, uint64_t b) {
    uint64_t lo = a * b;
    uint64_t hi = mulhi((ulong)a, (ulong)b);
    return uint128_t{lo, hi};
}

inline uint128_t add128(uint128_t a, uint128_t b) {
    uint64_t lo = a.lo + b.lo;
    uint64_t hi = a.hi + b.hi + (lo < a.lo ? 1ULL : 0ULL);
    return uint128_t{lo, hi};
}

inline uint128_t add128_u64(uint128_t a, uint64_t b) {
    uint64_t lo = a.lo + b;
    uint64_t hi = a.hi + (lo < a.lo ? 1ULL : 0ULL);
    return uint128_t{lo, hi};
}

// ---------------------------------------------------------------------------
// Construction helpers
// ---------------------------------------------------------------------------

inline FrElement fr_from_u64(uint64_t a) {
    FrElement r = {a, 0, 0, 0};
    return r;
}

inline FqElement fq_from_u64(uint64_t a) {
    FqElement r = {a, 0, 0, 0};
    return r;
}

inline FqElement fq_zero(void) {
    FqElement r = {0, 0, 0, 0};
    return r;
}

inline FrElement fr_zero(void) {
    FrElement r = {0, 0, 0, 0};
    return r;
}

// Montgomery representation of 1 (R mod q) for Fq
inline FqElement fq_montgomery_one(void) {
    // R mod q = 2^256 mod q
    FqElement r = {0xd35d438dc58f0d9dULL, 0x0a78eb28f5c70b3dULL, 0x666ea36f7879462cULL, 0x0e0a77c19a07df2fULL};
    return r;
}

// Montgomery representation of 1 (R mod r) for Fr
inline FrElement fr_montgomery_one(void) {
    // 6350874878119819312338956282401532410253015985375196716315342565497...
    FrElement r = {0xac96341c4ffffffbULL, 0x36fc76959f60cd29ULL, 0x666ea36f7879462eULL, 0x0e0a77c19a07df2fULL};
    return r;
}

inline FrElement fr_load_q(void) {
    FrElement r = {FR_Q[0], FR_Q[1], FR_Q[2], FR_Q[3]};
    return r;
}

inline FqElement fq_load_q(void) {
    FqElement r = {FQ_Q[0], FQ_Q[1], FQ_Q[2], FQ_Q[3]};
    return r;
}

// ---------------------------------------------------------------------------
// Comparison (lexicographic on limbs, high limb first)
// ---------------------------------------------------------------------------

inline int fr_cmp(const FrElement a, const FrElement b) {
    for (int i = 3; i >= 0; i--) {
        if (a.v[i] > b.v[i]) return 1;
        if (a.v[i] < b.v[i]) return -1;
    }
    return 0;
}

inline int fq_cmp(const FqElement a, const FqElement b) {
    for (int i = 3; i >= 0; i--) {
        if (a.v[i] > b.v[i]) return 1;
        if (a.v[i] < b.v[i]) return -1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Fr: addition with modular reduction
// ---------------------------------------------------------------------------

inline FrElement fr_add(const FrElement a, const FrElement b) {
    uint64_t carry = 0;
    FrElement r;
    for (int i = 0; i < 4; i++) {
        uint64_t sum  = a.v[i] + b.v[i];
        uint64_t c1   = (sum < a.v[i]) ? 1ULL : 0ULL;
        uint64_t sum2 = sum + carry;
        uint64_t c2   = (sum2 < sum) ? 1ULL : 0ULL;
        r.v[i] = sum2;
        carry  = c1 + c2;          // bounded to {0,1}
    }

    FrElement q = fr_load_q();
    if (carry || fr_cmp(r, q) >= 0) {
        uint64_t borrow = 0;
        FrElement diff;
        for (int i = 0; i < 4; i++) {
            uint64_t total_sub = q.v[i] + borrow;
            uint64_t c1 = (total_sub < q.v[i]) ? 1ULL : 0ULL;
            uint64_t d   = r.v[i] - total_sub;
            uint64_t c2  = (d > r.v[i]) ? 1ULL : 0ULL;
            diff.v[i] = d;
            borrow = c1 | c2;
        }
        return diff;
    }
    return r;
}

// ---------------------------------------------------------------------------
// Fr: subtraction with conditional add of modulus
// ---------------------------------------------------------------------------

inline FrElement fr_sub(const FrElement a, const FrElement b) {
    uint64_t borrow = 0;
    FrElement r;
    for (int i = 0; i < 4; i++) {
        uint64_t total_sub = b.v[i] + borrow;
        uint64_t c1 = (total_sub < b.v[i]) ? 1ULL : 0ULL;
        uint64_t diff = a.v[i] - total_sub;
        uint64_t c2 = (diff > a.v[i]) ? 1ULL : 0ULL;
        r.v[i] = diff;
        borrow = c1 | c2;
    }

    if (borrow) {
        FrElement q = fr_load_q();
        uint64_t carry = 0;
        FrElement sum;
        for (int i = 0; i < 4; i++) {
            uint64_t s  = r.v[i] + q.v[i];
            uint64_t c1 = (s < r.v[i]) ? 1ULL : 0ULL;
            uint64_t s2 = s + carry;
            uint64_t c2 = (s2 < s) ? 1ULL : 0ULL;
            sum.v[i] = s2;
            carry  = c1 + c2;
        }
        return sum;
    }
    return r;
}

// ---------------------------------------------------------------------------
// Fr: Montgomery multiplication (CIOS, 4-limb)
// ---------------------------------------------------------------------------

inline FrElement fr_mul(const FrElement a, const FrElement b) {
    uint64_t t[5] = {0, 0, 0, 0, 0};

    #pragma unroll
    for (int i = 0; i < 4; i++) {
        // t += a * b[i]
        uint64_t carry = 0;
        #pragma unroll
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(a.v[j], b.v[i]);
            uint128_t acc  = add128(prod, (uint128_t){t[j], 0});
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        uint64_t sum = t[4] + carry;
        t[4] = sum;

        // Montgomery reduction:  t += q * m   where m = t[0] * np
        uint64_t m = t[0] * FR_NP;

        carry = 0;
        #pragma unroll
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(FR_Q[j], m);
            uint128_t acc  = add128(prod, (uint128_t){t[j], 0});
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        sum = t[4] + carry;
        t[4] = sum;

        // Shift right by one limb
        #pragma unroll
        for (int j = 0; j < 4; j++) {
            t[j] = t[j + 1];
        }
        t[4] = 0;
    }

    FrElement r = {t[0], t[1], t[2], t[3]};

    FrElement q = fr_load_q();
    if (fr_cmp(r, q) >= 0) {
        r = fr_sub(r, q);
    }
    return r;
}

// ---------------------------------------------------------------------------
// Fr: convert out of Montgomery form
// ---------------------------------------------------------------------------

inline FrElement fr_from_montgomery(const FrElement a) {
    uint64_t t[5] = {a.v[0], a.v[1], a.v[2], a.v[3], 0};

    for (int i = 0; i < 4; i++) {
        uint64_t m = t[0] * FR_NP;

        uint64_t carry = 0;
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(FR_Q[j], m);
            uint128_t acc  = add128(prod, (uint128_t){t[j], 0});
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        uint64_t sum = t[4] + carry;
        t[4] = sum;

        for (int j = 0; j < 4; j++) {
            t[j] = t[j + 1];
        }
        t[4] = 0;
    }

    FrElement r = {t[0], t[1], t[2], t[3]};

    FrElement q = fr_load_q();
    if (fr_cmp(r, q) >= 0) {
        r = fr_sub(r, q);
    }
    return r;
}

// ---------------------------------------------------------------------------
// Fq: addition with modular reduction
// ---------------------------------------------------------------------------

inline FqElement fq_add(const FqElement a, const FqElement b) {
    uint64_t carry = 0;
    FqElement r;
    for (int i = 0; i < 4; i++) {
        uint64_t sum  = a.v[i] + b.v[i];
        uint64_t c1   = (sum < a.v[i]) ? 1ULL : 0ULL;
        uint64_t sum2 = sum + carry;
        uint64_t c2   = (sum2 < sum) ? 1ULL : 0ULL;
        r.v[i] = sum2;
        carry  = c1 + c2;
    }

    FqElement q = fq_load_q();
    if (carry || fq_cmp(r, q) >= 0) {
        uint64_t borrow = 0;
        FqElement diff;
        for (int i = 0; i < 4; i++) {
            uint64_t total_sub = q.v[i] + borrow;
            uint64_t c1 = (total_sub < q.v[i]) ? 1ULL : 0ULL;
            uint64_t d   = r.v[i] - total_sub;
            uint64_t c2  = (d > r.v[i]) ? 1ULL : 0ULL;
            diff.v[i] = d;
            borrow = c1 | c2;
        }
        return diff;
    }
    return r;
}

// ---------------------------------------------------------------------------
// Fq: subtraction with conditional add of modulus
// ---------------------------------------------------------------------------

inline FqElement fq_sub(const FqElement a, const FqElement b) {
    uint64_t borrow = 0;
    FqElement r;
    for (int i = 0; i < 4; i++) {
        uint64_t total_sub = b.v[i] + borrow;
        uint64_t c1 = (total_sub < b.v[i]) ? 1ULL : 0ULL;
        uint64_t diff = a.v[i] - total_sub;
        uint64_t c2 = (diff > a.v[i]) ? 1ULL : 0ULL;
        r.v[i] = diff;
        borrow = c1 | c2;
    }

    if (borrow) {
        FqElement q = fq_load_q();
        uint64_t carry = 0;
        FqElement sum;
        for (int i = 0; i < 4; i++) {
            uint64_t s  = r.v[i] + q.v[i];
            uint64_t c1 = (s < r.v[i]) ? 1ULL : 0ULL;
            uint64_t s2 = s + carry;
            uint64_t c2 = (s2 < s) ? 1ULL : 0ULL;
            sum.v[i] = s2;
            carry  = c1 + c2;
        }
        return sum;
    }
    return r;
}

// ---------------------------------------------------------------------------
// Fq: Montgomery multiplication (CIOS, 4-limb)
// ---------------------------------------------------------------------------

inline FqElement fq_mul(const FqElement a, const FqElement b) {
    uint64_t t[5] = {0, 0, 0, 0, 0};

    #pragma unroll
    for (int i = 0; i < 4; i++) {
        uint64_t carry = 0;
        #pragma unroll
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(a.v[j], b.v[i]);
            uint128_t acc  = add128(prod, (uint128_t){t[j], 0});
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        uint64_t sum = t[4] + carry;
        t[4] = sum;

        uint64_t m = t[0] * FQ_NP;

        carry = 0;
        #pragma unroll
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(FQ_Q[j], m);
            uint128_t acc  = add128(prod, (uint128_t){t[j], 0});
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        sum = t[4] + carry;
        t[4] = sum;

        #pragma unroll
        for (int j = 0; j < 4; j++) {
            t[j] = t[j + 1];
        }
        t[4] = 0;
    }

    FqElement r = {t[0], t[1], t[2], t[3]};

    FqElement q = fq_load_q();
    if (fq_cmp(r, q) >= 0) {
        r = fq_sub(r, q);
    }
    return r;
}

// ---------------------------------------------------------------------------
// Fq: convert out of Montgomery form
// ---------------------------------------------------------------------------

inline FqElement fq_from_montgomery(const FqElement a) {
    uint64_t t[5] = {a.v[0], a.v[1], a.v[2], a.v[3], 0};

    for (int i = 0; i < 4; i++) {
        uint64_t m = t[0] * FQ_NP;

        uint64_t carry = 0;
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(FQ_Q[j], m);
            uint128_t acc  = add128(prod, (uint128_t){t[j], 0});
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        uint64_t sum = t[4] + carry;
        t[4] = sum;

        for (int j = 0; j < 4; j++) {
            t[j] = t[j + 1];
        }
        t[4] = 0;
    }

    FqElement r = {t[0], t[1], t[2], t[3]};

    FqElement q = fq_load_q();
    if (fq_cmp(r, q) >= 0) {
        r = fq_sub(r, q);
    }
    return r;
}

// ============================================================================
// Fq2: quadratic extension Fq[i] / (i^2 + 1)
// ============================================================================

typedef struct {
    FqElement a;
    FqElement b;
} Fq2Element;

inline Fq2Element fq2_add(const Fq2Element x, const Fq2Element y) {
    return Fq2Element{ fq_add(x.a, y.a), fq_add(x.b, y.b) };
}

inline Fq2Element fq2_sub(const Fq2Element x, const Fq2Element y) {
    return Fq2Element{ fq_sub(x.a, y.a), fq_sub(x.b, y.b) };
}

inline Fq2Element fq2_mul(const Fq2Element x, const Fq2Element y) {
    // (a + bi) * (c + di) = (ac - bd) + (ad + bc)i
    FqElement ac = fq_mul(x.a, y.a);
    FqElement bd = fq_mul(x.b, y.b);
    FqElement ad = fq_mul(x.a, y.b);
    FqElement bc = fq_mul(x.b, y.a);
    return Fq2Element{ fq_sub(ac, bd), fq_add(ad, bc) };
}

inline bool fq2_is_zero(const Fq2Element x) {
    return (x.a.v[0] == 0 && x.a.v[1] == 0 && x.a.v[2] == 0 && x.a.v[3] == 0 &&
            x.b.v[0] == 0 && x.b.v[1] == 0 && x.b.v[2] == 0 && x.b.v[3] == 0);
}
