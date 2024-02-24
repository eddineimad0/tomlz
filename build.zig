const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const max_nestting_allowed = b
        .option(
        u8,
        "max_nestting",
        "Set the maximum allowed level of table nesting, beyond which the parser will throw an error.",
    ) orelse
        6;

    const options = b.addOptions();
    options.addOption(u8, "MAX_NESTTING_LEVEL", max_nestting_allowed);
    const options_module = options.createModule();

    var tomlz = b.createModule(.{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &.{
            .{
                .name = "build_options",
                .module = options_module,
            },
        },
    });

    const lib_fuzz_step = b.step("fuzz", "build static library for fuzzing with afl++ fuzzer.");
    const fuzz_lib = b.addStaticLibrary(.{
        .name = "fuzz-me",
        .root_source_file = .{ .path = "fuzz/export.zig" },
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.addModule("tomlz", tomlz);
    const fuzz_lib_install = b.addInstallArtifact(
        fuzz_lib,
        .{ .dest_dir = .{ .override = .{ .custom = "../fuzz/fuzzer/link/" } } },
    );
    lib_fuzz_step.dependOn(&fuzz_lib_install.step);

    const run_step = b.step("run", "Compile and run examples");
    const binary = b.addExecutable(.{
        .name = "examples",
        .root_source_file = .{ .path = "tests/examples.zig" },
        .target = target,
        .optimize = optimize,
    });
    binary.addModule("tomlz", tomlz);
    const examples_install_step = b.addInstallArtifact(binary, .{});
    const examples_run_step = b.addRunArtifact(binary);
    examples_run_step.step.dependOn(&examples_install_step.step);
    run_step.dependOn(&examples_run_step.step);

    const test_step = b.step("test", "Compile a binary to run against the toml test suite");
    const curr_test = b.addExecutable(.{
        .name = "test-parser",
        .root_source_file = .{ .path = "tests/test-parser.zig" },
        .target = target,
        .optimize = optimize,
    });
    curr_test.addModule("tomlz", tomlz);
    const test_install_step = b.addInstallArtifact(curr_test, .{});
    test_step.dependOn(&test_install_step.step);
}
