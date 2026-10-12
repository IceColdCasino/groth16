const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zkey",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/metal_host.m"),
        .flags = &.{"-fobjc-arc"},
        .language = .objective_c,
    });
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("Foundation", .{});

    const air_cmd = b.addSystemCommand(&.{ "xcrun", "-sdk", "macosx", "metal", "-O2", "-c" });
    air_cmd.addFileArg(b.path("src/bn254.metal"));
    air_cmd.addArg("-o");
    const air = air_cmd.addOutputFileArg("bn254.air");
    const lib_cmd = b.addSystemCommand(&.{ "xcrun", "-sdk", "macosx", "metallib" });
    lib_cmd.addFileArg(air);
    lib_cmd.addArg("-o");
    const metallib = lib_cmd.addOutputFileArg("bn254.metallib");
    const install_lib = b.addInstallBinFile(metallib, "bn254.metallib");
    b.getInstallStep().dependOn(&install_lib.step);

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run zkey").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Field and curve tests").dependOn(&b.addRunArtifact(tests).step);
}
