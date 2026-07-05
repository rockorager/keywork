//! HarfBuzz + FreeType text rasterization for CPU backends.

const Self = @This();

const std = @import("std");
const c = @import("text_c");
const keywork = @import("core.zig");

const log = std.log.scoped(.keywork_text);

allocator: std.mem.Allocator,
library: c.FT_Library,
fonts: std.ArrayList(FontFace) = .empty,
next_font_id: u32 = 0,
fallback_cache: std.AutoHashMapUnmanaged(u21, usize) = .empty,
shape_cache: ShapeCache = .empty,
glyph_cache: GlyphCache = .empty,

const default_text_size = 16;
const primary_font_index = 0;
const max_shape_cache_entries = 512;
const ShapeCache = std.HashMapUnmanaged(ShapeKey, ShapedRun, ShapeContext, std.hash_map.default_max_load_percentage);
const GlyphCache = std.AutoHashMapUnmanaged(GlyphKey, GlyphBitmap);

const FontFace = struct {
    id: u32,
    path: []u8,
    face: c.FT_Face,
    hb_font: *c.hb_font_t,
    pixel_size: u31,

    fn init(allocator: std.mem.Allocator, library: c.FT_Library, id: u32, path: []const u8) !FontFace {
        var face: c.FT_Face = null;
        if (c.FT_New_Face(library, path.ptr, 0, &face) != 0) return error.FontLoadFailed;
        errdefer _ = c.FT_Done_Face(face);

        if (c.keywork_ft_set_pixel_size(face, default_text_size) == 0) return error.FontSizeFailed;

        const hb_font = c.keywork_hb_font_create(face) orelse return error.HarfBuzzFailed;
        errdefer c.hb_font_destroy(hb_font);

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        return .{
            .id = id,
            .path = owned_path,
            .face = face,
            .hb_font = hb_font,
            .pixel_size = default_text_size,
        };
    }

    fn deinit(self: *FontFace, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        c.hb_font_destroy(self.hb_font);
        _ = c.FT_Done_Face(self.face);
    }
};

const ShapeKey = struct {
    font_id: u32,
    pixel_size: u31,
    value: []const u8,
};

const ShapeContext = struct {
    pub fn hash(_: ShapeContext, key: ShapeKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.font_id));
        hasher.update(std.mem.asBytes(&key.pixel_size));
        hasher.update(key.value);
        return hasher.final();
    }

    pub fn eql(_: ShapeContext, a: ShapeKey, b: ShapeKey) bool {
        return a.font_id == b.font_id and a.pixel_size == b.pixel_size and std.mem.eql(u8, a.value, b.value);
    }
};

const ShapedRun = struct {
    glyphs: []c.KeyworkGlyph,
    advance: f32,

    fn deinit(self: ShapedRun, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
    }
};

const GlyphKey = struct {
    font_id: u32,
    pixel_size: u31,
    glyph_index: u32,
};

pub const GlyphBitmap = struct {
    width: u32,
    rows: u32,
    left: i32,
    top: i32,
    coverage: []u8,

    fn deinit(self: GlyphBitmap, allocator: std.mem.Allocator) void {
        if (self.coverage.len > 0) allocator.free(self.coverage);
    }
};

pub const PositionedGlyph = struct {
    font_id: u32,
    pixel_size: u31,
    glyph_index: u32,
    x: f32,
    y: f32,
    color: keywork.Color,
    width: u32,
    rows: u32,
    coverage: []const u8,
};

const FontRun = struct {
    font_index: usize,
    value: []const u8,
};

const CodepointSlice = struct {
    value: []const u8,
    codepoint: u21,
};

pub fn init(allocator: std.mem.Allocator) !Self {
    var font_path: [4096]u8 = undefined;
    if (c.keywork_fontconfig_match_default(font_path[0..].ptr, font_path.len) == 0) return error.FontMatchFailed;

    var library: c.FT_Library = null;
    if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeFailed;
    errdefer _ = c.FT_Done_FreeType(library);

    var self: Self = .{ .allocator = allocator, .library = library };
    errdefer self.deinit();

    _ = try self.loadFont(std.mem.sliceTo(font_path[0..], 0));
    log.info("loaded font {s}", .{self.fonts.items[primary_font_index].path});
    return self;
}

