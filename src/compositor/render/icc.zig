//! ICC display-profile validation and matrix/shaper extraction.

const std = @import("std");
const render = @import("types.zig");

const c = @cImport({
    @cInclude("lcms2.h");
});

pub const Profile = struct {
    primaries: render.Chromaticities,
    transfer_function: render.TransferFunction,

    pub fn applyTo(self: Profile, base: render.ColorDescription) render.ColorDescription {
        var description = base;
        description.primaries = self.primaries;
        description.named_primaries = null;
        description.transfer_function = self.transfer_function;
        return description;
    }
};

pub const calibration_lut_edge_length = render.output_calibration_edge_length;

/// A complete linear-light output transform, including any VCGT calibration,
/// sampled for direct upload to a three-dimensional GPU texture.
pub const CalibrationLut = struct {
    values: [][4]f16,
    identity: u64,

    pub fn deinit(self: *CalibrationLut, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        self.* = undefined;
    }

    pub fn value(self: CalibrationLut, red: usize, green: usize, blue: usize) [4]f16 {
        std.debug.assert(red < calibration_lut_edge_length);
        std.debug.assert(green < calibration_lut_edge_length);
        std.debug.assert(blue < calibration_lut_edge_length);
        return self.values[lutIndex(red, green, blue)];
    }

    pub fn rendererCalibration(self: CalibrationLut) render.OutputCalibration {
        return .{
            .identity = self.identity,
            .edge_length = calibration_lut_edge_length,
            .values = self.values,
        };
    }
};

