//! Pure color-space conversion and shader parameter construction.

const std = @import("std");
const render = @import("types.zig");

/// CPU-side values copied into shader push constants. Transfer discriminators
/// and vector lanes must remain synchronized with the image and encode shaders.
pub const ColorTransform = extern struct {
    color_matrix_0: [4]f32 = .{ 1, 0, 0, 0 },
    color_matrix_1: [4]f32 = .{ 0, 1, 0, 0 },
    color_matrix_2: [4]f32 = .{ 0, 0, 1, 0 },
    transfer: [4]f32 = .{ 0, 1, 1, 1 },
    output_transfer: [4]f32 = .{ 1, 0, 80, 80 },
    transfer_aux: [4]f32 = .{ 0.2, 0.2126, 0.7152, 0.0722 },
};

const Matrix3 = [3][3]f64;

/// Converts encoded source pixels into the output's linear working space.
pub fn sourceTransform(
    description: render.ColorDescription,
    output_description: render.ColorDescription,
) ColorTransform {
    const matrix = colorConversionMatrix(
        description.primaries,
        output_description.primaries,
    ) orelse identityMatrix3();
    const target_peak = description.max_cll orelse description.targetMaxLuminance();
    const transfer = transferParameters(description, target_peak);
    const output_rgb = rgbToXyz(output_description.primaries) orelse
        rgbToXyz(render.srgb_chromaticities).?;
    const compress_gamut = gamutCompressionNeeded(matrix);
    return .{
        .color_matrix_0 = .{ @floatCast(matrix[0][0]), @floatCast(matrix[0][1]), @floatCast(matrix[0][2]), @floatCast(if (compress_gamut) output_rgb[1][0] else -output_rgb[1][0]) },
        .color_matrix_1 = .{ @floatCast(matrix[1][0]), @floatCast(matrix[1][1]), @floatCast(matrix[1][2]), @floatCast(output_rgb[1][1]) },
        .color_matrix_2 = .{ @floatCast(matrix[2][0]), @floatCast(matrix[2][1]), @floatCast(matrix[2][2]), @floatCast(output_rgb[1][2]) },
        .transfer = transfer,
        .output_transfer = outputTransfer(output_description),
        .transfer_aux = transferAux(description),
    };
}

/// Encodes the transfer function and luminance parameters consumed by the
/// output encoding shaders.
pub fn outputTransfer(description: render.ColorDescription) [4]f32 {
    return transferParameters(description, description.max_luminance);
}

fn transferParameters(description: render.ColorDescription, peak_luminance: u32) [4]f32 {
    return switch (description.transfer_function) {
        .gamma22 => .{ 1, 0, @floatFromInt(description.reference_luminance), @floatFromInt(description.max_luminance) },
        .srgb => .{ 2, 0, @floatFromInt(description.reference_luminance), @floatFromInt(description.max_luminance) },
        .bt1886 => .{ 3, @as(f32, @floatFromInt(description.min_luminance)) / 10000.0, @floatFromInt(description.reference_luminance), @floatFromInt(description.max_luminance) },
        .power => |exponent| .{ 4, @as(f32, @floatFromInt(exponent)) / 10000.0, @floatFromInt(description.reference_luminance), @floatFromInt(description.max_luminance) },
        .st2084_pq => .{ 5, @floatFromInt(description.max_luminance), @floatFromInt(description.reference_luminance), @floatFromInt(peak_luminance) },
        .hlg => .{ 6, @floatFromInt(description.max_luminance), @floatFromInt(description.reference_luminance), @floatFromInt(peak_luminance) },
    };
}

/// Returns the black level and linear-light luminance coefficients consumed by
/// the transfer shaders.
pub fn transferAux(description: render.ColorDescription) [4]f32 {
    const matrix = rgbToXyz(description.primaries) orelse
        rgbToXyz(render.srgb_chromaticities).?;
    return .{
        @as(f32, @floatFromInt(description.min_luminance)) / 10000.0,
        @floatCast(matrix[1][0]),
        @floatCast(matrix[1][1]),
        @floatCast(matrix[1][2]),
    };
}