pub fn deinit(self: *Self) void {
    self.clearShapeCache();
    self.shape_cache.deinit(self.allocator);
    self.clearGlyphCache();
    self.glyph_cache.deinit(self.allocator);
    self.fallback_cache.deinit(self.allocator);
    for (self.fonts.items) |*font| font.deinit(self.allocator);
    self.fonts.deinit(self.allocator);
    _ = c.FT_Done_FreeType(self.library);
}

pub fn render(
    self: *Self,
    pixels: []u32,
    width: u31,
    height: u31,
    scale: f32,
    text: keywork.PaintCommand.TextRun,
) !void {
    const pixel_size = try scaledPixelSize(scale, text.style.font_size);
    try self.ensureFontPixelSize(primary_font_index, pixel_size);

    const primary = &self.fonts.items[primary_font_index];
    const ascender: f32 = @floatFromInt(c.keywork_ft_ascender(primary.face));
    const line_height: f32 = @floatFromInt(@max(1, c.keywork_ft_line_height(primary.face)));
    const origin_x = snapToPixel(text.origin.x * scale);
    var baseline_y = snapToPixel(text.origin.y * scale) + ascender;

    var line_start: usize = 0;
    while (line_start <= text.value.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text.value, line_start, '\n') orelse text.value.len;
        try self.renderLine(pixels, width, height, origin_x, baseline_y, text.value[line_start..line_end], text.style.color, pixel_size);
        if (line_end == text.value.len) break;
        line_start = line_end + 1;
        baseline_y += line_height;
    }
}

pub fn measure(self: *Self, scale: f32, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
    const pixel_size = try scaledPixelSize(scale, style.font_size);
    try self.ensureFontPixelSize(primary_font_index, pixel_size);

    const primary = &self.fonts.items[primary_font_index];
    const line_height_pixels: f32 = @floatFromInt(@max(1, c.keywork_ft_line_height(primary.face)));
    const line_height = line_height_pixels / scale;
    var max_width: f32 = 0;
    var line_count: usize = 0;

    var line_start: usize = 0;
    while (line_start <= value.len) {
        const line_end = std.mem.indexOfScalarPos(u8, value, line_start, '\n') orelse value.len;
        max_width = @max(max_width, try self.measureLine(value[line_start..line_end], pixel_size) / scale);
        line_count += 1;
        if (line_end == value.len) break;
        line_start = line_end + 1;
    }

    return .{ .width = max_width, .height = @as(f32, @floatFromInt(line_count)) * line_height };
}

pub fn appendGlyphs(
    self: *Self,
    allocator: std.mem.Allocator,
    scale: f32,
    text: keywork.PaintCommand.TextRun,
    out: *std.ArrayList(PositionedGlyph),
) !void {
    const pixel_size = try scaledPixelSize(scale, text.style.font_size);
    try self.ensureFontPixelSize(primary_font_index, pixel_size);

    const primary = &self.fonts.items[primary_font_index];
    const ascender: f32 = @floatFromInt(c.keywork_ft_ascender(primary.face));
    const line_height: f32 = @floatFromInt(@max(1, c.keywork_ft_line_height(primary.face)));
    const origin_x = snapToPixel(text.origin.x * scale);
    var baseline_y = snapToPixel(text.origin.y * scale) + ascender;

    var line_start: usize = 0;
    while (line_start <= text.value.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text.value, line_start, '\n') orelse text.value.len;
        try self.appendLineGlyphs(allocator, origin_x, baseline_y, text.value[line_start..line_end], text.style.color, pixel_size, out);
        if (line_end == text.value.len) break;
        line_start = line_end + 1;
        baseline_y += line_height;
    }
}

fn loadFont(self: *Self, path: []const u8) !usize {
    for (self.fonts.items, 0..) |font, index| {
        if (std.mem.eql(u8, font.path, path)) return index;
    }

    const font = try FontFace.init(self.allocator, self.library, self.next_font_id, path);
    errdefer {
        var mutable_font = font;
        mutable_font.deinit(self.allocator);
    }
    try self.fonts.append(self.allocator, font);
    self.next_font_id += 1;
    if (font.id != 0) log.info("loaded fallback font {s}", .{path});
    return self.fonts.items.len - 1;
}

fn ensureFontPixelSize(self: *Self, font_index: usize, pixel_size: u31) !void {
    const font = &self.fonts.items[font_index];
    if (font.pixel_size == pixel_size) return;
    if (c.keywork_ft_set_pixel_size(font.face, pixel_size) == 0) return error.FontSizeFailed;
    c.hb_ft_font_changed(font.hb_font);
    font.pixel_size = pixel_size;
}

