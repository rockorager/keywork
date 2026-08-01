const std = @import("std");
const luajit = @import("luajit.zig");
const runtime = @import("runtime.zig");
const ui = @import("ui.zig");

pub const Output = struct {
    executable: *std.Build.Step.Compile,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: ?bool,
    keywork_loop_module: *std.Build.Module,
    ui_output: ui.Output,
    runtime_output: runtime.Output,
    lua_jit: luajit.LuaJit,
    test_step: *std.Build.Step,
) Output {
    const curl_c = b.addTranslateC(.{
        .root_source_file = b.path("src/lua/ffi/curl_c.h"),
        .target = target,
        .optimize = optimize,
    });
    curl_c.step.dependOn(&requirePkgConfigVersion(b, "libcurl", "7.45.0").step);
    curl_c.linkSystemLibrary("libcurl", .{ .use_pkg_config = .force });
    const curl_c_module = curl_c.createModule();

    const pipewire_c = b.addTranslateC(.{
        .root_source_file = b.path("src/lua/ffi/pipewire_c.h"),
        .target = target,
        .optimize = optimize,
    });
    const pipewire_c_module = pipewire_c.createModule();

    const keywork_lua_module = b.addModule("keywork-lua", .{
        .root_source_file = b.path("src/lua/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    keywork_lua_module.addImport("keywork-runtime", runtime_output.module);
    keywork_lua_module.addImport("keywork-loop", keywork_loop_module);
    keywork_lua_module.addImport("keywork-ui", ui_output.module);
    keywork_lua_module.addImport("keywork-ui-engine", ui_output.engine_module);
    keywork_lua_module.addImport("systemd_c", runtime_output.systemd_c);
    keywork_lua_module.addImport("curl_c", curl_c_module);
    keywork_lua_module.addImport("pipewire_c", pipewire_c_module);
    keywork_lua_module.addCSourceFile(.{ .file = b.path("src/lua/ffi/pipewire_c.c") });
    keywork_lua_module.linkSystemLibrary("libpipewire-0.3", .{ .use_pkg_config = .force });
    keywork_lua_module.linkSystemLibrary("libcurl", .{ .use_pkg_config = .force });

    const luajit_c = b.addTranslateC(.{
        .root_source_file = b.path("src/lua/ffi/luajit_c.h"),
        .target = target,
        .optimize = optimize,
    });
    luajit_c.addIncludePath(lua_jit.include_dir);
    luajit_c.addIncludePath(lua_jit.generated_include_dir);
    keywork_lua_module.addImport("luajit_c", luajit_c.createModule());
    keywork_lua_module.linkLibrary(lua_jit.library);

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/lua/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_module.addImport("keywork-lua", keywork_lua_module);
    app_module.addImport("keywork-runtime", runtime_output.module);
    app_module.addImport("keywork-loop", keywork_loop_module);
    app_module.addImport("keywork-ui", ui_output.module);
    app_module.addImport("keywork-ui-engine", ui_output.engine_module);

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
        .source_dir = b.path("src/lua/types"),
        .install_dir = .prefix,
        .install_subdir = "share/keywork/emmylua",
        .include_extensions = &.{".lua"},
    });

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run a Lua application (pass -- <script.lua>)");
    run_step.dependOn(&run_cmd.step);

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

    return .{ .executable = exe };
}

fn requirePkgConfigVersion(b: *std.Build, package: []const u8, minimum_version: []const u8) *std.Build.Step.Run {
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
    return b.addSystemCommand(&.{ pkg_config, b.fmt("--atleast-version={s}", .{minimum_version}), package });
}
