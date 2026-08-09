const std = @import("std");
const static_wayland = @import("static_wayland.zig");
const Scanner = @import("wayland").Scanner;

pub const Output = struct {
    executable: *std.Build.Step.Compile,
    keyworkctl_adapter: *std.Build.Module,
    keyworkctl_tests: *std.Build.Step,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
    varlink: *std.Build.Module,
    control: *std.Build.Module,
    wayring: *std.Build.Module,
    wayring_protocol: *std.Build.Module,
    wayland_libraries: static_wayland.Output,
    wayland_xml: std.Build.LazyPath,
    wayland_protocols: std.Build.LazyPath,
    test_step: *std.Build.Step,
    test_wayring_step: *std.Build.Step,
) Output {
    const scanner = Scanner.create(b, .{
        .wayland_xml = wayland_xml,
        .wayland_protocols = wayland_protocols,
    });
    const vulkan = b.dependency("compositor_vulkan", .{
        .registry = b.dependency("compositor_vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/primary-selection/primary-selection-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/text-input/text-input-unstable-v3.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("stable/presentation-time/presentation-time.xml");
    scanner.addSystemProtocol("stable/linux-dmabuf/linux-dmabuf-v1.xml");
    scanner.addSystemProtocol("staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml");
    scanner.addSystemProtocol("staging/tearing-control/tearing-control-v1.xml");
    scanner.addSystemProtocol("staging/fifo/fifo-v1.xml");
    scanner.addSystemProtocol("staging/commit-timing/commit-timing-v1.xml");
    scanner.addSystemProtocol("staging/xdg-toplevel-drag/xdg-toplevel-drag-v1.xml");
    scanner.addSystemProtocol("staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml");
    scanner.addSystemProtocol("staging/xdg-dialog/xdg-dialog-v1.xml");
    scanner.addSystemProtocol("staging/xdg-system-bell/xdg-system-bell-v1.xml");
    scanner.addSystemProtocol("staging/xdg-toplevel-tag/xdg-toplevel-tag-v1.xml");
    scanner.addSystemProtocol("staging/xdg-session-management/xdg-session-management-v1.xml");
    scanner.addSystemProtocol("staging/ext-transient-seat/ext-transient-seat-v1.xml");
    scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");
    scanner.addSystemProtocol("staging/single-pixel-buffer/single-pixel-buffer-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/content-type/content-type-v1.xml");
    scanner.addSystemProtocol("staging/color-management/color-management-v1.xml");
    scanner.addSystemProtocol("staging/color-representation/color-representation-v1.xml");
    scanner.addSystemProtocol("staging/alpha-modifier/alpha-modifier-v1.xml");
    scanner.addSystemProtocol("staging/security-context/security-context-v1.xml");
    scanner.addSystemProtocol("staging/drm-lease/drm-lease-v1.xml");
    scanner.addSystemProtocol("staging/ext-background-effect/ext-background-effect-v1.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("staging/ext-idle-notify/ext-idle-notify-v1.xml");
    scanner.addSystemProtocol("staging/ext-data-control/ext-data-control-v1.xml");
    scanner.addSystemProtocol("staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml");
    scanner.addSystemProtocol("staging/ext-image-capture-source/ext-image-capture-source-v1.xml");
    scanner.addSystemProtocol("staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml");
    scanner.addSystemProtocol("staging/ext-workspace/ext-workspace-v1.xml");
    scanner.addSystemProtocol("staging/xwayland-shell/xwayland-shell-v1.xml");
    scanner.addSystemProtocol("unstable/xwayland-keyboard-grab/xwayland-keyboard-grab-unstable-v1.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/relative-pointer/relative-pointer-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addSystemProtocol("staging/pointer-warp/pointer-warp-v1.xml");
    scanner.addSystemProtocol("unstable/idle-inhibit/idle-inhibit-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-foreign/xdg-foreign-unstable-v2.xml");
    scanner.addSystemProtocol("unstable/xdg-output/xdg-output-unstable-v1.xml");
    scanner.addCustomProtocol(b.path("protocols/wayland/upstream/input-method-unstable-v2.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/upstream/wlr-data-control-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/upstream/wlr-foreign-toplevel-management-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/wlr-output-management-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/wlr-screencopy-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/gtk-shell.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/virtual-keyboard-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/upstream/wlr-virtual-pointer-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/upstream/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/upstream/wlr-output-power-management-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/upstream/wlr-gamma-control-unstable-v1.xml"));
    scanner.generate("wl_compositor", 7);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 2);
    scanner.generate("wl_fixes", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 10);
    scanner.generate("wl_data_device_manager", 4);
    scanner.generate("xdg_wm_base", 7);
    scanner.generate("zxdg_decoration_manager_v1", 2);
    scanner.generate("zwp_primary_selection_device_manager_v1", 1);
    scanner.generate("zwp_text_input_manager_v3", 2);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("wp_presentation", 2);
    scanner.generate("zwp_linux_dmabuf_v1", 6);
    scanner.generate("wp_linux_drm_syncobj_manager_v1", 1);
    scanner.generate("wp_tearing_control_manager_v1", 1);
    scanner.generate("wp_fifo_manager_v1", 1);
    scanner.generate("wp_commit_timing_manager_v1", 1);
    scanner.generate("xdg_toplevel_drag_manager_v1", 1);
    scanner.generate("xdg_toplevel_icon_manager_v1", 1);
    scanner.generate("xdg_wm_dialog_v1", 1);
    scanner.generate("xdg_system_bell_v1", 1);
    scanner.generate("xdg_toplevel_tag_manager_v1", 1);
    scanner.generate("xdg_session_manager_v1", 1);
    scanner.generate("ext_transient_seat_manager_v1", 1);
    scanner.generate("xdg_activation_v1", 1);
    scanner.generate("wp_single_pixel_buffer_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 2);
    scanner.generate("wp_content_type_manager_v1", 1);
    scanner.generate("wp_color_manager_v1", 3);
    scanner.generate("wp_color_representation_manager_v1", 1);
    scanner.generate("wp_alpha_modifier_v1", 1);
    scanner.generate("wp_security_context_manager_v1", 1);
    scanner.generate("wp_drm_lease_device_v1", 1);
    scanner.generate("ext_background_effect_manager_v1", 1);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("ext_idle_notifier_v1", 2);
    scanner.generate("ext_data_control_manager_v1", 1);
    scanner.generate("ext_foreign_toplevel_list_v1", 1);
    scanner.generate("ext_output_image_capture_source_manager_v1", 1);
    scanner.generate("ext_foreign_toplevel_image_capture_source_manager_v1", 1);
    scanner.generate("ext_image_copy_capture_manager_v1", 1);
    scanner.generate("ext_workspace_manager_v1", 1);
    scanner.generate("xwayland_shell_v1", 1);
    scanner.generate("zwp_xwayland_keyboard_grab_manager_v1", 1);
    scanner.generate("zwp_tablet_manager_v2", 2);
    scanner.generate("zwp_pointer_gestures_v1", 3);
    scanner.generate("zwp_relative_pointer_manager_v1", 1);
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.generate("wp_pointer_warp_v1", 1);
    scanner.generate("zwp_idle_inhibit_manager_v1", 1);
    scanner.generate("zwp_keyboard_shortcuts_inhibit_manager_v1", 1);
    scanner.generate("zxdg_exporter_v2", 1);
    scanner.generate("zxdg_importer_v2", 1);
    scanner.generate("zxdg_output_manager_v1", 3);
    scanner.generate("zwp_input_method_manager_v2", 1);
    scanner.generate("zwp_virtual_keyboard_manager_v1", 1);
    scanner.generate("zwlr_virtual_pointer_manager_v1", 2);
    scanner.generate("zwlr_data_control_manager_v1", 2);
    scanner.generate("zwlr_foreign_toplevel_manager_v1", 3);
    scanner.generate("zwlr_output_manager_v1", 4);
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    scanner.generate("gtk_shell1", 5);
    scanner.generate("zwlr_layer_shell_v1", 5);
    scanner.generate("zwlr_output_power_manager_v1", 1);
    scanner.generate("zwlr_gamma_control_manager_v1", 1);

    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    const compositor = b.createModule(.{
        .root_source_file = b.path("src/compositor/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    compositor.addOptions("build-options", build_options);
    compositor.addImport("keywork-control", control);
    compositor.addImport("varlink", varlink);
    compositor.addImport("wayring", wayring);
    compositor.addImport("wayring-protocol", wayring_protocol);
    compositor.addImport("wayland", wayland);
    compositor.addImport("vulkan", vulkan);
    compositor.addAnonymousImport("default-config", .{
        .root_source_file = b.path("src/compositor/resources/keywork.conf"),
    });
    addRendererShaders(b, compositor);
    linkSystemLibraries(compositor);
    wayland_libraries.linkClientAndServer(compositor);

    const exe = b.addExecutable(.{
        .name = "keywork-compositor",
        .root_module = compositor,
    });
    exe.each_lib_rpath = false;
    const keyworkctl_adapter = b.addModule("keyworkctl-compositor", .{
        .root_source_file = b.path("src/compositor/keyworkctl/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    keyworkctl_adapter.addImport("varlink", varlink);
    keyworkctl_adapter.addImport("keywork-control", control);

    b.installArtifact(exe);
    b.installFile(
        "src/compositor/resources/keywork-session.target",
        "share/systemd/user/keywork-session.target",
    );
    b.installFile(
        "src/compositor/resources/keywork-xdg-autostart.service",
        "share/systemd/user/keywork-xdg-autostart.service",
    );
    b.installFile(
        "src/compositor/resources/keywork-xdg-autostart.target",
        "share/systemd/user/keywork-xdg-autostart.target",
    );
    b.installFile(
        "src/compositor/resources/keywork.desktop",
        "share/wayland-sessions/keywork.desktop",
    );
    b.installFile(
        "src/compositor/resources/keywork-portals.conf",
        "share/xdg-desktop-portal/keywork-portals.conf",
    );
    b.installFile(
        "src/compositor/resources/keywork.conf",
        "share/keywork/keywork.conf",
    );
    addGdmSessionInstallStep(b);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run-compositor", "Run the compositor");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = compositor,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    const security_context_tests = b.createModule(.{
        .root_source_file = b.path("src/compositor/wayring_security_context_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayring", .module = wayring },
            .{ .name = "wayring-protocol", .module = wayring_protocol },
            .{ .name = "wayland", .module = wayland },
        },
    });
    security_context_tests.linkSystemLibrary("pixman-1", .{});
    security_context_tests.linkSystemLibrary("ffi", .{});
    wayland_libraries.linkClientAndServer(security_context_tests);
    const run_security_context_tests = b.addRunArtifact(b.addTest(.{ .root_module = security_context_tests }));
    test_step.dependOn(&run_security_context_tests.step);
    test_wayring_step.dependOn(&run_security_context_tests.step);
    const transient_seat_tests = b.createModule(.{
        .root_source_file = b.path("src/compositor/wayring_transient_seat_test_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayring", .module = wayring },
            .{ .name = "wayring-protocol", .module = wayring_protocol },
            .{ .name = "wayland", .module = wayland },
        },
    });
    transient_seat_tests.linkSystemLibrary("pixman-1", .{});
    transient_seat_tests.linkSystemLibrary("ffi", .{});
    wayland_libraries.linkClientAndServer(transient_seat_tests);
    const run_transient_seat_tests = b.addRunArtifact(b.addTest(.{ .root_module = transient_seat_tests }));
    test_step.dependOn(&run_transient_seat_tests.step);
    test_wayring_step.dependOn(&run_transient_seat_tests.step);
    const keyworkctl_tests = b.addTest(.{ .root_module = keyworkctl_adapter });
    const run_keyworkctl_tests = b.addRunArtifact(keyworkctl_tests);
    test_step.dependOn(&run_keyworkctl_tests.step);

    const renderer_conformance_tests = b.addTest(.{
        .root_module = compositor,
        .filters = &.{"renderer conformance:"},
    });
    const renderer_conformance_run = b.addRunArtifact(renderer_conformance_tests);

    const renderer_scene_tests = b.addTest(.{
        .root_module = compositor,
        .filters = &.{"reproducible scene:"},
    });
    const renderer_scene_run = b.addRunArtifact(renderer_scene_tests);

    const renderer_check_step = b.step(
        "renderer-check",
        "Run renderer conformance and reproducible scene tests",
    );
    renderer_check_step.dependOn(&renderer_conformance_run.step);
    renderer_check_step.dependOn(&renderer_scene_run.step);

    const cpu_benchmark_module = b.createModule(.{
        .root_source_file = b.path("src/compositor/cpu_benchmark_root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    cpu_benchmark_module.linkSystemLibrary("pixman-1", .{});
    const cpu_benchmark = b.addExecutable(.{
        .name = "cpu-renderer-benchmark",
        .root_module = cpu_benchmark_module,
    });
    const benchmark_run = b.addRunArtifact(cpu_benchmark);
    const benchmark_step = b.step(
        "benchmark-cpu-renderer",
        "Benchmark the ReleaseFast Pixman CPU renderer",
    );
    benchmark_step.dependOn(&benchmark_run.step);
    return .{
        .executable = exe,
        .keyworkctl_adapter = keyworkctl_adapter,
        .keyworkctl_tests = &run_keyworkctl_tests.step,
    };
}

fn addGdmSessionInstallStep(b: *std.Build) void {
    const compositor_path = b.getInstallPath(.bin, "keywork-compositor");
    const session = b.addWriteFiles().add(
        "keywork.desktop",
        b.fmt(
            \\[Desktop Entry]
            \\Name=Keywork
            \\Comment=Keywork Wayland desktop
            \\Exec={s}
            \\Type=Application
            \\DesktopNames=keywork
            \\
        , .{compositor_path}),
    );

    const session_dir = b.option(
        []const u8,
        "wayland-session-dir",
        "System Wayland session directory",
    ) orelse "/usr/local/share/wayland-sessions";
    const destdir = b.graph.environ_map.get("DESTDIR") orelse "";
    const install_session = if (destdir.len == 0)
        b.addSystemCommand(&.{ b.graph.environ_map.get("SUDO") orelse "sudo", "install", "-Dm0644" })
    else
        b.addSystemCommand(&.{ "install", "-Dm0644" });
    install_session.addFileArg(session);
    install_session.addArg(b.fmt(
        "{s}{s}/keywork.desktop",
        .{ destdir, std.mem.trimEnd(u8, session_dir, "/") },
    ));
    install_session.has_side_effects = true;

    const install_session_step = b.step(
        "install-gdm-session",
        "Install a system-visible GDM session for the selected prefix",
    );
    install_session_step.dependOn(&install_session.step);
}

fn addRendererShaders(b: *std.Build, module: *std.Build.Module) void {
    addVulkanShader(b, module, "vulkan-quad", "src/compositor/render/shaders/quad.vert");
    addVulkanShader(b, module, "vulkan-solid", "src/compositor/render/shaders/solid.frag");
    addVulkanShader(b, module, "vulkan-image", "src/compositor/render/shaders/image.frag");
    addVulkanShaderVariant(b, module, "vulkan-crossfade", "src/compositor/render/shaders/image.frag", &.{"KEYWORK_CROSSFADE"});
    addVulkanShaderVariant(b, module, "vulkan-image-nearest", "src/compositor/render/shaders/image.frag", &.{"KEYWORK_NEAREST"});
    addVulkanShaderVariant(b, module, "vulkan-image-nearest-gamma22", "src/compositor/render/shaders/image.frag", &.{ "KEYWORK_NEAREST", "KEYWORK_TRANSFER_GAMMA22" });
    addVulkanShaderVariant(b, module, "vulkan-backdrop-image", "src/compositor/render/shaders/image.frag", &.{"KEYWORK_BACKDROP"});
    addVulkanShaderVariant(b, module, "vulkan-image-catmull-rom", "src/compositor/render/shaders/image.frag", &.{"KEYWORK_CATMULL_ROM"});
    addVulkanShaderVariant(b, module, "vulkan-image-area", "src/compositor/render/shaders/image.frag", &.{"KEYWORK_AREA"});
    addVulkanShaderVariant(b, module, "vulkan-video-manual", "src/compositor/render/shaders/image.frag", &.{"KEYWORK_MANUAL_YCBCR"});
    addVulkanShader(b, module, "vulkan-shadow", "src/compositor/render/shaders/shadow.frag");
    addVulkanShader(b, module, "vulkan-blur-downsample", "src/compositor/render/shaders/blur_downsample.frag");
    addVulkanShader(b, module, "vulkan-blur-upsample", "src/compositor/render/shaders/blur_upsample.frag");
    addVulkanShader(b, module, "vulkan-encode", "src/compositor/render/shaders/encode.frag");
    addVulkanShader(b, module, "vulkan-encode-calibrated", "src/compositor/render/shaders/encode_calibrated.frag");
}

fn linkSystemLibraries(module: *std.Build.Module) void {
    module.linkSystemLibrary("lcms2", .{});
    module.linkSystemLibrary("libdisplay-info", .{});
    module.linkSystemLibrary("libdrm", .{});
    module.linkSystemLibrary("gbm", .{});
    module.linkSystemLibrary("libinput", .{});
    module.linkSystemLibrary("pixman-1", .{});
    module.linkSystemLibrary("xcursor", .{});
    module.linkSystemLibrary("libseat", .{});
    module.linkSystemLibrary("libsystemd", .{});
    module.linkSystemLibrary("libudev", .{});
    module.linkSystemLibrary("ffi", .{});
    module.linkSystemLibrary("m", .{});
    module.linkSystemLibrary("xkbcommon", .{});
    module.linkSystemLibrary("xcb", .{});
    module.linkSystemLibrary("xcb-composite", .{});
    module.linkSystemLibrary("xcb-icccm", .{});
    module.linkSystemLibrary("xcb-res", .{});
    module.linkSystemLibrary("xcb-xfixes", .{});
}

fn addVulkanShader(
    b: *std.Build,
    module: *std.Build.Module,
    name: []const u8,
    source_path: []const u8,
) void {
    addVulkanShaderVariant(b, module, name, source_path, &.{});
}

fn addVulkanShaderVariant(
    b: *std.Build,
    module: *std.Build.Module,
    name: []const u8,
    source_path: []const u8,
    defines: []const []const u8,
) void {
    const compile = b.addSystemCommand(&.{ "glslc", "-O" });
    for (defines) |value| compile.addArg(b.fmt("-D{s}", .{value}));
    compile.addFileArg(b.path(source_path));
    compile.addArg("-o");
    const spirv = compile.addOutputFileArg(b.fmt("{s}.spv", .{name}));
    module.addAnonymousImport(name, .{ .root_source_file = spirv });
}