fn measureLine(self: *Self, value: []const u8, pixel_size: u31) !f32 {
    if (value.len == 0) return 0;

    var index: usize = 0;
    var pen_x: f32 = 0;
    while (try self.nextFontRun(value, &index)) |run| {
        const shaped = try self.shapeRun(run.font_index, pixel_size, run.value);
        for (shaped.glyphs) |glyph| {
            pen_x += fromFixed26Dot6(glyph.x_advance);
        }
    }
    return pen_x;
}

fn renderLine(
    self: *Self,
    pixels: []u32,
    width: u31,
    height: u31,
    x: f32,
    baseline_y: f32,
    value: []const u8,
    color: keywork.Color,
    pixel_size: u31,
) !void {
    if (value.len == 0) return;

    var index: usize = 0;
    var pen_x = x;
    var pen_y = baseline_y;
    while (try self.nextFontRun(value, &index)) |run| {
        const shaped = try self.shapeRun(run.font_index, pixel_size, run.value);
        for (shaped.glyphs) |glyph| {
            if (try self.glyphBitmap(run.font_index, pixel_size, glyph.glyph_index)) |bitmap| {
                blitGlyphBitmap(
                    bitmap,
                    pixels,
                    width,
                    height,
                    pen_x + fromFixed26Dot6(glyph.x_offset),
                    pen_y - fromFixed26Dot6(glyph.y_offset),
                    color,
                );
            }
            pen_x += fromFixed26Dot6(glyph.x_advance);
            pen_y -= fromFixed26Dot6(glyph.y_advance);
        }
    }
}

fn appendLineGlyphs(
    self: *Self,
    allocator: std.mem.Allocator,
    x: f32,
    baseline_y: f32,
    value: []const u8,
    color: keywork.Color,
    pixel_size: u31,
    out: *std.ArrayList(PositionedGlyph),
) !void {
    if (value.len == 0) return;

    var index: usize = 0;
    var pen_x = x;
    var pen_y = baseline_y;
    while (try self.nextFontRun(value, &index)) |run| {
        const shaped = try self.shapeRun(run.font_index, pixel_size, run.value);
        const font = &self.fonts.items[run.font_index];
        for (shaped.glyphs) |glyph| {
            if (try self.glyphBitmap(run.font_index, pixel_size, glyph.glyph_index)) |bitmap| {
                if (bitmap.width > 0 and bitmap.rows > 0) {
                    try out.append(allocator, .{
                        .font_id = font.id,
                        .pixel_size = pixel_size,
                        .glyph_index = glyph.glyph_index,
                        .x = pen_x + fromFixed26Dot6(glyph.x_offset) + @as(f32, @floatFromInt(bitmap.left)),
                        .y = pen_y - fromFixed26Dot6(glyph.y_offset) - @as(f32, @floatFromInt(bitmap.top)),
                        .color = color,
                        .width = bitmap.width,
                        .rows = bitmap.rows,
                        .coverage = bitmap.coverage,
                    });
                }
            }
            pen_x += fromFixed26Dot6(glyph.x_advance);
            pen_y -= fromFixed26Dot6(glyph.y_advance);
        }
    }
}

fn nextFontRun(self: *Self, value: []const u8, index: *usize) !?FontRun {
    if (index.* >= value.len) return null;

    const run_start = index.*;
    const first = try nextCodepoint(value, index);
    const font_index = try self.fontForCodepoint(first.codepoint);

    while (index.* < value.len) {
        const saved = index.*;
        const codepoint = try nextCodepoint(value, index);
        const next_font_index = try self.fontForCodepoint(codepoint.codepoint);
        if (next_font_index != font_index) {
            index.* = saved;
            break;
        }
    }

    return .{ .font_index = font_index, .value = value[run_start..index.*] };
}

fn nextCodepoint(value: []const u8, index: *usize) !CodepointSlice {
    const start = index.*;
    const length = try std.unicode.utf8ByteSequenceLength(value[start]);
    const end = start + length;
    if (end > value.len) return error.TruncatedUtf8;
    const slice = value[start..end];
    index.* = end;
    return .{ .value = slice, .codepoint = try std.unicode.utf8Decode(slice) };
}

