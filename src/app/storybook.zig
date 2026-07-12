//! Interactive and headless Storybook commands.

const std = @import("std");
const keywork = @import("../ui.zig");
const cli = @import("cli.zig");
const runner = @import("runner.zig");
const memory_backend = @import("../backend/memory.zig");
const event_loop = @import("../linux/event_loop.zig");
const lua_app = @import("../lua/app.zig");
const lua_storybook = @import("../lua/storybook.zig");
const runtime_mod = @import("../ui/runtime.zig");

const schema_version = 2;

const ViewportHeightOutput = union(enum) {
    fixed: f32,
    content,

    pub fn jsonStringify(self: ViewportHeightOutput, stringify: anytype) !void {
        switch (self) {
            .fixed => |height| try stringify.write(height),
            .content => try stringify.write("content"),
        }
    }
};

const ViewportOutput = struct {
    width: f32,
    height: ViewportHeightOutput,
    scale: f32,
};

const StoryOutput = struct {
    id: []const u8,
    group: ?[]const u8,
    name: []const u8,
    viewport: ViewportOutput,
    color_scheme: []const u8,
};

const CatalogOutput = struct {
    version: u8 = schema_version,
    title: ?[]const u8,
    stories: []const StoryOutput,
};

const SnapshotOutput = struct {
    id: []const u8,
    group: ?[]const u8,
    name: []const u8,
    path: []const u8,
    sha256: [64]u8,
    viewport: ViewportOutput,
    pixel_width: u31,
    pixel_height: u31,
    color_scheme: []const u8,
};

const SnapshotManifest = struct {
    version: u8 = schema_version,
    snapshots: []const SnapshotOutput,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: cli.StorybookOptions, writer: *std.Io.Writer) !void {
    switch (options.operation) {
        .run => try runInteractive(allocator, options, writer),
        .list => try list(allocator, options, writer),
        .snapshot => try snapshot(allocator, io, options, writer),
    }
}

fn runInteractive(allocator: std.mem.Allocator, options: cli.StorybookOptions, writer: *std.Io.Writer) !void {
    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    var app = try lua_app.App.initStorybookBrowser(allocator, options.script_path);
    defer app.deinit();
    const catalog = try app.storyCatalog();
    const title = if (catalog.title) |book_title|
        try std.fmt.allocPrintSentinel(allocator, "{s} — Keywork Storybook", .{book_title}, 0)
    else
        try allocator.dupeZ(u8, "Keywork Storybook");
    defer allocator.free(title);

    try runner.run(allocator, &loop, app.host(), .{
        .title = title,
        .app_id = "dev.keywork.Storybook",
        .width = 1200,
        .height = 800,
        .backend = .wayland_shm,
        .log_writer = writer,
        .runtime_context = &app,
        .bind_runtime = lua_app.App.bindRuntimeOpaque,
        .bind_platform = lua_app.App.bindPlatformOpaque,
        .unbind_platform = lua_app.App.unbindPlatformOpaque,
        .unbind_runtime = lua_app.App.unbindRuntimeOpaque,
        .bind_event_loop = lua_app.App.bindEventLoopOpaque,
        .unbind_event_loop = lua_app.App.unbindEventLoopOpaque,
    });
}

fn list(allocator: std.mem.Allocator, options: cli.StorybookOptions, writer: *std.Io.Writer) !void {
    var app = try lua_app.App.initStorybook(allocator, options.script_path);
    defer app.deinit();
    const catalog = try app.storyCatalog();

    if (!options.json) {
        if (catalog.title) |title| try writer.print("{s}\n", .{title});
        for (catalog.stories) |story| {
            if (story.content_height) {
                try writer.print("{s}\t{s}\t{d}xcontent@{d}\t{s}\n", .{
                    story.id,
                    story.name,
                    story.width,
                    story.scale,
                    story.color_scheme.name(),
                });
            } else {
                try writer.print("{s}\t{s}\t{d}x{d}@{d}\t{s}\n", .{
                    story.id,
                    story.name,
                    story.width,
                    story.height,
                    story.scale,
                    story.color_scheme.name(),
                });
            }
        }
        return;
    }

    const stories = try allocator.alloc(StoryOutput, catalog.stories.len);
    defer allocator.free(stories);
    for (catalog.stories, stories) |story, *output| output.* = storyOutput(story);
    try writeJson(writer, CatalogOutput{
        .title = catalog.title,
        .stories = stories,
    });
}

