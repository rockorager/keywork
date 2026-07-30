//! Stable identity for command prefixes sampled by backdrop captures.

const std = @import("std");
const render = @import("types.zig");

/// Returns null when a command references content without a stable source
/// identity, preventing reuse of a cache that cannot be validated.
pub fn key(commands: []const render.Command) ?u64 {
    var hasher = std.hash.Wyhash.init(0x6b6579776f726b);
    for (commands) |command| {
        if (!hashRenderCommand(&hasher, command)) return null;
    }
    return hasher.final();
}

/// Identifies capture geometry and blur parameters for damage-local cache
/// rekeying when sampled scene content changed outside the capture footprint.
pub fn geometryKey(capture: render.BackdropCapture) u64 {
    var hasher = std.hash.Wyhash.init(0x6261636b64726f70);
    hashRect(&hasher, capture.rect);
    hashScalar(&hasher, capture.radius);
    hashOptionalScalar(&hasher, capture.downsample_level);
    hashBackdropBlurFinish(&hasher, capture.finish);
    return hasher.final();
}

fn hashRenderCommand(hasher: *std.hash.Wyhash, command: render.Command) bool {
    switch (command) {
        .crossfade => return false,
        .clear => |color| {
            hashScalar(hasher, @as(u8, 0));
            hashColor(hasher, color);
        },
        .solid_rect => |solid| {
            hashScalar(hasher, @as(u8, 1));
            hashRect(hasher, solid.rect);
            hashColor(hasher, solid.color);
            hashOptionalRect(hasher, solid.clip);
        },
        .shadow => |shadow| {
            hashScalar(hasher, @as(u8, 2));
            hashRect(hasher, shadow.rect);
            hashScalar(hasher, shadow.corner_radius);
            hashScalar(hasher, shadow.blur_radius);
            hashScalar(hasher, shadow.spread);
            hashColor(hasher, shadow.color);
            hashOptionalColor(hasher, shadow.bottom_color);
            hashOptionalRoundedClip(hasher, shadow.cutout);
            hashOptionalRect(hasher, shadow.clip);
        },
        .backdrop_capture => |capture| {
            hashScalar(hasher, @as(u8, 3));
            hashScalar(hasher, capture.id);
            hashRect(hasher, capture.rect);
            hashScalar(hasher, capture.radius);
            hashOptionalScalar(hasher, capture.downsample_level);
            hashBackdropBlurFinish(hasher, capture.finish);
            hashScalar(hasher, @intFromBool(capture.base));
        },
        .backdrop_blur => |blur| {
            hashScalar(hasher, @as(u8, 4));
            hashScalar(hasher, blur.capture_id);
            hashRect(hasher, blur.rect);
            hashScalar(hasher, blur.corner_radius);
            hashScalar(hasher, blur.radius);
            hashOptionalScalar(hasher, blur.downsample_level);
            hashBackdropBlurFinish(hasher, blur.finish);
            hashOptionalRect(hasher, blur.clip);
        },
        .image => |image| {
            const source_cache = image.buffer.source_cache orelse return false;
            hashScalar(hasher, @as(u8, 5));
            hashScalar(hasher, image.x);
            hashScalar(hasher, image.y);
            hashSize(hasher, image.size);
            hashSize(hasher, image.buffer.size);
            hashScalar(hasher, image.buffer.stride_pixels);
            hashColorDescription(hasher, image.buffer.color_description);
            hashScalar(hasher, @intFromEnum(image.buffer.color_representation.coefficients));
            hashScalar(hasher, @intFromEnum(image.buffer.color_representation.range));
            hashOptionalScalar(hasher, image.buffer.color_representation.chroma_location);
            hashScalar(hasher, source_cache.id);
            hashScalar(hasher, source_cache.version);
            hashOptionalSourceRect(hasher, image.source);
            hashScalar(hasher, @intFromEnum(image.transform));
            hashOptionalRoundedClip(hasher, image.rounded_clip);
            hashOptionalRect(hasher, image.clip);
            hashScalar(hasher, @intFromBool(image.is_opaque));
            hashScalar(hasher, image.alpha_multiplier);
            if (image.buffer.dmabuf) |dmabuf| {
                hashScalar(hasher, @as(u8, 1));
                hashScalar(hasher, dmabuf.format);
                hashScalar(hasher, dmabuf.modifier);
                hashScalar(hasher, dmabuf.plane_count);
                for (dmabuf.planeSlice()) |plane| {
                    hashScalar(hasher, plane.stride);
                    hashScalar(hasher, plane.offset);
                }
                hashScalar(hasher, @intFromBool(dmabuf.y_inverted));
                hashScalar(hasher, @intFromBool(dmabuf.force_opaque));
            } else {
                hashScalar(hasher, @as(u8, 0));
            }
        },
    }
    return true;
}

