const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("sys/time.h");
});

const usage =
    \\Usage: prover <zkey_file> <witness_file> [output_proof.json] [output_public.json]
    \\
    \\Options:
    \\  --cpu          Use CPU backend (rapidsnark)
    \\  --metal        Use Metal GPU backend
    \\  --gpu          Auto-select best GPU (Metal on macOS)
    \\  -V, --verbose  Show timing information
    \\  -h, --help     Show this help message
    \\
;

fn writeFile(path: []const u8, data: []const u8) !void {
    const path_z = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(path_z);
    const file = c.fopen(path_z.ptr, "w");
    if (file == null) return error.FileNotFound;
    defer _ = c.fclose(file);
    _ = c.fwrite(data.ptr, 1, data.len, file);
}

/// Get current time in milliseconds (matches benchmarks/bench.zig)
fn getTimeMs() f64 {
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @as(f64, @floatFromInt(tv.tv_sec)) * 1000.0 + @as(f64, @floatFromInt(tv.tv_usec)) / 1000.0;
}

/// Backend selection mode
const BackendMode = enum {
    auto,
    cpu,
    metal,
    gpu,
};

/// Run prover with selected backend. Dispatches to CPU or GPU and returns
/// proof and public signals. GPU errors are returned so the caller can
/// decide whether to fall back to CPU.
fn runProver(
    backend: BackendMode,
    zkey_path: []const u8,
    witness_path: []const u8,
) !cpu.ProofResult {
    switch (backend) {
        .cpu => return cpu.prove(zkey_path, witness_path),
        .auto, .metal => {
            if (@import("builtin").os.tag != .macos) {
                return error.BackendNotAvailable;
            }
            // Run full GPU proving pipeline via Metal
            return gpu.metal.proveOnGpu(zkey_path, witness_path, .{});
        },
        .gpu => {
            // GPU backend - currently Metal only
            if (@import("builtin").os.tag == .macos) {
                return runProver(.metal, zkey_path, witness_path);
            } else {
                return error.BackendNotAvailable;
            }
        },
    }
}

pub fn main(init: std.process.Init) !u8 {
    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arg_iter.deinit();

    // Skip program name
    _ = arg_iter.next();

    var zkey_path: ?[]const u8 = null;
    var witness_path: ?[]const u8 = null;
    var proof_output: []const u8 = "proof.json";
    var public_output: []const u8 = "public.json";
    var verbose = false;
    var backend: BackendMode = .auto;
    var positional_count: u32 = 0;

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return 0;
        } else if (std.mem.eql(u8, arg, "--cpu")) {
            backend = .cpu;
        } else if (std.mem.eql(u8, arg, "--metal")) {
            backend = .metal;
        } else if (std.mem.eql(u8, arg, "--gpu")) {
            backend = .gpu;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else {
            positional_count += 1;
            switch (positional_count) {
                1 => zkey_path = arg,
                2 => witness_path = arg,
                3 => proof_output = arg,
                4 => public_output = arg,
                else => {},
            }
        }
    }

    if (zkey_path == null or witness_path == null) {
        return 1;
    }

    if (verbose) {
    }

    // Resolve auto and gpu backends
    var resolved_backend = backend;
    if (backend == .gpu) {
        resolved_backend = if (@import("builtin").os.tag == .macos) .metal else .cpu;
        if (verbose) {
        }
    }

    // Run prover with optional timing
    const start_time = if (verbose) getTimeMs() else 0;

    var result = blk: {
        break :blk runProver(resolved_backend, zkey_path.?, witness_path.?) catch |err| {
            const is_gpu_err = err == error.GpuProveNotImplemented or
                err == error.BackendNotAvailable or
                err == error.NoMetalDevice or
                err == error.NoCommandQueue or
                err == error.ShaderCompileFailed or
                err == error.FunctionNotFound or
                err == error.PipelineCreationFailed or
                err == error.BufferCreationFailed or
                err == error.CommandBufferFailed or
                err == error.EncoderFailed or
                err == error.ProverFailed;

            if (is_gpu_err) {
                if (resolved_backend != .cpu) {
                }
                break :blk try cpu.prove(zkey_path.?, witness_path.?);
            } else {
                return err;
            }
        };
    };
    defer result.deinit();

    if (verbose) {
        std.debug.print("prove {d:.1} ms\n", .{getTimeMs() - start_time});
    }

    // Write outputs
    try writeFile(proof_output, result.proof);
    try writeFile(public_output, result.public_signals);

    return 0;
}
