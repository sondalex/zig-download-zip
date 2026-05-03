const std = @import("std");
const dz = @import("src/root.zig");

pub const DownloadZip = dz.DownloadZip;
pub const addDownloadStep = dz.addDownloadStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const temp_dep = b.dependency("temp", .{});

    const mod = b.addModule("download_zip", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "temp", .module = temp_dep.module("temp") },
        },
        .target = target,
        .optimize = optimize,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root_test.zig"),
        .imports = &.{
            .{ .name = "download_zip", .module = mod },
        },
        .target = target,
        .optimize = optimize,
    });

    const test_artifact = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(test_artifact);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // Check step
    const check_step = b.step("check", "Check if main + tests compile");

    const check_main = b.addTest(.{
        .root_module = mod,
    });
    check_step.dependOn(&check_main.step);
    check_step.dependOn(&test_artifact.step);
}
