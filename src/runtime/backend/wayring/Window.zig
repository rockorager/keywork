//! XDG window state and frame pacing for the Wayring Vulkan path.

const Window = @This();

const std = @import("std");
const keywork = @import("keywork-ui");
const wayring = @import("wayring");
const protocol = @import("wayring-protocols");
const Client = @import("Client.zig");
const VulkanWindow = @import("VulkanWindow.zig");

pub const Event = enum { configured, repaint, close };
pub const ResizeEdge = enum { top, bottom, left, right, top_left, top_right, bottom_left, bottom_right };

allocator: std.mem.Allocator,
client: *Client,
handles: Client.Window,
renderer: VulkanWindow,
frame_callback: ?wayring.ObjectHandle = null,
width: u32,
height: u32,
pending_width: u32,
pending_height: u32,
configured: bool = false,
configure_generation: u64 = 0,
closed: bool = false,
closing: bool = false,
protocol_destroyed: bool = false,
scale_120: u32 = 120,
preferred_buffer_scale: ?u32 = null,
entered_outputs: std.ArrayList(u32) = .empty,

pub fn init(
    allocator: std.mem.Allocator,
    client: *Client,
    title: []const u8,
    app_id: []const u8,
    default_width: u32,
    default_height: u32,
) !Window {
    if (default_width == 0 or default_height == 0) return error.EmptyWindow;
    const handles = try client.createXdgWindow(title, app_id);
    errdefer destroyProtocol(client, handles);

    const raw_candidates = client.dmaBufCandidates();
    const candidates = try allocator.alloc(VulkanWindow.Candidate, raw_candidates.len);
    defer allocator.free(candidates);
    var candidate_count: usize = 0;
    for (raw_candidates) |candidate| {
        const format: @FieldType(VulkanWindow.Candidate, "format") = switch (candidate.format) {
            0x34325241 => .argb8888,
            0x34325258 => .xrgb8888,
            else => continue,
        };
        candidates[candidate_count] = .{ .format = format, .modifier = candidate.modifier };
        candidate_count += 1;
    }

    var renderer = try VulkanWindow.init(
        allocator,
        client.connectionPtr(),
        handles.surface,
        client.dmaBufFactory() orelse return error.MissingDmaBufFactory,
        candidates[0..candidate_count],
    );
    errdefer renderer.deinit();
    return .{
        .allocator = allocator,
        .client = client,
        .handles = handles,
        .renderer = renderer,
        .width = default_width,
        .height = default_height,
        .pending_width = default_width,
        .pending_height = default_height,
    };
}

/// Call after disconnect or after `readyToDeinit` reports true.
pub fn deinit(self: *Window) void {
    self.entered_outputs.deinit(self.allocator);
    self.renderer.deinit();
    self.* = undefined;
}

/// Unmaps the surface before retiring its buffers. Committed DMA-BUF targets
/// remain alive until the compositor releases every `wl_buffer`; only then
/// are the XDG and surface objects destroyed.
pub fn beginClose(self: *Window) !void {
    if (self.closing) return;
    self.closing = true;
    self.closed = true;
    try protocol.wl_surface_types.requests.attach(
        self.client.connectionPtr(),
        self.handles.surface,
        null,
        0,
        0,
    );
    try protocol.wl_surface_types.requests.commit(
        self.client.connectionPtr(),
        self.handles.surface,
    );
    try self.finishClose();
    try self.client.flush();
}

pub fn readyToDeinit(self: *const Window) bool {
    return self.protocol_destroyed;
}

pub fn isConfigured(self: *const Window) bool {
    return self.configured;
}

pub fn renderBackend(self: *Window) keywork.RenderBackend {
    return .{ .ptr = self, .vtable = &render_backend_vtable };
}

pub fn ownsObject(self: *const Window, id: u32) bool {
    return id == self.handles.surface.id or
        id == self.handles.xdg_surface.id or
        id == self.handles.toplevel.id or
        (self.handles.fractional_scale != null and id == self.handles.fractional_scale.?.id) or
        (self.frame_callback != null and id == self.frame_callback.?.id) or
        self.renderer.ownsObject(id);
}

