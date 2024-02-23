const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var tomlz = b.createModule(.{
        .source_file = .{ .path = "src/main.zig" },
    });

    const lib_fuzz_step = b.step("fuzz-lib", "fuzz static library with afl++ fuzzer.");
    const fuzz_lib = b.addStaticLibrary(.{
        .name = "lib-fuzz-me",
        .root_source_file = .{ .path = "fuzz/lib.zig" },
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.addModule("tomlz", tomlz);
    const fuzz_lib_install = b.addInstallArtifact(fuzz_lib, .{});
    lib_fuzz_step.dependOn(&fuzz_lib_install.step);

    // const fuzz_c_path = try std.fs.path.join(
    //     b.allocator,
    //     &.{ b.build_root.path.?, "fuzz", "fuzz_lib.c" },
    // );
    // const fuzz_obj_path = try std.fs.path.join(
    //     b.allocator,
    //     &.{ b.cache_root.path.?, "fuzz.o" },
    // );
    // const fuzz_lib_exe_path = try std.fs.path.join(
    //     b.allocator,
    //     &.{ b.build_root.path.?, "zig-out", "bin", "fuzz" },
    // );
    //
    // const compile_cmd = b.addSystemCommand(&.{
    //     "afl-clang-lto",
    //     "-o",
    //     fuzz_obj_path,
    //     fuzz_c_path,
    // });
    // const link_cmd = b.addSystemCommand(&.{
    //     "afl-clang-lto",
    //     "-o",
    //     fuzz_lib_exe_path,
    //     fuzz_obj_path,
    //     "-l",
    // });
    // link_cmd.step.dependOn(&compile_cmd.step);
    // link_cmd.step.dependOn(&fuzz_lib_install.step);

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
