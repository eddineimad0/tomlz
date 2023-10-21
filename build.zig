const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var toml = b.createModule(.{
        .source_file = .{ .path = "src/main.zig" },
    });

    const test_step = b.step("test", "Compile tests");
    const tests = [_][]const u8{
        "test_examples",
    };

    for (tests) |test_name| {
        const curr_test = b.addExecutable(.{
            .name = test_name,
            .root_source_file = .{ .path = b.fmt("tests/{s}.zig", .{test_name}) },
            .target = target,
            .optimize = optimize,
        });
        curr_test.addModule("toml", toml);
        const install_step = b.addInstallArtifact(curr_test, .{});
        test_step.dependOn(&curr_test.step);
        test_step.dependOn(&install_step.step);
    }
}
