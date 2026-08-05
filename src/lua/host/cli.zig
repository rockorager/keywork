//! Command-line parsing for the Keywork executable.

const std = @import("std");
const native_runtime = @import("keywork-runtime");

pub const Options = struct {
    backend: ?native_runtime.BackendKind = null,
    width: ?f32 = null,
    height: ?f32 = null,
    script_path: []const u8 = "",
    layer_shell: ?native_runtime.LayerShellOptions = null,
    /// Arguments after the script path, forwarded verbatim to the Lua
    /// application via the `arg` global.
    app_args: []const [:0]const u8 = &.{},
};

pub const StorybookOperation = enum {
    run,
    list,
    snapshot,
};

pub const StorybookOptions = struct {
    operation: StorybookOperation,
    script_path: []const u8,
    story_id: ?[]const u8 = null,
    output_path: []const u8 = "storybook-snapshots",
    json: bool = false,
};

pub const TestOptions = struct {
    paths: []const [:0]const u8,
    filter: ?[]const u8 = null,
    default_path: bool = false,
    help: bool = false,
};

pub const Command = union(enum) {
    run: Options,
    storybook: StorybookOptions,
    test_command: TestOptions,
};

pub const usage =
    \\usage: keywork [options] <script.lua> [args...]
    \\       keywork storybook run <stories.lua>
    \\       keywork storybook list <stories.lua> [--json]
    \\       keywork storybook snapshot <stories.lua> [--story <id>] [--output <dir>] [--json]
    \\       keywork test [path...] [--filter <name>]
    \\
;

pub const test_usage =
    \\usage: keywork test [path...] [options]
    \\
    \\Recursively discovers *.test.lua files. With no paths, searches ./tests.
    \\An explicit file is run regardless of its suffix. Each file gets a fresh
    \\Lua VM with the real Keywork modules and the test-only keywork.test module.
    \\
    \\options:
    \\  --filter <text>  Run cases whose full name contains text
    \\  -h, --help       Show this help
    \\
    \\test files:
    \\  local test = require("keywork.test")
    \\  test.case("adds values", function(t)
    \\      t:equal(2 + 2, 4) -- actual, expected
    \\  end)
    \\
    \\Cases currently run synchronously. Files and cases run in deterministic
    \\discovery and registration order; failures do not stop later cases.
    \\
    \\Editor definitions for keywork.test and the other Keywork modules are
    \\installed at <prefix>/share/keywork/emmylua. Add that directory to the
    \\workspace library configured for your Lua language server.
    \\
;

pub fn parseCommand(init: std.process.Init, allocator: std.mem.Allocator) !Command {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const first = args.next() orelse return error.MissingScriptPath;
    if (std.mem.eql(u8, first, "storybook")) return .{ .storybook = try parseStorybook(&args) };
    if (std.mem.eql(u8, first, "test")) return .{ .test_command = try parseTest(&args, allocator) };
    return .{ .run = try parse(init, allocator) };
}

