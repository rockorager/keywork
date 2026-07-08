//! Builds NanoSVG and its rasterizer from the upstream header-only package.

const std = @import("std");

pub const NanoSvg = struct {
    library: *std.Build.Step.Compile,
    include_dir: std.Build.LazyPath,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) NanoSvg {
    const upstream = b.dependency("nanosvg", .{});
    const include_dir = upstream.path("src");

    const source = b.addWriteFiles().add("nanosvg.c",
        \\#define NANOSVG_IMPLEMENTATION
        \\#define NANOSVGRAST_IMPLEMENTATION
        \\#include <nanosvg.h>
        \\#include <nanosvgrast.h>
        \\
    );

    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addSystemIncludePath(include_dir);
    module.addCSourceFile(.{
        .file = source,
        .flags = &.{"-fvisibility=hidden"},
    });

    const library = b.addLibrary(.{
        .name = "nanosvg",
        .root_module = module,
        .linkage = .static,
    });

    return .{
        .library = library,
        .include_dir = include_dir,
    };
}
