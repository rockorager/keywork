//! Native DRM/KMS output using CPU-mapped dumb buffers.

const Self = @This();

const std = @import("std");
const Gbm = @import("gbm.zig");
const NestedOutput = @import("nested_wayland.zig");
const Logging = @import("../logging.zig");
const presentation = @import("../presentation.zig");
const Region = @import("../region.zig");
const Icc = @import("../render/icc.zig");
const render = @import("../render/types.zig");
const plane_assignment = @import("drm_plane_assignment.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("libdisplay-info/info.h");
    @cInclude("libudev.h");
    @cInclude("libdrm/drm_fourcc.h");
    @cInclude("linux/dma-buf.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/stat.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});
const log = std.log.scoped(.drm);
const buffer_count = 2;
const description_capacity = 512;
const drm_format_mod_linear: u64 = 0;
const default_target_dpi: f64 = 110.0;
const minimum_plausible_dpi: f64 = 50.0;
const maximum_plausible_dpi: f64 = 500.0;
const maximum_axis_dpi_ratio: f64 = 1.2;
const default_scale_step = render.Scale.denominator / 4;
const maximum_default_scale = render.Scale.denominator * 4;

allocator: std.mem.Allocator,
io: std.Io,
device_access: DeviceAccess,
listener: ?Listener,
dmabuf_renderer: ?render.DmabufRenderer,
old_crtc: ?*c.drmModeCrtc,
buffers: [buffer_count]Buffer,
shadow_pixels: []u32,
buffer_damage: [buffer_count]Region,
acquired_damage: Region,
cursor_buffers: [2]Buffer,
cursor_width: u32,
cursor_height: u32,
cursor_buffer_index: ?usize,
cursor_source: ?render.SourceCache,
cursor_scale: render.Scale,
cursor_active: bool,
cursor_failed: bool,
mode: c.drmModeModeInfo,
mode_index: usize,
modes: []Mode,
size: render.Size,
physical_size: render.Size,
scale: render.Scale,
connector_id: u32,
crtc_id: u32,
primary_plane_id: ?u32,
atomic_plane: ?AtomicPlaneProperties,
overlay_plane: ?OverlayPlane,
atomic_color: ?AtomicColorProperties,
gamma_size: u32,
gamma_lut: []u16,
scanout_formats: []render.DmabufFormatModifier,
implicit_scanout: bool,
sync_file_import_supported: bool,
async_page_flip_supported: bool,
connector_name: [32]u8,
connector_name_length: usize,
make_value: [*c]u8,
model_value: [*c]u8,
serial_value: [*c]u8,
color_description: render.ColorDescription,
native_color_description: render.ColorDescription,
sdr_color_description: render.ColorDescription,
icc_profile: ?Icc.OutputProfile,
icc_profile_path: ?[]u8,
hdr_capabilities: HdrCapabilities,
output_color_mode: OutputColorMode,
output_color_dirty: bool,
rejected_output_color_mode: ?OutputColorMode,
hdr_failed: bool,
color_fallback_pending: bool,
hdr_metadata_blob: u32,
hdr_metadata_blob_mode: ?OutputColorMode,
description_value: [description_capacity]u8,
description_length: usize,
logical_x: i32,
logical_y: i32,
refresh_nanoseconds: u32,
presentation_clock_id: u32,
acquired: ?usize,
pending: ?usize,
displayed: ?usize,
direct_pending: ?ClientScanout,
direct_displayed: ?ClientScanout,
overlay_pending: ?ClientScanout,
overlay_displayed: ?ClientScanout,
validated_overlay: ?PreparedOverlay,
pending_page_flip: ?PageFlipMode,
scanout_framebuffers: std.AutoHashMapUnmanaged(ScanoutFramebufferKey, ScanoutFramebuffer),
scanout_frame_number: u64,
direct_scanout_active: bool,
enabled: bool,
powered: bool,
mode_set: bool,
retired: bool,

pub const Listener = NestedOutput.Listener;

const Buffer = struct {
    gbm: ?Gbm.Buffer = null,
    render_target_id: ?u64 = null,
    handle: u32 = 0,
    framebuffer_id: u32 = 0,
    mapping: ?[]align(std.heap.page_size_min) u8 = null,
    pixels: []u32 = &.{},
    stride_pixels: u32 = 0,
};

const ScanoutFramebufferKey = struct {
    cache_id: u64,
    format: u32,
};

const ScanoutFramebuffer = struct {
    framebuffer_id: u32,
    size: render.Size,
    format: u32,
    modifier: u64,
    plane_count: u8,
    strides: [render.max_dmabuf_planes]u32,
    offsets: [render.max_dmabuf_planes]u32,
    last_used: u64,
};

const ClientScanout = struct {
    source: render.DmabufSource,
    framebuffer_key: ScanoutFramebufferKey,

    fn release(self: ClientScanout) void {
        self.source.release(self.source.context);
    }
};

const AtomicOverlay = struct {
    source: render.DmabufSource,
    source_size: render.Size,
    destination: render.Rect,
    framebuffer_id: u32,
    color: ?AtomicPlaneColorState,
};

const PreparedOverlay = struct {
    atomic: AtomicOverlay,
    scanout: ClientScanout,
};

const PreparedOverlayResult = union(enum) {
    prepared: PreparedOverlay,
    rejected: render.OverlayScanoutRejection,
};

const AcquiredFrame = struct {
    fd: std.posix.fd_t,
    index: usize,
    buffer: *Buffer,
};

const PageFlipMode = enum {
    vsync,
    async,
};

const PageFlipAction = enum {
    test_only,
    commit,
};

const AtomicPlaneProperties = struct {
    fb_id: u32 = 0,
    crtc_id: u32 = 0,
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    crtc_x: u32 = 0,
    crtc_y: u32 = 0,
    crtc_w: u32 = 0,
    crtc_h: u32 = 0,
    in_fence_fd: u32 = 0,
    color: AtomicPlaneColorProperties = .{},

    fn complete(self: AtomicPlaneProperties) bool {
        return self.fb_id != 0 and self.crtc_id != 0 and
            self.src_x != 0 and self.src_y != 0 and self.src_w != 0 and self.src_h != 0 and
            self.crtc_x != 0 and self.crtc_y != 0 and
            self.crtc_w != 0 and self.crtc_h != 0;
    }
};

const AtomicPlaneColorProperties = struct {
    encoding: u32 = 0,
    bt601: ?u64 = null,
    bt709: ?u64 = null,
    bt2020: ?u64 = null,
    range: u32 = 0,
    full_range: ?u64 = null,
    limited_range: ?u64 = null,

    fn state(
        self: AtomicPlaneColorProperties,
        representation: render.ColorRepresentation,
    ) ?AtomicPlaneColorState {
        if (self.encoding == 0 or self.range == 0) return null;
        const encoding = switch (representation.coefficients) {
            .identity => return null,
            .bt601 => self.bt601,
            .bt709 => self.bt709,
            .bt2020 => self.bt2020,
        } orelse return null;
        const range = switch (representation.range) {
            .full => self.full_range,
            .limited => self.limited_range,
        } orelse return null;
        return .{
            .encoding_property = self.encoding,
            .encoding = encoding,
            .range_property = self.range,
            .range = range,
        };
    }
};

const AtomicPlaneColorState = struct {
    encoding_property: u32,
    encoding: u64,
    range_property: u32,
    range: u64,
};

const AtomicZpos = struct {
    property_id: u32,
    value: u64,
};

const AtomicPlaneDisableProperties = struct {
    fb_id: u32 = 0,
    crtc_id: u32 = 0,

    fn complete(self: AtomicPlaneDisableProperties) bool {
        return self.fb_id != 0 and self.crtc_id != 0;
    }
};

const PlaneSelectionInfo = struct {
    plane_type: ?u64 = null,
    formats_blob_id: ?u32 = null,
    zpos: ?plane_assignment.Zpos = null,
};

const OverlayPlane = struct {
    id: u32,
    formats: []render.DmabufFormatModifier,
    atomic: AtomicPlaneProperties,
    zpos_property: ?u32,
    zpos: u64,

    fn deinit(self: OverlayPlane, allocator: std.mem.Allocator) void {
        allocator.free(self.formats);
    }

    fn clone(self: OverlayPlane, allocator: std.mem.Allocator) !OverlayPlane {
        var result = self;
        result.formats = try allocator.dupe(render.DmabufFormatModifier, self.formats);
        return result;
    }
};

const AtomicConnectorColorProperties = struct {
    colorspace: u32 = 0,
    default_colorspace: ?u64 = null,
    bt2020_rgb: ?u64 = null,
    current_colorspace: u64 = 0,
    hdr_output_metadata: u32 = 0,
    current_hdr_output_metadata: u64 = 0,
    max_bpc: u32 = 0,
    min_bpc: u64 = 0,
    max_bpc_limit: u64 = 0,
    current_max_bpc: u64 = 0,
};

const AtomicCrtcColorProperties = struct {
    degamma_lut: u32 = 0,
    degamma_lut_size: u32 = 0,
    current_degamma_lut: u64 = 0,
    ctm: u32 = 0,
    current_ctm: u64 = 0,
    gamma_lut: u32 = 0,
    gamma_lut_size: u32 = 0,
    current_gamma_lut: u64 = 0,
};

const AtomicColorProperties = struct {
    connector: AtomicConnectorColorProperties,
    crtc: AtomicCrtcColorProperties,
};

const HdrCapabilities = struct {
    bt2020_rgb: bool = false,
    static_metadata_type1: bool = false,
    pq: bool = false,
    hlg: bool = false,
    min_luminance: ?u32 = null,
    max_luminance: ?u32 = null,
    max_frame_average_luminance: ?u32 = null,

    fn supports(self: HdrCapabilities, transfer: render.TransferFunction) bool {
        if (!self.bt2020_rgb or !self.static_metadata_type1) return false;
        return switch (transfer) {
            .st2084_pq => self.pq,
            .hlg => self.hlg,
            .bt1886, .gamma22, .srgb, .power => false,
        };
    }
};

const OutputColorMode = enum {
    sdr,
    pq,
    hlg,

    fn transfer(self: OutputColorMode) ?render.TransferFunction {
        return switch (self) {
            .sdr => null,
            .pq => .st2084_pq,
            .hlg => .hlg,
        };
    }
};

pub const DirectScanoutResult = union(enum) {
    accepted,
    rejected: render.DirectScanoutRejection,
};

pub const OverlayScanoutResult = union(enum) {
    accepted,
    rejected: render.OverlayScanoutRejection,
};

const max_scanout_framebuffers = 8;

pub const Selection = struct {
    modes: []Mode,
    mode_index: usize,
    physical_size: render.Size,
    connector_id: u32,
    connector_type: u32,
    connector_type_id: u32,
    crtc_id: u32,
    primary_plane_id: ?u32,
    overlay_plane: ?OverlayPlane,
    scanout_formats: []render.DmabufFormatModifier,
    implicit_scanout: bool,
};

const PrimaryPlane = struct {
    id: ?u32 = null,
    formats: []render.DmabufFormatModifier = &.{},
    implicit: bool = true,
    zpos: ?u64 = null,
};

pub const Mode = struct {
    value: c.drmModeModeInfo,
    preferred: bool,

    pub fn size(self: Mode) render.Size {
        return .{ .width = self.value.hdisplay, .height = self.value.vdisplay };
    }

    pub fn refreshMillihertz(self: Mode) i32 {
        return @intCast(@min(
            @as(u64, self.value.vrefresh) * 1000,
            std.math.maxInt(i32),
        ));
    }
};

pub const DeviceAccess = struct {
    context: *anyopaque,
    fd: *const fn (*anyopaque) ?std.posix.fd_t,
    gbm: *const fn (*anyopaque) ?*Gbm = unavailableGbm,
    atomic: *const fn (*anyopaque) bool = unavailableAtomic,
    active: *const fn (*anyopaque) bool,
    fail: *const fn (*anyopaque, anyerror) void,
};

const event_context: c.drmEventContext = .{
    .version = 2,
    .vblank_handler = null,
    .page_flip_handler = handlePageFlip,
    .page_flip_handler2 = null,
    .sequence_handler = null,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    device_access: DeviceAccess,
) void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .device_access = device_access,
        .listener = null,
        .dmabuf_renderer = null,
        .old_crtc = null,
        .buffers = .{ .{}, .{} },
        .shadow_pixels = &.{},
        .buffer_damage = .{ Region.init(), Region.init() },
        .acquired_damage = Region.init(),
        .cursor_buffers = .{ .{}, .{} },
        .cursor_width = 0,
        .cursor_height = 0,
        .cursor_buffer_index = null,
        .cursor_source = null,
        .cursor_scale = .{},
        .cursor_active = false,
        .cursor_failed = false,
        .mode = std.mem.zeroes(c.drmModeModeInfo),
        .mode_index = 0,
        .modes = &.{},
        .size = .{ .width = 0, .height = 0 },
        .physical_size = .{ .width = 0, .height = 0 },
        .scale = .{},
        .connector_id = 0,
        .crtc_id = 0,
        .primary_plane_id = null,
        .atomic_plane = null,
        .overlay_plane = null,
        .atomic_color = null,
        .gamma_size = 0,
        .gamma_lut = &.{},
        .scanout_formats = &.{},
        .implicit_scanout = true,
        .sync_file_import_supported = true,
        .async_page_flip_supported = false,
        .connector_name = undefined,
        .connector_name_length = 0,
        .make_value = null,
        .model_value = null,
        .serial_value = null,
        .color_description = .{},
        .native_color_description = .{},
        .sdr_color_description = .{},
        .icc_profile = null,
        .icc_profile_path = null,
        .hdr_capabilities = .{},
        .output_color_mode = .sdr,
        .output_color_dirty = false,
        .rejected_output_color_mode = null,
        .hdr_failed = false,
        .color_fallback_pending = false,
        .hdr_metadata_blob = 0,
        .hdr_metadata_blob_mode = null,
        .description_value = undefined,
        .description_length = 0,
        .logical_x = 0,
        .logical_y = 0,
        .refresh_nanoseconds = presentation.nominal_refresh_nanoseconds,
        .presentation_clock_id = presentation.monotonic_clock_id,
        .acquired = null,
        .pending = null,
        .displayed = null,
        .direct_pending = null,
        .direct_displayed = null,
        .overlay_pending = null,
        .overlay_displayed = null,
        .validated_overlay = null,
        .pending_page_flip = null,
        .scanout_framebuffers = .empty,
        .scanout_frame_number = 0,
        .direct_scanout_active = false,
        .enabled = true,
        .powered = true,
        .mode_set = false,
        .retired = false,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.listener == null);
    std.debug.assert(self.old_crtc == null);
    std.debug.assert(self.hdr_metadata_blob == 0);
    std.debug.assert(self.shadow_pixels.len == 0);
    std.debug.assert(self.direct_pending == null and self.direct_displayed == null);
    std.debug.assert(self.overlay_pending == null and self.overlay_displayed == null);
    std.debug.assert(self.validated_overlay == null);
    std.debug.assert(self.scanout_framebuffers.count() == 0);
    self.scanout_framebuffers.deinit(self.allocator);
    self.clearIdentity();
    if (self.icc_profile) |*profile| profile.deinit(self.allocator);
    if (self.icc_profile_path) |path| self.allocator.free(path);
    self.allocator.free(self.gamma_lut);
    self.allocator.free(self.modes);
    self.allocator.free(self.scanout_formats);
    if (self.overlay_plane) |plane| plane.deinit(self.allocator);
    for (&self.buffer_damage) |*damage| damage.deinit();
    self.acquired_damage.deinit();
    self.* = undefined;
}

pub fn attach(self: *Self, listener: Listener, dmabuf_renderer: ?render.DmabufRenderer) !void {
    std.debug.assert(self.listener == null);
    std.debug.assert(dmabuf_renderer != null or self.buffers[0].render_target_id == null);
    self.dmabuf_renderer = dmabuf_renderer;
    errdefer self.dmabuf_renderer = null;
    if (self.powered and self.buffers[0].framebuffer_id == 0) {
        std.debug.assert(self.acquired == null and self.pending == null and self.displayed == null);
        std.debug.assert(!self.mode_set and self.shadow_pixels.len == 0);
        const fd = self.device_access.fd(self.device_access.context) orelse
            return error.SessionInactive;
        const pair = try self.allocatePair(fd, self.size);
        self.buffers = pair.buffers;
        self.shadow_pixels = pair.shadow_pixels;
        self.resetBufferDamage(self.size);
    }
    self.listener = listener;
}

pub fn scanoutFormats(self: *const Self) []const render.DmabufFormatModifier {
    return self.scanout_formats;
}

pub fn compositedScanoutFormat(self: *const Self) render.DmabufFormat {
    const format = if (self.buffers[0].gbm) |buffer|
        buffer.format
    else
        c.DRM_FORMAT_XRGB8888;
    return render.DmabufFormat.fromFourcc(format) orelse unreachable;
}

pub fn detach(self: *Self) void {
    std.debug.assert(self.listener != null);
    self.listener = null;
}

pub fn releaseClientBuffers(self: *Self) void {
    self.releaseClientScanouts();
}

pub fn name(self: *const Self) []const u8 {
    return self.connector_name[0..self.connector_name_length];
}

pub fn make(self: *const Self) ?[]const u8 {
    return if (self.make_value == null) null else std.mem.span(self.make_value);
}

pub fn model(self: *const Self) ?[]const u8 {
    return if (self.model_value == null) null else std.mem.span(self.model_value);
}

pub fn serial(self: *const Self) ?[]const u8 {
    return if (self.serial_value == null) null else std.mem.span(self.serial_value);
}

pub fn description(self: *const Self) []const u8 {
    return self.description_value[0..self.description_length];
}

pub fn colorDescription(self: *const Self) render.ColorDescription {
    return self.color_description;
}

pub fn nativeColorDescription(self: *const Self) render.ColorDescription {
    return self.native_color_description;
}

pub fn outputCalibration(self: *const Self) ?render.OutputCalibration {
    if (self.output_color_mode != .sdr) return null;
    return if (self.icc_profile) |profile| profile.rendererCalibration() else null;
}

pub fn iccProfilePath(self: *const Self) ?[]const u8 {
    return self.icc_profile_path;
}

/// Returns the color description that `replaceIccProfile` will publish without
/// taking ownership of the prospective profile.
pub fn colorDescriptionForIccProfile(
    self: *const Self,
    profile: ?Icc.OutputProfile,
) render.ColorDescription {
    if (self.output_color_mode != .sdr) return self.color_description;
    return if (profile) |value|
        value.applyTo(self.native_color_description)
    else
        self.native_color_description;
}

pub fn replaceIccProfile(
    self: *Self,
    profile: ?Icc.OutputProfile,
    owned_path: ?[]u8,
) void {
    std.debug.assert((profile == null) == (owned_path == null));
    const color_description = self.colorDescriptionForIccProfile(profile);
    if (self.icc_profile) |*old| old.deinit(self.allocator);
    if (self.icc_profile_path) |path| self.allocator.free(path);
    self.icc_profile = profile;
    self.icc_profile_path = owned_path;
    self.refreshSdrColorDescription();
    std.debug.assert(self.output_color_mode != .sdr or
        std.meta.eql(color_description, self.sdr_color_description));
    self.color_description = color_description;
}

pub fn selectOutputTransfer(self: *Self, transfer: ?render.TransferFunction) bool {
    const selected_description = if (transfer) |requested|
        self.hdrOutputDescription(requested)
    else
        null;
    const mode: OutputColorMode = if (selected_description) |selected|
        switch (selected.transfer_function) {
            .st2084_pq => .pq,
            .hlg => .hlg,
            .bt1886, .gamma22, .srgb, .power => unreachable,
        }
    else
        .sdr;
    if (mode == self.output_color_mode) return false;
    if (self.rejected_output_color_mode == mode) return false;
    const fd = self.device_access.fd(self.device_access.context) orelse return false;
    if (!self.testOutputColorState(
        fd,
        mode,
        selected_description orelse self.sdr_color_description,
    )) {
        self.rejected_output_color_mode = mode;
        if (mode != .sdr) self.hdr_failed = true;
        return false;
    }
    self.output_color_mode = mode;
    self.output_color_dirty = true;
    self.rejected_output_color_mode = null;
    self.color_description = selected_description orelse self.sdr_color_description;
    return true;
}

