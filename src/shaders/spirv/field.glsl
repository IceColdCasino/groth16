// ============================================================================
// BN254 Field Arithmetic (Fr and Fq)
// ============================================================================
// 4-limb uint64_t arithmetic using u64vec4 packed data.
// Straight-line CIOS Montgomery multiplication, modular add/sub.
// ============================================================================

struct FrElement {
    u64vec4 v;
};

struct FqElement {
    u64vec4 v;
};

// BN254 Fr modulus
const uint64_t FR_Q[4] = uint64_t[](
    0x43e1f593f0000001UL,
    0x2833e84879b97091UL,
    0xb85045b68181585dUL,
    0x30644e72e131a029UL
);

const uint64_t FR_NP = 0xc2e1f593efffffffUL;

// BN254 Fq modulus
const uint64_t FQ_Q[4] = uint64_t[](
    0x3c208c16d87cfd47UL,
    0x97816a916871ca8dUL,
    0xb85045b68181585dUL,
    0x30644e72e131a029UL
);

const uint64_t FQ_NP = 0x87d20782e4866389UL;

// 128-bit helper
struct uint128_t {
    uint64_t lo;
    uint64_t hi;
};

// ---------------------------------------------------------------------------
// 64-bit multiply high (manual 32-bit decomposition)
// ---------------------------------------------------------------------------

uint128_t mul128(uint64_t a, uint64_t b) {
    uint64_t a0 = a & 0xFFFFFFFFUL;
    uint64_t a1 = a >> 32;
    uint64_t b0 = b & 0xFFFFFFFFUL;
    uint64_t b1 = b >> 32;

    uint64_t p00 = a0 * b0;
    uint64_t p01 = a0 * b1;
    uint64_t p10 = a1 * b0;
    uint64_t p11 = a1 * b1;

    uint64_t mid = p01 + p10;
    uint64_t mid_carry = (mid < p01) ? 1UL : 0UL;

    uint64_t lo = p00 + (mid << 32);
    uint64_t lo_carry = (lo < p00) ? 1UL : 0UL;

    uint64_t hi = p11 + (mid >> 32) + (mid_carry << 32) + lo_carry;

    return uint128_t(lo, hi);
}

uint128_t add128(uint128_t a, uint128_t b) {
    uint64_t lo = a.lo + b.lo;
    uint64_t hi = a.hi + b.hi + ((lo < a.lo) ? 1UL : 0UL);
    return uint128_t(lo, hi);
}

uint128_t add128_u64(uint128_t a, uint64_t b) {
    uint64_t lo = a.lo + b;
    uint64_t hi = a.hi + ((lo < a.lo) ? 1UL : 0UL);
    return uint128_t(lo, hi);
}

// ---------------------------------------------------------------------------
// Construction helpers
// ---------------------------------------------------------------------------

FrElement fr_from_u64(uint64_t a) {
    FrElement r;
    r.v = u64vec4(a, 0UL, 0UL, 0UL);
    return r;
}

FqElement fq_from_u64(uint64_t a) {
    FqElement r;
    r.v = u64vec4(a, 0UL, 0UL, 0UL);
    return r;
}

FqElement fq_montgomery_one() {
    FqElement r;
    r.v = u64vec4(0xd35d438dc58f0d9dUL, 0x0a78eb28f5c70b3dUL, 0x666ea36f7879462cUL, 0x0e0a77c19a07df2fUL);
    return r;
}

FrElement fr_montgomery_one() {
    FrElement r;
    r.v = u64vec4(0xac96341c4ffffffbUL, 0x36fc76959f60cd29UL, 0x666ea36f7879462eUL, 0x0e0a77c19a07df2fUL);
    return r;
}

FrElement fr_load_q() {
    FrElement r;
    r.v = u64vec4(FR_Q[0], FR_Q[1], FR_Q[2], FR_Q[3]);
    return r;
}

FqElement fq_load_q() {
    FqElement r;
    r.v = u64vec4(FQ_Q[0], FQ_Q[1], FQ_Q[2], FQ_Q[3]);
    return r;
}

// ---------------------------------------------------------------------------
// Comparison (lexicographic on limbs, high limb first)
// ---------------------------------------------------------------------------

int fr_cmp(FrElement a, FrElement b) {
    for (int i = 3; i >= 0; i--) {
        if (a.v[i] > b.v[i]) return 1;
        if (a.v[i] < b.v[i]) return -1;
    }
    return 0;
}

