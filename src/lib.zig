const std = @import("std");
const cpu = @import("cpu");
const gpu = @import("gpu");
const c = @cImport({
    @cInclude("stdio.h");
});

const PROVER_OK = 0x0;
const PROVER_ERROR = 0x1;
const PROVER_ERROR_SHORT_BUFFER = 0x2;
const PROVER_INVALID_WITNESS_LENGTH = 0x3;

var temp_file_counter = std.atomic.Value(u32).init(0);

/// Generate a unique temp file path.
fn makeTempPath(prefix: []const u8) ![]u8 {
    const pid = std.c.getpid();
    const seq = temp_file_counter.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(std.heap.c_allocator, "/tmp/{s}_{d}_{d}.bin", .{ prefix, pid, seq });
}

/// Write buffer to temporary file using C stdio.
/// Handles partial writes for very large buffers (>2GB not supported by single fwrite on some platforms).
fn writeBufferToTempFile(tmp_path: []const u8, buffer: []const u8) !void {
    const path_z = try std.heap.c_allocator.dupeZ(u8, tmp_path);
    defer std.heap.c_allocator.free(path_z);
    const file = c.fopen(path_z.ptr, "wb");
    if (file == null) return error.FileNotFound;
    defer _ = c.fclose(file);

    var total_written: usize = 0;
    while (total_written < buffer.len) {
        const remaining = buffer.len - total_written;
        const chunk_size = @min(remaining, 64 * 1024 * 1024); // 64MB chunks
        const written = c.fwrite(buffer.ptr + total_written, 1, chunk_size, file);
        if (written == 0) return error.WriteFailed;
        total_written += written;
    }
}

/// Run prover with auto-selected backend (GPU if available, else CPU).
fn runProverLibrary(zkey_path: []const u8, witness_path: []const u8) !cpu.ProofResult {
    if (@import("builtin").os.tag == .macos) {
        return gpu.metal.proveOnGpuProfiled(zkey_path, witness_path, .{});
    }
    return error.GpuOnly;
}

export fn groth16_prover_zkey_file(
    zkey_fname: [*c]const u8,
    wtns_buffer: *const anyopaque,
    wtns_size: c_ulonglong,
    proof_buffer: [*c]u8,
    proof_size: *c_ulonglong,
    public_buffer: [*c]u8,
    public_size: *c_ulonglong,
    error_msg: [*c]u8,
    error_msg_maxsize: c_ulonglong,
) c_int {
    const zkey_path = std.mem.span(zkey_fname);
    const zkey_data = cpu.readFileToBuffer(zkey_path, std.heap.c_allocator) catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Failed to read zkey file: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };
    defer std.heap.c_allocator.free(zkey_data);
    return groth16_prover(
        zkey_data.ptr,
        zkey_data.len,
        wtns_buffer,
        wtns_size,
        proof_buffer,
        proof_size,
        public_buffer,
        public_size,
        error_msg,
        error_msg_maxsize,
    );
}

export fn groth16_prover(
    zkey_buffer: *const anyopaque,
    zkey_size: c_ulonglong,
    wtns_buffer: *const anyopaque,
    wtns_size: c_ulonglong,
    proof_buffer: [*c]u8,
    proof_size: *c_ulonglong,
    public_buffer: [*c]u8,
    public_size: *c_ulonglong,
    error_msg: [*c]u8,
    error_msg_maxsize: c_ulonglong,
) c_int {
    var prover: *anyopaque = undefined;
    var err = groth16_prover_create(&prover, zkey_buffer, zkey_size, error_msg, error_msg_maxsize);
    if (err != PROVER_OK) return err;
    err = groth16_prover_prove(
        prover,
        wtns_buffer,
        wtns_size,
        proof_buffer,
        proof_size,
        public_buffer,
        public_size,
        error_msg,
        error_msg_maxsize,
    );
    groth16_prover_destroy(prover);
    return err;
}

