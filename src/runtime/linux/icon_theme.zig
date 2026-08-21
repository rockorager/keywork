//! XDG icon-theme lookup helpers.

const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

const log = std.log.scoped(.keywork_icon_theme);

const default_data_dirs = "/usr/local/share:/usr/share";
const max_theme_depth = 16;
const max_index_theme_bytes = 1024 * 1024;

pub const IconFormat = enum {
    svg,
    png,

    fn extension(self: IconFormat) []const u8 {
        return switch (self) {
            .svg => "svg",
            .png => "png",
        };
    }
};

pub const IconFile = struct {
    path: [:0]u8,
    format: IconFormat,
};

const DirectoryType = enum {
    fixed,
    scalable,
    threshold,
};

const Directory = struct {
    path: []u8,
    size: u32 = 16,
    // MinSize and MaxSize default to Size, but only once parsing is
    // done: index.theme key order is arbitrary (hicolor writes MinSize
    // before Size), so the fallback is resolved at use time instead of
    // being baked in while parsing.
    min_size: ?u32 = null,
    max_size: ?u32 = null,
    threshold: u32 = 2,
    type: DirectoryType = .threshold,

    fn deinit(self: *Directory, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }

    fn minSize(self: Directory) u32 {
        return self.min_size orelse self.size;
    }

    fn maxSize(self: Directory) u32 {
        return self.max_size orelse self.size;
    }

    fn matchesSize(self: Directory, size: u32) bool {
        return switch (self.type) {
            .fixed => self.size == size,
            .scalable => self.minSize() <= size and size <= self.maxSize(),
            .threshold => self.size -| self.threshold <= size and size <= self.size +| self.threshold,
        };
    }

    fn distance(self: Directory, size: u32) u32 {
        return switch (self.type) {
            .fixed => distanceToPoint(self.size, size),
            .scalable => if (size < self.minSize()) self.minSize() - size else if (size > self.maxSize()) size - self.maxSize() else 0,
            .threshold => if (size < self.size -| self.threshold) self.size -| self.threshold - size else if (size > self.size +| self.threshold) size - (self.size +| self.threshold) else 0,
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

/// Caches name+size lookups, including misses (tombstones), so icons
/// that resolve to nothing don't re-walk the theme directories on
/// every rebuild. Entries live until deinit; an icon-theme change at
/// runtime keeps serving stale results until the process restarts.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(?IconFile) = .empty,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |icon| self.allocator.free(icon.path);
        }
        self.entries.deinit(self.allocator);
    }

    /// The returned icon path is owned by the cache and stays valid
    /// until deinit; null means the icon is known to be missing.
    pub fn lookup(self: *Cache, name: []const u8, logical_size: f32) !?IconFile {
        return self.lookupPreferred(name, logical_size, false);
    }

    /// Prefers the name's -symbolic variant when requested, then falls
    /// back to the regular icon. The preference is part of the cache key.
    pub fn lookupPreferred(self: *Cache, name: []const u8, logical_size: f32, prefer_symbolic: bool) !?IconFile {
        const size = positiveIconSize(logical_size);
        // Hits are the hot path (every icon widget on every rebuild):
        // probe with a stack-formatted key so they stay allocation-free.
        var buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{d}\x00{d}\x00{s}", .{ size, @intFromBool(prefer_symbolic), name })) |probe| {
            if (self.entries.get(probe)) |cached| return cached;
        } else |_| {}
        const key = try std.fmt.allocPrint(self.allocator, "{d}\x00{d}\x00{s}", .{ size, @intFromBool(prefer_symbolic), name });
        errdefer self.allocator.free(key);
        if (self.entries.get(key)) |cached| {
            self.allocator.free(key);
            return cached;
        }
        const icon = try lookupIconSizedPreferred(self.allocator, name, logical_size, prefer_symbolic);
        errdefer if (icon) |value| self.allocator.free(value.path);
        if (icon == null) log.warn("missing icon {s}", .{name});
        try self.entries.put(self.allocator, key, icon);
        return icon;
    }
};

pub fn lookupIconSized(allocator: std.mem.Allocator, name: []const u8, logical_size: f32) !?IconFile {
    return lookupIconSizedWithFormats(allocator, name, logical_size, &.{ .svg, .png });
}