pub fn hdrOutputDescription(
    self: *const Self,
    transfer: render.TransferFunction,
) ?render.ColorDescription {
    if (self.hdr_failed or !self.hdr_capabilities.supports(transfer) or
        self.compositedScanoutFormat() != .xrgb2101010 or self.atomic_plane == null)
    {
        return null;
    }
    const connector = (self.atomic_color orelse return null).connector;
    if (connector.colorspace == 0 or connector.default_colorspace == null or
        connector.bt2020_rgb == null or connector.hdr_output_metadata == 0 or
        (connector.max_bpc != 0 and connector.max_bpc_limit < 10))
    {
        return null;
    }
    return hdrDescription(self.native_color_description, self.hdr_capabilities, transfer);
}

pub fn refreshMillihertz(self: *const Self) i32 {
    return @intCast(@min(
        @as(u64, self.mode.vrefresh) * 1000,
        std.math.maxInt(i32),
    ));
}

pub fn availableModes(self: *const Self) []const Mode {
    return self.modes;
}

pub fn currentModeIndex(self: *const Self) usize {
    std.debug.assert(self.mode_index < self.modes.len);
    return self.mode_index;
}

pub fn logicalSize(self: *const Self) render.Size {
    return self.scale.logicalSize(self.size) catch unreachable;
}

pub fn ready(self: *const Self) bool {
    if (!self.enabled or !self.powered or !self.device_access.active(self.device_access.context) or
        self.acquired != null or self.pending != null or self.direct_pending != null) return false;
    return self.availableBuffer() != null;
}

pub const ShapeCursor = struct {
    buffer: render.PixelBuffer,
    size: render.Size,
    pointer_x: i32,
    pointer_y: i32,
    hotspot_x: i32,
    hotspot_y: i32,
};

pub fn canUseShapeCursor(self: *const Self, cursor: ShapeCursor) bool {
    if (!self.enabled or !self.powered or !self.mode_set or self.cursor_failed or
        self.output_color_mode != .sdr or
        !self.device_access.active(self.device_access.context)) return false;
    if (cursor.buffer.source_cache == null or cursor.buffer.dmabuf != null or
        cursor.buffer.pixels.len == 0) return false;
    return cursor.size.width != 0 and cursor.size.height != 0 and
        cursor.size.width <= self.cursor_width and cursor.size.height <= self.cursor_height;
}

/// Apply a built-in shape cursor, returning false when software composition is required.
/// Failure is sticky for this activation to avoid retrying an unsupported ioctl path.
pub fn setShapeCursor(self: *Self, cursor: ShapeCursor) bool {
    if (!self.canUseShapeCursor(cursor)) return false;
    const fd = self.device_access.fd(self.device_access.context) orelse return false;
    const source = cursor.buffer.source_cache.?;
    if (cursor.size.width == 0 or cursor.size.height == 0 or
        cursor.size.width > self.cursor_width or cursor.size.height > self.cursor_height) unreachable;
    const local = cursorLocalPosition(
        cursor.pointer_x,
        cursor.pointer_y,
        self.logical_x,
        self.logical_y,
        self.scale,
        cursor.hotspot_x,
        cursor.hotspot_y,
    );
    const unchanged = self.cursor_source != null and
        std.meta.eql(self.cursor_source.?, source) and std.meta.eql(self.cursor_scale, self.scale);
    if (!unchanged) {
        const index = if (self.cursor_buffer_index) |active| 1 - active else 0;
        if (self.cursor_buffers[index].handle == 0) {
            self.createCursorBuffer(fd, &self.cursor_buffers[index]) catch |err| {
                self.failCursor(err);
                return false;
            };
        }
        rescaleCursor(cursor.buffer, cursor.size, &self.cursor_buffers[index]);
        if (c.drmModeSetCursor(fd, self.crtc_id, self.cursor_buffers[index].handle, self.cursor_width, self.cursor_height) != 0) {
            self.failCursor(error.SetCursorFailed);
            return false;
        }
        self.cursor_buffer_index = index;
        self.cursor_source = source;
        self.cursor_scale = self.scale;
        self.cursor_active = true;
        log.debug(
            "hardware cursor enabled on {s}: source={d}:{d} pixels={d}x{d} image={d}x{d} plane={d}x{d}",
            .{
                self.name(),
                source.id,
                source.version,
                cursor.buffer.size.width,
                cursor.buffer.size.height,
                cursor.size.width,
                cursor.size.height,
                self.cursor_width,
                self.cursor_height,
            },
        );
    }
    if (c.drmModeMoveCursor(fd, self.crtc_id, local.x, local.y) != 0) {
        self.failCursor(error.MoveCursorFailed);
        return false;
    }
    return true;
}

pub fn disableShapeCursor(self: *Self) bool {
    if (!self.cursor_active) return true;
    const fd = self.device_access.fd(self.device_access.context) orelse return false;
    return self.disableCursor(fd);
}

pub fn shapeCursorActive(self: *const Self) bool {
    return self.cursor_active;
}

pub fn acquire(self: *Self) ?render.Target {
    std.debug.assert(self.acquired == null);
    std.debug.assert(self.acquired_damage.isEmpty());
    if (!self.ready()) return null;
    const index = self.availableBuffer().?;
    self.acquired = index;
    if (self.buffers[index].render_target_id) |id| return .{ .dmabuf = .{
        .id = id,
        .size = self.size,
    } };
    const pixel_count = self.size.pixelCount() catch unreachable;
    std.debug.assert(self.shadow_pixels.len == pixel_count);
    return .{ .pixels = .{
        .size = self.size,
        .stride_pixels = self.size.width,
        .pixels = self.shadow_pixels,
    } };
}

pub fn repairDamage(self: *Self, damage: *Region) !void {
    const index = self.acquired orelse unreachable;
    std.debug.assert(self.acquired_damage.isEmpty());
    try self.acquired_damage.copyFrom(damage);
    if (self.buffers[index].render_target_id != null) {
        if (Logging.enabled(.debug)) {
            const full_damage = damage.coversRectangle(0, 0, self.size.width, self.size.height);
            const full_repair = self.buffer_damage[index].coversRectangle(
                0,
                0,
                self.size.width,
                self.size.height,
            );
            if (full_damage) {
                log.debug("new scene damage is full-output before buffer {d} repair", .{index});
            } else if (full_repair) {
                log.debug("buffer {d} repair adds a full-output backlog", .{index});
            }
        }
        try damage.unionWith(&self.buffer_damage[index]);
    }
}

pub fn cancel(self: *Self) void {
    self.acquired = null;
    self.acquired_damage.clear();
    self.discardValidatedOverlay();
}

pub fn present(
    self: *Self,
    _: *const Region,
    render_fence_fd: ?std.posix.fd_t,
    allow_tearing: bool,
) !?presentation.Info {
    std.debug.assert(self.validated_overlay == null);
    const frame = try self.prepareAcquiredFrame(render_fence_fd);
    if (!self.mode_set) {
        var connector_id = self.connector_id;
        if (c.drmModeSetCrtc(
            frame.fd,
            self.crtc_id,
            frame.buffer.framebuffer_id,
            0,
            0,
            &connector_id,
            1,
            &self.mode,
        ) != 0) return error.ModeSetFailed;
        self.mode_set = true;
        if (self.output_color_dirty and !self.commitOutputColorState(frame.fd)) {
            self.rejectOutputColorState();
            self.displayed = frame.index;
            self.acquired = null;
            self.setDirectScanoutActive(false);
            self.color_fallback_pending = false;
            return error.OutputColorFallback;
        }
        self.applyDesiredGamma(frame.fd) catch |err| {
            log.warn("failed to restore gamma ramps on {s}: {t}", .{ self.name(), err });
        };
        self.displayed = frame.index;
        self.acquired = null;
        self.setDirectScanoutActive(false);
        const clock: std.Io.Clock = if (self.presentation_clock_id ==
            presentation.monotonic_clock_id) .awake else .real;
        return .{
            .timestamp = .fromNanoseconds(clock.now(self.io).nanoseconds),
            .refresh_nanoseconds = self.refresh_nanoseconds,
        };
    }

    const page_flip = self.queuePageFlip(
        frame.fd,
        frame.buffer.framebuffer_id,
        self.size,
        null,
        null,
        .commit,
        allow_tearing,
    ) catch |err| switch (err) {
        error.OutputBusy => return err,
        error.AtomicTestFailed, error.OverlaySynchronizationFailed => unreachable,
    } orelse {
        if (self.color_fallback_pending) {
            self.acquired = null;
            self.color_fallback_pending = false;
            return error.OutputColorFallback;
        }
        return error.PageFlipFailed;
    };
    self.pending = frame.index;
    self.pending_page_flip = page_flip;
    self.acquired = null;
    return null;
}

/// Present the previously validated overlay with a primary frame that omits
/// that image. Failure leaves the old display state intact and never commits
/// the incomplete primary buffer by itself.
pub fn presentValidatedOverlay(
    self: *Self,
    _: *const Region,
    render_fence_fd: ?std.posix.fd_t,
    allow_tearing: bool,
) !?presentation.Info {
    const validated = self.validated_overlay orelse return error.NoValidatedOverlay;
    std.debug.assert(self.mode_set);
    const frame = try self.prepareAcquiredFrame(render_fence_fd);
    const page_flip = self.queuePageFlip(
        frame.fd,
        frame.buffer.framebuffer_id,
        self.size,
        null,
        validated.atomic,
        .commit,
        allow_tearing,
    ) catch |err| {
        self.discardFailedValidatedFrame();
        if (err == error.OutputBusy) return err;
        if (self.color_fallback_pending) {
            self.color_fallback_pending = false;
            return error.OutputColorFallback;
        }
        return error.OverlayCommitFailed;
    } orelse {
        self.discardFailedValidatedFrame();
        if (self.color_fallback_pending) {
            self.color_fallback_pending = false;
            return error.OutputColorFallback;
        }
        return error.OverlayCommitFailed;
    };
    self.overlay_pending = validated.scanout;
    self.validated_overlay = null;
    self.pending = frame.index;
    self.pending_page_flip = page_flip;
    self.acquired = null;
    return null;
}

fn prepareAcquiredFrame(
    self: *Self,
    render_fence_fd: ?std.posix.fd_t,
) !AcquiredFrame {
    const index = self.acquired orelse return error.NoAcquiredBuffer;
    const fd = self.device_access.fd(self.device_access.context) orelse return error.SessionInactive;
    if (!self.device_access.active(self.device_access.context)) return error.SessionInactive;
    const buffer = &self.buffers[index];
    if (render_fence_fd) |fence_fd| {
        const gbm_buffer = buffer.gbm orelse return error.InvalidRenderFence;
        if (buffer.render_target_id == null) return error.InvalidRenderFence;
        var imported = false;
        if (self.sync_file_import_supported) {
            imported = importSyncFile(gbm_buffer.fd, fence_fd);
            if (!imported) {
                self.sync_file_import_supported = false;
                log.warn("DMA-BUF sync-file import failed; blocking before DRM commits", .{});
            }
        }
        // Legacy commits don't consistently consume DMA-BUF reservation
        // fences. Initial modesets are rare, so wait for both cases.
        if (!imported or !self.mode_set or self.atomic_plane == null) {
            try waitSyncFile(fence_fd);
        }
    }
    if (buffer.render_target_id == null) {
        try self.buffer_damage[index].unionWith(&self.acquired_damage);
        copyShadowDamage(
            buffer.pixels,
            buffer.stride_pixels,
            self.shadow_pixels,
            self.size,
            &self.buffer_damage[index],
        );
    }
    try finishBufferDamageRepair(
        &self.buffer_damage,
        &self.acquired_damage,
        index,
    );
    return .{
        .fd = fd,
        .index = index,
        .buffer = buffer,
    };
}

fn importSyncFile(dmabuf_fd: std.posix.fd_t, sync_file_fd: std.posix.fd_t) bool {
    var import_sync_file: c.dma_buf_import_sync_file = .{
        .flags = c.DMA_BUF_SYNC_WRITE,
        .fd = sync_file_fd,
    };
    while (true) {
        const result = c.ioctl(
            dmabuf_fd,
            c.DMA_BUF_IOCTL_IMPORT_SYNC_FILE,
            &import_sync_file,
        );
        if (result >= 0) return true;
        switch (std.posix.errno(result)) {
            .INTR, .AGAIN => continue,
            else => return false,
        }
    }
}