pub const OutputProfile = union(enum) {
    matrix: Profile,
    calibration: CalibrationLut,

    pub fn deinit(self: *OutputProfile, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .matrix => {},
            .calibration => |*lut| lut.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn applyTo(self: OutputProfile, base: render.ColorDescription) render.ColorDescription {
        return switch (self) {
            .matrix => |profile| profile.applyTo(base),
            .calibration => base,
        };
    }

    pub fn rendererCalibration(self: OutputProfile) ?render.OutputCalibration {
        return switch (self) {
            .matrix => null,
            .calibration => |lut| lut.rendererCalibration(),
        };
    }
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Profile {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const profile = c.cmsOpenProfileFromFile(path_z.ptr, "r") orelse
        return error.InvalidIccProfile;
    defer _ = c.cmsCloseProfile(profile);
    return parse(profile);
}

/// Loads a display transform. The caller must deinitialize the returned value
/// with the same allocator; matrix profiles do not retain the profile file.
pub fn loadOutputProfile(
    allocator: std.mem.Allocator,
    path: []const u8,
    linear_primaries: render.Chromaticities,
) !OutputProfile {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const profile = c.cmsOpenProfileFromFile(path_z.ptr, "r") orelse
        return error.InvalidIccProfile;
    defer _ = c.cmsCloseProfile(profile);
    return outputProfile(allocator, profile, linear_primaries);
}

fn outputProfile(
    allocator: std.mem.Allocator,
    profile: c.cmsHPROFILE,
    linear_primaries: render.Chromaticities,
) !OutputProfile {
    const matrix = parse(profile) catch |err| switch (err) {
        error.UnsupportedIccProfile => return .{
            .calibration = try compileCalibrationLut(allocator, profile, linear_primaries),
        },
        else => return err,
    };
    return .{ .matrix = matrix };
}

/// Compiles an allocator-owned calibration LUT. The caller must deinitialize
/// the returned value with the same allocator.
pub fn loadCalibrationLut(
    allocator: std.mem.Allocator,
    path: []const u8,
    linear_primaries: render.Chromaticities,
) !CalibrationLut {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const profile = c.cmsOpenProfileFromFile(path_z.ptr, "r") orelse
        return error.InvalidIccProfile;
    defer _ = c.cmsCloseProfile(profile);
    return compileCalibrationLut(allocator, profile, linear_primaries);
}

fn compileCalibrationLut(
    allocator: std.mem.Allocator,
    profile: c.cmsHPROFILE,
    linear_primaries: render.Chromaticities,
) !CalibrationLut {
    if (c.cmsGetDeviceClass(profile) != c.cmsSigDisplayClass or
        c.cmsGetColorSpace(profile) != c.cmsSigRgbData or
        (c.cmsGetPCS(profile) != c.cmsSigXYZData and c.cmsGetPCS(profile) != c.cmsSigLabData) or
        c.cmsIsIntentSupported(
            profile,
            c.INTENT_RELATIVE_COLORIMETRIC,
            c.LCMS_USED_AS_OUTPUT,
        ) == 0)
    {
        return error.UnsupportedIccProfile;
    }

    const linear_profile = try createLinearProfile(linear_primaries);
    defer _ = c.cmsCloseProfile(linear_profile);
    const transform = c.cmsCreateTransform(
        linear_profile,
        c.TYPE_RGB_FLT,
        profile,
        c.TYPE_RGB_FLT,
        c.INTENT_RELATIVE_COLORIMETRIC,
        c.cmsFLAGS_HIGHRESPRECALC | c.cmsFLAGS_NOCACHE,
    ) orelse return error.InvalidIccProfile;
    defer c.cmsDeleteTransform(transform);

    const value_count = calibration_lut_edge_length *
        calibration_lut_edge_length * calibration_lut_edge_length;
    const values = try allocator.alloc([4]f16, value_count);
    errdefer allocator.free(values);
    const vcgt = try readVcgt(profile);
    var input: [calibration_lut_edge_length][3]f32 = undefined;
    var output: [calibration_lut_edge_length][3]f32 = undefined;
    const denominator: f32 = @floatFromInt(calibration_lut_edge_length - 1);
    for (0..calibration_lut_edge_length) |blue| {
        for (0..calibration_lut_edge_length) |green| {
            for (0..calibration_lut_edge_length) |red| input[red] = .{
                @as(f32, @floatFromInt(red)) / denominator,
                @as(f32, @floatFromInt(green)) / denominator,
                @as(f32, @floatFromInt(blue)) / denominator,
            };
            c.cmsDoTransform(transform, &input, &output, calibration_lut_edge_length);
            for (output, 0..) |transformed, red| {
                for (transformed) |component| {
                    if (!std.math.isFinite(component)) return error.InvalidIccProfile;
                }
                var calibrated = transformed;
                if (vcgt) |curves| {
                    for (&calibrated, 0..) |*component, channel| {
                        component.* = c.cmsEvalToneCurveFloat(
                            curves[channel],
                            std.math.clamp(component.*, 0, 1),
                        );
                    }
                }
                for (calibrated) |component| {
                    if (!std.math.isFinite(component)) return error.InvalidIccProfile;
                }
                values[lutIndex(red, green, blue)] = .{
                    @floatCast(std.math.clamp(calibrated[0], 0, 1)),
                    @floatCast(std.math.clamp(calibrated[1], 0, 1)),
                    @floatCast(std.math.clamp(calibrated[2], 0, 1)),
                    1,
                };
            }
        }
    }
    return .{
        .values = values,
        .identity = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(values)),
    };
}

fn createLinearProfile(primaries: render.Chromaticities) !c.cmsHPROFILE {
    const white = try xyY(primaries.white_x, primaries.white_y);
    const rgb: c.cmsCIExyYTRIPLE = .{
        .Red = try xyY(primaries.red_x, primaries.red_y),
        .Green = try xyY(primaries.green_x, primaries.green_y),
        .Blue = try xyY(primaries.blue_x, primaries.blue_y),
    };
    const curve = c.cmsBuildGamma(null, 1) orelse return error.OutOfMemory;
    defer c.cmsFreeToneCurve(curve);
    var curves = [_]*c.cmsToneCurve{ curve, curve, curve };
    return c.cmsCreateRGBProfile(&white, &rgb, &curves) orelse error.InvalidIccProfile;
}

fn xyY(x_fixed: i32, y_fixed: i32) !c.cmsCIExyY {
    const scale: i64 = 1_000_000;
    const x_value: i64 = x_fixed;
    const y_value: i64 = y_fixed;
    const sum = x_value + y_value;
    if (x_value < 0 or y_value <= 0 or x_value > scale or y_value > scale or
        sum > scale + 1)
    {
        return error.InvalidIccProfile;
    }
    // Independent fixed-point rounding can move a boundary coordinate one
    // unit past x + y = 1. Normalize that representational error away.
    const denominator: f64 = @floatFromInt(@max(sum, scale));
    return .{
        .x = @as(f64, @floatFromInt(x_value)) / denominator,
        .y = @as(f64, @floatFromInt(y_value)) / denominator,
        .Y = 1,
    };
}

fn readVcgt(profile: c.cmsHPROFILE) !?[*]const *c.cmsToneCurve {
    if (c.cmsIsTag(profile, c.cmsSigVcgtTag) == 0) return null;
    const value = c.cmsReadTag(profile, c.cmsSigVcgtTag) orelse
        return error.InvalidIccProfile;
    return @ptrCast(@alignCast(value));
}

fn lutIndex(red: usize, green: usize, blue: usize) usize {
    // Vulkan uploads this contiguous dimension as texture X, so shaders sample
    // the three-dimensional image with coordinates (red, green, blue).
    return (blue * calibration_lut_edge_length + green) * calibration_lut_edge_length + red;
}

fn parse(profile: c.cmsHPROFILE) !Profile {
    if (c.cmsGetDeviceClass(profile) != c.cmsSigDisplayClass or
        c.cmsGetColorSpace(profile) != c.cmsSigRgbData or
        c.cmsGetPCS(profile) != c.cmsSigXYZData or
        c.cmsIsMatrixShaper(profile) == 0)
    {
        return error.UnsupportedIccProfile;
    }
    for (0..4) |intent| {
        if (c.cmsIsCLUT(profile, @intCast(intent), c.LCMS_USED_AS_INPUT) != 0 or
            c.cmsIsCLUT(profile, @intCast(intent), c.LCMS_USED_AS_OUTPUT) != 0)
        {
            return error.UnsupportedIccProfile;
        }
    }
    if (c.cmsIsTag(profile, c.cmsSigVcgtTag) != 0) return error.UnsupportedIccProfile;

    const red_tag = readTag(c.cmsCIEXYZ, profile, c.cmsSigRedColorantTag) orelse
        return error.InvalidIccProfile;
    const green_tag = readTag(c.cmsCIEXYZ, profile, c.cmsSigGreenColorantTag) orelse
        return error.InvalidIccProfile;
    const blue_tag = readTag(c.cmsCIEXYZ, profile, c.cmsSigBlueColorantTag) orelse
        return error.InvalidIccProfile;
    const colorants = try nativeColorants(profile, .{ red_tag.*, green_tag.*, blue_tag.* });
    const red_xy = try xyzChromaticity(colorants[0]);
    const green_xy = try xyzChromaticity(colorants[1]);
    const blue_xy = try xyzChromaticity(colorants[2]);
    const white_xy = try xyzChromaticity(.{
        .X = colorants[0].X + colorants[1].X + colorants[2].X,
        .Y = colorants[0].Y + colorants[1].Y + colorants[2].Y,
        .Z = colorants[0].Z + colorants[1].Z + colorants[2].Z,
    });

    const red_trc = readTag(c.cmsToneCurve, profile, c.cmsSigRedTRCTag) orelse
        return error.InvalidIccProfile;
    const green_trc = readTag(c.cmsToneCurve, profile, c.cmsSigGreenTRCTag) orelse
        return error.InvalidIccProfile;
    const blue_trc = readTag(c.cmsToneCurve, profile, c.cmsSigBlueTRCTag) orelse
        return error.InvalidIccProfile;
    const gamma = [_]f64{
        c.cmsEstimateGamma(red_trc, 0.001),
        c.cmsEstimateGamma(green_trc, 0.001),
        c.cmsEstimateGamma(blue_trc, 0.001),
    };
    for (gamma) |value| {
        if (!std.math.isFinite(value) or value < 1 or value > 10 or
            @abs(value - gamma[0]) > 0.01)
        {
            return error.UnsupportedIccProfile;
        }
    }

    return .{
        .primaries = .{
            .red_x = red_xy.x,
            .red_y = red_xy.y,
            .green_x = green_xy.x,
            .green_y = green_xy.y,
            .blue_x = blue_xy.x,
            .blue_y = blue_xy.y,
            .white_x = white_xy.x,
            .white_y = white_xy.y,
        },
        .transfer_function = .{
            .power = @intFromFloat(@round(gamma[0] * 10000.0)),
        },
    };
}

const Matrix3 = [3][3]f64;

fn nativeColorants(
    profile: c.cmsHPROFILE,
    pcs_colorants: [3]c.cmsCIEXYZ,
) ![3]c.cmsCIEXYZ {
    if (try readChromaticAdaptation(profile)) |adaptation| {
        const inverse = invertMatrix3(adaptation) orelse return error.InvalidIccProfile;
        var result: [3]c.cmsCIEXYZ = undefined;
        for (pcs_colorants, &result) |colorant, *native| native.* = multiplyXyz(inverse, colorant);
        return result;
    }

    const media_white = readTag(c.cmsCIEXYZ, profile, c.cmsSigMediaWhitePointTag) orelse
        return error.UnsupportedIccProfile;
    var result: [3]c.cmsCIEXYZ = undefined;
    for (pcs_colorants, &result) |colorant, *native| {
        if (c.cmsAdaptToIlluminant(native, c.cmsD50_XYZ(), media_white, &colorant) == 0) {
            return error.InvalidIccProfile;
        }
    }
    return result;
}

fn readChromaticAdaptation(profile: c.cmsHPROFILE) !?Matrix3 {
    const size = c.cmsReadRawTag(profile, c.cmsSigChromaticAdaptationTag, null, 0);
    if (size == 0) return null;
    if (size != 44) return error.InvalidIccProfile;
    var bytes: [44]u8 = undefined;
    if (c.cmsReadRawTag(profile, c.cmsSigChromaticAdaptationTag, &bytes, bytes.len) != bytes.len or
        !std.mem.eql(u8, bytes[0..4], "sf32") or !std.mem.allEqual(u8, bytes[4..8], 0))
    {
        return error.InvalidIccProfile;
    }
    var matrix: Matrix3 = undefined;
    for (0..3) |row| {
        for (0..3) |column| {
            const offset = 8 + (row * 3 + column) * 4;
            const fixed = std.mem.readInt(i32, bytes[offset..][0..4], .big);
            matrix[row][column] = @as(f64, @floatFromInt(fixed)) / 65536.0;
        }
    }
    return matrix;
}

fn invertMatrix3(matrix: Matrix3) ?Matrix3 {
    const determinant =
        matrix[0][0] * (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) -
        matrix[0][1] * (matrix[1][0] * matrix[2][2] - matrix[1][2] * matrix[2][0]) +
        matrix[0][2] * (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]);
    if (!std.math.isFinite(determinant) or @abs(determinant) < 0.000000001) return null;
    const inverse_determinant = 1.0 / determinant;
    return .{
        .{
            (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) * inverse_determinant,
            (matrix[0][2] * matrix[2][1] - matrix[0][1] * matrix[2][2]) * inverse_determinant,
            (matrix[0][1] * matrix[1][2] - matrix[0][2] * matrix[1][1]) * inverse_determinant,
        },
        .{
            (matrix[1][2] * matrix[2][0] - matrix[1][0] * matrix[2][2]) * inverse_determinant,
            (matrix[0][0] * matrix[2][2] - matrix[0][2] * matrix[2][0]) * inverse_determinant,
            (matrix[0][2] * matrix[1][0] - matrix[0][0] * matrix[1][2]) * inverse_determinant,
        },
        .{
            (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]) * inverse_determinant,
            (matrix[0][1] * matrix[2][0] - matrix[0][0] * matrix[2][1]) * inverse_determinant,
            (matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]) * inverse_determinant,
        },
    };
}

