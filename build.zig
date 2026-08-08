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
    const wayring_scanner = b.addExecutable(.{
        .name = "wayring-scanner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wayring/scanner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wayring", .module = wayring }},
        }),
    });
    const generate_wayring_fixture = b.addRunArtifact(wayring_scanner);
    generate_wayring_fixture.addFileArg(b.path("src/wayring/checkpoint2.xml"));
    const generated_wayring_source = generate_wayring_fixture.captureStdOut(.{ .basename = "checkpoint2_generated.zig" });
    const generated_wayring = b.createModule(.{
        .root_source_file = generated_wayring_source,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });
    const generated_wayring_check = b.addTest(.{ .root_module = generated_wayring });
    test_wayring_step.dependOn(&b.addRunArtifact(generated_wayring_check).step);
    const generated_wayring_api = b.createModule(.{
        .root_source_file = generated_wayring_source,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });
    const checkpoint2_test_module = b.createModule(.{
        .root_source_file = b.path("src/wayring/checkpoint2_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    checkpoint2_test_module.addImport("generated", generated_wayring_api);
    checkpoint2_test_module.addImport("wayring", wayring);
    const checkpoint2_tests = b.addTest(.{ .root_module = checkpoint2_test_module });
    const run_checkpoint2_tests = b.addRunArtifact(checkpoint2_tests);
    test_wayring_step.dependOn(&run_checkpoint2_tests.step);
    test_step.dependOn(&run_checkpoint2_tests.step);
    const generate_core_protocol = b.addRunArtifact(wayring_scanner);
    generate_core_protocol.addFileArg(b.dependency("wayland_source", .{}).path("protocol/wayland.xml"));
    const generated_core_source = generate_core_protocol.captureStdOut(.{ .basename = "core_protocol.zig" });
    const core_protocol = b.createModule(.{
        .root_source_file = generated_core_source,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });
    const core_protocol_check = b.createModule(.{
        .root_source_file = generated_core_source,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });
    const run_core_protocol_check = b.addRunArtifact(b.addTest(.{ .root_module = core_protocol_check }));
    test_wayring_step.dependOn(&run_core_protocol_check.step);
    test_step.dependOn(&run_core_protocol_check.step);
    const generate_xdg_protocol = b.addRunArtifact(wayring_scanner);
    generate_xdg_protocol.addFileArg(b.dependency("wayland_source", .{}).path("protocol/wayland.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("stable/xdg-shell/xdg-shell.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("unstable/primary-selection/primary-selection-unstable-v1.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("staging/ext-data-control/ext-data-control-v1.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("staging/xdg-activation/xdg-activation-v1.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("stable/viewporter/viewporter.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("staging/fractional-scale/fractional-scale-v1.xml"));
    // Cursor shape refers to the tablet-tool interface in its manager request;
    // tablet is scanner input only and is not published by the generated host.
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("stable/tablet/tablet-v2.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("staging/cursor-shape/cursor-shape-v1.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("unstable/text-input/text-input-unstable-v3.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("staging/ext-idle-notify/ext-idle-notify-v1.xml"));
    generate_xdg_protocol.addFileArg(b.path("protocols/wayland/upstream/input-method-unstable-v2.xml"));
    generate_xdg_protocol.addFileArg(b.path("protocols/wayland/virtual-keyboard-unstable-v1.xml"));
    generate_xdg_protocol.addFileArg(b.path("protocols/wayland/upstream/wlr-layer-shell-unstable-v1.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("staging/ext-session-lock/ext-session-lock-v1.xml"));
    generate_xdg_protocol.addFileArg(b.dependency("wayland_protocols", .{}).path("staging/ext-workspace/ext-workspace-v1.xml"));
    const generated_xdg_source = generate_xdg_protocol.captureStdOut(.{ .basename = "wayring_xdg_protocol.zig" });
    const xdg_protocol = b.createModule(.{
        .root_source_file = generated_xdg_source,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });
    const xdg_protocol_check = b.createModule(.{
        .root_source_file = generated_xdg_source,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });
    const run_xdg_protocol_check = b.addRunArtifact(b.addTest(.{ .root_module = xdg_protocol_check }));
    test_wayring_step.dependOn(&run_xdg_protocol_check.step);
    test_step.dependOn(&run_xdg_protocol_check.step);
    const wayring_example = b.addExecutable(.{
        .name = "wayring-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wayring/example_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "core_protocol", .module = core_protocol },
            },
        }),
    });
    const wayring_example_step = b.step("wayring-example", "Compile the minimal standalone Wayring server example");
    wayring_example_step.dependOn(&wayring_example.step);
    test_wayring_step.dependOn(&wayring_example.step);
    const run_wayring_example = b.addRunArtifact(wayring_example);
    if (b.args) |args| run_wayring_example.addArgs(args);
    const run_wayring_example_step = b.step("run-wayring-example", "Run the once-only Wayring server example");
    run_wayring_example_step.dependOn(&run_wayring_example.step);
    const benchmark_client = b.addExecutable(.{
        .name = "wayring-benchmark-client",
        .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseSafe, .link_libc = true }),
    });
    benchmark_client.root_module.addCSourceFile(.{ .file = b.path("scripts/wayring_benchmark_client.c"), .flags = &.{"-std=c11"} });
    benchmark_client.root_module.linkSystemLibrary("wayland-client", .{ .use_pkg_config = .force });
    const install_benchmark_client = b.addInstallArtifact(benchmark_client, .{ .dest_dir = .{ .override = .{ .custom = "wayring-benchmark" } } });
    const benchmark_server = b.addExecutable(.{
        .name = "wayring-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wayring/example_server.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{ .{ .name = "wayring", .module = wayring }, .{ .name = "core_protocol", .module = core_protocol } },
        }),
    });
    const install_benchmark_server = b.addInstallArtifact(benchmark_server, .{ .dest_dir = .{ .override = .{ .custom = "wayring-benchmark" } } });
    const benchmark_run = b.addSystemCommand(&.{ "python3", "scripts/wayring_benchmark.py" });
    benchmark_run.step.dependOn(&install_benchmark_client.step);
    benchmark_run.step.dependOn(&install_benchmark_server.step);
    if (b.args) |args| benchmark_run.addArgs(args);
    const benchmark_step = b.step("microdiagnostic-wayring", "Non-parity Wayring example/Sway microdiagnostic");
    benchmark_step.dependOn(&benchmark_run.step);
    const checkpoint3_test_module = b.createModule(.{
        .root_source_file = b.path("src/wayring/checkpoint3_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    checkpoint3_test_module.addImport("core_protocol", core_protocol);
    checkpoint3_test_module.addImport("wayring", wayring);
    const checkpoint3_tests = b.addTest(.{ .root_module = checkpoint3_test_module });
    const run_checkpoint3_tests = b.addRunArtifact(checkpoint3_tests);
    test_wayring_step.dependOn(&run_checkpoint3_tests.step);
    test_step.dependOn(&run_checkpoint3_tests.step);
    const shm_protocol_test_module = b.createModule(.{
        .root_source_file = b.path("src/wayring/shm_protocol_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    shm_protocol_test_module.addImport("core_protocol", core_protocol);
    shm_protocol_test_module.addImport("wayring", wayring);
    const run_shm_protocol_tests = b.addRunArtifact(b.addTest(.{ .root_module = shm_protocol_test_module }));
    test_wayring_step.dependOn(&run_shm_protocol_tests.step);
    test_step.dependOn(&run_shm_protocol_tests.step);
    const checkpoint4_test_module = b.createModule(.{
        .root_source_file = b.path("src/wayring/checkpoint4_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    checkpoint4_test_module.addImport("core_protocol", core_protocol);
    checkpoint4_test_module.addImport("wayring", wayring);
    checkpoint4_test_module.linkSystemLibrary("wayland-client", .{ .use_pkg_config = .force });
    const checkpoint4_tests = b.addTest(.{ .root_module = checkpoint4_test_module });
    const run_checkpoint4_tests = b.addRunArtifact(checkpoint4_tests);
    test_wayring_step.dependOn(&run_checkpoint4_tests.step);
    test_step.dependOn(&run_checkpoint4_tests.step);
    const scanner_step = b.step("wayring-scanner", "Build the Wayring protocol scanner");
    scanner_step.dependOn(&wayring_scanner.step);

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
        wayring,
        xdg_protocol,
        wayland,
        wayland.wayland_xml,
        wayland.protocols,
        test_step,
    );
    const parity_run = b.addSystemCommand(&.{ "python3", "scripts/keywork_wayland_benchmark.py" });
    parity_run.step.dependOn(&install_benchmark_client.step);
    parity_run.addArg("--compositor");
    parity_run.addFileArg(compositor_output.executable.getEmittedBin());
    if (b.args) |args| parity_run.addArgs(args);
    const parity_step = b.step("benchmark-wayland-parity", "P3-H same-binary Keywork libwayland/Wayring harness (requires -Doptimize=ReleaseSafe)");
    if (optimize == .ReleaseSafe) {
        parity_step.dependOn(&parity_run.step);
    } else {
        const require_release_safe = b.addSystemCommand(&.{ "sh", "-c", "echo 'benchmark-wayland-parity requires -Doptimize=ReleaseSafe' >&2; exit 2" });
        parity_step.dependOn(&require_release_safe.step);
    }
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