fn waitSyncFile(sync_file_fd: std.posix.fd_t) !void {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = sync_file_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if (try std.posix.poll(&poll_fds, -1) == 0 or
        poll_fds[0].revents & std.posix.POLL.IN == 0 or
        poll_fds[0].revents &
            (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0)
    {
        return error.RenderFenceWaitFailed;
    }
}

fn prepareOverlay(
    self: *Self,
    fd: std.posix.fd_t,
    candidate: render.OverlayScanout,
) PreparedOverlayResult {
    const plane = self.overlay_plane orelse return .{ .rejected = .no_overlay_plane };
    if (self.atomic_plane == null) return .{ .rejected = .no_overlay_plane };
    const source = candidate.buffer.dmabuf orelse return .{ .rejected = .non_dmabuf };
    if (!source.force_opaque) return .{ .rejected = .non_opaque_surface };
    if (source.y_inverted) return .{ .rejected = .y_inverted };
    if (candidate.buffer.source_cache == null) {
        return .{ .rejected = .missing_buffer_identity };
    }
    const format = render.DmabufFormat.fromFourcc(source.format) orelse
        return .{ .rejected = .unsupported_format_or_modifier };
    const rgb_representation: render.ColorRepresentation = .{};
    if (source.plane_count != format.planeCount()) {
        return .{ .rejected = .unsupported_layout };
    }
    const color_state: ?AtomicPlaneColorState = if (format.isPackedRgb()) rgb: {
        if (!std.meta.eql(candidate.buffer.color_representation, rgb_representation)) {
            return .{ .rejected = .non_rgb_surface };
        }
        break :rgb null;
    } else video: {
        // KMS has no chroma-location property, so only Keywork's conventional
        // native-video siting can preserve the composed result.
        if (candidate.buffer.color_representation.chroma_location != .type_0) {
            return .{ .rejected = .color_conversion };
        }
        // One plane has one acquire fence. A shared allocation ensures its
        // reservation object covers every image plane.
        if (!dmabufPlanesShareAllocation(source.planeSlice())) {
            return .{ .rejected = .unsupported_layout };
        }
        break :video plane.atomic.color.state(candidate.buffer.color_representation) orelse
            return .{ .rejected = .color_conversion };
    };
    if (!std.meta.eql(candidate.buffer.color_description, self.color_description) or
        self.outputCalibration() != null)
    {
        return .{ .rejected = .color_conversion };
    }
    if (!std.meta.eql(candidate.buffer.size, .{
        .width = candidate.destination.width,
        .height = candidate.destination.height,
    })) return .{ .rejected = .scaled_surface };
    const right = @as(i64, candidate.destination.x) + candidate.destination.width;
    const bottom = @as(i64, candidate.destination.y) + candidate.destination.height;
    if (candidate.destination.x < 0 or candidate.destination.y < 0 or
        candidate.destination.width == 0 or candidate.destination.height == 0 or
        right > self.size.width or bottom > self.size.height)
    {
        return .{ .rejected = .outside_output };
    }
    const framebuffer = self.scanoutFramebuffer(
        fd,
        candidate.buffer,
        plane.formats,
        false,
    ) catch |err| return .{ .rejected = switch (err) {
        error.UnsupportedModifier => .unsupported_format_or_modifier,
        error.InvalidBuffer => .unsupported_layout,
        else => .framebuffer_import_failed,
    } };
    return .{ .prepared = .{
        .atomic = .{
            .source = source,
            .source_size = candidate.buffer.size,
            .destination = candidate.destination,
            .framebuffer_id = framebuffer.framebuffer_id,
            .color = color_state,
        },
        .scanout = .{
            .source = source,
            .framebuffer_key = framebuffer.key,
        },
    } };
}

/// Validate and retain an overlay candidate for the currently acquired frame.
/// A successful candidate must be consumed by `presentValidatedOverlay` or
/// released by `cancel` before another frame is acquired.
pub fn validateOverlayScanout(
    self: *Self,
    candidate: render.OverlayScanout,
) OverlayScanoutResult {
    if (self.validated_overlay != null or self.acquired == null or
        self.pending != null or self.direct_pending != null)
    {
        return .{ .rejected = .output_busy };
    }
    if (!self.mode_set) return .{ .rejected = .output_unavailable };
    const fd = self.device_access.fd(self.device_access.context) orelse
        return .{ .rejected = .device_inactive };
    if (!self.device_access.active(self.device_access.context)) {
        return .{ .rejected = .device_inactive };
    }
    const prepared = switch (self.prepareOverlay(fd, candidate)) {
        .prepared => |prepared| prepared,
        .rejected => |reason| return .{ .rejected = reason },
    };
    const index = self.acquired.?;
    const tested = self.queuePageFlip(
        fd,
        self.buffers[index].framebuffer_id,
        self.size,
        null,
        prepared.atomic,
        .test_only,
        false,
    ) catch |err| {
        const reason: render.OverlayScanoutRejection = switch (err) {
            error.AtomicTestFailed => .atomic_test_failed,
            error.OverlaySynchronizationFailed => .synchronization_failed,
            error.OutputBusy => .output_busy,
        };
        return .{ .rejected = reason };
    };
    if (tested == null) return .{ .rejected = .atomic_test_failed };
    prepared.scanout.source.retain(prepared.scanout.source.context);
    self.validated_overlay = prepared;
    return .accepted;
}

pub fn tryDirectScanout(
    self: *Self,
    buffer: render.PixelBuffer,
    allow_tearing: bool,
) DirectScanoutResult {
    const source = buffer.dmabuf orelse return .{ .rejected = .non_dmabuf };
    if (buffer.source_cache == null) return .{ .rejected = .missing_buffer_identity };
    if (self.output_color_dirty) return .{ .rejected = .color_conversion };
    if (!self.mode_set) return .{ .rejected = .output_unavailable };
    if (self.acquired == null or self.pending != null or self.direct_pending != null) {
        return .{ .rejected = .output_busy };
    }
    if (source.y_inverted) return .{ .rejected = .y_inverted };
    if (render.DmabufFormat.fromFourcc(source.format) == null) {
        return .{ .rejected = .unsupported_format_or_modifier };
    }
    if (self.atomic_plane == null and (!std.meta.eql(buffer.size, self.size) or
        !self.legacyFramebufferLayoutMatches(buffer)))
    {
        return .{ .rejected = .unsupported_layout };
    }
    const fd = self.device_access.fd(self.device_access.context) orelse
        return .{ .rejected = .device_inactive };
    if (!self.device_access.active(self.device_access.context)) {
        return .{ .rejected = .device_inactive };
    }
    if (source.plane_count != 1) return .{ .rejected = .unsupported_layout };
    const framebuffer = self.scanoutFramebuffer(
        fd,
        buffer,
        self.scanout_formats,
        self.implicit_scanout,
    ) catch |err| return .{
        .rejected = if (err == error.UnsupportedModifier)
            .unsupported_format_or_modifier
        else
            .framebuffer_import_failed,
    };

    source.retain(source.context);
    const page_flip = self.queuePageFlip(
        fd,
        framebuffer.framebuffer_id,
        buffer.size,
        source,
        null,
        .commit,
        allow_tearing,
    ) catch |err| {
        source.release(source.context);
        return .{ .rejected = if (err == error.OutputBusy)
            .output_busy
        else
            .page_flip_failed };
    } orelse {
        source.release(source.context);
        return .{ .rejected = .page_flip_failed };
    };
    self.direct_pending = .{
        .source = source,
        .framebuffer_key = framebuffer.key,
    };
    self.pending_page_flip = page_flip;
    self.acquired = null;
    self.acquired_damage.clear();
    self.resetBufferDamage(self.size);
    return .accepted;
}

pub fn activate(self: *Self, fd: std.posix.fd_t, selection: Selection, device_path: []const u8) !void {
    std.debug.assert(selection.modes.len > 0);
    std.debug.assert(selection.mode_index < selection.modes.len);
    const selected_mode = selection.modes[selection.mode_index];
    const selected_size = selected_mode.size();
    const first_activation = self.size.width == 0;
    const atomic = self.device_access.atomic(self.device_access.context);
    const selected_overlay_id = if (atomic)
        optionalOverlayPlaneId(selection.overlay_plane)
    else
        null;
    if (self.size.width != 0 and (!std.meta.eql(self.size, selected_size) or
        self.connector_id != selection.connector_id or
        self.primary_plane_id != selection.primary_plane_id or
        optionalOverlayPlaneId(self.overlay_plane) != selected_overlay_id or
        !modeListsEqual(self.modes, selection.modes)))
    {
        return error.OutputChanged;
    }
    const modes = try self.allocator.dupe(Mode, selection.modes);
    const scanout_formats = self.allocator.dupe(render.DmabufFormatModifier, selection.scanout_formats) catch |err| {
        self.allocator.free(modes);
        return err;
    };
    const overlay_plane = if (atomic)
        if (selection.overlay_plane) |plane| plane.clone(self.allocator) catch |err| {
            self.allocator.free(scanout_formats);
            self.allocator.free(modes);
            return err;
        } else null
    else
        null;
    self.allocator.free(self.modes);
    self.allocator.free(self.scanout_formats);
    if (self.overlay_plane) |plane| plane.deinit(self.allocator);
    self.modes = modes;
    self.scanout_formats = scanout_formats;
    self.overlay_plane = overlay_plane;
    self.implicit_scanout = selection.implicit_scanout;
    self.mode_index = selection.mode_index;
    self.mode = selected_mode.value;
    self.size = selected_size;
    self.physical_size = selection.physical_size;
    if (first_activation) self.scale = defaultScale(selected_size, selection.physical_size);
    self.connector_id = selection.connector_id;
    self.crtc_id = selection.crtc_id;
    self.primary_plane_id = selection.primary_plane_id;
    self.atomic_plane = if (atomic)
        loadAtomicPlaneProperties(fd, self.primary_plane_id orelse 0)
    else
        null;
    self.atomic_color = if (atomic)
        loadAtomicColorProperties(fd, self.connector_id, self.crtc_id)
    else
        null;
    if (atomic and self.atomic_plane == null) {
        log.warn("primary plane lacks required atomic properties; using legacy frame commits", .{});
    }
    if (self.overlay_plane) |plane| {
        log.info(
            "claimed overlay plane {d} for CRTC {d} at zpos {d} with {d} format/modifier pairs",
            .{ plane.id, self.crtc_id, plane.zpos, plane.formats.len },
        );
    }
    self.async_page_flip_supported = supportsAsyncPageFlips(fd, self.atomic_plane != null);
    self.retired = false;
    const connector_type = c.drmModeGetConnectorTypeName(selection.connector_type);
    const type_name = if (connector_type == null) "Unknown" else std.mem.span(connector_type);
    const name_value = try std.fmt.bufPrint(
        &self.connector_name,
        "{s}-{d}",
        .{ type_name, selection.connector_type_id },
    );
    self.connector_name_length = name_value.len;
    _ = self.refreshIdentity(fd);
    const make_value = self.make() orelse "Unknown";
    const model_value = self.model() orelse "display";
    const description_value = if (self.serial()) |serial_text|
        try std.fmt.bufPrint(
            &self.description_value,
            "{s} {s} {s} ({s})",
            .{ make_value, model_value, serial_text, self.name() },
        )
    else
        try std.fmt.bufPrint(
            &self.description_value,
            "{s} {s} ({s})",
            .{ make_value, model_value, self.name() },
        );
    self.description_length = description_value.len;
    self.refresh_nanoseconds = refreshNanoseconds(self.mode);

    var monotonic: u64 = 0;
    if (c.drmGetCap(fd, c.DRM_CAP_TIMESTAMP_MONOTONIC, &monotonic) == 0 and
        monotonic != 0)
    {
        self.presentation_clock_id = presentation.monotonic_clock_id;
    } else {
        self.presentation_clock_id = @intCast(@intFromEnum(std.posix.CLOCK.REALTIME));
    }

    self.old_crtc = c.drmModeGetCrtc(fd, self.crtc_id);
    if (self.old_crtc == null) return error.GetCrtcFailed;
    errdefer {
        c.drmModeFreeCrtc(self.old_crtc.?);
        self.old_crtc = null;
    }
    self.gamma_size = if (self.old_crtc.?.*.gamma_size > 0)
        @intCast(self.old_crtc.?.*.gamma_size)
    else
        0;
    var cursor_width: u64 = 0;
    var cursor_height: u64 = 0;
    if (c.drmGetCap(fd, c.DRM_CAP_CURSOR_WIDTH, &cursor_width) == 0 and
        c.drmGetCap(fd, c.DRM_CAP_CURSOR_HEIGHT, &cursor_height) == 0 and
        cursor_width <= std.math.maxInt(u32) and cursor_height <= std.math.maxInt(u32))
    {
        self.cursor_width = @intCast(cursor_width);
        self.cursor_height = @intCast(cursor_height);
    }
    self.cursor_failed = self.cursor_width == 0 or self.cursor_height == 0;
    const expected_gamma_values = std.math.mul(usize, self.gamma_size, 3) catch 0;
    if (self.gamma_lut.len != 0 and self.gamma_lut.len != expected_gamma_values) {
        self.allocator.free(self.gamma_lut);
        self.gamma_lut = &.{};
    }

    if (!self.powered) {
        if (c.drmModeSetCrtc(fd, self.crtc_id, 0, 0, 0, null, 0, null) != 0) {
            return error.DisableFailed;
        }
    } else if (self.listener != null) {
        // Initial discovery precedes renderer creation so Vulkan can target this DRM device.
        // Its attach allocates the first buffers directly instead of replacing a CPU pair.
        const pair = try self.allocatePair(fd, self.size);
        self.buffers = pair.buffers;
        self.shadow_pixels = pair.shadow_pixels;
        self.resetBufferDamage(self.size);
    }
    self.clearInheritedCursor(fd);
    log.info(
        "activated connector {s} ({d}) on {s} at {d}x{d}, CRTC {d}, enabled={}, powered={}: {s}",
        .{ self.name(), self.connector_id, device_path, self.size.width, self.size.height, self.crtc_id, self.enabled, self.powered, self.description() },
    );
}

fn readIdentity(self: *Self, fd: std.posix.fd_t) void {
    self.clearIdentity();
    self.hdr_failed = false;
    self.rejected_output_color_mode = null;
    const properties = c.drmModeObjectGetProperties(
        fd,
        self.connector_id,
        c.DRM_MODE_OBJECT_CONNECTOR,
    ) orelse return;
    defer c.drmModeFreeObjectProperties(properties);

    const property_count: usize = @intCast(properties.*.count_props);
    for (0..property_count) |index| {
        const property = c.drmModeGetProperty(fd, properties.*.props[index]) orelse continue;
        defer c.drmModeFreeProperty(property);
        const name_value = std.mem.sliceTo(property.*.name[0..], 0);
        if (!std.mem.eql(u8, name_value, "EDID")) continue;
        const blob_id = properties.*.prop_values[index];
        if (blob_id == 0 or blob_id > std.math.maxInt(u32)) return;
        const blob = c.drmModeGetPropertyBlob(fd, @intCast(blob_id)) orelse return;
        defer c.drmModeFreePropertyBlob(blob);
        if (blob.*.data == null or blob.*.length == 0) return;
        const info = c.di_info_parse_edid(blob.*.data, blob.*.length) orelse return;
        defer c.di_info_destroy(info);
        self.make_value = c.di_info_get_make(info);
        self.model_value = c.di_info_get_model(info);
        self.serial_value = c.di_info_get_serial(info);
        self.native_color_description = colorDescriptionFromInfo(info);
        self.refreshSdrColorDescription();
        self.hdr_capabilities = hdrCapabilitiesFromInfo(info);
        self.destroyHdrMetadataBlob(fd);
        self.color_description = if (self.output_color_mode.transfer()) |transfer|
            hdrDescription(self.native_color_description, self.hdr_capabilities, transfer) orelse
                self.sdr_color_description
        else
            self.sdr_color_description;
        if (self.output_color_mode != .sdr) {
            self.output_color_dirty = true;
        }
        return;
    }
}

pub fn refreshIdentity(self: *Self, fd: std.posix.fd_t) bool {
    const previous = self.color_description;
    self.readIdentity(fd);
    return !std.meta.eql(previous, self.color_description);
}

fn clearIdentity(self: *Self) void {
    if (self.make_value != null) c.free(self.make_value);
    if (self.model_value != null) c.free(self.model_value);
    if (self.serial_value != null) c.free(self.serial_value);
    self.make_value = null;
    self.model_value = null;
    self.serial_value = null;
    self.native_color_description = .{};
    self.refreshSdrColorDescription();
    self.color_description = self.sdr_color_description;
    self.hdr_capabilities = .{};
}

fn refreshSdrColorDescription(self: *Self) void {
    self.sdr_color_description = if (self.icc_profile) |profile|
        profile.applyTo(self.native_color_description)
    else
        self.native_color_description;
}

fn hdrDescription(
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

fn hdrCapabilitiesFromInfo(info: *const c.di_info) HdrCapabilities {
    const metadata = c.di_info_get_hdr_static_metadata(info);
    const colorimetry = c.di_info_get_supported_signal_colorimetry(info);
    return hdrCapabilitiesFromValues(.{
        .bt2020_rgb = colorimetry.*.bt2020_rgb,
        .static_metadata_type1 = metadata.*.type1,
        .pq = metadata.*.pq,
        .hlg = metadata.*.hlg,
        .min_luminance = metadata.*.desired_content_min_luminance,
        .max_luminance = metadata.*.desired_content_max_luminance,
        .max_frame_average_luminance = metadata.*.desired_content_max_frame_avg_luminance,
    });
}

const HdrCapabilityValues = struct {
    bt2020_rgb: bool,
    static_metadata_type1: bool,
    pq: bool,
    hlg: bool,
    min_luminance: f32,
    max_luminance: f32,
    max_frame_average_luminance: f32,
};

fn hdrCapabilitiesFromValues(values: HdrCapabilityValues) HdrCapabilities {
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

fn colorDescriptionFromInfo(info: *const c.di_info) render.ColorDescription {
    const primaries = c.di_info_get_default_color_primaries(info);
    var values: ?[8]f32 = null;
    if (primaries.*.has_primaries and primaries.*.has_default_white_point) {
        const colors = primaries.*.primary;
        values = .{
            colors[0].x,
            colors[0].y,
            colors[1].x,
            colors[1].y,
            colors[2].x,
            colors[2].y,
            primaries.*.default_white.x,
            primaries.*.default_white.y,
        };
    }
    return colorDescriptionFromValues(values, c.di_info_get_default_gamma(info));
}

fn colorDescriptionFromValues(
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

pub fn isPrimaryNode(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    if (!std.mem.startsWith(u8, basename, "card") or basename.len == "card".len) return false;
    for (basename["card".len..]) |character| {
        if (!std.ascii.isDigit(character)) return false;
    }
    return true;
}

pub fn deactivate(self: *Self, fd: std.posix.fd_t) void {
    if (self.gamma_lut.len != 0) self.applyIdentityGamma(fd) catch |err| {
        log.warn("failed to restore gamma ramps before releasing {s}: {t}", .{ self.name(), err });
    };
    if (!self.restoreOutputColorState(fd)) {
        log.warn("failed to restore SDR connector state before releasing {s}", .{self.name()});
    }
    if (self.old_crtc) |old_crtc| restoreCrtc(fd, self.connector_id, old_crtc);
    self.release(fd);
}

pub fn disconnect(self: *Self, fd: std.posix.fd_t) void {
    if (self.powered and
        c.drmModeSetCrtc(fd, self.crtc_id, 0, 0, 0, null, 0, null) != 0)
    {
        log.warn("failed to disable disconnected CRTC {d}", .{self.crtc_id});
    }
    self.release(fd);
}

fn release(self: *Self, fd: std.posix.fd_t) void {
    _ = self.disableCursor(fd);
    for (&self.cursor_buffers) |*buffer| self.destroyBuffer(fd, buffer);
    const restore_color_state = self.output_color_mode != .sdr or self.output_color_dirty;
    self.destroyHdrMetadataBlob(fd);
    self.output_color_mode = .sdr;
    self.output_color_dirty = restore_color_state;
    self.rejected_output_color_mode = null;
    self.hdr_failed = false;
    self.color_fallback_pending = false;
    self.color_description = self.sdr_color_description;
    self.mode_set = false;
    self.atomic_plane = null;
    self.atomic_color = null;
    self.async_page_flip_supported = false;
    self.acquired = null;
    self.acquired_damage.clear();
    self.pending = null;
    self.displayed = null;
    if (!self.retired) self.pending_page_flip = null;
    self.releaseClientScanouts();
    self.destroyScanoutFramebuffers(fd);
    self.destroyPair(fd, &self.buffers, self.shadow_pixels);
    self.shadow_pixels = &.{};
    for (&self.buffer_damage) |*damage| damage.clear();
    if (self.old_crtc) |old_crtc| {
        c.drmModeFreeCrtc(old_crtc);
        self.old_crtc = null;
    }
}

pub fn setEnabled(self: *Self, fd: std.posix.fd_t, enabled: bool) !void {
    if (self.enabled == enabled) return;
    std.debug.assert(self.old_crtc != null);
    if (enabled) {
        self.enabled = true;
        errdefer self.enabled = false;
        try self.setPowered(fd, true);
        return;
    }

    if (self.powered) try self.setPowered(fd, false);
    self.enabled = false;
}

pub fn setPowered(self: *Self, fd: std.posix.fd_t, powered: bool) !void {
    if (!self.enabled) return error.OutputDisabled;
    if (self.powered == powered) return;
    std.debug.assert(self.old_crtc != null);
    if (powered) {
        const pair = try self.allocatePair(fd, self.size);
        self.buffers = pair.buffers;
        self.shadow_pixels = pair.shadow_pixels;
        self.resetBufferDamage(self.size);
        self.powered = true;
        self.mode_set = false;
        self.cursor_failed = self.cursor_width == 0 or self.cursor_height == 0;
        return;
    }

    // Destroying a framebuffer queued for a page flip is not safe. Output
    // configuration is infrequent, so reject a busy head and let the client
    // retry rather than complicating the page-flip lifetime.
    if (self.pending != null or self.direct_pending != null) return error.OutputBusy;
    _ = self.disableCursor(fd);
    self.acquired = null;
    self.acquired_damage.clear();
    if (c.drmModeSetCrtc(fd, self.crtc_id, 0, 0, 0, null, 0, null) != 0) {
        return error.DisableFailed;
    }
    self.cursor_active = false;
    self.cursor_source = null;
    self.cursor_buffer_index = null;
    for (&self.cursor_buffers) |*buffer| self.destroyBuffer(fd, buffer);
    self.powered = false;
    self.mode_set = false;
    self.displayed = null;
    self.releaseClientScanouts();
    self.destroyScanoutFramebuffers(fd);
    self.notifyDeactivated();
    self.destroyPair(fd, &self.buffers, self.shadow_pixels);
    self.shadow_pixels = &.{};
    for (&self.buffer_damage) |*damage| damage.clear();
}

pub fn setMode(self: *Self, fd: std.posix.fd_t, mode_index: usize) !void {
    if (mode_index >= self.modes.len) return error.InvalidMode;
    if (mode_index == self.mode_index) return;
    if (self.pending != null or self.direct_pending != null) return error.OutputBusy;
    const mode = self.modes[mode_index];
    const size = mode.size();

    if (self.powered) {
        _ = self.disableCursor(fd);
        const pair = try self.allocatePair(fd, size);
        self.acquired = null;
        self.acquired_damage.clear();
        if (c.drmModeSetCrtc(fd, self.crtc_id, 0, 0, 0, null, 0, null) != 0) {
            var failed_buffers = pair.buffers;
            self.destroyPair(fd, &failed_buffers, pair.shadow_pixels);
            return error.DisableFailed;
        }
        self.cursor_active = false;
        self.cursor_source = null;
        self.cursor_buffer_index = null;
        for (&self.cursor_buffers) |*buffer| self.destroyBuffer(fd, buffer);
        self.notifyDeactivated();
        var old_buffers = self.buffers;
        const old_shadow_pixels = self.shadow_pixels;
        self.buffers = pair.buffers;
        self.shadow_pixels = pair.shadow_pixels;
        self.resetBufferDamage(size);
        self.destroyPair(fd, &old_buffers, old_shadow_pixels);
        self.displayed = null;
        self.releaseClientScanouts();
        self.destroyScanoutFramebuffers(fd);
        self.mode_set = false;
    }

    self.mode_index = mode_index;
    self.mode = mode.value;
    self.size = size;
    self.refresh_nanoseconds = refreshNanoseconds(self.mode);
}

pub fn gammaSize(self: *const Self) ?u32 {
    if (self.old_crtc == null or self.gamma_size == 0) return null;
    return self.gamma_size;
}

pub fn setGamma(self: *Self, table: []const u16) !void {
    const gamma_size = self.gammaSize() orelse return error.GammaUnsupported;
    const expected_values = std.math.mul(usize, gamma_size, 3) catch
        return error.InvalidGammaSize;
    if (table.len != expected_values) return error.InvalidGammaSize;

    const replacement = try self.allocator.dupe(u16, table);
    errdefer self.allocator.free(replacement);
    if (self.powered) {
        const fd = self.device_access.fd(self.device_access.context) orelse
            return error.SessionInactive;
        if (!self.device_access.active(self.device_access.context)) {
            return error.SessionInactive;
        }
        try self.applyGamma(fd, replacement);
    }
    self.allocator.free(self.gamma_lut);
    self.gamma_lut = replacement;
}

pub fn resetGamma(self: *Self) void {
    if (self.gamma_lut.len == 0) return;
    if (self.powered and self.device_access.active(self.device_access.context)) {
        if (self.device_access.fd(self.device_access.context)) |fd| {
            self.applyIdentityGamma(fd) catch |err| {
                log.warn("failed to reset gamma ramps on {s}: {t}", .{ self.name(), err });
            };
        }
    }
    self.allocator.free(self.gamma_lut);
    self.gamma_lut = &.{};
}

fn applyDesiredGamma(self: *Self, fd: std.posix.fd_t) !void {
    if (self.gamma_lut.len == 0) return;
    try self.applyGamma(fd, self.gamma_lut);
}

fn applyGamma(self: *const Self, fd: std.posix.fd_t, table: []const u16) !void {
    const gamma_size: usize = self.gamma_size;
    std.debug.assert(gamma_size != 0 and table.len == gamma_size * 3);
    if (c.drmModeCrtcSetGamma(
        fd,
        self.crtc_id,
        self.gamma_size,
        @constCast(table[0..gamma_size].ptr),
        @constCast(table[gamma_size .. gamma_size * 2].ptr),
        @constCast(table[gamma_size * 2 ..].ptr),
    ) != 0) return error.SetGammaFailed;
}

fn applyIdentityGamma(self: *const Self, fd: std.posix.fd_t) !void {
    if (self.gamma_size == 0) return;
    const ramp = try self.allocator.alloc(u16, self.gamma_size);
    defer self.allocator.free(ramp);
    fillIdentityGammaRamp(ramp);
    if (c.drmModeCrtcSetGamma(
        fd,
        self.crtc_id,
        self.gamma_size,
        ramp.ptr,
        ramp.ptr,
        ramp.ptr,
    ) != 0) return error.SetGammaFailed;
}

fn fillIdentityGammaRamp(ramp: []u16) void {
    if (ramp.len == 0) return;
    if (ramp.len == 1) {
        ramp[0] = std.math.maxInt(u16);
        return;
    }
    const denominator = ramp.len - 1;
    for (ramp, 0..) |*value, index| {
        value.* = @intCast(index * std.math.maxInt(u16) / denominator);
    }
}

fn availableBuffer(self: *const Self) ?usize {
    for (0..buffer_count) |index| {
        if (self.displayed == index or self.pending == index) continue;
        return index;
    }
    return null;
}

pub fn notifyReady(self: *Self) void {
    if (self.listener) |listener| listener.ready(listener.context);
}

pub fn notifyDeactivated(self: *Self) void {
    log.info("deactivating {s}", .{self.name()});
    if (self.listener) |listener| listener.discarded(listener.context);
}

pub fn retire(self: *Self) void {
    std.debug.assert(!self.retired);
    self.retired = true;
    self.pending = null;
}

/// True when no queued DRM callback can still reference this retired output.
pub fn retirementComplete(self: *const Self) bool {
    std.debug.assert(self.retired);
    return self.pending_page_flip == null;
}

pub fn dispatchEvents(fd: std.posix.fd_t) !void {
    var context = event_context;
    if (c.drmHandleEvent(fd, &context) != 0) return error.EventDispatchFailed;
}

fn handlePageFlip(
    _: c_int,
    sequence: c_uint,
    seconds: c_uint,
    microseconds: c_uint,
    data: ?*anyopaque,
) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data.?));
    if (self.retired) {
        std.debug.assert(self.pending_page_flip != null);
        self.pending_page_flip = null;
        return;
    }
    if (self.pending == null and self.direct_pending == null) {
        self.device_access.fail(self.device_access.context, error.UnexpectedPageFlip);
        return;
    }
    const page_flip = self.pending_page_flip orelse {
        self.device_access.fail(self.device_access.context, error.UnexpectedPageFlip);
        return;
    };
    self.pending_page_flip = null;
    const zero_copy = self.direct_pending != null;
    if (self.direct_pending) |direct| {
        if (self.direct_displayed) |displayed| displayed.release();
        self.direct_displayed = direct;
        self.direct_pending = null;
        self.displayed = null;
        self.setDirectScanoutActive(true);
    } else {
        if (self.direct_displayed) |displayed| displayed.release();
        self.direct_displayed = null;
        self.displayed = self.pending.?;
        self.pending = null;
        self.setDirectScanoutActive(false);
    }
    if (self.overlay_displayed) |displayed| displayed.release();
    self.overlay_displayed = self.overlay_pending;
    self.overlay_pending = null;
    const listener = self.listener orelse return;
    listener.presented(listener.context, .{
        .timestamp = .{
            .seconds = seconds,
            .nanoseconds = microseconds * std.time.ns_per_us,
        },
        .refresh_nanoseconds = self.refresh_nanoseconds,
        .sequence = sequence,
        .flags = .{
            .vsync = page_flip == .vsync,
            .hardware_clock = true,
            .hardware_completion = true,
            .zero_copy = zero_copy,
        },
    });
    listener.ready(listener.context);
}

/// Discovers connected outputs and returns allocator-owned selections. The
/// caller must release the result with `deinitSelections` using the same
/// allocator.
pub fn selectOutputs(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    existing_outputs: []const *Self,
) ![]Selection {
    const resources = c.drmModeGetResources(fd) orelse return error.GetResourcesFailed;
    defer c.drmModeFreeResources(resources);
    if (resources.*.count_crtcs <= 0) return error.NoCrtc;
    var selections: std.ArrayList(Selection) = .empty;
    errdefer {
        for (selections.items) |selection| {
            allocator.free(selection.modes);
            allocator.free(selection.scanout_formats);
            if (selection.overlay_plane) |plane| plane.deinit(allocator);
        }
        selections.deinit(allocator);
    }
    var claimed: u32 = 0;
    var claimed_primary_planes: std.ArrayList(u32) = .empty;
    defer claimed_primary_planes.deinit(allocator);
    var reserved_primary_planes: std.ArrayList(u32) = .empty;
    defer reserved_primary_planes.deinit(allocator);
    var claimed_overlay_planes: std.ArrayList(u32) = .empty;
    defer claimed_overlay_planes.deinit(allocator);
    var reserved_overlay_planes: std.ArrayList(u32) = .empty;
    defer reserved_overlay_planes.deinit(allocator);

    // Reserve working routes before assigning CRTCs to newly connected heads.
    // Otherwise connector enumeration order can steal an active output's CRTC.
    for (existing_outputs) |output| {
        const connector = c.drmModeGetConnector(fd, output.connector_id) orelse continue;
        defer c.drmModeFreeConnector(connector);
        if (connector.*.connection != c.DRM_MODE_CONNECTED or connector.*.count_modes <= 0) {
            continue;
        }
        const possible_crtcs = c.drmModeConnectorGetPossibleCrtcs(fd, connector);
        const index = crtcIndex(resources, output.crtc_id) orelse continue;
        if (crtcIndexPossible(possible_crtcs, index)) {
            claimed |= @as(u32, 1) << @intCast(index);
            if (output.primary_plane_id) |plane_id| {
                if (std.mem.indexOfScalar(u32, reserved_primary_planes.items, plane_id) == null) {
                    try reserved_primary_planes.append(allocator, plane_id);
                }
            }
            if (output.overlay_plane) |plane| {
                if (std.mem.indexOfScalar(u32, reserved_overlay_planes.items, plane.id) == null) {
                    try reserved_overlay_planes.append(allocator, plane.id);
                }
            }
        }
    }

    const connector_count: usize = @intCast(@max(resources.*.count_connectors, 0));
    for (0..connector_count) |connector_index| {
        const connector = c.drmModeGetConnector(
            fd,
            resources.*.connectors[connector_index],
        ) orelse continue;
        defer c.drmModeFreeConnector(connector);
        if (connector.*.connection != c.DRM_MODE_CONNECTED or
            connector.*.count_modes <= 0) continue;

        const possible_crtcs = c.drmModeConnectorGetPossibleCrtcs(fd, connector);
        const existing_output = findOutput(existing_outputs, connector.*.connector_id);
        var preferred_crtc: ?u32 = null;
        if (connector.*.encoder_id != 0) {
            const encoder = c.drmModeGetEncoder(fd, connector.*.encoder_id);
            if (encoder) |value| {
                defer c.drmModeFreeEncoder(value);
                preferred_crtc = value.*.crtc_id;
            }
        }
        const existing_crtc_index = if (existing_output) |output| existing: {
            const index = crtcIndex(resources, output.crtc_id) orelse break :existing null;
            break :existing if (crtcIndexPossible(possible_crtcs, index)) index else null;
        } else null;
        const crtc_index = existing_crtc_index orelse selectCrtcIndex(
            resources,
            possible_crtcs,
            preferred_crtc,
            claimed,
        ) orelse {
            log.warn("skipping connector {d}: no unclaimed compatible CRTC", .{connector.*.connector_id});
            continue;
        };
        claimed |= @as(u32, 1) << @intCast(crtc_index);
        const crtc_id = resources.*.crtcs[crtc_index];
        const primary_plane = try primaryPlane(
            fd,
            crtc_id,
            crtc_index,
            if (existing_output) |output| output.primary_plane_id else null,
            claimed_primary_planes.items,
            reserved_primary_planes.items,
            allocator,
        );
        if (primary_plane.id) |plane_id| {
            claimed_primary_planes.append(allocator, plane_id) catch |err| {
                allocator.free(primary_plane.formats);
                return err;
            };
        }
        const overlay_plane = overlayPlane(
            fd,
            crtc_id,
            crtc_index,
            if (existing_output) |output| optionalOverlayPlaneId(output.overlay_plane) else null,
            claimed_overlay_planes.items,
            reserved_overlay_planes.items,
            primary_plane.zpos,
            allocator,
        ) catch |err| {
            allocator.free(primary_plane.formats);
            return err;
        };
        if (overlay_plane) |plane| {
            claimed_overlay_planes.append(allocator, plane.id) catch |err| {
                allocator.free(primary_plane.formats);
                plane.deinit(allocator);
                return err;
            };
        }
        const mode_count: usize = @intCast(connector.*.count_modes);
        const connector_modes = connector.*.modes[0..mode_count];
        const modes = allocator.alloc(Mode, mode_count) catch |err| {
            allocator.free(primary_plane.formats);
            if (overlay_plane) |plane| plane.deinit(allocator);
            return err;
        };
        for (connector_modes, modes) |mode, *stored| stored.* = .{
            .value = mode,
            .preferred = mode.type & c.DRM_MODE_TYPE_PREFERRED != 0,
        };
        const mode_index = if (existing_output) |output|
            findModeIndex(modes, output.mode) orelse preferredModeIndex(connector_modes)
        else
            preferredModeIndex(connector_modes);
        selections.append(allocator, .{
            .modes = modes,
            .mode_index = mode_index,
            .physical_size = .{
                .width = @max(connector.*.mmWidth, 1),
                .height = @max(connector.*.mmHeight, 1),
            },
            .connector_id = connector.*.connector_id,
            .connector_type = connector.*.connector_type,
            .connector_type_id = connector.*.connector_type_id,
            .crtc_id = crtc_id,
            .primary_plane_id = primary_plane.id,
            .overlay_plane = overlay_plane,
            .scanout_formats = primary_plane.formats,
            .implicit_scanout = primary_plane.implicit,
        }) catch |err| {
            allocator.free(modes);
            allocator.free(primary_plane.formats);
            if (overlay_plane) |plane| plane.deinit(allocator);
            return err;
        };
    }
    return selections.toOwnedSlice(allocator);
}

/// Releases selections returned by `selectOutputs`.
pub fn deinitSelections(allocator: std.mem.Allocator, selections: []Selection) void {
    for (selections) |selection| {
        allocator.free(selection.modes);
        allocator.free(selection.scanout_formats);
        if (selection.overlay_plane) |plane| plane.deinit(allocator);
    }
    allocator.free(selections);
}

fn primaryPlane(
    fd: std.posix.fd_t,
    crtc_id: u32,
    crtc_index: usize,
    preferred_plane_id: ?u32,
    claimed_planes: []const u32,
    reserved_planes: []const u32,
    allocator: std.mem.Allocator,
) !PrimaryPlane {
    const resources = c.drmModeGetPlaneResources(fd) orelse return .{};
    defer c.drmModeFreePlaneResources(resources);
    var selected: PrimaryPlane = .{};
    errdefer allocator.free(selected.formats);
    var selected_score: u8 = 0;
    const plane_count: usize = @intCast(resources.*.count_planes);
    for (resources.*.planes[0..plane_count]) |plane_id| {
        const plane = c.drmModeGetPlane(fd, plane_id) orelse continue;
        defer c.drmModeFreePlane(plane);
        if (!crtcIndexPossible(plane.*.possible_crtcs, crtc_index) or
            std.mem.indexOfScalar(u32, claimed_planes, plane_id) != null or
            (preferred_plane_id != plane_id and
                std.mem.indexOfScalar(u32, reserved_planes, plane_id) != null)) continue;

        const info = planeSelectionInfo(fd, plane_id) orelse continue;
        if (info.plane_type != c.DRM_PLANE_TYPE_PRIMARY) continue;
        const score: u8 = if (preferred_plane_id == plane_id and
            (plane.*.crtc_id == 0 or plane.*.crtc_id == crtc_id))
            3
        else if (plane.*.crtc_id == crtc_id)
            2
        else if (plane.*.crtc_id == 0)
            1
        else
            0;
        if (score <= selected_score) continue;

        var implicit = false;
        const format_count: usize = @intCast(plane.*.count_formats);
        for (plane.*.formats[0..format_count]) |format| {
            if (format == c.DRM_FORMAT_XRGB8888) {
                implicit = true;
                break;
            }
        }
        const owned_formats = try planeFormats(fd, plane, info.formats_blob_id, allocator);
        allocator.free(selected.formats);
        selected = .{
            .id = plane_id,
            .formats = owned_formats,
            .implicit = implicit,
            .zpos = if (info.zpos) |zpos| zpos.current else null,
        };
        selected_score = score;
        if (score == 3) break;
    }
    return selected;
}

fn optionalOverlayPlaneId(plane: ?OverlayPlane) ?u32 {
    return if (plane) |value| value.id else null;
}

fn planeSelectionInfo(fd: std.posix.fd_t, plane_id: u32) ?PlaneSelectionInfo {
    const properties = c.drmModeObjectGetProperties(
        fd,
        plane_id,
        c.DRM_MODE_OBJECT_PLANE,
    ) orelse return null;
    defer c.drmModeFreeObjectProperties(properties);

    var result: PlaneSelectionInfo = .{};
    const property_count: usize = @intCast(properties.*.count_props);
    for (0..property_count) |property_index| {
        const property_id = properties.*.props[property_index];
        const property = c.drmModeGetProperty(fd, property_id) orelse continue;
        defer c.drmModeFreeProperty(property);
        const property_name = std.mem.sliceTo(property.*.name[0..], 0);
        const value = properties.*.prop_values[property_index];
        if (std.mem.eql(u8, property_name, "type")) {
            result.plane_type = value;
        } else if (std.mem.eql(u8, property_name, "IN_FORMATS") and
            value > 0 and value <= std.math.maxInt(u32))
        {
            result.formats_blob_id = @intCast(value);
        } else if (std.mem.eql(u8, property_name, "zpos")) {
            const immutable = property.*.flags & c.DRM_MODE_PROP_IMMUTABLE != 0;
            const maximum = if (!immutable and property.*.count_values >= 2)
                @max(value, property.*.values[1])
            else
                value;
            result.zpos = .{
                .property_id = property_id,
                .current = value,
                .maximum = maximum,
                .immutable = immutable,
            };
        }
    }
    return result;
}

fn overlayPlane(
    fd: std.posix.fd_t,
    crtc_id: u32,
    crtc_index: usize,
    preferred_plane_id: ?u32,
    claimed_planes: []const u32,
    reserved_planes: []const u32,
    primary_zpos: ?u64,
    allocator: std.mem.Allocator,
) !?OverlayPlane {
    const required_primary_zpos = primary_zpos orelse return null;
    const resources = c.drmModeGetPlaneResources(fd) orelse return null;
    defer c.drmModeFreePlaneResources(resources);
    var selected: ?OverlayPlane = null;
    errdefer if (selected) |plane| plane.deinit(allocator);
    var selected_rank: ?plane_assignment.Rank = null;
    const plane_count: usize = @intCast(resources.*.count_planes);
    for (resources.*.planes[0..plane_count]) |plane_id| {
        const plane = c.drmModeGetPlane(fd, plane_id) orelse continue;
        defer c.drmModeFreePlane(plane);
        if (!crtcIndexPossible(plane.*.possible_crtcs, crtc_index) or
            std.mem.indexOfScalar(u32, claimed_planes, plane_id) != null or
            (preferred_plane_id != plane_id and
                std.mem.indexOfScalar(u32, reserved_planes, plane_id) != null)) continue;

        const rank = plane_assignment.rank(
            plane_id,
            plane.*.crtc_id,
            plane.*.possible_crtcs,
            crtc_id,
            preferred_plane_id,
        );
        if (rank.attachment == 0 or
            (selected_rank != null and !rank.betterThan(selected_rank.?))) continue;
        const info = planeSelectionInfo(fd, plane_id) orelse continue;
        if (info.plane_type != c.DRM_PLANE_TYPE_OVERLAY or info.formats_blob_id == null) continue;
        const zpos = info.zpos orelse continue;
        const selected_zpos = plane_assignment.overlayZpos(zpos, required_primary_zpos) orelse continue;
        const atomic = loadAtomicPlaneProperties(fd, plane_id) orelse continue;
        const formats = try planeFormats(fd, plane, info.formats_blob_id, allocator);
        if (formats.len == 0) {
            allocator.free(formats);
            continue;
        }
        if (selected) |old| old.deinit(allocator);
        selected = .{
            .id = plane_id,
            .formats = formats,
            .atomic = atomic,
            .zpos_property = selected_zpos.property_id,
            .zpos = selected_zpos.value,
        };
        selected_rank = rank;
    }
    return selected;
}

fn planeFormats(
    fd: std.posix.fd_t,
    plane: *c.drmModePlane,
    formats_blob_id: ?u32,
    allocator: std.mem.Allocator,
) ![]render.DmabufFormatModifier {
    var formats: std.ArrayList(render.DmabufFormatModifier) = .empty;
    defer formats.deinit(allocator);
    if (formats_blob_id) |blob_id| if (c.drmModeGetPropertyBlob(fd, blob_id)) |blob| {
        defer c.drmModeFreePropertyBlob(blob);
        var iterator = std.mem.zeroes(c.drmModeFormatModifierIterator);
        while (c.drmModeFormatModifierBlobIterNext(blob, &iterator)) {
            if (render.DmabufFormat.fromFourcc(iterator.fmt) == null or
                render.DmabufFormatModifier.contains(formats.items, iterator.fmt, iterator.mod)) continue;
            try formats.append(allocator, .{ .format = iterator.fmt, .modifier = iterator.mod });
        }
    };
    if (formats_blob_id == null) {
        const format_count: usize = @intCast(plane.*.count_formats);
        for (plane.*.formats[0..format_count]) |format| if (render.DmabufFormat.fromFourcc(format) != null and
            !render.DmabufFormatModifier.contains(formats.items, format, drm_format_mod_linear))
            try formats.append(allocator, .{ .format = format, .modifier = drm_format_mod_linear });
    }
    for ([_]render.DmabufFormat{ .argb8888, .abgr8888 }) |alpha| {
        const opaque_format = alpha.opaqueFormat();
        const initial_len = formats.items.len;
        var format_index: usize = 0;
        while (format_index < initial_len) : (format_index += 1) {
            const pair = formats.items[format_index];
            if (pair.format == @intFromEnum(opaque_format) and
                !render.DmabufFormatModifier.contains(formats.items, @intFromEnum(alpha), pair.modifier))
            {
                try formats.append(allocator, .{
                    .format = @intFromEnum(alpha),
                    .modifier = pair.modifier,
                });
            }
        }
    }
    return formats.toOwnedSlice(allocator);
}

fn scanoutFramebufferFormat(
    formats: []const render.DmabufFormatModifier,
    source_format: u32,
    modifier: u64,
) ?u32 {
    const format = render.DmabufFormat.fromFourcc(source_format) orelse return null;
    const opaque_format = @intFromEnum(format.opaqueFormat());
    if (render.DmabufFormatModifier.contains(formats, opaque_format, modifier)) {
        return opaque_format;
    }
    if (render.DmabufFormatModifier.contains(formats, source_format, modifier)) {
        return source_format;
    }
    return null;
}

test "scanout framebuffer prefers an opaque format with the same memory layout" {
    const formats = [_]render.DmabufFormatModifier{
        .{ .format = c.DRM_FORMAT_ARGB8888, .modifier = 7 },
        .{ .format = c.DRM_FORMAT_XRGB8888, .modifier = 7 },
        .{ .format = c.DRM_FORMAT_ABGR8888, .modifier = 9 },
    };
    try std.testing.expectEqual(
        c.DRM_FORMAT_XRGB8888,
        scanoutFramebufferFormat(&formats, c.DRM_FORMAT_ARGB8888, 7).?,
    );
    try std.testing.expectEqual(
        c.DRM_FORMAT_ABGR8888,
        scanoutFramebufferFormat(&formats, c.DRM_FORMAT_ABGR8888, 9).?,
    );
    try std.testing.expect(scanoutFramebufferFormat(&formats, c.DRM_FORMAT_XBGR8888, 9) == null);
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
    try std.testing.expectEqual(render.TransferFunction{ .power = 24000 }, color_description.transfer_function);

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
    const metadata = hdrOutputMetadata(.pq, output_description);
    const info = metadata.unnamed_0.hdmi_metadata_type1;
    try std.testing.expectEqual(@as(u8, 2), info.eotf);
    try std.testing.expectEqual(@as(u16, 32000), info.display_primaries[0].x);
    try std.testing.expectEqual(@as(u16, 16450), info.white_point.y);
    try std.testing.expectEqual(@as(u16, 1000), info.max_display_mastering_luminance);
    try std.testing.expectEqual(@as(u16, 50), info.min_display_mastering_luminance);
    try std.testing.expectEqual(@as(u16, 400), info.max_fall);
}

fn findOutput(outputs: []const *Self, connector_id: u32) ?*Self {
    for (outputs) |output| if (output.connector_id == connector_id) return output;
    return null;
}

fn crtcIndex(resources: *c.drmModeRes, crtc_id: u32) ?usize {
    const count: usize = @intCast(@max(resources.*.count_crtcs, 0));
    for (0..count) |index| if (resources.*.crtcs[index] == crtc_id) return index;
    return null;
}

fn selectCrtcIndex(
    resources: *c.drmModeRes,
    possible_crtcs: u32,
    preferred_crtc: ?u32,
    claimed: u32,
) ?usize {
    const crtc_count: usize = @intCast(@max(resources.*.count_crtcs, 0));
    if (preferred_crtc) |preferred| for (0..crtc_count) |index| {
        if (resources.*.crtcs[index] == preferred and crtcIndexPossible(possible_crtcs, index) and
            claimed & (@as(u32, 1) << @intCast(index)) == 0) return index;
    };
    for (0..crtc_count) |crtc_index| {
        if (!crtcIndexPossible(possible_crtcs, crtc_index)) continue;
        if (claimed & (@as(u32, 1) << @intCast(crtc_index)) == 0) return crtc_index;
    }
    return null;
}

fn crtcIndexPossible(possible_crtcs: u32, index: usize) bool {
    return index < @bitSizeOf(u32) and
        possible_crtcs & (@as(u32, 1) << @intCast(index)) != 0;
}

fn preferredModeIndex(modes: []const c.drmModeModeInfo) usize {
    std.debug.assert(modes.len > 0);
    for (modes, 0..) |mode, index| {
        if (mode.type & c.DRM_MODE_TYPE_PREFERRED != 0) return index;
    }
    return 0;
}

fn findModeIndex(modes: []const Mode, target: c.drmModeModeInfo) ?usize {
    for (modes, 0..) |mode, index| {
        if (std.meta.eql(mode.value, target)) return index;
    }
    return null;
}

fn modeListsEqual(a: []const Mode, b: []const Mode) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_mode, b_mode| {
        if (!std.meta.eql(a_mode, b_mode)) return false;
    }
    return true;
}

