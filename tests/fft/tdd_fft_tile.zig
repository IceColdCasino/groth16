const std = @import("std");
const gpu = @import("gpu");
const cpu = @import("cpu");
const field = cpu.field;

test "fft_tile_3buf matches CPU fft_fr for 256 elements" {
    const n: u32 = 256;
    var data_cpu = try std.testing.allocator.alloc(field.FrElement, n);
    defer std.testing.allocator.free(data_cpu);
    var data_gpu = try std.testing.allocator.alloc(field.FrElement, n);
    defer std.testing.allocator.free(data_gpu);
    
    for (0..n) |i| {
        data_cpu[i] = field.fr_toMont(field.fr_from_u64(@intCast(i + 1)));
        data_gpu[i] = data_cpu[i];
    }
    
    // CPU reference
    cpu.fft.fft_fr(data_cpu, n);
    
    // GPU tile kernel
    const prover = try gpu.metal.MetalProver.init(std.testing.allocator);
    defer prover.deinit();
    
    try prover.fftTile3buf(data_gpu, n);
    
    for (0..n) |i| {
        try std.testing.expect(field.fr_eq(data_cpu[i], data_gpu[i]));
    }
}
