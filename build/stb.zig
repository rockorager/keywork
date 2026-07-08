//! Builds stb_image and stb_image_resize from the upstream header-only package.

const std = @import("std");

pub const Stb = struct {
    library: *std.Build.Step.Compile,
    include_dir: std.Build.LazyPath,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Stb {
    const upstream = b.dependency("stb", .{});
    const include_dir = upstream.path("");

    const source = b.addWriteFiles().add("stb.c",
        \\#define STBI_ONLY_PNG
        \\#define STBI_MAX_DIMENSIONS 131072
        \\#define STB_IMAGE_IMPLEMENTATION
        \\#include <stb_image.h>
        \\
        \\#define STBIR_ASSERT(x)
        \\#define STB_IMAGE_RESIZE_IMPLEMENTATION
        \\#include <stb_image_resize2.h>
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
        .name = "stb",
        .root_module = module,
        .linkage = .static,
    });

    return .{
        .library = library,
        .include_dir = include_dir,
    };
}