pub fn handleMessage(self: *Window, message: *const wayring.Message) !?Event {
    if (self.renderer.ownsObject(message.object_id)) {
        try self.renderer.handleMessage(message);
        if (self.closing) try self.finishClose();
        return null;
    }
    if (message.object_id == self.handles.toplevel.id) {
        switch (try protocol.xdg_toplevel_types.decodeEvent(
            self.client.connectionPtr(),
            self.handles.toplevel,
            message,
        )) {
            .configure => |event| {
                if (event.width > 0) self.pending_width = @intCast(event.width);
                if (event.height > 0) self.pending_height = @intCast(event.height);
            },
            .close => {
                self.closed = true;
                return .close;
            },
            .configure_bounds, .wm_capabilities => {},
        }
        return null;
    }
    if (message.object_id == self.handles.xdg_surface.id) {
        const configure = (try protocol.xdg_surface_types.decodeEvent(
            self.client.connectionPtr(),
            self.handles.xdg_surface,
            message,
        )).configure;
        try protocol.xdg_surface_types.requests.ack_configure(
            self.client.connectionPtr(),
            self.handles.xdg_surface,
            configure.serial,
        );
        self.width = self.pending_width;
        self.height = self.pending_height;
        try self.configureScale();
        self.configured = true;
        self.configure_generation +%= 1;
        try self.client.flush();
        return .configured;
    }
    if (self.frame_callback) |callback| {
        if (message.object_id == callback.id) {
            _ = try protocol.wl_callback_types.decodeEvent(
                self.client.connectionPtr(),
                callback,
                message,
            );
            self.frame_callback = null;
            if (self.closing) return null;
            return .repaint;
        }
    }
    if (message.object_id == self.handles.surface.id) {
        switch (try protocol.wl_surface_types.decodeEvent(
            self.client.connectionPtr(),
            self.handles.surface,
            message,
        )) {
            .enter => |event| {
                for (self.entered_outputs.items) |id| if (id == event.output) return null;
                try self.entered_outputs.append(self.allocator, event.output);
                return self.applyScale();
            },
            .leave => |event| {
                for (self.entered_outputs.items, 0..) |id, index| {
                    if (id != event.output) continue;
                    _ = self.entered_outputs.orderedRemove(index);
                    break;
                }
                return self.applyScale();
            },
            .preferred_buffer_scale => |event| {
                if (event.factor <= 0) return error.InvalidSurfaceScale;
                self.preferred_buffer_scale = @intCast(event.factor);
                return self.applyScale();
            },
            .preferred_buffer_transform => {},
        }
        return null;
    }
    if (self.handles.fractional_scale) |fractional_scale| {
        if (message.object_id == fractional_scale.id) {
            const preferred = (try protocol.wp_fractional_scale_v1_types.decodeEvent(
                self.client.connectionPtr(),
                fractional_scale,
                message,
            )).preferred_scale;
            if (preferred.scale == 0) return error.InvalidSurfaceScale;
            return self.applyScale120(preferred.scale);
        }
    }
    return error.UnknownWindowObject;
}

pub fn present(
    self: *Window,
    display_list: []const keywork.PaintCommand,
    scale: f32,
) !bool {
    if (!self.configured or self.closed or self.frame_callback != null) return false;
    self.frame_callback = (try self.renderer.presentWithFrame(display_list, scale)) orelse
        return false;
    try self.client.flush();
    return true;
}

pub fn size(self: *const Window) struct { width: u32, height: u32 } {
    return .{ .width = self.width, .height = self.height };
}

pub fn configureGeneration(self: *const Window) u64 {
    return self.configure_generation;
}

pub fn isClosed(self: *const Window) bool {
    return self.closed;
}

pub fn surfaceId(self: *const Window) u32 {
    return self.handles.surface.id;
}

pub fn surfaceHandle(self: *const Window) wayring.ObjectHandle {
    return self.handles.surface;
}

pub fn cursorScale(self: *const Window) u32 {
    return self.scale_120 / 120 + @intFromBool(self.scale_120 % 120 != 0);
}

pub fn startMove(self: *Window, seat: wayring.ObjectHandle, serial: u32) !void {
    try protocol.xdg_toplevel_types.requests.move(
        self.client.connectionPtr(),
        self.handles.toplevel,
        seat,
        serial,
    );
    try self.client.flush();
}

pub fn startResize(self: *Window, seat: wayring.ObjectHandle, serial: u32, edge: ResizeEdge) !void {
    const protocol_edge: protocol.xdg_toplevel_types.resize_edge = switch (edge) {
        .top => .top,
        .bottom => .bottom,
        .left => .left,
        .right => .right,
        .top_left => .top_left,
        .top_right => .top_right,
        .bottom_left => .bottom_left,
        .bottom_right => .bottom_right,
    };
    try protocol.xdg_toplevel_types.requests.resize(
        self.client.connectionPtr(),
        self.handles.toplevel,
        seat,
        serial,
        @intFromEnum(protocol_edge),
    );
    try self.client.flush();
}

pub fn outputScaleChanged(self: *Window) !?Event {
    if (self.handles.fractional_scale != null or self.preferred_buffer_scale != null) return null;
    return self.applyScale();
}

const render_backend_vtable: keywork.RenderBackend.VTable = .{
    .present = renderBackendPresent,
    .measure_text = renderBackendMeasureText,
    .scale = renderBackendScale,
    .text_metrics = renderBackendTextMetrics,
};

fn renderBackendPresent(context: *anyopaque, frame: keywork.RenderBackend.Frame) !bool {
    const self: *Window = @ptrCast(@alignCast(context));
    return self.present(frame.display_list, frame.scale);
}

fn renderBackendMeasureText(
    context: *anyopaque,
    value: []const u8,
    style: keywork.ResolvedTextStyle,
) !keywork.Size {
    const self: *Window = @ptrCast(@alignCast(context));
    return self.renderer.measureText(self.renderScale(), value, style);
}

fn renderBackendScale(context: *anyopaque) f32 {
    const self: *Window = @ptrCast(@alignCast(context));
    return self.renderScale();
}

