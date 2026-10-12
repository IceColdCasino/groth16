const std = @import("std");
const gpu = @import("gpu");
const cpu = @import("cpu");

// Test values (16 in Montgomery form)
const sixteen_mont = [4]u64{ 0x45520880f6fce4b4, 0x49890849baa989a8, 0x85a9201d818f014a, 0x1f16424e1bb7724f };

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const prover = try gpu.metal.MetalProver.init(allocator);
    defer prover.deinit();

    std.debug.print("\n=== GPU Throughput Benchmarks ===\n", .{});

    // Benchmark raw mulhi throughput
    std.debug.print("\n1. Raw mulhi throughput (1024 ops/thread):\n", .{});
    const mulhi_time = try prover.benchmarkKernel("bench_mulhi", sixteen_mont, sixteen_mont, 1);
    std.debug.print("   1 thread:   {d:.3} ms  ({d:.1} M mulhi/sec/thread)\n", .{ mulhi_time, 1.0 / (mulhi_time / 1000.0) * 1024.0 / 1_000_000.0 });
    const mulhi_time_1k = try prover.benchmarkKernel("bench_mulhi", sixteen_mont, sixteen_mont, 1024);
    std.debug.print("   1024 threads: {d:.3} ms  ({d:.1} M mulhi/sec total)\n", .{ mulhi_time_1k, 1024.0 * 1024.0 / (mulhi_time_1k / 1000.0) / 1_000_000.0 });
    const mulhi_time_32k = try prover.benchmarkKernel("bench_mulhi", sixteen_mont, sixteen_mont, 32768);
    std.debug.print("   32768 threads: {d:.3} ms  ({d:.1} M mulhi/sec total)\n", .{ mulhi_time_32k, 32768.0 * 1024.0 / (mulhi_time_32k / 1000.0) / 1_000_000.0 });

    // Benchmark fq_mul throughput
    std.debug.print("\n2. fq_mul throughput (256 ops/thread):\n", .{});
    const fq_time = try prover.benchmarkKernel("bench_fq_mul", sixteen_mont, sixteen_mont, 1);
    std.debug.print("   1 thread:   {d:.3} ms  ({d:.1} K mul/sec/thread)\n", .{ fq_time, 1.0 / (fq_time / 1000.0) * 256.0 / 1000.0 });
    const fq_time_1k = try prover.benchmarkKernel("bench_fq_mul", sixteen_mont, sixteen_mont, 1024);
    std.debug.print("   1024 threads: {d:.3} ms  ({d:.1} K mul/sec total)\n", .{ fq_time_1k, 1024.0 * 256.0 / (fq_time_1k / 1000.0) / 1000.0 });
    const fq_time_32k = try prover.benchmarkKernel("bench_fq_mul", sixteen_mont, sixteen_mont, 32768);
    std.debug.print("   32768 threads: {d:.3} ms  ({d:.1} K mul/sec total)\n", .{ fq_time_32k, 32768.0 * 256.0 / (fq_time_32k / 1000.0) / 1000.0 });

    // Benchmark g1_add_affine throughput
    std.debug.print("\n3. g1_add_affine throughput (128 ops/thread):\n", .{});
    // Create two valid G1 points for benchmarking
    var g1_a_bytes: [64]u8 = undefined;
    var g1_b_bytes: [64]u8 = undefined;
    const g1_gen = cpu.curve.g1_generator();
    const g1_gen_affine = cpu.curve.g1_normalize(g1_gen);
    const g1_2 = cpu.curve.g1_dbl(g1_gen);
    const g1_2_affine = cpu.curve.g1_normalize(g1_2);
    @memcpy(&g1_a_bytes, std.mem.sliceAsBytes(&[1]cpu.curve.G1PointAffine{g1_gen_affine}));
    @memcpy(&g1_b_bytes, std.mem.sliceAsBytes(&[1]cpu.curve.G1PointAffine{g1_2_affine}));
    
    // Use first 32 bytes as two [4]u64 for the benchmark function signature
    var g1_a_u64: [4]u64 = undefined;
    var g1_b_u64: [4]u64 = undefined;
    @memcpy(std.mem.sliceAsBytes(&g1_a_u64), g1_a_bytes[0..32]);
    @memcpy(std.mem.sliceAsBytes(&g1_b_u64), g1_b_bytes[0..32]);
    
    const g1_time_1k = try prover.benchmarkKernel("bench_g1_add_affine", g1_a_u64, g1_b_u64, 1024);
    std.debug.print("   1024 threads: {d:.3} ms  ({d:.1} K adds/sec total)\n", .{ g1_time_1k, 1024.0 * 128.0 / (g1_time_1k / 1000.0) / 1000.0 });
    const g1_time_32k = try prover.benchmarkKernel("bench_g1_add_affine", g1_a_u64, g1_b_u64, 32768);
    std.debug.print("   32768 threads: {d:.3} ms  ({d:.1} K adds/sec total)\n", .{ g1_time_32k, 32768.0 * 128.0 / (g1_time_32k / 1000.0) / 1000.0 });

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Each g1_add_affine uses ~10 fq_mul\n", .{});
    std.debug.print("Each fq_mul uses ~16 mulhi (4x4 mult + 4x4 reduction)\n", .{});
    std.debug.print("So each g1_add_affine uses ~160 mulhi\n\n", .{});
}
