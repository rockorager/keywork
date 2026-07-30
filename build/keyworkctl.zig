const std = @import("std");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    compositor_adapter: *std.Build.Module,
    application_control: *std.Build.Module,
    varlink: *std.Build.Module,
    compositor_tests: *std.Build.Step,
    test_step: *std.Build.Step,
) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/keyworkctl/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("keyworkctl-compositor", compositor_adapter);
    module.addImport("keywork-application-control", application_control);
    module.addImport("varlink", varlink);

    const executable = b.addExecutable(.{
        .name = "keyworkctl",
        .root_module = module,
    });
    b.installArtifact(executable);

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const check_step = b.step("keyworkctl", "Build and test keyworkctl");
    check_step.dependOn(&executable.step);
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(compositor_tests);
}
