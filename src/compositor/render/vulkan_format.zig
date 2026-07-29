//! Pure DMA-BUF format and YCbCr conversion policy for the Vulkan renderer.

const std = @import("std");
const vk = @import("vulkan");
const render = @import("types.zig");

pub const YcbcrConversion = struct {
    model: vk.SamplerYcbcrModelConversion,
    range: vk.SamplerYcbcrRange,
    x_chroma_offset: vk.ChromaLocation,
    y_chroma_offset: vk.ChromaLocation,
};

pub const ManualYcbcr = struct {
    quantization_levels: f32,
    narrow_range: bool,
    coefficients: [2]f32,
    chroma_location: render.ChromaLocation,
};

pub const GraphicsKey = struct {
    format: vk.Format,
    manual: bool = false,
    model: vk.SamplerYcbcrModelConversion,
    range: vk.SamplerYcbcrRange,
    x_chroma_offset: vk.ChromaLocation,
    y_chroma_offset: vk.ChromaLocation,
};

pub fn sourceVkFormat(fourcc: u32) ?vk.Format {
    return switch (render.DmabufFormat.fromFourcc(fourcc) orelse return null) {
        .argb8888, .xrgb8888 => .b8g8r8a8_unorm,
        .abgr8888, .xbgr8888 => .r8g8b8a8_unorm,
        .nv12 => .g8_b8r8_2plane_420_unorm,
        .p010 => .g10x6_b10x6r10x6_2plane_420_unorm_3pack16,
        .xrgb2101010 => null,
    };
}

pub fn planeViewFormats(format: vk.Format) ?[2]vk.Format {
    return switch (format) {
        .g8_b8r8_2plane_420_unorm => .{ .r8_unorm, .r8g8_unorm },
        .g10x6_b10x6r10x6_2plane_420_unorm_3pack16 => .{
            .r10x6_unorm_pack16,
            .r10x6g10x6_unorm_2pack16,
        },
        else => null,
    };
}

pub fn targetVkFormat(fourcc: u32) ?vk.Format {
    return switch (render.DmabufFormat.fromFourcc(fourcc) orelse return null) {
        .argb8888, .xrgb8888 => .b8g8r8a8_unorm,
        .xrgb2101010 => .a2r10g10b10_unorm_pack32,
        .abgr8888, .xbgr8888, .nv12, .p010 => null,
    };
}

pub fn sourceExtentValid(format: render.DmabufFormat, size: render.Size) bool {
    if (size.width == 0 or size.height == 0) return false;
    return format.isPackedRgb() or (size.width % 2 == 0 and size.height % 2 == 0);
}

pub fn defaultRepresentation() render.ColorRepresentation {
    return .{
        .coefficients = .bt709,
        .range = .limited,
        .chroma_location = .type_0,
    };
}

pub fn automaticConversion(representation: render.ColorRepresentation) ?YcbcrConversion {
    const model: vk.SamplerYcbcrModelConversion = switch (representation.coefficients) {
        .identity => return null,
        .bt601 => .ycbcr_601,
        .bt709 => .ycbcr_709,
        .bt2020 => .ycbcr_2020,
    };
    const range: vk.SamplerYcbcrRange = switch (representation.range) {
        .full => .itu_full,
        .limited => .itu_narrow,
    };
    const location = representation.chroma_location orelse return null;
    const offsets: struct { vk.ChromaLocation, vk.ChromaLocation } = switch (location) {
        .type_0 => .{ .cosited_even, .midpoint },
        .type_1 => .{ .midpoint, .midpoint },
        .type_2 => .{ .cosited_even, .cosited_even },
        .type_3 => .{ .midpoint, .cosited_even },
        // Vulkan's basic conversion cannot express a vertical offset of one.
        .type_4, .type_5 => return null,
    };
    return .{
        .model = model,
        .range = range,
        .x_chroma_offset = offsets[0],
        .y_chroma_offset = offsets[1],
    };
}