pub fn parse(init: std.process.Init, allocator: std.mem.Allocator) !Options {
    var result: Options = .{};
    var app_args: std.ArrayList([:0]const u8) = .empty;
    errdefer app_args.deinit(allocator);
    var script_seen = false;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (script_seen) {
            try app_args.append(allocator, arg);
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            result.script_path = arg;
            script_seen = true;
        } else if (std.mem.eql(u8, arg, "--wayland")) {
            result.backend = .wayring_shm;
        } else if (std.mem.eql(u8, arg, "--backend=cpu")) {
            result.backend = .wayring_shm;
        } else if (std.mem.eql(u8, arg, "--backend=vulkan")) {
            result.backend = .vulkan;
        } else if (std.mem.eql(u8, arg, "--backend=wayring")) {
            result.backend = .wayring;
        } else if (std.mem.eql(u8, arg, "--backend=wayring-cpu")) {
            result.backend = .wayring_shm;
        } else if (std.mem.eql(u8, arg, "--backend=log")) {
            result.backend = .log;
        } else if (std.mem.eql(u8, arg, "--layer-shell")) {
            if (result.layer_shell == null) result.layer_shell = .{};
        } else if (std.mem.startsWith(u8, arg, "--layer=")) {
            if (result.layer_shell == null) result.layer_shell = .{};
            result.layer_shell.?.layer = parseLayer(arg["--layer=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--anchor=")) {
            if (result.layer_shell == null) result.layer_shell = .{};
            result.layer_shell.?.anchors = parseAnchors(arg["--anchor=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--exclusive-zone=")) {
            if (result.layer_shell == null) result.layer_shell = .{};
            result.layer_shell.?.exclusive_zone = std.fmt.parseInt(i32, arg["--exclusive-zone=".len..], 10) catch result.layer_shell.?.exclusive_zone;
        } else if (std.mem.startsWith(u8, arg, "--keyboard=")) {
            if (result.layer_shell == null) result.layer_shell = .{};
            result.layer_shell.?.keyboard_interactivity = parseKeyboardInteractivity(arg["--keyboard=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            result.width = std.fmt.parseFloat(f32, arg["--width=".len..]) catch result.width;
        } else if (std.mem.startsWith(u8, arg, "--height=")) {
            result.height = std.fmt.parseFloat(f32, arg["--height=".len..]) catch result.height;
        } else if (std.mem.startsWith(u8, arg, "--script=")) {
            result.script_path = arg["--script=".len..];
            script_seen = true;
        }
    }
    if (result.script_path.len == 0) return error.MissingScriptPath;
    result.app_args = try app_args.toOwnedSlice(allocator);
    return result;
}

fn parseStorybook(args: anytype) !StorybookOptions {
    const operation_name = args.next() orelse return error.MissingStorybookOperation;
    const operation: StorybookOperation = if (std.mem.eql(u8, operation_name, "run"))
        .run
    else if (std.mem.eql(u8, operation_name, "list"))
        .list
    else if (std.mem.eql(u8, operation_name, "snapshot"))
        .snapshot
    else
        return error.UnknownStorybookOperation;

    var result: StorybookOptions = .{ .operation = operation, .script_path = "" };
    var output_set = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            result.json = true;
        } else if (std.mem.eql(u8, arg, "--story")) {
            result.story_id = args.next() orelse return error.MissingOptionValue;
        } else if (std.mem.startsWith(u8, arg, "--story=")) {
            result.story_id = arg["--story=".len..];
        } else if (std.mem.eql(u8, arg, "--output")) {
            result.output_path = args.next() orelse return error.MissingOptionValue;
            output_set = true;
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            result.output_path = arg["--output=".len..];
            output_set = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else if (result.script_path.len == 0) {
            result.script_path = arg;
        } else {
            return error.UnexpectedArgument;
        }
    }

    if (result.script_path.len == 0) return error.MissingScriptPath;
    if (result.story_id) |id| if (id.len == 0) return error.MissingOptionValue;
    if (result.output_path.len == 0) return error.MissingOptionValue;
    if (operation != .snapshot and (result.story_id != null or output_set)) return error.InvalidStorybookOption;
    return result;
}

fn parseTest(args: anytype, allocator: std.mem.Allocator) !TestOptions {
    var paths: std.ArrayList([:0]const u8) = .empty;
    errdefer paths.deinit(allocator);
    var filter: ?[]const u8 = null;
    var help = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help = true;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            filter = args.next() orelse return error.MissingOptionValue;
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            filter = arg["--filter=".len..];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            try paths.append(allocator, arg);
        }
    }

    if (filter) |value| if (value.len == 0) return error.MissingOptionValue;
    const default_path = paths.items.len == 0;
    if (default_path) try paths.append(allocator, "tests");
    return .{
        .paths = try paths.toOwnedSlice(allocator),
        .filter = filter,
        .default_path = default_path,
        .help = help,
    };
}

const TestArgs = struct {
    items: []const [:0]const u8,
    index: usize = 0,

    fn next(self: *TestArgs) ?[:0]const u8 {
        if (self.index == self.items.len) return null;
        defer self.index += 1;
        return self.items[self.index];
    }
};

test "test command defaults to the tests directory" {
    var args: TestArgs = .{ .items = &.{} };
    const options = try parseTest(&args, std.testing.allocator);
    defer std.testing.allocator.free(options.paths);

    try std.testing.expect(options.default_path);
    try std.testing.expectEqual(@as(usize, 1), options.paths.len);
    try std.testing.expectEqualStrings("tests", options.paths[0]);
}

test "test command accepts paths and a name filter" {
    var args: TestArgs = .{ .items = &.{ "unit", "integration/example.lua", "--filter", "parser" } };
    const options = try parseTest(&args, std.testing.allocator);
    defer std.testing.allocator.free(options.paths);

    try std.testing.expect(!options.default_path);
    try std.testing.expectEqual(@as(usize, 2), options.paths.len);
    try std.testing.expectEqualStrings("unit", options.paths[0]);
    try std.testing.expectEqualStrings("integration/example.lua", options.paths[1]);
    try std.testing.expectEqualStrings("parser", options.filter.?);
}

test "test command accepts its help option" {
    var args: TestArgs = .{ .items = &.{"--help"} };
    const options = try parseTest(&args, std.testing.allocator);
    defer std.testing.allocator.free(options.paths);

    try std.testing.expect(options.help);
}

fn parseLayer(value: []const u8) native_runtime.LayerShellOptions.Layer {
    if (std.mem.eql(u8, value, "background")) return .background;
    if (std.mem.eql(u8, value, "bottom")) return .bottom;
    if (std.mem.eql(u8, value, "overlay")) return .overlay;
    return .top;
}

fn parseAnchors(value: []const u8) native_runtime.LayerShellOptions.AnchorSet {
    var result: native_runtime.LayerShellOptions.AnchorSet = .{};
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |anchor| {
        if (std.mem.eql(u8, anchor, "top")) result.top = true;
        if (std.mem.eql(u8, anchor, "bottom")) result.bottom = true;
        if (std.mem.eql(u8, anchor, "left")) result.left = true;
        if (std.mem.eql(u8, anchor, "right")) result.right = true;
    }
    return result;
}

fn parseKeyboardInteractivity(value: []const u8) native_runtime.LayerShellOptions.KeyboardInteractivity {
    if (std.mem.eql(u8, value, "exclusive")) return .exclusive;
    if (std.mem.eql(u8, value, "on-demand") or std.mem.eql(u8, value, "on_demand")) return .on_demand;
    return .none;
}
