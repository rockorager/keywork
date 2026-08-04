const std = @import("std");
const compositor = @import("build/compositor.zig");
const keyworkctl = @import("build/keyworkctl.zig");
const lua_host = @import("build/lua.zig");
const luajit = @import("build/luajit.zig");
const release = @import("build/release.zig");
const runtime = @import("build/runtime.zig");
const shell = @import("build/shell.zig");
const static_wayland = @import("build/static_wayland.zig");
const stream = @import("build/stream.zig");
const ui = @import("build/ui.zig");
const version = @import("build/version.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Escape hatch for toolchains where the self-hosted linker cannot link
    // system CRT objects (e.g. .sframe sections from GCC 16's crt1.o).
    const use_llvm = b.option(bool, "llvm", "Use the LLVM backend and LLD linker");

    const keywork_loop = b.addModule("keywork-loop", .{
        .root_source_file = b.path("src/loop/event_loop.zig"),
        .target = target,
        .optimize = optimize,
    });
    const varlink = b.addModule("varlink", .{
        .root_source_file = b.path("src/varlink/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wayring = b.addModule("wayring", .{
        .root_source_file = b.path("src/wayring/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const keywork_control = b.addModule("keywork-control", .{
        .root_source_file = b.path("src/compositor/control/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    keywork_control.addAnonymousImport("control-interface", .{
        .root_source_file = b.path("src/compositor/protocol/varlink/dev.rockorager.keywork.compositor.varlink"),
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version.string);

    const test_step = b.step("test", "Run all unit tests and formatting checks");
    const loop_tests = b.addTest(.{ .root_module = keywork_loop });
    test_step.dependOn(&b.addRunArtifact(loop_tests).step);
    const varlink_tests = b.addTest(.{ .root_module = varlink });
    test_step.dependOn(&b.addRunArtifact(varlink_tests).step);
    const wayring_tests = b.addTest(.{ .root_module = wayring });
    const run_wayring_tests = b.addRunArtifact(wayring_tests);
    test_step.dependOn(&run_wayring_tests.step);
    const test_wayring_step = b.step("test-wayring", "Run Wayring tests");
    test_wayring_step.dependOn(&run_wayring_tests.step);

    const lint_step = b.step("lint", "Run all static analysis");
    const check_step = b.step("check", "Run all tests and static analysis");
    check_step.dependOn(test_step);
    check_step.dependOn(lint_step);

    const wayland = static_wayland.add(b, target, optimize);
    const stream_output = stream.add(
        b,
        target,
        optimize,
        build_options,
        wayland,
        wayland.wayland_xml,
        wayland.protocols,
        test_step,
    );
    const ui_output = ui.add(b, target, optimize, test_step);
    const runtime_output = runtime.add(
        b,
        target,
        optimize,
        use_llvm,
        keywork_loop,
        varlink,
        ui_output,
        wayland.wayland_xml,
        wayland.protocols,
        test_step,
    );
    const lua_jit = luajit.add(b, target, optimize);
    const lua_output = lua_host.add(
        b,
        target,
        optimize,
        use_llvm,
        keywork_loop,
        ui_output,
        runtime_output,
        lua_jit,
        test_step,
    );
    const compositor_output = compositor.add(
        b,
        target,
        optimize,
        build_options,
        varlink,
        keywork_control,
        wayland,
        wayland.wayland_xml,
        wayland.protocols,
        test_step,
    );
    release.add(
        b,
        target,
        optimize,
        version.string,
        compositor_output.executable,
        stream_output,
    );
    keyworkctl.add(
        b,
        target,
        optimize,
        compositor_output.keyworkctl_adapter,
        runtime_output.application_control,
        varlink,
        compositor_output.keyworkctl_tests,
        test_step,
    );

    const format_paths = &.{
        "build.zig",
        "build.zig.zon",
        "build",
        "src",
    };
    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = format_paths, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);

    const format_step = b.step("format", "Format code");
    const format = b.addFmt(.{ .paths = format_paths });
    format_step.dependOn(&format.step);

    shell.add(
        b,
        target,
        optimize,
        use_llvm,
        lua_jit,
        lua_output.executable,
        wayland.protocols,
        test_step,
        lint_step,
        fmt_step,
        format_step,
    );
}
