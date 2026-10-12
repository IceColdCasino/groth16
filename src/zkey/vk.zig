//! Groth16 verification key, in the JSON snarkjs writes (`space: 1`).
const std = @import("std");
const curve = @import("curve.zig");
const ff = @import("ff.zig");
const pairing = @import("pairing.zig");

const Fq = ff.Fq;

const Sec = struct { off: usize, size: usize };

pub fn run(alloc: std.mem.Allocator, io: std.Io, in_path: []const u8, out_path: []const u8) !void {
    var f = try std.Io.Dir.cwd().openFile(io, in_path, .{});
    defer f.close(io);
    const size: usize = @intCast(try f.length(io));
    const buf = try alloc.alloc(u8, size);
    defer alloc.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    if (n != buf.len) return error.UnexpectedEof;
    try writeFile(alloc, io, buf, out_path);
}

pub fn writeFile(alloc: std.mem.Allocator, io: std.Io, zkey: []const u8, path: []const u8) !void {
    const text = try render(alloc, zkey);
    defer alloc.free(text);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, text, 0);
    std.debug.print("wrote {s}\n", .{path});
}

pub fn render(alloc: std.mem.Allocator, zkey: []const u8) ![]u8 {
    const secs = try scan(zkey);
    const s2 = secs[2] orelse return error.NotZkey;
    const s3 = secs[3] orelse return error.NotZkey;
    const header = zkey[s2.off .. s2.off + s2.size];
    const alpha_at = try alphaOff(header);
    const n_public = std.mem.readInt(u32, header[alpha_at - 8 ..][0..4], .little);
    const ic = zkey[s3.off .. s3.off + s3.size];
    if (ic.len < @as(usize, n_public + 1) * 64) return error.BadPoints;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\n");
    try fieldStr(alloc, &out, 1, "protocol", "groth16", true);
    try fieldStr(alloc, &out, 1, "curve", "bn128", true);
    try fieldNum(alloc, &out, 1, "nPublic", n_public, true);
    try g1Field(alloc, &out, 1, "vk_alpha_1", header[alpha_at..][0..64], true);
    try g2Field(alloc, &out, 1, "vk_beta_2", header[alpha_at + 128 ..][0..128], true);
    try g2Field(alloc, &out, 1, "vk_gamma_2", header[alpha_at + 256 ..][0..128], true);
    try g2Field(alloc, &out, 1, "vk_delta_2", header[alpha_at + 448 ..][0..128], true);

    const alpha = curve.loadG1(header[alpha_at..][0..64], 0);
    const beta = curve.loadG2(header[alpha_at + 128 ..][0..128], 0);
    const gt = pairing.pairing(alpha, beta);
    try gtField(alloc, &out, gt, true);

    try out.appendSlice(alloc, " \"IC\": [\n");
    var i: u32 = 0;
    while (i <= n_public) : (i += 1) {
        const last = i == n_public;
        try indent(alloc, &out, 2);
        try g1Value(alloc, &out, 2, ic[i * 64 ..][0..64], !last);
    }
    try out.appendSlice(alloc, " ]\n}");
    return out.toOwnedSlice(alloc);
}

fn alphaOff(sec: []const u8) !usize {
    if (sec.len < 8) return error.NotZkey;
    const n8q = std.mem.readInt(u32, sec[0..4], .little);
    var o: usize = 4 + n8q;
    if (o + 4 > sec.len) return error.NotZkey;
    const n8r = std.mem.readInt(u32, sec[o..][0..4], .little);
    o += 4 + n8r;
    if (o + 12 + 64 > sec.len) return error.NotZkey;
    return o + 12;
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
        const size: usize = @intCast(std.mem.readInt(u64, file[pos + 4 ..][0..8], .little));
        const off = pos + 12;
        if (off + size > file.len) return error.UnexpectedEof;
        if (id < secs.len and secs[id] == null) secs[id] = .{ .off = off, .size = size };
        pos = off + size;
    }
    return secs;
}

fn fieldStr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, name: []const u8, value: []const u8, comma: bool) !void {
    try indent(alloc, out, depth);
    try out.appendSlice(alloc, "\"");
    try out.appendSlice(alloc, name);
    try out.appendSlice(alloc, "\": \"");
    try out.appendSlice(alloc, value);
    try out.appendSlice(alloc, if (comma) "\",\n" else "\"\n");
}

fn fieldNum(alloc: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, name: []const u8, value: u32, comma: bool) !void {
    try indent(alloc, out, depth);
    try out.appendSlice(alloc, "\"");
    try out.appendSlice(alloc, name);
    const text = try std.fmt.allocPrint(alloc, "\": {d}", .{value});
    defer alloc.free(text);
    try out.appendSlice(alloc, text);
    try out.appendSlice(alloc, if (comma) ",\n" else "\n");
}

fn g1Field(alloc: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, name: []const u8, raw: []const u8, comma: bool) !void {
    try indent(alloc, out, depth);
    try out.appendSlice(alloc, "\"");
    try out.appendSlice(alloc, name);
    try out.appendSlice(alloc, "\": ");
    try g1Value(alloc, out, depth, raw, comma);
}

