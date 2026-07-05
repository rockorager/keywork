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

    const libkeywork_module = b.addModule("libkeywork", .{
        .root_source_file = b.path("src/libkeywork.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    libkeywork_module.addImport("wayland", wayland_mod);
    libkeywork_module.linkSystemLibrary("wayland-client", .{});

    const image_c = b.addTranslateC(.{
        .root_source_file = b.path("src/image_c.h"),
        .target = target,
        .optimize = optimize,
    });
    libkeywork_module.addImport("image_c", image_c.createModule());
    libkeywork_module.addCSourceFile(.{ .file = b.path("src/image_impl.c") });

    const vulkan_mod = b.dependency("vulkan_zig", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");
    libkeywork_module.addImport("vulkan", vulkan_mod);
    libkeywork_module.linkSystemLibrary("vulkan", .{});

    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{"grapheme_break"}),
    });
    libkeywork_module.addImport("uucode", uucode_dep.module("uucode"));

    const xkb_c = b.addTranslateC(.{
        .root_source_file = b.path("src/xkb_c.h"),
        .target = target,
        .optimize = optimize,
    });
    xkb_c.linkSystemLibrary("xkbcommon", .{});
    libkeywork_module.addImport("xkb_c", xkb_c.createModule());
    libkeywork_module.linkSystemLibrary("xkbcommon", .{});

    const dbus_c = b.addTranslateC(.{
        .root_source_file = b.path("src/dbus_c.h"),
        .target = target,
        .optimize = optimize,
    });
    dbus_c.linkSystemLibrary("dbus-1", .{});
    libkeywork_module.addImport("dbus_c", dbus_c.createModule());
    libkeywork_module.linkSystemLibrary("dbus-1", .{});

    const text_c = b.addTranslateC(.{
        .root_source_file = b.path("src/text_c.h"),
        .target = target,
        .optimize = optimize,
    });
    text_c.linkSystemLibrary("fontconfig", .{});
    text_c.linkSystemLibrary("freetype", .{});
    text_c.linkSystemLibrary("harfbuzz", .{});
    libkeywork_module.addImport("text_c", text_c.createModule());
    libkeywork_module.linkSystemLibrary("fontconfig", .{});
    libkeywork_module.linkSystemLibrary("freetype", .{});
    libkeywork_module.linkSystemLibrary("harfbuzz", .{});

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_module.addImport("libkeywork", libkeywork_module);

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
    c_api_module.addImport("libkeywork", libkeywork_module);
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
    const c_example = b.addExecutable(.{
        .name = "keywork-c-example",
        .root_module = c_example_module,
    });

    b.installArtifact(native_example);
    b.installArtifact(c_library);
    b.installArtifact(c_example);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const run_lua_layershell_example_cmd = b.addRunArtifact(exe);
    run_lua_layershell_example_cmd.step.dependOn(b.getInstallStep());
    run_lua_layershell_example_cmd.addArgs(&.{
        "--script=examples/lua/layershell.lua",
        "--layer-shell",
        "--anchor=top,left,right",
        "--height=32",
        "--exclusive-zone=32",
    });
    if (b.args) |args| {
        run_lua_layershell_example_cmd.addArgs(args);
    }

    const run_lua_layershell_example_step = b.step("run-lua-layershell-example", "Run the Lua layer-shell example");
    run_lua_layershell_example_step.dependOn(&run_lua_layershell_example_cmd.step);

    const run_lua_vulkan_layershell_example_cmd = b.addRunArtifact(exe);
    run_lua_vulkan_layershell_example_cmd.step.dependOn(b.getInstallStep());
    run_lua_vulkan_layershell_example_cmd.addArgs(&.{
        "--script=examples/lua/layershell.lua",
        "--backend=vulkan",
        "--layer-shell",
        "--anchor=top,left,right",
        "--height=32",
        "--exclusive-zone=32",
    });
    if (b.args) |args| {
        run_lua_vulkan_layershell_example_cmd.addArgs(args);
    }

    const run_lua_vulkan_layershell_example_step = b.step("run-lua-vulkan-layershell-example", "Run the Lua Vulkan layer-shell example");
    run_lua_vulkan_layershell_example_step.dependOn(&run_lua_vulkan_layershell_example_cmd.step);

    const run_lua_bar_example_cmd = b.addRunArtifact(exe);
    run_lua_bar_example_cmd.step.dependOn(b.getInstallStep());
    run_lua_bar_example_cmd.addArgs(&.{
        "--script=examples/lua/bar.lua",
        "--layer-shell",
        "--anchor=top,left,right",
        "--width=0",
        "--height=32",
        "--exclusive-zone=32",
    });
    if (b.args) |args| {
        run_lua_bar_example_cmd.addArgs(args);
    }

    const run_lua_bar_example_step = b.step("run-lua-bar-example", "Run the Lua desktop bar example");
    run_lua_bar_example_step.dependOn(&run_lua_bar_example_cmd.step);

    const run_lua_vulkan_bar_example_cmd = b.addRunArtifact(exe);
    run_lua_vulkan_bar_example_cmd.step.dependOn(b.getInstallStep());
    run_lua_vulkan_bar_example_cmd.addArgs(&.{
        "--script=examples/lua/bar.lua",
        "--backend=vulkan",
        "--layer-shell",
        "--anchor=top,left,right",
        "--width=0",
        "--height=32",
        "--exclusive-zone=32",
    });
    if (b.args) |args| {
        run_lua_vulkan_bar_example_cmd.addArgs(args);
    }

    const run_lua_vulkan_bar_example_step = b.step("run-lua-vulkan-bar-example", "Run the Lua Vulkan desktop bar example");
    run_lua_vulkan_bar_example_step.dependOn(&run_lua_vulkan_bar_example_cmd.step);

    const run_native_example_cmd = b.addRunArtifact(native_example);
    run_native_example_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_native_example_cmd.addArgs(args);
    }

    const run_native_example_step = b.step("run-native-example", "Run the native Zig example");
    run_native_example_step.dependOn(&run_native_example_cmd.step);

    const run_c_example_cmd = b.addRunArtifact(c_example);
    run_c_example_cmd.step.dependOn(b.getInstallStep());

    const run_c_example_step = b.step("run-c-example", "Run the C example");
    run_c_example_step.dependOn(&run_c_example_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = libkeywork_module,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "examples", "include", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);
}