fn fontForCodepoint(self: *Self, codepoint: u21) !usize {
    if (self.fontSupports(primary_font_index, codepoint)) return primary_font_index;
    if (self.fallback_cache.get(codepoint)) |font_index| return font_index;

    var font_path: [4096]u8 = undefined;
    const font_index = fallback: {
        if (c.keywork_fontconfig_match_codepoint(codepoint, font_path[0..].ptr, font_path.len) == 0) break :fallback primary_font_index;
        const path = std.mem.sliceTo(font_path[0..], 0);
        const loaded_index = self.loadFont(path) catch break :fallback primary_font_index;
        if (!self.fontSupports(loaded_index, codepoint)) break :fallback primary_font_index;
        break :fallback loaded_index;
    };

    try self.fallback_cache.put(self.allocator, codepoint, font_index);
    return font_index;
}

fn fontSupports(self: *Self, font_index: usize, codepoint: u21) bool {
    return c.keywork_ft_get_char_index(self.fonts.items[font_index].face, codepoint) != 0;
}

fn shapeRun(self: *Self, font_index: usize, pixel_size: u31, value: []const u8) !*const ShapedRun {
    if (value.len > std.math.maxInt(c_int)) return error.TextTooLong;
    if (value.len > std.math.maxInt(c_uint)) return error.TextTooLong;
    try self.ensureFontPixelSize(font_index, pixel_size);

    const font = &self.fonts.items[font_index];
    const lookup_key: ShapeKey = .{ .font_id = font.id, .pixel_size = pixel_size, .value = value };
    if (self.shape_cache.getPtrContext(lookup_key, .{})) |run| return run;
    if (self.shape_cache.count() >= max_shape_cache_entries) self.clearShapeCache();

    const scratch_glyphs = try self.allocator.alloc(c.KeyworkGlyph, @max(value.len, 1));
    defer self.allocator.free(scratch_glyphs);

    const count = c.keywork_hb_shape_text(
        font.hb_font,
        value.ptr,
        @intCast(value.len),
        scratch_glyphs.ptr,
        @intCast(scratch_glyphs.len),
    );

    const owned_value = try self.allocator.dupe(u8, value);
    errdefer self.allocator.free(owned_value);
    const owned_glyphs = try self.allocator.dupe(c.KeyworkGlyph, scratch_glyphs[0..count]);
    errdefer self.allocator.free(owned_glyphs);

    var advance: f32 = 0;
    for (owned_glyphs) |glyph| {
        advance += fromFixed26Dot6(glyph.x_advance);
    }

    const result = try self.shape_cache.getOrPutContext(self.allocator, lookup_key, .{});
    if (result.found_existing) {
        self.allocator.free(owned_value);
        self.allocator.free(owned_glyphs);
        return result.value_ptr;
    }

    result.key_ptr.* = .{ .font_id = font.id, .pixel_size = pixel_size, .value = owned_value };
    result.value_ptr.* = .{ .glyphs = owned_glyphs, .advance = advance };
    return result.value_ptr;
}

fn clearShapeCache(self: *Self) void {
    var entries = self.shape_cache.iterator();
    while (entries.next()) |entry| {
        self.allocator.free(entry.key_ptr.value);
        entry.value_ptr.deinit(self.allocator);
    }
    self.shape_cache.clearRetainingCapacity();
}

fn glyphBitmap(self: *Self, font_index: usize, pixel_size: u31, glyph_index: u32) !?*const GlyphBitmap {
    try self.ensureFontPixelSize(font_index, pixel_size);
    const font = &self.fonts.items[font_index];
    const key: GlyphKey = .{ .font_id = font.id, .pixel_size = pixel_size, .glyph_index = glyph_index };
    if (self.glyph_cache.getPtr(key)) |bitmap| return bitmap;

    if (c.keywork_ft_load_render_glyph(font.face, glyph_index) == 0) return null;

    var bitmap = try self.copyCurrentGlyphBitmap(font.face);
    errdefer bitmap.deinit(self.allocator);

    const result = try self.glyph_cache.getOrPut(self.allocator, key);
    std.debug.assert(!result.found_existing);
    result.value_ptr.* = bitmap;
    return result.value_ptr;
}

