//! XDG icon-theme lookup helpers.

const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

const default_data_dirs = "/usr/local/share:/usr/share";
const max_theme_depth = 16;
const max_index_theme_bytes = 1024 * 1024;

const DirectoryType = enum {
    fixed,
    scalable,
    threshold,
};

const Directory = struct {
    path: []u8,
    size: u32 = 16,
    min_size: u32 = 16,
    max_size: u32 = 16,
    threshold: u32 = 2,
    type: DirectoryType = .threshold,

    fn deinit(self: *Directory, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }

    fn matchesSize(self: Directory, size: u32) bool {
        return switch (self.type) {
            .fixed => self.size == size,
            .scalable => self.min_size <= size and size <= self.max_size,
            .threshold => self.size >= self.threshold and self.size - self.threshold <= size and size <= self.size + self.threshold,
        };
    }

    fn distance(self: Directory, size: u32) u32 {
        return switch (self.type) {
            .fixed => distanceToPoint(self.size, size),
            .scalable => if (size < self.min_size) self.min_size - size else if (size > self.max_size) size - self.max_size else 0,
            .threshold => if (size < self.size -| self.threshold) self.size - self.threshold - size else if (size > self.size + self.threshold) size - (self.size + self.threshold) else 0,
        };
    }
};

const Theme = struct {
    directories: std.ArrayList(Directory) = .empty,
    inherits: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Theme, allocator: std.mem.Allocator) void {
        for (self.directories.items) |*directory| directory.deinit(allocator);
        self.directories.deinit(allocator);
        for (self.inherits.items) |theme| allocator.free(theme);
        self.inherits.deinit(allocator);
    }
};

pub fn lookupSvgIcon(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return lookupSvgIconSized(allocator, name, 16);
}

pub fn lookupSvgIconSized(allocator: std.mem.Allocator, name: []const u8, logical_size: f32) !?[]u8 {
    if (name.len == 0) return null;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (try exists(allocator, name)) return try allocator.dupe(u8, name);
        return null;
    }

    const size = positiveIconSize(logical_size);
    var visited: std.ArrayList([]u8) = .empty;
    defer {
        for (visited.items) |theme| allocator.free(theme);
        visited.deinit(allocator);
    }

    const theme = preferredTheme();
    if (try lookupInTheme(allocator, name, size, theme, &visited, 0)) |path| return path;
    if (!visitedContains(visited.items, "hicolor")) {
        if (try lookupInTheme(allocator, name, size, "hicolor", &visited, 0)) |path| return path;
    }
    return lookupInPixmaps(allocator, name);
}

fn lookupInTheme(
    allocator: std.mem.Allocator,
    name: []const u8,
    size: u32,
    theme_name: []const u8,
    visited: *std.ArrayList([]u8),
    depth: usize,
) !?[]u8 {
    if (depth >= max_theme_depth or visitedContains(visited.items, theme_name)) return null;
    try visited.append(allocator, try allocator.dupe(u8, theme_name));

    var inherited: std.ArrayList([]u8) = .empty;
    defer {
        for (inherited.items) |theme| allocator.free(theme);
        inherited.deinit(allocator);
    }

    if (try lookupInHomeTheme(allocator, name, size, theme_name, &inherited)) |path| return path;
    if (try lookupInDataDirThemes(allocator, name, size, theme_name, &inherited)) |path| return path;

    for (inherited.items) |parent| {
        if (try lookupInTheme(allocator, name, size, parent, visited, depth + 1)) |path| return path;
    }
    if (!std.mem.eql(u8, theme_name, "hicolor") and !visitedContains(inherited.items, "hicolor")) {
        if (try lookupInTheme(allocator, name, size, "hicolor", visited, depth + 1)) |path| return path;
    }
    return null;
}

fn lookupInHomeTheme(
    allocator: std.mem.Allocator,
    name: []const u8,
    size: u32,
    theme_name: []const u8,
    inherited: *std.ArrayList([]u8),
) !?[]u8 {
    const config_home = env("XDG_DATA_HOME") orelse blk: {
        const home = env("HOME") orelse return null;
        break :blk try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
    };
    const allocated = env("XDG_DATA_HOME") == null;
    defer if (allocated) allocator.free(config_home);
    return lookupInDataRootTheme(allocator, config_home, name, size, theme_name, inherited);
}

fn lookupInDataDirThemes(
    allocator: std.mem.Allocator,
    name: []const u8,
    size: u32,
    theme_name: []const u8,
    inherited: *std.ArrayList([]u8),
) !?[]u8 {
    const data_dirs = env("XDG_DATA_DIRS") orelse default_data_dirs;
    var it = std.mem.splitScalar(u8, data_dirs, ':');
    while (it.next()) |root| {
        if (root.len == 0) continue;
        if (try lookupInDataRootTheme(allocator, root, name, size, theme_name, inherited)) |path| return path;
    }
    return null;
}

