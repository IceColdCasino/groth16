const std = @import("std");
const cpu = @import("cpu");

test {
    // Force inclusion of tests from source files.
    _ = @import("../src/prover.zig");
    _ = @import("../src/verifier.zig");
    _ = @import("../src/curve.zig");
    _ = @import("../src/parser.zig");
    _ = @import("../src/json.zig");
    _ = @import("../src/field.zig");
    _ = @import("../src/fft.zig");
    _ = @import("../src/msm.zig");
    _ = @import("../src/pairing.zig");
}

test "cpu: prove with testdata" {
    var result = try cpu.prove(
        "../rapidsnark/testdata/circuit_final.zkey",
        "../rapidsnark/testdata/witness.wtns",
    );
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.proof, "pi_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.proof, "pi_b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.proof, "pi_c") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.public_signals, "[") != null);
}