/// Converts an 8-bit premultiplied sRGB color to premultiplied linear values in
/// the output's color primaries.
pub fn linearColor(
    color: render.Color,
    output_description: render.ColorDescription,
) [4]f32 {
    const inverse: f32 = 1.0 / 255.0;
    const alpha = @as(f32, @floatFromInt(color.alpha)) * inverse;
    if (alpha == 0) return .{ 0, 0, 0, 0 };
    const red = @as(f32, @floatFromInt(color.red)) * inverse / alpha;
    const green = @as(f32, @floatFromInt(color.green)) * inverse / alpha;
    const blue = @as(f32, @floatFromInt(color.blue)) * inverse / alpha;
    const sdr: render.ColorDescription = .{};
    const sdr_black = @as(f32, @floatFromInt(sdr.min_luminance)) / 10000.0;
    const sdr_white: f32 = @floatFromInt(sdr.max_luminance);
    const linear: [3]f64 = .{
        ((sdr_white - sdr_black) * std.math.pow(f32, @max(red, 0), 2.2) + sdr_black) / sdr_white,
        ((sdr_white - sdr_black) * std.math.pow(f32, @max(green, 0), 2.2) + sdr_black) / sdr_white,
        ((sdr_white - sdr_black) * std.math.pow(f32, @max(blue, 0), 2.2) + sdr_black) / sdr_white,
    };
    const matrix = colorConversionMatrix(
        render.srgb_chromaticities,
        output_description.primaries,
    ) orelse identityMatrix3();
    const converted = multiplyMatrixVector(matrix, linear);
    return .{
        @floatCast(converted[0] * alpha),
        @floatCast(converted[1] * alpha),
        @floatCast(converted[2] * alpha),
        alpha,
    };
}

fn gamutCompressionNeeded(matrix: Matrix3) bool {
    const tolerance = 0.001;
    for (matrix) |row| {
        for (row) |value| {
            if (value < -tolerance or value > 1 + tolerance) return true;
        }
    }
    return false;
}

fn colorConversionMatrix(source: render.Chromaticities, destination: render.Chromaticities) ?Matrix3 {
    const source_rgb = rgbToXyz(source) orelse return null;
    const destination_rgb = rgbToXyz(destination) orelse return null;
    const destination_inverse = inverseMatrix3(destination_rgb) orelse return null;
    const adaptation = chromaticAdaptation(source, destination) orelse return null;
    return multiplyMatrix3(destination_inverse, multiplyMatrix3(adaptation, source_rgb));
}

fn rgbToXyz(chromaticities: render.Chromaticities) ?Matrix3 {
    const values = chromaticities.values();
    const red = xyToXyz(values[0], values[1]) orelse return null;
    const green = xyToXyz(values[2], values[3]) orelse return null;
    const blue = xyToXyz(values[4], values[5]) orelse return null;
    const white = xyToXyz(values[6], values[7]) orelse return null;
    const primaries: Matrix3 = .{
        .{ red[0], green[0], blue[0] },
        .{ red[1], green[1], blue[1] },
        .{ red[2], green[2], blue[2] },
    };
    const inverse = inverseMatrix3(primaries) orelse return null;
    const scale = multiplyMatrixVector(inverse, white);
    return .{
        .{ primaries[0][0] * scale[0], primaries[0][1] * scale[1], primaries[0][2] * scale[2] },
        .{ primaries[1][0] * scale[0], primaries[1][1] * scale[1], primaries[1][2] * scale[2] },
        .{ primaries[2][0] * scale[0], primaries[2][1] * scale[1], primaries[2][2] * scale[2] },
    };
}

fn chromaticAdaptation(source: render.Chromaticities, destination: render.Chromaticities) ?Matrix3 {
    const source_values = source.values();
    const destination_values = destination.values();
    const source_white = xyToXyz(source_values[6], source_values[7]) orelse return null;
    const destination_white = xyToXyz(destination_values[6], destination_values[7]) orelse return null;
    const bradford: Matrix3 = .{
        .{ 0.8951, 0.2664, -0.1614 },
        .{ -0.7502, 1.7135, 0.0367 },
        .{ 0.0389, -0.0685, 1.0296 },
    };
    const bradford_inverse: Matrix3 = .{
        .{ 0.9869929, -0.1470543, 0.1599627 },
        .{ 0.4323053, 0.5183603, 0.0492912 },
        .{ -0.0085287, 0.0400428, 0.9684867 },
    };
    const source_cone = multiplyMatrixVector(bradford, source_white);
    const destination_cone = multiplyMatrixVector(bradford, destination_white);
    if (@abs(source_cone[0]) < 1e-12 or @abs(source_cone[1]) < 1e-12 or @abs(source_cone[2]) < 1e-12) return null;
    const scale: Matrix3 = .{
        .{ destination_cone[0] / source_cone[0], 0, 0 },
        .{ 0, destination_cone[1] / source_cone[1], 0 },
        .{ 0, 0, destination_cone[2] / source_cone[2] },
    };
    return multiplyMatrix3(bradford_inverse, multiplyMatrix3(scale, bradford));
}

