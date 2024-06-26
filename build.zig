const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_options = prepareBuildOptions(b);

    const tomlz = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{
                .name = "build_options",
                .module = build_options,
            },
        },
    });

    const lib_fuzz_step = b.step("fuzz", "build static library for fuzzing with afl++ fuzzer.");
    const fuzz_lib = b.addStaticLibrary(.{
        .name = "fuzz-me",
        .root_source_file = b.path("fuzz/export.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    fuzz_lib.bundle_compiler_rt = true;
    const fuzz_lib_install = b.addInstallArtifact(
        fuzz_lib,
        .{ .dest_dir = .{ .override = .{ .custom = "../fuzz/fuzzer/link/" } } },
    );
    lib_fuzz_step.dependOn(&fuzz_lib_install.step);

    const examples_step = b.step("parse-examples", "Compile and parse toml examples");
    const binary = b.addExecutable(.{
        .name = "parse-examples",
        .root_source_file = b.path("steps/parse-examples.zig"),
        .target = target,
        .optimize = optimize,
    });
    binary.root_module.addImport("tomlz", tomlz);
    const examples_install_step = b.addInstallArtifact(binary, .{});
    const examples_run_step = b.addRunArtifact(binary);
    examples_run_step.step.dependOn(&examples_install_step.step);
    examples_step.dependOn(&examples_run_step.step);

    const test_parser_step = b.step("test-parser", "Compile a binary to run against the toml test suite");
    const test_parser_bin = b.addExecutable(.{
        .name = "test-parser",
        .root_source_file = b.path("steps/test-parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_parser_bin.root_module.addImport("tomlz", tomlz);
    const test_install_step = b.addInstallArtifact(test_parser_bin, .{});
    test_parser_step.dependOn(&test_install_step.step);

    const utest_step = b.step("test", "Run unit tests");
    const utest = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    utest.root_module.addImport("build_options", build_options);
    const run_utest = b.addRunArtifact(utest);
    utest_step.dependOn(&run_utest.step);
}

fn prepareBuildOptions(b: *std.Build) *std.Build.Module {
    const max_nestting_allowed = b
        .option(
        u8,
        "max_nestting",
        "Set the maximum allowed level of table nesting, beyond which the parser will throw an error.",
    ) orelse
        6;

    const lexer_log_state = b.option(
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

    const error_stack_buffer_size = b.option(
        usize,
        "toml_error_stack_buffer_size",
        "Specify the size of toml tables when parsing.",
    ) orelse 256;

    const options = b.addOptions();
    options.addOption(u8, "MAX_NESTTING_LEVEL", max_nestting_allowed);
    options.addOption(bool, "LOG_LEXER_STATE", lexer_log_state);
    options.addOption(bool, "EMIT_COMMENT_TOKEN", lexer_emit_comment);
    options.addOption(usize, "LEXER_BUFFER_SIZE", lexer_buffer_size);
    options.addOption(usize, "DEFAULT_ARRAY_SIZE", default_array_size);
    options.addOption(usize, "DEFAULT_HASHMAP_SIZE", default_hashmap_size);
    options.addOption(usize, "ERROR_STACK_BUFFER_SIZE", error_stack_buffer_size);

    const options_module = options.createModule();
    return options_module;
}
