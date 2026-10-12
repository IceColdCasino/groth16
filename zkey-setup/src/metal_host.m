#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#import <string.h>

static id<MTLDevice> g_dev;
static id<MTLCommandQueue> g_queue;
static id<MTLComputePipelineState> g_same;
static id<MTLComputePipelineState> g_many;
static id<MTLComputePipelineState> g_g2;

int metal_init(const char *path) {
    @autoreleasepool {
        g_dev = MTLCreateSystemDefaultDevice();
        if (!g_dev) return 1;
        NSError *err = nil;
        NSString *file = [NSString stringWithUTF8String:path];
        id<MTLLibrary> lib = [g_dev newLibraryWithFile:file error:&err];
        if (!lib) return 2;
        id<MTLFunction> same = [lib newFunctionWithName:@"g1_mul_same"];
        id<MTLFunction> many = [lib newFunctionWithName:@"g1_mul_many"];
        if (!same || !many) return 3;
        g_same = [g_dev newComputePipelineStateWithFunction:same error:&err];
        if (!g_same) return 4;
        g_many = [g_dev newComputePipelineStateWithFunction:many error:&err];
        if (!g_many) return 5;
        id<MTLFunction> g2 = [lib newFunctionWithName:@"g2_glv_many"];
        if (!g2) return 3;
        g_g2 = [g_dev newComputePipelineStateWithFunction:g2 error:&err];
        if (!g_g2) return 5;
        g_queue = [g_dev newCommandQueue];
        if (!g_queue) return 6;
        return 0;
    }
}

static int dispatch(id<MTLComputePipelineState> pipe, const void *points, unsigned n, const void *scalars, unsigned long long scalar_bytes, const void *params, void *out) {
    if (n == 0) return 0;
    @autoreleasepool {
        unsigned long long nbytes = (unsigned long long)n * 64ull;
        id<MTLBuffer> in_b = [g_dev newBufferWithBytes:points length:(NSUInteger)nbytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> out_b = [g_dev newBufferWithLength:(NSUInteger)nbytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> sc_b = [g_dev newBufferWithBytes:scalars length:scalar_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> p_b = [g_dev newBufferWithBytes:params length:136 options:MTLResourceStorageModeShared];
        if (!in_b || !out_b || !sc_b || !p_b) return 7;
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pipe];
        [enc setBuffer:in_b offset:0 atIndex:0];
        [enc setBuffer:out_b offset:0 atIndex:1];
        [enc setBuffer:sc_b offset:0 atIndex:2];
        [enc setBuffer:p_b offset:0 atIndex:3];
        NSUInteger width = pipe.threadExecutionWidth;
        if (width == 0) width = 32;
        if (width > n) width = n;
        [enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) return 8;
        memcpy(out, out_b.contents, (size_t)nbytes);
        return 0;
    }
}

int metal_g1_same(const void *points, unsigned n, const void *scalar, const void *params, void *out) {
    return dispatch(g_same, points, n, scalar, 32, params, out);
}

int metal_g1_many(const void *points, unsigned n, const void *scalars, const void *params, void *out) {
    return dispatch(g_many, points, n, scalars, (unsigned long long)n * 32ull, params, out);
}

int metal_g2_many(const void *p1, const void *p2, unsigned n, const void *scalars, const void *params, void *out) {
    if (n == 0) return 0;
    @autoreleasepool {
        unsigned long long nbytes = (unsigned long long)n * 128ull;
        unsigned long long obytes = (unsigned long long)n * 192ull;
        unsigned long long sbytes = (unsigned long long)n * 32ull;
        id<MTLBuffer> b1 = [g_dev newBufferWithBytes:p1 length:(NSUInteger)nbytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> b2 = [g_dev newBufferWithBytes:p2 length:(NSUInteger)nbytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> out_b = [g_dev newBufferWithLength:(NSUInteger)obytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> sc_b = [g_dev newBufferWithBytes:scalars length:(NSUInteger)sbytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> p_b = [g_dev newBufferWithBytes:params length:136 options:MTLResourceStorageModeShared];
        if (!b1 || !b2 || !out_b || !sc_b || !p_b) return 7;
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:g_g2];
        [enc setBuffer:b1 offset:0 atIndex:0];
        [enc setBuffer:out_b offset:0 atIndex:1];
        [enc setBuffer:b2 offset:0 atIndex:2];
        [enc setBuffer:sc_b offset:0 atIndex:3];
        [enc setBuffer:p_b offset:0 atIndex:4];
        NSUInteger width = g_g2.threadExecutionWidth;
        if (width == 0) width = 32;
        NSUInteger cap = g_g2.maxTotalThreadsPerThreadgroup;
        if (cap > 0 && width > cap) width = cap;
        if (width > n) width = n;
        [enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) return 8;
        memcpy(out, out_b.contents, (size_t)obytes);
        return 0;
    }
}
