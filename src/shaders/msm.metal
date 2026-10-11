#include <metal_stdlib>
#include "curve.metal"
using namespace metal;

// ============================================================================
// Debug / Test Kernels
// ============================================================================

kernel void test_g1_dbl(
    device const G1Point* input [[buffer(0)]],
    device G1Point* output [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid == 0) {
        output[0] = g1_dbl(input[0]);
    }
}

kernel void test_g1_add(
    device const G1Point* a [[buffer(0)]],
    device const G1Point* b [[buffer(1)]],
    device G1Point* output [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid == 0) {
        output[0] = g1_add(a[0], b[0]);
    }
}

kernel void test_g1_add_affine(
    device const G1PointAffine* a [[buffer(0)]],
    device const G1PointAffine* b [[buffer(1)]],
    device G1Point* output [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid == 0) {
        G1Point pa = g1_affine_to_projective(a[0]);
        G1Point pb = g1_affine_to_projective(b[0]);
        output[0] = g1_add(pa, pb);
    }
}

kernel void test_fq_add(
    device const FqElement* a [[buffer(0)]],
    device const FqElement* b [[buffer(1)]],
    device FqElement* output [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid == 0) {
        output[0] = fq_add(a[0], b[0]);
    }
}

kernel void test_fq_mul(
    device const FqElement* a [[buffer(0)]],
    device const FqElement* b [[buffer(1)]],
    device FqElement* output [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid == 0) {
        output[0] = fq_mul(a[0], b[0]);
    }
}

kernel void test_fq_sub(
    device const FqElement* a [[buffer(0)]],
    device const FqElement* b [[buffer(1)]],
    device FqElement* output [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid == 0) {
        output[0] = fq_sub(a[0], b[0]);
    }
}

kernel void test_mul128(
    device const FqElement* a [[buffer(0)]],
    device const FqElement* b [[buffer(1)]],
    device FqElement* output [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid == 0) {
        uint128_t prod = mul128(a->v[0], b->v[0]);
        output->v[0] = prod.lo;
        output->v[1] = prod.hi;
        output->v[2] = 0;
        output->v[3] = 0;
    }
}

// ============================================================================
// G2 Test Kernels
// ============================================================================

