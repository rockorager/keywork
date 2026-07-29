const std = @import("std");
const luajit = @import("luajit.zig");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: ?bool,
    lua: luajit.LuaJit,
    keywork: *std.Build.Step.Compile,
    wayland_protocols: std.Build.LazyPath,
    test_step: *std.Build.Step,
    lint_step: *std.Build.Step,
    fmt_step: *std.Build.Step,
    format_step: *std.Build.Step,
) void {
    const auth_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    auth_module.addIncludePath(lua.include_dir);
    auth_module.addIncludePath(lua.generated_include_dir);
    auth_module.addCSourceFile(.{
        .file = b.path("src/shell/native/auth.c"),
        .flags = c_flags,
    });
    auth_module.linkSystemLibrary("pam", .{ .use_pkg_config = .force });
    const auth = b.addLibrary(.{
        .name = "keywork-shell-auth",
        .root_module = auth_module,
        .linkage = .dynamic,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    auth.linker_allow_shlib_undefined = true;

    const scanner = b.graph.environ_map.get("WAYLAND_SCANNER") orelse "wayland-scanner";
    const idle = scanProtocol(
        b,
        scanner,
        wayland_protocols.path(b, "staging/ext-idle-notify/ext-idle-notify-v1.xml"),
        "ext-idle-notify-v1",
    );
    const workspace = scanProtocol(
        b,
        scanner,
        wayland_protocols.path(b, "staging/ext-workspace/ext-workspace-v1.xml"),
        "ext-workspace-v1",
    );
    const output_power = scanProtocol(
        b,
        scanner,
        b.path("protocols/wayland/upstream/wlr-output-power-management-unstable-v1.xml"),
        "wlr-output-power-management-unstable-v1",
    );

    const wayland_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wayland_module.addIncludePath(lua.include_dir);
    wayland_module.addIncludePath(lua.generated_include_dir);
    inline for (.{ idle, workspace, output_power }) |protocol| {
        wayland_module.addIncludePath(protocol.header.dirname());
        wayland_module.addCSourceFile(.{ .file = protocol.code, .flags = c_flags });
    }
    wayland_module.addCSourceFile(.{
        .file = b.path("src/shell/native/wayland.c"),
        .flags = c_flags,
    });
    wayland_module.linkSystemLibrary("wayland-client", .{ .use_pkg_config = .force });
    const wayland = b.addLibrary(.{
        .name = "keywork-shell-wayland",
        .root_module = wayland_module,
        .linkage = .dynamic,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    wayland.linker_allow_shlib_undefined = true;

    const shell_step = b.step("shell", "Build and validate the desktop shell");
    shell_step.dependOn(&auth.step);
    shell_step.dependOn(&wayland.step);
    addLuaChecks(b, shell_step);
    test_step.dependOn(shell_step);
    b.getInstallStep().dependOn(shell_step);

    const shell_lint = b.addSystemCommand(&.{b.graph.environ_map.get("EMMYLUA_CHECK") orelse "emmylua_check"});
    shell_lint.setCwd(b.path("src/shell"));
    shell_lint.addDirectoryArg(b.path("src/shell/lua"));
    shell_lint.addDirectoryArg(b.path("src/lua/types"));
    shell_lint.addDirectoryArg(b.path("src/shell/types"));
    shell_lint.addArgs(&.{"--config"});
    shell_lint.addFileArg(b.path("src/shell/.emmyrc.json"));
    shell_lint.addArg("--warnings-as-errors");
    const shell_lint_step = b.step("lint-shell", "Run shell static analysis");
    shell_lint_step.dependOn(&shell_lint.step);
    lint_step.dependOn(shell_lint_step);

    const lua_formatter = b.graph.environ_map.get("LUAFMT") orelse "luafmt";
    const shell_fmt = addLuaFormat(b, lua_formatter, true);
    const shell_fmt_step = b.step("fmt-shell", "Check shell formatting");
    shell_fmt_step.dependOn(&shell_fmt.step);
    fmt_step.dependOn(shell_fmt_step);

    const shell_format = addLuaFormat(b, lua_formatter, false);
    const shell_format_step = b.step("format-shell", "Format shell sources");
    shell_format_step.dependOn(&shell_format.step);
    format_step.dependOn(shell_format_step);

    const install_auth = b.addInstallArtifact(auth, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = "share/keywork-shell/lua/shell/auth.so",
        .h_dir = .disabled,
    });
    const install_wayland = b.addInstallArtifact(wayland, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = "share/keywork-shell/lua/shell/wayland.so",
        .h_dir = .disabled,
    });
    const install_lua = b.addInstallDirectory(.{
        .source_dir = b.path("src/shell/lua"),
        .install_dir = .prefix,
        .install_subdir = "share/keywork-shell/lua",
        .include_extensions = &.{".lua"},
    });
    const install_launcher = b.addInstallFileWithDir(
        b.path("src/shell/bin/keywork-shell"),
        .bin,
        "keywork-shell",
    );
    const install_service = b.addInstallFileWithDir(
        b.path("src/shell/keywork-shell.service"),
        .prefix,
        "share/systemd/user/keywork-shell.service",
    );
    inline for (.{
        &install_auth.step,
        &install_wayland.step,
        &install_lua.step,
        &install_launcher.step,
        &install_service.step,
    }) |install| b.getInstallStep().dependOn(install);

    const run_shell = b.addSystemCommand(&.{"env"});
    run_shell.addArg(b.fmt("KEYWORK_SHELL_DATADIR={s}", .{
        b.getInstallPath(.prefix, "share/keywork-shell"),
    }));
    run_shell.addPrefixedFileArg("KEYWORK_SHELL_KEYWORK=", keywork.getEmittedBin());
    run_shell.addFileArg(b.path("src/shell/bin/keywork-shell"));
    if (b.args) |args| run_shell.addArgs(args);
    run_shell.step.dependOn(shell_step);
    inline for (.{
        &install_auth.step,
        &install_wayland.step,
        &install_lua.step,
    }) |install| run_shell.step.dependOn(install);
    const run_shell_step = b.step("run-shell", "Run the desktop shell");
    run_shell_step.dependOn(&run_shell.step);

    const pam_dir = b.option([]const u8, "pam-dir", "PAM service directory") orelse "/etc/pam.d";
    const destdir = b.graph.environ_map.get("DESTDIR") orelse "";
    const install_pam = b.addSystemCommand(&.{ "install", "-Dm0644" });
    install_pam.addFileArg(b.path("src/shell/pam/keywork-shell"));
    install_pam.addArg(b.fmt("{s}{s}/keywork-shell", .{ destdir, std.mem.trimEnd(u8, pam_dir, "/") }));
    install_pam.has_side_effects = true;
    const install_pam_step = b.step("install-pam", "Install the shell PAM service (may require root)");
    install_pam_step.dependOn(&install_pam.step);
}

const Protocol = struct {
    header: std.Build.LazyPath,
    code: std.Build.LazyPath,
};

fn scanProtocol(
    b: *std.Build,
    scanner: []const u8,
    xml: std.Build.LazyPath,
    basename: []const u8,
) Protocol {
    const header = b.addSystemCommand(&.{ scanner, "client-header" });
    header.addFileArg(xml);
    const header_output = header.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{basename}));

    const code = b.addSystemCommand(&.{ scanner, "private-code" });
    code.addFileArg(xml);
    const code_output = code.addOutputFileArg(b.fmt("{s}-protocol.c", .{basename}));

    return .{ .header = header_output, .code = code_output };
}