fn multiplyXyz(matrix: Matrix3, value: c.cmsCIEXYZ) c.cmsCIEXYZ {
    const vector = [_]f64{ value.X, value.Y, value.Z };
    return .{
        .X = matrix[0][0] * vector[0] + matrix[0][1] * vector[1] + matrix[0][2] * vector[2],
        .Y = matrix[1][0] * vector[0] + matrix[1][1] * vector[1] + matrix[1][2] * vector[2],
        .Z = matrix[2][0] * vector[0] + matrix[2][1] * vector[1] + matrix[2][2] * vector[2],
    };
}

fn readTag(
    comptime T: type,
    profile: c.cmsHPROFILE,
    signature: c.cmsTagSignature,
) ?*const T {
    const value = c.cmsReadTag(profile, signature) orelse return null;
    return @ptrCast(@alignCast(value));
}

fn xyzChromaticity(value: c.cmsCIEXYZ) !struct { x: i32, y: i32 } {
    const sum = value.X + value.Y + value.Z;
    if (!std.math.isFinite(sum) or sum <= 0) return error.InvalidIccProfile;
    const x = value.X / sum;
    const y = value.Y / sum;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        x < 0 or x > 1 or y <= 0 or y > 1)
    {
        return error.InvalidIccProfile;
    }
    return .{
        .x = @intFromFloat(@round(x * 1_000_000.0)),
        .y = @intFromFloat(@round(y * 1_000_000.0)),
    };
}