fn g2Field(alloc: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, name: []const u8, raw: []const u8, comma: bool) !void {
    try indent(alloc, out, depth);
    try out.appendSlice(alloc, "\"");
    try out.appendSlice(alloc, name);
    try out.appendSlice(alloc, "\": ");
    try g2Value(alloc, out, depth, raw, comma);
}

fn g1Value(alloc: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, raw: []const u8, comma: bool) !void {
    try out.appendSlice(alloc, "[\n");
    if (std.mem.allEqual(u8, raw, 0)) {
        try decLine(alloc, out, depth + 1, Fq.fromInt(0).toStd(), true);
        try decLine(alloc, out, depth + 1, Fq.fromInt(1).toStd(), true);
        try decLine(alloc, out, depth + 1, Fq.fromInt(0).toStd(), false);
    } else {
        const p = curve.loadG1(raw, 0);
        try decLine(alloc, out, depth + 1, p.x.toStd(), true);
        try decLine(alloc, out, depth + 1, p.y.toStd(), true);
        try decLine(alloc, out, depth + 1, Fq.fromInt(1).toStd(), false);
    }
    try indent(alloc, out, depth);
    try out.appendSlice(alloc, if (comma) "],\n" else "]\n");
}

fn g2Value(alloc: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, raw: []const u8, comma: bool) !void {
    try out.appendSlice(alloc, "[\n");
    if (std.mem.allEqual(u8, raw, 0)) {
        try fp2Line(alloc, out, depth + 1, Fq.fromInt(0).toStd(), Fq.fromInt(0).toStd(), true);
        try fp2Line(alloc, out, depth + 1, Fq.fromInt(1).toStd(), Fq.fromInt(0).toStd(), true);
        try fp2Line(alloc, out, depth + 1, Fq.fromInt(0).toStd(), Fq.fromInt(0).toStd(), false);
    } else {
        const p = curve.loadG2(raw, 0);
        try fp2Line(alloc, out, depth + 1, p.x.c0.toStd(), p.x.c1.toStd(), true);
        try fp2Line(alloc, out, depth + 1, p.y.c0.toStd(), p.y.c1.toStd(), true);
        try fp2Line(alloc, out, depth + 1, Fq.fromInt(1).toStd(), Fq.fromInt(0).toStd(), false);
    }
    try indent(alloc, out, depth);
    try out.appendSlice(alloc, if (comma) "],\n" else "]\n");
}

fn gtField(alloc: std.mem.Allocator, out: *std.ArrayList(u8), gt: pairing.Fp12, comma: bool) !void {
    try out.appendSlice(alloc, " \"vk_alphabeta_12\": [\n");
    try fp6Value(alloc, out, 2, gt.c0, true);
    try fp6Value(alloc, out, 2, gt.c1, false);
    try out.appendSlice(alloc, if (comma) " ],\n" else " ]\n");
}

fn fp6Value(alloc: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, v: pairing.Fp6, comma: bool) !void {
    try indent(alloc, out, depth);
    try out.appendSlice(alloc, "[\n");
    try fp2Line(alloc, out, depth + 1, v.a.c0.toStd(), v.a.c1.toStd(), true);
    try fp2Line(alloc, out, depth + 1, v.b.c0.toStd(), v.b.c1.toStd(), true);
    try fp2Line(alloc, out, depth + 1, v.c.c0.toStd(), v.c.c1.toStd(), false);
    try indent(alloc, out, depth);
    try out.appendSlice(alloc, if (comma) "],\n" else "]\n");
}

fn fp2Line(alloc: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, a: [4]u64, b: [4]u64, comma: bool) !void {
    try indent(alloc, out, depth);
    try out.appendSlice(alloc, "[\n");
    try decLine(alloc, out, depth + 1, a, true);
    try decLine(alloc, out, depth + 1, b, false);
    try indent(alloc, out, depth);
    try out.appendSlice(alloc, if (comma) "],\n" else "]\n");
}

fn decLine(alloc: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, limbs: [4]u64, comma: bool) !void {
    try indent(alloc, out, depth);
    try out.appendSlice(alloc, "\"");
    try appendDec(alloc, out, limbs);
    try out.appendSlice(alloc, if (comma) "\",\n" else "\"\n");
}

fn indent(alloc: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize) !void {
    try out.appendNTimes(alloc, ' ', depth);
}

fn appendDec(alloc: std.mem.Allocator, out: *std.ArrayList(u8), limbs_in: [4]u64) !void {
    var limbs = limbs_in;
    if ((limbs[0] | limbs[1] | limbs[2] | limbs[3]) == 0) {
        try out.append(alloc, '0');
        return;
    }
    var digits: [80]u8 = undefined;
    var n: usize = 0;
    while ((limbs[0] | limbs[1] | limbs[2] | limbs[3]) != 0) {
        var rem: u128 = 0;
        var i: usize = 4;
        while (i > 0) {
            i -= 1;
            const v = (rem << 64) | limbs[i];
            limbs[i] = @intCast(v / 10);
            rem = v % 10;
        }
        digits[n] = '0' + @as(u8, @intCast(rem));
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        try out.append(alloc, digits[n]);
    }
}