fn copyCurrentGlyphBitmap(self: *Self, face: c.FT_Face) !GlyphBitmap {
    const bitmap_width: u32 = @intCast(c.keywork_ft_bitmap_width(face));
    const bitmap_rows: u32 = @intCast(c.keywork_ft_bitmap_rows(face));
    const left = c.keywork_ft_bitmap_left(face);
    const top = c.keywork_ft_bitmap_top(face);
    if (bitmap_width == 0 or bitmap_rows == 0) {
        return .{ .width = bitmap_width, .rows = bitmap_rows, .left = left, .top = top, .coverage = &.{} };
    }

    const bitmap_buffer = c.keywork_ft_bitmap_buffer(face);
    if (bitmap_buffer == null) {
        return .{ .width = 0, .rows = 0, .left = left, .top = top, .coverage = &.{} };
    }

    const coverage = try self.allocator.alloc(u8, @as(usize, bitmap_width) * bitmap_rows);
    errdefer self.allocator.free(coverage);

    const pitch = c.keywork_ft_bitmap_pitch(face);
    const pitch_abs: usize = @intCast(@abs(pitch));
    var row: usize = 0;
    while (row < bitmap_rows) : (row += 1) {
        const src_row = if (pitch >= 0) row else bitmap_rows - 1 - row;
        const width: usize = @intCast(bitmap_width);
        const src = bitmap_buffer[src_row * pitch_abs ..][0..width];
        const dst = coverage[row * width ..][0..width];
        @memcpy(dst, src);
    }

    return .{ .width = bitmap_width, .rows = bitmap_rows, .left = left, .top = top, .coverage = coverage };
}

fn clearGlyphCache(self: *Self) void {
    var values = self.glyph_cache.valueIterator();
    while (values.next()) |bitmap| {
        bitmap.deinit(self.allocator);
    }
    self.glyph_cache.clearRetainingCapacity();
}

fn blitGlyphBitmap(
    bitmap: *const GlyphBitmap,
    pixels: []u32,
    width: u31,
    height: u31,
    glyph_origin_x: f32,
    glyph_baseline_y: f32,
    color: keywork.Color,
) void {
    if (bitmap.width == 0 or bitmap.rows == 0) return;

    const left: f32 = @floatFromInt(bitmap.left);
    const top: f32 = @floatFromInt(bitmap.top);
    const dst_x0: i32 = @intFromFloat(@floor(glyph_origin_x + left));
    const dst_y0: i32 = @intFromFloat(@floor(glyph_baseline_y - top));

    var row: usize = 0;
    while (row < bitmap.rows) : (row += 1) {
        var column: usize = 0;
        const bitmap_width: usize = @intCast(bitmap.width);
        while (column < bitmap_width) : (column += 1) {
            const coverage = bitmap.coverage[row * bitmap_width + column];
            if (coverage == 0) continue;
            blendPixel(
                pixels,
                width,
                height,
                dst_x0 + @as(i32, @intCast(column)),
                dst_y0 + @as(i32, @intCast(row)),
                color,
                coverage,
            );
        }
    }
}

fn blendPixel(pixels: []u32, width: u31, height: u31, x: i32, y: i32, color: keywork.Color, coverage: u8) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= width or uy >= height) return;

    const index = uy * width + ux;
    const dst: keywork.Color = @bitCast(pixels[index]);
    const src_a = (@as(u32, color.a) * coverage + 127) / 255;
    const inv_a = 255 - src_a;

    const out: keywork.Color = .{
        .a = @intCast(src_a + (@as(u32, dst.a) * inv_a + 127) / 255),
        .r = @intCast((@as(u32, color.r) * src_a + @as(u32, dst.r) * inv_a + 127) / 255),
        .g = @intCast((@as(u32, color.g) * src_a + @as(u32, dst.g) * inv_a + 127) / 255),
        .b = @intCast((@as(u32, color.b) * src_a + @as(u32, dst.b) * inv_a + 127) / 255),
    };
    pixels[index] = @bitCast(out);
}

fn scaledPixelSize(scale: f32, font_size: f32) !u31 {
    if (!std.math.isFinite(scale) or scale <= 0 or !std.math.isFinite(font_size) or font_size <= 0) return error.InvalidScale;
    const rounded = @round(font_size * scale);
    if (rounded < 1 or rounded > @as(f32, @floatFromInt(std.math.maxInt(u31)))) return error.InvalidScale;
    return @intFromFloat(rounded);
}

fn snapToPixel(value: f32) f32 {
    return @round(value);
}

fn fromFixed26Dot6(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / 64.0;
}
