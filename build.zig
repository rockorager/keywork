const std = @import("std");
const Scanner = @import("wayland").Scanner;
const luajit = @import("build/luajit.zig");
const nanosvg = @import("build/nanosvg.zig");
const stb = @import("build/stb.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 8);
    scanner.generate("wl_output", 4);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("zwlr_layer_shell_v1", 5);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("zwp_tablet_manager_v2", 1);
    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    const nanosvg_lib = nanosvg.add(b, target, optimize);
    const stb_lib = stb.add(b, target, optimize);

    const image_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ffi/image_c.h"),
        .target = target,
        .optimize = optimize,
    });
    image_c.addSystemIncludePath(nanosvg_lib.include_dir);
    image_c.addSystemIncludePath(stb_lib.include_dir);
    const image_c_module = image_c.createModule();

    const vulkan_mod = b.dependency("vulkan_zig", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{"grapheme_break"}),
    });
    const uucode_module = uucode_dep.module("uucode");

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
    addPkgConfigIncludePaths(b, xkb_c, &.{"xkbcommon"});
    const xkb_c_module = xkb_c.createModule();

    const dbus_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ffi/dbus_c.h"),
        .target = target,
        .optimize = optimize,
    });
    addPkgConfigIncludePaths(b, dbus_c, &.{"dbus-1"});
    const dbus_c_module = dbus_c.createModule();

    const text_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ffi/text_c.h"),
        .target = target,
        .optimize = optimize,
    });
    addPkgConfigIncludePaths(b, text_c, &.{ "fontconfig", "freetype2", "harfbuzz" });
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
    app_module.linkLibrary(nanosvg_lib.library);
    app_module.linkLibrary(stb_lib.library);
    app_module.addImport("vulkan", vulkan_mod);
    app_module.addImport("uucode", uucode_module);
    app_module.addImport("z2d", z2d_module);
    app_module.addImport("xkb_c", xkb_c_module);
    app_module.addImport("dbus_c", dbus_c_module);
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
    });
    // Lua C modules resolve the statically linked LuaJIT API from the host
    // executable when dlopen loads them.
    exe.rdynamic = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    // Window options come from the script's keywork.window declaration.
    const run_lua_layershell_example_cmd = b.addRunArtifact(exe);
    run_lua_layershell_example_cmd.addArgs(&.{
        "--script=examples/lua/layershell.lua",
    });
    if (b.args) |args| {
        run_lua_layershell_example_cmd.addArgs(args);
    }

    const run_lua_layershell_example_step = b.step("run-lua-layershell-example", "Run the Lua layer-shell example");
    run_lua_layershell_example_step.dependOn(&run_lua_layershell_example_cmd.step);

    const run_lua_vulkan_layershell_example_cmd = b.addRunArtifact(exe);
    run_lua_vulkan_layershell_example_cmd.addArgs(&.{
        "--script=examples/lua/layershell.lua",
        "--backend=vulkan",
    });
    if (b.args) |args| {
        run_lua_vulkan_layershell_example_cmd.addArgs(args);
    }

    const run_lua_vulkan_layershell_example_step = b.step("run-lua-vulkan-layershell-example", "Run the Lua Vulkan layer-shell example");
    run_lua_vulkan_layershell_example_step.dependOn(&run_lua_vulkan_layershell_example_cmd.step);

    const run_lua_bar_example_cmd = b.addRunArtifact(exe);
    run_lua_bar_example_cmd.addArgs(&.{
        "--script=examples/lua/bar.lua",
    });
    if (b.args) |args| {
        run_lua_bar_example_cmd.addArgs(args);
    }

    const run_lua_bar_example_step = b.step("run-lua-bar-example", "Run the Lua desktop bar example");
    run_lua_bar_example_step.dependOn(&run_lua_bar_example_cmd.step);

    const run_lua_vulkan_bar_example_cmd = b.addRunArtifact(exe);
    run_lua_vulkan_bar_example_cmd.addArgs(&.{
        "--script=examples/lua/bar.lua",
        "--backend=vulkan",
    });
    if (b.args) |args| {
        run_lua_vulkan_bar_example_cmd.addArgs(args);
    }

    const run_lua_vulkan_bar_example_step = b.step("run-lua-vulkan-bar-example", "Run the Lua Vulkan desktop bar example");
    run_lua_vulkan_bar_example_step.dependOn(&run_lua_vulkan_bar_example_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const app_tests = b.addTest(.{
        .root_module = app_module,
    });
    app_tests.rdynamic = true;
    test_step.dependOn(&b.addRunArtifact(app_tests).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "examples", "build", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);
}

fn linkKeyworkSystemLibraries(module: *std.Build.Module) void {
    module.linkSystemLibrary("wayland-client", .{});
    module.linkSystemLibrary("vulkan", .{});
    module.linkSystemLibrary("xkbcommon", .{});
    module.linkSystemLibrary("dbus-1", .{});
    module.linkSystemLibrary("fontconfig", .{});
    module.linkSystemLibrary("freetype", .{});
    module.linkSystemLibrary("harfbuzz", .{});
}

fn addPkgConfigIncludePaths(b: *std.Build, translate_c: *std.Build.Step.TranslateC, packages: []const []const u8) void {
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(b.allocator);

    argv.append(b.allocator, pkg_config) catch @panic("OOM");
    argv.append(b.allocator, "--cflags-only-I") catch @panic("OOM");
    for (packages) |package| argv.append(b.allocator, package) catch @panic("OOM");

    const cflags = b.run(argv.items);
    var it = std.mem.tokenizeAny(u8, cflags, " \t\r\n");
    while (it.next()) |flag| {
        if (!std.mem.startsWith(u8, flag, "-I")) continue;
        if (flag.len == 2) continue;
        const include_path = b.allocator.dupe(u8, flag[2..]) catch @panic("OOM");
        translate_c.addSystemIncludePath(.{ .cwd_relative = include_path });
    }
}
