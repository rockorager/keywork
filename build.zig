const std = @import("std");
const Scanner = @import("wayland").Scanner;
const luajit = @import("build/luajit.zig");
const stb = @import("build/stb.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Escape hatch for toolchains where the self-hosted linker cannot link
    // system CRT objects (e.g. .sframe sections from GCC 16's crt1.o).
    const use_llvm = b.option(bool, "llvm", "Use the LLVM backend and LLD linker");

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    // Generate current core surface events, then negotiate every global down
    // to the version advertised by the compositor at runtime.
    scanner.generate("wl_compositor", 7);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 8);
    scanner.generate("wl_output", 4);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("zwlr_layer_shell_v1", 5);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("zwp_tablet_manager_v2", 1);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_activation_v1", 1);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    const stb_lib = stb.add(b, target, optimize);

    const image_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ffi/image_c.h"),
        .target = target,
        .optimize = optimize,
    });
    image_c.addSystemIncludePath(stb_lib.include_dir);
    requirePkgConfigVersion(b, "resvg", "0.47.0");
    image_c.linkSystemLibrary("resvg", .{ .use_pkg_config = .force });
    const image_c_module = image_c.createModule();

    const vulkan_mod = b.dependency("vulkan_zig", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = b.path("lib/linebreak/uucode_config.zig"),
    });
    const uucode_module = uucode_dep.module("uucode");

    const linebreak_module = b.addModule("linebreak", .{
        .root_source_file = b.path("lib/linebreak/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linebreak_module.addImport("uucode", uucode_module);

    const z2d_dep = b.dependency("z2d", .{
        .target = target,
        .optimize = optimize,
    });
    const z2d_module = z2d_dep.module("z2d");

    const xkb_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ffi/xkb_c.h"),
        .target = target,
        .optimize = optimize,
    });
    xkb_c.linkSystemLibrary("xkbcommon", .{ .use_pkg_config = .force });
    const xkb_c_module = xkb_c.createModule();

    const dbus_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ffi/dbus_c.h"),
        .target = target,
        .optimize = optimize,
    });
    dbus_c.linkSystemLibrary("dbus-1", .{ .use_pkg_config = .force });
    const dbus_c_module = dbus_c.createModule();

    const pipewire_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ffi/pipewire_c.h"),
        .target = target,
        .optimize = optimize,
    });
    const pipewire_c_module = pipewire_c.createModule();

    const text_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ffi/text_c.h"),
        .target = target,
        .optimize = optimize,
    });
    text_c.linkSystemLibrary("fontconfig", .{ .use_pkg_config = .force });
    text_c.linkSystemLibrary("freetype2", .{ .use_pkg_config = .force });
    text_c.linkSystemLibrary("harfbuzz", .{ .use_pkg_config = .force });
    const text_c_module = text_c.createModule();

    const lua = luajit.add(b, target, optimize);

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_module.addImport("wayland", wayland_mod);
    app_module.addImport("image_c", image_c_module);
    app_module.linkLibrary(stb_lib.library);
    app_module.linkSystemLibrary("resvg", .{ .use_pkg_config = .force });
    app_module.addImport("vulkan", vulkan_mod);
    app_module.addImport("uucode", uucode_module);
    app_module.addImport("linebreak", linebreak_module);
    app_module.addImport("z2d", z2d_module);
    app_module.addImport("xkb_c", xkb_c_module);
    app_module.addImport("dbus_c", dbus_c_module);
    app_module.addImport("pipewire_c", pipewire_c_module);
    app_module.addCSourceFile(.{ .file = b.path("src/ffi/pipewire_c.c") });
    app_module.linkSystemLibrary("libpipewire-0.3", .{ .use_pkg_config = .force });
    app_module.addImport("text_c", text_c_module);
    linkKeyworkSystemLibraries(app_module);

    const luajit_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ffi/luajit_c.h"),
        .target = target,
        .optimize = optimize,
    });
    luajit_c.addIncludePath(lua.include_dir);
    luajit_c.addIncludePath(lua.generated_include_dir);
    app_module.addImport("luajit_c", luajit_c.createModule());
    app_module.linkLibrary(lua.library);

    const exe = b.addExecutable(.{
        .name = "keywork",
        .root_module = app_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    // Lua C modules resolve the statically linked LuaJIT API from the host
    // executable when dlopen loads them.
    exe.rdynamic = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run a Lua application (pass -- <script.lua>)");
    run_step.dependOn(&run_cmd.step);

    // Window options come from the script's keywork.window declaration.
    addExampleRunStep(b, exe, "run-lua-layershell-example", "Run the Lua layer-shell example", &.{
        "--script=examples/lua/layershell.lua",
    });
    addExampleRunStep(b, exe, "run-lua-vulkan-layershell-example", "Run the Lua Vulkan layer-shell example", &.{
        "--script=examples/lua/layershell.lua",
        "--backend=vulkan",
    });
    addExampleRunStep(b, exe, "run-lua-bar-example", "Run the Lua desktop bar example", &.{
        "--script=examples/lua/bar.lua",
    });
    addExampleRunStep(b, exe, "run-lua-vulkan-bar-example", "Run the Lua Vulkan desktop bar example", &.{
        "--script=examples/lua/bar.lua",
        "--backend=vulkan",
    });
    addExampleRunStep(b, exe, "run-lua-shell-example", "Run the Lua desktop shell example", &.{
        "--script=examples/lua/shell.lua",
    });

    const test_step = b.step("test", "Run unit tests");
    const app_tests = b.addTest(.{
        .root_module = app_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    app_tests.rdynamic = true;
    test_step.dependOn(&b.addRunArtifact(app_tests).step);
    const linebreak_tests = b.addTest(.{ .root_module = linebreak_module });
    test_step.dependOn(&b.addRunArtifact(linebreak_tests).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "lib", "examples", "build", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);
}

fn linkKeyworkSystemLibraries(module: *std.Build.Module) void {
    module.linkSystemLibrary("wayland-client", .{});
    module.linkSystemLibrary("wayland-cursor", .{});
    module.linkSystemLibrary("vulkan", .{});
    module.linkSystemLibrary("xkbcommon", .{});
    module.linkSystemLibrary("dbus-1", .{});
    module.linkSystemLibrary("fontconfig", .{});
    module.linkSystemLibrary("freetype", .{});
    module.linkSystemLibrary("harfbuzz", .{});
}

fn requirePkgConfigVersion(b: *std.Build, package: []const u8, minimum_version: []const u8) void {
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
    _ = b.run(&.{ pkg_config, b.fmt("--atleast-version={s}", .{minimum_version}), package });
}

fn addExampleRunStep(b: *std.Build, exe: *std.Build.Step.Compile, name: []const u8, description: []const u8, fixed_args: []const []const u8) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addArgs(fixed_args);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}
