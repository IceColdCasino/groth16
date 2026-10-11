const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_macos = target.result.os.tag == .macos;
    const is_native = target.result.os.tag == @import("builtin").os.tag;

    // e_jerk_gpu dependency
    const e_jerk_gpu_dep = b.dependency("e_jerk_gpu", .{});
    const e_jerk_gpu_module = e_jerk_gpu_dep.module("e_jerk_gpu");

    // zig-metal dependency (for Metal compute backend)
    const zig_metal_dep = b.dependency("zig_metal", .{});
    const zig_metal_module = b.addModule("zig-metal", .{
        .root_source_file = zig_metal_dep.path("src/main.zig"),
    });

    // rapidsnark dependency (C++ prover + testdata)
    const rapidsnark_dep = b.dependency("rapidsnark", .{});

    const cpu_module = b.createModule(.{
        .root_source_file = b.path("src/cpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    cpu_module.link_libc = true;

    // Metal shader preprocessing (macOS only)
    var metal_shader_module: ?*std.Build.Module = null;
    var metal_check_step: ?*std.Build.Step = null;
    if (is_macos) {
        const metal_preprocess = b.addSystemCommand(&.{
            "/bin/sh", "-c",
            \\grep -v '#include "field.metal"' "$1" | grep -v '#include "curve.metal"' | grep -v '#include "field_simd.metal"' && grep -v '#include "field.metal"' "$2" | grep -v '#include "curve.metal"' | grep -v '#include "field_simd.metal"' && grep -v '#include "field.metal"' "$3" | grep -v '#include "curve.metal"' | grep -v '#include "field_simd.metal"' && grep -v '#include "field.metal"' "$4" | grep -v '#include "curve.metal"' | grep -v '#include "field_simd.metal"' && grep -v '#include "field.metal"' "$5" | grep -v '#include "curve.metal"' | grep -v '#include "field_simd.metal"' && grep -v '#include "field.metal"' "$6" | grep -v '#include "curve.metal"' | grep -v '#include "field_simd.metal"' && grep -v '#include "field.metal"' "$7" | grep -v '#include "curve.metal"' | grep -v '#include "field_simd.metal"'
            , "--",
        });
        metal_preprocess.addFileArg(b.path("src/shaders/field.metal"));
        metal_preprocess.addFileArg(b.path("src/shaders/field_simd.metal"));
        metal_preprocess.addFileArg(b.path("src/shaders/curve.metal"));
        metal_preprocess.addFileArg(b.path("src/shaders/msm.metal"));
        metal_preprocess.addFileArg(b.path("src/shaders/fft.metal"));
        metal_preprocess.addFileArg(b.path("src/shaders/fft_tile.metal"));
        metal_preprocess.addFileArg(b.path("src/shaders/fft_4step.metal"));
        const preprocessed_metal = metal_preprocess.captureStdOut(.{});

        const write_files = b.addWriteFiles();
        const metal_shader_zig = write_files.add("metal_shader.zig", "pub const EMBEDDED_METAL_SHADER = @embedFile(\"prover.metal\");\n");
        metal_shader_module = b.addModule("metal_shader", .{
            .root_source_file = metal_shader_zig,
        });
        metal_shader_module.?.addAnonymousImport("prover.metal", .{ .root_source_file = preprocessed_metal });

        // Build-time Metal validation
        const write_shader = b.addWriteFiles();
        _ = write_shader.addCopyFile(preprocessed_metal, "prover_check.metal");
        const metal_compile_check = b.addSystemCommand(&.{
            "env", "-u", "CPATH", "xcrun", "-sdk", "macosx", "metal",
            "-Werror", "-c",
        });
        metal_compile_check.addFileArg(write_shader.getDirectory().path(b, "prover_check.metal"));
        metal_compile_check.addArg("-o");
        _ = metal_compile_check.addOutputFileArg("prover.air");
        metal_check_step = &metal_compile_check.step;
    }

    // SPIR-V shader compilation (Vulkan compute backend)
    const spirv_msm_g1_br = b.addSystemCommand(&.{
        "glslangValidator", "-V", "--target-env", "vulkan1.2",
        "-Isrc/shaders",
    });
    spirv_msm_g1_br.addFileArg(b.path("src/shaders/msm_g1_v5_bucket_reduce.comp"));
    spirv_msm_g1_br.addArg("-o");
    const spirv_msm_g1_br_out = spirv_msm_g1_br.addOutputFileArg("msm_g1_v5_bucket_reduce.spv");

    const spirv_msm_g1_wr = b.addSystemCommand(&.{
        "glslangValidator", "-V", "--target-env", "vulkan1.2",
        "-Isrc/shaders",
    });
    spirv_msm_g1_wr.addFileArg(b.path("src/shaders/msm_g1_v5_window_reduce.comp"));
    spirv_msm_g1_wr.addArg("-o");
    const spirv_msm_g1_wr_out = spirv_msm_g1_wr.addOutputFileArg("msm_g1_v5_window_reduce.spv");

    const spirv_msm_g2_br = b.addSystemCommand(&.{
        "glslangValidator", "-V", "--target-env", "vulkan1.2",
        "-Isrc/shaders",
    });
    spirv_msm_g2_br.addFileArg(b.path("src/shaders/msm_g2_v6_bucket_reduce.comp"));
    spirv_msm_g2_br.addArg("-o");
    const spirv_msm_g2_br_out = spirv_msm_g2_br.addOutputFileArg("msm_g2_v6_bucket_reduce.spv");

    const spirv_msm_g2_wr = b.addSystemCommand(&.{
        "glslangValidator", "-V", "--target-env", "vulkan1.2",
        "-Isrc/shaders",
    });
    spirv_msm_g2_wr.addFileArg(b.path("src/shaders/msm_g2_v6_window_reduce.comp"));
    spirv_msm_g2_wr.addArg("-o");
    const spirv_msm_g2_wr_out = spirv_msm_g2_wr.addOutputFileArg("msm_g2_v6_window_reduce.spv");

    const write_spirv = b.addWriteFiles();
    const spirv_msm_g1_br_spv = write_spirv.addCopyFile(spirv_msm_g1_br_out, "msm_g1_v5_bucket_reduce.spv");
    const spirv_msm_g1_wr_spv = write_spirv.addCopyFile(spirv_msm_g1_wr_out, "msm_g1_v5_window_reduce.spv");
    const spirv_msm_g2_br_spv = write_spirv.addCopyFile(spirv_msm_g2_br_out, "msm_g2_v6_bucket_reduce.spv");
    const spirv_msm_g2_wr_spv = write_spirv.addCopyFile(spirv_msm_g2_wr_out, "msm_g2_v6_window_reduce.spv");
    const spirv_zig = write_spirv.add("spirv.zig",
        \\pub const MSM_G1_V5_BUCKET_REDUCE = @embedFile("msm_g1_v5_bucket_reduce.spv");
        \\pub const MSM_G1_V5_WINDOW_REDUCE = @embedFile("msm_g1_v5_window_reduce.spv");
        \\pub const MSM_G2_V6_BUCKET_REDUCE = @embedFile("msm_g2_v6_bucket_reduce.spv");
        \\pub const MSM_G2_V6_WINDOW_REDUCE = @embedFile("msm_g2_v6_window_reduce.spv");
        \\
    );
    const spirv_module = b.addModule("spirv", .{
        .root_source_file = spirv_zig,
    });
    spirv_module.addAnonymousImport("msm_g1_v5_bucket_reduce.spv", .{ .root_source_file = spirv_msm_g1_br_spv });
    spirv_module.addAnonymousImport("msm_g1_v5_window_reduce.spv", .{ .root_source_file = spirv_msm_g1_wr_spv });
    spirv_module.addAnonymousImport("msm_g2_v6_bucket_reduce.spv", .{ .root_source_file = spirv_msm_g2_br_spv });
    spirv_module.addAnonymousImport("msm_g2_v6_window_reduce.spv", .{ .root_source_file = spirv_msm_g2_wr_spv });

    // Generate rapidsnark testdata module from upstream dependency
    const write_testdata = b.addWriteFiles();
    const zkey_file = write_testdata.addCopyFile(rapidsnark_dep.path("testdata/circuit_final.zkey"), "circuit_final.zkey");
    const wtns_file = write_testdata.addCopyFile(rapidsnark_dep.path("testdata/witness.wtns"), "witness.wtns");
    const vk_file = write_testdata.addCopyFile(rapidsnark_dep.path("testdata/verification_key.json"), "verification_key.json");
    const testdata_zig = write_testdata.add("testdata.zig",
        \\pub const ZKEY = @embedFile("circuit_final.zkey");
        \\pub const WTNS = @embedFile("witness.wtns");
        \\pub const VK = @embedFile("verification_key.json");
        \\
    );
    const testdata_module = b.addModule("rapidsnark_testdata", .{
        .root_source_file = testdata_zig,
    });
    testdata_module.addAnonymousImport("circuit_final.zkey", .{ .root_source_file = zkey_file });
    testdata_module.addAnonymousImport("witness.wtns", .{ .root_source_file = wtns_file });
    testdata_module.addAnonymousImport("verification_key.json", .{ .root_source_file = vk_file });
    cpu_module.addImport("rapidsnark_testdata", testdata_module);

    const gpu_module = b.createModule(.{
        .root_source_file = b.path("src/gpu/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_module.addImport("e_jerk_gpu", e_jerk_gpu_module);
    gpu_module.addImport("zig-metal", zig_metal_module);
    gpu_module.addImport("cpu", cpu_module);
    gpu_module.addImport("spirv", spirv_module);
    gpu_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Cellar/molten-vk/1.4.1/libexec/include" });
    if (metal_shader_module) |msm| {
        gpu_module.addImport("metal_shader", msm);
    }

    // --- Static Library: librapidsnark.a ---
    const lib = b.addLibrary(.{
        .name = "rapidsnark",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "gpu", .module = gpu_module },
            },
        }),
    });

    lib.root_module.link_libc = true;

    if (is_native) {
        if (is_macos) {
            lib.root_module.linkFramework("Foundation", .{});
            lib.root_module.linkFramework("Metal", .{});
            lib.root_module.linkFramework("QuartzCore", .{});
            // Also link MoltenVK on macOS when building natively
            lib.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
            lib.root_module.linkSystemLibrary("MoltenVK", .{});
        } else {
            lib.root_module.linkSystemLibrary("pthread", .{});
        }
    }

    b.installArtifact(lib);

    // --- Dynamic Library: librapidsnark.dylib / .so / .dll ---
    const dylib = b.addLibrary(.{
        .name = "rapidsnark",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "gpu", .module = gpu_module },
            },
        }),
    });

    dylib.root_module.link_libc = true;

    if (is_native) {
        if (is_macos) {
            dylib.root_module.linkFramework("Foundation", .{});
            dylib.root_module.linkFramework("Metal", .{});
            dylib.root_module.linkFramework("QuartzCore", .{});
            dylib.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
            dylib.root_module.linkSystemLibrary("MoltenVK", .{});
        } else {
            dylib.root_module.linkSystemLibrary("pthread", .{});
        }
    }

    b.installArtifact(dylib);

    // Install header alongside dylib
    b.installFile("../rapidsnark/src/prover.h", "include/prover.h");

    // --- Executable: prover CLI ---
    const exe = b.addExecutable(.{
        .name = "prover",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "gpu", .module = gpu_module },
            },
        }),
    });

    exe.root_module.link_libc = true;

    if (is_native) {
        if (is_macos) {
            exe.root_module.linkFramework("Foundation", .{});
            exe.root_module.linkFramework("Metal", .{});
            exe.root_module.linkFramework("QuartzCore", .{});
            // Also link MoltenVK on macOS when building natively
            exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
            exe.root_module.linkSystemLibrary("MoltenVK", .{});
        } else {
            exe.root_module.linkSystemLibrary("pthread", .{});
        }
    }

    b.installArtifact(exe);

    const rapidsnark_test_api_module = b.createModule(.{
        .root_source_file = b.path("src/rapidsnark_test_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cpu", .module = cpu_module },
        },
    });

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/rapidsnark_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "rapidsnark_test_api", .module = rapidsnark_test_api_module },
                .{ .name = "rapidsnark_testdata", .module = testdata_module },
                .{ .name = "gpu", .module = gpu_module },
            },
        }),
    });

    unit_tests.root_module.link_libc = true;
    unit_tests.root_module.addObjectFile(b.path("../rapidsnark/zig-out/lib/librapidsnark_test_api.dylib"));

    if (is_native and is_macos) {
        unit_tests.root_module.linkFramework("Foundation", .{});
        unit_tests.root_module.linkFramework("Metal", .{});
        unit_tests.root_module.linkFramework("QuartzCore", .{});
        unit_tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        unit_tests.root_module.linkSystemLibrary("MoltenVK", .{});
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&write_testdata.step);
    if (metal_check_step) |check| {
        test_step.dependOn(check);
    }

    // Temporary MSM debug executable
    const msm_debug = b.addExecutable(.{
        .name = "msm-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/msm_debug.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    msm_debug.root_module.link_libc = true;
    b.installArtifact(msm_debug);

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "rapidsnark_testdata", .module = testdata_module },
            },
        }),
    });

    bench.root_module.link_libc = true;
    if (is_native and is_macos) {
        bench.root_module.linkFramework("Foundation", .{});
        bench.root_module.linkFramework("Metal", .{});
        bench.root_module.linkFramework("QuartzCore", .{});
        bench.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        bench.root_module.linkSystemLibrary("MoltenVK", .{});
    }

    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Medium circuit benchmark
    const bench_medium = b.addExecutable(.{
        .name = "bench-medium",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench_medium.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "gpu", .module = gpu_module },
            },
        }),
    });
    bench_medium.root_module.link_libc = true;
    if (is_native and is_macos) {
        bench_medium.root_module.linkFramework("Foundation", .{});
        bench_medium.root_module.linkFramework("Metal", .{});
        bench_medium.root_module.linkFramework("QuartzCore", .{});
        bench_medium.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        bench_medium.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    const run_bench_medium = b.addRunArtifact(bench_medium);
    const bench_medium_step = b.step("bench-medium", "Run medium circuit benchmark");
    bench_medium_step.dependOn(&run_bench_medium.step);

    // Window preprocessing benchmark
    const window_preprocess_bench = b.addExecutable(.{
        .name = "window-preprocess-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/window_preprocess_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
            },
        }),
    });
    if (is_native) {
        if (is_macos) {
            window_preprocess_bench.root_module.linkFramework("Foundation", .{});
            window_preprocess_bench.root_module.linkFramework("Metal", .{});
            window_preprocess_bench.root_module.linkFramework("QuartzCore", .{});
            window_preprocess_bench.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
            window_preprocess_bench.root_module.linkSystemLibrary("MoltenVK", .{});
        } else {
            window_preprocess_bench.root_module.linkSystemLibrary("pthread", .{});
        }
    }
    window_preprocess_bench.root_module.link_libc = true;

    const run_window_preprocess_bench = b.addRunArtifact(window_preprocess_bench);
    const window_preprocess_bench_step = b.step("window-preprocess-bench", "Run window preprocessing benchmark");
    window_preprocess_bench_step.dependOn(&run_window_preprocess_bench.step);
    if (metal_check_step) |check| {
        window_preprocess_bench_step.dependOn(check);
    }

    // Metal fq_mul test
    const metal_fq_mul_test = b.addExecutable(.{
        .name = "test-metal-fq-mul",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_metal_fq_mul.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
            },
        }),
    });
    if (is_native and is_macos) {
        metal_fq_mul_test.root_module.linkFramework("Foundation", .{});
        metal_fq_mul_test.root_module.linkFramework("Metal", .{});
        metal_fq_mul_test.root_module.linkFramework("QuartzCore", .{});
        metal_fq_mul_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        metal_fq_mul_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    metal_fq_mul_test.root_module.link_libc = true;
    b.installArtifact(metal_fq_mul_test);

    // Metal mul128 test
    const metal_mul128_test = b.addExecutable(.{
        .name = "test-metal-mul128",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_metal_mul128.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
            },
        }),
    });
    if (is_native and is_macos) {
        metal_mul128_test.root_module.linkFramework("Foundation", .{});
        metal_mul128_test.root_module.linkFramework("Metal", .{});
        metal_mul128_test.root_module.linkFramework("QuartzCore", .{});
        metal_mul128_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        metal_mul128_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    metal_mul128_test.root_module.link_libc = true;
    b.installArtifact(metal_mul128_test);

    // Metal add128/fq_add test
    const metal_add128_test = b.addExecutable(.{
        .name = "test-metal-add128",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_metal_add128.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
            },
        }),
    });
    if (is_native and is_macos) {
        metal_add128_test.root_module.linkFramework("Foundation", .{});
        metal_add128_test.root_module.linkFramework("Metal", .{});
        metal_add128_test.root_module.linkFramework("QuartzCore", .{});
        metal_add128_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        metal_add128_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    metal_add128_test.root_module.link_libc = true;
    b.installArtifact(metal_add128_test);

    // Metal mul128 direct test
    const metal_mul128_direct_test = b.addExecutable(.{
        .name = "test-metal-mul128-direct",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_metal_mul128_direct.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
            },
        }),
    });
    if (is_native and is_macos) {
        metal_mul128_direct_test.root_module.linkFramework("Foundation", .{});
        metal_mul128_direct_test.root_module.linkFramework("Metal", .{});
        metal_mul128_direct_test.root_module.linkFramework("QuartzCore", .{});
        metal_mul128_direct_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        metal_mul128_direct_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    metal_mul128_direct_test.root_module.link_libc = true;
    b.installArtifact(metal_mul128_direct_test);

    // fftTile1024 debug test
    const fft_tile1024_debug_test = b.addExecutable(.{
        .name = "test-fft-tile1024-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_fft_tile1024_debug.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        fft_tile1024_debug_test.root_module.linkFramework("Foundation", .{});
        fft_tile1024_debug_test.root_module.linkFramework("Metal", .{});
        fft_tile1024_debug_test.root_module.linkFramework("QuartzCore", .{});
        fft_tile1024_debug_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        fft_tile1024_debug_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    fft_tile1024_debug_test.root_module.link_libc = true;
    b.installArtifact(fft_tile1024_debug_test);

    // Hierarchical FFT test (tile + global stages)
    const fft_hierarchical_test = b.addExecutable(.{
        .name = "test-fft-hierarchical",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_fft_hierarchical.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        fft_hierarchical_test.root_module.linkFramework("Foundation", .{});
        fft_hierarchical_test.root_module.linkFramework("Metal", .{});
        fft_hierarchical_test.root_module.linkFramework("QuartzCore", .{});
        fft_hierarchical_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        fft_hierarchical_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    fft_hierarchical_test.root_module.link_libc = true;
    b.installArtifact(fft_hierarchical_test);

    // fftGlobalStage isolated test
    const fft_global_stage_test = b.addExecutable(.{
        .name = "test-fft-global-stage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_fft_global_stage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        fft_global_stage_test.root_module.linkFramework("Foundation", .{});
        fft_global_stage_test.root_module.linkFramework("Metal", .{});
        fft_global_stage_test.root_module.linkFramework("QuartzCore", .{});
        fft_global_stage_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        fft_global_stage_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    fft_global_stage_test.root_module.link_libc = true;
    b.installArtifact(fft_global_stage_test);

    // 4-step FFT TDD test
    const fft_4step_test = b.addExecutable(.{
        .name = "test-fft-4step",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_fft_4step.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        fft_4step_test.root_module.linkFramework("Foundation", .{});
        fft_4step_test.root_module.linkFramework("Metal", .{});
        fft_4step_test.root_module.linkFramework("QuartzCore", .{});
        fft_4step_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        fft_4step_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    fft_4step_test.root_module.link_libc = true;
    b.installArtifact(fft_4step_test);

    // GPU IFFT TDD test
    const gpu_ifft_test = b.addExecutable(.{
        .name = "test-gpu-ifft",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_ifft.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        gpu_ifft_test.root_module.linkFramework("Foundation", .{});
        gpu_ifft_test.root_module.linkFramework("Metal", .{});
        gpu_ifft_test.root_module.linkFramework("QuartzCore", .{});
        gpu_ifft_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        gpu_ifft_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    gpu_ifft_test.root_module.link_libc = true;
    b.installArtifact(gpu_ifft_test);

    // Metal throughput benchmark
    const metal_throughput_bench = b.addExecutable(.{
        .name = "bench-metal-throughput",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench_metal_throughput.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });
    if (is_native and is_macos) {
        metal_throughput_bench.root_module.linkFramework("Foundation", .{});
        metal_throughput_bench.root_module.linkFramework("Metal", .{});
        metal_throughput_bench.root_module.linkFramework("QuartzCore", .{});
        metal_throughput_bench.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        metal_throughput_bench.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    metal_throughput_bench.root_module.link_libc = true;
    b.installArtifact(metal_throughput_bench);


    // GPU IFFT roundtrip test
    const gpu_ifft_rt_test = b.addExecutable(.{
        .name = "test-gpu-ifft-roundtrip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_ifft_roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        gpu_ifft_rt_test.root_module.linkFramework("Foundation", .{});
        gpu_ifft_rt_test.root_module.linkFramework("Metal", .{});
        gpu_ifft_rt_test.root_module.linkFramework("QuartzCore", .{});
        gpu_ifft_rt_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        gpu_ifft_rt_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    gpu_ifft_rt_test.root_module.link_libc = true;
    b.installArtifact(gpu_ifft_rt_test);

    // GPU FFT n=1024 test
    const gpu_fft_1024_test = b.addExecutable(.{
        .name = "test-gpu-fft-1024",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_fft_1024.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        gpu_fft_1024_test.root_module.linkFramework("Foundation", .{});
        gpu_fft_1024_test.root_module.linkFramework("Metal", .{});
        gpu_fft_1024_test.root_module.linkFramework("QuartzCore", .{});
        gpu_fft_1024_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        gpu_fft_1024_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    gpu_fft_1024_test.root_module.link_libc = true;
    b.installArtifact(gpu_fft_1024_test);

    // Twiddle check test
    const twiddle_check = b.addExecutable(.{
        .name = "test-twiddle-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_twiddle_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });
    twiddle_check.root_module.link_libc = true;
    b.installArtifact(twiddle_check);

    // GPU IFFT small n test
    const gpu_ifft_small_test = b.addExecutable(.{
        .name = "test-gpu-ifft-small",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_ifft_small.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        gpu_ifft_small_test.root_module.linkFramework("Foundation", .{});
        gpu_ifft_small_test.root_module.linkFramework("Metal", .{});
        gpu_ifft_small_test.root_module.linkFramework("QuartzCore", .{});
        gpu_ifft_small_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        gpu_ifft_small_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    gpu_ifft_small_test.root_module.link_libc = true;
    b.installArtifact(gpu_ifft_small_test);

    // GPU IFFT trace test
    const gpu_ifft_trace = b.addExecutable(.{
        .name = "test-gpu-ifft-trace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_ifft_trace.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        gpu_ifft_trace.root_module.linkFramework("Foundation", .{});
        gpu_ifft_trace.root_module.linkFramework("Metal", .{});
        gpu_ifft_trace.root_module.linkFramework("QuartzCore", .{});
        gpu_ifft_trace.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        gpu_ifft_trace.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    gpu_ifft_trace.root_module.link_libc = true;
    b.installArtifact(gpu_ifft_trace);

    // GPU roundtrip large n test
    const gpu_roundtrip_large = b.addExecutable(.{
        .name = "test-gpu-roundtrip-large",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_roundtrip_large.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        gpu_roundtrip_large.root_module.linkFramework("Foundation", .{});
        gpu_roundtrip_large.root_module.linkFramework("Metal", .{});
        gpu_roundtrip_large.root_module.linkFramework("QuartzCore", .{});
        gpu_roundtrip_large.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        gpu_roundtrip_large.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    gpu_roundtrip_large.root_module.link_libc = true;
    b.installArtifact(gpu_roundtrip_large);

    // GPU roundtrip many sizes test
    const gpu_roundtrip_many = b.addExecutable(.{
        .name = "test-gpu-roundtrip-many",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_roundtrip_many.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        gpu_roundtrip_many.root_module.linkFramework("Foundation", .{});
        gpu_roundtrip_many.root_module.linkFramework("Metal", .{});
        gpu_roundtrip_many.root_module.linkFramework("QuartzCore", .{});
        gpu_roundtrip_many.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        gpu_roundtrip_many.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    gpu_roundtrip_many.root_module.link_libc = true;
    b.installArtifact(gpu_roundtrip_many);

    // GPU FFT only test
    const gpu_fft_only = b.addExecutable(.{
        .name = "test-gpu-fft-only",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_fft_only.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        gpu_fft_only.root_module.linkFramework("Foundation", .{});
        gpu_fft_only.root_module.linkFramework("Metal", .{});
        gpu_fft_only.root_module.linkFramework("QuartzCore", .{});
        gpu_fft_only.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        gpu_fft_only.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    gpu_fft_only.root_module.link_libc = true;
    b.installArtifact(gpu_fft_only);

    // GPU IFFT only test
    const gpu_ifft_only = b.addExecutable(.{
        .name = "test-gpu-ifft-only",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_ifft_only.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        gpu_ifft_only.root_module.linkFramework("Foundation", .{});
        gpu_ifft_only.root_module.linkFramework("Metal", .{});
        gpu_ifft_only.root_module.linkFramework("QuartzCore", .{});
        gpu_ifft_only.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        gpu_ifft_only.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    gpu_ifft_only.root_module.link_libc = true;
    b.installArtifact(gpu_ifft_only);

    // Twiddle inverse comparison test
    const twiddle_inv_cmp = b.addExecutable(.{
        .name = "test-twiddle-inv-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_twiddle_inv_compare.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });
    twiddle_inv_cmp.root_module.link_libc = true;
    b.installArtifact(twiddle_inv_cmp);

    // Twiddle cache GPU check
    const twiddle_cache_check = b.addExecutable(.{
        .name = "test-twiddle-cache-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_twiddle_cache_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        twiddle_cache_check.root_module.linkFramework("Foundation", .{});
        twiddle_cache_check.root_module.linkFramework("Metal", .{});
        twiddle_cache_check.root_module.linkFramework("QuartzCore", .{});
        twiddle_cache_check.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        twiddle_cache_check.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    twiddle_cache_check.root_module.link_libc = true;
    b.installArtifact(twiddle_cache_check);

    // GPU IFFT old style test
    const gpu_ifft_old = b.addExecutable(.{
        .name = "test-gpu-ifft-old-style",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_ifft_old_style.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        gpu_ifft_old.root_module.linkFramework("Foundation", .{});
        gpu_ifft_old.root_module.linkFramework("Metal", .{});
        gpu_ifft_old.root_module.linkFramework("QuartzCore", .{});
        gpu_ifft_old.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        gpu_ifft_old.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    gpu_ifft_old.root_module.link_libc = true;
    b.installArtifact(gpu_ifft_old);

    // GPU tile IFFT test
    const tile_ifft_test = b.addExecutable(.{
        .name = "test-gpu-tile-ifft",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_tile_ifft.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        tile_ifft_test.root_module.linkFramework("Foundation", .{});
        tile_ifft_test.root_module.linkFramework("Metal", .{});
        tile_ifft_test.root_module.linkFramework("QuartzCore", .{});
        tile_ifft_test.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        tile_ifft_test.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    tile_ifft_test.root_module.link_libc = true;
    b.installArtifact(tile_ifft_test);

    // GPU tile+global IFFT test
    const tile_global_ifft = b.addExecutable(.{
        .name = "test-gpu-tile-global-ifft",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_tile_global_ifft.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        tile_global_ifft.root_module.linkFramework("Foundation", .{});
        tile_global_ifft.root_module.linkFramework("Metal", .{});
        tile_global_ifft.root_module.linkFramework("QuartzCore", .{});
        tile_global_ifft.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        tile_global_ifft.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    tile_global_ifft.root_module.link_libc = true;
    b.installArtifact(tile_global_ifft);

    // GPU calculateH pipeline test
    const calcH_pipeline = b.addExecutable(.{
        .name = "test-gpu-calculateh-pipeline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_calculateh_pipeline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        calcH_pipeline.root_module.linkFramework("Foundation", .{});
        calcH_pipeline.root_module.linkFramework("Metal", .{});
        calcH_pipeline.root_module.linkFramework("QuartzCore", .{});
        calcH_pipeline.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        calcH_pipeline.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    calcH_pipeline.root_module.link_libc = true;
    b.installArtifact(calcH_pipeline);

    // GPU calculateH pipeline many sizes test
    const calcH_many = b.addExecutable(.{
        .name = "test-gpu-calculateh-many",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_calculateh_pipeline_many.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        calcH_many.root_module.linkFramework("Foundation", .{});
        calcH_many.root_module.linkFramework("Metal", .{});
        calcH_many.root_module.linkFramework("QuartzCore", .{});
        calcH_many.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        calcH_many.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    calcH_many.root_module.link_libc = true;
    b.installArtifact(calcH_many);

    // GPU bit-reverse large test
    const bitreverse_large = b.addExecutable(.{
        .name = "test-gpu-bitreverse-large",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_bitreverse_large.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        bitreverse_large.root_module.linkFramework("Foundation", .{});
        bitreverse_large.root_module.linkFramework("Metal", .{});
        bitreverse_large.root_module.linkFramework("QuartzCore", .{});
        bitreverse_large.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        bitreverse_large.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    bitreverse_large.root_module.link_libc = true;
    b.installArtifact(bitreverse_large);

    // GPU ifftScaleShift large test
    const ifftscale_large = b.addExecutable(.{
        .name = "test-gpu-ifftscale-large",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tdd_gpu_ifftscale_large.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "zig-metal", .module = zig_metal_module },
            },
        }),
    });
    if (is_native and is_macos) {
        ifftscale_large.root_module.linkFramework("Foundation", .{});
        ifftscale_large.root_module.linkFramework("Metal", .{});
        ifftscale_large.root_module.linkFramework("QuartzCore", .{});
        ifftscale_large.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        ifftscale_large.root_module.linkSystemLibrary("MoltenVK", .{});
    }
    ifftscale_large.root_module.link_libc = true;
    b.installArtifact(ifftscale_large);
}
