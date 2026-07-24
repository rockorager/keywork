//! Runtime-selected compositor output backend.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DrmOutput = @import("drm.zig");
const HeadlessOutput = @import("headless.zig");
const NestedOutput = @import("nested_wayland.zig");
const presentation = @import("../presentation.zig");
const Region = @import("../region.zig");
const render = @import("../render/types.zig");

const wl = wayland.server.wl;

io: std.Io,
backend: Backend,

const Backend = union(enum) {
    drm: *DrmOutput,
    headless: HeadlessOutput,
    nested: NestedOutput,
};

pub const Kind = enum {
    drm,
    headless,
    nested,
};

pub const Listener = NestedOutput.Listener;
pub const DirectScanoutResult = DrmOutput.DirectScanoutResult;
pub const ShapeCursor = DrmOutput.ShapeCursor;

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    output_size: render.Size,
    output_scale: render.Scale,
    output_refresh_millihertz: i32,
    kind: Kind,
    drm_output: ?*DrmOutput,
    listener: Listener,
    dmabuf_renderer: ?render.DmabufRenderer,
    offscreen_renderer: ?render.OffscreenRenderer,
) !void {
    self.io = io;
    switch (kind) {
        .drm => {
            const output = drm_output orelse return error.MissingDrmOutput;
            try output.attach(listener, dmabuf_renderer);
            self.backend = .{ .drm = output };
        },
        .headless => self.backend = .{ .headless = try HeadlessOutput.initForRenderer(
            allocator,
            output_size,
            output_scale,
            output_refresh_millihertz,
            offscreen_renderer,
        ) },
        .nested => {
            self.backend = .{ .nested = undefined };
            try self.backend.nested.init(io, display, output_size, listener);
        },
    }
}

pub fn drmOutput(self: *const Self) ?*DrmOutput {
    return switch (self.backend) {
        .drm => |output| output,
        else => null,
    };
}

pub fn scanoutFormats(self: *const Self) []const render.DmabufFormatModifier {
    return switch (self.backend) {
        .drm => |output| output.scanoutFormats(),
        else => &.{},
    };
}

pub fn compositedScanoutFormat(self: *const Self) ?render.DmabufFormat {
    return switch (self.backend) {
        .drm => |output| output.compositedScanoutFormat(),
        .headless => null,
        .nested => .argb8888,
    };
}

pub fn name(self: *const Self, fallback: []const u8) []const u8 {
    return switch (self.backend) {
        .drm => |output| output.name(),
        .headless, .nested => fallback,
    };
}

pub fn description(self: *const Self, fallback: []const u8) []const u8 {
    return switch (self.backend) {
        .drm => |output| output.description(),
        .headless, .nested => fallback,
    };
}

pub fn colorDescription(self: *const Self) render.ColorDescription {
    return switch (self.backend) {
        .drm => |output| output.colorDescription(),
        .headless, .nested => .{},
    };
}

pub fn outputCalibration(self: *const Self) ?render.OutputCalibration {
    return switch (self.backend) {
        .drm => |output| output.outputCalibration(),
        .headless, .nested => null,
    };
}

pub fn hdrOutputDescription(
    self: *const Self,
    transfer: render.TransferFunction,
) ?render.ColorDescription {
    return switch (self.backend) {
        .drm => |output| output.hdrOutputDescription(transfer),
        .headless, .nested => null,
    };
}

pub fn selectOutputTransfer(
    self: *Self,
    transfer: ?render.TransferFunction,
) bool {
    return switch (self.backend) {
        .drm => |output| output.selectOutputTransfer(transfer),
        .headless, .nested => false,
    };
}

pub fn make(self: *const Self, fallback: []const u8) []const u8 {
    return switch (self.backend) {
        .drm => |output| output.make() orelse fallback,
        .headless, .nested => fallback,
    };
}

pub fn model(self: *const Self, fallback: []const u8) []const u8 {
    return switch (self.backend) {
        .drm => |output| output.model() orelse fallback,
        .headless, .nested => fallback,
    };
}

pub fn deinit(self: *Self) void {
    switch (self.backend) {
        .drm => |output| output.detach(),
        .headless => |*output| output.deinit(),
        .nested => |*output| output.deinit(),
    }
    self.* = undefined;
}

pub fn startInput(self: *Self) !void {
    switch (self.backend) {
        .drm, .headless => {},
        .nested => |*output| try output.startInput(),
    }
}

pub fn size(self: *const Self) render.Size {
    return switch (self.backend) {
        .drm => |output| output.logicalSize(),
        .headless => |output| output.logicalSize(),
        .nested => |output| output.size,
    };
}

pub fn modeSize(self: *const Self) render.Size {
    return switch (self.backend) {
        .drm => |output| output.size,
        .headless => |output| output.size,
        .nested => |output| output.buffer_size,
    };
}

pub fn modePreferred(self: *const Self) bool {
    return switch (self.backend) {
        .drm => |output| output.availableModes()[output.currentModeIndex()].preferred,
        .headless, .nested => true,
    };
}

pub fn refreshMillihertz(self: *const Self) i32 {
    return switch (self.backend) {
        .drm => |output| output.refreshMillihertz(),
        .headless => |output| output.refreshMillihertz(),
        .nested => 60_000,
    };
}

