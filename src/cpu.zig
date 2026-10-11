const std = @import("std");

// Re-export shared submodules so the GPU module can access them without
// cross-module file import issues.
pub const prover = @import("prover.zig");
pub const verifier = @import("verifier.zig");
pub const parser = @import("parser.zig");
pub const field = @import("field.zig");
pub const curve = @import("curve.zig");
pub const fft = @import("fft.zig");
pub const msm = @import("msm.zig");
pub const json = @import("json.zig");
pub const random = @import("random.zig");
pub const pairing = @import("pairing.zig");
pub const qap = @import("gpu/qap.zig");
pub const assembler = @import("gpu/assembler.zig");
pub const zkey_cache = @import("zkey_cache.zig");

test {
    // Force inclusion of tests from all re-exported modules.
    _ = prover;
    _ = verifier;
    _ = parser;
    _ = field;
    _ = curve;
    _ = fft;
    _ = msm;
    _ = json;
    _ = random;
    _ = pairing;
    _ = qap;
    _ = assembler;
}

const c = @cImport({
    @cInclude("stdio.h");
});

pub const ProverError = error{
    ProverFailed,
    ShortBuffer,
    InvalidWitnessLength,
    OutOfMemory,
};

pub const ProofResult = struct {
    proof: []const u8,
    public_signals: []const u8,

    pub fn deinit(self: *ProofResult) void {
        std.heap.c_allocator.free(self.proof);
        std.heap.c_allocator.free(self.public_signals);
    }
};

/// Read entire file into memory using C stdio
pub fn readFileToBuffer(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const file = c.fopen(path_z.ptr, "rb");
    if (file == null) return error.ProverFailed;
    defer _ = c.fclose(file);

    _ = c.fseek(file, 0, c.SEEK_END);
    const size = c.ftell(file);
    _ = c.fseek(file, 0, c.SEEK_SET);

    const buf = try allocator.alloc(u8, @intCast(size));
    const read_size = c.fread(buf.ptr, 1, @intCast(size), file);
    if (read_size != @as(usize, @intCast(size))) {
        allocator.free(buf);
        return error.ProverFailed;
    }

    return buf;
}

/// CPU prover using pure-Zig implementation
pub fn prove(
    zkey_path: []const u8,
    witness_path: []const u8,
) ProverError!ProofResult {
    const zkey_data = readFileToBuffer(zkey_path, std.heap.c_allocator) catch {
        return error.ProverFailed;
    };
    defer std.heap.c_allocator.free(zkey_data);

    const witness_data = readFileToBuffer(witness_path, std.heap.c_allocator) catch {
        return error.ProverFailed;
    };
    defer std.heap.c_allocator.free(witness_data);

    var result = prover.prove(std.heap.c_allocator, zkey_data, witness_data, .{}) catch {
        return error.ProverFailed;
    };
    defer result.deinit(std.heap.c_allocator);

    const proof = std.heap.c_allocator.dupe(u8, result.proof_json) catch return error.OutOfMemory;
    const public = std.heap.c_allocator.dupe(u8, result.public_json) catch return error.OutOfMemory;

    return ProofResult{
        .proof = proof,
        .public_signals = public,
    };
}

/// Verify a proof
pub fn verify(
    vk_json: []const u8,
    proof_json: []const u8,
    public_json: []const u8,
) !bool {
    return verifier.verify(std.heap.c_allocator, vk_json, proof_json, public_json);
}