fn hashScalar(hasher: *std.hash.Wyhash, value: anytype) void {
    var copy = value;
    hasher.update(std.mem.asBytes(&copy));
}

fn hashSize(hasher: *std.hash.Wyhash, size: render.Size) void {
    hashScalar(hasher, size.width);
    hashScalar(hasher, size.height);
}

fn hashRect(hasher: *std.hash.Wyhash, rect: render.Rect) void {
    hashScalar(hasher, rect.x);
    hashScalar(hasher, rect.y);
    hashScalar(hasher, rect.width);
    hashScalar(hasher, rect.height);
}

fn hashColor(hasher: *std.hash.Wyhash, color: render.Color) void {
    hashScalar(hasher, color.red);
    hashScalar(hasher, color.green);
    hashScalar(hasher, color.blue);
    hashScalar(hasher, color.alpha);
}

fn hashOptionalColor(hasher: *std.hash.Wyhash, color: ?render.Color) void {
    if (color) |present| {
        hashScalar(hasher, @as(u8, 1));
        hashColor(hasher, present);
    } else {
        hashScalar(hasher, @as(u8, 0));
    }
}

fn hashBackdropBlurFinish(hasher: *std.hash.Wyhash, finish: render.BackdropBlurFinish) void {
    hashScalar(hasher, finish.brightness);
    hashScalar(hasher, finish.contrast);
    hashScalar(hasher, finish.saturation);
    hashScalar(hasher, finish.noise);
}

fn hashColorDescription(hasher: *std.hash.Wyhash, description: render.ColorDescription) void {
    hashChromaticities(hasher, description.primaries);
    hashOptionalScalar(hasher, description.named_primaries);
    switch (description.transfer_function) {
        .bt1886 => hashScalar(hasher, @as(u8, 0)),
        .gamma22 => hashScalar(hasher, @as(u8, 1)),
        .srgb => hashScalar(hasher, @as(u8, 2)),
        .st2084_pq => hashScalar(hasher, @as(u8, 3)),
        .hlg => hashScalar(hasher, @as(u8, 4)),
        .power => |exponent| {
            hashScalar(hasher, @as(u8, 5));
            hashScalar(hasher, exponent);
        },
    }
    hashScalar(hasher, description.min_luminance);
    hashScalar(hasher, description.max_luminance);
    hashScalar(hasher, description.reference_luminance);
    hashOptionalChromaticities(hasher, description.mastering_primaries);
    hashOptionalScalar(hasher, description.mastering_min_luminance);
    hashOptionalScalar(hasher, description.mastering_max_luminance);
    hashOptionalScalar(hasher, description.max_cll);
    hashOptionalScalar(hasher, description.max_fall);
}

fn hashChromaticities(hasher: *std.hash.Wyhash, chromaticities: render.Chromaticities) void {
    for (chromaticities.values()) |value| hashScalar(hasher, value);
}

fn hashOptionalChromaticities(
    hasher: *std.hash.Wyhash,
    chromaticities: ?render.Chromaticities,
) void {
    if (chromaticities) |present| {
        hashScalar(hasher, @as(u8, 1));
        hashChromaticities(hasher, present);
    } else {
        hashScalar(hasher, @as(u8, 0));
    }
}

