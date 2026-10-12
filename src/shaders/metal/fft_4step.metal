// ============================================================================
// 4-Step NTT for large domains (n >= 2^10) using hierarchical approach
//
// Strategy:
//   1. fft_tile_1024: Stages 1-10 in threadgroup memory (1024-element tiles)
//   2. transpose_1024: Transpose 1024x1024 matrix using shared memory tiles
//   3. twiddle_multiply: Element-wise multiply by omega^{i*j}
//   4. fft_tile_1024: Column NTTs on transposed data (now row NTTs)
//   5. transpose_1024: Transpose back
//
// Total: 5 dispatches for a complete 2^20 NTT vs 21 dispatches for per-stage.
// ============================================================================

#include <metal_stdlib>
#include "field.metal"
using namespace metal;

// ---------------------------------------------------------------------------
// fft_tile_1024 — single-kernel FFT for stages 1-10
// Each threadgroup processes one 1024-element tile entirely in shared memory.
// 1024 threads per group, each handles 1 element.
// Shared memory: 1024 elements × 32 bytes = 32KB (at Apple Silicon limit)
// ---------------------------------------------------------------------------

#define TILE_1024_SIZE 1024
#define TILE_1024_LOG 10
#define TILE_1024_THREADS 1024

inline uint reverse_bits_1024(uint x) {
    // Fast 10-bit reversal (full 32-bit reversal then keep lower 10)
    x = ((x & 0x55555555u) << 1) | ((x & 0xAAAAAAAAu) >> 1);
    x = ((x & 0x33333333u) << 2) | ((x & 0xCCCCCCCCu) >> 2);
    x = ((x & 0x0F0F0F0Fu) << 4) | ((x & 0xF0F0F0F0u) >> 4);
    x = ((x & 0x00FF00FFu) << 8) | ((x & 0xFF00FF00u) >> 8);
    x = (x << 16) | (x >> 16);
    return x >> 22; // Keep only lower 10 bits
}

#define THREADS_PER_GROUP_1024 512

