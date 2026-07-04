const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 8);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    const libkeywork_module = b.addModule("libkeywork", .{
        .root_source_file = b.path("src/libkeywork.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    libkeywork_module.addImport("wayland", wayland_mod);
    libkeywork_module.linkSystemLibrary("wayland-client", .{});

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

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = libkeywork_module,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);
}