fn defaultScale(pixel_size: render.Size, physical_size: render.Size) render.Scale {
    const pixels_x: f64 = @floatFromInt(pixel_size.width);
    const pixels_y: f64 = @floatFromInt(pixel_size.height);
    const millimeters_x: f64 = @floatFromInt(physical_size.width);
    const millimeters_y: f64 = @floatFromInt(physical_size.height);
    const dpi_x = pixels_x * 25.4 / millimeters_x;
    const dpi_y = pixels_y * 25.4 / millimeters_y;
    if (!std.math.isFinite(dpi_x) or !std.math.isFinite(dpi_y) or
        dpi_x < minimum_plausible_dpi or dpi_x > maximum_plausible_dpi or
        dpi_y < minimum_plausible_dpi or dpi_y > maximum_plausible_dpi or
        @max(dpi_x, dpi_y) / @min(dpi_x, dpi_y) > maximum_axis_dpi_ratio)
    {
        return .{};
    }

    const diagonal_pixels = std.math.sqrt(pixels_x * pixels_x + pixels_y * pixels_y);
    const diagonal_inches = std.math.sqrt(
        millimeters_x * millimeters_x + millimeters_y * millimeters_y,
    ) / 25.4;
    const scale = diagonal_pixels / diagonal_inches / default_target_dpi;
    const quantized = @round(scale * render.Scale.denominator / default_scale_step) *
        default_scale_step;
    return .{ .numerator = @intFromFloat(std.math.clamp(
        quantized,
        render.Scale.denominator,
        maximum_default_scale,
    )) };
}