pub fn physicalSize(self: *const Self) render.Size {
    return switch (self.backend) {
        .drm => |output| output.physical_size,
        .headless => |output| output.size,
        .nested => |output| output.buffer_size,
    };
}

pub fn renderScale(self: *const Self) render.Scale {
    return switch (self.backend) {
        .drm => |output| output.scale,
        .headless => |output| output.scale,
        .nested => |output| output.render_scale,
    };
}

pub fn clientScale(self: *const Self) u32 {
    return switch (self.backend) {
        .drm => |output| output.scale.ceil() catch unreachable,
        .headless => |output| output.scale.ceil() catch unreachable,
        .nested => |output| output.client_scale,
    };
}

pub fn ready(self: *const Self) bool {
    return switch (self.backend) {
        .drm => |output| output.ready(),
        .headless => true,
        .nested => |*output| output.ready(),
    };
}

pub fn persistentRenderTarget(self: *const Self) bool {
    return switch (self.backend) {
        .drm, .headless => true,
        .nested => false,
    };
}

pub fn powered(self: *const Self) bool {
    return switch (self.backend) {
        .drm => |output| output.powered,
        .headless, .nested => true,
    };
}

/// Applies a built-in cursor shape when this backend can safely use hardware.
/// False means the caller must retain software composition.
pub fn setShapeCursor(self: *Self, cursor: ShapeCursor) bool {
    return switch (self.backend) {
        .drm => |output| output.setShapeCursor(cursor),
        .headless, .nested => false,
    };
}

pub fn canUseShapeCursor(self: *const Self, cursor: ShapeCursor) bool {
    return switch (self.backend) {
        .drm => |output| output.canUseShapeCursor(cursor),
        .headless, .nested => false,
    };
}

pub fn disableShapeCursor(self: *Self) bool {
    return switch (self.backend) {
        .drm => |output| output.disableShapeCursor(),
        .headless, .nested => true,
    };
}

pub fn shapeCursorActive(self: *const Self) bool {
    return switch (self.backend) {
        .drm => |output| output.shapeCursorActive(),
        .headless, .nested => false,
    };
}

pub fn repaintIntervalNanoseconds(self: *const Self) ?u32 {
    return switch (self.backend) {
        // Presentation-backed outputs only defer until the current event batch is complete.
        .drm, .nested => null,
        .headless => |output| output.refreshNanoseconds(),
    };
}

pub fn presentationClockId(self: *const Self) u32 {
    return switch (self.backend) {
        .drm => |output| output.presentation_clock_id,
        .headless => presentation.monotonic_clock_id,
        .nested => |*output| output.presentationClockId(),
    };
}

pub fn acquire(self: *Self) ?render.Target {
    return switch (self.backend) {
        .drm => |output| output.acquire(),
        .headless => |*output| output.renderTarget(),
        .nested => |*output| if (output.acquire()) |target| .{ .pixels = target } else null,
    };
}

pub fn repairDamage(self: *Self, damage: *Region) !void {
    switch (self.backend) {
        .drm => |output| try output.repairDamage(damage),
        .headless, .nested => {},
    }
}

pub fn cancel(self: *Self) void {
    switch (self.backend) {
        .drm => |output| output.cancel(),
        .headless => {},
        .nested => |*output| output.cancel(),
    }
}

pub fn present(
    self: *Self,
    damage: *const Region,
    render_fence_fd: ?std.posix.fd_t,
    allow_tearing: bool,
) !?presentation.Info {
    return switch (self.backend) {
        .drm => |output| output.present(damage, render_fence_fd, allow_tearing),
        .headless => |output| blk: {
            std.debug.assert(render_fence_fd == null);
            var info = presentation.Info.now(self.io);
            info.refresh_nanoseconds = output.refreshNanoseconds();
            break :blk info;
        },
        .nested => |*output| blk: {
            std.debug.assert(render_fence_fd == null);
            try output.present();
            break :blk null;
        },
    };
}

/// Retain an accepted candidate until it is presented or the frame is canceled.
pub fn validateOverlayScanout(
    self: *Self,
    overlay: render.OverlayScanout,
) DrmOutput.OverlayScanoutResult {
    return switch (self.backend) {
        .drm => |output| output.validateOverlayScanout(overlay),
        .headless, .nested => .{ .rejected = .unsupported_backend },
    };
}

/// Present a primary buffer that omits the overlay retained by validation.
pub fn presentValidatedOverlay(
    self: *Self,
    damage: *const Region,
    render_fence_fd: ?std.posix.fd_t,
    allow_tearing: bool,
) !?presentation.Info {
    return switch (self.backend) {
        .drm => |output| output.presentValidatedOverlay(
            damage,
            render_fence_fd,
            allow_tearing,
        ),
        .headless, .nested => error.NoValidatedOverlay,
    };
}

pub fn tryDirectScanout(
    self: *Self,
    buffer: render.PixelBuffer,
    allow_tearing: bool,
) DirectScanoutResult {
    return switch (self.backend) {
        .drm => |output| output.tryDirectScanout(buffer, allow_tearing),
        .headless, .nested => .{ .rejected = .unsupported_backend },
    };
}
