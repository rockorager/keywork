//! Lua adaptation for the runtime-owned raster-image widget.

const std = @import("std");
const native_runtime = @import("keywork-runtime");
const keywork = @import("keywork-ui");
const lua_codec = @import("codec.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const RasterImage = native_runtime.RasterImage;
const absoluteIndex = lua_value.absoluteIndex;
const expectType = lua_value.expectType;
const pop = lua_value.pop;
const stringFromStack = lua_value.stringFromStack;

const Options = struct {
    path: ?[]const u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    size: ?f32 = null,
    format: []const u8 = "argb32",
    fit: RasterImage.Fit = .fill,
    @"align": RasterImage.Alignment = .center,
    cache: RasterImage.Cache = .auto,
    revision: f64 = 0,
};

pub fn parse(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    dims_cache: ?*RasterImage.DimsCache,
    table: c_int,
) !keywork.Widget {
    const options = try lua_codec.decode(Options, lua_state, table, allocator);

    c.lua_getfield(lua_state, table, "pixels");
    defer pop(lua_state, 1);
    const has_pixels = !c.lua_isnil(lua_state, -1);
    if ((options.path != null) == has_pixels) return error.InvalidImageSource;

    if (options.path) |path| return RasterImage.fromFile(
        allocator,
        dims_cache,
        path,
        nativeOptions(options, try imageRevision(options.revision)),
    );

    try RasterImage.validateDimensions(options.width, options.height);
    if (!std.mem.eql(u8, options.format, "argb32")) return error.UnsupportedImageFormat;
    const pixels = try parseArgb32Pixels(lua_state, allocator, -1, options.width, options.height);
    errdefer allocator.free(pixels);
    return RasterImage.fromOwnedPixels(allocator, pixels, nativeOptions(options, 0));
}

fn nativeOptions(options: Options, revision: u64) RasterImage.Options {
    return .{
        .width = options.width,
        .height = options.height,
        .size = options.size,
        .fit = options.fit,
        .alignment = options.@"align",
        .cache = options.cache,
        .revision = revision,
    };
}

fn imageRevision(value: f64) !u64 {
    const max_exact_integer: f64 = 9007199254740991;
    if (!std.math.isFinite(value) or value < 0 or value > max_exact_integer or value != @floor(value)) return error.InvalidImageRevision;
    return @intFromFloat(value);
}

fn parseArgb32Pixels(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    index: c_int,
    width: u32,
    height: u32,
) ![]keywork.Color {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const byte_count = pixel_count * 4;
    const pixels = try allocator.alloc(keywork.Color, pixel_count);
    errdefer allocator.free(pixels);

    if (c.lua_type(lua_state, index) == c.LUA_TSTRING) {
        const bytes = try stringFromStack(lua_state, index);
        if (bytes.len < byte_count) return error.InvalidImagePixels;
        fillArgb32Pixels(pixels, bytes[0..byte_count]);
        return pixels;
    }

    try expectType(lua_state, index, c.LUA_TTABLE);
    const table = absoluteIndex(lua_state, index);
    var pixel_index: usize = 0;
    while (pixel_index < pixel_count) : (pixel_index += 1) {
        const base: c_int = @intCast(pixel_index * 4);
        const a = try imageByteField(lua_state, table, base + 1);
        const r = try imageByteField(lua_state, table, base + 2);
        const g = try imageByteField(lua_state, table, base + 3);
        const b = try imageByteField(lua_state, table, base + 4);
        pixels[pixel_index] = keywork.Color.argb(a, r, g, b);
    }
    return pixels;
}

fn fillArgb32Pixels(pixels: []keywork.Color, bytes: []const u8) void {
    for (pixels, 0..) |*pixel, index| {
        const base = index * 4;
        pixel.* = keywork.Color.argb(bytes[base], bytes[base + 1], bytes[base + 2], bytes[base + 3]);
    }
}

fn imageByteField(lua_state: *c.lua_State, table: c_int, index: c_int) !u8 {
    c.lua_rawgeti(lua_state, table, index);
    defer pop(lua_state, 1);
    if (c.lua_isnumber(lua_state, -1) == 0) return error.InvalidImagePixels;
    const value = c.lua_tointeger(lua_state, -1);
    if (value < 0 or value > 255) return error.InvalidImagePixels;
    return @intCast(value);
}

test "image options map onto the native raster contract" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);

    c.lua_newtable(lua_state);
    const table = c.lua_gettop(lua_state);
    lua_value.setStringField(lua_state, table, "path", "/tmp/wallpaper.png");
    lua_value.setStringField(lua_state, table, "fit", "cover");
    lua_value.setStringField(lua_state, table, "align", "bottom_right");
    lua_value.setStringField(lua_state, table, "cache", "frame");
    lua_value.setIntegerField(lua_state, table, "revision", 7);

    const options = try lua_codec.decode(Options, lua_state, table, std.testing.allocator);
    const native = nativeOptions(options, try imageRevision(options.revision));
    try std.testing.expectEqual(RasterImage.Fit.cover, native.fit);
    try std.testing.expectEqual(RasterImage.Alignment.bottom_right, native.alignment);
    try std.testing.expectEqual(RasterImage.Cache.frame, native.cache);
    try std.testing.expectEqual(@as(u64, 7), native.revision);
    try std.testing.expectError(error.InvalidImageRevision, imageRevision(-1));
    try std.testing.expectError(error.InvalidImageRevision, imageRevision(1.5));
    try std.testing.expectError(error.InvalidImageRevision, imageRevision(std.math.inf(f64)));
    try std.testing.expectEqual(table, c.lua_gettop(lua_state));
}

test "image requires exactly one source" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);

    c.lua_newtable(lua_state);
    const table = c.lua_gettop(lua_state);
    try std.testing.expectError(error.InvalidImageSource, parse(lua_state, std.testing.allocator, null, table));

    lua_value.setStringField(lua_state, table, "path", "/tmp/wallpaper.png");
    lua_value.setStringField(lua_state, table, "pixels", "argb");
    try std.testing.expectError(error.InvalidImageSource, parse(lua_state, std.testing.allocator, null, table));
    try std.testing.expectEqual(table, c.lua_gettop(lua_state));
}

test "pixel image parses through the native raster contract" {
    const allocator = std.testing.allocator;
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);

    c.lua_newtable(lua_state);
    const table = c.lua_gettop(lua_state);
    lua_value.setIntegerField(lua_state, table, "width", 2);
    lua_value.setIntegerField(lua_state, table, "height", 1);
    const pixels = [_]u8{ 255, 255, 0, 0, 255, 0, 0, 255 };
    c.lua_pushlstring(lua_state, &pixels, pixels.len);
    c.lua_setfield(lua_state, table, "pixels");

    const widget = try parse(lua_state, allocator, null, table);
    const render_object = switch (widget) {
        .render_object => |value| value,
        else => return error.ExpectedRenderObject,
    };
    defer render_object.destroy(allocator);
    const size = try render_object.layout(.{
        .constraints = .{ .max_width = std.math.inf(f32), .max_height = std.math.inf(f32) },
        .measurer = .fixed,
    });
    try std.testing.expectEqual(@as(f32, 2), size.width);
    try std.testing.expectEqual(@as(f32, 2), size.height);
}
