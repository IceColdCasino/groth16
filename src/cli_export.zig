const std = @import("std");
const cli = @import("cli.zig");

fn entry(init: *std.process.Init) callconv(.c) c_int {
    const rc = cli.run(init.*) catch |err| {
        std.debug.print("prover failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return @intCast(rc);
}

comptime {
    @export(&entry, .{ .name = "groth16_cli" });
}