/// Prefers a themed -symbolic icon while preserving ordinary lookup as
/// a fallback. Explicit symbolic names and paths keep their normal meaning.
pub fn lookupIconSizedPreferred(allocator: std.mem.Allocator, name: []const u8, logical_size: f32, prefer_symbolic: bool) !?IconFile {
    if (!prefer_symbolic or std.mem.endsWith(u8, name, "-symbolic") or std.mem.indexOfScalar(u8, name, '/') != null) return lookupIconSized(allocator, name, logical_size);

    const symbolic_name = try std.fmt.allocPrint(allocator, "{s}-symbolic", .{name});
    defer allocator.free(symbolic_name);
    if (try lookupIconSizedWithFormats(allocator, symbolic_name, logical_size, &.{ .svg, .png })) |icon| return icon;
    return lookupIconSized(allocator, name, logical_size);
}

fn lookupIconSizedWithFormats(allocator: std.mem.Allocator, name: []const u8, logical_size: f32, formats: []const IconFormat) !?IconFile {
    if (name.len == 0) return null;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        // Only absolute paths bypass theme lookup (the spec allows them
        // in desktop entries); relative names with slashes are neither
        // valid icon names nor paths we want to resolve from the cwd.
        if (name[0] != '/') return null;
        if (formatFromPath(name, formats)) |format| {
            const path = try allocator.dupeZ(u8, name);
            if (exists(path)) return .{ .path = path, .format = format };
            allocator.free(path);
        }
        return null;
    }

    const size = positiveIconSize(logical_size);
    var visited: std.ArrayList([]u8) = .empty;
    defer {
        for (visited.items) |theme| allocator.free(theme);
        visited.deinit(allocator);
    }

    const theme = preferredTheme();
    if (try lookupInTheme(allocator, name, size, theme, formats, &visited, 0)) |path| return path;
    // Keep the previous desktop fallback when the packaged Keywork theme is
    // not visible from a development or non-standard install prefix.
    if (!visitedContains(visited.items, "Adwaita")) {
        if (try lookupInTheme(allocator, name, size, "Adwaita", formats, &visited, 0)) |path| return path;
    }
    if (!visitedContains(visited.items, "hicolor")) {
        if (try lookupInTheme(allocator, name, size, "hicolor", formats, &visited, 0)) |path| return path;
    }
    return lookupInPixmaps(allocator, name, formats);
}

fn lookupInTheme(
    allocator: std.mem.Allocator,
    name: []const u8,
    size: u32,
    theme_name: []const u8,
    formats: []const IconFormat,
    visited: *std.ArrayList([]u8),
    depth: usize,
) !?IconFile {
    if (depth >= max_theme_depth or visitedContains(visited.items, theme_name)) return null;
    if (!safeSubpath(theme_name)) return null;
    try visited.append(allocator, try allocator.dupe(u8, theme_name));

    var icon_roots = try collectIconRoots(allocator);
    defer {
        for (icon_roots.items) |root| allocator.free(root);
        icon_roots.deinit(allocator);
    }

    var loaded_theme = try loadThemeFromIconRoots(allocator, icon_roots.items, theme_name);
    defer if (loaded_theme) |*theme| theme.deinit(allocator);
    const theme: *const Theme = if (loaded_theme) |*value| value else return null;

    if (try lookupInIconRootsTheme(allocator, icon_roots.items, theme_name, name, size, formats, theme)) |path| return path;

    for (theme.inherits.items) |parent| {
        if (try lookupInTheme(allocator, name, size, parent, formats, visited, depth + 1)) |path| return path;
    }
    if (!std.mem.eql(u8, theme_name, "hicolor") and !visitedContains(theme.inherits.items, "hicolor")) {
        if (try lookupInTheme(allocator, name, size, "hicolor", formats, visited, depth + 1)) |path| return path;
    }
    return null;
}

fn collectIconRoots(allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var roots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (roots.items) |root| allocator.free(root);
        roots.deinit(allocator);
    }
    if (env("HOME")) |home| try appendIconRoot(allocator, &roots, home, "/.icons");
    if (try allocDataHome(allocator)) |data_home| {
        defer allocator.free(data_home);
        try appendIconRoot(allocator, &roots, data_home, "/icons");
    }
    const data_dirs = env("XDG_DATA_DIRS") orelse default_data_dirs;
    var it = std.mem.splitScalar(u8, data_dirs, ':');
    while (it.next()) |root| {
        if (root.len == 0) continue;
        try appendIconRoot(allocator, &roots, root, "/icons");
    }
    return roots;
}

