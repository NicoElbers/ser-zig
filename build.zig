const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const test_step = b.step("test", "Run tests");
    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&(b.addRunArtifact(mod_tests)).step);

    const check_step = b.step("check", "Check if everything compiles");
    check_step.dependOn(&mod_tests.step);
}