test "ICC linear profiles tolerate fixed-point boundary rounding" {
    const red = try xyY(679688, 320313);
    try std.testing.expectApproxEqAbs(@as(f64, 1), red.x + red.y, 0.000000000001);
    try std.testing.expectError(error.InvalidIccProfile, xyY(679688, 320314));

    var primaries = render.display_p3_chromaticities;
    primaries.red_x = 679688;
    primaries.red_y = 320313;
    const profile = try createLinearProfile(primaries);
    defer _ = c.cmsCloseProfile(profile);
}

test "ICC matrix profiles expose primaries and a shared transfer curve" {
    const white: c.cmsCIExyY = .{ .x = 0.3127, .y = 0.3290, .Y = 1 };
    const primaries: c.cmsCIExyYTRIPLE = .{
        .Red = .{ .x = 0.64, .y = 0.33, .Y = 1 },
        .Green = .{ .x = 0.30, .y = 0.60, .Y = 1 },
        .Blue = .{ .x = 0.15, .y = 0.06, .Y = 1 },
    };
    const curve = c.cmsBuildGamma(null, 2.4) orelse return error.OutOfMemory;
    defer c.cmsFreeToneCurve(curve);
    var curves = [_]*c.cmsToneCurve{ curve, curve, curve };
    const profile = c.cmsCreateRGBProfile(&white, &primaries, &curves) orelse
        return error.OutOfMemory;
    defer _ = c.cmsCloseProfile(profile);

    const parsed = try parse(profile);
    var selected = try outputProfile(
        std.testing.allocator,
        profile,
        render.srgb_chromaticities,
    );
    defer selected.deinit(std.testing.allocator);
    try std.testing.expect(selected == .matrix);
    try std.testing.expectEqual(render.TransferFunction{ .power = 24000 }, parsed.transfer_function);
    try expectNear(640000, parsed.primaries.red_x, 100);
    try expectNear(330000, parsed.primaries.red_y, 100);
    try expectNear(300000, parsed.primaries.green_x, 100);
    try expectNear(600000, parsed.primaries.green_y, 100);
    try expectNear(150000, parsed.primaries.blue_x, 100);
    try expectNear(60000, parsed.primaries.blue_y, 100);
    try expectNear(312700, parsed.primaries.white_x, 100);
    try expectNear(329000, parsed.primaries.white_y, 100);
}

