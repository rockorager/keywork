const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub const Output = struct {
    streamd: *std.Build.Step.Compile,
    gateway: std.Build.LazyPath,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
    wayland_xml: std.Build.LazyPath,
    wayland_protocols: std.Build.LazyPath,
    test_step: *std.Build.Step,
) Output {
    const scanner = Scanner.create(b, .{
        .wayland_xml = wayland_xml,
        .wayland_protocols = wayland_protocols,
    });
    scanner.addSystemProtocol("staging/ext-data-control/ext-data-control-v1.xml");
    scanner.addCustomProtocol(b.path("protocols/wayland/wlr-output-management-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/wlr-screencopy-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/virtual-keyboard-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/upstream/wlr-virtual-pointer-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wayland/upstream/input-method-unstable-v2.xml"));
    scanner.addSystemProtocol("unstable/text-input/text-input-unstable-v3.xml");
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 9);
    scanner.generate("ext_data_control_manager_v1", 1);
    scanner.generate("zwlr_output_manager_v1", 4);
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    scanner.generate("zwlr_virtual_pointer_manager_v1", 2);
    scanner.generate("zwp_virtual_keyboard_manager_v1", 1);
    scanner.generate("zwp_input_method_manager_v2", 1);
    scanner.generate("zwp_text_input_manager_v3", 1);
    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    const capture_module = b.createModule(.{
        .root_source_file = b.path("src/stream/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    capture_module.addOptions("build-options", build_options);
    capture_module.addImport("wayland", wayland);
    capture_module.linkSystemLibrary("wayland-client", .{
        .use_pkg_config = .no,
        .preferred_link_mode = .static,
        .search_strategy = .no_fallback,
    });
    capture_module.linkSystemLibrary("ffi", .{});
    capture_module.linkSystemLibrary("m", .{});
    capture_module.linkSystemLibrary("xkbcommon", .{});
    const capture = b.addExecutable(.{
        .name = "keywork-streamd",
        .root_module = capture_module,
    });
    capture.each_lib_rpath = false;
    b.installArtifact(capture);

    const capture_tests = b.addTest(.{ .root_module = capture_module });
    test_step.dependOn(&b.addRunArtifact(capture_tests).step);

    const go_build = b.addSystemCommand(&.{ "go", "build", "-trimpath", "-ldflags" });
    go_build.setCwd(b.path("src/stream/gateway"));
    go_build.setEnvironmentVariable("CGO_ENABLED", "0");
    go_build.setEnvironmentVariable("GOOS", goOS(target.result.os.tag));
    go_build.setEnvironmentVariable("GOARCH", goArch(target.result.cpu.arch));
    go_build.addArg(b.fmt("-s -w -X main.version={s}", .{@import("version.zig").string}));
    go_build.addArg("-o");
    for ([_][]const u8{
        "src/stream/gateway/main.go",
        "src/stream/gateway/go.mod",
        "src/stream/gateway/go.sum",
        "src/stream/gateway/examples/web/index.html",
        "src/stream/gateway/examples/web/style.css",
        "src/stream/gateway/examples/web/client.js",
        "src/stream/gateway/sdk/keywork-stream.js",
        "src/stream/gateway/sdk/keywork-stream.d.ts",
        "src/stream/gateway/sdk/audio-player.js",
        "src/stream/gateway/sdk/package.json",
        "src/stream/gateway/sdk/README.md",
    }) |input| {
        go_build.addFileInput(b.path(input));
    }
    const gateway = go_build.addOutputFileArg("keywork-stream-gateway");
    go_build.addArg(".");
    const install_gateway = b.addInstallBinFile(gateway, "keywork-stream-gateway");
    b.getInstallStep().dependOn(&install_gateway.step);

    const go_test = b.addSystemCommand(&.{ "go", "test", "./..." });
    go_test.setCwd(b.path("src/stream/gateway"));
    test_step.dependOn(&go_test.step);

    const sdk_pack_check = b.addSystemCommand(&.{ "npm", "pack", "--dry-run", "--json" });
    sdk_pack_check.setCwd(b.path("src/stream/gateway/sdk"));
    test_step.dependOn(&sdk_pack_check.step);

    const stream_step = b.step("stream", "Build the browser streaming prototype");
    stream_step.dependOn(&capture.step);
    stream_step.dependOn(&go_build.step);
    return .{ .streamd = capture, .gateway = gateway };
}

fn goOS(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .linux => "linux",
        else => @panic("the stream gateway currently supports Linux release targets only"),
    };
}

fn goArch(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => @panic("the stream gateway currently supports x86_64 and aarch64 only"),
    };
}
