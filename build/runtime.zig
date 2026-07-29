const std = @import("std");
const Scanner = @import("wayland").Scanner;
const luajit = @import("luajit.zig");
const stb = @import("stb.zig");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: ?bool,
    keywork_loop_module: *std.Build.Module,
    wayland_xml: std.Build.LazyPath,
    wayland_protocols: std.Build.LazyPath,
    test_step: *std.Build.Step,
) void {
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
    scanner.addCustomProtocol(b.path("runtime/protocols/wlr-layer-shell-unstable-v1.xml"));
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
        .root_source_file = b.path("runtime/src/ffi/image_c.h"),
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

    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = b.path("ui/lib/linebreak/uucode_config.zig"),
    });
    const uucode_module = uucode_dep.module("uucode");

    const linebreak_module = b.addModule("linebreak", .{
        .root_source_file = b.path("ui/lib/linebreak/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linebreak_module.addImport("uucode", uucode_module);

    const z2d_dep = b.dependency("z2d", .{
        .target = target,
        .optimize = optimize,
    });
    const z2d_module = z2d_dep.module("z2d");

    const keywork_ui_module = b.addModule("keywork-ui", .{
        .root_source_file = b.path("ui/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    keywork_ui_module.addImport("uucode", uucode_module);
    keywork_ui_module.addImport("linebreak", linebreak_module);
    keywork_ui_module.addImport("z2d", z2d_module);

    const keywork_ui_engine_module = b.addModule("keywork-ui-engine", .{
        .root_source_file = b.path("ui/engine/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    keywork_ui_engine_module.addImport("keywork-ui", keywork_ui_module);
    keywork_ui_engine_module.addImport("uucode", uucode_module);

    const xkb_c = b.addTranslateC(.{
        .root_source_file = b.path("runtime/src/ffi/xkb_c.h"),
        .target = target,
        .optimize = optimize,
    });
    xkb_c.linkSystemLibrary("xkbcommon", .{ .use_pkg_config = .force });
    const xkb_c_module = xkb_c.createModule();

    const systemd_c = b.addTranslateC(.{
        .root_source_file = b.path("runtime/src/ffi/systemd_c.h"),
        .target = target,
        .optimize = optimize,
    });
    systemd_c.step.dependOn(&requirePkgConfigVersion(b, "libsystemd", "257").step);
    systemd_c.linkSystemLibrary("libsystemd", .{ .use_pkg_config = .force });
    const systemd_c_module = systemd_c.createModule();

    const curl_c = b.addTranslateC(.{
        .root_source_file = b.path("lua/src/ffi/curl_c.h"),
        .target = target,
        .optimize = optimize,
    });
    curl_c.step.dependOn(&requirePkgConfigVersion(b, "libcurl", "7.45.0").step);
    curl_c.linkSystemLibrary("libcurl", .{ .use_pkg_config = .force });
    const curl_c_module = curl_c.createModule();

    const pipewire_c = b.addTranslateC(.{
        .root_source_file = b.path("lua/src/ffi/pipewire_c.h"),
        .target = target,
        .optimize = optimize,
    });
    const pipewire_c_module = pipewire_c.createModule();

    const text_c = b.addTranslateC(.{
        .root_source_file = b.path("runtime/src/ffi/text_c.h"),
        .target = target,
        .optimize = optimize,
    });
    text_c.linkSystemLibrary("fontconfig", .{ .use_pkg_config = .force });
    text_c.linkSystemLibrary("freetype2", .{ .use_pkg_config = .force });
    text_c.linkSystemLibrary("harfbuzz", .{ .use_pkg_config = .force });
    const text_c_module = text_c.createModule();

    const pixman_c = b.addTranslateC(.{
        .root_source_file = b.path("runtime/src/ffi/pixman_c.h"),
        .target = target,
        .optimize = optimize,
    });
    pixman_c.linkSystemLibrary("pixman-1", .{ .use_pkg_config = .force });
    const pixman_c_module = pixman_c.createModule();

    const lua = luajit.add(b, target, optimize);

    const keywork_runtime_module = b.addModule("keywork-runtime", .{
        .root_source_file = b.path("runtime/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    keywork_runtime_module.addImport("keywork-loop", keywork_loop_module);
    keywork_runtime_module.addImport("keywork-ui", keywork_ui_module);
    keywork_runtime_module.addImport("keywork-ui-engine", keywork_ui_engine_module);
    keywork_runtime_module.addImport("wayland", wayland_mod);
    keywork_runtime_module.addImport("image_c", image_c_module);
    keywork_runtime_module.linkLibrary(stb_lib.library);
    keywork_runtime_module.linkSystemLibrary("resvg", .{ .use_pkg_config = .force });
    keywork_runtime_module.addImport("vulkan", vulkan_mod);
    keywork_runtime_module.addImport("uucode", uucode_module);
    keywork_runtime_module.addImport("xkb_c", xkb_c_module);
    keywork_runtime_module.addImport("systemd_c", systemd_c_module);
    keywork_runtime_module.addImport("text_c", text_c_module);
    keywork_runtime_module.addImport("pixman_c", pixman_c_module);
    linkKeyworkNativeSystemLibraries(keywork_runtime_module);

    const native_example_module = b.createModule(.{
        .root_source_file = b.path("runtime/examples/native/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_example_module.addImport("keywork-loop", keywork_loop_module);
    native_example_module.addImport("keywork-runtime", keywork_runtime_module);
    native_example_module.addImport("keywork-ui", keywork_ui_module);

    const native_example = b.addExecutable(.{
        .name = "keywork-native-example",
        .root_module = native_example_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    const native_example_step = b.step("native-example", "Build the native Wayland example");
    native_example_step.dependOn(&native_example.step);
    const run_native_example = b.addRunArtifact(native_example);
    const run_native_example_step = b.step("run-native-example", "Run the native Wayland example");
    run_native_example_step.dependOn(&run_native_example.step);

    const keywork_lua_module = b.addModule("keywork-lua", .{
        .root_source_file = b.path("lua/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    keywork_lua_module.addImport("keywork-runtime", keywork_runtime_module);
    keywork_lua_module.addImport("keywork-loop", keywork_loop_module);
    keywork_lua_module.addImport("keywork-ui", keywork_ui_module);
    keywork_lua_module.addImport("keywork-ui-engine", keywork_ui_engine_module);
    keywork_lua_module.addImport("image_c", image_c_module);
    keywork_lua_module.addImport("systemd_c", systemd_c_module);
    keywork_lua_module.addImport("curl_c", curl_c_module);
    keywork_lua_module.addImport("pipewire_c", pipewire_c_module);
    keywork_lua_module.addCSourceFile(.{ .file = b.path("lua/src/ffi/pipewire_c.c") });
    keywork_lua_module.linkSystemLibrary("libpipewire-0.3", .{ .use_pkg_config = .force });
    keywork_lua_module.linkSystemLibrary("libcurl", .{ .use_pkg_config = .force });

    const luajit_c = b.addTranslateC(.{
        .root_source_file = b.path("lua/src/ffi/luajit_c.h"),
        .target = target,
        .optimize = optimize,
    });
    luajit_c.addIncludePath(lua.include_dir);
    luajit_c.addIncludePath(lua.generated_include_dir);
    keywork_lua_module.addImport("luajit_c", luajit_c.createModule());
    keywork_lua_module.linkLibrary(lua.library);

    const app_module = b.createModule(.{
        .root_source_file = b.path("lua/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_module.addImport("keywork-lua", keywork_lua_module);
    app_module.addImport("keywork-runtime", keywork_runtime_module);
    app_module.addImport("keywork-loop", keywork_loop_module);
    app_module.addImport("keywork-ui", keywork_ui_module);
    app_module.addImport("keywork-ui-engine", keywork_ui_engine_module);

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
    b.installDirectory(.{
        .source_dir = b.path("lua/types"),
        .install_dir = .prefix,
        .install_subdir = "share/keywork/emmylua",
        .include_extensions = &.{".lua"},
    });
    b.installDirectory(.{
        .source_dir = b.path("runtime/resources/icons"),
        .install_dir = .prefix,
        .install_subdir = "share/icons",
    });

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run a Lua application (pass -- <script.lua>)");
    run_step.dependOn(&run_cmd.step);

    // Window options come from the script's keywork.window declaration.
    addExampleRunStep(b, exe, "run-lua-layershell-example", "Run the Lua layer-shell example", "lua/examples/layershell.lua", &.{});
    addExampleRunStep(b, exe, "run-lua-vulkan-layershell-example", "Run the Lua Vulkan layer-shell example", "lua/examples/layershell.lua", &.{"--backend=vulkan"});
    addExampleRunStep(b, exe, "run-lua-bar-example", "Run the Lua desktop bar example", "lua/examples/bar.lua", &.{});
    addExampleRunStep(b, exe, "run-lua-vulkan-bar-example", "Run the Lua Vulkan desktop bar example", "lua/examples/bar.lua", &.{"--backend=vulkan"});
    addExampleRunStep(b, exe, "run-lua-shell-example", "Run the Lua desktop shell example", "lua/examples/shell.lua", &.{});

    const app_tests = b.addTest(.{
        .root_module = app_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    app_tests.rdynamic = true;
    test_step.dependOn(&b.addRunArtifact(app_tests).step);
    const keywork_lua_tests = b.addTest(.{
        .root_module = keywork_lua_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    keywork_lua_tests.rdynamic = true;
    test_step.dependOn(&b.addRunArtifact(keywork_lua_tests).step);
    const keywork_runtime_tests = b.addTest(.{
        .root_module = keywork_runtime_module,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    test_step.dependOn(&b.addRunArtifact(keywork_runtime_tests).step);
    const keywork_ui_tests = b.addTest(.{ .root_module = keywork_ui_module });
    test_step.dependOn(&b.addRunArtifact(keywork_ui_tests).step);
    const keywork_ui_engine_tests = b.addTest(.{ .root_module = keywork_ui_engine_module });
    test_step.dependOn(&b.addRunArtifact(keywork_ui_engine_tests).step);
    const linebreak_tests = b.addTest(.{ .root_module = linebreak_module });
    test_step.dependOn(&b.addRunArtifact(linebreak_tests).step);
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

fn addExampleRunStep(b: *std.Build, exe: *std.Build.Step.Compile, name: []const u8, description: []const u8, script: []const u8, fixed_args: []const []const u8) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPrefixedFileArg("--script=", b.path(script));
    run_cmd.addArgs(fixed_args);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}
