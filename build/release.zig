//! Release package construction for the Linux compositor bundle.

const std = @import("std");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: []const u8,
    compositor: *std.Build.Step.Compile,
) void {
    const target_name = b.fmt("{s}-{s}", .{
        @tagName(target.result.os.tag),
        @tagName(target.result.cpu.arch),
    });
    const package = b.addSystemCommand(&.{"bash"});
    package.addFileArg(b.path("scripts/package-release"));
    package.addArgs(&.{ version, target_name, @tagName(optimize) });
    package.addFileArg(compositor.getEmittedBin());
    package.addFileArg(b.path("LICENSE"));
    package.addFileArg(b.path("README.md"));
    package.addFileArg(b.path("build.zig.zon"));
    package.addFileArg(b.path("licenses/wayland.txt"));
    const archives = package.addOutputDirectoryArg("release");

    const install = b.addInstallDirectory(.{
        .source_dir = archives,
        .install_dir = .prefix,
        .install_subdir = "release",
    });
    const release_step = b.step(
        "release",
        "Build a versioned Linux compositor bundle (requires ReleaseSafe)",
    );
    release_step.dependOn(&install.step);
}