kernel void fft_tile_1024(
    device FrElement* data [[buffer(0)]],
    device const FrElement* twiddles [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint tid [[thread_position_in_grid]],
    uint lid [[thread_index_in_threadgroup]],
    uint gid [[threadgroup_position_in_grid]]
) {
    threadgroup FrElement tile[TILE_1024_SIZE];
    
    uint tile_start = gid * TILE_1024_SIZE;
    
    // Load tile from device memory (coalesced)
    // Input must already be bit-reversed for full N-point FFT.
    for (uint i = lid; i < TILE_1024_SIZE; i += THREADS_PER_GROUP_1024) {
        tile[i] = data[tile_start + i];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Butterfly stages 1-10 (m = 2, 4, 8, ..., 1024)
    for (uint stage = 1; stage <= TILE_1024_LOG; stage++) {
        uint half_m = 1u << (stage - 1u);
        uint m = half_m << 1u;
        uint twiddle_step = n >> stage;
        
        // Each thread handles multiple butterflies within tile
        for (uint idx = lid; idx < (TILE_1024_SIZE >> 1); idx += THREADS_PER_GROUP_1024) {
            uint group = idx / half_m;
            uint offset = idx & (half_m - 1u);
            uint i = (group * m) + offset;
            uint j_idx = i + half_m;
            
            uint twiddle_idx = offset * twiddle_step;
            
            FrElement u = tile[i];
            FrElement v = fr_mul(tile[j_idx], twiddles[twiddle_idx]);
            tile[i] = fr_add(u, v);
            tile[j_idx] = fr_sub(u, v);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    
    // Store tile back to device memory (coalesced)
    for (uint i = lid; i < TILE_1024_SIZE; i += THREADS_PER_GROUP_1024) {
        data[tile_start + i] = tile[i];
    }
}

#define TILE_512_SIZE 512
#define TILE_512_LOG 9

inline uint reverse_bits_512(uint x) {
    x = ((x & 0x55555555u) << 1) | ((x & 0xAAAAAAAAu) >> 1);
    x = ((x & 0x33333333u) << 2) | ((x & 0xCCCCCCCCu) >> 2);
    x = ((x & 0x0F0F0F0Fu) << 4) | ((x & 0xF0F0F0F0u) >> 4);
    x = ((x & 0x00FF00FFu) << 8) | ((x & 0xFF00FF00u) >> 8);
    x = (x << 16) | (x >> 16);
    return (x >> 23) & 0x1FF; // Keep only lower 9 bits
}

#define THREADS_PER_GROUP_512 256

kernel void fft_tile_512(
    device FrElement* data [[buffer(0)]],
    device const FrElement* twiddles [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint tid [[thread_position_in_grid]],
    uint lid [[thread_index_in_threadgroup]],
    uint gid [[threadgroup_position_in_grid]]
) {
    threadgroup FrElement tile[TILE_512_SIZE];
    
    uint tile_start = gid * TILE_512_SIZE;
    
    // Load tile from device memory (coalesced)
    // Input must already be bit-reversed for full N-point FFT.
    for (uint i = lid; i < TILE_512_SIZE; i += THREADS_PER_GROUP_512) {
        tile[i] = data[tile_start + i];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Butterfly stages 1-9 (m = 2, 4, 8, ..., 512)
    for (uint stage = 1; stage <= TILE_512_LOG; stage++) {
        uint half_m = 1u << (stage - 1u);
        uint m = half_m << 1u;
        uint twiddle_step = n >> stage;
        
        // Each thread handles multiple butterflies within tile
        for (uint idx = lid; idx < (TILE_512_SIZE >> 1); idx += THREADS_PER_GROUP_512) {
            uint group = idx / half_m;
            uint offset = idx & (half_m - 1u);
            uint i = (group * m) + offset;
            uint j_idx = i + half_m;
            
            uint twiddle_idx = offset * twiddle_step;
            
            FrElement u = tile[i];
            FrElement v = fr_mul(tile[j_idx], twiddles[twiddle_idx]);
            tile[i] = fr_add(u, v);
            tile[j_idx] = fr_sub(u, v);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    
    // Store tile back to device memory (coalesced)
    for (uint i = lid; i < TILE_512_SIZE; i += THREADS_PER_GROUP_512) {
        data[tile_start + i] = tile[i];
    }
}

// ---------------------------------------------------------------------------
// fft_global_stage — single stage in global memory for stages 10+
// Optimized for coalesced access: each threadgroup processes contiguous butterflies
// ---------------------------------------------------------------------------

kernel void fft_global_stage(
    device FrElement* data [[buffer(0)]],
    device const FrElement* twiddles [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    constant uint& stage [[buffer(3)]],  // stage number (1-based)
    uint tid [[thread_position_in_grid]]
) {
    uint half_m = 1u << (stage - 1u);
    uint m = half_m << 1u;
    uint twiddle_step = n >> stage;
    uint total_butterflies = n >> 1;
    
    // Each thread processes one butterfly
    if (tid >= total_butterflies) return;
    
    uint group = tid / half_m;
    uint offset = tid & (half_m - 1u);
    uint i = (group * m) + offset;
    uint j_idx = i + half_m;
    uint twiddle_idx = offset * twiddle_step;
    
    FrElement u = data[i];
    FrElement v = fr_mul(data[j_idx], twiddles[twiddle_idx]);
    data[i] = fr_add(u, v);
    data[j_idx] = fr_sub(u, v);
}

// ---------------------------------------------------------------------------
// fft_global_stages_batched — multiple global stages in ONE dispatch
//
// Strategy: each threadgroup processes a self-contained chunk of butterflies.
// The chunk size equals the group size of the LAST stage in the batch, ensuring
// all butterflies in the chunk stay within the chunk for every stage.
// Threads within a threadgroup synchronize via threadgroup_barrier on device
// memory between stages.
//
// This reduces command buffer overhead by batching stages while maintaining
// correctness through threadgroup-level barriers on disjoint chunks.
// ---------------------------------------------------------------------------

kernel void fft_global_stages_batched(
    device FrElement* data [[buffer(0)]],
    device const FrElement* twiddles [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    constant uint& start_stage [[buffer(3)]],
    constant uint& num_stages [[buffer(4)]],
    constant uint& threads_per_group [[buffer(5)]],
    uint tid [[thread_position_in_grid]],
    uint lid [[thread_index_in_threadgroup]],
    uint gid [[threadgroup_position_in_grid]]
) {
    uint max_stage = start_stage + num_stages - 1;
    uint chunk_size = 1u << max_stage;        // elements per chunk
    uint butterflies_per_chunk = chunk_size >> 1;
    uint num_chunks = n >> max_stage;
    
    // Each threadgroup is assigned one chunk; chunks are disjoint
    if (gid >= num_chunks) return;
    
    uint chunk_start_butterfly = gid * butterflies_per_chunk;
    uint butterflies_per_thread = (butterflies_per_chunk + threads_per_group - 1) / threads_per_group;
    
    for (uint s = 0; s < num_stages; s++) {
        uint stage = start_stage + s;
        uint half_m = 1u << (stage - 1u);
        uint m = half_m << 1u;
        uint twiddle_step = n >> stage;
        
        // Each thread processes multiple butterflies within its chunk
        for (uint b = 0; b < butterflies_per_thread; b++) {
            uint butterfly_id = chunk_start_butterfly + lid + b * threads_per_group;
            if (butterfly_id >= chunk_start_butterfly + butterflies_per_chunk) continue;
            
            uint group = butterfly_id / half_m;
            uint offset = butterfly_id & (half_m - 1u);
            uint i = (group * m) + offset;
            uint j_idx = i + half_m;
            uint twiddle_idx = offset * twiddle_step;
            
            FrElement u = data[i];
            FrElement v = fr_mul(data[j_idx], twiddles[twiddle_idx]);
            data[i] = fr_add(u, v);
            data[j_idx] = fr_sub(u, v);
        }
        
        // Ensure all threads in this threadgroup finish the stage before next
        threadgroup_barrier(mem_flags::mem_device);
    }
}

// ---------------------------------------------------------------------------
// fft_global_stages_batched — multiple global stages in ONE dispatch
// This is the key optimization: we batch stages 11-20 into fewer dispatches.
// We do this by having each thread process a sub-tree of butterflies.
//
// For stages 11-20 with n=2^20:
//   Stage 11: half_m=1024, each butterfly pairs elements 1024 apart
//   Stage 12: half_m=2048
//   ...
//   Stage 20: half_m=524288
//
// The key insight: for stages s where half_m >= 1024, we can view the FFT as
// 1024 independent sub-FFTs of size n/1024 = 2^(20-s).
// Each sub-FFT is independent and can be processed by one threadgroup.
//
// Wait, that's not quite right. In a radix-2 FFT, stages are NOT independent.
// Stage s+1 reads the outputs of stage s.
// Without a global barrier, we can't do multiple stages in one dispatch.
//
// Alternative: We process stages in groups where each group uses a
// "virtual transpose" to make access patterns local.
//
// For now, the practical approach:
//   - Stages 1-8: fft_tile_3buf (1 dispatch, 3 buffers)
//   - Stages 9-10: fft_tile_512 called 3 times (1 dispatch per buffer)
//   - Stages 11-20: fft_global_stage called 3 times per stage (10 stages × 3 = 30 dispatches)
// Total: 1 + 3 + 30 = 34 dispatches for 3 buffers. Worse than current.
//
// The 4-step approach is better:
//   - Stages 1-10: fft_tile_1024 for each buffer (3 dispatches)
//   - Transpose: 1 dispatch (shared by all 3 buffers... but they need separate outputs)
//     Actually, each buffer needs its own transpose. 3 dispatches.
//   - Twiddle multiply: 1 dispatch per buffer. 3 dispatches.
//   - Column NTT (fft_tile_1024 on transposed): 3 dispatches.
//   - Transpose back: 3 dispatches.
// Total: 3 + 3 + 3 + 3 + 3 = 15 dispatches for 3 buffers.
// Compare to current: 21 stages × 3 buffers = 63 dispatches (in fftFrBatched3).
// 15 is better than 63, but still has overhead.
//
// Can we do the transpose and twiddle for all 3 buffers in one dispatch?
// Yes! We can create a kernel that does all 3 simultaneously.
//
// Let me create batched versions:
// ---------------------------------------------------------------------------

#define TRANSPOSE_TILE 32
#define TRANSPOSE_TILE_ELEMENTS (TRANSPOSE_TILE * TRANSPOSE_TILE)

kernel void transpose_1024(
    device const FrElement* input [[buffer(0)]],
    device FrElement* output [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint tid [[thread_position_in_grid]],
    uint lid [[thread_index_in_threadgroup]],
    uint gid [[threadgroup_position_in_grid]]
) {
    const uint tiles_per_row = 1024 / TRANSPOSE_TILE;
    
    uint tile_idx = gid;
    uint tile_row = tile_idx / tiles_per_row;
    uint tile_col = tile_idx % tiles_per_row;
    
    uint local_row = lid / TRANSPOSE_TILE;
    uint local_col = lid % TRANSPOSE_TILE;
    
    uint in_row = tile_row * TRANSPOSE_TILE + local_row;
    uint in_col = tile_col * TRANSPOSE_TILE + local_col;
    
    threadgroup FrElement smem[TRANSPOSE_TILE_ELEMENTS];
    uint in_idx = in_row * 1024 + in_col;
    smem[lid] = input[in_idx];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    uint transposed_lid = local_col * TRANSPOSE_TILE + local_row;
    uint out_row = tile_col * TRANSPOSE_TILE + local_col;
    uint out_col = tile_row * TRANSPOSE_TILE + local_row;
    uint out_idx = out_row * 1024 + out_col;
    output[out_idx] = smem[transposed_lid];
}

kernel void transpose_1024_3buf(
    device const FrElement* input_a [[buffer(0)]],
    device FrElement* output_a [[buffer(1)]],
    device const FrElement* input_b [[buffer(2)]],
    device FrElement* output_b [[buffer(3)]],
    device const FrElement* input_c [[buffer(4)]],
    device FrElement* output_c [[buffer(5)]],
    constant uint& n [[buffer(6)]],
    uint tid [[thread_position_in_grid]],
    uint lid [[thread_index_in_threadgroup]],
    uint gid [[threadgroup_position_in_grid]]
) {
    const uint tiles_per_row = 32;
    
    uint tile_idx = gid;
    uint tile_row = tile_idx / tiles_per_row;
    uint tile_col = tile_idx % tiles_per_row;
    
    uint local_row = lid / 32;
    uint local_col = lid % 32;
    
    uint in_row = tile_row * 32 + local_row;
    uint in_col = tile_col * 32 + local_col;
    
    threadgroup FrElement smem_a[1024];
    threadgroup FrElement smem_b[1024];
    threadgroup FrElement smem_c[1024];
    
    uint in_idx = in_row * 1024 + in_col;
    smem_a[lid] = input_a[in_idx];
    smem_b[lid] = input_b[in_idx];
    smem_c[lid] = input_c[in_idx];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    uint transposed_lid = local_col * 32 + local_row;
    uint out_row = tile_col * 32 + local_row;
    uint out_col = tile_row * 32 + local_col;
    uint out_idx = out_row * 1024 + out_col;
    
    output_a[out_idx] = smem_a[transposed_lid];
    output_b[out_idx] = smem_b[transposed_lid];
    output_c[out_idx] = smem_c[transposed_lid];
}

kernel void twiddle_multiply_1024(
    device FrElement* data [[buffer(0)]],
    device const FrElement* twiddles_2d [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    uint chunk = (n + 255u) / 256u;
    uint64_t start64 = (uint64_t)tid * (uint64_t)chunk;
    if (start64 >= n) return;
    uint start = (uint)start64;
    uint end = min(start + chunk, n);
    
    for (uint i = start; i < end; i++) {
        data[i] = fr_mul(data[i], twiddles_2d[i]);
    }
}

kernel void twiddle_multiply_1024_3buf(
    device FrElement* a [[buffer(0)]],
    device FrElement* b [[buffer(1)]],
    device FrElement* c [[buffer(2)]],
    device const FrElement* twiddles_2d [[buffer(3)]],
    constant uint& n [[buffer(4)]],
    uint tid [[thread_position_in_grid]]
) {
    uint chunk = (n + 255u) / 256u;
    uint64_t start64 = (uint64_t)tid * (uint64_t)chunk;
    if (start64 >= n) return;
    uint start = (uint)start64;
    uint end = min(start + chunk, n);
    
    for (uint i = start; i < end; i++) {
        a[i] = fr_mul(a[i], twiddles_2d[i]);
        b[i] = fr_mul(b[i], twiddles_2d[i]);
        c[i] = fr_mul(c[i], twiddles_2d[i]);
    }
}

// ---------------------------------------------------------------------------
// bit_reverse — in-place bit-reversal permutation
// Each thread handles a chunk of elements, swapping i <-> bitreverse(i) when i < rev(i)
// ---------------------------------------------------------------------------
inline uint bit_reverse_4step(uint x, uint log_n) {
    uint r = 0;
    for (uint i = 0; i < log_n; i++) {
        r = (r << 1) | ((x >> i) & 1u);
    }
    return r;
}

// out-of-place bit-reversal to avoid data races in device memory.
// Each thread writes to a unique output index (bit-reverse permutation).
kernel void bit_reverse(
    device const FrElement* input [[buffer(0)]],
    device FrElement* output [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    constant uint& log_n [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    uint chunk = (n + 255u) / 256u;
    uint64_t start64 = (uint64_t)tid * (uint64_t)chunk;
    if (start64 >= n) return;
    uint start = (uint)start64;
    uint end = min(start + chunk, n);
    for (uint i = start; i < end; i++) {
        uint j = bit_reverse_4step(i, log_n);
        output[j] = input[i];
    }
}

// ---------------------------------------------------------------------------
// ifft_scale_shift — divide by n (Montgomery inverse) and multiply by g^i
// Combined into one kernel to reduce dispatch overhead.
// ---------------------------------------------------------------------------
kernel void ifft_scale_shift(
    device FrElement* a [[buffer(0)]],
    device FrElement* b [[buffer(1)]],
    device FrElement* c [[buffer(2)]],
    device const FrElement* g_powers [[buffer(3)]],
    device const FrElement* inverse_n [[buffer(4)]],
    constant uint& n [[buffer(5)]],
    uint tid [[thread_position_in_grid]]
) {
    uint chunk = (n + 255u) / 256u;
    uint64_t start64 = (uint64_t)tid * (uint64_t)chunk;
    if (start64 >= n) return;
    uint start = (uint)start64;
    uint end = min(start + chunk, n);
    for (uint i = start; i < end; i++) {
        a[i] = fr_mul(fr_mul(a[i], *inverse_n), g_powers[i]);
        b[i] = fr_mul(fr_mul(b[i], *inverse_n), g_powers[i]);
        c[i] = fr_mul(fr_mul(c[i], *inverse_n), g_powers[i]);
    }
}