test "ICC output transforms compile into stable linear-light LUTs" {
    const linear = try createLinearProfile(render.srgb_chromaticities);
    defer _ = c.cmsCloseProfile(linear);
    var first = try compileCalibrationLut(
        std.testing.allocator,
        linear,
        render.srgb_chromaticities,
    );
    defer first.deinit(std.testing.allocator);
    var second = try compileCalibrationLut(
        std.testing.allocator,
        linear,
        render.srgb_chromaticities,
    );
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqual(first.identity, second.identity);
    try expectLutValue(first, 0, 0, 0, .{ 0, 0, 0 }, 0.0001);
    try expectLutValue(first, 16, 16, 16, .{ 0.5, 0.5, 0.5 }, 0.001);
    try expectLutValue(first, 32, 32, 32, .{ 1, 1, 1 }, 0.0001);
    try expectLutValue(first, 32, 0, 0, .{ 1, 0, 0 }, 0.001);
}

test "ICC output LUT includes transfer and VCGT calibration curves" {
    const white: c.cmsCIExyY = .{ .x = 0.3127, .y = 0.3290, .Y = 1 };
    const primaries: c.cmsCIExyYTRIPLE = .{
        .Red = .{ .x = 0.68, .y = 0.32, .Y = 1 },
        .Green = .{ .x = 0.265, .y = 0.69, .Y = 1 },
        .Blue = .{ .x = 0.15, .y = 0.06, .Y = 1 },
    };
    const output_curve = c.cmsBuildGamma(null, 2) orelse return error.OutOfMemory;
    defer c.cmsFreeToneCurve(output_curve);
    var output_curves = [_]*c.cmsToneCurve{ output_curve, output_curve, output_curve };
    const profile = c.cmsCreateRGBProfile(&white, &primaries, &output_curves) orelse
        return error.OutOfMemory;
    defer _ = c.cmsCloseProfile(profile);
    var linear_primaries = render.display_p3_chromaticities;
    linear_primaries.red_x = 679688;
    linear_primaries.red_y = 320313;
    var uncalibrated = try compileCalibrationLut(
        std.testing.allocator,
        profile,
        linear_primaries,
    );
    defer uncalibrated.deinit(std.testing.allocator);
    const calibration_curve = c.cmsBuildGamma(null, 2) orelse return error.OutOfMemory;
    defer c.cmsFreeToneCurve(calibration_curve);
    var calibration_curves = [_]*c.cmsToneCurve{
        calibration_curve,
        calibration_curve,
        calibration_curve,
    };
    try std.testing.expect(c.cmsWriteTag(profile, c.cmsSigVcgtTag, &calibration_curves) != 0);

    var selected = try outputProfile(
        std.testing.allocator,
        profile,
        linear_primaries,
    );
    defer selected.deinit(std.testing.allocator);
    try std.testing.expect(selected == .calibration);
    const calibrated = selected.calibration;

    const before = uncalibrated.value(24, 8, 16);
    const after = calibrated.value(24, 8, 16);
    var changed = false;
    for (before[0..3], after[0..3]) |input, actual| {
        const expected = c.cmsEvalToneCurveFloat(calibration_curve, @floatCast(input));
        try std.testing.expectApproxEqAbs(expected, @as(f32, @floatCast(actual)), 0.002);
        changed = changed or @abs(@as(f32, @floatCast(input)) - @as(f32, @floatCast(actual))) >
            0.01;
    }
    try std.testing.expect(changed);
}