fn refreshNanoseconds(mode: c.drmModeModeInfo) u32 {
    if (mode.vrefresh == 0) return presentation.nominal_refresh_nanoseconds;
    return @intCast(std.time.ns_per_s / mode.vrefresh);
}

noinline fn resetBufferDamage(self: *Self, size: render.Size) void {
    log.debug("resetting full buffer damage from 0x{x}", .{@returnAddress()});
    for (&self.buffer_damage) |*damage| {
        damage.setRectangle(0, 0, size.width, size.height);
    }
}

fn finishBufferDamageRepair(
    buffer_damage: *[buffer_count]Region,
    acquired_damage: *Region,
    acquired_index: usize,
) Region.Error!void {
    std.debug.assert(acquired_index < buffer_damage.len);
    for (buffer_damage, 0..) |*damage, index| {
        if (index != acquired_index) try damage.unionWith(acquired_damage);
    }
    buffer_damage[acquired_index].clear();
    acquired_damage.clear();
}

fn createShadowBuffer(
    allocator: std.mem.Allocator,
    size: render.Size,
    pixels: *[]u32,
) !void {
    std.debug.assert(pixels.*.len == 0);
    pixels.* = try allocator.alloc(u32, try size.pixelCount());
    @memset(pixels.*, 0);
}

fn destroyShadowBuffer(allocator: std.mem.Allocator, pixels: *[]u32) void {
    allocator.free(pixels.*);
    pixels.* = &.{};
}

fn copyShadowDamage(
    destination: []u32,
    destination_stride: u32,
    source: []const u32,
    size: render.Size,
    damage: *const Region,
) void {
    std.debug.assert(destination_stride >= size.width);
    const source_count = size.pixelCount() catch unreachable;
    std.debug.assert(source.len >= source_count);
    const destination_count = std.math.add(
        usize,
        std.math.mul(usize, size.height - 1, destination_stride) catch unreachable,
        size.width,
    ) catch unreachable;
    std.debug.assert(destination.len >= destination_count);

    var rectangles = damage.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        std.debug.assert(rectangle.x >= 0 and rectangle.y >= 0);
        const x: u32 = @intCast(rectangle.x);
        const y: u32 = @intCast(rectangle.y);
        std.debug.assert(x + rectangle.width <= size.width);
        std.debug.assert(y + rectangle.height <= size.height);
        for (0..rectangle.height) |row| {
            const source_offset = (@as(usize, y) + row) * size.width + x;
            const destination_offset = (@as(usize, y) + row) * destination_stride + x;
            @memcpy(
                destination[destination_offset..][0..rectangle.width],
                source[source_offset..][0..rectangle.width],
            );
        }
    }
}

fn scanoutFramebuffer(
    self: *Self,
    fd: std.posix.fd_t,
    buffer: render.PixelBuffer,
    formats: []const render.DmabufFormatModifier,
    implicit_scanout: bool,
) !struct { key: ScanoutFramebufferKey, framebuffer_id: u32 } {
    const source = buffer.dmabuf orelse return error.InvalidBuffer;
    if (source.plane_count == 0 or source.plane_count > render.max_dmabuf_planes) {
        return error.InvalidBuffer;
    }
    const framebuffer_format = scanoutFramebufferFormat(
        formats,
        source.format,
        source.modifier,
    ) orelse return error.UnsupportedModifier;
    const modifier_supported = render.DmabufFormatModifier.contains(
        formats,
        framebuffer_format,
        source.modifier,
    );
    if (!modifier_supported and !(implicit_scanout and
        source.modifier == drm_format_mod_linear)) return error.UnsupportedModifier;
    const key: ScanoutFramebufferKey = .{
        .cache_id = buffer.source_cache.?.id,
        .format = framebuffer_format,
    };
    self.scanout_frame_number +%= 1;
    if (self.scanout_frame_number == 0) self.scanout_frame_number = 1;
    if (self.scanout_framebuffers.getPtr(key)) |framebuffer| {
        if (!scanoutFramebufferLayoutMatches(framebuffer.*, buffer.size, source)) {
            return error.CacheIdentityMismatch;
        }
        framebuffer.last_used = self.scanout_frame_number;
        return .{ .key = key, .framebuffer_id = framebuffer.framebuffer_id };
    }
    try self.makeScanoutFramebufferRoom(fd);

    var handles: [render.max_dmabuf_planes]u32 = @splat(0);
    defer closeImportedBufferHandles(fd, handles);
    var pitches: [render.max_dmabuf_planes]u32 = @splat(0);
    var offsets: [render.max_dmabuf_planes]u32 = @splat(0);
    for (source.planeSlice(), 0..) |plane, index| {
        if (c.drmPrimeFDToHandle(fd, plane.fd, &handles[index]) != 0) {
            return error.ImportHandleFailed;
        }
        pitches[index] = plane.stride;
        offsets[index] = plane.offset;
    }
    var framebuffer_id: u32 = 0;
    var add_result: c_int = -1;
    if (modifier_supported) {
        var modifiers: [render.max_dmabuf_planes]u64 = @splat(0);
        for (modifiers[0..source.plane_count]) |*modifier| modifier.* = source.modifier;
        add_result = c.drmModeAddFB2WithModifiers(
            fd,
            buffer.size.width,
            buffer.size.height,
            framebuffer_format,
            &handles,
            &pitches,
            &offsets,
            &modifiers,
            &framebuffer_id,
            c.DRM_MODE_FB_MODIFIERS,
        );
    }
    if (add_result != 0 and source.modifier == drm_format_mod_linear and implicit_scanout) {
        add_result = c.drmModeAddFB2(
            fd,
            buffer.size.width,
            buffer.size.height,
            framebuffer_format,
            &handles,
            &pitches,
            &offsets,
            &framebuffer_id,
            0,
        );
    }
    if (add_result != 0) return error.AddFramebufferFailed;
    errdefer _ = c.drmModeRmFB(fd, framebuffer_id);

    try self.scanout_framebuffers.put(self.allocator, key, .{
        .framebuffer_id = framebuffer_id,
        .size = buffer.size,
        .format = source.format,
        .modifier = source.modifier,
        .plane_count = source.plane_count,
        .strides = pitches,
        .offsets = offsets,
        .last_used = self.scanout_frame_number,
    });
    return .{ .key = key, .framebuffer_id = framebuffer_id };
}

fn scanoutFramebufferLayoutMatches(
    framebuffer: ScanoutFramebuffer,
    size: render.Size,
    source: render.DmabufSource,
) bool {
    if (!std.meta.eql(framebuffer.size, size) or
        framebuffer.format != source.format or
        framebuffer.modifier != source.modifier or
        framebuffer.plane_count != source.plane_count)
    {
        return false;
    }
    for (source.planeSlice(), 0..) |plane, index| {
        if (framebuffer.strides[index] != plane.stride or
            framebuffer.offsets[index] != plane.offset) return false;
    }
    return true;
}

fn closeImportedBufferHandles(
    fd: std.posix.fd_t,
    handles: [render.max_dmabuf_planes]u32,
) void {
    handle_loop: for (handles, 0..) |handle, index| {
        if (handle == 0) continue;
        for (handles[0..index]) |previous| if (previous == handle) continue :handle_loop;
        if (c.drmCloseBufferHandle(fd, handle) != 0) {
            log.err("failed to close imported DRM buffer handle {d}", .{handle});
        }
    }
}

fn dmabufPlanesShareAllocation(planes: []const render.DmabufPlane) bool {
    if (planes.len == 0) return false;
    var first: c.struct_stat = undefined;
    if (c.fstat(planes[0].fd, &first) != 0) return false;
    for (planes[1..]) |plane| {
        var current: c.struct_stat = undefined;
        if (c.fstat(plane.fd, &current) != 0 or
            current.st_dev != first.st_dev or current.st_ino != first.st_ino)
        {
            return false;
        }
    }
    return true;
}

test "overlay synchronization requires one shared DMA-BUF allocation" {
    var first_pipe: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe2(&first_pipe, .{ .CLOEXEC = true }));
    defer {
        for (first_pipe) |fd| _ = std.c.close(fd);
    }

    var second_pipe: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe2(&second_pipe, .{ .CLOEXEC = true }));
    defer {
        for (second_pipe) |fd| _ = std.c.close(fd);
    }

    const duplicate = std.c.dup(first_pipe[0]);
    try std.testing.expect(duplicate >= 0);
    defer _ = std.c.close(duplicate);

    try std.testing.expect(dmabufPlanesShareAllocation(&.{
        .{ .fd = first_pipe[0] },
        .{ .fd = duplicate },
    }));
    try std.testing.expect(!dmabufPlanesShareAllocation(&.{
        .{ .fd = first_pipe[0] },
        .{ .fd = second_pipe[0] },
    }));
}

test "scanout framebuffer cache validates every DMA-BUF plane" {
    const NoopSource = struct {
        fn retain(_: *anyopaque) void {}
        fn release(_: *anyopaque) void {}
        fn begin(_: *anyopaque) bool {
            return true;
        }
        fn end(_: *anyopaque) bool {
            return true;
        }
        fn exportFence(_: *anyopaque, _: u8) ?std.posix.fd_t {
            return null;
        }
    };

    var context: u8 = 0;
    var source: render.DmabufSource = .{
        .context = &context,
        .format = @intFromEnum(render.DmabufFormat.nv12),
        .modifier = 7,
        .planes = .{
            .{ .stride = 128, .offset = 0 },
            .{ .stride = 64, .offset = 8192 },
            .{},
            .{},
        },
        .plane_count = 2,
        .y_inverted = false,
        .force_opaque = true,
        .retain = NoopSource.retain,
        .release = NoopSource.release,
        .begin_cpu_read = NoopSource.begin,
        .end_cpu_read = NoopSource.end,
        .export_read_fence = NoopSource.exportFence,
    };
    const framebuffer: ScanoutFramebuffer = .{
        .framebuffer_id = 1,
        .size = .{ .width = 64, .height = 64 },
        .format = source.format,
        .modifier = source.modifier,
        .plane_count = source.plane_count,
        .strides = .{ 128, 64, 0, 0 },
        .offsets = .{ 0, 8192, 0, 0 },
        .last_used = 1,
    };
    try std.testing.expect(scanoutFramebufferLayoutMatches(
        framebuffer,
        framebuffer.size,
        source,
    ));
    source.planes[1].offset += 64;
    try std.testing.expect(!scanoutFramebufferLayoutMatches(
        framebuffer,
        framebuffer.size,
        source,
    ));
}

fn legacyFramebufferLayoutMatches(self: *const Self, buffer: render.PixelBuffer) bool {
    const source = buffer.dmabuf orelse return false;
    if (source.plane_count != 1) return false;
    const plane = source.planes[0];
    const compositor_format = if (self.buffers[0].gbm) |gbm_buffer|
        gbm_buffer.format
    else
        c.DRM_FORMAT_XRGB8888;
    if (source.format != compositor_format) return false;
    if (self.direct_displayed) |displayed| {
        const current = self.scanout_framebuffers.get(displayed.framebuffer_key) orelse return false;
        return current.format == source.format and
            std.meta.eql(current.size, buffer.size) and
            current.modifier == source.modifier and
            current.plane_count == 1 and
            current.strides[0] == plane.stride and
            current.offsets[0] == plane.offset;
    }

    const index = self.displayed orelse return false;
    const current = self.buffers[index].gbm orelse return false;
    // Legacy KMS only guarantees page flips between framebuffers allocated
    // with identical layouts. Enforcing this here also guarantees that the
    // compositor-owned framebuffer can be restored after direct scan-out.
    return current.modifier == source.modifier and
        current.stride == plane.stride and
        current.offset == plane.offset;
}