fn renderBackendTextMetrics(context: *anyopaque, font_size: f32) !keywork.TextMetrics {
    const self: *Window = @ptrCast(@alignCast(context));
    return self.renderer.textMetrics(self.renderScale(), font_size);
}

fn applyScale(self: *Window) !?Event {
    if (self.handles.fractional_scale != null) return null;
    var next_scale = self.preferred_buffer_scale orelse 1;
    if (self.preferred_buffer_scale == null) {
        for (self.entered_outputs.items) |output_id| {
            next_scale = @max(next_scale, self.client.outputScale(output_id) orelse 1);
        }
    }
    if (next_scale > std.math.maxInt(i32)) return error.InvalidSurfaceScale;
    const next_scale_120 = std.math.mul(u32, next_scale, 120) catch return error.InvalidSurfaceScale;
    if (next_scale_120 == self.scale_120) return null;
    try protocol.wl_surface_types.requests.set_buffer_scale(
        self.client.connectionPtr(),
        self.handles.surface,
        @intCast(next_scale),
    );
    return self.applyScale120(next_scale_120);
}

fn applyScale120(self: *Window, next_scale_120: u32) !?Event {
    if (next_scale_120 == 0) return error.InvalidSurfaceScale;
    if (next_scale_120 == self.scale_120) return null;
    self.scale_120 = next_scale_120;
    if (!self.configured) return null;
    try self.configureScale();
    try self.client.flush();
    return .configured;
}

fn configureScale(self: *Window) !void {
    if (self.handles.viewport) |viewport| {
        const logical_width = std.math.cast(i32, self.width) orelse return error.DimensionOverflow;
        const logical_height = std.math.cast(i32, self.height) orelse return error.DimensionOverflow;
        try protocol.wp_viewport_types.requests.set_destination(
            self.client.connectionPtr(),
            viewport,
            logical_width,
            logical_height,
        );
    }
    const pixel_size = try scaledSize120(self.width, self.height, self.scale_120);
    try self.renderer.configure(pixel_size.width, pixel_size.height);
}

fn renderScale(self: *const Window) f32 {
    return @as(f32, @floatFromInt(self.scale_120)) / 120.0;
}

fn scaledSize120(width: u32, height: u32, scale_120: u32) !struct { width: u32, height: u32 } {
    if (scale_120 == 0) return error.InvalidSurfaceScale;
    return .{
        .width = try scaledDimension120(width, scale_120),
        .height = try scaledDimension120(height, scale_120),
    };
}

fn scaledDimension120(dimension: u32, scale_120: u32) !u32 {
    const product = @as(u64, dimension) * @as(u64, scale_120);
    const result = product / 120 + @intFromBool(product % 120 != 0);
    return std.math.cast(u32, result) orelse error.DimensionOverflow;
}

fn destroyProtocol(client: *Client, handles: Client.Window) void {
    if (handles.fractional_scale) |fractional_scale|
        protocol.wp_fractional_scale_v1_types.requests.destroy(client.connectionPtr(), fractional_scale) catch {};
    if (handles.viewport) |viewport|
        protocol.wp_viewport_types.requests.destroy(client.connectionPtr(), viewport) catch {};
    protocol.xdg_toplevel_types.requests.destroy(client.connectionPtr(), handles.toplevel) catch {};
    protocol.xdg_surface_types.requests.destroy(client.connectionPtr(), handles.xdg_surface) catch {};
    protocol.wl_surface_types.requests.destroy(client.connectionPtr(), handles.surface) catch {};
    client.flush() catch {};
}

fn finishClose(self: *Window) !void {
    if (self.protocol_destroyed or !try self.renderer.retireAll()) return;
    if (self.handles.fractional_scale) |fractional_scale| {
        try protocol.wp_fractional_scale_v1_types.requests.destroy(
            self.client.connectionPtr(),
            fractional_scale,
        );
    }
    if (self.handles.viewport) |viewport| {
        try protocol.wp_viewport_types.requests.destroy(
            self.client.connectionPtr(),
            viewport,
        );
    }
    try protocol.xdg_toplevel_types.requests.destroy(
        self.client.connectionPtr(),
        self.handles.toplevel,
    );
    try protocol.xdg_surface_types.requests.destroy(
        self.client.connectionPtr(),
        self.handles.xdg_surface,
    );
    try protocol.wl_surface_types.requests.destroy(
        self.client.connectionPtr(),
        self.handles.surface,
    );
    self.protocol_destroyed = true;
}

test {
    std.testing.refAllDecls(Window);
    try std.testing.expectEqual(
        @as(u32, 3840),
        (try scaledSize120(1920, 1080, 240)).width,
    );
    try std.testing.expectEqual(
        @as(u32, 1282),
        (try scaledSize120(1025, 1, 150)).width,
    );
    try std.testing.expectError(
        error.DimensionOverflow,
        scaledSize120(std.math.maxInt(u32), 1, 240),
    );
    try std.testing.expectError(error.InvalidSurfaceScale, scaledSize120(1, 1, 0));
}