fn lookupInDataRootTheme(
    allocator: std.mem.Allocator,
    data_root: []const u8,
    name: []const u8,
    size: u32,
    theme_name: []const u8,
    inherited: *std.ArrayList([]u8),
) !?[]u8 {
    var theme = try loadTheme(allocator, data_root, theme_name) orelse return null;
    defer theme.deinit(allocator);

    for (theme.inherits.items) |parent| {
        if (!visitedContains(inherited.items, parent)) try inherited.append(allocator, try allocator.dupe(u8, parent));
    }

    if (try lookupExactSizeInTheme(allocator, data_root, theme_name, name, size, theme.directories.items)) |path| return path;
    return lookupClosestSizeInTheme(allocator, data_root, theme_name, name, size, theme.directories.items);
}

fn lookupExactSizeInTheme(
    allocator: std.mem.Allocator,
    data_root: []const u8,
    theme_name: []const u8,
    name: []const u8,
    size: u32,
    directories: []const Directory,
) !?[]u8 {
    for (directories) |directory| {
        if (!directory.matchesSize(size)) continue;
        if (try lookupCandidate(allocator, data_root, theme_name, directory.path, name)) |path| return path;
    }
    return null;
}

fn lookupClosestSizeInTheme(
    allocator: std.mem.Allocator,
    data_root: []const u8,
    theme_name: []const u8,
    name: []const u8,
    size: u32,
    directories: []const Directory,
) !?[]u8 {
    var best_path: ?[]u8 = null;
    var best_distance: u32 = std.math.maxInt(u32);
    for (directories) |directory| {
        const path = try lookupCandidate(allocator, data_root, theme_name, directory.path, name) orelse continue;
        const candidate_distance = directory.distance(size);
        if (candidate_distance < best_distance) {
            if (best_path) |old| allocator.free(old);
            best_path = path;
            best_distance = candidate_distance;
        } else {
            allocator.free(path);
        }
    }
    return best_path;
}

fn loadTheme(allocator: std.mem.Allocator, data_root: []const u8, theme_name: []const u8) !?Theme {
    const path = try std.fmt.allocPrint(allocator, "{s}/icons/{s}/index.theme", .{ data_root, theme_name });
    defer allocator.free(path);
    const contents = try readSmallFile(allocator, path) orelse return null;
    defer allocator.free(contents);
    return try parseIndexTheme(allocator, contents);
}

fn parseIndexTheme(allocator: std.mem.Allocator, contents: []const u8) !Theme {
    var theme: Theme = .{};
    errdefer theme.deinit(allocator);

    var current_section: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = trim(std.mem.trim(u8, raw_line, "\r"));
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            current_section = trim(line[1 .. line.len - 1]);
            continue;
        }
        const section = current_section orelse continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trim(line[0..equals]);
        const value = trim(line[equals + 1 ..]);

        if (std.mem.eql(u8, section, "Icon Theme")) {
            if (std.mem.eql(u8, key, "Directories")) {
                try parseDirectories(allocator, &theme, value);
            } else if (std.mem.eql(u8, key, "Inherits")) {
                try parseInherits(allocator, &theme, value);
            }
        } else if (findDirectory(theme.directories.items, section)) |index| {
            parseDirectoryField(&theme.directories.items[index], key, value);
        }
    }
    return theme;
}

fn parseDirectories(allocator: std.mem.Allocator, theme: *Theme, value: []const u8) !void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw_directory| {
        const directory = trim(raw_directory);
        if (directory.len == 0 or findDirectory(theme.directories.items, directory) != null) continue;
        try theme.directories.append(allocator, .{ .path = try allocator.dupe(u8, directory) });
    }
}

fn parseInherits(allocator: std.mem.Allocator, theme: *Theme, value: []const u8) !void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw_parent| {
        const parent = trim(raw_parent);
        if (parent.len == 0 or visitedContains(theme.inherits.items, parent)) continue;
        try theme.inherits.append(allocator, try allocator.dupe(u8, parent));
    }
}

fn parseDirectoryField(directory: *Directory, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "Size")) {
        directory.size = parseU32(value) orelse directory.size;
        directory.min_size = directory.size;
        directory.max_size = directory.size;
    } else if (std.mem.eql(u8, key, "MinSize")) {
        directory.min_size = parseU32(value) orelse directory.min_size;
    } else if (std.mem.eql(u8, key, "MaxSize")) {
        directory.max_size = parseU32(value) orelse directory.max_size;
    } else if (std.mem.eql(u8, key, "Threshold")) {
        directory.threshold = parseU32(value) orelse directory.threshold;
    } else if (std.mem.eql(u8, key, "Type")) {
        if (std.mem.eql(u8, value, "Fixed")) directory.type = .fixed;
        if (std.mem.eql(u8, value, "Scalable")) directory.type = .scalable;
        if (std.mem.eql(u8, value, "Threshold")) directory.type = .threshold;
    }
}

