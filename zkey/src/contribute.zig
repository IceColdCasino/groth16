//! Groth16 phase-2 contribution (`snarkjs zkey contribute`).
//!
//! The toxic waste is three field elements drawn from the operating system
//! and reduced into Fr by rejection sampling. `g2_sp` is a random multiple of
//! the G2 generator. Sections 8 and 9 are scaled by `inv(delta)` on the GPU
//! and the CPU together.
const std = @import("std");
const batch = @import("batch.zig");
const curve = @import("curve.zig");
const ff = @import("ff.zig");

const Fq = ff.Fq;
const Fr = ff.Fr;
const Blake = std.crypto.hash.blake2.Blake2b512;

extern "c" fn getentropy(buf: [*]u8, buflen: usize) c_int;

const Sec = struct { off: usize, size: usize };

pub fn run(alloc: std.mem.Allocator, io: std.Io, in_path: []const u8, out_path: []const u8, name_in: []const u8) !void {
    var file = try readFile(alloc, io, in_path);
    defer alloc.free(file);
    try apply(alloc, io, &file, name_in);
    var out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer out_file.close(io);
    try out_file.writePositionalAll(io, file, 0);
    std.debug.print("wrote {s} ({d} bytes)\n", .{ out_path, file.len });
}

/// Contribute into `file` and keep the result there. The buffer grows by one contribution record.
pub fn apply(alloc: std.mem.Allocator, io: std.Io, file: *[]u8, name_in: []const u8) !void {
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const secs = try scan(file.*);

    const s1 = secs[1] orelse return error.NotZkey;
    const s2 = secs[2] orelse return error.NotZkey;
    const s8 = secs[8] orelse return error.NotZkey;
    const s9 = secs[9] orelse return error.NotZkey;
    const s10 = secs[10] orelse return error.NotZkey;
    if (slice(file.*, s1).len < 4) return error.NotZkey;
    if (std.mem.readInt(u32, slice(file.*, s1)[0..4], .little) != 1) return error.NotGroth16;

    var drawn: usize = 0;
    const delta = try sampleFr(&drawn);
    const s1_scalar = try sampleFr(&drawn);
    const s2_scalar = try sampleFr(&drawn);
    std.debug.print("drew {d} bytes from the operating system\n", .{drawn});

    const inv_delta = Fr.fromStd(delta).inv().toStd();

    const d1 = try delta1Off(slice(file.*, s2));
    scaleG1(file.*[s2.off + d1 ..][0..64], delta);
    scaleG2(file.*[s2.off + d1 + 64 ..][0..128], delta);

    var g1_s: [64]u8 = undefined;
    var g1_sx: [64]u8 = undefined;
    var g2_spx: [128]u8 = undefined;
    var delta_after: [64]u8 = undefined;
    storeG1(&g1_s, curve.scaleG1(curve.g1Generator(), s1_scalar));
    storeG1(&g1_sx, curve.scaleG1(curve.loadG1(&g1_s, 0), delta));
    storeG2(&g2_spx, curve.scaleG2(curve.scaleG2(curve.g2Generator(), s2_scalar).toAffine(), delta));
    @memcpy(&delta_after, file.*[s2.off + d1 ..][0..64]);

    const old10 = slice(file.*, s10);
    if (old10.len < 68) return error.BadContribution;
    const n_prev = std.mem.readInt(u32, old10[64..68], .little);
    var transcript = Blake.init(.{});
    transcript.update(old10[0..64]);
    const prev_end = try hashPrev(&transcript, old10, n_prev);
    hashLem(&transcript, &g1_s, 64);
    hashLem(&transcript, &g1_sx, 64);
    var transcript_bytes: [64]u8 = undefined;
    transcript.final(&transcript_bytes);

    const name = name_in[0..@min(name_in.len, 64)];
    const param_len: u32 = @intCast(2 + name.len);
    const new_contrib = 64 * 3 + 128 + 64 + 4 + 4 + param_len;
    const sec10 = try alloc.alloc(u8, prev_end + new_contrib);
    defer alloc.free(sec10);
    @memcpy(sec10[0..64], old10[0..64]);
    std.mem.writeInt(u32, sec10[64..68], n_prev + 1, .little);
    @memcpy(sec10[68..prev_end], old10[68..prev_end]);
    var w = prev_end;
    @memcpy(sec10[w..][0..64], &delta_after);
    w += 64;
    @memcpy(sec10[w..][0..64], &g1_s);
    w += 64;
    @memcpy(sec10[w..][0..64], &g1_sx);
    w += 64;
    @memcpy(sec10[w..][0..128], &g2_spx);
    w += 128;
    @memcpy(sec10[w..][0..64], &transcript_bytes);
    w += 64;
    std.mem.writeInt(u32, sec10[w..][0..4], 0, .little);
    w += 4;
    std.mem.writeInt(u32, sec10[w..][0..4], param_len, .little);
    w += 4;
    sec10[w] = 1;
    sec10[w + 1] = @intCast(name.len);
    @memcpy(sec10[w + 2 ..][0..name.len], name);

    if (s8.size % 64 != 0 or s9.size % 64 != 0) return error.BadPoints;
    try scaleSection(alloc, io, file.*, s8, inv_delta);
    try scaleSection(alloc, io, file.*, s9, inv_delta);
    if (s10.off + s10.size != file.*.len) return error.BadContribution;
    const new_len = s10.off + sec10.len;
    file.* = try alloc.realloc(file.*, new_len);
    std.mem.writeInt(u64, file.*[s10.off - 8 ..][0..8], @intCast(sec10.len), .little);
    @memcpy(file.*[s10.off..][0..sec10.len], sec10);

    var contrib_hash = Blake.init(.{});
    hashLem(&contrib_hash, &delta_after, 64);
    hashLem(&contrib_hash, &g1_s, 64);
    hashLem(&contrib_hash, &g1_sx, 64);
    hashLem(&contrib_hash, &g2_spx, 128);
    contrib_hash.update(&transcript_bytes);
    var digest: [64]u8 = undefined;
    contrib_hash.final(&digest);
    std.debug.print("contribution hash {x}\n", .{digest});
    const ms = elapsedMs(started.durationTo(.now(io, .awake)).raw.nanoseconds);
    std.debug.print("contributed in {d} ms\n", .{ms});
}