fn queuePageFlip(
    self: *Self,
    fd: std.posix.fd_t,
    framebuffer_id: u32,
    source_size: render.Size,
    source: ?render.DmabufSource,
    overlay: ?AtomicOverlay,
    action: PageFlipAction,
    allow_tearing: bool,
) error{ AtomicTestFailed, OverlaySynchronizationFailed, OutputBusy }!?PageFlipMode {
    const preferred_mode: PageFlipMode = if (!self.output_color_dirty and
        allow_tearing and self.async_page_flip_supported and overlay == null and
        self.overlay_displayed == null)
        .async
    else
        .vsync;
    const properties = self.atomic_plane orelse {
        std.debug.assert(overlay == null and action == .commit);
        const preferred_result = c.drmModePageFlip(
            fd,
            self.crtc_id,
            framebuffer_id,
            pageFlipFlags(preferred_mode),
            self,
        );
        if (preferred_result == 0) return preferred_mode;
        const preferred_errno = drmModeError(preferred_result);
        if (preferred_mode == .async) {
            const fallback_result = c.drmModePageFlip(
                fd,
                self.crtc_id,
                framebuffer_id,
                pageFlipFlags(.vsync),
                self,
            );
            if (fallback_result == 0) return .vsync;
            const fallback_errno = drmModeError(fallback_result);
            if (fallback_errno == .BUSY) {
                log.warn(
                    "legacy page flip busy on {s}: CRTC={d} framebuffer={d} async_errno={t} vsync_errno={t}; retrying frame",
                    .{
                        self.name(),
                        self.crtc_id,
                        framebuffer_id,
                        preferred_errno,
                        fallback_errno,
                    },
                );
                return error.OutputBusy;
            }
            log.err(
                "legacy page flip failed on {s}: CRTC={d} framebuffer={d} async_errno={t} vsync_errno={t}",
                .{
                    self.name(),
                    self.crtc_id,
                    framebuffer_id,
                    preferred_errno,
                    fallback_errno,
                },
            );
            return null;
        }
        if (preferred_errno == .BUSY) {
            log.warn(
                "legacy page flip busy on {s}: CRTC={d} framebuffer={d}; retrying frame",
                .{ self.name(), self.crtc_id, framebuffer_id },
            );
            return error.OutputBusy;
        }
        log.err(
            "legacy page flip failed on {s}: CRTC={d} framebuffer={d} errno={t}",
            .{ self.name(), self.crtc_id, framebuffer_id, preferred_errno },
        );
        return null;
    };
    const request = c.drmModeAtomicAlloc() orelse {
        log.err("failed to allocate atomic page flip request on {s}", .{self.name()});
        return null;
    };
    defer c.drmModeAtomicFree(request);

    const plane_id = self.primary_plane_id orelse {
        log.err("atomic page flip on {s} has no primary plane", .{self.name()});
        return null;
    };
    const fence_fd = if (properties.in_fence_fd != 0 and source != null)
        source.?.export_read_fence(source.?.context, 0)
    else
        null;
    defer {
        if (fence_fd) |value| _ = std.c.close(value);
    }
    const overlay_fence_fd = if (overlay) |value|
        value.source.export_read_fence(value.source.context, 0)
    else
        null;
    defer {
        if (overlay_fence_fd) |value| _ = std.c.close(value);
    }
    if (!addAtomicPlaneState(
        request,
        plane_id,
        properties,
        framebuffer_id,
        self.crtc_id,
        source_size,
        .{ .x = 0, .y = 0, .width = self.size.width, .height = self.size.height },
        null,
        fence_fd,
        null,
    )) {
        log.err(
            "failed to add primary plane state for atomic page flip on {s}: plane={d} CRTC={d} framebuffer={d} source={d}x{d} destination={d}x{d}",
            .{
                self.name(),
                plane_id,
                self.crtc_id,
                framebuffer_id,
                source_size.width,
                source_size.height,
                self.size.width,
                self.size.height,
            },
        );
        return null;
    }
    if (self.overlay_plane) |plane| {
        if (overlay) |value| {
            const in_fence_fd = if (plane.atomic.in_fence_fd != 0)
                overlay_fence_fd
            else
                null;
            if (overlay_fence_fd) |value_fence_fd| if (action == .commit and
                in_fence_fd == null and
                (!self.sync_file_import_supported or
                    !importSyncFile(value.source.planes[0].fd, value_fence_fd)))
            {
                return error.OverlaySynchronizationFailed;
            };
            if (!addAtomicPlaneState(
                request,
                plane.id,
                plane.atomic,
                value.framebuffer_id,
                self.crtc_id,
                value.source_size,
                value.destination,
                value.color,
                in_fence_fd,
                if (plane.zpos_property) |property_id|
                    .{ .property_id = property_id, .value = plane.zpos }
                else
                    null,
            )) return null;
        } else if (!addAtomicPlaneDisabled(request, plane.id, plane.atomic)) {
            return null;
        }
    } else std.debug.assert(overlay == null);
    const color_dirty = self.output_color_dirty;
    if (color_dirty or self.output_color_mode != .sdr) {
        const color_added = self.addOutputColorState(
            fd,
            request,
            self.output_color_mode,
            self.color_description,
        ) catch {
            if (action == .commit and color_dirty and self.output_color_mode != .sdr) {
                self.rejectOutputColorState();
            }
            return null;
        };
        if (!color_added) {
            if (self.output_color_mode == .sdr) {
                if (action == .commit) self.output_color_dirty = false;
            } else {
                if (action == .commit and color_dirty) self.rejectOutputColorState();
                return null;
            }
        }
    }
    const atomic_flags: c_uint = if (color_dirty)
        @intCast(c.DRM_MODE_ATOMIC_ALLOW_MODESET)
    else
        @intCast(c.DRM_MODE_ATOMIC_NONBLOCK);
    if (overlay != null and !testAtomicRequest(fd, request, color_dirty)) {
        return error.AtomicTestFailed;
    }
    if (action == .test_only) {
        std.debug.assert(overlay != null);
        return .vsync;
    }
    const preferred_flags = atomic_flags | pageFlipFlags(preferred_mode);
    const preferred_result = c.drmModeAtomicCommit(
        fd,
        request,
        preferred_flags,
        self,
    );
    if (preferred_result == 0) {
        self.output_color_dirty = false;
        return preferred_mode;
    }
    const preferred_errno = drmModeError(preferred_result);
    if (preferred_mode == .async) {
        const fallback_flags = atomic_flags | pageFlipFlags(.vsync);
        const fallback_result = c.drmModeAtomicCommit(
            fd,
            request,
            fallback_flags,
            self,
        );
        if (fallback_result == 0) {
            self.output_color_dirty = false;
            return .vsync;
        }
        const fallback_errno = drmModeError(fallback_result);
        if (fallback_errno == .BUSY) {
            log.warn(
                "atomic page flip busy on {s}: CRTC={d} plane={d} framebuffer={d} source={d}x{d} destination={d}x{d} overlay={any} color_dirty={any} async_flags=0x{x} async_errno={t} vsync_flags=0x{x} vsync_errno={t}; retrying frame",
                .{
                    self.name(),
                    self.crtc_id,
                    plane_id,
                    framebuffer_id,
                    source_size.width,
                    source_size.height,
                    self.size.width,
                    self.size.height,
                    overlay != null,
                    color_dirty,
                    preferred_flags,
                    preferred_errno,
                    fallback_flags,
                    fallback_errno,
                },
            );
            return error.OutputBusy;
        }
        log.err(
            "atomic page flip commit failed on {s}: CRTC={d} plane={d} framebuffer={d} source={d}x{d} destination={d}x{d} overlay={any} color_dirty={any} async_flags=0x{x} async_errno={t} vsync_flags=0x{x} vsync_errno={t}",
            .{
                self.name(),
                self.crtc_id,
                plane_id,
                framebuffer_id,
                source_size.width,
                source_size.height,
                self.size.width,
                self.size.height,
                overlay != null,
                color_dirty,
                preferred_flags,
                preferred_errno,
                fallback_flags,
                fallback_errno,
            },
        );
    } else {
        if (preferred_errno == .BUSY) {
            log.warn(
                "atomic page flip busy on {s}: CRTC={d} plane={d} framebuffer={d} source={d}x{d} destination={d}x{d} overlay={any} color_dirty={any} flags=0x{x}; retrying frame",
                .{
                    self.name(),
                    self.crtc_id,
                    plane_id,
                    framebuffer_id,
                    source_size.width,
                    source_size.height,
                    self.size.width,
                    self.size.height,
                    overlay != null,
                    color_dirty,
                    preferred_flags,
                },
            );
            return error.OutputBusy;
        }
        log.err(
            "atomic page flip commit failed on {s}: CRTC={d} plane={d} framebuffer={d} source={d}x{d} destination={d}x{d} overlay={any} color_dirty={any} flags=0x{x} errno={t}",
            .{
                self.name(),
                self.crtc_id,
                plane_id,
                framebuffer_id,
                source_size.width,
                source_size.height,
                self.size.width,
                self.size.height,
                overlay != null,
                color_dirty,
                preferred_flags,
                preferred_errno,
            },
        );
    }
    if (color_dirty and self.output_color_mode != .sdr) self.rejectOutputColorState();
    return null;
}

fn supportsAsyncPageFlips(fd: std.posix.fd_t, atomic: bool) bool {
    var capability: u64 = 0;
    const capability_name = if (atomic)
        c.DRM_CAP_ATOMIC_ASYNC_PAGE_FLIP
    else
        c.DRM_CAP_ASYNC_PAGE_FLIP;
    return c.drmGetCap(fd, @intCast(capability_name), &capability) == 0 and capability != 0;
}

fn pageFlipFlags(mode: PageFlipMode) c_uint {
    return @as(c_uint, @intCast(c.DRM_MODE_PAGE_FLIP_EVENT)) |
        if (mode == .async) @as(c_uint, @intCast(c.DRM_MODE_PAGE_FLIP_ASYNC)) else 0;
}

fn drmModeError(result: c_int) std.posix.E {
    std.debug.assert(result < 0);
    return @enumFromInt(@as(u16, @intCast(-@as(i64, result))));
}

fn clearInheritedCursor(self: *Self, fd: std.posix.fd_t) void {
    if (self.device_access.atomic(self.device_access.context) and
        disableAtomicCursorPlanes(fd, self.crtc_id))
    {
        return;
    }
    if (c.drmModeSetCursor(fd, self.crtc_id, 0, 0, 0) != 0) {
        log.warn("failed to clear inherited cursor on CRTC {d}", .{self.crtc_id});
    }
}

fn disableCursor(self: *Self, fd: std.posix.fd_t) bool {
    const was_active = self.cursor_active;
    if (self.cursor_active and c.drmModeSetCursor(fd, self.crtc_id, 0, 0, 0) != 0) {
        log.warn("failed to disable hardware cursor on CRTC {d}", .{self.crtc_id});
        return false;
    }
    self.cursor_active = false;
    self.cursor_source = null;
    self.cursor_buffer_index = null;
    if (was_active) log.debug("hardware cursor disabled on {s}", .{self.name()});
    return true;
}

fn failCursor(self: *Self, err: anyerror) void {
    log.warn("hardware cursor unavailable for {s} until reactivation: {t}", .{ self.name(), err });
    self.cursor_failed = true;
}

fn createCursorBuffer(self: *Self, fd: std.posix.fd_t, buffer: *Buffer) !void {
    var create = std.mem.zeroes(c.struct_drm_mode_create_dumb);
    create.width = self.cursor_width;
    create.height = self.cursor_height;
    create.bpp = 32;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_CREATE_DUMB, &create) != 0) return error.CreateDumbBufferFailed;
    buffer.handle = create.handle;
    errdefer self.destroyBuffer(fd, buffer);
    var map = std.mem.zeroes(c.struct_drm_mode_map_dumb);
    map.handle = create.handle;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_MAP_DUMB, &map) != 0) return error.MapDumbBufferFailed;
    const mapping = try std.posix.mmap(null, @intCast(create.size), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, map.offset);
    buffer.mapping = mapping;
    buffer.stride_pixels = create.pitch / @sizeOf(u32);
    buffer.pixels = @as([*]u32, @ptrCast(@alignCast(mapping.ptr)))[0 .. mapping.len / @sizeOf(u32)];
    @memset(buffer.pixels, 0);
}

fn cursorLocalPosition(
    pointer_x: i32,
    pointer_y: i32,
    output_x: i32,
    output_y: i32,
    scale: render.Scale,
    hotspot_x: i32,
    hotspot_y: i32,
) render.Position {
    return .{
        .x = scaleSigned(pointer_x -| output_x, scale) -| hotspot_x,
        .y = scaleSigned(pointer_y -| output_y, scale) -| hotspot_y,
    };
}

fn scaleSigned(value: i32, scale: render.Scale) i32 {
    const product = @as(i64, value) * scale.numerator;
    const half: i64 = render.Scale.denominator / 2;
    return @intCast(if (product >= 0)
        @divTrunc(product + half, render.Scale.denominator)
    else
        @divTrunc(product - half, render.Scale.denominator));
}

fn rescaleCursor(source: render.PixelBuffer, size: render.Size, destination: *Buffer) void {
    @memset(destination.pixels, 0);
    if (std.meta.eql(source.size, size)) {
        for (0..size.height) |y| {
            @memcpy(
                destination.pixels[y * destination.stride_pixels ..][0..size.width],
                source.pixels[y * source.stride_pixels ..][0..size.width],
            );
        }
        return;
    }
    for (0..size.height) |y| {
        const vertical = cursorSample(y, source.size.height, size.height);
        for (0..size.width) |x| {
            const horizontal = cursorSample(x, source.size.width, size.width);
            const top_left = source.pixels[vertical.first * source.stride_pixels + horizontal.first];
            const top_right = source.pixels[vertical.first * source.stride_pixels + horizontal.second];
            const bottom_left = source.pixels[vertical.second * source.stride_pixels + horizontal.first];
            const bottom_right = source.pixels[vertical.second * source.stride_pixels + horizontal.second];
            destination.pixels[y * destination.stride_pixels + x] =
                interpolateCursorPixel(
                    top_left,
                    top_right,
                    bottom_left,
                    bottom_right,
                    horizontal.weight,
                    vertical.weight,
                );
        }
    }
}

const CursorSample = struct {
    first: usize,
    second: usize,
    weight: f64,
};

fn cursorSample(destination: usize, source_size: u32, destination_size: u32) CursorSample {
    std.debug.assert(source_size > 0 and destination_size > 0);
    const position = (@as(f64, @floatFromInt(destination)) + 0.5) *
        @as(f64, @floatFromInt(source_size)) / @as(f64, @floatFromInt(destination_size)) - 0.5;
    const first_unclamped: i64 = @intFromFloat(@floor(position));
    const maximum: i64 = source_size - 1;
    return .{
        .first = @intCast(std.math.clamp(first_unclamped, 0, maximum)),
        .second = @intCast(std.math.clamp(first_unclamped + 1, 0, maximum)),
        .weight = position - @floor(position),
    };
}

fn interpolateCursorPixel(
    top_left: u32,
    top_right: u32,
    bottom_left: u32,
    bottom_right: u32,
    horizontal: f64,
    vertical: f64,
) u32 {
    var result: u32 = 0;
    inline for (0..4) |component| {
        const shift: u5 = @intCast(component * 8);
        const top = @as(f64, @floatFromInt(@as(u8, @truncate(top_left >> shift)))) *
            (1.0 - horizontal) +
            @as(f64, @floatFromInt(@as(u8, @truncate(top_right >> shift)))) * horizontal;
        const bottom = @as(f64, @floatFromInt(@as(u8, @truncate(bottom_left >> shift)))) *
            (1.0 - horizontal) +
            @as(f64, @floatFromInt(@as(u8, @truncate(bottom_right >> shift)))) * horizontal;
        const value: u32 = @intFromFloat(@round(top * (1.0 - vertical) + bottom * vertical));
        result |= value << shift;
    }
    return result;
}

fn disableAtomicCursorPlanes(fd: std.posix.fd_t, crtc_id: u32) bool {
    const resources = c.drmModeGetPlaneResources(fd) orelse return false;
    defer c.drmModeFreePlaneResources(resources);
    const request = c.drmModeAtomicAlloc() orelse return false;
    defer c.drmModeAtomicFree(request);

    var found = false;
    const plane_count: usize = @intCast(resources.*.count_planes);
    for (resources.*.planes[0..plane_count]) |plane_id| {
        const plane = c.drmModeGetPlane(fd, plane_id) orelse continue;
        defer c.drmModeFreePlane(plane);
        if (plane.*.crtc_id != crtc_id) continue;
        const info = loadAtomicPlaneDisableInfo(fd, plane_id) orelse return false;
        if (info.plane_type != c.DRM_PLANE_TYPE_CURSOR) continue;
        found = true;
        if (!addAtomicProperty(request, plane_id, info.properties.fb_id, 0) or
            !addAtomicProperty(request, plane_id, info.properties.crtc_id, 0))
        {
            return false;
        }
    }
    if (!found) return true;
    return c.drmModeAtomicCommit(fd, request, 0, null) == 0;
}

fn loadAtomicPlaneDisableInfo(fd: std.posix.fd_t, plane_id: u32) ?struct {
    plane_type: u64,
    properties: AtomicPlaneDisableProperties,
} {
    const properties = c.drmModeObjectGetProperties(
        fd,
        plane_id,
        c.DRM_MODE_OBJECT_PLANE,
    ) orelse return null;
    defer c.drmModeFreeObjectProperties(properties);

    var plane_type: ?u64 = null;
    var result: AtomicPlaneDisableProperties = .{};
    const property_count: usize = @intCast(properties.*.count_props);
    for (0..property_count) |index| {
        const property_id = properties.*.props[index];
        const property = c.drmModeGetProperty(fd, property_id) orelse continue;
        defer c.drmModeFreeProperty(property);
        const property_name = std.mem.sliceTo(property.*.name[0..], 0);
        if (std.mem.eql(u8, property_name, "type")) {
            plane_type = properties.*.prop_values[index];
        } else if (std.mem.eql(u8, property_name, "FB_ID")) {
            result.fb_id = property_id;
        } else if (std.mem.eql(u8, property_name, "CRTC_ID")) {
            result.crtc_id = property_id;
        }
    }
    return .{
        .plane_type = plane_type orelse return null,
        .properties = if (result.complete()) result else return null,
    };
}

fn addAtomicProperty(
    request: *c.drmModeAtomicReq,
    object_id: u32,
    property_id: u32,
    value: u64,
) bool {
    return c.drmModeAtomicAddProperty(request, object_id, property_id, value) >= 0;
}

fn addAtomicPlaneState(
    request: *c.drmModeAtomicReq,
    plane_id: u32,
    properties: AtomicPlaneProperties,
    framebuffer_id: u32,
    crtc_id: u32,
    source_size: render.Size,
    destination: render.Rect,
    color: ?AtomicPlaneColorState,
    in_fence_fd: ?std.posix.fd_t,
    zpos: ?AtomicZpos,
) bool {
    std.debug.assert(framebuffer_id != 0 and crtc_id != 0);
    std.debug.assert(source_size.width > 0 and source_size.height > 0);
    std.debug.assert(destination.x >= 0 and destination.y >= 0);
    std.debug.assert(destination.width > 0 and destination.height > 0);
    if (!addAtomicProperty(request, plane_id, properties.fb_id, framebuffer_id) or
        !addAtomicProperty(request, plane_id, properties.crtc_id, crtc_id) or
        !addAtomicProperty(request, plane_id, properties.src_x, 0) or
        !addAtomicProperty(request, plane_id, properties.src_y, 0) or
        !addAtomicProperty(request, plane_id, properties.src_w, @as(u64, source_size.width) << 16) or
        !addAtomicProperty(request, plane_id, properties.src_h, @as(u64, source_size.height) << 16) or
        !addAtomicProperty(request, plane_id, properties.crtc_x, @intCast(destination.x)) or
        !addAtomicProperty(request, plane_id, properties.crtc_y, @intCast(destination.y)) or
        !addAtomicProperty(request, plane_id, properties.crtc_w, destination.width) or
        !addAtomicProperty(request, plane_id, properties.crtc_h, destination.height))
    {
        return false;
    }
    if (color) |value| {
        if (!addAtomicProperty(
            request,
            plane_id,
            value.encoding_property,
            value.encoding,
        ) or !addAtomicProperty(
            request,
            plane_id,
            value.range_property,
            value.range,
        )) return false;
    }
    if (in_fence_fd) |value| {
        if (properties.in_fence_fd == 0 or !addAtomicProperty(
            request,
            plane_id,
            properties.in_fence_fd,
            @bitCast(@as(i64, value)),
        )) return false;
    }
    if (zpos) |value| {
        if (!addAtomicProperty(request, plane_id, value.property_id, value.value)) return false;
    }
    return true;
}

fn addAtomicPlaneDisabled(
    request: *c.drmModeAtomicReq,
    plane_id: u32,
    properties: AtomicPlaneProperties,
) bool {
    return addAtomicProperty(request, plane_id, properties.fb_id, 0) and
        addAtomicProperty(request, plane_id, properties.crtc_id, 0);
}

fn testAtomicRequest(fd: std.posix.fd_t, request: *c.drmModeAtomicReq, allow_modeset: bool) bool {
    const flags = @as(c_uint, @intCast(c.DRM_MODE_ATOMIC_TEST_ONLY)) |
        if (allow_modeset) @as(c_uint, @intCast(c.DRM_MODE_ATOMIC_ALLOW_MODESET)) else 0;
    return c.drmModeAtomicCommit(fd, request, flags, null) == 0;
}

fn testOutputColorState(
    self: *Self,
    fd: std.posix.fd_t,
    mode: OutputColorMode,
    output_description: render.ColorDescription,
) bool {
    const request = c.drmModeAtomicAlloc() orelse return false;
    defer c.drmModeAtomicFree(request);
    const added = self.addOutputColorState(fd, request, mode, output_description) catch |err| {
        log.warn("failed to prepare {t} output color state on {s}: {t}", .{
            mode,
            self.name(),
            err,
        });
        return false;
    };
    if (!added) return mode == .sdr;
    if (testAtomicRequest(fd, request, true)) return true;
    log.warn("{t} output color state is unsupported on {s}", .{ mode, self.name() });
    return false;
}

fn commitOutputColorState(self: *Self, fd: std.posix.fd_t) bool {
    const request = c.drmModeAtomicAlloc() orelse return false;
    defer c.drmModeAtomicFree(request);
    const added = self.addOutputColorState(
        fd,
        request,
        self.output_color_mode,
        self.color_description,
    ) catch return false;
    if (!added) {
        if (self.output_color_mode != .sdr) return false;
        self.output_color_dirty = false;
        return true;
    }
    const flags = @as(c_uint, @intCast(c.DRM_MODE_ATOMIC_ALLOW_MODESET));
    if (c.drmModeAtomicCommit(fd, request, flags, null) != 0) return false;
    self.output_color_dirty = false;
    return true;
}

fn rejectOutputColorState(self: *Self) void {
    log.warn("{t} output color commit failed on {s}; falling back to SDR", .{
        self.output_color_mode,
        self.name(),
    });
    self.output_color_mode = .sdr;
    self.output_color_dirty = true;
    self.rejected_output_color_mode = null;
    self.hdr_failed = true;
    self.color_fallback_pending = true;
    self.color_description = self.sdr_color_description;
}

fn restoreOutputColorState(self: *Self, fd: std.posix.fd_t) bool {
    if (self.output_color_mode == .sdr and !self.output_color_dirty) return true;
    const properties = (self.atomic_color orelse return false).connector;
    const request = c.drmModeAtomicAlloc() orelse return false;
    defer c.drmModeAtomicFree(request);
    var added = false;
    if (properties.colorspace != 0) {
        const value = properties.default_colorspace orelse return false;
        if (!addAtomicProperty(request, self.connector_id, properties.colorspace, value)) {
            return false;
        }
        added = true;
    }
    if (properties.hdr_output_metadata != 0) {
        if (!addAtomicProperty(request, self.connector_id, properties.hdr_output_metadata, 0)) {
            return false;
        }
        added = true;
    }
    if (properties.max_bpc != 0) {
        if (!addAtomicProperty(
            request,
            self.connector_id,
            properties.max_bpc,
            properties.current_max_bpc,
        )) return false;
        added = true;
    }
    if (added) {
        const flags = @as(c_uint, @intCast(c.DRM_MODE_ATOMIC_ALLOW_MODESET));
        if (c.drmModeAtomicCommit(fd, request, flags, null) != 0) return false;
    }
    self.output_color_mode = .sdr;
    self.output_color_dirty = false;
    self.color_description = self.sdr_color_description;
    return true;
}