fn appendIconRoot(allocator: std.mem.Allocator, roots: *std.ArrayList([]u8), base: []const u8, suffix: []const u8) !void {
    const root = try std.mem.concat(allocator, u8, &.{ base, suffix });
    errdefer allocator.free(root);
    try roots.append(allocator, root);
}

fn lookupInIconRootsTheme(
    allocator: std.mem.Allocator,
    icon_roots: []const []const u8,
    theme_name: []const u8,
    name: []const u8,
    size: u32,
    formats: []const IconFormat,
    theme: *const Theme,
) !?IconFile {
    for (theme.directories.items) |directory| {
        if (!directory.matchesSize(size)) continue;
        for (icon_roots) |icon_root| {
            if (try lookupCandidate(allocator, icon_root, theme_name, directory.path, name, formats)) |path| return path;
        }
    }

    var best_icon: ?IconFile = null;
    var best_distance: u32 = std.math.maxInt(u32);
    for (theme.directories.items) |directory| {
        const candidate_distance = directory.distance(size);
        for (icon_roots) |icon_root| {
            const icon = try lookupCandidate(allocator, icon_root, theme_name, directory.path, name, formats) orelse continue;
            if (candidate_distance < best_distance) {
                if (best_icon) |old| allocator.free(old.path);
                best_icon = icon;
                best_distance = candidate_distance;
            } else {
                allocator.free(icon.path);
            }
        }
    }
    return best_icon;
}

fn loadThemeFromIconRoots(allocator: std.mem.Allocator, icon_roots: []const []const u8, theme_name: []const u8) !?Theme {
    for (icon_roots) |icon_root| {
        if (try loadThemeFromIconRoot(allocator, icon_root, theme_name)) |theme| return theme;
    }
    return null;
}

fn loadThemeFromIconRoot(allocator: std.mem.Allocator, icon_root: []const u8, theme_name: []const u8) !?Theme {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}/index.theme", .{ icon_root, theme_name });
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
        if (!safeSubpath(directory) or findDirectory(theme.directories.items, directory) != null) continue;
        try theme.directories.append(allocator, .{ .path = try allocator.dupe(u8, directory) });
    }
}

fn parseInherits(allocator: std.mem.Allocator, theme: *Theme, value: []const u8) !void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw_parent| {
        const parent = trim(raw_parent);
        if (!safeSubpath(parent) or visitedContains(theme.inherits.items, parent)) continue;
        try theme.inherits.append(allocator, try allocator.dupe(u8, parent));
    }
}

fn parseDirectoryField(directory: *Directory, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "Size")) {
        directory.size = parseU32(value) orelse directory.size;
    } else if (std.mem.eql(u8, key, "MinSize")) {
        if (parseU32(value)) |min_size| directory.min_size = min_size;
    } else if (std.mem.eql(u8, key, "MaxSize")) {
        if (parseU32(value)) |max_size| directory.max_size = max_size;
    } else if (std.mem.eql(u8, key, "Threshold")) {
        directory.threshold = parseU32(value) orelse directory.threshold;
    } else if (std.mem.eql(u8, key, "Type")) {
        if (std.mem.eql(u8, value, "Fixed")) directory.type = .fixed;
        if (std.mem.eql(u8, value, "Scalable")) directory.type = .scalable;
        if (std.mem.eql(u8, value, "Threshold")) directory.type = .threshold;
    }
}

fn lookupInPixmaps(allocator: std.mem.Allocator, name: []const u8, formats: []const IconFormat) !?IconFile {
    if (try lookupInHomePixmaps(allocator, name, formats)) |path| return path;
    const data_dirs = env("XDG_DATA_DIRS") orelse default_data_dirs;
    var it = std.mem.splitScalar(u8, data_dirs, ':');
    while (it.next()) |root| {
        if (root.len == 0) continue;
        if (try lookupInDataRootPixmaps(allocator, root, name, formats)) |path| return path;
    }
    return null;
}

fn lookupInHomePixmaps(allocator: std.mem.Allocator, name: []const u8, formats: []const IconFormat) !?IconFile {
    const data_home = try allocDataHome(allocator) orelse return null;
    defer allocator.free(data_home);
    return lookupInDataRootPixmaps(allocator, data_home, name, formats);
}