inline void g2_add_inline(const thread G2Point* p1, const thread G2Point* p2, thread G2Point* out) {
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

kernel void test_g2_add_inline(
    device const G2PointAffine* a [[buffer(0)]],
    device const G2PointAffine* b [[buffer(1)]],
    device G2Point* out [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid == 0) {
        G2PointAffine a_affine = a[0];
        G2PointAffine b_affine = b[0];
        G2Point pa;
        g2_affine_to_projective(&a_affine, &pa);
        G2Point pb;
        g2_affine_to_projective(&b_affine, &pb);
        G2Point result;
        g2_add_inline(&pa, &pb, &result);
        out[0] = result;
    }
}

kernel void test_g2_dbl(
    device const G2PointAffine* a [[buffer(0)]],
    device G2Point* out [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid == 0) {
        G2PointAffine a_affine = a[0];
        G2Point pa;
        g2_affine_to_projective(&a_affine, &pa);
        G2Point result;
        g2_dbl(&pa, &result);
        out[0] = result;
    }
}

kernel void test_g2_affine(
    device const G2PointAffine* a [[buffer(0)]],
    device G2Point* out [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid == 0) {
        G2PointAffine a_affine = a[0];
        G2Point pa;
        g2_affine_to_projective(&a_affine, &pa);
        out[0] = pa;
    }
}

kernel void test_g2_add_projective(
    device const G2Point* a [[buffer(0)]],
    device const G2Point* b [[buffer(1)]],
    device G2Point* out [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid == 0) {
        G2Point pa = a[0];
        G2Point pb = b[0];
        G2Point result;
        g2_add(&pa, &pb, &result);
        out[0] = result;
    }
}

// ============================================================================
// Shared MSM Types
// ============================================================================

typedef struct {
    uint num_scalars;
    uint num_windows;
    uint window_size;
    uint n_buckets;
} MSMConfig;

inline uint extract_scalar_window(FrElement scalar, uint window_offset, uint window_size) {
    uint limb_idx = window_offset / 64;
    uint bit_idx  = window_offset % 64;
    uint64_t val  = 0;

    if (bit_idx + window_size <= 64) {
        val = scalar.v[limb_idx] >> bit_idx;
    } else {
        uint64_t low  = scalar.v[limb_idx] >> bit_idx;
        uint next_limb = limb_idx + 1;
        uint64_t high = 0;
        if (next_limb < 4) {
            uint high_bits = bit_idx + window_size - 64;
            uint64_t high_mask = (1ULL << high_bits) - 1ULL;
            high = (scalar.v[next_limb] & high_mask) << (64 - bit_idx);
        }
        val = low | high;
    }

    uint64_t mask = (1ULL << window_size) - 1ULL;
    return (uint)(val & mask);
}

// ============================================================================
// G1 MSM v5 — sorted-bucket Pippenger (production)
// ============================================================================

#define V5_WINDOW_SIZE 8
#define V5_NUM_BUCKETS 256
#define V5_NUM_WINDOWS 32
#define V5_THREADS_PER_BUCKET 64

kernel void msm_g1_v5_bucket_reduce(
    device const FqElement*  x_array [[buffer(0)]],
    device const FqElement*  y_array [[buffer(1)]],
    device const FqElement*  neg_y_array [[buffer(2)]],
    device const MSMConfig*  config  [[buffer(3)]],
    device const uint32_t*   bucket_offsets [[buffer(4)]],
    device const uint32_t*   sorted_indices [[buffer(5)]],
    device G1Point*          bucket_sums [[buffer(6)]],
    uint tid [[thread_position_in_grid]]
) {
    uint num_buckets = V5_NUM_BUCKETS;
    uint total_buckets = V5_NUM_WINDOWS * num_buckets;
    uint threads_per_bucket = V5_THREADS_PER_BUCKET;

    uint global_tid = tid;
    if (global_tid >= total_buckets * threads_per_bucket) return;

    uint window = global_tid / (num_buckets * threads_per_bucket);
    uint bucket = (global_tid / threads_per_bucket) % num_buckets;
    uint local_tid = global_tid % threads_per_bucket;

    uint offset = bucket_offsets[window * (num_buckets + 1) + bucket];
    uint count  = bucket_offsets[window * (num_buckets + 1) + bucket + 1] - offset;

    G1Point sum = g1_zero();

    for (uint i = local_tid; i < count; i += threads_per_bucket) {
        uint point_idx = sorted_indices[offset + i];
        G1PointAffine pt;
        pt.x = x_array[point_idx];
        pt.y = (bucket < 128) ? y_array[point_idx] : neg_y_array[point_idx];
        sum = g1_add_affine(sum, pt);
    }

    threadgroup G1Point local_sums[V5_THREADS_PER_BUCKET];
    local_sums[local_tid] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (local_tid < 32) {
        local_sums[local_tid] = g1_add(local_sums[local_tid], local_sums[local_tid + 32]);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (local_tid < 16) {
        local_sums[local_tid] = g1_add(local_sums[local_tid], local_sums[local_tid + 16]);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (local_tid < 8) {
        local_sums[local_tid] = g1_add(local_sums[local_tid], local_sums[local_tid + 8]);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (local_tid < 4) {
        local_sums[local_tid] = g1_add(local_sums[local_tid], local_sums[local_tid + 4]);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (local_tid < 2) {
        local_sums[local_tid] = g1_add(local_sums[local_tid], local_sums[local_tid + 2]);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (local_tid == 0) {
        G1Point total = g1_add(local_sums[0], local_sums[1]);
        bucket_sums[window * num_buckets + bucket] = total;
    }
}

kernel void msm_g1_v5_window_reduce(
    device const G1Point*    bucket_sums [[buffer(0)]],
    device G1Point*          result [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid >= V5_NUM_WINDOWS) return;

    uint window = tid;
    uint num_buckets = V5_NUM_BUCKETS;

    G1Point pos_running = g1_zero();
    G1Point pos_sum = g1_zero();
    for (int b = 127; b >= 0; b--) {
        pos_running = g1_add(pos_running, bucket_sums[window * num_buckets + b]);
        pos_sum = g1_add(pos_sum, pos_running);
    }

    G1Point neg_running = g1_zero();
    G1Point neg_sum = g1_zero();
    for (int b = 255; b >= 128; b--) {
        neg_running = g1_add(neg_running, bucket_sums[window * num_buckets + b]);
        neg_sum = g1_add(neg_sum, neg_running);
    }

    result[window] = g1_add(pos_sum, neg_sum);
}

// ============================================================================
// G2 MSM v6 — sorted-bucket Pippenger (production)
// ============================================================================

#define G2_V6_THREADS_PER_BUCKET 64

kernel void msm_g2_v6_bucket_reduce(
    device const FqElement*  x_c0 [[buffer(0)]],
    device const FqElement*  x_c1 [[buffer(1)]],
    device const FqElement*  y_c0 [[buffer(2)]],
    device const FqElement*  y_c1 [[buffer(3)]],
    device const MSMConfig*  config  [[buffer(4)]],
    device const uint32_t*   bucket_offsets [[buffer(5)]],
    device const uint32_t*   sorted_indices [[buffer(6)]],
    device G2Point*          bucket_sums [[buffer(7)]],
    device const FqElement*  neg_y_c0 [[buffer(8)]],
    device const FqElement*  neg_y_c1 [[buffer(9)]],
    uint tid [[thread_position_in_grid]]
) {
    uint num_windows = config->num_windows;
    uint window_size = config->window_size;
    uint num_buckets = 1u << window_size;
    uint threads_per_bucket = G2_V6_THREADS_PER_BUCKET;
    uint total_buckets = num_windows * num_buckets;

    uint global_tid = tid;
    if (global_tid >= total_buckets * threads_per_bucket) return;

    uint window = global_tid / (num_buckets * threads_per_bucket);
    uint bucket = (global_tid / threads_per_bucket) % num_buckets;
    uint local_tid = global_tid % threads_per_bucket;

    uint offset = bucket_offsets[window * (num_buckets + 1) + bucket];
    uint count  = bucket_offsets[window * (num_buckets + 1) + bucket + 1] - offset;

    G2Point sum;
    g2_zero(&sum);

    for (uint i = local_tid; i < count; i += threads_per_bucket) {
        uint point_idx = sorted_indices[offset + i];
        G2PointAffine pt_affine;
        pt_affine.x.a = x_c0[point_idx];
        pt_affine.x.b = x_c1[point_idx];
        pt_affine.y.a = (bucket < 128) ? y_c0[point_idx] : neg_y_c0[point_idx];
        pt_affine.y.b = (bucket < 128) ? y_c1[point_idx] : neg_y_c1[point_idx];
        G2Point pt;
        g2_affine_to_projective(&pt_affine, &pt);
        G2Point add_result;
        g2_add(&sum, &pt, &add_result);
        sum = add_result;
    }

    threadgroup G2Point local_sums[G2_V6_THREADS_PER_BUCKET];
    local_sums[local_tid] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (local_tid < 32) {
        G2Point a = local_sums[local_tid];
        G2Point b = local_sums[local_tid + 32];
        G2Point add_result;
        g2_add(&a, &b, &add_result);
        local_sums[local_tid] = add_result;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (local_tid < 16) {
        G2Point a = local_sums[local_tid];
        G2Point b = local_sums[local_tid + 16];
        G2Point add_result;
        g2_add(&a, &b, &add_result);
        local_sums[local_tid] = add_result;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (local_tid < 8) {
        G2Point a = local_sums[local_tid];
        G2Point b = local_sums[local_tid + 8];
        G2Point add_result;
        g2_add(&a, &b, &add_result);
        local_sums[local_tid] = add_result;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (local_tid < 4) {
        G2Point a = local_sums[local_tid];
        G2Point b = local_sums[local_tid + 4];
        G2Point add_result;
        g2_add(&a, &b, &add_result);
        local_sums[local_tid] = add_result;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (local_tid < 2) {
        G2Point a = local_sums[local_tid];
        G2Point b = local_sums[local_tid + 2];
        G2Point add_result;
        g2_add(&a, &b, &add_result);
        local_sums[local_tid] = add_result;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (local_tid == 0) {
        G2Point a = local_sums[0];
        G2Point b = local_sums[1];
        G2Point add_result;
        g2_add(&a, &b, &add_result);
        bucket_sums[window * num_buckets + bucket] = add_result;
    }
}

kernel void msm_g2_v6_window_reduce(
    device const G2Point*    bucket_sums [[buffer(0)]],
    device const MSMConfig*  config  [[buffer(1)]],
    device G2Point*          result  [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    uint num_windows = config->num_windows;
    uint num_buckets = 1u << config->window_size;

    if (tid >= num_windows) return;

    uint window = tid;

    G2Point pos_running;
    G2Point pos_sum;
    g2_zero(&pos_running);
    g2_zero(&pos_sum);
    for (int b = 127; b >= 0; b--) {
        G2Point bucket_val = bucket_sums[window * num_buckets + b];
        G2Point add_result;
        g2_add(&pos_running, &bucket_val, &add_result);
        pos_running = add_result;
        g2_add(&pos_sum, &pos_running, &add_result);
        pos_sum = add_result;
    }

    G2Point neg_running;
    G2Point neg_sum;
    g2_zero(&neg_running);
    g2_zero(&neg_sum);
    for (int b = 255; b >= 128; b--) {
        G2Point bucket_val = bucket_sums[window * num_buckets + b];
        G2Point add_result;
        g2_add(&neg_running, &bucket_val, &add_result);
        neg_running = add_result;
        g2_add(&neg_sum, &neg_running, &add_result);
        neg_sum = add_result;
    }

    G2Point final_result;
    g2_add(&pos_sum, &neg_sum, &final_result);
    result[window] = final_result;
}
