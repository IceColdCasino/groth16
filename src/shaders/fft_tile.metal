// ============================================================================
// fft_tile_3buf — threadgroup tile FFT for stages 0-8, all 3 buffers
//
// Each threadgroup processes 256 elements for a, b, c simultaneously.
// Threadgroup memory: 3 × 256 × 32 bytes = 24 KB (fits in 32 KB limit)
// 128 threads per threadgroup, each handles 2 elements.
// ============================================================================

#include <metal_stdlib>
#include "field.metal"
using namespace metal;

// Reverse bits in a 32-bit integer (tile-specific version)
inline uint tile_reverse_bits(uint x) {
    x = ((x & 0x55555555u) << 1) | ((x & 0xAAAAAAAAu) >> 1);
    x = ((x & 0x33333333u) << 2) | ((x & 0xCCCCCCCCu) >> 2);
    x = ((x & 0x0F0F0F0Fu) << 4) | ((x & 0xF0F0F0F0u) >> 4);
    x = ((x & 0x00FF00FFu) << 8) | ((x & 0xFF00FF00u) >> 8);
    x = (x << 16) | (x >> 16);
    return x;
}

kernel void fft_tile_3buf(
    device FrElement* a [[buffer(0)]],
    device FrElement* b [[buffer(1)]],
    device FrElement* c [[buffer(2)]],
    device const FrElement* twiddles [[buffer(3)]],
    constant uint& n [[buffer(4)]],
    uint tid [[thread_position_in_grid]],
    uint lid [[thread_index_in_threadgroup]],
    uint gid [[threadgroup_position_in_grid]]
) {
    const uint TILE_SIZE = 256;
    const uint LOG_TILE = 8;
    const uint THREADS_PER_GROUP = 128;
    
    // Threadgroup memory: 3 buffers × 256 elements
    threadgroup FrElement tile_a[TILE_SIZE];
    threadgroup FrElement tile_b[TILE_SIZE];
    threadgroup FrElement tile_c[TILE_SIZE];
    
    uint tile_start = gid * TILE_SIZE;
    
    // Load tile from device memory (coalesced)
    for (uint i = lid; i < TILE_SIZE; i += THREADS_PER_GROUP) {
        tile_a[i] = a[tile_start + i];
        tile_b[i] = b[tile_start + i];
        tile_c[i] = c[tile_start + i];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Bit-reverse permutation within tile
    for (uint i = lid; i < TILE_SIZE; i += THREADS_PER_GROUP) {
            uint j = tile_reverse_bits(i) >> (32 - LOG_TILE);
        if (i < j) {
            FrElement tmp = tile_a[i];
            tile_a[i] = tile_a[j];
            tile_a[j] = tmp;
            
            tmp = tile_b[i];
            tile_b[i] = tile_b[j];
            tile_b[j] = tmp;
            
            tmp = tile_c[i];
            tile_c[i] = tile_c[j];
            tile_c[j] = tmp;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Butterfly stages 1-8 (m = 2, 4, 8, ..., 256)
    for (uint stage = 1; stage <= LOG_TILE; stage++) {
        uint half_m = 1u << (stage - 1u);
        uint m = half_m << 1u;
        uint twiddle_step = n >> stage;
        
        // Each thread handles multiple butterflies within tile
        for (uint idx = lid; idx < (TILE_SIZE >> 1); idx += THREADS_PER_GROUP) {
            uint group = idx / half_m;
            uint offset = idx & (half_m - 1u);
            uint i = (group * m) + offset;
            uint j = i + half_m;
            
            uint twiddle_idx = offset * twiddle_step;
            
            FrElement u = tile_a[i];
            FrElement v = fr_mul(tile_a[j], twiddles[twiddle_idx]);
            tile_a[i] = fr_add(u, v);
            tile_a[j] = fr_sub(u, v);
            
            u = tile_b[i];
            v = fr_mul(tile_b[j], twiddles[twiddle_idx]);
            tile_b[i] = fr_add(u, v);
            tile_b[j] = fr_sub(u, v);
            
            u = tile_c[i];
            v = fr_mul(tile_c[j], twiddles[twiddle_idx]);
            tile_c[i] = fr_add(u, v);
            tile_c[j] = fr_sub(u, v);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    
    // Store tile back to device memory
    for (uint i = lid; i < TILE_SIZE; i += THREADS_PER_GROUP) {
        a[tile_start + i] = tile_a[i];
        b[tile_start + i] = tile_b[i];
        c[tile_start + i] = tile_c[i];
    }
}