test "ICC output LUT rejects malformed VCGT calibration" {
    const profile = try createLinearProfile(render.srgb_chromaticities);
    defer _ = c.cmsCloseProfile(profile);
    const invalid_vcgt = [_]u8{ 'v', 'c', 'g', 't', 0, 0, 0, 0 };
    try std.testing.expect(c.cmsWriteRawTag(
        profile,
        c.cmsSigVcgtTag,
        &invalid_vcgt,
        invalid_vcgt.len,
    ) != 0);
    try std.testing.expectError(
        error.InvalidIccProfile,
        compileCalibrationLut(std.testing.allocator, profile, render.srgb_chromaticities),
    );
}

test "ICC CLUT display profiles compile into output LUTs" {
    const profile = try createTestClutProfile();
    defer _ = c.cmsCloseProfile(profile);
    try std.testing.expect(c.cmsIsCLUT(
        profile,
        c.INTENT_RELATIVE_COLORIMETRIC,
        c.LCMS_USED_AS_OUTPUT,
    ) != 0);

    var selected = try outputProfile(
        std.testing.allocator,
        profile,
        render.srgb_chromaticities,
    );
    defer selected.deinit(std.testing.allocator);
    try std.testing.expect(selected == .calibration);
    const lut = selected.calibration;
    try expectLutValue(lut, 16, 16, 16, .{ 0.5, 0.5, 0.5 }, 0.01);
    try expectLutValue(lut, 32, 0, 0, .{ 1, 0, 0 }, 0.01);
}

