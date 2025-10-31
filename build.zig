const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("ser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&(b.addRunArtifact(b.addTest(.{ .root_module = mod }))).step);
}
