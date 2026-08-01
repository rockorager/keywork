const std = @import("std");
const Scanner = @import("wayland").Scanner;
const stb = @import("stb.zig");
const ui = @import("ui.zig");

pub const Output = struct {
    module: *std.Build.Module,
    application_control: *std.Build.Module,
    systemd_c: *std.Build.Module,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: ?bool,
    keywork_loop_module: *std.Build.Module,
    wayring_module: *std.Build.Module,
    wayring_protocols_module: *std.Build.Module,
    varlink_module: *std.Build.Module,
    ui_output: ui.Output,
    wayland_xml: std.Build.LazyPath,
    wayland_protocols: std.Build.LazyPath,
    test_step: *std.Build.Step,
) Output {
    const scanner = Scanner.create(b, .{
        .wayland_xml = wayland_xml,
        .wayland_protocols = wayland_protocols,
    });
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("staging/ext-background-effect/ext-background-effect-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addCustomProtocol(b.path("protocols/wayland/upstream/wlr-layer-shell-unstable-v1.xml"));
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
    scanner.generate("ext_background_effect_manager_v1", 1);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    const stb_lib = stb.add(b, target, optimize);

    const image_c = b.addTranslateC(.{
        .root_source_file = b.path("src/runtime/ffi/image_c.h"),
        .target = target,
        .optimize = optimize,
    });
    image_c.addSystemIncludePath(stb_lib.include_dir);
    image_c.step.dependOn(&requirePkgConfigVersion(b, "resvg", "0.47.0").step);
    image_c.linkSystemLibrary("resvg", .{ .use_pkg_config = .force });
    const image_c_module = image_c.createModule();

    const vulkan_mod = b.dependency("runtime_vulkan", .{
        .registry = b.dependency("runtime_vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    const xkb_c = b.addTranslateC(.{
        .root_source_file = b.path("src/runtime/ffi/xkb_c.h"),
        .target = target,
        .optimize = optimize,
    });
    xkb_c.linkSystemLibrary("xkbcommon", .{ .use_pkg_config = .force });
    const xkb_c_module = xkb_c.createModule();

    const systemd_c = b.addTranslateC(.{
        .root_source_file = b.path("src/runtime/ffi/systemd_c.h"),
        .target = target,
        .optimize = optimize,
    });
    // translate-c cannot lower glibc's optimized variadic open wrappers. This
    // affects header translation only; linked libraries keep their hardening.
    systemd_c.defineCMacro("_FORTIFY_SOURCE", "0");
    systemd_c.step.dependOn(&requirePkgConfigVersion(b, "libsystemd", "258").step);
    systemd_c.linkSystemLibrary("libsystemd", .{ .use_pkg_config = .force });
    const systemd_c_module = systemd_c.createModule();

    const text_c = b.addTranslateC(.{
        .root_source_file = b.path("src/runtime/ffi/text_c.h"),
        .target = target,
        .optimize = optimize,
    });
    text_c.linkSystemLibrary("fontconfig", .{ .use_pkg_config = .force });
    text_c.linkSystemLibrary("freetype2", .{ .use_pkg_config = .force });
    text_c.linkSystemLibrary("harfbuzz", .{ .use_pkg_config = .force });
    const text_c_module = text_c.createModule();

    const pixman_c = b.addTranslateC(.{
        .root_source_file = b.path("src/runtime/ffi/pixman_c.h"),
        .target = target,
        .optimize = optimize,
    });
    pixman_c.linkSystemLibrary("pixman-1", .{ .use_pkg_config = .force });
    const pixman_c_module = pixman_c.createModule();

    const application_control = b.addModule("keywork-application-control", .{
        .root_source_file = b.path("src/runtime/app/control_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const keywork_runtime_module = b.addModule("keywork-runtime", .{
        .root_source_file = b.path("src/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    keywork_runtime_module.addImport("keywork-loop", keywork_loop_module);
    keywork_runtime_module.addImport("wayring", wayring_module);
    keywork_runtime_module.addImport("wayring-protocols", wayring_protocols_module);
    keywork_runtime_module.addImport("varlink", varlink_module);
    keywork_runtime_module.addImport("keywork-ui", ui_output.module);
    keywork_runtime_module.addImport("keywork-ui-engine", ui_output.engine_module);
    keywork_runtime_module.addImport("keywork-application-control", application_control);
    keywork_runtime_module.addImport("wayland", wayland_mod);
    keywork_runtime_module.addImport("image_c", image_c_module);
    keywork_runtime_module.linkLibrary(stb_lib.library);
    keywork_runtime_module.linkSystemLibrary("resvg", .{ .use_pkg_config = .force });
    keywork_runtime_module.addImport("vulkan", vulkan_mod);
    keywork_runtime_module.addImport("uucode", ui_output.uucode_module);
    keywork_runtime_module.addImport("xkb_c", xkb_c_module);
    keywork_runtime_module.addImport("systemd_c", systemd_c_module);
    keywork_runtime_module.addImport("text_c", text_c_module);
    keywork_runtime_module.addImport("pixman_c", pixman_c_module);
    keywork_runtime_module.addCSourceFile(.{
        .file = b.path("src/runtime/ffi/application_varlink.c"),
        .flags = &.{"-std=gnu23"},
    });
    keywork_runtime_module.addIncludePath(b.path("src/runtime/ffi"));
    linkKeyworkNativeSystemLibraries(keywork_runtime_module);

    const native_example_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/examples/native/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_example_module.addImport("keywork-loop", keywork_loop_module);
    native_example_module.addImport("keywork-runtime", keywork_runtime_module);
    native_example_module.addImport("keywork-ui", ui_output.module);

    const native_example = b.addExecutable(.{
        .name = "keywork-native-example",
        .root_module = native_example_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    const run_native_example = b.addRunArtifact(native_example);
    const run_native_example_step = b.step("run-native-example", "Run the native Wayland example");
    run_native_example_step.dependOn(&run_native_example.step);

    const fluent_icons = addFluentIcons(b);
    b.installDirectory(.{
        .source_dir = fluent_icons,
        .install_dir = .prefix,
        .install_subdir = "share/icons/Keywork",
    });

    const keywork_runtime_tests = b.addTest(.{
        .root_module = keywork_runtime_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    test_step.dependOn(&b.addRunArtifact(keywork_runtime_tests).step);

    return .{
        .module = keywork_runtime_module,
        .application_control = application_control,
        .systemd_c = systemd_c_module,
    };
}

fn linkKeyworkNativeSystemLibraries(module: *std.Build.Module) void {
    module.linkSystemLibrary("wayland-client", .{});
    module.linkSystemLibrary("wayland-cursor", .{});
    module.linkSystemLibrary("vulkan", .{});
    module.linkSystemLibrary("xkbcommon", .{});
    module.linkSystemLibrary("libsystemd", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("fontconfig", .{});
    module.linkSystemLibrary("freetype", .{});
    module.linkSystemLibrary("harfbuzz", .{});
    module.linkSystemLibrary("pixman-1", .{ .use_pkg_config = .force });
}

fn requirePkgConfigVersion(b: *std.Build, package: []const u8, minimum_version: []const u8) *std.Build.Step.Run {
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
    return b.addSystemCommand(&.{ pkg_config, b.fmt("--atleast-version={s}", .{minimum_version}), package });
}

fn addFluentIcons(b: *std.Build) std.Build.LazyPath {
    const fluent_icons = b.dependency("fluent_icons", .{});
    const python = b.graph.environ_map.get("PYTHON") orelse "python3";
    const generate = b.addSystemCommand(&.{python});
    generate.addFileArg(b.path("scripts/generate-fluent-icons"));
    generate.addDirectoryArg(fluent_icons.path(""));
    generate.addFileArg(b.path("src/runtime/design/fluent/aliases.json"));
    generate.addFileArg(b.path("src/runtime/design/fluent/LICENSE"));
    return generate.addOutputDirectoryArg("Keywork");
}