export fn groth16_verify(
    vk_buffer: *const anyopaque,
    vk_size: c_ulonglong,
    proof_buffer: *const anyopaque,
    proof_size: c_ulonglong,
    public_buffer: *const anyopaque,
    public_size: c_ulonglong,
    error_msg: [*c]u8,
    error_msg_maxsize: c_ulonglong,
) c_int {
    const vk_slice = @as([*]const u8, @ptrCast(vk_buffer))[0..vk_size];
    const proof_slice = @as([*]const u8, @ptrCast(proof_buffer))[0..proof_size];
    const public_slice = @as([*]const u8, @ptrCast(public_buffer))[0..public_size];

    const result = cpu.verify(vk_slice, proof_slice, public_slice) catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Verification failed: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };

    if (result) return PROVER_OK else return PROVER_ERROR;
}

export fn groth16_proof_size(proof_size: *c_ulonglong) void {
    proof_size.* = 810;
}

export fn groth16_public_size_for_zkey_buf(
    zkey_buffer: *const anyopaque,
    zkey_size: c_ulonglong,
    public_size: *c_ulonglong,
    error_msg: [*c]u8,
    error_msg_maxsize: c_ulonglong,
) c_int {
    const zkey_slice = @as([*]const u8, @ptrCast(zkey_buffer))[0..zkey_size];
    var zkey = cpu.parser.parseZkey(std.heap.c_allocator, zkey_slice) catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Failed to parse zkey: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };
    defer zkey.deinit(std.heap.c_allocator);
    public_size.* = zkey.header.nPublic * 82 + 4;
    return PROVER_OK;
}

export fn groth16_public_size_for_zkey_file(
    zkey_fname: [*c]const u8,
    public_size: *c_ulonglong,
    error_msg: [*c]u8,
    error_msg_maxsize: c_ulonglong,
) c_int {
    const zkey_path = std.mem.span(zkey_fname);
    const zkey_data = cpu.readFileToBuffer(zkey_path, std.heap.c_allocator) catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Failed to read zkey file: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };
    defer std.heap.c_allocator.free(zkey_data);
    return groth16_public_size_for_zkey_buf(zkey_data.ptr, zkey_data.len, public_size, error_msg, error_msg_maxsize);
}

const Groth16ProverObj = struct {
    zkey_data: []const u8,
    nVars: u32,
    nPublic: u32,
    domainSize: u32,
    n8: u32,
    n8r: u32,
};

export fn groth16_prover_create(
    prover_object: ?**anyopaque,
    zkey_buffer: ?*const anyopaque,
    zkey_size: c_ulonglong,
    error_msg: [*c]u8,
    error_msg_maxsize: c_ulonglong,
) c_int {
    if (prover_object == null) {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Null prover object pointer", .{}) catch {};
        }
        return PROVER_ERROR;
    }
    if (zkey_buffer == null) {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Null zkey buffer", .{}) catch {};
        }
        return PROVER_ERROR;
    }

    const zkey_slice = @as([*]const u8, @ptrCast(zkey_buffer))[0..zkey_size];
    var zkey = cpu.parser.parseZkey(std.heap.c_allocator, zkey_slice) catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Failed to parse zkey: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };
    defer zkey.deinit(std.heap.c_allocator);

    const obj = std.heap.c_allocator.create(Groth16ProverObj) catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Out of memory: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };

    obj.* = .{
        .zkey_data = std.heap.c_allocator.dupe(u8, zkey_slice) catch |err| {
            std.heap.c_allocator.destroy(obj);
            if (error_msg_maxsize > 0) {
                _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Out of memory: {}", .{err}) catch {};
            }
            return PROVER_ERROR;
        },
        .nVars = zkey.header.nVars,
        .nPublic = zkey.header.nPublic,
        .domainSize = zkey.header.domainSize,
        .n8 = zkey.header.n8,
        .n8r = zkey.header.n8r,
    };
    prover_object.?.* = obj;
    return PROVER_OK;
}

export fn groth16_prover_create_zkey_file(
    prover_object: **anyopaque,
    zkey_file_path: [*c]const u8,
    error_msg: [*c]u8,
    error_msg_maxsize: c_ulonglong,
) c_int {
    const zkey_path = std.mem.span(zkey_file_path);
    const zkey_data = cpu.readFileToBuffer(zkey_path, std.heap.c_allocator) catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Failed to read zkey file: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };
    defer std.heap.c_allocator.free(zkey_data);
    return groth16_prover_create(prover_object, zkey_data.ptr, zkey_data.len, error_msg, error_msg_maxsize);
}