fn xyToXyz(x_fixed: i32, y_fixed: i32) ?[3]f64 {
    const x = @as(f64, @floatFromInt(x_fixed)) / 1_000_000.0;
    const y = @as(f64, @floatFromInt(y_fixed)) / 1_000_000.0;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or y <= 0) return null;
    return .{ x / y, 1, (1 - x - y) / y };
}

fn identityMatrix3() Matrix3 {
    return .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
}

fn multiplyMatrix3(a: Matrix3, b: Matrix3) Matrix3 {
    var result: Matrix3 = @splat(@splat(0));
    for (0..3) |row| for (0..3) |column| for (0..3) |index| {
        result[row][column] += a[row][index] * b[index][column];
    };
    return result;
}

fn multiplyMatrixVector(matrix: Matrix3, vector: [3]f64) [3]f64 {
    var result: [3]f64 = @splat(0);
    for (0..3) |row| {
        for (0..3) |column| result[row] += matrix[row][column] * vector[column];
    }
    return result;
}

fn inverseMatrix3(matrix: Matrix3) ?Matrix3 {
    const determinant = matrix[0][0] * (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) -
        matrix[0][1] * (matrix[1][0] * matrix[2][2] - matrix[1][2] * matrix[2][0]) +
        matrix[0][2] * (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]);
    if (!std.math.isFinite(determinant) or @abs(determinant) < 1e-12) return null;
    const inverse = 1.0 / determinant;
    return .{
        .{ (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) * inverse, (matrix[0][2] * matrix[2][1] - matrix[0][1] * matrix[2][2]) * inverse, (matrix[0][1] * matrix[1][2] - matrix[0][2] * matrix[1][1]) * inverse },
        .{ (matrix[1][2] * matrix[2][0] - matrix[1][0] * matrix[2][2]) * inverse, (matrix[0][0] * matrix[2][2] - matrix[0][2] * matrix[2][0]) * inverse, (matrix[0][2] * matrix[1][0] - matrix[0][0] * matrix[1][2]) * inverse },
        .{ (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]) * inverse, (matrix[0][1] * matrix[2][0] - matrix[0][0] * matrix[2][1]) * inverse, (matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]) * inverse },
    };
}

test "source and output HDR transforms retain distinct peak luminance" {
    const description: render.ColorDescription = .{
        .transfer_function = .st2084_pq,
        .max_luminance = 1000,
        .max_cll = 4000,
    };
    const source = sourceTransform(description, .{});
    const output = outputTransfer(description);

    try std.testing.expectEqual(@as(f32, 5), source.transfer[0]);
    try std.testing.expectEqual(@as(f32, 4000), source.transfer[3]);
    try std.testing.expectEqual(@as(f32, 5), output[0]);
    try std.testing.expectEqual(@as(f32, 1000), output[3]);
}

test "gamut compression policy distinguishes wider and equivalent primaries" {
    try std.testing.expect(!gamutCompressionNeeded(identityMatrix3()));
    try std.testing.expect(gamutCompressionNeeded(colorConversionMatrix(
        render.display_p3_chromaticities,
        render.srgb_chromaticities,
    ).?));
    try std.testing.expect(!gamutCompressionNeeded(colorConversionMatrix(
        render.srgb_chromaticities,
        render.display_p3_chromaticities,
    ).?));

    var nearly_srgb = render.srgb_chromaticities;
    nearly_srgb.red_x += 1;
    try std.testing.expect(!gamutCompressionNeeded(colorConversionMatrix(
        nearly_srgb,
        render.srgb_chromaticities,
    ).?));
}
