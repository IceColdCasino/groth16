#include <metal_stdlib>
#include "field.metal"
using namespace metal;

kernel void test_mul(
    device const FqElement* a [[buffer(0)]],
    device const FqElement* b [[buffer(1)]],
    device FqElement* result [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid != 0) return;
    result[0] = fq_mul(a[0], b[0]);
}

kernel void test_mulhi(
    device const uint64_t* a [[buffer(0)]],
    device const uint64_t* b [[buffer(1)]],
    device uint64_t* result [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid != 0) return;
    result[0] = mulhi(a[0], b[0]);
}