int fq_cmp(FqElement a, FqElement b) {
    for (int i = 3; i >= 0; i--) {
        if (a.v[i] > b.v[i]) return 1;
        if (a.v[i] < b.v[i]) return -1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Fr: addition with modular reduction
// ---------------------------------------------------------------------------

FrElement fr_add(FrElement a, FrElement b) {
    uint64_t carry = 0UL;
    FrElement r;
    for (int i = 0; i < 4; i++) {
        uint64_t sum  = a.v[i] + b.v[i];
        uint64_t c1   = (sum < a.v[i]) ? 1UL : 0UL;
        uint64_t sum2 = sum + carry;
        uint64_t c2   = (sum2 < sum) ? 1UL : 0UL;
        r.v[i] = sum2;
        carry  = c1 + c2;
    }

    FrElement q = fr_load_q();
    if (carry != 0UL || fr_cmp(r, q) >= 0) {
        uint64_t borrow = 0UL;
        FrElement diff;
        for (int i = 0; i < 4; i++) {
            uint64_t total_sub = q.v[i] + borrow;
            uint64_t c1 = (total_sub < q.v[i]) ? 1UL : 0UL;
            uint64_t d   = r.v[i] - total_sub;
            uint64_t c2  = (d > r.v[i]) ? 1UL : 0UL;
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

FrElement fr_sub(FrElement a, FrElement b) {
    uint64_t borrow = 0UL;
    FrElement r;
    for (int i = 0; i < 4; i++) {
        uint64_t total_sub = b.v[i] + borrow;
        uint64_t c1 = (total_sub < b.v[i]) ? 1UL : 0UL;
        uint64_t diff = a.v[i] - total_sub;
        uint64_t c2 = (diff > a.v[i]) ? 1UL : 0UL;
        r.v[i] = diff;
        borrow = c1 | c2;
    }

    if (borrow != 0UL) {
        FrElement q = fr_load_q();
        uint64_t carry = 0UL;
        FrElement sum;
        for (int i = 0; i < 4; i++) {
            uint64_t s  = r.v[i] + q.v[i];
            uint64_t c1 = (s < r.v[i]) ? 1UL : 0UL;
            uint64_t s2 = s + carry;
            uint64_t c2 = (s2 < s) ? 1UL : 0UL;
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

FrElement fr_mul(FrElement a, FrElement b) {
    uint64_t t[5];
    for (int k = 0; k < 5; k++) t[k] = 0UL;

    for (int i = 0; i < 4; i++) {
        uint64_t carry = 0UL;
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(a.v[j], b.v[i]);
            uint128_t acc  = add128(prod, uint128_t(t[j], 0UL));
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        uint64_t sum = t[4] + carry;
        t[4] = sum;

        uint64_t m = t[0] * FR_NP;

        carry = 0UL;
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(FR_Q[j], m);
            uint128_t acc  = add128(prod, uint128_t(t[j], 0UL));
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        sum = t[4] + carry;
        t[4] = sum;

        for (int j = 0; j < 4; j++) {
            t[j] = t[j + 1];
        }
        t[4] = 0UL;
    }

    FrElement r;
    r.v = u64vec4(t[0], t[1], t[2], t[3]);

    FrElement q = fr_load_q();
    if (fr_cmp(r, q) >= 0) {
        r = fr_sub(r, q);
    }
    return r;
}

// ---------------------------------------------------------------------------
// Fr: convert out of Montgomery form
// ---------------------------------------------------------------------------

FrElement fr_from_montgomery(FrElement a) {
    uint64_t t[5];
    t[0] = a.v[0]; t[1] = a.v[1]; t[2] = a.v[2]; t[3] = a.v[3]; t[4] = 0UL;

    for (int i = 0; i < 4; i++) {
        uint64_t m = t[0] * FR_NP;

        uint64_t carry = 0UL;
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(FR_Q[j], m);
            uint128_t acc  = add128(prod, uint128_t(t[j], 0UL));
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        uint64_t sum = t[4] + carry;
        t[4] = sum;

        for (int j = 0; j < 4; j++) {
            t[j] = t[j + 1];
        }
        t[4] = 0UL;
    }

    FrElement r;
    r.v = u64vec4(t[0], t[1], t[2], t[3]);

    FrElement q = fr_load_q();
    if (fr_cmp(r, q) >= 0) {
        r = fr_sub(r, q);
    }
    return r;
}

// ---------------------------------------------------------------------------
// Fq: addition with modular reduction
// ---------------------------------------------------------------------------

FqElement fq_add(FqElement a, FqElement b) {
    uint64_t carry = 0UL;
    FqElement r;
    for (int i = 0; i < 4; i++) {
        uint64_t sum  = a.v[i] + b.v[i];
        uint64_t c1   = (sum < a.v[i]) ? 1UL : 0UL;
        uint64_t sum2 = sum + carry;
        uint64_t c2   = (sum2 < sum) ? 1UL : 0UL;
        r.v[i] = sum2;
        carry  = c1 + c2;
    }

    FqElement q = fq_load_q();
    if (carry != 0UL || fq_cmp(r, q) >= 0) {
        uint64_t borrow = 0UL;
        FqElement diff;
        for (int i = 0; i < 4; i++) {
            uint64_t total_sub = q.v[i] + borrow;
            uint64_t c1 = (total_sub < q.v[i]) ? 1UL : 0UL;
            uint64_t d   = r.v[i] - total_sub;
            uint64_t c2  = (d > r.v[i]) ? 1UL : 0UL;
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

FqElement fq_sub(FqElement a, FqElement b) {
    uint64_t borrow = 0UL;
    FqElement r;
    for (int i = 0; i < 4; i++) {
        uint64_t total_sub = b.v[i] + borrow;
        uint64_t c1 = (total_sub < b.v[i]) ? 1UL : 0UL;
        uint64_t diff = a.v[i] - total_sub;
        uint64_t c2 = (diff > a.v[i]) ? 1UL : 0UL;
        r.v[i] = diff;
        borrow = c1 | c2;
    }

    if (borrow != 0UL) {
        FqElement q = fq_load_q();
        uint64_t carry = 0UL;
        FqElement sum;
        for (int i = 0; i < 4; i++) {
            uint64_t s  = r.v[i] + q.v[i];
            uint64_t c1 = (s < r.v[i]) ? 1UL : 0UL;
            uint64_t s2 = s + carry;
            uint64_t c2 = (s2 < s) ? 1UL : 0UL;
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

FqElement fq_mul(FqElement a, FqElement b) {
    uint64_t t[5];
    for (int k = 0; k < 5; k++) t[k] = 0UL;

    for (int i = 0; i < 4; i++) {
        uint64_t carry = 0UL;
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(a.v[j], b.v[i]);
            uint128_t acc  = add128(prod, uint128_t(t[j], 0UL));
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        uint64_t sum = t[4] + carry;
        t[4] = sum;

        uint64_t m = t[0] * FQ_NP;

        carry = 0UL;
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(FQ_Q[j], m);
            uint128_t acc  = add128(prod, uint128_t(t[j], 0UL));
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        sum = t[4] + carry;
        t[4] = sum;

        for (int j = 0; j < 4; j++) {
            t[j] = t[j + 1];
        }
        t[4] = 0UL;
    }

    FqElement r;
    r.v = u64vec4(t[0], t[1], t[2], t[3]);

    FqElement q = fq_load_q();
    if (fq_cmp(r, q) >= 0) {
        r = fq_sub(r, q);
    }
    return r;
}

// ---------------------------------------------------------------------------
// Fq: convert out of Montgomery form
// ---------------------------------------------------------------------------

FqElement fq_from_montgomery(FqElement a) {
    uint64_t t[5];
    t[0] = a.v[0]; t[1] = a.v[1]; t[2] = a.v[2]; t[3] = a.v[3]; t[4] = 0UL;

    for (int i = 0; i < 4; i++) {
        uint64_t m = t[0] * FQ_NP;

        uint64_t carry = 0UL;
        for (int j = 0; j < 4; j++) {
            uint128_t prod = mul128(FQ_Q[j], m);
            uint128_t acc  = add128(prod, uint128_t(t[j], 0UL));
            acc = add128_u64(acc, carry);
            t[j]   = acc.lo;
            carry  = acc.hi;
        }
        uint64_t sum = t[4] + carry;
        t[4] = sum;

        for (int j = 0; j < 4; j++) {
            t[j] = t[j + 1];
        }
        t[4] = 0UL;
    }

    FqElement r;
    r.v = u64vec4(t[0], t[1], t[2], t[3]);

    FqElement q = fq_load_q();
    if (fq_cmp(r, q) >= 0) {
        r = fq_sub(r, q);
    }
    return r;
}

// ============================================================================
// Fq2 Extension (for G2 curve)
// ============================================================================

struct Fq2Element {
    FqElement a;
    FqElement b;
};

Fq2Element fq2_add(Fq2Element x, Fq2Element y) {
    return Fq2Element(fq_add(x.a, y.a), fq_add(x.b, y.b));
}

Fq2Element fq2_sub(Fq2Element x, Fq2Element y) {
    return Fq2Element(fq_sub(x.a, y.a), fq_sub(x.b, y.b));
}

Fq2Element fq2_mul(Fq2Element x, Fq2Element y) {
    FqElement ac = fq_mul(x.a, y.a);
    FqElement bd = fq_mul(x.b, y.b);
    FqElement ad = fq_mul(x.a, y.b);
    FqElement bc = fq_mul(x.b, y.a);
    return Fq2Element(fq_sub(ac, bd), fq_add(ad, bc));
}

bool fq2_is_zero(Fq2Element x) {
    return (x.a.v[0] == 0UL && x.a.v[1] == 0UL && x.a.v[2] == 0UL && x.a.v[3] == 0UL &&
            x.b.v[0] == 0UL && x.b.v[1] == 0UL && x.b.v[2] == 0UL && x.b.v[3] == 0UL);
}