fn snapshot(allocator: std.mem.Allocator, io: std.Io, options: cli.StorybookOptions, writer: *std.Io.Writer) !void {
    // This VM is catalog discovery only. Every rendered story below gets a
    // fresh VM and Runtime so globals, modules, tasks, and widget state cannot
    // leak between snapshots.
    var discovery = try lua_app.App.initStorybook(allocator, options.script_path);
    defer discovery.deinit();
    const catalog = try discovery.storyCatalog();
    if (options.story_id) |id| _ = catalog.find(id) orelse return error.UnknownStory;

    try std.Io.Dir.cwd().createDirPath(io, options.output_path);
    var results: std.ArrayList(SnapshotOutput) = .empty;
    defer {
        for (results.items) |result| allocator.free(result.path);
        results.deinit(allocator);
    }

    for (catalog.stories) |story| {
        if (options.story_id) |id| {
            if (!std.mem.eql(u8, id, story.id)) continue;
        }
        const result = try renderStory(allocator, io, options, story);
        errdefer allocator.free(result.path);
        try results.append(allocator, result);
    }

    if (options.json) {
        try writeJson(writer, SnapshotManifest{ .snapshots = results.items });
        return;
    }
    for (results.items) |result| {
        try writer.print("{s} -> {s}  {s}\n", .{ result.id, result.path, &result.sha256 });
    }
}

fn renderStory(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: cli.StorybookOptions,
    story: lua_storybook.Story,
) !SnapshotOutput {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.png", .{story.id});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ options.output_path, file_name });
    errdefer allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);

    var app = try lua_app.App.initStorybook(allocator, options.script_path);
    defer app.deinit();
    try app.selectStory(story.id);

    var backend = try memory_backend.init(allocator, story.scale);
    defer backend.deinit();
    var runtime = try runtime_mod.Runtime.init(
        allocator,
        backend.backend(),
        if (story.content_height)
            .{
                .min_width = story.width,
                .max_width = story.width,
                .max_height = story.height,
            }
        else
            .{ .max_width = story.width, .max_height = story.height },
        app.host(),
        runtimeColorScheme(story.color_scheme),
    );
    defer runtime.deinit();
    app.bindRuntime(&runtime);
    defer app.unbindRuntime();
    // The first frame is always time zero, regardless of host timing.
    runtime.clock = .{ .now_fn = zeroTime };
    if (story.content_height) runtime.setContentSizing(.{ .height = true });
    try runtime.repaint();
    try backend.writePng(io, path);

    return .{
        .id = story.id,
        .group = story.group,
        .name = story.name,
        .path = path,
        .sha256 = try hashFile(io, path),
        .viewport = viewportOutput(story),
        .pixel_width = backend.width,
        .pixel_height = backend.height,
        .color_scheme = story.color_scheme.name(),
    };
}

fn storyOutput(story: lua_storybook.Story) StoryOutput {
    return .{
        .id = story.id,
        .group = story.group,
        .name = story.name,
        .viewport = viewportOutput(story),
        .color_scheme = story.color_scheme.name(),
    };
}

fn viewportOutput(story: lua_storybook.Story) ViewportOutput {
    return .{
        .width = story.width,
        .height = if (story.content_height) .content else .{ .fixed = story.height },
        .scale = story.scale,
    };
}

fn runtimeColorScheme(scheme: lua_storybook.ColorScheme) runtime_mod.UiColorScheme {
    return switch (scheme) {
        .light => .light,
        .dark => .dark,
    };
}

