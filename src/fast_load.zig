//! Opens libgroth16_fast.so when this binary was built as the portable half
//! of a Linux pair. The wide library exports the same C names and does not
//! load itself.
const builtin = @import("builtin");
const std = @import("std");
const host_simd = @import("host_simd.zig");

const dispatch = @import("isa_options").dispatch;

var opened: ?*anyopaque = undefined;
var state: std.atomic.Value(u8) = .init(0);

pub fn lookup(comptime T: type, name: [:0]const u8) ?T {
    if (comptime !dispatch or builtin.os.tag != .linux) return null;
    if (!host_simd.fast()) return null;
    const handle = library() orelse return null;
    const sym = std.c.dlsym(handle, name.ptr) orelse return null;
    return @ptrCast(@alignCast(sym));
}

fn library() ?*anyopaque {
    switch (state.load(.acquire)) {
        1 => return null,
        2 => return opened,
        else => {},
    }
    const handle = std.c.dlopen("libgroth16_fast.so", .{ .LAZY = true });
    if (handle == null) {
        state.store(1, .release);
        return null;
    }
    opened = handle;
    state.store(2, .release);
    return handle;
}