pub fn manualConversion(
    format: vk.Format,
    representation: render.ColorRepresentation,
) ?ManualYcbcr {
    const quantization_levels: f32 = switch (format) {
        .g8_b8r8_2plane_420_unorm => 255,
        .g10x6_b10x6r10x6_2plane_420_unorm_3pack16 => 1023,
        else => return null,
    };
    const coefficients: [2]f32 = switch (representation.coefficients) {
        .identity => return null,
        .bt601 => .{ 0.299, 0.114 },
        .bt709 => .{ 0.2126, 0.0722 },
        .bt2020 => .{ 0.2627, 0.0593 },
    };
    const chroma_location = representation.chroma_location orelse return null;
    switch (chroma_location) {
        .type_0, .type_1, .type_2, .type_3 => return null,
        .type_4, .type_5 => {},
    }
    return .{
        .quantization_levels = quantization_levels,
        .narrow_range = representation.range == .limited,
        .coefficients = coefficients,
        .chroma_location = chroma_location,
    };
}

pub fn automaticGraphicsKey(format: vk.Format, conversion: YcbcrConversion) GraphicsKey {
    return .{
        .format = format,
        .model = conversion.model,
        .range = conversion.range,
        .x_chroma_offset = conversion.x_chroma_offset,
        .y_chroma_offset = conversion.y_chroma_offset,
    };
}

pub fn manualGraphicsKey(format: vk.Format) GraphicsKey {
    return .{
        .format = format,
        .manual = true,
        .model = .rgb_identity,
        .range = .itu_full,
        .x_chroma_offset = .cosited_even,
        .y_chroma_offset = .cosited_even,
    };
}

test "Vulkan source extents respect chroma subsampling" {
    try std.testing.expect(sourceExtentValid(.nv12, .{ .width = 1920, .height = 1080 }));
    try std.testing.expect(!sourceExtentValid(.nv12, .{ .width = 1919, .height = 1080 }));
    try std.testing.expect(!sourceExtentValid(.p010, .{ .width = 1920, .height = 1079 }));
    try std.testing.expect(sourceExtentValid(.argb8888, .{ .width = 1919, .height = 1079 }));
}

test "video plane views preserve native sample precision" {
    try std.testing.expectEqualSlices(
        vk.Format,
        &.{ .r8_unorm, .r8g8_unorm },
        &planeViewFormats(.g8_b8r8_2plane_420_unorm).?,
    );
    try std.testing.expectEqualSlices(
        vk.Format,
        &.{ .r10x6_unorm_pack16, .r10x6g10x6_unorm_2pack16 },
        &planeViewFormats(.g10x6_b10x6r10x6_2plane_420_unorm_3pack16).?,
    );
    try std.testing.expect(planeViewFormats(.r8g8b8a8_unorm) == null);
}

test "color representation maps to Vulkan YCbCr conversion" {
    const conversion = automaticConversion(.{
        .coefficients = .bt2020,
        .range = .limited,
        .chroma_location = .type_3,
    }).?;
    try std.testing.expectEqual(vk.SamplerYcbcrModelConversion.ycbcr_2020, conversion.model);
    try std.testing.expectEqual(vk.SamplerYcbcrRange.itu_narrow, conversion.range);
    try std.testing.expectEqual(vk.ChromaLocation.midpoint, conversion.x_chroma_offset);
    try std.testing.expectEqual(vk.ChromaLocation.cosited_even, conversion.y_chroma_offset);

    const expected_offsets = [_][2]vk.ChromaLocation{
        .{ .cosited_even, .midpoint },
        .{ .midpoint, .midpoint },
        .{ .cosited_even, .cosited_even },
        .{ .midpoint, .cosited_even },
    };
    for (expected_offsets, 0..) |expected, index| {
        const location: render.ChromaLocation = @enumFromInt(index);
        const mapped = automaticConversion(.{
            .coefficients = .bt709,
            .range = .full,
            .chroma_location = location,
        }).?;
        try std.testing.expectEqual(expected[0], mapped.x_chroma_offset);
        try std.testing.expectEqual(expected[1], mapped.y_chroma_offset);
    }
}

