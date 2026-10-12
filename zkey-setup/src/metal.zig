const std = @import("std");
const ff = @import("ff.zig");

extern "c" fn metal_init(path: [*:0]const u8) c_int;
extern "c" fn metal_g1_same(points: [*]const u8, n: c_uint, scalar: [*]const u8, params: [*]const u8, out: [*]u8) c_int;
extern "c" fn metal_g1_many(points: [*]const u8, n: c_uint, scalars: [*]const u8, params: [*]const u8, out: [*]u8) c_int;
extern "c" fn metal_g2_many(p1: [*]const u8, p2: [*]const u8, n: c_uint, scalars: [*]const u8, params: [*]const u8, out: [*]u8) c_int;

var ready = false;
var failed = false;
var params_buf: [136]u8 = undefined;

const fr_half = [4]u64{
    0xa1f0fac9f8000000,
    0x9419f4243cdcb848,
    0xdc2822db40c0ac2e,
    0x183227397098d014,
};

fn fillParams() void {
    var words: [17]u64 = undefined;
    words[0..4].* = ff.Fq.mod_limbs;
    words[4] = ff.Fq.mont_n0;
    words[5..9].* = ff.Fq.one().limbs;
    words[9..13].* = ff.Fr.mod_limbs;
    words[13..17].* = fr_half;
    inline for (0..17) |i| {
        std.mem.writeInt(u64, params_buf[i * 8 ..][0..8], words[i], .little);
    }
}

pub fn init(io: std.Io) bool {
    if (ready) return true;
    if (failed) return false;
    fillParams();
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &exe_buf) catch {
        failed = true;
        return false;
    };
    const exe = exe_buf[0..n];
    const slash = std.mem.lastIndexOfScalar(u8, exe, '/') orelse {
        failed = true;
        return false;
    };
    const dir = exe[0..slash];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const suffix = "/bn254.metallib";
    if (dir.len + suffix.len + 1 > path_buf.len) {
        failed = true;
        return false;
    }
    @memcpy(path_buf[0..dir.len], dir);
    @memcpy(path_buf[dir.len..][0..suffix.len], suffix);
    const len = dir.len + suffix.len;
    path_buf[len] = 0;
    const path = path_buf[0..len :0];
    if (metal_init(path) != 0) {
        failed = true;
        std.debug.print("Metal unavailable, using CPU cores only\n", .{});
        return false;
    }
    ready = true;
    return true;
}

pub fn g1Same(points: []const u8, scalar: *const [32]u8, out: []u8) bool {
    if (!ready) return false;
    const n: c_uint = @intCast(points.len / 64);
    return metal_g1_same(points.ptr, n, scalar, &params_buf, out.ptr) == 0;
}

pub fn g1Many(points: []const u8, scalars: []const u8, out: []u8) bool {
    if (!ready) return false;
    const n: c_uint = @intCast(points.len / 64);
    return metal_g1_many(points.ptr, n, scalars.ptr, &params_buf, out.ptr) == 0;
}

pub fn g2Many(p1: []const u8, p2: []const u8, scalars: []const u8, out: []u8) bool {
    if (!ready) return false;
    const n: c_uint = @intCast(p1.len / 128);
    return metal_g2_many(p1.ptr, p2.ptr, n, scalars.ptr, &params_buf, out.ptr) == 0;
}
