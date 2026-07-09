//! Build tool that assembles the keywork XDG icon theme from the Phosphor
//! icon set. Copies every Phosphor SVG under its original name (regular
//! weight as `<name>.svg`, fill weight as `<name>-fill.svg`) and adds
//! symlinks for freedesktop standard names from an alias mapping file.
//!
//! Usage: gen-icon-theme <regular-dir> <fill-dir> <aliases-file> <license-file> <out-dir>
//!
//! The output directory is written in place (it is the installed theme
//! directory, not a cached artifact) so symlinks survive; Zig's InstallDir
//! step silently drops them. A stamp file keyed on the inputs makes
//! repeated builds cheap no-ops.

const std = @import("std");

const index_theme =
    \\[Icon Theme]
    \\Name=Keywork
    \\Comment=Phosphor icons (phosphoricons.com) with freedesktop icon name aliases
    \\Inherits=Adwaita,hicolor
    \\Directories=scalable
    \\
    \\[scalable]
    \\Size=24
    \\MinSize=8
    \\MaxSize=512
    \\Type=Scalable
    \\
;

const Alias = struct {
    name: []const u8,
    target: []const u8,
    line: usize,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const regular_path = args.next() orelse usageError();
    const fill_path = args.next() orelse usageError();
    const aliases_path = args.next() orelse usageError();
    const license_path = args.next() orelse usageError();
    const out_path = args.next() orelse usageError();
    if (args.next() != null) usageError();

    const cwd: std.Io.Dir = .cwd();
    const aliases_bytes = try cwd.readFileAlloc(io, aliases_path, allocator, .limited(1024 * 1024));

    const stamp = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{x}\n{x}\n", .{
        regular_path,
        fill_path,
        std.hash.Wyhash.hash(0, aliases_bytes),
        std.hash.Wyhash.hash(0, index_theme),
    });
    if (stampMatches(io, cwd, out_path, stamp)) return;

    const aliases = try parseAliases(allocator, aliases_bytes, aliases_path);

    var out_dir = try cwd.createDirPathOpen(io, out_path, .{});
    defer out_dir.close(io);
    try out_dir.createDirPath(io, "scalable");
    var scalable_dir = try out_dir.openDir(io, "scalable", .{});
    defer scalable_dir.close(io);

    // Copy every Phosphor icon under its original name (fill files are
    // already suffixed `-fill`), remembering the names so aliases can be
    // validated against the shipped set.
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for ([_][]const u8{ regular_path, fill_path }) |icons_path| {
        var icons_dir = try cwd.openDir(io, icons_path, .{ .iterate = true });
        defer icons_dir.close(io);
        var it = icons_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".svg")) continue;
            const name = try allocator.dupe(u8, entry.name[0 .. entry.name.len - ".svg".len]);
            try names.put(allocator, name, {});
            const file_name = try allocator.dupe(u8, entry.name);
            try icons_dir.copyFile(file_name, scalable_dir, file_name, io, .{});
        }
        if (names.count() == 0) fail("no .svg icons found in {s}", .{icons_path});
    }

    for (aliases) |alias| {
        if (names.contains(alias.name)) {
            // An alias may shadow a shipped icon only to swap it for its
            // own fill weight (XDG status names like battery-full default
            // to the filled style); anything else is a mistake.
            const fill_of_name = try std.fmt.allocPrint(allocator, "{s}-fill", .{alias.name});
            if (!std.mem.eql(u8, alias.target, fill_of_name)) {
                fail("{s}:{d}: alias '{s}' collides with a Phosphor icon name", .{ aliases_path, alias.line, alias.name });
            }
        }
        if (!names.contains(alias.target)) {
            fail("{s}:{d}: unknown Phosphor icon '{s}'", .{ aliases_path, alias.line, alias.target });
        }
        const link_path = try std.fmt.allocPrint(allocator, "{s}.svg", .{alias.name});
        const target_path = try std.fmt.allocPrint(allocator, "{s}.svg", .{alias.target});
        scalable_dir.deleteFile(io, link_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try scalable_dir.symLink(io, target_path, link_path, .{});
    }

    try out_dir.writeFile(io, .{ .sub_path = "index.theme", .data = index_theme });
    try cwd.copyFile(license_path, out_dir, "LICENSE", io, .{});
    try out_dir.writeFile(io, .{ .sub_path = ".stamp", .data = stamp });
}

fn parseAliases(allocator: std.mem.Allocator, bytes: []const u8, path: []const u8) ![]Alias {
    var aliases: std.ArrayList(Alias) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_number: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
        const name = fields.next() orelse unreachable;
        const target = fields.next() orelse fail("{s}:{d}: expected '<xdg-name> <phosphor-name>'", .{ path, line_number });
        if (fields.next() != null) fail("{s}:{d}: expected '<xdg-name> <phosphor-name>'", .{ path, line_number });
        if (seen.contains(name)) fail("{s}:{d}: duplicate alias '{s}'", .{ path, line_number, name });
        try seen.put(allocator, name, {});
        try aliases.append(allocator, .{ .name = name, .target = target, .line = line_number });
    }
    return aliases.items;
}

fn stampMatches(io: std.Io, cwd: std.Io.Dir, out_path: []const u8, stamp: []const u8) bool {
    var buffer: [256]u8 = undefined;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const stamp_path = std.fmt.bufPrint(&path_buffer, "{s}/.stamp", .{out_path}) catch return false;
    const existing = cwd.readFile(io, stamp_path, &buffer) catch return false;
    return std.mem.eql(u8, existing, stamp);
}

fn usageError() noreturn {
    fail("usage: gen-icon-theme <regular-dir> <fill-dir> <aliases-file> <license-file> <out-dir>", .{});
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.process.fatal(format, args);
}
