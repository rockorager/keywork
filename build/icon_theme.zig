//! Installs the keywork XDG icon theme (Phosphor icons plus freedesktop
//! name aliases) into <prefix>/share/icons/keywork.

const std = @import("std");

pub const IconTheme = struct {
    step: *std.Build.Step,
    /// XDG-style data root containing icons/keywork. Run steps export it
    /// as KEYWORK_DATA_DIR so binaries running from the build cache find
    /// the theme.
    data_dir: []const u8,

    /// Wires a run command to find the installed theme at dev time.
    pub fn attach(self: IconTheme, run: *std.Build.Step.Run) void {
        run.setEnvironmentVariable("KEYWORK_DATA_DIR", self.data_dir);
        run.step.dependOn(self.step);
    }
};

pub fn add(b: *std.Build) IconTheme {
    const phosphor = b.dependency("phosphor", .{});

    const tool = b.addExecutable(.{
        .name = "gen-icon-theme",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/gen_icon_theme.zig"),
            .target = b.graph.host,
        }),
    });

    // The tool writes the theme directly into the install prefix instead
    // of a cached artifact directory: alias entries are symlinks, and the
    // InstallDir step silently skips symlinks when copying. A stamp file
    // inside the output makes repeated builds no-ops.
    const run = b.addRunArtifact(tool);
    run.has_side_effects = true;
    run.addDirectoryArg(phosphor.path("assets/regular"));
    run.addDirectoryArg(phosphor.path("assets/fill"));
    run.addFileArg(b.path("build/xdg-icon-aliases.txt"));
    run.addFileArg(phosphor.path("LICENSE"));
    run.addArg(b.getInstallPath(.prefix, "share/icons/keywork"));
    b.getInstallStep().dependOn(&run.step);

    return .{
        .step = &run.step,
        .data_dir = b.getInstallPath(.prefix, "share"),
    };
}
