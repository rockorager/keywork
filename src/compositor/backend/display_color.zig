//! Pure EDID value normalization and HDR output-description policy.

const std = @import("std");
const render = @import("../render/types.zig");

pub const HdrCapabilities = struct {
    bt2020_rgb: bool = false,
    static_metadata_type1: bool = false,
    pq: bool = false,
    hlg: bool = false,
    min_luminance: ?u32 = null,
    max_luminance: ?u32 = null,
    max_frame_average_luminance: ?u32 = null,

    pub fn supports(self: HdrCapabilities, transfer: render.TransferFunction) bool {
        if (!self.bt2020_rgb or !self.static_metadata_type1) return false;
        return switch (transfer) {
            .st2084_pq => self.pq,
            .hlg => self.hlg,
            .bt1886, .gamma22, .srgb, .power => false,
        };
    }
};

pub const HdrCapabilityValues = struct {
    bt2020_rgb: bool,
    static_metadata_type1: bool,
    pq: bool,
    hlg: bool,
    min_luminance: f32,
    max_luminance: f32,
    max_frame_average_luminance: f32,
};

pub fn hdrCapabilitiesFromValues(values: HdrCapabilityValues) HdrCapabilities {
    return .{
        .bt2020_rgb = values.bt2020_rgb,
        .static_metadata_type1 = values.static_metadata_type1,
        .pq = values.pq,
        .hlg = values.hlg,
        .min_luminance = scaledLuminance(values.min_luminance, 10000),
        .max_luminance = scaledLuminance(values.max_luminance, 1),
        .max_frame_average_luminance = scaledLuminance(
            values.max_frame_average_luminance,
            1,
        ),
    };
}

fn scaledLuminance(value: f32, scale: u32) ?u32 {
    if (!std.math.isFinite(value) or value <= 0) return null;
    const scaled = @as(f64, value) * @as(f64, @floatFromInt(scale));
    const maximum: f64 = @floatFromInt(std.math.maxInt(u32));
    return @intFromFloat(@round(@min(scaled, maximum)));
}

pub fn colorDescriptionFromValues(
    primaries: ?[8]f32,
    gamma: f32,
) render.ColorDescription {
    var result: render.ColorDescription = .{};
    if (primaries) |values| {
        var fixed: [8]i32 = undefined;
        var valid = true;
        for (values, &fixed) |value, *destination| {
            if (!std.math.isFinite(value) or value < 0 or value > 1) {
                valid = false;
                break;
            }
            destination.* = @intFromFloat(@round(value * 1_000_000.0));
        }
        if (valid and fixed[1] > 0 and fixed[3] > 0 and fixed[5] > 0 and fixed[7] > 0) {
            const chromaticities: render.Chromaticities = .{
                .red_x = fixed[0],
                .red_y = fixed[1],
                .green_x = fixed[2],
                .green_y = fixed[3],
                .blue_x = fixed[4],
                .blue_y = fixed[5],
                .white_x = fixed[6],
                .white_y = fixed[7],
            };
            if (approximatelySrgb(chromaticities)) {
                result.primaries = render.srgb_chromaticities;
                result.named_primaries = .srgb;
            } else {
                result.primaries = chromaticities;
                result.named_primaries = null;
            }
        }
    }
    if (std.math.isFinite(gamma) and gamma >= 1 and gamma <= 10 and
        @abs(gamma - 2.2) > 0.005)
    {
        result.transfer_function = .{
            .power = @intFromFloat(@round(gamma * 10000.0)),
        };
    }
    return result;
}

fn approximatelySrgb(chromaticities: render.Chromaticities) bool {
    const tolerance = 1000;
    const actual = chromaticities.values();
    const expected = render.srgb_chromaticities.values();
    for (actual, expected) |value, reference| {
        if (@abs(value - reference) > tolerance) return false;
    }
    return true;
}

pub fn hdrDescription(
    sdr_description: render.ColorDescription,
    capabilities: HdrCapabilities,
    transfer: render.TransferFunction,
) ?render.ColorDescription {
    if (!capabilities.supports(transfer)) return null;
    const maximum = capabilities.max_luminance orelse 1000;
    return .{
        .primaries = render.bt2020_chromaticities,
        .named_primaries = .bt2020,
        .transfer_function = transfer,
        .min_luminance = capabilities.min_luminance orelse 50,
        .max_luminance = maximum,
        .reference_luminance = 203,
        .mastering_primaries = sdr_description.primaries,
        .mastering_min_luminance = capabilities.min_luminance,
        .mastering_max_luminance = capabilities.max_luminance,
        .max_cll = maximum,
        .max_fall = capabilities.max_frame_average_luminance,
    };
}

test "EDID color values preserve valid primaries and gamma" {
    const color_description = colorDescriptionFromValues(.{
        0.680,
        0.320,
        0.265,
        0.690,
        0.150,
        0.060,
        0.3127,
        0.3290,
    }, 2.4);
    try std.testing.expectEqual(@as(i32, 680000), color_description.primaries.red_x);
    try std.testing.expectEqual(@as(i32, 329000), color_description.primaries.white_y);
    try std.testing.expect(color_description.named_primaries == null);
    try std.testing.expectEqual(
        render.TransferFunction{ .power = 24000 },
        color_description.transfer_function,
    );

    const invalid = colorDescriptionFromValues(.{
        0.680,
        0,
        0.265,
        0.690,
        0.150,
        0.060,
        0.3127,
        0.3290,
    }, std.math.nan(f32));
    try std.testing.expectEqual(render.ColorDescription{}, invalid);
    try std.testing.expectEqual(
        render.TransferFunction.gamma22,
        colorDescriptionFromValues(null, 2.2).transfer_function,
    );

    const quantized_srgb = colorDescriptionFromValues(.{
        0.639648,
        0.330078,
        0.299805,
        0.599609,
        0.150391,
        0.059570,
        0.312500,
        0.329102,
    }, 2.2);
    try std.testing.expectEqual(render.ColorDescription{}, quantized_srgb);
}

test "EDID HDR capabilities preserve supported transfers and luminance" {
    const capabilities = hdrCapabilitiesFromValues(.{
        .bt2020_rgb = true,
        .static_metadata_type1 = true,
        .pq = true,
        .hlg = false,
        .min_luminance = 0.005,
        .max_luminance = 1000,
        .max_frame_average_luminance = 400,
    });
    try std.testing.expect(capabilities.supports(.st2084_pq));
    try std.testing.expect(!capabilities.supports(.hlg));
    try std.testing.expect(!capabilities.supports(.srgb));
    try std.testing.expectEqual(@as(?u32, 50), capabilities.min_luminance);
    try std.testing.expectEqual(@as(?u32, 1000), capabilities.max_luminance);
    try std.testing.expectEqual(
        @as(?u32, 400),
        capabilities.max_frame_average_luminance,
    );

    var missing_colorimetry = capabilities;
    missing_colorimetry.bt2020_rgb = false;
    try std.testing.expect(!missing_colorimetry.supports(.st2084_pq));
    try std.testing.expect(scaledLuminance(std.math.nan(f32), 1) == null);
    try std.testing.expect(scaledLuminance(0, 1) == null);

    const output_description = hdrDescription(.{}, capabilities, .st2084_pq).?;
    try std.testing.expectEqual(render.bt2020_chromaticities, output_description.primaries);
    try std.testing.expectEqual(render.srgb_chromaticities, output_description.mastering_primaries.?);
    try std.testing.expectEqual(@as(u32, 50), output_description.min_luminance);
    try std.testing.expectEqual(@as(?u32, 400), output_description.max_fall);
}
