const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var tomlz = b.createModule(.{
        .source_file = .{ .path = "src/main.zig" },
    });

    const lib_fuzz_step = b.step("fuzz", "build static library for fuzzing with afl++ fuzzer.");
    const fuzz_lib = b.addStaticLibrary(.{
        .name = "lib-fuzz-me",
        .root_source_file = .{ .path = "fuzz/fuzz.zig" },
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.addModule("tomlz", tomlz);
    const fuzz_lib_install = b.addInstallArtifact(fuzz_lib, .{});
    lib_fuzz_step.dependOn(&fuzz_lib_install.step);

    const test_step = b.step("test", "Compile and run tests");
    const tests = [_][]const u8{
        "examples",
    };
    for (tests) |test_name| {
        const curr_test = b.addExecutable(.{
            .name = test_name,
            .root_source_file = .{ .path = b.fmt("tests/{s}.zig", .{test_name}) },
            .target = target,
            .optimize = optimize,
        });
        curr_test.addModule("tomlz", tomlz);
        const test_install_step = b.addInstallArtifact(curr_test, .{});
        const test_run_step = b.addRunArtifact(curr_test);
        test_run_step.step.dependOn(&test_install_step.step);
        test_step.dependOn(&test_run_step.step);
    }
}
