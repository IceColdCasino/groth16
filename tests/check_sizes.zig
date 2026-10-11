const std = @import("std");
const curve = @import("cpu").curve;

test "check sizes" {
    std.debug.print("sizeof(G1Point) = {d}\n", .{@sizeOf(curve.G1Point)});
    std.debug.print("sizeof(G1PointAffine) = {d}\n", .{@sizeOf(curve.G1PointAffine)});
    std.debug.print("sizeof(G2Point) = {d}\n", .{@sizeOf(curve.G2Point)});
    std.debug.print("sizeof(G2PointAffine) = {d}\n", .{@sizeOf(curve.G2PointAffine)});
    std.debug.print("sizeof(FqElement) = {d}\n", .{@sizeOf(curve.FqElement)});
    std.debug.print("sizeof(Fq2Element) = {d}\n", .{@sizeOf(curve.Fq2Element)});
    std.debug.print("sizeof(FrElement) = {d}\n", .{@sizeOf(curve.FrElement)});
}