test "unsupported YCbCr conversion metadata is rejected" {
    try std.testing.expect(automaticConversion(.{
        .coefficients = .identity,
        .range = .full,
        .chroma_location = .type_0,
    }) == null);
    try std.testing.expect(automaticConversion(.{
        .coefficients = .bt709,
        .range = .limited,
        .chroma_location = null,
    }) == null);
    inline for (.{ render.ChromaLocation.type_4, render.ChromaLocation.type_5 }) |location| {
        try std.testing.expect(automaticConversion(.{
            .coefficients = .bt709,
            .range = .limited,
            .chroma_location = location,
        }) == null);
    }
}

test "manual YCbCr conversion preserves video precision and metadata" {
    const nv12 = manualConversion(.g8_b8r8_2plane_420_unorm, .{
        .coefficients = .bt601,
        .range = .full,
        .chroma_location = .type_4,
    }).?;
    try std.testing.expectEqual(@as(f32, 255), nv12.quantization_levels);
    try std.testing.expect(!nv12.narrow_range);
    try std.testing.expectEqual([2]f32{ 0.299, 0.114 }, nv12.coefficients);
    try std.testing.expectEqual(render.ChromaLocation.type_4, nv12.chroma_location);

    const p010 = manualConversion(
        .g10x6_b10x6r10x6_2plane_420_unorm_3pack16,
        .{
            .coefficients = .bt2020,
            .range = .limited,
            .chroma_location = .type_5,
        },
    ).?;
    try std.testing.expectEqual(@as(f32, 1023), p010.quantization_levels);
    try std.testing.expect(p010.narrow_range);
    try std.testing.expectEqual([2]f32{ 0.2627, 0.0593 }, p010.coefficients);
    try std.testing.expectEqual(render.ChromaLocation.type_5, p010.chroma_location);

    try std.testing.expect(manualConversion(.g8_b8r8_2plane_420_unorm, .{
        .coefficients = .bt709,
        .range = .limited,
        .chroma_location = .type_3,
    }) == null);
}

test "DMA-BUF source FourCC selects the matching Vulkan format" {
    try std.testing.expectEqual(
        vk.Format.b8g8r8a8_unorm,
        sourceVkFormat(@intFromEnum(render.DmabufFormat.argb8888)).?,
    );
    try std.testing.expectEqual(
        vk.Format.b8g8r8a8_unorm,
        sourceVkFormat(@intFromEnum(render.DmabufFormat.xrgb8888)).?,
    );
    try std.testing.expectEqual(
        vk.Format.r8g8b8a8_unorm,
        sourceVkFormat(@intFromEnum(render.DmabufFormat.abgr8888)).?,
    );
    try std.testing.expectEqual(
        vk.Format.r8g8b8a8_unorm,
        sourceVkFormat(@intFromEnum(render.DmabufFormat.xbgr8888)).?,
    );
    try std.testing.expectEqual(
        vk.Format.g8_b8r8_2plane_420_unorm,
        sourceVkFormat(@intFromEnum(render.DmabufFormat.nv12)).?,
    );
    try std.testing.expectEqual(
        vk.Format.g10x6_b10x6r10x6_2plane_420_unorm_3pack16,
        sourceVkFormat(@intFromEnum(render.DmabufFormat.p010)).?,
    );
    try std.testing.expect(
        sourceVkFormat(@intFromEnum(render.DmabufFormat.xrgb2101010)) == null,
    );
    try std.testing.expect(sourceVkFormat(0) == null);
}

test "DMA-BUF target FourCC selects the matching Vulkan format" {
    try std.testing.expectEqual(
        vk.Format.b8g8r8a8_unorm,
        targetVkFormat(@intFromEnum(render.DmabufFormat.xrgb8888)).?,
    );
    try std.testing.expectEqual(
        vk.Format.a2r10g10b10_unorm_pack32,
        targetVkFormat(@intFromEnum(render.DmabufFormat.xrgb2101010)).?,
    );
    try std.testing.expect(targetVkFormat(0) == null);
}
