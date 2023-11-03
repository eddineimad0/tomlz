const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var toml = b.createModule(.{
        .source_file = .{ .path = "src/main.zig" },
    });

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
        curr_test.addModule("toml", toml);
        const install_step = b.addInstallArtifact(curr_test, .{});
        const run_step = b.addRunArtifact(curr_test);
        run_step.step.dependOn(&install_step.step);
        test_step.dependOn(&run_step.step);
    }
}