fn allocDataHome(allocator: std.mem.Allocator) !?[]u8 {
    if (env("XDG_DATA_HOME")) |data_home| return try allocator.dupe(u8, data_home);
    const home = env("HOME") orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
}

fn lookupInDataRootPixmaps(allocator: std.mem.Allocator, data_root: []const u8, name: []const u8, formats: []const IconFormat) !?IconFile {
    return lookupFileCandidates(allocator, "{s}/pixmaps/{s}.{s}", "{s}/pixmaps/{s}-symbolic.{s}", .{ data_root, name }, formats);
}

fn lookupCandidate(allocator: std.mem.Allocator, icon_root: []const u8, theme: []const u8, dir: []const u8, name: []const u8, formats: []const IconFormat) !?IconFile {
    return lookupFileCandidates(allocator, "{s}/{s}/{s}/{s}.{s}", "{s}/{s}/{s}/{s}-symbolic.{s}", .{ icon_root, theme, dir, name }, formats);
}

fn lookupFileCandidates(allocator: std.mem.Allocator, comptime exact_fmt: []const u8, comptime symbolic_fmt: []const u8, args: anytype, formats: []const IconFormat) !?IconFile {
    for (formats) |format| {
        const path = try std.fmt.allocPrintSentinel(allocator, exact_fmt, args ++ .{format.extension()}, 0);
        if (exists(path)) return .{ .path = path, .format = format };
        allocator.free(path);
    }

    if (std.mem.endsWith(u8, args[args.len - 1], "-symbolic")) return null;
    for (formats) |format| {
        const path = try std.fmt.allocPrintSentinel(allocator, symbolic_fmt, args ++ .{format.extension()}, 0);
        if (exists(path)) return .{ .path = path, .format = format };
        allocator.free(path);
    }
    return null;
}

