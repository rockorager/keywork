//! Renderer-independent command, frame, and pixel-buffer data.

const std = @import("std");

var next_source_cache_id: std.atomic.Value(u64) = .init(1);
var next_render_target_id: std.atomic.Value(u64) = .init(1);

pub fn allocateSourceCacheId() u64 {
    const id = next_source_cache_id.fetchAdd(1, .monotonic);
    std.debug.assert(id != 0);
    return id;
}

pub fn allocateRenderTargetId() u64 {
    const id = next_render_target_id.fetchAdd(1, .monotonic);
    std.debug.assert(id != 0);
    return id;
}

pub const Size = struct {
    width: u32,
    height: u32,

    pub fn pixelCount(self: Size) error{Overflow}!usize {
        return std.math.mul(usize, self.width, self.height);
    }
};

pub const Position = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const Scale = struct {
    numerator: u32 = denominator,

    pub const denominator = 120;

    pub fn ceil(self: Scale) error{ InvalidScale, Overflow }!u32 {
        if (self.numerator == 0) return error.InvalidScale;
        return std.math.divCeil(u32, self.numerator, denominator) catch
            return error.Overflow;
    }

    pub fn apply(self: Scale, size: Size) error{ InvalidScale, Overflow }!Size {
        if (self.numerator == 0) return error.InvalidScale;
        return .{
            .width = try self.applyDimension(size.width),
            .height = try self.applyDimension(size.height),
        };
    }

    pub fn logicalSize(self: Scale, pixel_size: Size) error{ InvalidScale, InvalidDimensions, Overflow }!Size {
        if (self.numerator == 0) return error.InvalidScale;
        const width = try self.logicalDimension(pixel_size.width);
        const height = try self.logicalDimension(pixel_size.height);
        if (width == 0 or height == 0) return error.InvalidDimensions;
        return .{ .width = width, .height = height };
    }

    fn applyDimension(self: Scale, value: u32) error{Overflow}!u32 {
        const product = std.math.mul(u64, value, self.numerator) catch
            return error.Overflow;
        const rounded = std.math.add(u64, product, denominator / 2) catch
            return error.Overflow;
        const result = rounded / denominator;
        if (result > std.math.maxInt(u32)) return error.Overflow;
        return @intCast(result);
    }

    fn logicalDimension(self: Scale, value: u32) error{Overflow}!u32 {
        const product = std.math.mul(u64, value, denominator) catch
            return error.Overflow;
        const result = product / self.numerator;
        if (result > std.math.maxInt(u32)) return error.Overflow;
        return @intCast(result);
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn contains(self: Rect, other: Rect) bool {
        return @as(i64, other.x) >= self.x and
            @as(i64, other.y) >= self.y and
            @as(i64, other.x) + other.width <= @as(i64, self.x) + self.width and
            @as(i64, other.y) + other.height <= @as(i64, self.y) + self.height;
    }

    pub fn intersection(self: Rect, other: Rect) ?Rect {
        const left = @max(@as(i64, self.x), other.x);
        const top = @max(@as(i64, self.y), other.y);
        const right = @min(
            @as(i64, self.x) + self.width,
            @as(i64, other.x) + other.width,
        );
        const bottom = @min(
            @as(i64, self.y) + self.height,
            @as(i64, other.y) + other.height,
        );
        if (left >= right or top >= bottom) return null;
        return .{
            .x = @intCast(left),
            .y = @intCast(top),
            .width = @intCast(right - left),
            .height = @intCast(bottom - top),
        };
    }

    pub fn unionWith(self: Rect, other: Rect) Rect {
        const left = @min(self.x, other.x);
        const top = @min(self.y, other.y);
        const right = @max(
            @as(i64, self.x) + self.width,
            @as(i64, other.x) + other.width,
        );
        const bottom = @max(
            @as(i64, self.y) + self.height,
            @as(i64, other.y) + other.height,
        );
        return .{
            .x = left,
            .y = top,
            .width = @intCast(right - left),
            .height = @intCast(bottom - top),
        };
    }

    pub fn translated(self: Rect, x: i32, y: i32) Rect {
        return .{
            .x = self.x +| x,
            .y = self.y +| y,
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn clipTo(self: Rect, size: Size) ?Rect {
        const left = @max(@as(i64, self.x), 0);
        const top = @max(@as(i64, self.y), 0);
        const right = @min(@as(i64, self.x) + self.width, size.width);
        const bottom = @min(@as(i64, self.y) + self.height, size.height);

        if (left >= right or top >= bottom) return null;

        return .{
            .x = @intCast(left),
            .y = @intCast(top),
            .width = @intCast(right - left),
            .height = @intCast(bottom - top),
        };
    }
};

/// An 8-bit premultiplied-alpha color.
pub const Color = struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,

    pub fn rgba(red: u8, green: u8, blue: u8, alpha: u8) Color {
        return .{
            .red = premultiply(red, alpha),
            .green = premultiply(green, alpha),
            .blue = premultiply(blue, alpha),
            .alpha = alpha,
        };
    }

    pub fn argb8888(self: Color) u32 {
        return @as(u32, self.alpha) << 24 |
            @as(u32, self.red) << 16 |
            @as(u32, self.green) << 8 |
            self.blue;
    }

    fn premultiply(component: u8, alpha: u8) u8 {
        const product = @as(u16, component) * alpha + 127;
        return @intCast(product / 255);
    }
};

pub const Chromaticities = struct {
    red_x: i32,
    red_y: i32,
    green_x: i32,
    green_y: i32,
    blue_x: i32,
    blue_y: i32,
    white_x: i32,
    white_y: i32,

    pub fn values(self: Chromaticities) [8]i32 {
        return .{
            self.red_x,
            self.red_y,
            self.green_x,
            self.green_y,
            self.blue_x,
            self.blue_y,
            self.white_x,
            self.white_y,
        };
    }
};

pub const Primaries = enum {
    srgb,
    display_p3,
    bt2020,
};

pub const TransferFunction = union(enum) {
    bt1886,
    gamma22,
    srgb,
    st2084_pq,
    hlg,
    power: u32,

    pub fn isHdr(self: TransferFunction) bool {
        return switch (self) {
            .st2084_pq, .hlg => true,
            .bt1886, .gamma22, .srgb, .power => false,
        };
    }
};

pub const srgb_chromaticities: Chromaticities = .{
    .red_x = 640000,
    .red_y = 330000,
    .green_x = 300000,
    .green_y = 600000,
    .blue_x = 150000,
    .blue_y = 60000,
    .white_x = 312700,
    .white_y = 329000,
};

pub const display_p3_chromaticities: Chromaticities = .{
    .red_x = 680000,
    .red_y = 320000,
    .green_x = 265000,
    .green_y = 690000,
    .blue_x = 150000,
    .blue_y = 60000,
    .white_x = 312700,
    .white_y = 329000,
};

pub const bt2020_chromaticities: Chromaticities = .{
    .red_x = 708000,
    .red_y = 292000,
    .green_x = 170000,
    .green_y = 797000,
    .blue_x = 131000,
    .blue_y = 46000,
    .white_x = 312700,
    .white_y = 329000,
};

/// Immutable colorimetry copied into every retained image snapshot. Minimum
/// luminances use the color-management-v1 fixed-point scale of 10000.
pub const ColorDescription = struct {
    primaries: Chromaticities = srgb_chromaticities,
    named_primaries: ?Primaries = .srgb,
    transfer_function: TransferFunction = .gamma22,
    min_luminance: u32 = 2000,
    max_luminance: u32 = 80,
    reference_luminance: u32 = 80,
    mastering_primaries: ?Chromaticities = null,
    mastering_min_luminance: ?u32 = null,
    mastering_max_luminance: ?u32 = null,
    max_cll: ?u32 = null,
    max_fall: ?u32 = null,

    pub fn targetPrimaries(self: ColorDescription) Chromaticities {
        return self.mastering_primaries orelse self.primaries;
    }

    pub fn targetMinLuminance(self: ColorDescription) u32 {
        return self.mastering_min_luminance orelse self.min_luminance;
    }

    pub fn targetMaxLuminance(self: ColorDescription) u32 {
        return self.mastering_max_luminance orelse self.max_luminance;
    }
};

pub const ColorCoefficients = enum(u8) {
    identity,
    bt601,
    bt709,
    bt2020,
};

pub const ColorRange = enum(u8) {
    full,
    limited,
};

pub const ChromaLocation = enum(u8) {
    type_0,
    type_1,
    type_2,
    type_3,
    type_4,
    type_5,
};

pub const ColorRepresentation = struct {
    coefficients: ColorCoefficients = .identity,
    range: ColorRange = .full,
    chroma_location: ?ChromaLocation = null,
};

pub const SolidRect = struct {
    rect: Rect,
    color: Color,
    clip: ?Rect = null,
};

pub const SourceRect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const RoundedClip = struct {
    rect: Rect,
    radius: u32,
};

pub const BufferTransform = enum(u8) {
    normal,
    rotate_90,
    rotate_180,
    rotate_270,
    flipped,
    flipped_90,
    flipped_180,
    flipped_270,

    pub fn swapsAxes(self: BufferTransform) bool {
        return switch (self) {
            .rotate_90, .rotate_270, .flipped_90, .flipped_270 => true,
            .normal, .rotate_180, .flipped, .flipped_180 => false,
        };
    }

    pub fn applyToSize(self: BufferTransform, size: Size) Size {
        return if (self.swapsAxes())
            .{ .width = size.height, .height = size.width }
        else
            size;
    }
};

pub const Image = struct {
    x: i32,
    y: i32,
    size: Size,
    buffer: PixelBuffer,
    /// Non-rendering identity reported when this image contributes to a frame.
    sample_tag: ?u64 = null,
    source: ?SourceRect = null,
    transform: BufferTransform = .normal,
    rounded_clip: ?RoundedClip = null,
    clip: ?Rect = null,
    is_opaque: bool = false,
    /// Opaque portions in the same coordinate space as x/y. This bounded hint
    /// may omit rectangles, but every rectangle it contains must be opaque.
    opaque_region: OpaqueRegion = .{},
    alpha_multiplier: u32 = std.math.maxInt(u32),

    pub fn samplingFilter(self: Image) SamplingFilter {
        const transformed_size = self.transform.applyToSize(self.buffer.size);
        const source = self.source orelse SourceRect{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(transformed_size.width),
            .height = @floatFromInt(transformed_size.height),
        };
        if (source.x != @trunc(source.x) or source.y != @trunc(source.y) or
            source.width != @as(f64, @floatFromInt(self.size.width)) or
            source.height != @as(f64, @floatFromInt(self.size.height)))
        {
            const horizontal_scale = @as(f64, @floatFromInt(self.size.width)) / source.width;
            const vertical_scale = @as(f64, @floatFromInt(self.size.height)) / source.height;
            if (horizontal_scale < 0.5 or vertical_scale < 0.5) return .area;
            const full_source = source.x == 0 and source.y == 0 and
                source.width == @as(f64, @floatFromInt(transformed_size.width)) and
                source.height == @as(f64, @floatFromInt(transformed_size.height));
            // The linear sampler clamps at the buffer edge, so interior source crops
            // keep reconstruction's explicit crop-edge clamping to prevent bleeding.
            if (full_source and horizontal_scale > 1 and vertical_scale > 1) return .linear;
            return .reconstruction;
        }
        return .nearest;
    }
};

/// A composed image source. CPU renderers consume pixels, while Vulkan
/// renderers consume offscreen targets created by that renderer. Retained
/// targets remain valid only while their creating renderer owns them.
pub const ImageSource = union(enum) {
    pixels: PixelBuffer,
    offscreen: OffscreenTarget,

    pub fn size(self: ImageSource) Size {
        return switch (self) {
            .pixels => |pixels| pixels.size,
            .offscreen => |target| target.size,
        };
    }
};

/// Mixes two premultiplied sources first, then composites that single result.
pub const Crossfade = struct {
    destination: Rect,
    old: ImageSource,
    new: ImageSource,
    old_source: ?SourceRect = null,
    new_source: ?SourceRect = null,
    /// Normalized unsigned fixed-point factor: 0 selects old, maxInt selects new.
    factor: u32,
    rounded_clip: ?RoundedClip = null,
    clip: ?Rect = null,
};

pub const maximum_opaque_region_rectangles = 16;

pub const OpaqueRegion = struct {
    rectangles: [maximum_opaque_region_rectangles]Rect = undefined,
    count: u8 = 0,

    pub fn append(self: *OpaqueRegion, rectangle: Rect) bool {
        if (rectangle.width == 0 or rectangle.height == 0 or
            self.count == self.rectangles.len) return false;
        self.rectangles[self.count] = rectangle;
        self.count += 1;
        return true;
    }

    pub fn slice(self: *const OpaqueRegion) []const Rect {
        return self.rectangles[0..self.count];
    }
};

test "opaque region bounds retained rectangle hints" {
    var region: OpaqueRegion = .{};
    for (0..maximum_opaque_region_rectangles) |index| {
        try std.testing.expect(region.append(.{
            .x = @intCast(index),
            .y = 0,
            .width = 1,
            .height = 1,
        }));
    }
    try std.testing.expect(!region.append(.{ .x = 20, .y = 0, .width = 1, .height = 1 }));
    try std.testing.expectEqual(maximum_opaque_region_rectangles, region.slice().len);
}

pub const SamplingFilter = enum {
    nearest,
    linear,
    reconstruction,
    area,
};

pub fn shadowBlurExtent(blur_radius: u32) u32 {
    // The shadow shader uses half the blur radius as sigma, so three sigma
    // lets the Gaussian tail dissipate before reaching the render boundary.
    return blur_radius +| (blur_radius / 2 + blur_radius % 2);
}

pub const Shadow = struct {
    rect: Rect,
    corner_radius: u32,
    blur_radius: u32,
    spread: i32,
    /// Top color. When `bottom_color` is set, the renderer interpolates between
    /// the two colors over the shadow shape's full vertical extent.
    color: Color,
    bottom_color: ?Color = null,
    cutout: ?RoundedClip = null,
    clip: ?Rect = null,
};

pub const BackdropBlurFinish = struct {
    brightness: f32 = 1,
    contrast: f32 = 1,
    saturation: f32 = 1,
    noise: f32 = 0,

    pub fn isNeutral(self: BackdropBlurFinish) bool {
        return self.brightness == 1 and self.contrast == 1 and
            self.saturation == 1 and self.noise == 0;
    }
};

/// Captures the completed target at this command-stream position. Subsequent
/// backdrop blurs explicitly reference this immutable source by ID.
pub const BackdropCapture = struct {
    id: u32 = 0,
    rect: Rect,
    radius: u32,
    downsample_level: ?u8 = null,
    finish: BackdropBlurFinish = .{},
    /// The base scene can be shared by later captures whose footprints contain
    /// no intervening content.
    base: bool = false,
};

/// Composites from the nearest preceding BackdropCapture with the matching ID.
/// The capture must cover this command and have matching blur parameters.
pub const BackdropBlur = struct {
    capture_id: u32 = 0,
    rect: Rect,
    corner_radius: u32,
    radius: u32,
    downsample_level: ?u8 = null,
    finish: BackdropBlurFinish = .{},
    clip: ?Rect = null,
};

pub const maximum_blur_downsample_level: u8 = 5;

pub const Command = union(enum) {
    clear: Color,
    solid_rect: SolidRect,
    shadow: Shadow,
    backdrop_capture: BackdropCapture,
    backdrop_blur: BackdropBlur,
    image: Image,
    crossfade: Crossfade,
};

pub const output_calibration_edge_length = 33;
pub const max_dmabuf_planes = 4;

/// The LUT values are borrowed and must remain alive and unchanged for every
/// render operation that uses this calibration.
pub const OutputCalibration = struct {
    identity: u64,
    edge_length: u32,
    values: []const [4]f16,
};

/// A one-shot render description. All slices and nested PixelBuffer storage
/// are borrowed for the duration of the render operation.
pub const Frame = struct {
    size: Size,
    commands: []const Command,
    /// Target-local physical pixels to update. Null updates the full target.
    /// Rectangles must not overlap; renderers may composite each rectangle
    /// independently, so overlaps would blend translucent content twice.
    damage: ?[]const Rect = null,
    scale: Scale = .{},
    /// Global logical coordinate rendered at the target's top-left corner.
    origin: Position = .{},
    output_color_description: ColorDescription = .{},
    output_calibration: ?OutputCalibration = null,
};

pub const DmabufFormat = enum(u32) {
    argb8888 = 0x34325241,
    xrgb8888 = 0x34325258,
    abgr8888 = 0x34324241,
    xbgr8888 = 0x34324258,
    xrgb2101010 = 0x30335258,
    nv12 = 0x3231564e,
    p010 = 0x30313050,

    pub fn fromFourcc(fourcc: u32) ?DmabufFormat {
        return switch (fourcc) {
            @intFromEnum(DmabufFormat.argb8888) => .argb8888,
            @intFromEnum(DmabufFormat.xrgb8888) => .xrgb8888,
            @intFromEnum(DmabufFormat.abgr8888) => .abgr8888,
            @intFromEnum(DmabufFormat.xbgr8888) => .xbgr8888,
            @intFromEnum(DmabufFormat.xrgb2101010) => .xrgb2101010,
            @intFromEnum(DmabufFormat.nv12) => .nv12,
            @intFromEnum(DmabufFormat.p010) => .p010,
            else => null,
        };
    }

    pub fn hasAlpha(self: DmabufFormat) bool {
        return self == .argb8888 or self == .abgr8888;
    }

    pub fn isPackedRgb(self: DmabufFormat) bool {
        return switch (self) {
            .argb8888, .xrgb8888, .abgr8888, .xbgr8888, .xrgb2101010 => true,
            .nv12, .p010 => false,
        };
    }

    pub fn planeCount(self: DmabufFormat) u8 {
        return switch (self) {
            .argb8888, .xrgb8888, .abgr8888, .xbgr8888, .xrgb2101010 => 1,
            .nv12, .p010 => 2,
        };
    }

    pub fn planeRowBytes(self: DmabufFormat, plane_index: u8, width: u32) ?u64 {
        if (plane_index >= self.planeCount()) return null;
        return switch (self) {
            .argb8888, .xrgb8888, .abgr8888, .xbgr8888, .xrgb2101010 => @as(u64, width) * @sizeOf(u32),
            .nv12 => if (plane_index == 0)
                width
            else
                @as(u64, (width + 1) / 2) * 2,
            .p010 => if (plane_index == 0)
                @as(u64, width) * 2
            else
                @as(u64, (width + 1) / 2) * 4,
        };
    }

    pub fn planeHeight(self: DmabufFormat, plane_index: u8, height: u32) ?u32 {
        if (plane_index >= self.planeCount()) return null;
        return switch (self) {
            .argb8888, .xrgb8888, .abgr8888, .xbgr8888, .xrgb2101010 => height,
            .nv12, .p010 => if (plane_index == 0) height else (height + 1) / 2,
        };
    }

    pub fn planeAlignment(self: DmabufFormat) u32 {
        return switch (self) {
            .argb8888, .xrgb8888, .abgr8888, .xbgr8888, .xrgb2101010 => @alignOf(u32),
            .nv12 => 1,
            .p010 => @alignOf(u16),
        };
    }

    pub fn opaqueFormat(self: DmabufFormat) DmabufFormat {
        return switch (self) {
            .argb8888 => .xrgb8888,
            .abgr8888 => .xbgr8888,
            .xrgb8888, .xbgr8888, .xrgb2101010, .nv12, .p010 => self,
        };
    }

    pub fn redBlueSwapped(self: DmabufFormat) bool {
        return self == .abgr8888 or self == .xbgr8888;
    }

    pub fn toArgb8888(self: DmabufFormat, pixel: u32) u32 {
        std.debug.assert(self.isPackedRgb());
        if (self == .xrgb2101010) return 0xff00_0000 |
            tenToEight((pixel >> 20) & 0x3ff) << 16 |
            tenToEight((pixel >> 10) & 0x3ff) << 8 |
            tenToEight(pixel & 0x3ff);
        var converted = if (self.redBlueSwapped()) swapRedBlue(pixel) else pixel;
        if (!self.hasAlpha()) converted |= 0xff00_0000;
        return converted;
    }

    pub fn fromArgb8888(self: DmabufFormat, pixel: u32) u32 {
        std.debug.assert(self.isPackedRgb());
        if (self == .xrgb2101010) return 0xc000_0000 |
            eightToTen((pixel >> 16) & 0xff) << 20 |
            eightToTen((pixel >> 8) & 0xff) << 10 |
            eightToTen(pixel & 0xff);
        const converted = if (self.hasAlpha()) pixel else pixel | 0xff00_0000;
        return if (self.redBlueSwapped()) swapRedBlue(converted) else converted;
    }

    fn tenToEight(value: u32) u32 {
        return (value * 255 + 511) / 1023;
    }

    fn eightToTen(value: u32) u32 {
        return (value * 1023 + 127) / 255;
    }

    fn swapRedBlue(pixel: u32) u32 {
        return pixel & 0xff00_ff00 |
            (pixel & 0x00ff_0000) >> 16 |
            (pixel & 0x0000_00ff) << 16;
    }
};

pub const DmabufFormatModifier = struct {
    format: u32,
    modifier: u64,

    pub fn matches(self: DmabufFormatModifier, format: u32, modifier: u64) bool {
        return self.format == format and self.modifier == modifier;
    }

    pub fn contains(pairs: []const DmabufFormatModifier, format: u32, modifier: u64) bool {
        for (pairs) |pair| if (pair.matches(format, modifier)) return true;
        return false;
    }
};

/// A CPU-addressable ARGB8888 target or a retained DMA-BUF image source.
/// Render targets are always CPU-addressable. Image sources may instead set
/// `dmabuf` and leave `pixels` empty so GPU renderers can sample them directly.
/// Pixel and source-damage slices are borrowed for the render operation.
pub const PixelBuffer = struct {
    size: Size,
    stride_pixels: u32,
    pixels: []u32 = &.{},
    dmabuf: ?DmabufSource = null,
    color_description: ColorDescription = .{},
    color_representation: ColorRepresentation = .{},
    /// Stable content identity for renderer texture caches. Anonymous buffers
    /// leave this null and must be uploaded whenever they are rendered.
    source_cache: ?SourceCache = null,
    /// Changed pixels for this source-cache version, in buffer coordinates.
    /// Null means the full buffer or unknown damage.
    source_damage: ?[]const Rect = null,
};

pub const DirectScanoutRejection = enum(u8) {
    no_fullscreen_surface,
    non_opaque_surface,
    surface_transform,
    non_dmabuf,
    y_inverted,
    missing_buffer_identity,
    color_conversion,
    unsupported_backend,
    output_unavailable,
    output_busy,
    device_inactive,
    unsupported_format_or_modifier,
    unsupported_layout,
    framebuffer_import_failed,
    page_flip_failed,
};

pub const DirectScanoutCandidate = union(enum) {
    candidate: PixelBuffer,
    rejected: DirectScanoutRejection,
};

pub const OverlayScanoutRejection = enum(u8) {
    no_topmost_surface,
    non_opaque_surface,
    clipped_surface,
    transformed_surface,
    scaled_surface,
    outside_output,
    non_dmabuf,
    non_rgb_surface,
    y_inverted,
    missing_buffer_identity,
    color_conversion,
    unsupported_backend,
    output_unavailable,
    output_busy,
    device_inactive,
    no_overlay_plane,
    unsupported_format_or_modifier,
    unsupported_layout,
    synchronization_failed,
    framebuffer_import_failed,
    atomic_test_failed,
    page_flip_failed,
};

pub const OverlayScanout = struct {
    buffer: PixelBuffer,
    destination: Rect,
};

pub const OverlayScanoutCandidate = union(enum) {
    candidate: OverlayScanout,
    rejected: OverlayScanoutRejection,
};

pub const DmabufPlane = struct {
    fd: std.posix.fd_t = -1,
    stride: u32 = 0,
    offset: u32 = 0,
    required_bytes: usize = 0,
};

/// An externally owned DMA-BUF image. The context and plane descriptors,
/// including their file descriptors, are borrowed. A consumer that stores the
/// source beyond the current call must retain it and later release it.
pub const DmabufSource = struct {
    context: *anyopaque,
    format: u32,
    modifier: u64,
    planes: [max_dmabuf_planes]DmabufPlane,
    plane_count: u8,
    y_inverted: bool,
    force_opaque: bool,
    retain: *const fn (*anyopaque) void,
    release: *const fn (*anyopaque) void,
    /// A successful begin must be paired with end_cpu_read.
    begin_cpu_read: *const fn (*anyopaque) bool,
    end_cpu_read: *const fn (*anyopaque) bool,
    /// Returns a caller-owned sync-file descriptor when synchronization is needed.
    export_read_fence: *const fn (*anyopaque, u8) ?std.posix.fd_t,

    pub fn planeSlice(self: *const DmabufSource) []const DmabufPlane {
        std.debug.assert(self.plane_count > 0 and self.plane_count <= max_dmabuf_planes);
        return self.planes[0..self.plane_count];
    }
};

pub const DmabufSourceDescriptor = struct {
    size: Size,
    format: u32,
    modifier: u64,
    planes: [max_dmabuf_planes]DmabufPlane,
    plane_count: u8,
    force_opaque: bool,
};

/// A validator borrowed from its renderer. The context and callback become
/// invalid when that renderer is deinitialized.
pub const DmabufSourceValidator = struct {
    context: *anyopaque,
    validate: *const fn (*anyopaque, DmabufSourceDescriptor) anyerror!void,
};

pub const Target = union(enum) {
    pixels: PixelBuffer,
    offscreen: OffscreenTarget,
    dmabuf: DmabufTarget,

    pub fn size(self: Target) Size {
        return switch (self) {
            .pixels => |pixels| pixels.size,
            .offscreen => |offscreen| offscreen.size,
            .dmabuf => |dmabuf| dmabuf.size,
        };
    }
};

pub const FrameCompletion = struct {
    /// Owned by the caller when non-null.
    sync_file_fd: ?std.posix.fd_t = null,
    /// CPU-to-GPU texture upload operations performed for this frame.
    cpu_uploads: u32 = 0,
    /// New Vulkan DMA-BUF image imports created for this frame.
    dmabuf_imports: u32 = 0,
};

pub const ResourceStatistics = struct {
    targets: usize = 0,
    pixel_targets: usize = 0,
    offscreen_targets: usize = 0,
    dmabuf_targets: usize = 0,
    cached_textures: usize = 0,
    imported_textures: usize = 0,
    pending_textures: usize = 0,
    pending_gpu_submissions: usize = 0,
    calibration_textures: usize = 0,
    video_graphics_pipelines: usize = 0,
    blur_scratch_images: usize = 0,
    backdrop_cache_images: usize = 0,
    mapped_buffer_capacity_bytes: usize = 0,
    /// Cumulative frames whose preparation began while the same output's
    /// previous submission was still executing on the GPU.
    submission_overlap_frames: u64 = 0,
    /// Cumulative frames that blocked because every submission ring slot
    /// was still in flight, and the total time spent blocked.
    submission_slot_waits: u64 = 0,
    submission_slot_wait_nanoseconds: u64 = 0,
};

pub const OffscreenTarget = struct {
    id: u64,
    size: Size,
};

pub const DmabufTarget = struct {
    id: u64,
    size: Size,
};

pub const DmabufDescriptor = struct {
    id: u64,
    size: Size,
    fd: std.posix.fd_t,
    format: u32,
    modifier: u64,
    stride: u32,
    offset: u32,
};

pub const DrmDeviceId = struct {
    major: u32,
    minor: u32,
};

/// Renderer operations borrowed by a DRM output for the lifetime of the
/// renderer. Import duplicates the descriptor's borrowed file descriptor.
/// Every successful import owns the descriptor ID until exactly one matching
/// release_target call.
pub const DmabufRenderer = struct {
    context: *anyopaque,
    target_formats: []const DmabufFormatModifier,
    supports_target: *const fn (*anyopaque, Size, u32, u64) bool,
    import_target: *const fn (*anyopaque, DmabufDescriptor) anyerror!void,
    release_target: *const fn (*anyopaque, u64) void,
};

/// Renderer-owned storage for outputs which have no display backend. The
/// context and callbacks remain valid only for the renderer's lifetime. Every
/// successful create_target call requires exactly one matching release_target
/// call before that renderer is deinitialized.
pub const OffscreenRenderer = struct {
    context: *anyopaque,
    create_target: *const fn (*anyopaque, Size) anyerror!OffscreenTarget,
    release_target: *const fn (*anyopaque, u64) void,
};

pub const SourceCache = struct {
    id: u64,
    version: u64,
};

test "color conversion premultiplies alpha" {
    const color = Color.rgba(255, 127, 0, 128);

    try std.testing.expectEqual(@as(u8, 128), color.red);
    try std.testing.expectEqual(@as(u8, 64), color.green);
    try std.testing.expectEqual(@as(u8, 0), color.blue);
    try std.testing.expectEqual(@as(u8, 128), color.alpha);
    try std.testing.expectEqual(@as(u32, 0x80804000), color.argb8888());
}

test "DMA-BUF formats normalize red-blue order and opacity" {
    try std.testing.expectEqual(DmabufFormat.xrgb8888, DmabufFormat.argb8888.opaqueFormat());
    try std.testing.expectEqual(DmabufFormat.xbgr8888, DmabufFormat.abgr8888.opaqueFormat());
    const pairs = [_]DmabufFormatModifier{.{ .format = 7, .modifier = 11 }};
    try std.testing.expect(DmabufFormatModifier.contains(&pairs, 7, 11));
    try std.testing.expect(!DmabufFormatModifier.contains(&pairs, 7, 12));
    try std.testing.expectEqual(
        DmabufFormat.abgr8888,
        DmabufFormat.fromFourcc(0x34324241).?,
    );
    try std.testing.expect(DmabufFormat.fromFourcc(0) == null);
    try std.testing.expectEqual(
        @as(u32, 0x80332211),
        DmabufFormat.abgr8888.toArgb8888(0x80112233),
    );
    try std.testing.expectEqual(@as(u8, 2), DmabufFormat.nv12.planeCount());
    try std.testing.expectEqual(@as(u64, 5), DmabufFormat.nv12.planeRowBytes(0, 5).?);
    try std.testing.expectEqual(@as(u64, 6), DmabufFormat.nv12.planeRowBytes(1, 5).?);
    try std.testing.expectEqual(@as(u32, 3), DmabufFormat.nv12.planeHeight(1, 5).?);
    try std.testing.expectEqual(@as(u64, 10), DmabufFormat.p010.planeRowBytes(0, 5).?);
    try std.testing.expectEqual(@as(u64, 12), DmabufFormat.p010.planeRowBytes(1, 5).?);
    try std.testing.expect(!DmabufFormat.p010.isPackedRgb());
    try std.testing.expectEqual(
        @as(u32, 0xff332211),
        DmabufFormat.xbgr8888.toArgb8888(0x00112233),
    );
    try std.testing.expectEqual(
        @as(u32, 0x80112233),
        DmabufFormat.abgr8888.fromArgb8888(0x80332211),
    );
    try std.testing.expectEqual(
        @as(u32, 0xff804020),
        DmabufFormat.xrgb2101010.toArgb8888(0xe024_0480),
    );
    try std.testing.expectEqual(
        @as(u32, 0xe024_0480),
        DmabufFormat.xrgb2101010.fromArgb8888(0xff804020),
    );
}

test "HDR transfer functions are identified explicitly" {
    const pq: TransferFunction = .st2084_pq;
    const hlg: TransferFunction = .hlg;
    const srgb: TransferFunction = .srgb;
    try std.testing.expect(pq.isHdr());
    try std.testing.expect(hlg.isHdr());
    try std.testing.expect(!srgb.isHdr());
    try std.testing.expect(!(TransferFunction{ .power = 22000 }).isHdr());
}

test "fractional scale rounds physical dimensions halfway up" {
    const scale: Scale = .{ .numerator = 180 };
    try std.testing.expectEqual(@as(u32, 2), try scale.ceil());
    try std.testing.expectEqual(
        Size{ .width = 1920, .height = 1080 },
        try scale.apply(.{ .width = 1280, .height = 720 }),
    );
    try std.testing.expectEqual(
        Size{ .width = 2, .height = 5 },
        try scale.apply(.{ .width = 1, .height = 3 }),
    );
}

test "fractional scale floors logical output dimensions" {
    const scale: Scale = .{ .numerator = 156 };
    try std.testing.expectEqual(
        Size{ .width = 1476, .height = 830 },
        try scale.logicalSize(.{ .width = 1920, .height = 1080 }),
    );
    try std.testing.expectError(
        error.InvalidDimensions,
        (Scale{ .numerator = 240 }).logicalSize(.{ .width = 1, .height = 1 }),
    );
}

test "renderer conformance: image sampling preserves exact texel alignment" {
    const buffer: PixelBuffer = .{
        .size = .{ .width = 3, .height = 2 },
        .stride_pixels = 3,
    };
    var image: Image = .{
        .x = 0,
        .y = 0,
        .size = buffer.size,
        .buffer = buffer,
    };
    try std.testing.expectEqual(SamplingFilter.nearest, image.samplingFilter());

    image.size = .{ .width = 6, .height = 4 };
    try std.testing.expectEqual(SamplingFilter.linear, image.samplingFilter());
    image.size = .{ .width = 1, .height = 1 };
    try std.testing.expectEqual(SamplingFilter.area, image.samplingFilter());

    image.size = .{ .width = 1, .height = 2 };
    try std.testing.expectEqual(SamplingFilter.area, image.samplingFilter());
    image.size = .{ .width = 3, .height = 1 };
    try std.testing.expectEqual(SamplingFilter.reconstruction, image.samplingFilter());

    image.size = .{ .width = 2, .height = 2 };
    image.source = .{ .x = 1, .y = 0, .width = 2, .height = 2 };
    try std.testing.expectEqual(SamplingFilter.nearest, image.samplingFilter());
    image.source.?.x = 0.5;
    try std.testing.expectEqual(SamplingFilter.reconstruction, image.samplingFilter());

    image.buffer.size = .{ .width = 4, .height = 4 };
    image.size = .{ .width = 4, .height = 4 };
    image.source = .{ .x = 1, .y = 1, .width = 2, .height = 2 };
    try std.testing.expectEqual(SamplingFilter.reconstruction, image.samplingFilter());

    image.source = null;
    image.size = .{ .width = 8, .height = 2 };
    try std.testing.expectEqual(SamplingFilter.reconstruction, image.samplingFilter());

    image.transform = .rotate_90;
    image.buffer.size = .{ .width = 3, .height = 2 };
    image.size = .{ .width = 2, .height = 3 };
    try std.testing.expectEqual(SamplingFilter.nearest, image.samplingFilter());
}

test "shadow blur extent covers the three sigma tail" {
    try std.testing.expectEqual(@as(u32, 0), shadowBlurExtent(0));
    try std.testing.expectEqual(@as(u32, 2), shadowBlurExtent(1));
    try std.testing.expectEqual(@as(u32, 3), shadowBlurExtent(2));
    try std.testing.expectEqual(@as(u32, 5), shadowBlurExtent(3));
    try std.testing.expectEqual(@as(u32, 36), shadowBlurExtent(24));
    try std.testing.expectEqual(std.math.maxInt(u32), shadowBlurExtent(std.math.maxInt(u32)));
}

test "rectangle clipping handles negative and overflowing coordinates" {
    const clipped = (Rect{
        .x = -2,
        .y = 3,
        .width = 8,
        .height = 10,
    }).clipTo(.{ .width = 5, .height = 7 });

    try std.testing.expectEqual(Rect{
        .x = 0,
        .y = 3,
        .width = 5,
        .height = 4,
    }, clipped.?);

    try std.testing.expectEqual(@as(?Rect, null), (Rect{
        .x = 5,
        .y = 0,
        .width = 1,
        .height = 1,
    }).clipTo(.{ .width = 5, .height = 7 }));
}

test "rectangle intersection and translation preserve logical coordinates" {
    const first: Rect = .{ .x = 10, .y = 20, .width = 30, .height = 40 };
    const second: Rect = .{ .x = 25, .y = 5, .width = 30, .height = 30 };

    try std.testing.expect(first.contains(.{ .x = 12, .y = 24, .width = 4, .height = 5 }));
    try std.testing.expect(!first.contains(second));
    try std.testing.expectEqual(Rect{
        .x = 25,
        .y = 20,
        .width = 15,
        .height = 15,
    }, first.intersection(second).?);
    try std.testing.expectEqual(Rect{
        .x = 10,
        .y = 5,
        .width = 45,
        .height = 55,
    }, first.unionWith(second));
    try std.testing.expectEqual(Rect{
        .x = 7,
        .y = 24,
        .width = 30,
        .height = 40,
    }, first.translated(-3, 4));
    try std.testing.expectEqual(@as(?Rect, null), first.intersection(.{
        .x = 40,
        .y = 20,
        .width = 1,
        .height = 1,
    }));
}