fn lookupInPixmaps(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (try lookupInHomePixmaps(allocator, name)) |path| return path;
    const data_dirs = env("XDG_DATA_DIRS") orelse default_data_dirs;
    var it = std.mem.splitScalar(u8, data_dirs, ':');
    while (it.next()) |root| {
        if (root.len == 0) continue;
        if (try lookupInDataRootPixmaps(allocator, root, name)) |path| return path;
    }
    return null;
}

fn lookupInHomePixmaps(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const data_home = env("XDG_DATA_HOME") orelse blk: {
        const home = env("HOME") orelse return null;
        break :blk try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
    };
    const allocated = env("XDG_DATA_HOME") == null;
    defer if (allocated) allocator.free(data_home);
    return lookupInDataRootPixmaps(allocator, data_home, name);
}

fn lookupInDataRootPixmaps(allocator: std.mem.Allocator, data_root: []const u8, name: []const u8) !?[]u8 {
    const exact = try std.fmt.allocPrint(allocator, "{s}/pixmaps/{s}.svg", .{ data_root, name });
    defer allocator.free(exact);
    if (try exists(allocator, exact)) return try allocator.dupe(u8, exact);

    if (!std.mem.endsWith(u8, name, "-symbolic")) {
        const symbolic = try std.fmt.allocPrint(allocator, "{s}/pixmaps/{s}-symbolic.svg", .{ data_root, name });
        defer allocator.free(symbolic);
        if (try exists(allocator, symbolic)) return try allocator.dupe(u8, symbolic);
    }
    return null;
}

fn lookupCandidate(allocator: std.mem.Allocator, data_root: []const u8, theme: []const u8, dir: []const u8, name: []const u8) !?[]u8 {
    const exact = try std.fmt.allocPrint(allocator, "{s}/icons/{s}/{s}/{s}.svg", .{ data_root, theme, dir, name });
    defer allocator.free(exact);
    if (try exists(allocator, exact)) return try allocator.dupe(u8, exact);

    if (!std.mem.endsWith(u8, name, "-symbolic")) {
        const symbolic = try std.fmt.allocPrint(allocator, "{s}/icons/{s}/{s}/{s}-symbolic.svg", .{ data_root, theme, dir, name });
        defer allocator.free(symbolic);
        if (try exists(allocator, symbolic)) return try allocator.dupe(u8, symbolic);
    }
    return null;
}

fn readSmallFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const fd = posix.openat(linux.AT.FDCWD, path, .{ .CLOEXEC = true }, 0) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer _ = linux.close(fd);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_count = try posix.read(fd, &buffer);
        if (read_count == 0) break;
        if (result.items.len + read_count > max_index_theme_bytes) return error.FileTooBig;
        try result.appendSlice(allocator, buffer[0..read_count]);
    }
    return try result.toOwnedSlice(allocator);
}

fn exists(allocator: std.mem.Allocator, path: []const u8) !bool {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return linux.errno(linux.access(path_z.ptr, 0)) == .SUCCESS;
}

fn preferredTheme() []const u8 {
    return env("KEYWORK_ICON_THEME") orelse env("GTK_ICON_THEME") orelse "Adwaita";
}

fn env(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(value);
}

fn findDirectory(directories: []const Directory, path: []const u8) ?usize {
    for (directories, 0..) |directory, index| {
        if (std.mem.eql(u8, directory.path, path)) return index;
    }
    return null;
}

fn visitedContains(items: []const []u8, value: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn parseU32(value: []const u8) ?u32 {
    return std.fmt.parseInt(u32, value, 10) catch null;
}

fn positiveIconSize(logical_size: f32) u32 {
    if (!std.math.isFinite(logical_size) or logical_size <= 0) return 16;
    return @max(1, @as(u32, @intFromFloat(@round(logical_size))));
}

fn distanceToPoint(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

test "lookup returns null for a missing icon" {
    try std.testing.expect(try lookupSvgIcon(std.testing.allocator, "keywork-definitely-missing-icon") == null);
}

test "parse index theme directories and inherited themes" {
    var theme = try parseIndexTheme(std.testing.allocator,
        \\[Icon Theme]
        \\Directories=16x16/actions,scalable/status
        \\Inherits=hicolor,Adwaita
        \\
        \\[16x16/actions]
        \\Size=16
        \\Type=Fixed
        \\
        \\[scalable/status]
        \\Size=24
        \\Type=Scalable
        \\MinSize=8
        \\MaxSize=512
    );
    defer theme.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), theme.directories.items.len);
    try std.testing.expect(theme.directories.items[0].matchesSize(16));
    try std.testing.expect(theme.directories.items[1].matchesSize(128));
    try std.testing.expectEqual(@as(usize, 2), theme.inherits.items.len);
}