fn formatFromPath(path: []const u8, formats: []const IconFormat) ?IconFormat {
    for (formats) |format| {
        const extension = format.extension();
        if (path.len > extension.len and path[path.len - extension.len - 1] == '.' and std.mem.endsWith(u8, path, extension)) return format;
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

fn exists(path: [:0]const u8) bool {
    return linux.errno(linux.access(path.ptr, 0)) == .SUCCESS;
}

fn preferredTheme() []const u8 {
    return preferredThemeFrom(env("KEYWORK_ICON_THEME"), env("GTK_ICON_THEME"));
}

fn preferredThemeFrom(keywork_theme: ?[]const u8, gtk_theme: ?[]const u8) []const u8 {
    return keywork_theme orelse gtk_theme orelse "Keywork";
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

/// Theme names and index.theme directory values are interpolated into
/// filesystem paths under the icons roots; reject anything that could
/// escape them (absolute paths, ".." components, empty values).
fn safeSubpath(value: []const u8) bool {
    if (value.len == 0 or value[0] == '/') return false;
    var it = std.mem.splitScalar(u8, value, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
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
    const rounded = @round(logical_size);
    if (rounded >= @as(f32, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @max(1, @as(u32, @intFromFloat(rounded)));
}

fn distanceToPoint(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

test "lookup returns null for a missing icon" {
    try std.testing.expect(try lookupIconSized(std.testing.allocator, "keywork-definitely-missing-icon", 16) == null);
}

test "icon theme preference uses overrides before Keywork default" {
    try std.testing.expectEqualStrings("explicit", preferredThemeFrom("explicit", "gtk"));
    try std.testing.expectEqualStrings("gtk", preferredThemeFrom(null, "gtk"));
    try std.testing.expectEqualStrings("Keywork", preferredThemeFrom(null, null));
}

test "icon size conversion saturates large finite values" {
    try std.testing.expectEqual(std.math.maxInt(u32), positiveIconSize(std.math.floatMax(f32)));
}

test "lookup rejects relative slash names as direct paths" {
    // A relative name with slashes is neither a theme icon name nor a
    // path we resolve from the cwd; traversal must not escape lookup.
    try std.testing.expect(try lookupIconSized(std.testing.allocator, "../etc/icon.png", 16) == null);
    try std.testing.expect(try lookupIconSized(std.testing.allocator, "icons/foo.svg", 16) == null);
}

test "safeSubpath rejects traversal and absolute values" {
    try std.testing.expect(safeSubpath("16x16/actions"));
    try std.testing.expect(safeSubpath("scalable"));
    try std.testing.expect(!safeSubpath(""));
    try std.testing.expect(!safeSubpath("/etc"));
    try std.testing.expect(!safeSubpath(".."));
    try std.testing.expect(!safeSubpath("../theme"));
    try std.testing.expect(!safeSubpath("16x16/../../escape"));
}

test "index theme parsing drops unsafe directories and inherits" {
    var theme = try parseIndexTheme(std.testing.allocator,
        \\[Icon Theme]
        \\Directories=16x16/actions,../../escape,/abs
        \\Inherits=../evil,hicolor
    );
    defer theme.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), theme.directories.items.len);
    try std.testing.expectEqualStrings("16x16/actions", theme.directories.items[0].path);
    try std.testing.expectEqual(@as(usize, 1), theme.inherits.items.len);
    try std.testing.expectEqualStrings("hicolor", theme.inherits.items[0]);
}

test "cache tombstones missing icons and serves repeat lookups" {
    // The first miss per name+size logs a warning by design; keep the
    // expected ones out of the test output.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;

    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expect(try cache.lookup("keywork-definitely-missing-icon", 16) == null);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.count());

    // The tombstone answers without a second walk or a new entry.
    try std.testing.expect(try cache.lookup("keywork-definitely-missing-icon", 16) == null);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.count());

    // A different size is a distinct lookup.
    try std.testing.expect(try cache.lookup("keywork-definitely-missing-icon", 32) == null);
    try std.testing.expectEqual(@as(usize, 2), cache.entries.count());

    // Symbolic preference can resolve to a different file, so it gets
    // an independent cache entry at the same name and size.
    try std.testing.expect(try cache.lookupPreferred("keywork-definitely-missing-icon", 16, true) == null);
    try std.testing.expectEqual(@as(usize, 3), cache.entries.count());
}

test "cache returns the same owned path for repeated hits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keywork-cache-test.svg", .data = "<svg/>" });
    const absolute = try tmp.dir.realPathFileAlloc(std.testing.io, "keywork-cache-test.svg", std.testing.allocator);
    defer std.testing.allocator.free(absolute);

    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();

    const first = (try cache.lookup(absolute, 16)).?;
    try std.testing.expectEqual(IconFormat.svg, first.format);
    try std.testing.expectEqualStrings(absolute, first.path);

    const second = (try cache.lookup(absolute, 16)).?;
    try std.testing.expectEqual(first.path.ptr, second.path.ptr);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.count());
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

test "data root without index uses theme metadata from search path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "icons/hicolor/scalable/apps");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "icons/hicolor/scalable/apps/keywork-overlay-test.svg",
        .data = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 16 16\"/>",
    });
    const data_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(data_root);

    var fallback_theme = try parseIndexTheme(std.testing.allocator,
        \\[Icon Theme]
        \\Directories=scalable/apps
        \\
        \\[scalable/apps]
        \\Size=128
        \\MinSize=1
        \\MaxSize=512
        \\Type=Scalable
    );
    defer fallback_theme.deinit(std.testing.allocator);

    const icon_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/icons", .{data_root});
    defer std.testing.allocator.free(icon_root);
    const icon = (try lookupInIconRootsTheme(
        std.testing.allocator,
        &.{icon_root},
        "hicolor",
        "keywork-overlay-test",
        32,
        &.{ .svg, .png },
        &fallback_theme,
    )).?;
    defer std.testing.allocator.free(icon.path);

    try std.testing.expectEqual(IconFormat.svg, icon.format);
    try std.testing.expect(std.mem.endsWith(u8, icon.path, "/icons/hicolor/scalable/apps/keywork-overlay-test.svg"));
}