fn scaleSection(alloc: std.mem.Allocator, io: std.Io, file: []u8, sec: Sec, scalar: [4]u64) !void {
    const tmp = try alloc.alloc(u8, sec.size);
    defer alloc.free(tmp);
    try batch.mulSame(alloc, io, file[sec.off .. sec.off + sec.size], scalar, tmp);
    @memcpy(file[sec.off .. sec.off + sec.size], tmp);
}

fn hashPrev(hasher: *Blake, sec: []const u8, n: u32) !usize {
    var p: usize = 68;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (p + 384 + 8 > sec.len) return error.BadContribution;
        hashLem(hasher, sec[p..][0..64], 64);
        hashLem(hasher, sec[p + 64 ..][0..64], 64);
        hashLem(hasher, sec[p + 128 ..][0..64], 64);
        hashLem(hasher, sec[p + 192 ..][0..128], 128);
        hasher.update(sec[p + 320 ..][0..64]);
        p += 384;
        p += 4;
        const param_len = std.mem.readInt(u32, sec[p..][0..4], .little);
        p += 4;
        if (p + param_len > sec.len) return error.BadContribution;
        p += param_len;
    }
    return p;
}

fn delta1Off(sec: []const u8) !usize {
    if (sec.len < 8) return error.NotZkey;
    const n8q = std.mem.readInt(u32, sec[0..4], .little);
    var o: usize = 4 + n8q;
    if (o + 4 > sec.len) return error.NotZkey;
    const n8r = std.mem.readInt(u32, sec[o..][0..4], .little);
    o += 4 + n8r + 12 + 64 + 64 + 128 + 128;
    if (o + 64 + 128 > sec.len) return error.NotZkey;
    return o;
}

