const std = @import("std");
const cpu = @import("cpu");

test {
    // Force inclusion of tests from source files.
    _ = @import("../src/core/prover.zig");
    _ = @import("../src/core/verifier.zig");
    _ = @import("../src/core/curve.zig");
    _ = @import("../src/core/parser.zig");
    _ = @import("../src/core/json.zig");
    _ = @import("../src/core/field.zig");
    _ = @import("../src/core/fft.zig");
    _ = @import("../src/core/msm.zig");
    _ = @import("../src/core/pairing.zig");
}

test "cpu: prove with testdata" {
    var result = try cpu.prove(
        "testdata/circuit_final.zkey",
        "testdata/witness.wtns",
    );
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.proof, "pi_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.proof, "pi_b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.proof, "pi_c") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.public_signals, "[") != null);
}