fn addOutputColorState(
    self: *Self,
    fd: std.posix.fd_t,
    request: *c.drmModeAtomicReq,
    mode: OutputColorMode,
    output_description: render.ColorDescription,
) !bool {
    const properties = (self.atomic_color orelse return false).connector;
    var added = false;
    if (properties.colorspace != 0) {
        const value = switch (mode) {
            .sdr => properties.default_colorspace orelse return false,
            .pq, .hlg => properties.bt2020_rgb orelse return false,
        };
        if (!addAtomicProperty(request, self.connector_id, properties.colorspace, value)) {
            return error.AddAtomicPropertyFailed;
        }
        added = true;
    }
    if (properties.hdr_output_metadata != 0) {
        const blob = try self.outputMetadataBlob(fd, mode, output_description);
        if (!addAtomicProperty(
            request,
            self.connector_id,
            properties.hdr_output_metadata,
            blob,
        )) return error.AddAtomicPropertyFailed;
        added = true;
    }
    if (properties.max_bpc != 0 and properties.max_bpc_limit >= properties.min_bpc) {
        const target: u64 = if (self.compositedScanoutFormat() == .xrgb2101010) 10 else 8;
        const value = @max(properties.min_bpc, @min(target, properties.max_bpc_limit));
        if (!addAtomicProperty(request, self.connector_id, properties.max_bpc, value)) {
            return error.AddAtomicPropertyFailed;
        }
        added = true;
    }
    return added;
}

fn outputMetadataBlob(
    self: *Self,
    fd: std.posix.fd_t,
    mode: OutputColorMode,
    output_description: render.ColorDescription,
) !u32 {
    if (mode == .sdr) return 0;
    if (self.hdr_metadata_blob != 0 and self.hdr_metadata_blob_mode == mode) {
        return self.hdr_metadata_blob;
    }
    self.destroyHdrMetadataBlob(fd);
    var metadata = hdrOutputMetadata(mode, output_description);
    var blob_id: u32 = 0;
    if (c.drmModeCreatePropertyBlob(fd, &metadata, @sizeOf(@TypeOf(metadata)), &blob_id) != 0 or
        blob_id == 0)
    {
        return error.CreatePropertyBlobFailed;
    }
    self.hdr_metadata_blob = blob_id;
    self.hdr_metadata_blob_mode = mode;
    return blob_id;
}

fn destroyHdrMetadataBlob(self: *Self, fd: std.posix.fd_t) void {
    if (self.hdr_metadata_blob != 0) {
        _ = c.drmModeDestroyPropertyBlob(fd, self.hdr_metadata_blob);
        self.hdr_metadata_blob = 0;
        self.hdr_metadata_blob_mode = null;
    }
}

fn hdrOutputMetadata(
    mode: OutputColorMode,
    output_description: render.ColorDescription,
) c.hdr_output_metadata {
    std.debug.assert(mode != .sdr);
    var metadata = std.mem.zeroes(c.hdr_output_metadata);
    metadata.metadata_type = 0;
    const info = &metadata.unnamed_0.hdmi_metadata_type1;
    info.eotf = switch (mode) {
        .sdr => unreachable,
        .pq => 2,
        .hlg => 3,
    };
    info.metadata_type = 0;
    const primaries = output_description.mastering_primaries orelse output_description.primaries;
    info.display_primaries[0].x = hdrChromaticity(primaries.red_x);
    info.display_primaries[0].y = hdrChromaticity(primaries.red_y);
    info.display_primaries[1].x = hdrChromaticity(primaries.green_x);
    info.display_primaries[1].y = hdrChromaticity(primaries.green_y);
    info.display_primaries[2].x = hdrChromaticity(primaries.blue_x);
    info.display_primaries[2].y = hdrChromaticity(primaries.blue_y);
    info.white_point.x = hdrChromaticity(primaries.white_x);
    info.white_point.y = hdrChromaticity(primaries.white_y);
    info.max_display_mastering_luminance = boundedU16(
        output_description.mastering_max_luminance orelse output_description.max_luminance,
    );
    info.min_display_mastering_luminance = boundedU16(
        output_description.mastering_min_luminance orelse output_description.min_luminance,
    );
    info.max_cll = boundedU16(
        output_description.max_cll orelse output_description.max_luminance,
    );
    info.max_fall = boundedU16(output_description.max_fall orelse 0);
    return metadata;
}

fn hdrChromaticity(value: i32) u16 {
    const clamped: u32 = @intCast(std.math.clamp(value, 0, 1_000_000));
    return @intCast((clamped + 10) / 20);
}

fn boundedU16(value: u32) u16 {
    return @intCast(@min(value, std.math.maxInt(u16)));
}

fn loadAtomicPlaneProperties(fd: std.posix.fd_t, plane_id: u32) ?AtomicPlaneProperties {
    if (plane_id == 0) return null;
    const properties = c.drmModeObjectGetProperties(
        fd,
        plane_id,
        c.DRM_MODE_OBJECT_PLANE,
    ) orelse return null;
    defer c.drmModeFreeObjectProperties(properties);

    var result: AtomicPlaneProperties = .{};
    const property_count: usize = @intCast(properties.*.count_props);
    for (properties.*.props[0..property_count]) |property_id| {
        const property = c.drmModeGetProperty(fd, property_id) orelse continue;
        defer c.drmModeFreeProperty(property);
        const property_name = std.mem.sliceTo(property.*.name[0..], 0);
        if (std.mem.eql(u8, property_name, "COLOR_ENCODING")) {
            result.color.encoding = property_id;
            result.color.bt601 = propertyEnumValue(property, "ITU-R BT.601 YCbCr");
            result.color.bt709 = propertyEnumValue(property, "ITU-R BT.709 YCbCr");
            result.color.bt2020 = propertyEnumValue(property, "ITU-R BT.2020 YCbCr");
        } else if (std.mem.eql(u8, property_name, "COLOR_RANGE")) {
            result.color.range = property_id;
            result.color.full_range = propertyEnumValue(property, "YCbCr full range");
            result.color.limited_range = propertyEnumValue(property, "YCbCr limited range");
        }
        inline for (.{
            .{ "FB_ID", "fb_id" },
            .{ "CRTC_ID", "crtc_id" },
            .{ "SRC_X", "src_x" },
            .{ "SRC_Y", "src_y" },
            .{ "SRC_W", "src_w" },
            .{ "SRC_H", "src_h" },
            .{ "CRTC_X", "crtc_x" },
            .{ "CRTC_Y", "crtc_y" },
            .{ "CRTC_W", "crtc_w" },
            .{ "CRTC_H", "crtc_h" },
            .{ "IN_FENCE_FD", "in_fence_fd" },
        }) |mapping| {
            if (std.mem.eql(u8, property_name, mapping[0])) {
                @field(result, mapping[1]) = property_id;
            }
        }
    }
    return if (result.complete()) result else null;
}

fn loadAtomicColorProperties(
    fd: std.posix.fd_t,
    connector_id: u32,
    crtc_id: u32,
) AtomicColorProperties {
    return .{
        .connector = loadAtomicConnectorColorProperties(fd, connector_id),
        .crtc = loadAtomicCrtcColorProperties(fd, crtc_id),
    };
}

fn loadAtomicConnectorColorProperties(
    fd: std.posix.fd_t,
    connector_id: u32,
) AtomicConnectorColorProperties {
    const properties = c.drmModeObjectGetProperties(
        fd,
        connector_id,
        c.DRM_MODE_OBJECT_CONNECTOR,
    ) orelse return .{};
    defer c.drmModeFreeObjectProperties(properties);

    var result: AtomicConnectorColorProperties = .{};
    const property_count: usize = @intCast(properties.*.count_props);
    for (0..property_count) |index| {
        const property_id = properties.*.props[index];
        const property = c.drmModeGetProperty(fd, property_id) orelse continue;
        defer c.drmModeFreeProperty(property);
        const property_name = std.mem.sliceTo(property.*.name[0..], 0);
        const current_value = properties.*.prop_values[index];
        if (std.mem.eql(u8, property_name, "Colorspace")) {
            result.colorspace = property_id;
            result.default_colorspace = propertyEnumValue(property, "Default");
            result.bt2020_rgb = propertyEnumValue(property, "BT2020_RGB");
            result.current_colorspace = current_value;
        } else if (std.mem.eql(u8, property_name, "HDR_OUTPUT_METADATA")) {
            result.hdr_output_metadata = property_id;
            result.current_hdr_output_metadata = current_value;
        } else if (std.mem.eql(u8, property_name, "max bpc")) {
            result.max_bpc = property_id;
            result.current_max_bpc = current_value;
            if (property.*.count_values >= 2 and property.*.values != null) {
                result.min_bpc = property.*.values[0];
                result.max_bpc_limit = property.*.values[1];
            }
        }
    }
    return result;
}

fn loadAtomicCrtcColorProperties(
    fd: std.posix.fd_t,
    crtc_id: u32,
) AtomicCrtcColorProperties {
    const properties = c.drmModeObjectGetProperties(
        fd,
        crtc_id,
        c.DRM_MODE_OBJECT_CRTC,
    ) orelse return .{};
    defer c.drmModeFreeObjectProperties(properties);

    var result: AtomicCrtcColorProperties = .{};
    const property_count: usize = @intCast(properties.*.count_props);
    for (0..property_count) |index| {
        const property_id = properties.*.props[index];
        const property = c.drmModeGetProperty(fd, property_id) orelse continue;
        defer c.drmModeFreeProperty(property);
        const property_name = std.mem.sliceTo(property.*.name[0..], 0);
        const current_value = properties.*.prop_values[index];
        if (std.mem.eql(u8, property_name, "DEGAMMA_LUT")) {
            result.degamma_lut = property_id;
            result.current_degamma_lut = current_value;
        } else if (std.mem.eql(u8, property_name, "DEGAMMA_LUT_SIZE")) {
            result.degamma_lut_size = boundedU32(current_value);
        } else if (std.mem.eql(u8, property_name, "CTM")) {
            result.ctm = property_id;
            result.current_ctm = current_value;
        } else if (std.mem.eql(u8, property_name, "GAMMA_LUT")) {
            result.gamma_lut = property_id;
            result.current_gamma_lut = current_value;
        } else if (std.mem.eql(u8, property_name, "GAMMA_LUT_SIZE")) {
            result.gamma_lut_size = boundedU32(current_value);
        }
    }
    return result;
}

fn propertyEnumValue(property: *const c.drmModePropertyRes, enum_name: []const u8) ?u64 {
    const enum_count: usize = @intCast(@max(property.count_enums, 0));
    if (enum_count == 0 or property.enums == null) return null;
    for (property.enums[0..enum_count]) |candidate| {
        if (std.mem.eql(u8, std.mem.sliceTo(candidate.name[0..], 0), enum_name)) {
            return candidate.value;
        }
    }
    return null;
}

test "atomic plane color state maps supported YCbCr metadata" {
    const properties: AtomicPlaneColorProperties = .{
        .encoding = 10,
        .bt601 = 20,
        .bt709 = 21,
        .range = 11,
        .limited_range = 30,
    };
    try std.testing.expectEqual(
        AtomicPlaneColorState{
            .encoding_property = 10,
            .encoding = 21,
            .range_property = 11,
            .range = 30,
        },
        properties.state(.{
            .coefficients = .bt709,
            .range = .limited,
            .chroma_location = .type_1,
        }).?,
    );
    try std.testing.expect(properties.state(.{
        .coefficients = .bt2020,
        .range = .limited,
        .chroma_location = .type_1,
    }) == null);
    try std.testing.expect(properties.state(.{}) == null);
}

fn boundedU32(value: u64) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn makeScanoutFramebufferRoom(self: *Self, fd: std.posix.fd_t) !void {
    if (self.scanout_framebuffers.count() < max_scanout_framebuffers) return;
    var oldest_key: ?ScanoutFramebufferKey = null;
    var oldest_frame: u64 = std.math.maxInt(u64);
    var iterator = self.scanout_framebuffers.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if ((self.direct_pending != null and
            std.meta.eql(self.direct_pending.?.framebuffer_key, key)) or
            (self.direct_displayed != null and
                std.meta.eql(self.direct_displayed.?.framebuffer_key, key)) or
            (self.overlay_pending != null and
                std.meta.eql(self.overlay_pending.?.framebuffer_key, key)) or
            (self.overlay_displayed != null and
                std.meta.eql(self.overlay_displayed.?.framebuffer_key, key)) or
            (self.validated_overlay != null and
                std.meta.eql(self.validated_overlay.?.scanout.framebuffer_key, key)) or
            entry.value_ptr.last_used >= oldest_frame) continue;
        oldest_key = key;
        oldest_frame = entry.value_ptr.last_used;
    }
    const key = oldest_key orelse return error.CacheFull;
    const framebuffer = self.scanout_framebuffers.fetchRemove(key).?.value;
    if (c.drmModeRmFB(fd, framebuffer.framebuffer_id) != 0) {
        log.err("failed to remove scanout framebuffer {d}", .{framebuffer.framebuffer_id});
    }
}

fn releaseClientScanouts(self: *Self) void {
    if (self.direct_pending) |scanout| scanout.release();
    if (self.direct_displayed) |scanout| scanout.release();
    if (self.overlay_pending) |scanout| scanout.release();
    if (self.overlay_displayed) |scanout| scanout.release();
    self.direct_pending = null;
    self.direct_displayed = null;
    self.overlay_pending = null;
    self.overlay_displayed = null;
    self.discardValidatedOverlay();
    self.setDirectScanoutActive(false);
}

fn discardValidatedOverlay(self: *Self) void {
    if (self.validated_overlay) |overlay| overlay.scanout.release();
    self.validated_overlay = null;
}

fn discardFailedValidatedFrame(self: *Self) void {
    self.discardValidatedOverlay();
    self.acquired = null;
}

fn destroyScanoutFramebuffers(self: *Self, fd: std.posix.fd_t) void {
    while (self.scanout_framebuffers.count() > 0) {
        var iterator = self.scanout_framebuffers.iterator();
        const key = iterator.next().?.key_ptr.*;
        const framebuffer = self.scanout_framebuffers.fetchRemove(key).?.value;
        if (c.drmModeRmFB(fd, framebuffer.framebuffer_id) != 0) {
            log.err("failed to remove scanout framebuffer {d}", .{framebuffer.framebuffer_id});
        }
    }
}

fn setDirectScanoutActive(self: *Self, active: bool) void {
    if (self.direct_scanout_active == active) return;
    self.direct_scanout_active = active;
    log.info("Direct scan-out {s}", .{if (active) "enabled" else "disabled"});
}

fn unavailableAtomic(_: *anyopaque) bool {
    return false;
}

const BufferPair = struct {
    buffers: [buffer_count]Buffer = .{ .{}, .{} },
    shadow_pixels: []u32 = &.{},
};

fn allocatePair(self: *Self, fd: std.posix.fd_t, size: render.Size) !BufferPair {
    if (self.allocateGpuPair(fd, size)) |pair| return pair else |err| {
        if (self.dmabuf_renderer != null and
            self.device_access.gbm(self.device_access.context) != null)
        {
            log.warn("GPU scanout allocation failed, using CPU buffers: {t}", .{err});
        }
    }
    log.info("allocating CPU shadow and scanout buffers at {d}x{d}", .{ size.width, size.height });
    var pair: BufferPair = .{};
    errdefer self.destroyPair(fd, &pair.buffers, pair.shadow_pixels);
    for (&pair.buffers) |*buffer| try self.createBuffer(fd, size, buffer);
    try createShadowBuffer(self.allocator, size, &pair.shadow_pixels);
    return pair;
}

fn allocateGpuPair(self: *Self, fd: std.posix.fd_t, size: render.Size) !BufferPair {
    const renderer = self.dmabuf_renderer orelse return error.NoDmabufRenderer;
    const gbm = self.device_access.gbm(self.device_access.context) orelse return error.NoGbmDevice;
    var compatible_modifiers: std.ArrayList(u64) = .empty;
    defer compatible_modifiers.deinit(self.allocator);
    var last_error: anyerror = error.NoSupportedModifier;
    for ([_]u32{ c.DRM_FORMAT_XRGB2101010, c.DRM_FORMAT_XRGB8888 }) |format| {
        compatible_modifiers.clearRetainingCapacity();
        for (self.scanout_formats) |pair| {
            if (pair.format != format) continue;
            const modifier = pair.modifier;
            if (render.DmabufFormatModifier.contains(
                renderer.target_formats,
                pair.format,
                modifier,
            ) and renderer.supports_target(renderer.context, size, pair.format, modifier)) {
                try compatible_modifiers.append(self.allocator, modifier);
            }
        }
        if (compatible_modifiers.items.len == 0) continue;
        var pair: BufferPair = .{};
        createGpuPair(
            fd,
            gbm,
            renderer,
            size,
            format,
            compatible_modifiers.items,
            &pair,
        ) catch |err| {
            last_error = err;
            self.destroyPair(fd, &pair.buffers, pair.shadow_pixels);
        };
        if (pair.buffers[0].render_target_id != null) {
            log.info(
                "allocated {s} GPU scanout buffers at {d}x{d}, modifier 0x{x}",
                .{
                    @tagName(render.DmabufFormat.fromFourcc(format).?),
                    size.width,
                    size.height,
                    pair.buffers[0].gbm.?.modifier,
                },
            );
            return pair;
        }
    }
    if (!self.implicit_scanout) return last_error;

    var pair: BufferPair = .{};
    createGpuPair(
        fd,
        gbm,
        renderer,
        size,
        c.DRM_FORMAT_XRGB8888,
        null,
        &pair,
    ) catch |err| {
        self.destroyPair(fd, &pair.buffers, pair.shadow_pixels);
        return err;
    };
    log.info(
        "allocated GPU scanout buffers at {d}x{d}, implicit modifier 0x{x}",
        .{ size.width, size.height, pair.buffers[0].gbm.?.modifier },
    );
    return pair;
}

fn createGpuPair(
    fd: std.posix.fd_t,
    gbm: *Gbm,
    renderer: render.DmabufRenderer,
    size: render.Size,
    format: u32,
    modifiers: ?[]const u64,
    pair: *BufferPair,
) !void {
    for (&pair.buffers) |*buffer| {
        buffer.gbm = if (modifiers) |explicit|
            try gbm.createBuffer(size, format, explicit)
        else
            try gbm.createImplicitBuffer(size, format);
        const bo = &buffer.gbm.?;
        if (bo.format != format) return error.UnexpectedBufferFormat;
        if (!render.DmabufFormatModifier.contains(
            renderer.target_formats,
            format,
            bo.modifier,
        )) {
            return error.UnsupportedRendererModifier;
        }
        var handles = [_]u32{ bo.handle, 0, 0, 0 };
        var pitches = [_]u32{ bo.stride, 0, 0, 0 };
        var offsets = [_]u32{ bo.offset, 0, 0, 0 };
        const result = if (modifiers == null)
            c.drmModeAddFB2(fd, size.width, size.height, format, &handles, &pitches, &offsets, &buffer.framebuffer_id, 0)
        else blk: {
            var framebuffer_modifiers = [_]u64{ bo.modifier, 0, 0, 0 };
            break :blk c.drmModeAddFB2WithModifiers(fd, size.width, size.height, format, &handles, &pitches, &offsets, &framebuffer_modifiers, &buffer.framebuffer_id, c.DRM_MODE_FB_MODIFIERS);
        };
        if (result != 0) return error.AddFramebufferFailed;
        const id = render.allocateRenderTargetId();
        try renderer.import_target(renderer.context, .{
            .id = id,
            .size = size,
            .fd = bo.fd,
            .format = format,
            .modifier = bo.modifier,
            .stride = bo.stride,
            .offset = bo.offset,
        });
        buffer.render_target_id = id;
    }
}