fn scaleG1(dst: []u8, k: [4]u64) void {
    storeG1(dst, curve.scaleG1(curve.loadG1(dst, 0), k));
}

fn scaleG2(dst: []u8, k: [4]u64) void {
    var one = [_]curve.G2.Jac{curve.scaleG2(curve.loadG2(dst, 0), k)};
    curve.G2.storeJacMany(&one, dst);
}

fn storeG1(dst: []u8, p: curve.G1.Jac) void {
    var one = [_]curve.G1.Jac{p};
    curve.G1.storeJacMany(&one, dst);
}

fn storeG2(dst: []u8, p: curve.G2.Jac) void {
    var one = [_]curve.G2.Jac{p};
    curve.G2.storeJacMany(&one, dst);
}

fn sampleFr(drawn: *usize) ![4]u64 {
    var pool: [256]u8 = undefined;
    var used: usize = 256;
    while (true) {
        if (used + 32 > pool.len) {
            if (getentropy(&pool, pool.len) != 0) return error.Entropy;
            drawn.* += pool.len;
            used = 0;
        }
        const k = ff.loadLimbs(pool[used..][0..32]);
        used += 32;
        if (ff.gte(k, Fr.mod_limbs)) continue;
        if ((k[0] | k[1] | k[2] | k[3]) == 0) continue;
        return k;
    }
}

fn hashLem(hasher: *Blake, lem: []const u8, point_len: usize) void {
    var buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i < lem.len) : (i += point_len) {
        var o: usize = 0;
        while (o < point_len) : (o += 32) {
            const f = Fq{ .limbs = ff.loadLimbs(lem[i + o ..][0..32]) };
            storeStdBe(f.toStd(), buf[o..][0..32]);
        }
        if (point_len == 128) {
            var k: usize = 0;
            while (k < point_len) : (k += 64) {
                var tmp: [32]u8 = undefined;
                @memcpy(&tmp, buf[k..][0..32]);
                @memcpy(buf[k..][0..32], buf[k + 32 ..][0..32]);
                @memcpy(buf[k + 32 ..][0..32], &tmp);
            }
        }
        hasher.update(buf[0..point_len]);
    }
}

fn storeStdBe(limbs: [4]u64, dst: []u8) void {
    inline for (0..4) |i| {
        std.mem.writeInt(u64, dst[(3 - i) * 8 ..][0..8], limbs[i], .big);
    }
}

fn scan(file: []const u8) ![32]?Sec {
    if (file.len < 12 or !std.mem.eql(u8, file[0..4], "zkey")) return error.BadMagic;
    const nsec = std.mem.readInt(u32, file[8..12], .little);
    var secs: [32]?Sec = @splat(null);
    var pos: usize = 12;
    var i: u32 = 0;
    while (i < nsec) : (i += 1) {
        if (pos + 12 > file.len) return error.UnexpectedEof;
        const id = std.mem.readInt(u32, file[pos..][0..4], .little);
        const size64 = std.mem.readInt(u64, file[pos + 4 ..][0..8], .little);
        const size: usize = @intCast(size64);
        const off = pos + 12;
        if (off + size > file.len) return error.UnexpectedEof;
        if (id < secs.len and secs[id] == null) secs[id] = .{ .off = off, .size = size };
        pos = off + size;
    }
    return secs;
}

fn slice(file: []const u8, sec: Sec) []const u8 {
    return file[sec.off .. sec.off + sec.size];
}

fn readFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const size: usize = @intCast(try f.length(io));
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    if (n != buf.len) return error.UnexpectedEof;
    return buf;
}

fn elapsedMs(ns: i96) u64 {
    if (ns <= 0) return 0;
    return @intCast(@divTrunc(ns, 1_000_000));
}