export fn groth16_prover_destroy(prover_object: ?*anyopaque) void {
    if (prover_object == null) return;
    const obj = @as(*Groth16ProverObj, @ptrCast(@alignCast(prover_object.?)));
    std.heap.c_allocator.free(obj.zkey_data);
    std.heap.c_allocator.destroy(obj);
}

export fn groth16_prover_prove(
    prover_object: *anyopaque,
    wtns_buffer: *const anyopaque,
    wtns_size: c_ulonglong,
    proof_buffer: [*c]u8,
    proof_size: *c_ulonglong,
    public_buffer: [*c]u8,
    public_size: *c_ulonglong,
    error_msg: [*c]u8,
    error_msg_maxsize: c_ulonglong,
) c_int {
    if (@intFromPtr(prover_object) == 0) {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Null prover object", .{}) catch {};
        }
        return PROVER_ERROR;
    }
    if (@intFromPtr(wtns_buffer) == 0) {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Null witness buffer", .{}) catch {};
        }
        return PROVER_ERROR;
    }
    if (@intFromPtr(proof_buffer) == 0 or @intFromPtr(proof_size) == 0) {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Null proof buffer or size", .{}) catch {};
        }
        return PROVER_ERROR;
    }
    if (@intFromPtr(public_buffer) == 0 or @intFromPtr(public_size) == 0) {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Null public buffer or size", .{}) catch {};
        }
        return PROVER_ERROR;
    }

    const obj = @as(*Groth16ProverObj, @ptrCast(@alignCast(prover_object)));
    const wtns_slice = @as([*]const u8, @ptrCast(wtns_buffer))[0..wtns_size];

    // Validate witness length early
    const fr_bytes = @sizeOf(cpu.field.FrElement);
    if (wtns_size < obj.nVars * fr_bytes) {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Invalid witness length. Circuit: {d}, witness: {d}", .{obj.nVars, wtns_size / fr_bytes}) catch {};
        }
        return PROVER_INVALID_WITNESS_LENGTH;
    }

    // Write witness to unique temp file
    const witness_tmp = makeTempPath("rs_wtns") catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Failed to create temp path: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };
    defer {
        _ = c.remove(witness_tmp.ptr);
        std.heap.c_allocator.free(witness_tmp);
    }
    writeBufferToTempFile(witness_tmp, wtns_slice) catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Failed to write witness temp file: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };

    // Write zkey to unique temp file (proveOnGpu needs file path)
    const zkey_tmp = makeTempPath("rs_zkey") catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Failed to create temp path: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };
    defer {
        _ = c.remove(zkey_tmp.ptr);
        std.heap.c_allocator.free(zkey_tmp);
    }
    writeBufferToTempFile(zkey_tmp, obj.zkey_data) catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Failed to write zkey temp file: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };

    var result = runProverLibrary(zkey_tmp, witness_tmp) catch |err| {
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Proving failed: {}", .{err}) catch {};
        }
        return PROVER_ERROR;
    };
    defer result.deinit();

    const proof = result.proof;
    const public_signals = result.public_signals;

    if (proof.len + 1 > proof_size.*) {
        proof_size.* = proof.len + 1;
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Proof buffer too small, need {d} bytes", .{proof.len + 1}) catch {};
        }
        return PROVER_ERROR_SHORT_BUFFER;
    }
    @memcpy(proof_buffer[0..proof.len], proof);
    proof_buffer[proof.len] = 0;
    proof_size.* = proof.len;

    if (public_signals.len + 1 > public_size.*) {
        public_size.* = public_signals.len + 1;
        if (error_msg_maxsize > 0) {
            _ = std.fmt.bufPrint(error_msg[0..error_msg_maxsize], "Public buffer too small, need {d} bytes", .{public_signals.len + 1}) catch {};
        }
        return PROVER_ERROR_SHORT_BUFFER;
    }
    @memcpy(public_buffer[0..public_signals.len], public_signals);
    public_buffer[public_signals.len] = 0;
    public_size.* = public_signals.len;

    return PROVER_OK;
}