fn destroyPair(self: *Self, fd: std.posix.fd_t, buffers: *[buffer_count]Buffer, shadow: []u32) void {
    for (buffers) |*buffer| self.destroyBuffer(fd, buffer);
    self.allocator.free(shadow);
}

fn createBuffer(self: *Self, fd: std.posix.fd_t, size: render.Size, buffer: *Buffer) !void {
    var create = std.mem.zeroes(c.struct_drm_mode_create_dumb);
    create.width = size.width;
    create.height = size.height;
    create.bpp = 32;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_CREATE_DUMB, &create) != 0) {
        return error.CreateDumbBufferFailed;
    }
    buffer.handle = create.handle;
    errdefer self.destroyBuffer(fd, buffer);

    if (c.drmModeAddFB(
        fd,
        size.width,
        size.height,
        24,
        32,
        create.pitch,
        create.handle,
        &buffer.framebuffer_id,
    ) != 0) return error.AddFramebufferFailed;

    var map = std.mem.zeroes(c.struct_drm_mode_map_dumb);
    map.handle = create.handle;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_MAP_DUMB, &map) != 0) {
        return error.MapDumbBufferFailed;
    }
    const mapping = try std.posix.mmap(
        null,
        @intCast(create.size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        map.offset,
    );
    buffer.mapping = mapping;
    std.debug.assert(create.pitch % @sizeOf(u32) == 0);
    std.debug.assert(create.pitch >= size.width * @sizeOf(u32));
    buffer.stride_pixels = create.pitch / @sizeOf(u32);
    buffer.pixels = @as([*]u32, @ptrCast(@alignCast(mapping.ptr)))[0 .. mapping.len / @sizeOf(u32)];
    @memset(buffer.pixels, 0);
}

fn destroyBuffer(self: *Self, fd: std.posix.fd_t, buffer: *Buffer) void {
    if (buffer.render_target_id) |id| {
        const renderer = self.dmabuf_renderer orelse unreachable;
        renderer.release_target(renderer.context, id);
    }
    if (buffer.mapping) |mapping| std.posix.munmap(mapping);
    if (buffer.framebuffer_id != 0 and c.drmModeRmFB(fd, buffer.framebuffer_id) != 0) {
        log.err("failed to remove DRM framebuffer {d}", .{buffer.framebuffer_id});
    }
    if (buffer.gbm) |*gbm_buffer| {
        gbm_buffer.deinit();
    } else if (buffer.handle != 0) {
        var destroy = c.struct_drm_mode_destroy_dumb{ .handle = buffer.handle };
        if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_DESTROY_DUMB, &destroy) != 0) {
            log.err("failed to destroy DRM dumb buffer {d}", .{buffer.handle});
        }
    }
    buffer.* = .{};
}

fn restoreCrtc(fd: std.posix.fd_t, connector_id: u32, old_crtc: *c.drmModeCrtc) void {
    var connector = connector_id;
    const mode: ?*c.drmModeModeInfo = if (old_crtc.*.mode_valid != 0)
        &old_crtc.*.mode
    else
        null;
    if (c.drmModeSetCrtc(
        fd,
        old_crtc.*.crtc_id,
        old_crtc.*.buffer_id,
        old_crtc.*.x,
        old_crtc.*.y,
        if (mode == null) null else &connector,
        if (mode == null) 0 else 1,
        mode,
    ) != 0) {
        log.err("failed to restore CRTC {d}", .{old_crtc.*.crtc_id});
    }
}

test "identity gamma ramp spans the full unsigned range" {
    var ramp: [5]u16 = undefined;
    fillIdentityGammaRamp(&ramp);
    try std.testing.expectEqualSlices(u16, &.{ 0, 16383, 32767, 49151, 65535 }, &ramp);

    var singleton: [1]u16 = undefined;
    fillIdentityGammaRamp(&singleton);
    try std.testing.expectEqual(@as(u16, 65535), singleton[0]);
}

test "shadow copy respects scanout pitch" {
    const untouched = 0xfeed_beef;
    var destination = [_]u32{untouched} ** 10;
    const source = [_]u32{ 1, 2, 3, 4, 5, 6 };
    var damage = Region.init();
    defer damage.deinit();
    try damage.add(1, 0, 2, 2);

    copyShadowDamage(
        &destination,
        5,
        &source,
        .{ .width = 3, .height = 2 },
        &damage,
    );

    try std.testing.expectEqualSlices(
        u32,
        &.{ untouched, 2, 3, untouched, untouched, untouched, 5, 6, untouched, untouched },
        &destination,
    );
}

fn testDeviceFd(_: *anyopaque) ?std.posix.fd_t {
    return null;
}

fn unavailableGbm(_: *anyopaque) ?*Gbm {
    return null;
}

fn testDeviceGbm(_: *anyopaque) ?*Gbm {
    return null;
}

fn testDeviceActive(_: *anyopaque) bool {
    return false;
}

fn testDeviceFail(_: *anyopaque, _: anyerror) void {
    unreachable;
}

test "DRM buffer repair does not propagate an acquired buffer's backlog" {
    var context: u8 = 0;
    var output: Self = undefined;
    output.init(std.testing.allocator, std.testing.io, .{
        .context = &context,
        .fd = testDeviceFd,
        .gbm = testDeviceGbm,
        .active = testDeviceActive,
        .fail = testDeviceFail,
    });
    defer output.deinit();
    output.buffers[0].render_target_id = 1;
    output.buffers[1].render_target_id = 2;
    output.resetBufferDamage(.{ .width = 100, .height = 100 });

    var first_damage = Region.init();
    defer first_damage.deinit();
    first_damage.setRectangle(10, 10, 2, 2);
    output.acquired = 0;
    try output.repairDamage(&first_damage);
    try std.testing.expect(first_damage.coversRectangle(0, 0, 100, 100));
    try finishBufferDamageRepair(&output.buffer_damage, &output.acquired_damage, 0);
    try std.testing.expect(output.buffer_damage[0].isEmpty());
    try std.testing.expect(output.buffer_damage[1].coversRectangle(0, 0, 100, 100));

    var second_damage = Region.init();
    defer second_damage.deinit();
    second_damage.setRectangle(20, 20, 2, 2);
    output.acquired = 1;
    try output.repairDamage(&second_damage);
    try std.testing.expect(second_damage.coversRectangle(0, 0, 100, 100));
    try finishBufferDamageRepair(&output.buffer_damage, &output.acquired_damage, 1);
    try std.testing.expect(output.buffer_damage[0].coversRectangle(20, 20, 2, 2));
    try std.testing.expect(output.buffer_damage[1].isEmpty());

    var third_damage = Region.init();
    defer third_damage.deinit();
    third_damage.setRectangle(30, 30, 2, 2);
    output.acquired = 0;
    try output.repairDamage(&third_damage);
    try std.testing.expect(!third_damage.coversRectangle(0, 0, 100, 100));
    try std.testing.expect(third_damage.coversRectangle(20, 20, 2, 2));
    try std.testing.expect(third_damage.coversRectangle(30, 30, 2, 2));
    try finishBufferDamageRepair(&output.buffer_damage, &output.acquired_damage, 0);
    output.acquired = null;
}

test "cursor coordinates preserve signed fractional output-local positions" {
    const scale: render.Scale = .{ .numerator = 180 };
    try std.testing.expectEqual(
        render.Position{ .x = -2, .y = 3 },
        cursorLocalPosition(99, 52, 100, 50, scale, 0, 0),
    );
    try std.testing.expectEqual(
        render.Position{ .x = 30, .y = -2 },
        cursorLocalPosition(124, 52, 100, 50, scale, 6, 5),
    );
    try std.testing.expectEqual(@as(i32, 36), scaleSigned(24, scale));
}

test "cursor rescale interpolates pixels and clears plane padding" {
    const source_pixels = [_]u32{ 1, 2, 3, 4 };
    var destination_pixels = [_]u32{9} ** 12;
    var destination: Buffer = .{
        .pixels = &destination_pixels,
        .stride_pixels = 4,
    };
    rescaleCursor(.{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = @constCast(&source_pixels),
    }, .{ .width = 3, .height = 3 }, &destination);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 2, 0 }, destination_pixels[0..4]);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 3, 0 }, destination_pixels[4..8]);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 4, 0 }, destination_pixels[8..12]);

    @memset(&destination_pixels, 9);
    rescaleCursor(.{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = @constCast(&source_pixels),
    }, .{ .width = 2, .height = 2 }, &destination);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 0, 0 }, destination_pixels[0..4]);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 0, 0 }, destination_pixels[4..8]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, destination_pixels[8..12]);
}

test "preferred DRM mode wins over the first mode" {
    var modes = [_]c.drmModeModeInfo{
        std.mem.zeroes(c.drmModeModeInfo),
        std.mem.zeroes(c.drmModeModeInfo),
    };
    modes[1].type = c.DRM_MODE_TYPE_PREFERRED;
    try std.testing.expectEqual(@as(usize, 1), preferredModeIndex(&modes));
}

test "DRM mode inventory equality includes timing and preference" {
    var a = [_]Mode{.{
        .value = std.mem.zeroes(c.drmModeModeInfo),
        .preferred = true,
    }};
    var b = a;
    try std.testing.expect(modeListsEqual(&a, &b));
    b[0].value.vrefresh = 120;
    try std.testing.expect(!modeListsEqual(&a, &b));
    b = a;
    b[0].preferred = false;
    try std.testing.expect(!modeListsEqual(&a, &b));
}

test "DRM default scale targets a readable physical density" {
    try std.testing.expectEqual(
        render.Scale{ .numerator = 120 },
        defaultScale(.{ .width = 1920, .height = 1080 }, .{ .width = 531, .height = 299 }),
    );
    try std.testing.expectEqual(
        render.Scale{ .numerator = 150 },
        defaultScale(.{ .width = 3840, .height = 2160 }, .{ .width = 708, .height = 399 }),
    );
    try std.testing.expectEqual(
        render.Scale{ .numerator = 180 },
        defaultScale(.{ .width = 3840, .height = 2160 }, .{ .width = 598, .height = 336 }),
    );
}

test "DRM default scale rejects implausible physical dimensions" {
    try std.testing.expectEqual(
        render.Scale{},
        defaultScale(.{ .width = 3840, .height = 2160 }, .{ .width = 1, .height = 1 }),
    );
    try std.testing.expectEqual(
        render.Scale{},
        defaultScale(.{ .width = 3840, .height = 2160 }, .{ .width = 600, .height = 600 }),
    );
}

test "DRM mode refresh converts to presentation period" {
    var mode = std.mem.zeroes(c.drmModeModeInfo);
    mode.vrefresh = 50;
    try std.testing.expectEqual(@as(u32, 20_000_000), refreshNanoseconds(mode));
    mode.vrefresh = 0;
    try std.testing.expectEqual(presentation.nominal_refresh_nanoseconds, refreshNanoseconds(mode));
}

test "GBM Vulkan target accepts asynchronous render completion" {
    const fd = std.c.open("/dev/dri/card0", std.c.O{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    });
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);

    const VulkanRenderer = @import("../render/vulkan.zig");
    var renderer = VulkanRenderer.init(std.testing.allocator, .{ .major = 226, .minor = 0 }) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const access = renderer.dmabufAccess() orelse return error.SkipZigTest;
    var gbm = Gbm.init(fd) catch return error.SkipZigTest;
    defer gbm.deinit();

    const size: render.Size = .{ .width = 64, .height = 64 };
    const Selected = struct {
        buffer: Gbm.Buffer,
        framebuffer_id: u32,
        target_id: u64,
    };
    var selected: ?Selected = null;
    for (access.target_formats) |target_format| {
        var buffer = gbm.createBuffer(
            size,
            target_format.format,
            &.{target_format.modifier},
        ) catch continue;
        var handles = [_]u32{ buffer.handle, 0, 0, 0 };
        var pitches = [_]u32{ buffer.stride, 0, 0, 0 };
        var offsets = [_]u32{ buffer.offset, 0, 0, 0 };
        var framebuffer_id: u32 = 0;
        const add_result = if (buffer.modifier == drm_format_mod_linear)
            c.drmModeAddFB2(fd, size.width, size.height, target_format.format, &handles, &pitches, &offsets, &framebuffer_id, 0)
        else blk: {
            var modifiers = [_]u64{ buffer.modifier, 0, 0, 0 };
            break :blk c.drmModeAddFB2WithModifiers(fd, size.width, size.height, target_format.format, &handles, &pitches, &offsets, &modifiers, &framebuffer_id, c.DRM_MODE_FB_MODIFIERS);
        };
        if (add_result != 0) {
            buffer.deinit();
            continue;
        }
        const target_id = render.allocateRenderTargetId();
        access.import_target(access.context, .{
            .id = target_id,
            .size = size,
            .fd = buffer.fd,
            .format = target_format.format,
            .modifier = buffer.modifier,
            .stride = buffer.stride,
            .offset = buffer.offset,
        }) catch {
            _ = c.drmModeRmFB(fd, framebuffer_id);
            buffer.deinit();
            continue;
        };
        selected = .{
            .buffer = buffer,
            .framebuffer_id = framebuffer_id,
            .target_id = target_id,
        };
        break;
    }
    if (selected == null) return error.SkipZigTest;
    defer selected.?.buffer.deinit();
    defer _ = c.drmModeRmFB(fd, selected.?.framebuffer_id);
    defer access.release_target(access.context, selected.?.target_id);

    const completion = try renderer.renderFrameScanout(.{
        .size = size,
        .commands = &.{.{ .clear = render.Color.rgba(12, 34, 56, 255) }},
    }, .{ .dmabuf = .{ .id = selected.?.target_id, .size = size } }, null);
    if (completion.sync_file_fd) |fence_fd| {
        defer _ = std.c.close(fence_fd);
        try std.testing.expect(importSyncFile(selected.?.buffer.fd, fence_fd));
        try waitSyncFile(fence_fd);
    }
}

test "DRM scale preserves mode pixels and derives logical size" {
    var context: u8 = 0;
    var output: Self = undefined;
    output.init(std.testing.allocator, std.testing.io, .{
        .context = &context,
        .fd = testDeviceFd,
        .gbm = testDeviceGbm,
        .active = testDeviceActive,
        .fail = testDeviceFail,
    });
    defer output.deinit();
    output.size = .{ .width = 3840, .height = 2160 };
    output.scale = .{ .numerator = 150 };

    try std.testing.expectEqual(
        render.Size{ .width = 3072, .height = 1728 },
        output.logicalSize(),
    );
    try std.testing.expectEqual(render.Size{ .width = 3840, .height = 2160 }, output.size);
}

test "ICC profiles override SDR colorimetry without replacing native display data" {
    var context: u8 = 0;
    var output: Self = undefined;
    output.init(std.testing.allocator, std.testing.io, .{
        .context = &context,
        .fd = testDeviceFd,
        .gbm = testDeviceGbm,
        .active = testDeviceActive,
        .fail = testDeviceFail,
    });
    defer output.deinit();

    output.native_color_description = .{
        .primaries = render.display_p3_chromaticities,
        .named_primaries = .display_p3,
        .max_luminance = 120,
        .reference_luminance = 100,
    };
    output.refreshSdrColorDescription();
    output.color_description = output.sdr_color_description;
    const path = try std.testing.allocator.dupe(u8, "/profiles/display.icc");
    const matrix_profile: Icc.OutputProfile = .{ .matrix = .{
        .primaries = render.srgb_chromaticities,
        .transfer_function = .{ .power = 24000 },
    } };
    const matrix_description = output.colorDescriptionForIccProfile(matrix_profile);
    output.replaceIccProfile(matrix_profile, path);

    try std.testing.expectEqualStrings("/profiles/display.icc", output.iccProfilePath().?);
    try std.testing.expectEqual(matrix_description, output.colorDescription());
    try std.testing.expectEqual(render.srgb_chromaticities, output.color_description.primaries);
    try std.testing.expectEqual(
        render.TransferFunction{ .power = 24000 },
        output.color_description.transfer_function,
    );
    try std.testing.expectEqual(@as(u32, 120), output.color_description.max_luminance);
    try std.testing.expectEqual(
        render.display_p3_chromaticities,
        output.native_color_description.primaries,
    );

    const values = try std.testing.allocator.alloc(
        [4]f16,
        Icc.calibration_lut_edge_length * Icc.calibration_lut_edge_length *
            Icc.calibration_lut_edge_length,
    );
    @memset(values, .{ 0, 0, 0, 1 });
    const calibration_path = try std.testing.allocator.dupe(u8, "/profiles/calibration.icc");
    const calibration_profile: Icc.OutputProfile = .{ .calibration = .{
        .values = values,
        .identity = 42,
    } };
    const calibration_description = output.colorDescriptionForIccProfile(calibration_profile);
    output.replaceIccProfile(calibration_profile, calibration_path);
    try std.testing.expectEqual(calibration_description, output.colorDescription());
    try std.testing.expectEqual(
        render.display_p3_chromaticities,
        output.color_description.primaries,
    );
    try std.testing.expectEqual(@as(u64, 42), output.outputCalibration().?.identity);

    const replacement_values = try std.testing.allocator.dupe([4]f16, values);
    const replacement_path = try std.testing.allocator.dupe(u8, "/profiles/calibration.icc");
    output.replaceIccProfile(.{ .calibration = .{
        .values = replacement_values,
        .identity = 42,
    } }, replacement_path);
    const replacement_calibration = output.outputCalibration().?;
    try std.testing.expectEqual(@as(u64, 42), replacement_calibration.identity);
    try std.testing.expect(replacement_calibration.values.ptr == replacement_values.ptr);

    output.output_color_mode = .pq;
    var hdr_description = output.color_description;
    hdr_description.transfer_function = .st2084_pq;
    output.color_description = hdr_description;
    const predicted_hdr_description = output.colorDescriptionForIccProfile(null);
    output.replaceIccProfile(null, null);
    try std.testing.expectEqual(predicted_hdr_description, output.colorDescription());
    try std.testing.expect(output.outputCalibration() == null);
}

test "DRM discovery only accepts primary nodes" {
    try std.testing.expect(isPrimaryNode("/dev/dri/card0"));
    try std.testing.expect(isPrimaryNode("/dev/dri/card12"));
    try std.testing.expect(!isPrimaryNode("/dev/dri/renderD128"));
    try std.testing.expect(!isPrimaryNode("/sys/class/drm/card0-DP-1"));
}

test "asynchronous page flips retain completion events" {
    try std.testing.expectEqual(
        @as(u32, c.DRM_MODE_PAGE_FLIP_EVENT),
        pageFlipFlags(.vsync),
    );
    try std.testing.expectEqual(
        @as(u32, c.DRM_MODE_PAGE_FLIP_EVENT | c.DRM_MODE_PAGE_FLIP_ASYNC),
        pageFlipFlags(.async),
    );
}

test "retired DRM outputs wait for queued page flip callbacks" {
    var context: u8 = 0;
    var output: Self = undefined;
    output.init(std.testing.allocator, std.testing.io, .{
        .context = &context,
        .fd = testDeviceFd,
        .gbm = testDeviceGbm,
        .active = testDeviceActive,
        .fail = testDeviceFail,
    });
    defer output.deinit();
    output.pending = 0;
    output.pending_page_flip = .vsync;

    output.retire();
    try std.testing.expect(!output.retirementComplete());

    handlePageFlip(0, 0, 0, 0, &output);
    try std.testing.expect(output.retirementComplete());
}

test "CRTC selection preserves preferred and never selects claimed" {
    var ids = [_]u32{ 10, 20, 30 };
    var resources = std.mem.zeroes(c.drmModeRes);
    resources.count_crtcs = ids.len;
    resources.crtcs = &ids;
    try std.testing.expectEqual(@as(?usize, 1), selectCrtcIndex(&resources, 0b111, 20, 0));
    try std.testing.expectEqual(@as(?usize, 0), selectCrtcIndex(&resources, 0b111, 20, 0b010));
    try std.testing.expectEqual(@as(?usize, null), selectCrtcIndex(&resources, 0b011, null, 0b011));
}