fn hashOptionalScalar(hasher: *std.hash.Wyhash, value: anytype) void {
    if (value) |present| {
        hashScalar(hasher, @as(u8, 1));
        hashScalar(hasher, present);
    } else {
        hashScalar(hasher, @as(u8, 0));
    }
}

fn hashOptionalRect(hasher: *std.hash.Wyhash, rect: ?render.Rect) void {
    if (rect) |present| {
        hashScalar(hasher, @as(u8, 1));
        hashRect(hasher, present);
    } else {
        hashScalar(hasher, @as(u8, 0));
    }
}

fn hashOptionalRoundedClip(hasher: *std.hash.Wyhash, clip: ?render.RoundedClip) void {
    if (clip) |present| {
        hashScalar(hasher, @as(u8, 1));
        hashRect(hasher, present.rect);
        hashScalar(hasher, present.radius);
    } else {
        hashScalar(hasher, @as(u8, 0));
    }
}

fn hashOptionalSourceRect(hasher: *std.hash.Wyhash, rect: ?render.SourceRect) void {
    if (rect) |present| {
        hashScalar(hasher, @as(u8, 1));
        hashScalar(hasher, @as(u64, @bitCast(present.x)));
        hashScalar(hasher, @as(u64, @bitCast(present.y)));
        hashScalar(hasher, @as(u64, @bitCast(present.width)));
        hashScalar(hasher, @as(u64, @bitCast(present.height)));
    } else {
        hashScalar(hasher, @as(u8, 0));
    }
}

test "keys ignore later owner changes and track sampled content" {
    var lower_pixels = [_]u32{0xff112233};
    var owner_pixels = [_]u32{0x80112233};
    var commands = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 1, .height = 1 },
            .buffer = .{
                .size = .{ .width = 1, .height = 1 },
                .stride_pixels = 1,
                .pixels = &lower_pixels,
                .source_cache = .{ .id = 1, .version = 1 },
            },
        } },
        .{ .backdrop_capture = .{
            .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .radius = 8,
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .corner_radius = 0,
            .radius = 8,
        } },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 1, .height = 1 },
            .buffer = .{
                .size = .{ .width = 1, .height = 1 },
                .stride_pixels = 1,
                .pixels = &owner_pixels,
                .source_cache = .{ .id = 2, .version = 1 },
            },
        } },
    };
    const original = key(commands[0..3]).?;

    commands[4].image.buffer.source_cache.?.version = 2;
    try std.testing.expectEqual(original, key(commands[0..3]).?);

    commands[1].image.buffer.source_cache.?.version = 2;
    try std.testing.expect(original != key(commands[0..3]).?);
    commands[1].image.buffer.source_cache.?.version = 1;

    commands[1].image.buffer.color_description.transfer_function = .st2084_pq;
    try std.testing.expect(original != key(commands[0..3]).?);
    commands[1].image.buffer.color_description = .{};

    commands[2].backdrop_capture.radius = 9;
    try std.testing.expect(original != key(commands[0..3]).?);
    commands[1].image.buffer.source_cache = null;
    try std.testing.expectEqual(@as(?u64, null), key(commands[0..3]));
}

test "keys track backdrop capture topology" {
    var commands = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .backdrop_capture = .{
            .id = 1,
            .rect = .{ .x = 0, .y = 0, .width = 8, .height = 8 },
            .radius = 4,
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 0, .y = 0, .width = 8, .height = 8 },
            .color = render.Color.rgba(255, 255, 255, 255),
        } },
        .{ .backdrop_capture = .{
            .id = 2,
            .rect = .{ .x = 0, .y = 0, .width = 8, .height = 8 },
            .radius = 4,
        } },
        .{ .backdrop_blur = .{
            .capture_id = 1,
            .rect = .{ .x = 0, .y = 0, .width = 8, .height = 8 },
            .corner_radius = 0,
            .radius = 4,
        } },
    };
    const original = key(&commands).?;

    commands[4].backdrop_blur.capture_id = 2;
    try std.testing.expect(original != key(&commands).?);
    commands[4].backdrop_blur.capture_id = 1;

    commands[1].backdrop_capture.id = 3;
    try std.testing.expect(original != key(&commands).?);
}
