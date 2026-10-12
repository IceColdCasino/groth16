const std = @import("std");
const cpu = @import("cpu");
const c = @import("c");

const ZKEY_PATH = "benchmarks/circuits/medium/circuit_final.zkey";
const WTNS_PATH = "benchmarks/circuits/medium/witness.wtns";
fn getTimeMs() f64 {
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @as(f64, @floatFromInt(tv.tv_sec)) * 1000.0 + @as(f64, @floatFromInt(tv.tv_usec)) / 1000.0;
}

fn median(values: []f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[values.len / 2];
}

fn benchmarkCpu(iterations: usize) !f64 {
    var warmup = try cpu.prove(ZKEY_PATH, WTNS_PATH);
    std.debug.print("CPU warmup proof len={d} public={d}\n", .{ warmup.proof.len, warmup.public_signals.len });
    warmup.deinit();
    var times = try std.heap.c_allocator.alloc(f64, iterations);
    defer std.heap.c_allocator.free(times);
    for (0..iterations) |i| {
        const start = getTimeMs();
        var result = try cpu.prove(ZKEY_PATH, WTNS_PATH);
        const elapsed = getTimeMs() - start;
        std.debug.print("CPU iteration {d}: {d:.2} ms, proof={d}B\n", .{ i, elapsed, result.proof.len });
        // Verify the proof
        const vk_data = try cpu.readFileToBuffer("benchmarks/circuits/medium/verification_key.json", std.heap.c_allocator);
        defer std.heap.c_allocator.free(vk_data);
        const verified = try cpu.verifier.verify(std.heap.c_allocator, vk_data, result.proof, result.public_signals);
        std.debug.print("  Verified: {}\n", .{verified});
        result.deinit();
        times[i] = elapsed;
    }
    return median(times);
}

fn benchmarkMetal(iterations: usize) !f64 {
    const gpu = @import("gpu");
    var warmup = try gpu.metal.proveOnGpu(ZKEY_PATH, WTNS_PATH, .{});
    warmup.deinit();
    var times = try std.heap.c_allocator.alloc(f64, iterations);
    defer std.heap.c_allocator.free(times);
    for (0..iterations) |i| {
        const start = getTimeMs();
        var result = if (i == 0)
            try gpu.metal.proveOnGpuProfiled(ZKEY_PATH, WTNS_PATH, .{})
        else
            try gpu.metal.proveOnGpu(ZKEY_PATH, WTNS_PATH, .{});
        const elapsed = getTimeMs() - start;
        // Verify Metal proof (outside timing)
        const vk_data = try cpu.readFileToBuffer("benchmarks/circuits/medium/verification_key.json", std.heap.c_allocator);
        defer std.heap.c_allocator.free(vk_data);
        const verified = try cpu.verifier.verify(std.heap.c_allocator, vk_data, result.proof, result.public_signals);
        std.debug.print("  Metal iteration {d}: {d:.2} ms, verified={}\n", .{ i, elapsed, verified });
        result.deinit();
        times[i] = elapsed;
    }
    return median(times);
}

pub fn main() !void {
    const iterations = 3;
    std.debug.print("\n=== Medium Circuit (5K constraints) Benchmark ===\n\n", .{});
    std.debug.print("Benchmarking CPU prover...\n", .{});
    const cpu_ms = try benchmarkCpu(iterations);
    std.debug.print("Benchmarking Metal prover...\n", .{});
    const metal_ms = try benchmarkMetal(iterations);
    std.debug.print("\n=== Results ===\n", .{});
    std.debug.print("     Backend |  Median (ms) | Speedup vs CPU\n", .{});
    std.debug.print("-------------+--------------+----------------------\n", .{});
    std.debug.print("         CPU | {d:>12.2} | {d:>19.2}x\n", .{ cpu_ms, 1.0 });
    std.debug.print("       Metal | {d:>12.2} | {d:>19.2}x\n", .{ metal_ms, cpu_ms / metal_ms });
    std.debug.print("\n", .{});
}
