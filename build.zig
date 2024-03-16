const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var tomlz = b.createModule(.{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &.{
            .{
                .name = "build_options",
                .module = prepareBuildOptions(b),
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

fn prepareBuildOptions(b: *std.Build) *std.Build.Module {
    const max_nestting_allowed = b
        .option(
        u8,
        "max_nestting",
        "Set the maximum allowed level of table nesting, beyond which the parser will throw an error.",
    ) orelse
        6;

    const log_lexer_state = b.option(
        bool,
        "toml_lexer_log_state",
        "Log the lexer functions stack.",
    ) orelse false;

    const lexer_emit_comment = b.option(
        bool,
        "toml_lexer_emit_comment",
        "If set the lexer will emit Comment tokens when encountering a comment.",
    ) orelse false;

    const lexer_buffer_size = b.option(
        usize,
        "toml_lexer_buffer_size",
        "Specify the initial token buffer size used by the lexer.",
    ) orelse 1024;

    const default_array_size = b.option(
        usize,
        "toml_default_array_size",
        "Specify the initial size for toml arrays when parsing.",
    ) orelse 16;

    const default_hashmap_size = b.option(
        usize,
        "toml_default_hashmap_size",
        "Specify the size of toml tables when parsing.",
    ) orelse 32;

    const options = b.addOptions();
    options.addOption(u8, "MAX_NESTTING_LEVEL", max_nestting_allowed);
    options.addOption(bool, "LOG_LEXER_STATE", log_lexer_state);
    options.addOption(bool, "EMIT_COMMENT_TOKEN", lexer_emit_comment);
    options.addOption(usize, "LEXER_BUFFER_SIZE", lexer_buffer_size);
    options.addOption(usize, "DEFAULT_ARRAY_SIZE", default_array_size);
    options.addOption(usize, "DEFAULT_HASHMAP_SIZE", default_hashmap_size);

    const options_module = options.createModule();
    return options_module;
}
