const builtin = @import("builtin");
const std = @import("std");
const cli = @import("cli.zig");
const host_simd = @import("host_simd.zig");
const fast_load = @import("fast_load.zig");

const CliFn = *const fn (*std.process.Init) callconv(.c) c_int;

pub fn main(init: std.process.Init) !u8 {
    if (comptime builtin.os.tag == .linux) {
        if (host_simd.fast()) {
            if (fast_load.lookup(CliFn, "groth16_cli")) |entry| {
                var init_mut = init;
                return @intCast(entry(&init_mut));
            }
        }
    }
    return cli.run(init);
}
