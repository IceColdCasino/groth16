//! `zkey <circuit.r1cs> <ceremony.ptau> <out.zkey> [verification_key.json] [name]`
//! `zkey setup <circuit.r1cs> <ceremony.ptau> <out.zkey>`
//! `zkey contribute <in.zkey> <out.zkey> [name]`
//! `zkey vk <in.zkey> <verification_key.json>`
//! `zkey prove <libgroth16.dylib> <zkey> <wtns> <verification_key.json>`
//! `zkey lib`
const std = @import("std");
const contribute = @import("contribute.zig");
const setup = @import("setup.zig");
const vk = @import("vk.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    var argv_buf: [8][:0]const u8 = undefined;
    var argc: usize = 0;
    while (it.next()) |arg| {
        if (argc >= argv_buf.len) return error.Usage;
        argv_buf[argc] = arg;
        argc += 1;
    }
    const args = argv_buf[0..argc];
    if (args.len == 2 and std.mem.eql(u8, args[1], "lib")) {
        try printLib(init.io);
        return;
    }
    if (args.len == 6 and std.mem.eql(u8, args[1], "prove")) {
        try prove(alloc, init.io, args[2], args[3], args[4], args[5]);
        return;
    }
    if (args.len >= 4 and std.mem.eql(u8, args[1], "contribute")) {
        const name: []const u8 = if (args.len >= 5) args[4] else "zig";
        try contribute.run(alloc, init.io, args[2], args[3], name);
        return;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "vk")) {
        try vk.run(alloc, init.io, args[2], args[3]);
        return;
    }
    if (args.len == 5 and std.mem.eql(u8, args[1], "setup")) {
        try setup.run(alloc, init.io, args[2], args[3], args[4]);
        return;
    }
    if (args.len < 4 or args.len > 6) {
        usage(args[0]);
        return error.Usage;
    }
    const vk_path: ?[]const u8 = if (args.len >= 5 and std.mem.endsWith(u8, args[4], ".json")) args[4] else null;
    const name: []const u8 = if (vk_path != null and args.len == 6) args[5] else if (vk_path == null and args.len == 5) args[4] else "zig";
    var zkey = try setup.build(alloc, init.io, args[1], args[2]);
    defer alloc.free(zkey);
    try contribute.apply(alloc, init.io, &zkey, name);
    var out_file = try std.Io.Dir.cwd().createFile(init.io, args[3], .{ .truncate = true });
    defer out_file.close(init.io);
    const write_start = std.Io.Clock.Timestamp.now(init.io, .awake);
    try out_file.writePositionalAll(init.io, zkey, 0);
    const ns = write_start.durationTo(.now(init.io, .awake)).raw.nanoseconds;
    const ms: u64 = if (ns <= 0) 0 else @intCast(@divTrunc(ns, 1_000_000));
    std.debug.print("wrote {s} ({d} bytes) in {d} ms\n", .{ args[3], zkey.len, ms });
    if (vk_path) |path| try vk.writeFile(alloc, init.io, zkey, path);
}

fn usage(argv0: []const u8) void {
    std.debug.print("usage: {s} <circuit.r1cs> <ceremony.ptau> <out.zkey> [verification_key.json] [name]\n", .{argv0});
    std.debug.print("       {s} setup <circuit.r1cs> <ceremony.ptau> <out.zkey>\n", .{argv0});
    std.debug.print("       {s} contribute <in.zkey> <out.zkey> [name]\n", .{argv0});
    std.debug.print("       {s} vk <in.zkey> <verification_key.json>\n", .{argv0});
    std.debug.print("       {s} prove <libgroth16.dylib> <out.zkey> <witness.wtns> <vk.json>\n", .{argv0});
    std.debug.print("       {s} lib\n", .{argv0});
}

fn printLib(io: std.Io) !void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &exe_buf) catch return error.Usage;
    const exe = exe_buf[0..n];
    const slash = std.mem.lastIndexOfScalar(u8, exe, '/') orelse return error.Usage;
    const bin_dir = exe[0..slash];
    const prefix = if (bin_dir.len >= 4 and std.mem.endsWith(u8, bin_dir, "/bin"))
        bin_dir[0 .. bin_dir.len - 4]
    else
        bin_dir;

    var lib_buf: [std.fs.max_path_bytes]u8 = undefined;
    var inc_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lib_path = joinZ(&lib_buf, prefix, "/lib/libgroth16.dylib") orelse return error.Usage;
    const include_dir = joinZ(&inc_buf, prefix, "/include") orelse return error.Usage;

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const shown = if (std.c.realpath(lib_path.ptr, &real_buf)) |resolved|
        std.mem.span(resolved)
    else
        lib_path;

    var stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, shown);
    try stdout.writeStreamingAll(io, "\n");

    const lib_dir = std.fs.path.dirname(shown) orelse prefix;
    std.debug.print("-L{s} -lgroth16 -I{s}\n", .{ lib_dir, include_dir });
}

fn joinZ(buf: []u8, a: []const u8, b: []const u8) ?[:0]u8 {
    if (a.len + b.len + 1 > buf.len) return null;
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    buf[a.len + b.len] = 0;
    return buf[0 .. a.len + b.len :0];
}