test "exact icon matches across roots precede closest-size fallbacks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "early/test-theme/16x16/apps");
    try tmp.dir.createDirPath(std.testing.io, "late/test-theme/32x32/apps");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "early/test-theme/16x16/apps/keywork-root-order-test.svg",
        .data = "<svg/>",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "late/test-theme/32x32/apps/keywork-root-order-test.svg",
        .data = "<svg/>",
    });
    const early_root = try tmp.dir.realPathFileAlloc(std.testing.io, "early", std.testing.allocator);
    defer std.testing.allocator.free(early_root);
    const late_root = try tmp.dir.realPathFileAlloc(std.testing.io, "late", std.testing.allocator);
    defer std.testing.allocator.free(late_root);

    var theme = try parseIndexTheme(std.testing.allocator,
        \\[Icon Theme]
        \\Directories=16x16/apps,32x32/apps
        \\
        \\[16x16/apps]
        \\Size=16
        \\Type=Fixed
        \\
        \\[32x32/apps]
        \\Size=32
        \\Type=Fixed
    );
    defer theme.deinit(std.testing.allocator);

    const roots = [_][]const u8{ early_root, late_root };
    const icon = try lookupInIconRootsTheme(
        std.testing.allocator,
        &roots,
        "test-theme",
        "keywork-root-order-test",
        32,
        &.{ .svg, .png },
        &theme,
    );
    defer if (icon) |value| std.testing.allocator.free(value.path);

    try std.testing.expect(std.mem.startsWith(u8, icon.?.path, late_root));
}

test "legacy home icon root participates in themed lookup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".icons/legacy-test/32x32/apps");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".icons/legacy-test/index.theme",
        .data =
        \\[Icon Theme]
        \\Directories=32x32/apps
        \\
        \\[32x32/apps]
        \\Size=32
        \\Type=Fixed
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".icons/legacy-test/32x32/apps/keywork-legacy-home-test.svg",
        .data = "<svg/>",
    });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    const icon_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/.icons", .{home});
    defer std.testing.allocator.free(icon_root);
    var theme = (try loadThemeFromIconRoots(std.testing.allocator, &.{icon_root}, "legacy-test")).?;
    defer theme.deinit(std.testing.allocator);
    const icon = (try lookupInIconRootsTheme(
        std.testing.allocator,
        &.{icon_root},
        "legacy-test",
        "keywork-legacy-home-test",
        32,
        &.{ .svg, .png },
        &theme,
    )).?;
    defer std.testing.allocator.free(icon.path);

    try std.testing.expectEqual(IconFormat.svg, icon.format);
    try std.testing.expect(std.mem.endsWith(u8, icon.path, "/.icons/legacy-test/32x32/apps/keywork-legacy-home-test.svg"));
}

test "scalable directory size range survives any key order" {
    // hicolor writes MinSize before Size; Size must not clobber an
    // already-parsed MinSize/MaxSize (they only default to Size when
    // absent). This is why hicolor scalable/apps was skipped and app
    // icons fell through to their symbolic variants.
    var theme = try parseIndexTheme(std.testing.allocator,
        \\[Icon Theme]
        \\Directories=scalable/apps,scalable/status
        \\
        \\[scalable/apps]
        \\MinSize=1
        \\Size=128
        \\MaxSize=256
        \\Type=Scalable
        \\
        \\[scalable/status]
        \\Size=24
        \\Type=Scalable
    );
    defer theme.deinit(std.testing.allocator);

    const apps = theme.directories.items[0];
    try std.testing.expect(apps.matchesSize(1));
    try std.testing.expect(apps.matchesSize(64));
    try std.testing.expect(apps.matchesSize(256));
    try std.testing.expect(!apps.matchesSize(257));
    try std.testing.expectEqual(@as(u32, 64), apps.distance(320));

    // Without MinSize/MaxSize, the range collapses to Size.
    const status = theme.directories.items[1];
    try std.testing.expect(status.matchesSize(24));
    try std.testing.expect(!status.matchesSize(23));
    try std.testing.expect(!status.matchesSize(25));
}

test "threshold directory range saturates at integer bounds" {
    const small: Directory = .{ .path = undefined, .size = 1, .threshold = 2 };
    try std.testing.expect(small.matchesSize(1));
    try std.testing.expect(small.matchesSize(3));
    try std.testing.expect(!small.matchesSize(4));
    try std.testing.expectEqual(@as(u32, 0), small.distance(1));
    try std.testing.expectEqual(@as(u32, 1), small.distance(4));

    const large: Directory = .{
        .path = undefined,
        .size = std.math.maxInt(u32),
        .threshold = 2,
    };
    try std.testing.expect(large.matchesSize(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 0), large.distance(std.math.maxInt(u32)));
}
