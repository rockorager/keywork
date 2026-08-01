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
    const wayring = b.addModule("wayring", .{
        .root_source_file = b.path("src/wayring/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wayring_uring = b.addModule("wayring-uring", .{
        .root_source_file = b.path("src/wayring/IoUringTransport.zig"),
        .target = target,
        .optimize = optimize,
    });
    wayring_uring.addImport("wayring", wayring);
    wayring_uring.addImport("keywork-loop", keywork_loop);
    const wayring_core = b.addModule("wayring-core", .{
        .root_source_file = b.path("src/wayring/core_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    wayring_core.addImport("wayring", wayring);
    const wayland = static_wayland.add(b, target, optimize);
    const zig_wayland = b.dependency("wayland", .{});
    const wayring_xml = b.createModule(.{
        .root_source_file = zig_wayland.path("src/xml.zig"),
        .target = b.graph.host,
    });
    const wayring_scanner_module = b.createModule(.{
        .root_source_file = b.path("src/wayring/scanner.zig"),
        .target = b.graph.host,
    });
    wayring_scanner_module.addImport("xml", wayring_xml);
    const wayring_scanner = b.addExecutable(.{
        .name = "wayring-scanner",
        .root_module = wayring_scanner_module,
    });
    const generate_wayring_protocols = b.addRunArtifact(wayring_scanner);
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.wayland_xml);
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "stable/xdg-shell/xdg-shell.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "unstable/primary-selection/primary-selection-unstable-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "stable/presentation-time/presentation-time.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/content-type/content-type-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/alpha-modifier/alpha-modifier-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/single-pixel-buffer/single-pixel-buffer-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/xdg-system-bell/xdg-system-bell-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/tearing-control/tearing-control-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/fifo/fifo-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/commit-timing/commit-timing-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "stable/linux-dmabuf/linux-dmabuf-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "stable/tablet/tablet-v2.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "unstable/relative-pointer/relative-pointer-unstable-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/cursor-shape/cursor-shape-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/xdg-activation/xdg-activation-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "stable/viewporter/viewporter.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/fractional-scale/fractional-scale-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/ext-session-lock/ext-session-lock-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "staging/xwayland-shell/xwayland-shell-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(wayland.protocols.path(b, "unstable/xwayland-keyboard-grab/xwayland-keyboard-grab-unstable-v1.xml"));
    generate_wayring_protocols.addArg("-i");
    generate_wayring_protocols.addFileArg(b.path("protocols/wayland/upstream/wlr-layer-shell-unstable-v1.xml"));
    generate_wayring_protocols.addArg("-o");
    const wayring_protocol_source = generate_wayring_protocols.addOutputFileArg("wayring-protocols.zig");
    const wayring_protocols = b.addModule("wayring-protocols", .{
        .root_source_file = wayring_protocol_source,
        .target = target,
        .optimize = optimize,
    });
    wayring_protocols.addImport("wayring", wayring);
    wayring_core.addImport("wayring-protocols", wayring_protocols);
    const wayring_server = b.addModule("wayring-server", .{
        .root_source_file = b.path("src/wayring/Server.zig"),
        .target = target,
        .optimize = optimize,
    });
    wayring_server.addImport("wayring", wayring);
    wayring_server.addImport("wayring-core", wayring_core);
    const wayring_server_uring = b.addModule("wayring-server-uring", .{
        .root_source_file = b.path("src/wayring/IoUringServer.zig"),
        .target = target,
        .optimize = optimize,
    });
    wayring_server_uring.addImport("keywork-loop", keywork_loop);
    wayring_server_uring.addImport("wayring", wayring);
    wayring_server_uring.addImport("wayring-core", wayring_core);
    wayring_server_uring.addImport("wayring-server", wayring_server);
    wayring_server_uring.addImport("wayring-uring", wayring_uring);
    const varlink = b.addModule("varlink", .{
        .root_source_file = b.path("src/varlink/root.zig"),
        .target = target,
        .optimize = optimize,
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
    const wayring_test_step = b.step("test-wayring", "Run Wayring protocol and transport tests");
    const loop_tests = b.addTest(.{ .root_module = keywork_loop });
    test_step.dependOn(&b.addRunArtifact(loop_tests).step);
    const wayring_tests = b.addTest(.{ .root_module = wayring });
    wayring_test_step.dependOn(&b.addRunArtifact(wayring_tests).step);
    const wayring_uring_tests = b.addTest(.{ .root_module = wayring_uring });
    wayring_test_step.dependOn(&b.addRunArtifact(wayring_uring_tests).step);
    const wayring_core_test_module = b.createModule(.{
        .root_source_file = b.path("src/wayring/core_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    wayring_core_test_module.addImport("wayring", wayring);
    wayring_core_test_module.addImport("wayring-uring", wayring_uring);
    wayring_core_test_module.addImport("keywork-loop", keywork_loop);
    wayring_core_test_module.addImport("wayring-protocols", wayring_protocols);
    const wayring_core_tests = b.addTest(.{ .root_module = wayring_core_test_module });
    wayring_test_step.dependOn(&b.addRunArtifact(wayring_core_tests).step);
    const wayring_scanner_test_module = b.createModule(.{
        .root_source_file = b.path("src/wayring/scanner.zig"),
        .target = b.graph.host,
    });
    wayring_scanner_test_module.addImport("xml", wayring_xml);
    const wayring_scanner_tests = b.addTest(.{ .root_module = wayring_scanner_test_module });
    wayring_test_step.dependOn(&b.addRunArtifact(wayring_scanner_tests).step);
    const wayring_server_tests = b.addTest(.{ .root_module = wayring_server });
    wayring_test_step.dependOn(&b.addRunArtifact(wayring_server_tests).step);
    const wayring_server_uring_tests = b.addTest(.{ .root_module = wayring_server_uring });
    wayring_test_step.dependOn(&b.addRunArtifact(wayring_server_uring_tests).step);
    test_step.dependOn(wayring_test_step);
    const varlink_tests = b.addTest(.{ .root_module = varlink });
    test_step.dependOn(&b.addRunArtifact(varlink_tests).step);

    const lint_step = b.step("lint", "Run all static analysis");
    const check_step = b.step("check", "Run all tests and static analysis");
    check_step.dependOn(test_step);
    check_step.dependOn(lint_step);

    const wayring_protocol_tests = b.addTest(.{ .root_module = wayring_protocols });
    wayring_test_step.dependOn(&b.addRunArtifact(wayring_protocol_tests).step);
    const wayring_presenter_test_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/backend/wayring/DmaBufPresenter.zig"),
        .target = target,
        .optimize = optimize,
    });
    wayring_presenter_test_module.addImport("wayring", wayring);
    wayring_presenter_test_module.addImport("wayring-protocols", wayring_protocols);
    const wayring_presenter_tests = b.addTest(.{ .root_module = wayring_presenter_test_module });
    wayring_test_step.dependOn(&b.addRunArtifact(wayring_presenter_tests).step);
    const wayring_client_test_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/backend/wayring/Client.zig"),
        .target = target,
        .optimize = optimize,
    });
    wayring_client_test_module.addImport("keywork-loop", keywork_loop);
    wayring_client_test_module.addImport("wayring", wayring);
    wayring_client_test_module.addImport("wayring-uring", wayring_uring);
    wayring_client_test_module.addImport("wayring-protocols", wayring_protocols);
    const wayring_client_tests = b.addTest(.{ .root_module = wayring_client_test_module });
    wayring_test_step.dependOn(&b.addRunArtifact(wayring_client_tests).step);
    const wayring_clipboard_test_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/backend/wayring/Clipboard.zig"),
        .target = target,
        .optimize = optimize,
    });
    wayring_clipboard_test_module.addImport("keywork-loop", keywork_loop);
    wayring_clipboard_test_module.addImport("wayring", wayring);
    wayring_clipboard_test_module.addImport("wayring-uring", wayring_uring);
    wayring_clipboard_test_module.addImport("wayring-protocols", wayring_protocols);
    const wayring_clipboard_tests = b.addTest(.{ .root_module = wayring_clipboard_test_module });
    wayring_test_step.dependOn(&b.addRunArtifact(wayring_clipboard_tests).step);
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
        wayring,
        wayring_uring,
        wayring_protocols,
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
        keywork_loop,
        wayring,
        wayring_core,
        wayring_server,
        wayring_server_uring,
        wayring_protocols,
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
