// ============================================================================
// BN254 Fr FFT Kernel (Cooley-Tukey, iterative, in-place)
// ============================================================================
//
// One dispatch per stage.  The host calls:
//   stage 0          : bit-reverse permutation
//   stage 1 .. log_n : butterfly stage s
// For inverse FFT, stage == log_n also normalizes by inverse_n.
//
// Twiddles are precomputed for all n/2 unique factors.
// ============================================================================

typedef struct {
    uint n;
    uint inverse;
    uint log_n;
    uint stage;
    uint num_threads;
} FFTConfig;

// ---------------------------------------------------------------------------
// Bit-reverse an index in log_n bits
// ---------------------------------------------------------------------------

inline uint bit_reverse(uint x, uint log_n) {
    uint r = 0;
    for (uint i = 0; i < log_n; i++) {
        r = (r << 1) | ((x >> i) & 1u);
    }
    return r;
}

// ---------------------------------------------------------------------------
// fft_fr — in-place single-stage FFT kernel
// ---------------------------------------------------------------------------

kernel void fft_fr(
    device FrElement* data [[buffer(0)]],
    device const FrElement* twiddles [[buffer(1)]],
    constant FFTConfig& config [[buffer(2)]],
    device const FrElement* inverse_n [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    uint n = config.n;
    uint stage = config.stage;
    uint log_n = config.log_n;
    uint num_threads = config.num_threads;

    // Stage 0: bit-reverse permutation
    if (stage == 0) {
        uint chunk = (n + num_threads - 1) / num_threads;
        uint start = tid * chunk;
        uint end = min(start + chunk, n);

        for (uint i = start; i < end; i++) {
            uint j = bit_reverse(i, log_n);
            if (i < j) {
                FrElement tmp = data[i];
                data[i] = data[j];
                data[j] = tmp;
            }
        }
        return;
    }

    // Butterfly stages 1 .. log_n
    uint half_m = 1u << (stage - 1u);
    uint m = half_m << 1u;
    uint total_butterflies = n >> 1u;
    uint chunk = (total_butterflies + num_threads - 1) / num_threads;
    uint start = tid * chunk;
    uint end = min(start + chunk, total_butterflies);

    uint twiddle_step = n >> stage;

    bool is_last_inverse = (config.inverse != 0) && (stage == log_n);

    for (uint b = start; b < end; b++) {
        uint group = b >> (stage - 1u);
        uint offset = b & (half_m - 1u);
        uint i = (group * m) + offset;
        uint j = i + half_m;
        uint twiddle_idx = offset * twiddle_step;

        FrElement u = data[i];
        FrElement v = fr_mul(data[j], twiddles[twiddle_idx]);
        data[i] = fr_add(u, v);
        data[j] = fr_sub(u, v);

        if (is_last_inverse) {
            data[i] = fr_mul(data[i], *inverse_n);
            data[j] = fr_mul(data[j], *inverse_n);
        }
    }
}

// ---------------------------------------------------------------------------
// fft_shift — elementwise multiplication by shift factors (for coset FFT)
//   buffer(0): data (in/out)
//   buffer(1): shift_factors[n]
// ---------------------------------------------------------------------------
kernel void fft_shift(
    device FrElement* data [[buffer(0)]],
    device const FrElement* shift_factors [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    uint chunk = (n + 256u - 1u) / 256u;
    uint64_t start64 = (uint64_t)tid * (uint64_t)chunk;
    if (start64 >= n) return;
    uint start = (uint)start64;
    uint end = min(start + chunk, n);
    for (uint i = start; i < end; i++) {
        data[i] = fr_mul(data[i], shift_factors[i]);
    }
}

// ---------------------------------------------------------------------------
// fft_shift_simd — SIMD version of fft_shift, processes 4 elements per thread
// (field_simd.metal is concatenated before this file by the build step)
// ---------------------------------------------------------------------------
kernel void fft_shift_simd(
    device FrElement* data [[buffer(0)]],
    device const FrElement* shift_factors [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    uint simd_width = 4u;
    uint chunk = (n + simd_width - 1u) / simd_width;
    uint start = tid * chunk;
    uint end = min(start + chunk, n);

    // Scalar tail for unaligned elements
    uint aligned_end = (end / simd_width) * simd_width;
    for (uint i = start; i < min(aligned_end, start + (chunk / simd_width) * simd_width); i += simd_width) {
        FrElement4 a = fr_load4(data, i);
        FrElement4 b = fr_load4(shift_factors, i);
        FrElement4 r = fr_mul4(a, b);
        fr_store4(data, i, r);
    }
    for (uint i = aligned_end; i < end; i++) {
        data[i] = fr_mul(data[i], shift_factors[i]);
    }
}

// ---------------------------------------------------------------------------
// fft_pointwise_abc — a[i] = a[i]*b[i] - c[i], then fromMontgomery
//   buffer(0): a (in/out)
//   buffer(1): b
//   buffer(2): c
// ---------------------------------------------------------------------------
kernel void fft_pointwise_abc(
    device FrElement* a [[buffer(0)]],
    device const FrElement* b [[buffer(1)]],
    device const FrElement* c [[buffer(2)]],
    constant uint& n [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    uint chunk = (n + 256u - 1u) / 256u;
    uint64_t start64 = (uint64_t)tid * (uint64_t)chunk;
    if (start64 >= n) return;
    uint start = (uint)start64;
    uint end = min(start + chunk, n);
    for (uint i = start; i < end; i++) {
        FrElement tmp = fr_mul(a[i], b[i]);
        tmp = fr_sub(tmp, c[i]);
        a[i] = fr_from_montgomery(tmp);
    }
}

// ---------------------------------------------------------------------------
// fft_pointwise_abc_simd — SIMD version, processes 4 elements per thread
// ---------------------------------------------------------------------------
kernel void fft_pointwise_abc_simd(
    device FrElement* a [[buffer(0)]],
    device const FrElement* b [[buffer(1)]],
    device const FrElement* c [[buffer(2)]],
    constant uint& n [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    uint simd_width = 4u;
    uint chunk = (n + simd_width - 1u) / simd_width;
    uint start = tid * chunk;
    uint end = min(start + chunk, n);

    uint aligned_end = (end / simd_width) * simd_width;
    for (uint i = start; i < min(aligned_end, start + (chunk / simd_width) * simd_width); i += simd_width) {
        FrElement4 av = fr_load4(a, i);
        FrElement4 bv = fr_load4(b, i);
        FrElement4 cv = fr_load4(c, i);
        FrElement4 tmp = fr_mul4(av, bv);
        tmp = fr_sub4(tmp, cv);
        tmp = fr_from_montgomery4(tmp);
        fr_store4(a, i, tmp);
    }
    for (uint i = aligned_end; i < end; i++) {
        FrElement tmp = fr_mul(a[i], b[i]);
        tmp = fr_sub(tmp, c[i]);
        a[i] = fr_from_montgomery(tmp);
    }
}

// ---------------------------------------------------------------------------
// fft_ifft_postprocess — post-processing for an inverse FFT
//   After a forward FFT, swap a[i] <-> a[n-i] for i=1..n/2-1 and scale by 1/n.
//   buffer(0): data (in/out)
//   buffer(1): inverse_n (single FrElement)
// ---------------------------------------------------------------------------
kernel void fft_ifft_postprocess(
    device FrElement* data [[buffer(0)]],
    device const FrElement* inverse_n [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    uint nDiv2 = n >> 1u;
    // Scale a[0] and a[n/2]
    if (tid == 0) {
        data[0] = fr_mul(data[0], *inverse_n);
        data[nDiv2] = fr_mul(data[nDiv2], *inverse_n);
    }
    // Swap and scale a[i] <-> a[n-i] for i = 1 .. n/2-1
    uint chunk = (nDiv2 - 1u + 255u) / 256u;
    uint64_t start64 = (uint64_t)tid * (uint64_t)chunk;
    if (start64 >= nDiv2 - 1u) return;
    uint start = 1u + (uint)start64;
    uint end = min(start + chunk, nDiv2);
    for (uint i = start; i < end; i++) {
        uint r = n - i;
        FrElement tmp = data[i];
        data[i] = fr_mul(data[r], *inverse_n);
        data[r] = fr_mul(tmp, *inverse_n);
    }
}

// ---------------------------------------------------------------------------
// shift_3buf — elementwise coset shift for all 3 buffers
//   a[i] *= g^i, b[i] *= g^i, c[i] *= g^i
// ---------------------------------------------------------------------------
kernel void shift_3buf(
    device FrElement* a [[buffer(0)]],
    device FrElement* b [[buffer(1)]],
    device FrElement* c [[buffer(2)]],
    device const FrElement* g_powers [[buffer(3)]],
    constant uint& n [[buffer(4)]],
    uint tid [[thread_position_in_grid]]
) {
    uint simd_width = 4u;
    uint chunk = (n + simd_width - 1u) / simd_width;
    uint start = tid * chunk;
    uint end = min(start + chunk, n);

    uint aligned_end = (end / simd_width) * simd_width;
    for (uint i = start; i < aligned_end; i += simd_width) {
        FrElement4 av = fr_load4(a, i);
        FrElement4 gv = fr_load4(g_powers, i);
        FrElement4 r = fr_mul4(av, gv);
        fr_store4(a, i, r);

        FrElement4 bv = fr_load4(b, i);
        r = fr_mul4(bv, gv);
        fr_store4(b, i, r);

        FrElement4 cv = fr_load4(c, i);
        r = fr_mul4(cv, gv);
        fr_store4(c, i, r);
    }
    for (uint i = aligned_end; i < end; i++) {
        a[i] = fr_mul(a[i], g_powers[i]);
        b[i] = fr_mul(b[i], g_powers[i]);
        c[i] = fr_mul(c[i], g_powers[i]);
    }
}

// ---------------------------------------------------------------------------
// pointwise_abc_3buf — h[i] = a[i]*b[i] - c[i], then fromMontgomery
//   Result written to a buffer (which becomes h)
// ---------------------------------------------------------------------------
kernel void pointwise_abc_3buf(
    device FrElement* a [[buffer(0)]],
    device const FrElement* b [[buffer(1)]],
    device const FrElement* c [[buffer(2)]],
    constant uint& n [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid >= n) return;
    FrElement tmp = fr_mul(a[tid], b[tid]);
    tmp = fr_sub(tmp, c[tid]);
    a[tid] = fr_from_montgomery(tmp);
}
