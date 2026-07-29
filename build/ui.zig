const std = @import("std");

pub const Output = struct {
    module: *std.Build.Module,
    engine_module: *std.Build.Module,
    uucode_module: *std.Build.Module,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) Output {
    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = b.path("src/ui/linebreak/uucode_config.zig"),
    });
    const uucode_module = uucode_dep.module("uucode");

    const linebreak_module = b.addModule("linebreak", .{
        .root_source_file = b.path("src/ui/linebreak/root.zig"),
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
        .root_source_file = b.path("src/ui/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    keywork_ui_module.addImport("uucode", uucode_module);
    keywork_ui_module.addImport("linebreak", linebreak_module);
    keywork_ui_module.addImport("z2d", z2d_module);

    const keywork_ui_engine_module = b.addModule("keywork-ui-engine", .{
        .root_source_file = b.path("src/ui/engine/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    keywork_ui_engine_module.addImport("keywork-ui", keywork_ui_module);
    keywork_ui_engine_module.addImport("uucode", uucode_module);

    const keywork_ui_tests = b.addTest(.{ .root_module = keywork_ui_module });
    test_step.dependOn(&b.addRunArtifact(keywork_ui_tests).step);
    const keywork_ui_engine_tests = b.addTest(.{ .root_module = keywork_ui_engine_module });
    test_step.dependOn(&b.addRunArtifact(keywork_ui_engine_tests).step);
    const linebreak_tests = b.addTest(.{ .root_module = linebreak_module });
    test_step.dependOn(&b.addRunArtifact(linebreak_tests).step);

    return .{
        .module = keywork_ui_module,
        .engine_module = keywork_ui_engine_module,
        .uucode_module = uucode_module,
    };
}
