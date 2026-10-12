const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const testdata = @import("testdata");
const c = @import("c");

fn getTimeMs() f64 {
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @as(f64, @floatFromInt(tv.tv_sec)) * 1000.0 + @as(f64, @floatFromInt(tv.tv_usec)) / 1000.0;
}

fn writeTempFile(allocator: std.mem.Allocator, name: []const u8, data: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/prover_bench_{s}", .{name});
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
    return path;
}

fn benchmarkCpu(iterations: usize, zkey_path: []const u8, wtns_path: []const u8) !f64 {
    var warmup = try cpu.prove(zkey_path, wtns_path);
    warmup.deinit();
    var times = try std.heap.c_allocator.alloc(f64, iterations);
    defer std.heap.c_allocator.free(times);
    for (0..iterations) |i| {
        const start = getTimeMs();
        var result = try cpu.prove(zkey_path, wtns_path);
        result.deinit();
        const elapsed_ms = getTimeMs() - start;
        std.debug.print("  CPU iteration {d}: {d:.2} ms\n", .{ i, elapsed_ms });
        times[i] = elapsed_ms;
    }
    std.mem.sort(f64, times, {}, std.sort.asc(f64));
    return times[times.len / 2];
}

fn benchmarkMetal(iterations: usize, zkey_path: []const u8, wtns_path: []const u8) !f64 {
    var warmup = try gpu.metal.proveOnGpu(zkey_path, wtns_path, .{});
    warmup.deinit();
    var times = try std.heap.c_allocator.alloc(f64, iterations);
    defer std.heap.c_allocator.free(times);
    for (0..iterations) |i| {
        const start = getTimeMs();
        var result = try gpu.metal.proveOnGpu(zkey_path, wtns_path, .{});
        result.deinit();
        const elapsed_ms = getTimeMs() - start;
        times[i] = elapsed_ms;
    }
    std.mem.sort(f64, times, {}, std.sort.asc(f64));
    return times[times.len / 2];
}

fn benchmarkMetalProfiled(zkey_path: []const u8, wtns_path: []const u8) !void {
    std.debug.print("\n=== Metal Prover Stage Breakdown ===\n", .{});
    var result = try gpu.metal.proveOnGpuProfiled(zkey_path, wtns_path, .{});
    result.deinit();
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const iterations = 3;

    // Write embedded testdata to temp files
    const zkey_path = try writeTempFile(allocator, "circuit_final.zkey", testdata.ZKEY);
    defer allocator.free(zkey_path);
    const wtns_path = try writeTempFile(allocator, "witness.wtns", testdata.WTNS);
    defer allocator.free(wtns_path);

    std.debug.print("\n=== Prover Backend Comparison ===\n", .{});
    std.debug.print("Circuit: test circuit (domain=1024, nVars=1003)\n", .{});
    std.debug.print("Iterations: {d} (plus warmup)\n\n", .{iterations});

    std.debug.print("Benchmarking CPU prover...\n", .{});
    const cpu_ms = try benchmarkCpu(iterations, zkey_path, wtns_path);

    std.debug.print("Benchmarking Metal prover...\n", .{});
    const metal_ms = try benchmarkMetal(iterations, zkey_path, wtns_path);

    std.debug.print("\n=== Results ===\n", .{});
    std.debug.print("     Backend |  Median (ms)\n", .{});
    std.debug.print("-------------+--------------\n", .{});
    std.debug.print("         CPU | {d:>12.2}\n", .{cpu_ms});
    std.debug.print("       Metal | {d:>12.2} | {d:>19.2}x vs CPU\n", .{ metal_ms, cpu_ms / metal_ms });

    // Profile Metal stages
    try benchmarkMetalProfiled(zkey_path, wtns_path);
    std.debug.print("\n", .{});
}