fn zeroTime(_: ?*anyopaque) u64 {
    return 0;
}

fn hashFile(io: std.Io, path: []const u8) ![64]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        var chunk: [16 * 1024]u8 = undefined;
        const count = reader.interface.readSliceShort(&chunk) catch return reader.err.?;
        hasher.update(chunk[0..count]);
        if (count < chunk.len) break;
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn writeJson(writer: *std.Io.Writer, value: anytype) !void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.write(value);
    try writer.writeByte('\n');
}

test "story output keeps declared rendering metadata" {
    const story: lua_storybook.Story = .{
        .id = @constCast("button/default"),
        .group = @constCast("Button"),
        .name = @constCast("Default"),
        .index = 1,
        .width = 320,
        .height = 200,
        .scale = 2,
        .color_scheme = .dark,
    };
    const output = storyOutput(story);
    try std.testing.expectEqualStrings("button/default", output.id);
    try std.testing.expectEqual(@as(f32, 2), output.viewport.scale);
    try std.testing.expectEqualStrings("dark", output.color_scheme);
}

test "storybook JSON schema represents content viewport height" {
    const story: lua_storybook.Story = .{
        .id = @constCast("notice/default"),
        .name = @constCast("Default"),
        .index = 1,
        .width = 380,
        .content_height = true,
        .scale = 2,
    };
    const stories = [_]StoryOutput{storyOutput(story)};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeJson(&output.writer, CatalogOutput{ .title = null, .stories = &stories });

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"version\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"height\": \"content\"") != null);
}

test "content-height Storybook snapshot uses exact measured pixel height" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local sb = require("keywork.storybook")
        \\return sb.book({ stories = {
        \\  sb.story({
        \\    id = "notice/default",
        \\    name = "Default",
        \\    viewport = { width = 380, height = "content", scale = 2 },
        \\    render = function()
        \\      return kw.sized({ width = 380, height = 37, child = kw.spacer() })
        \\    end,
        \\  }),
        \\} })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "content-storybook.lua", .data = script });
    const root_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root_path);
    const script_path = try std.fs.path.join(allocator, &.{ root_path, "content-storybook.lua" });
    defer allocator.free(script_path);
    const output_path = try std.fs.path.join(allocator, &.{ root_path, "snapshots" });
    defer allocator.free(output_path);

    var discovery = try lua_app.App.initStorybook(allocator, script_path);
    defer discovery.deinit();
    const parsed_story = (try discovery.storyCatalog()).stories[0];
    try std.testing.expect(parsed_story.content_height);

    const result = try renderStory(
        allocator,
        std.testing.io,
        .{ .operation = .snapshot, .script_path = script_path, .output_path = output_path },
        parsed_story,
    );
    defer allocator.free(result.path);
    try std.testing.expectEqual(@as(u31, 760), result.pixel_width);
    try std.testing.expectEqual(@as(u31, 74), result.pixel_height);

    var browser = try lua_app.App.initStorybookBrowser(allocator, script_path);
    defer browser.deinit();
    var browser_backend = try memory_backend.init(allocator, 1);
    defer browser_backend.deinit();
    var browser_runtime = try runtime_mod.Runtime.init(
        allocator,
        browser_backend.backend(),
        .{ .max_width = 1200, .max_height = 800 },
        browser.host(),
        .light,
    );
    defer browser_runtime.deinit();
    browser.bindRuntime(&browser_runtime);
    defer browser.unbindRuntime();
    try std.testing.expect(renderTreeHasSize(browser_runtime.root.?, .{ .width = 380, .height = 37 }));
    try std.testing.expect(!renderTreeHasSize(browser_runtime.root.?, .{ .width = 380, .height = 480 }));
}

fn renderTreeHasSize(node: *const keywork.RenderNode, size: keywork.Size) bool {
    if (node.rect.width == size.width and node.rect.height == size.height) return true;
    for (node.children) |child| {
        if (renderTreeHasSize(child, size)) return true;
    }
    return false;
}
