const std = @import("std");
const gpu = @import("gpu");
const c = @cImport({
    @cInclude("sys/time.h");
});

fn getTimeMs() f64 {
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @as(f64, @floatFromInt(tv.tv_sec)) * 1000.0 + @as(f64, @floatFromInt(tv.tv_usec)) / 1000.0;
}

fn generateRandomScalars(allocator: std.mem.Allocator, n: usize) ![]u8 {
    const scalars = try allocator.alloc(u8, n * 32);
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    for (scalars) |*s| {
        s.* = rand.int(u8);
    }
    return scalars;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const sizes = &[_]usize{ 1_000, 10_000, 50_000, 100_000, 500_000 };
    const iterations = 20;

    std.debug.print("\n=== preprocessSignedWindows SIMD benchmark ===\n", .{});
    std.debug.print("{s:>10} {s:>12} {s:>15} {s:>15}\n", .{ "n_points", "iterations", "total_ms", "per_iter_ms" });

    for (sizes) |n| {
        const scalars = try generateRandomScalars(allocator, n);
        defer allocator.free(scalars);

        // Warmup
        const warmup = try gpu.preprocessSignedWindows(allocator, scalars, 8);
        allocator.free(warmup);

        const t0 = getTimeMs();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const result = try gpu.preprocessSignedWindows(allocator, scalars, 8);
            allocator.free(result);
        }
        const total_ms = getTimeMs() - t0;
        const per_iter_ms = total_ms / @as(f64, @floatFromInt(iterations));

        std.debug.print("{d:>10} {d:>12} {d:>15.3} {d:>15.3}\n", .{ n, iterations, total_ms, per_iter_ms });
    }
}