const CreateBuf = *const fn (*?*anyopaque, [*]const u8, c_ulonglong, [*]u8, c_ulonglong) callconv(.c) c_int;
const ProveFn = *const fn (*anyopaque, [*]const u8, c_ulonglong, [*]u8, *c_ulonglong, [*]u8, *c_ulonglong, [*]u8, c_ulonglong) callconv(.c) c_int;
const DestroyFn = *const fn (?*anyopaque) callconv(.c) void;
const PublicSizeFn = *const fn ([*]const u8, c_ulonglong, *c_ulonglong, [*]u8, c_ulonglong) callconv(.c) c_int;
const ProofSizeFn = *const fn (*c_ulonglong) callconv(.c) void;
const VerifyFn = *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*]u8, c_ulong) callconv(.c) c_int;

fn prove(alloc: std.mem.Allocator, io: std.Io, dylib: [:0]const u8, zkey: [:0]const u8, wtns_path: []const u8, vk_path: []const u8) !void {
    var lib = try std.DynLib.open(dylib);
    defer lib.close();
    const create = lib.lookup(CreateBuf, "groth16_prover_create") orelse return error.MissingSymbol;
    const prove_fn = lib.lookup(ProveFn, "groth16_prover_prove") orelse return error.MissingSymbol;
    const destroy = lib.lookup(DestroyFn, "groth16_prover_destroy") orelse return error.MissingSymbol;
    const public_size = lib.lookup(PublicSizeFn, "groth16_public_size_for_zkey_buf") orelse return error.MissingSymbol;
    const proof_size_fn = lib.lookup(ProofSizeFn, "groth16_proof_size") orelse return error.MissingSymbol;
    const verify = lib.lookup(VerifyFn, "groth16_verify") orelse return error.MissingSymbol;

    const zkey_bytes = try readAll(alloc, io, zkey);
    const zkey_c = mallocCopy(zkey_bytes) orelse return error.OutOfMemory;
    alloc.free(zkey_bytes);
    // The prover destructor frees this buffer.
    var err_buf: [1024]u8 = undefined;
    @memset(&err_buf, 0);
    var obj: ?*anyopaque = null;
    const rc = create(&obj, zkey_c.ptr, @intCast(zkey_c.len), &err_buf, err_buf.len);
    if (rc != 0 or obj == null) {
        std.c.free(zkey_c.ptr);
        std.debug.print("prover create failed: {s}\n", .{std.mem.sliceTo(&err_buf, 0)});
        return error.ProverCreate;
    }
    defer destroy(obj);

    @memset(&err_buf, 0);
    var pub_sz: c_ulonglong = 0;
    if (public_size(zkey_c.ptr, @intCast(zkey_c.len), &pub_sz, &err_buf, err_buf.len) != 0) {
        std.debug.print("public size failed: {s}\n", .{std.mem.sliceTo(&err_buf, 0)});
        return error.PublicSize;
    }
    var proof_sz: c_ulonglong = 0;
    proof_size_fn(&proof_sz);

    const wtns = try readAll(alloc, io, wtns_path);
    defer alloc.free(wtns);
    const wtns_c = mallocCopy(wtns) orelse return error.OutOfMemory;
    defer std.c.free(wtns_c.ptr);

    const proof_cap: usize = @intCast(proof_sz + 256);
    const public_cap: usize = @intCast(pub_sz + 256);
    const proof_buf = try alloc.alloc(u8, proof_cap);
    defer alloc.free(proof_buf);
    const public_buf = try alloc.alloc(u8, public_cap);
    defer alloc.free(public_buf);
    var proof_n: c_ulonglong = @intCast(proof_cap);
    var public_n: c_ulonglong = @intCast(public_cap);
    @memset(&err_buf, 0);
    const prc = prove_fn(
        obj.?,
        wtns_c.ptr,
        @intCast(wtns_c.len),
        proof_buf.ptr,
        &proof_n,
        public_buf.ptr,
        &public_n,
        &err_buf,
        err_buf.len,
    );
    if (prc != 0) {
        std.debug.print("prove failed rc={d}: {s}\n", .{ prc, std.mem.sliceTo(&err_buf, 0) });
        return error.ProveFailed;
    }

    const proof = try alloc.allocSentinel(u8, @intCast(proof_n), 0);
    defer alloc.free(proof);
    const public_json = try alloc.allocSentinel(u8, @intCast(public_n), 0);
    defer alloc.free(public_json);
    @memcpy(proof, proof_buf[0..proof.len]);
    @memcpy(public_json, public_buf[0..public_json.len]);

    const vk_bytes = try readAll(alloc, io, vk_path);
    defer alloc.free(vk_bytes);
    const vk_z = try alloc.allocSentinel(u8, vk_bytes.len, 0);
    defer alloc.free(vk_z);
    @memcpy(vk_z, vk_bytes);

    @memset(&err_buf, 0);
    const vrc = verify(proof, public_json, vk_z, &err_buf, err_buf.len);
    if (vrc != 0) {
        std.debug.print("verify failed rc={d}: {s}\n", .{ vrc, std.mem.sliceTo(&err_buf, 0) });
        std.debug.print("public {s}\n", .{public_json});
        return error.VerifyFailed;
    }
    std.debug.print("prove+verify ok\n", .{});
    std.debug.print("public {s}\n", .{public_json});
}

fn readAll(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const n = try f.length(io);
    const buf = try alloc.alloc(u8, @intCast(n));
    const got = try f.readPositionalAll(io, buf, 0);
    if (got != buf.len) return error.UnexpectedEof;
    return buf;
}

fn mallocCopy(src: []const u8) ?[]u8 {
    const raw = std.c.malloc(src.len) orelse return null;
    const dst: [*]u8 = @ptrCast(raw);
    @memcpy(dst[0..src.len], src);
    return dst[0..src.len];
}
