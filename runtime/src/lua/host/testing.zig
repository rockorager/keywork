//! Discovery and execution for the `keywork test` command.

const std = @import("std");
const cli = @import("cli.zig");
const lua_app = @import("../app.zig");
const lua_testing = @import("../testing.zig");

const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
    errors: usize = 0,
    skipped: usize = 0,

    fn selected(self: Summary) usize {
        return self.passed + self.failed + self.errors + self.skipped;
    }

    fn successful(self: Summary) bool {
        return self.selected() > 0 and self.failed == 0 and self.errors == 0;
    }
};

/// Discovers and runs test files. A false result is an ordinary test failure;
/// errors describe runner or filesystem failures.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: cli.TestOptions,
    writer: *std.Io.Writer,
) !bool {
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    for (options.paths) |path| {
        discoverPath(allocator, io, path, &files) catch |err| switch (err) {
            error.FileNotFound => if (!options.default_path) return err,
            else => return err,
        };
    }
    sortAndDeduplicate(allocator, &files);
    if (files.items.len == 0) return error.NoTestsFound;

    var summary: Summary = .{};
    for (files.items) |path| try runFile(allocator, path, options.filter, writer, &summary);

    if (summary.selected() == 0) {
        if (options.filter) |filter| {
            try writer.print("\nno tests matched filter '{s}'\n", .{filter});
        } else {
            try writer.writeAll("\nno tests were registered\n");
        }
        return false;
    }

    try writer.print(
        "\n{d} passed, {d} failed, {d} errors, {d} skipped\n",
        .{ summary.passed, summary.failed, summary.errors, summary.skipped },
    );
    return summary.successful();
}

fn runFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    filter: ?[]const u8,
    writer: *std.Io.Writer,
    summary: *Summary,
) !void {
    var app = lua_app.App.initTest(allocator, path) catch |err| {
        summary.errors += 1;
        try writer.print("ERROR {s}\n    {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer app.deinit();

    const results = app.runTests(filter) catch |err| {
        summary.errors += 1;
        try writer.print("ERROR {s}\n", .{path});
        if (app.lastLuaError()) |message| {
            try writeIndented(writer, message);
        } else {
            try writer.print("    {s}\n", .{@errorName(err)});
        }
        return;
    };
    defer lua_testing.deinitResults(allocator, results);

    for (results) |result| {
        switch (result.status) {
            .pass => {
                summary.passed += 1;
                try writer.print("PASS  {s} :: {s}\n", .{ path, result.name });
            },
            .fail => {
                summary.failed += 1;
                try writer.print("FAIL  {s} :: {s}\n", .{ path, result.name });
                try writeIndented(writer, result.message orelse "assertion failed");
            },
            .error_status => {
                summary.errors += 1;
                try writer.print("ERROR {s} :: {s}\n", .{ path, result.name });
                try writeIndented(writer, result.message orelse "unexpected error");
            },
            .skip => {
                summary.skipped += 1;
                try writer.print("SKIP  {s} :: {s}", .{ path, result.name });
                if (result.message) |message| try writer.print(" ({s})", .{message});
                try writer.writeByte('\n');
            },
        }
    }
}

fn writeIndented(writer: *std.Io.Writer, message: []const u8) !void {
    var lines = std.mem.splitScalar(u8, message, '\n');
    while (lines.next()) |line| try writer.print("    {s}\n", .{line});
}

fn discoverPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    files: *std.ArrayList([]u8),
) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    switch (stat.kind) {
        .file => {
            const copy = try allocator.dupe(u8, path);
            errdefer allocator.free(copy);
            try files.append(allocator, copy);
        },
        .directory => {
            const dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(io);
            try discoverDirectory(allocator, io, dir, path, files);
        },
        else => return error.UnsupportedTestPath,
    }
}

fn discoverDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    display_root: []const u8,
    files: *std.ArrayList([]u8),
) !void {
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".test.lua")) continue;
        const path = try std.fs.path.join(allocator, &.{ display_root, entry.path });
        errdefer allocator.free(path);
        try files.append(allocator, path);
    }
}

fn sortAndDeduplicate(allocator: std.mem.Allocator, files: *std.ArrayList([]u8)) void {
    std.mem.sort([]u8, files.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    var write_index: usize = 0;
    for (files.items) |path| {
        if (write_index > 0 and std.mem.eql(u8, files.items[write_index - 1], path)) {
            allocator.free(path);
            continue;
        }
        files.items[write_index] = path;
        write_index += 1;
    }
    files.shrinkRetainingCapacity(write_index);
}

test "directory discovery finds only test files recursively" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "tests/nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tests/z.test.lua", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tests/nested/a.test.lua", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tests/nested/helper.lua", .data = "" });

    const dir = try tmp.dir.openDir(std.testing.io, "tests", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    try discoverDirectory(allocator, std.testing.io, dir, "tests", &files);
    sortAndDeduplicate(allocator, &files);

    try std.testing.expectEqual(@as(usize, 2), files.items.len);
    try std.testing.expectEqualStrings("tests/nested/a.test.lua", files.items[0]);
    try std.testing.expectEqualStrings("tests/z.test.lua", files.items[1]);
}