fn createTestClutProfile() !c.cmsHPROFILE {
    const linear = try createLinearProfile(render.srgb_chromaticities);
    defer _ = c.cmsCloseProfile(linear);
    const xyz = c.cmsCreateXYZProfile() orelse return error.OutOfMemory;
    defer _ = c.cmsCloseProfile(xyz);
    const flags = c.cmsFLAGS_FORCE_CLUT | c.cmsFLAGS_HIGHRESPRECALC;
    const forward = c.cmsCreateTransform(
        linear,
        c.TYPE_RGB_FLT,
        xyz,
        c.TYPE_XYZ_FLT,
        c.INTENT_RELATIVE_COLORIMETRIC,
        flags,
    ) orelse return error.InvalidIccProfile;
    defer c.cmsDeleteTransform(forward);
    const reverse = c.cmsCreateTransform(
        xyz,
        c.TYPE_XYZ_FLT,
        linear,
        c.TYPE_RGB_FLT,
        c.INTENT_RELATIVE_COLORIMETRIC,
        flags,
    ) orelse return error.InvalidIccProfile;
    defer c.cmsDeleteTransform(reverse);

    const profile = c.cmsCreateProfilePlaceholder(null) orelse return error.OutOfMemory;
    errdefer _ = c.cmsCloseProfile(profile);
    c.cmsSetProfileVersion(profile, 4.3);
    c.cmsSetDeviceClass(profile, c.cmsSigDisplayClass);
    c.cmsSetColorSpace(profile, c.cmsSigRgbData);
    c.cmsSetPCS(profile, c.cmsSigXYZData);
    c.cmsSetHeaderRenderingIntent(profile, c.INTENT_RELATIVE_COLORIMETRIC);
    if (c.cmsWriteTag(profile, c.cmsSigMediaWhitePointTag, c.cmsD50_XYZ()) == 0 or
        c.cmsWriteTag(profile, c.cmsSigAToB1Tag, c.cmsGetTransformPipeline(forward)) == 0 or
        c.cmsWriteTag(profile, c.cmsSigBToA1Tag, c.cmsGetTransformPipeline(reverse)) == 0)
    {
        return error.InvalidIccProfile;
    }
    return profile;
}

fn expectLutValue(
    lut: CalibrationLut,
    red: usize,
    green: usize,
    blue: usize,
    expected: [3]f32,
    tolerance: f32,
) !void {
    const actual = lut.value(red, green, blue);
    for (expected, actual[0..3]) |expected_component, actual_component| {
        try std.testing.expectApproxEqAbs(
            expected_component,
            @as(f32, @floatCast(actual_component)),
            tolerance,
        );
    }
}

fn expectNear(expected: i32, actual: i32, tolerance: i32) !void {
    try std.testing.expect(@abs(expected - actual) <= tolerance);
}

test "ICC LUT profiles are rejected by the matrix profile path" {
    const profile = c.cmsCreateLab4Profile(null) orelse return error.OutOfMemory;
    defer _ = c.cmsCloseProfile(profile);
    try std.testing.expectError(error.UnsupportedIccProfile, parse(profile));
}
