const std = @import("std");
const Scanner = @import("wayland").Scanner;

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

    const image_c = b.addTranslateC(.{
        .root_source_file = b.path("src/image_c.h"),
        .target = target,
        .optimize = optimize,
    });
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
        .root_source_file = b.path("src/xkb_c.h"),
        .target = target,
        .optimize = optimize,
    });
    addPkgConfigIncludePaths(b, xkb_c, &.{"xkbcommon"});
    const xkb_c_module = xkb_c.createModule();

    const dbus_c = b.addTranslateC(.{
        .root_source_file = b.path("src/dbus_c.h"),
        .target = target,
        .optimize = optimize,
    });
    addPkgConfigIncludePaths(b, dbus_c, &.{"dbus-1"});
    const dbus_c_module = dbus_c.createModule();

    const text_c = b.addTranslateC(.{
        .root_source_file = b.path("src/text_c.h"),
        .target = target,
        .optimize = optimize,
    });
    addPkgConfigIncludePaths(b, text_c, &.{ "fontconfig", "freetype2", "harfbuzz" });
    const text_c_module = text_c.createModule();

    const libkeywork_imports: LibkeyworkImports = .{
        .wayland = wayland_mod,
        .image_c = image_c_module,
        .vulkan = vulkan_mod,
        .uucode = uucode_module,
        .z2d = z2d_module,
        .xkb_c = xkb_c_module,
        .dbus_c = dbus_c_module,
        .text_c = text_c_module,
    };

    const libkeywork_module = b.addModule("libkeywork", .{
        .root_source_file = b.path("src/libkeywork.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addLibkeyworkImports(b, libkeywork_module, libkeywork_imports);
    linkKeyworkSystemLibraries(libkeywork_module);

    const libkeywork_static_module = b.createModule(.{
        .root_source_file = b.path("src/libkeywork.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addLibkeyworkImports(b, libkeywork_static_module, libkeywork_imports);

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_module.addImport("libkeywork", libkeywork_module);
    app_module.addImport("dbus_c", dbus_c_module);

    const luajit_c = b.addTranslateC(.{
        .root_source_file = b.path("src/luajit_c.h"),
        .target = target,
        .optimize = optimize,
    });
    luajit_c.linkSystemLibrary("luajit", .{});
    app_module.addImport("luajit_c", luajit_c.createModule());
    app_module.linkSystemLibrary("luajit", .{});

    const exe = b.addExecutable(.{
        .name = "keywork",
        .root_module = app_module,
    });

    b.installArtifact(exe);

    const native_example_module = b.createModule(.{
        .root_source_file = b.path("examples/native/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_example_module.addImport("libkeywork", libkeywork_module);
    const native_example = b.addExecutable(.{
        .name = "keywork-native-example",
        .root_module = native_example_module,
    });

    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_module.addImport("libkeywork", libkeywork_static_module);
    const c_library = b.addLibrary(.{
        .linkage = .static,
        .name = "keywork",
        .root_module = c_api_module,
    });
    c_library.installHeader(b.path("include/keywork.h"), "keywork.h");

    const c_example_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_example_module.addCSourceFile(.{ .file = b.path("examples/c/main.c") });
    c_example_module.addIncludePath(b.path("include"));
    c_example_module.linkLibrary(c_library);
    linkKeyworkSystemLibraries(c_example_module);
    const c_example = b.addExecutable(.{
        .name = "keywork-c-example",
        .root_module = c_example_module,
    });

    b.installArtifact(native_example);
    b.installArtifact(c_library);
    b.installArtifact(c_example);

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

    const run_native_example_cmd = b.addRunArtifact(native_example);
    if (b.args) |args| {
        run_native_example_cmd.addArgs(args);
    }

    const run_native_example_step = b.step("run-native-example", "Run the native Zig example");
    run_native_example_step.dependOn(&run_native_example_cmd.step);

    const run_c_example_cmd = b.addRunArtifact(c_example);

    const run_c_example_step = b.step("run-c-example", "Run the C example");
    run_c_example_step.dependOn(&run_c_example_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = libkeywork_module,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const app_tests = b.addTest(.{
        .root_module = app_module,
    });
    test_step.dependOn(&b.addRunArtifact(app_tests).step);

    const c_api_test_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_test_module.addImport("libkeywork", libkeywork_static_module);
    linkKeyworkSystemLibraries(c_api_test_module);
    const c_api_tests = b.addTest(.{
        .root_module = c_api_test_module,
    });
    test_step.dependOn(&b.addRunArtifact(c_api_tests).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "examples", "include", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);
}

const LibkeyworkImports = struct {
    wayland: *std.Build.Module,
    image_c: *std.Build.Module,
    vulkan: *std.Build.Module,
    uucode: *std.Build.Module,
    z2d: *std.Build.Module,
    xkb_c: *std.Build.Module,
    dbus_c: *std.Build.Module,
    text_c: *std.Build.Module,
};

fn addLibkeyworkImports(b: *std.Build, module: *std.Build.Module, imports: LibkeyworkImports) void {
    module.addImport("wayland", imports.wayland);
    module.addImport("image_c", imports.image_c);
    module.addCSourceFile(.{ .file = b.path("src/image_impl.c") });
    module.addCSourceFile(.{ .file = b.path("third_party/stb/stb_image.c") });
    module.addCSourceFile(.{ .file = b.path("third_party/stb/stb_image_resize.c") });
    module.addImport("vulkan", imports.vulkan);
    module.addImport("uucode", imports.uucode);
    module.addImport("z2d", imports.z2d);
    module.addImport("xkb_c", imports.xkb_c);
    module.addImport("dbus_c", imports.dbus_c);
    module.addImport("text_c", imports.text_c);
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
