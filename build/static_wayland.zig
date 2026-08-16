//! Builds the pinned Wayland client and server static libraries.

const std = @import("std");
const builtin = @import("builtin");

pub const Output = struct {
    b: *std.Build,
    build_dir: std.Build.LazyPath,
    source_dir: std.Build.LazyPath,
    wayland_xml: std.Build.LazyPath,
    protocols: std.Build.LazyPath,

    pub fn linkClient(self: Output, module: *std.Build.Module) void {
        self.addIncludes(module);
        module.addObjectFile(self.build_dir.path(self.b, "src/libwayland-client.a"));
    }

    pub fn linkClientAndServer(self: Output, module: *std.Build.Module) void {
        self.addIncludes(module);
        module.addObjectFile(self.build_dir.path(self.b, "src/libwayland-client.a"));
        module.addObjectFile(self.build_dir.path(self.b, "src/libwayland-server.a"));
    }

    fn addIncludes(self: Output, module: *std.Build.Module) void {
        module.addIncludePath(self.source_dir.path(self.b, "src"));
        module.addIncludePath(self.build_dir.path(self.b, "src"));
    }
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Output {
    if (target.result.os.tag != .linux or
        !target.query.isNativeOs() or
        !target.query.isNativeAbi() or
        target.query.ofmt != null or
        target.result.cpu.arch != builtin.cpu.arch)
    {
        @panic("the bundled static Wayland build currently supports native Linux platform targets only");
    }

    const source = b.dependency("wayland_source", .{}).path("");
    const protocols = b.dependency("wayland_protocols", .{}).path("");
    const build_wayland = b.addSystemCommand(&.{"bash"});
    build_wayland.addFileArg(b.path("scripts/build-static-wayland"));
    const build_dir = build_wayland.addOutputDirectoryArg("wayland");
    build_wayland.addDirectoryArg(source);
    build_wayland.addArg(mesonBuildType(optimize));

    return .{
        .b = b,
        .build_dir = build_dir,
        .source_dir = source,
        .wayland_xml = source.path(b, "protocol/wayland.xml"),
        .protocols = protocols,
    };
}

fn mesonBuildType(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "debug",
        .ReleaseSafe => "debugoptimized",
        .ReleaseFast => "release",
        .ReleaseSmall => "minsize",
    };
}
