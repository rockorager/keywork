const std = @import("std");
const runtime = @import("build/runtime.zig");
const compositor = @import("build/compositor.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Escape hatch for toolchains where the self-hosted linker cannot link
    // system CRT objects (e.g. .sframe sections from GCC 16's crt1.o).
    const use_llvm = b.option(bool, "llvm", "Use the LLVM backend and LLD linker");

    const keywork_loop = b.addModule("keywork-loop", .{
        .root_source_file = b.path("loop/src/event_loop.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all unit tests and formatting checks");
    const loop_tests = b.addTest(.{ .root_module = keywork_loop });
    test_step.dependOn(&b.addRunArtifact(loop_tests).step);

    const wayland_sources = stageWaylandSources(b);
    runtime.add(b, target, optimize, use_llvm, keywork_loop, wayland_sources.wayland_xml, wayland_sources.protocols, test_step);
    compositor.add(b, target, optimize, wayland_sources.wayland_xml, wayland_sources.protocols, test_step);

    const format_paths = &.{
        "build.zig",
        "build.zig.zon",
        "build",
        "loop/src",
        "ui",
        "runtime/src",
        "runtime/examples",
        "lua/src",
        "compositor/src",
    };
    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = format_paths, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);

    const format_step = b.step("format", "Format code");
    const format = b.addFmt(.{ .paths = format_paths });
    format_step.dependOn(&format.step);
}

const WaylandSources = struct {
    wayland_xml: std.Build.LazyPath,
    protocols: std.Build.LazyPath,
};

fn stageWaylandSources(b: *std.Build) WaylandSources {
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
    const stage = b.addSystemCommand(&.{"sh"});
    stage.addFileArg(b.path("scripts/stage-wayland-sources"));
    stage.addArg(pkg_config);
    const output = stage.addOutputDirectoryArg("wayland-sources");
    stage.has_side_effects = true;
    return .{
        .wayland_xml = output.path(b, "wayland.xml"),
        .protocols = output.path(b, "wayland-protocols"),
    };
}
