const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_options = createBuildOptions(b);

    const tomlz = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "build_options",
                .module = build_options,
            },
        },
    });

    //const lib_fuzz_step = b.step("fuzz", "build static library for fuzzing with afl++ fuzzer.");
    //const fuzz_lib = b.addStaticLibrary(.{
    //    .name = "fuzz-me",
    //    .root_source_file = b.path("fuzz/export.zig"),
    //    .target = target,
    //    .optimize = .Debug,
    //    .link_libc = true,
    //});
    //fuzz_lib.bundle_compiler_rt = true;
    //fuzz_lib.root_module.addImport("tomlz", tomlz);
    //const fuzz_lib_install = b.addInstallArtifact(
    //    fuzz_lib,
    //    .{ .dest_dir = .{ .override = .{ .custom = "../fuzz/fuzzer/link/" } } },
    //);
    //lib_fuzz_step.dependOn(&fuzz_lib_install.step);

    const parse_examples_bin = b.addExecutable(.{
        .name = "parse_examples",
        .root_source_file = b.path("tests/parse_examples.zig"),
        .target = target,
        .optimize = optimize,
    });
    parse_examples_bin.root_module.addImport("tomlz", tomlz);
    const examples_run_step = b.addRunArtifact(parse_examples_bin);
    const examples_step = b.step("parse-examples", "Compile and parse toml examples");
    examples_step.dependOn(&examples_run_step.step);

    const test_parser_bin = b.addExecutable(.{
        .name = "toml_test_parser",
        .root_source_file = b.path("tests/toml_test_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_parser_bin.root_module.addImport("tomlz", tomlz);
    const test_parser_step = b.step(
        "toml-test-parser",
        "Compile a parser binary to run against the toml test suite",
    );
    test_parser_step.dependOn(&test_parser_bin.step);

    const utest_bin = b.addTest(.{
        .root_module = tomlz,
    });
    const run_utest = b.addRunArtifact(utest_bin);
    const utest_step = b.step("test", "Run unit tests");
    run_utest.step.dependOn(&utest_bin.step);
    utest_step.dependOn(&run_utest.step);
}

fn createBuildOptions(b: *std.Build) *std.Build.Module {
    const max_nestting_allowed = b
        .option(
        u8,
        "max_nestting",
        "Set the maximum allowed level of table nesting, beyond which the parser will throw an error.",
    ) orelse
        6;

    const lexer_log_state = b.option(
        bool,
        "tomlz_lexer_log_state",
        "Log the lexer state functions stack.",
    ) orelse false;

    const lexer_emit_comment = b.option(
        bool,
        "tomlz_lexer_emit_comment",
        "If set the lexer will emit Comment tokens when encountering a comment.",
    ) orelse false;

    const lexer_buffer_size = b.option(
        usize,
        "tomlz_lexer_buffer_size",
        "Specify the initial token buffer size used by the lexer.",
    ) orelse 1024;

    const initial_array_size = b.option(
        usize,
        "tomlz_initial_array_size",
        "Specify the initial size for toml arrays when parsing.",
    ) orelse 16;

    const initial_hashmap_size = b.option(
        usize,
        "tomlz_initial_hashmap_size",
        "Specify the initial size of toml tables when parsing.",
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
    options.addOption(usize, "INITIAL_ARRAY_SIZE", initial_array_size);
    options.addOption(usize, "INITIAL_HASHMAP_SIZE", initial_hashmap_size);
    options.addOption(usize, "ERROR_STACK_BUFFER_SIZE", error_stack_buffer_size);

    const options_module = options.createModule();
    return options_module;
}