fn addLuaChecks(b: *std.Build, shell_step: *std.Build.Step) void {
    const interpreter = b.graph.environ_map.get("LUAJIT") orelse "luajit";
    inline for (lua_files) |file| {
        const check = b.addSystemCommand(&.{ interpreter, "-b" });
        check.addFileArg(b.path("src/shell/" ++ file));
        _ = check.addOutputFileArg("check.luac");
        shell_step.dependOn(&check.step);
    }
}

fn addLuaFormat(b: *std.Build, formatter: []const u8, check: bool) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{formatter});
    run.addArg(if (check) "--check" else "--write");
    run.addArgs(&.{ "--recursive", "--config" });
    run.addFileArg(b.path("src/shell/.luafmt.toml"));
    run.addDirectoryArg(b.path("src/shell/lua"));
    run.addDirectoryArg(b.path("src/shell/types"));
    if (!check) run.has_side_effects = true;
    return run;
}

const c_flags = &.{ "-Wall", "-Wextra", "-Werror" };

const lua_files = [_][]const u8{
    "lua/init.lua",
    "lua/lock.lua",
    "lua/background.lua",
    "lua/storybook.lua",
    "lua/shell/ipc.lua",
    "lua/shell/audio.lua",
    "lua/shell/clock.lua",
    "lua/shell/idle.lua",
    "lua/shell/lock.lua",
    "lua/shell/bar/init.lua",
    "lua/shell/bar/colors.lua",
    "lua/shell/bar/network.lua",
    "lua/shell/bar/status.lua",
    "lua/shell/bar/workspaces.lua",
    "lua/shell/bar/tray.lua",
    "lua/shell/bar/util.lua",
    "lua/shell/notifications.lua",
    "lua/shell/osd.lua",
    "lua/shell/session.lua",
    "lua/shell/launcher/init.lua",
    "lua/shell/launcher/history.lua",
    "lua/shell/launcher/match.lua",
    "lua/shell/launcher/providers/init.lua",
    "lua/shell/launcher/providers/apps.lua",
    "lua/shell/launcher/providers/power.lua",
};
