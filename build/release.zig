//! Release package construction for the Linux bundle and browser SDK.

const std = @import("std");
const stream = @import("stream.zig");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: []const u8,
    compositor: *std.Build.Step.Compile,
    stream_output: stream.Output,
) void {
    const target_name = b.fmt("{s}-{s}", .{
        @tagName(target.result.os.tag),
        @tagName(target.result.cpu.arch),
    });
    const package = b.addSystemCommand(&.{"bash"});
    package.addFileArg(b.path("scripts/package-release"));
    package.addArgs(&.{ version, target_name, @tagName(optimize) });
    package.addFileArg(compositor.getEmittedBin());
    package.addFileArg(stream_output.streamd.getEmittedBin());
    package.addFileArg(stream_output.gateway);
    package.addDirectoryArg(b.path("src/stream/gateway/sdk"));
    package.addFileArg(b.path("LICENSE"));
    package.addFileArg(b.path("src/stream/README.md"));
    package.addFileArg(b.path("build.zig.zon"));
    const archives = package.addOutputDirectoryArg("release");

    const install = b.addInstallDirectory(.{
        .source_dir = archives,
        .install_dir = .prefix,
        .install_subdir = "release",
    });
    const release_step = b.step(
        "release",
        "Build a versioned Linux bundle and npm package (requires ReleaseSafe)",
    );
    release_step.dependOn(&install.step);
}
