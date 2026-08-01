//! XDG window state and frame pacing for the Wayring Vulkan path.

const Window = @This();

const std = @import("std");
const keywork = @import("keywork-ui");
const wayring = @import("wayring");
const protocol = @import("wayring-protocols");
const Client = @import("Client.zig");
const VulkanWindow = @import("VulkanWindow.zig");

pub const Event = enum { configured, repaint, close };

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
closed: bool = false,
closing: bool = false,
protocol_destroyed: bool = false,
scale: u32 = 1,
preferred_scale: ?u32 = null,
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
        const pixel_size = try scaledSize(self.pending_width, self.pending_height, self.scale);
        try self.renderer.configure(pixel_size.width, pixel_size.height);
        self.width = self.pending_width;
        self.height = self.pending_height;
        self.configured = true;
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
                self.preferred_scale = @intCast(event.factor);
                return self.applyScale();
            },
            .preferred_buffer_transform => {},
        }
        return null;
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

pub fn surfaceId(self: *const Window) u32 {
    return self.handles.surface.id;
}

pub fn outputScaleChanged(self: *Window) !?Event {
    if (self.preferred_scale != null) return null;
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
    return self.renderer.measureText(@floatFromInt(self.scale), value, style);
}

fn renderBackendScale(context: *anyopaque) f32 {
    const self: *Window = @ptrCast(@alignCast(context));
    return @floatFromInt(self.scale);
}

fn renderBackendTextMetrics(context: *anyopaque, font_size: f32) !keywork.TextMetrics {
    const self: *Window = @ptrCast(@alignCast(context));
    return self.renderer.textMetrics(@floatFromInt(self.scale), font_size);
}

fn applyScale(self: *Window) !?Event {
    var next_scale = self.preferred_scale orelse 1;
    if (self.preferred_scale == null) {
        for (self.entered_outputs.items) |output_id| {
            next_scale = @max(next_scale, self.client.outputScale(output_id) orelse 1);
        }
    }
    if (next_scale == self.scale) return null;
    if (next_scale > std.math.maxInt(i32)) return error.InvalidSurfaceScale;
    try protocol.wl_surface_types.requests.set_buffer_scale(
        self.client.connectionPtr(),
        self.handles.surface,
        @intCast(next_scale),
    );
    self.scale = next_scale;
    if (!self.configured) return null;
    const pixel_size = try scaledSize(self.width, self.height, self.scale);
    try self.renderer.configure(pixel_size.width, pixel_size.height);
    try self.client.flush();
    return .configured;
}

fn scaledSize(width: u32, height: u32, scale: u32) !struct { width: u32, height: u32 } {
    return .{
        .width = std.math.mul(u32, width, scale) catch return error.DimensionOverflow,
        .height = std.math.mul(u32, height, scale) catch return error.DimensionOverflow,
    };
}

fn destroyProtocol(client: *Client, handles: Client.Window) void {
    protocol.xdg_toplevel_types.requests.destroy(client.connectionPtr(), handles.toplevel) catch {};
    protocol.xdg_surface_types.requests.destroy(client.connectionPtr(), handles.xdg_surface) catch {};
    protocol.wl_surface_types.requests.destroy(client.connectionPtr(), handles.surface) catch {};
    client.flush() catch {};
}

fn finishClose(self: *Window) !void {
    if (self.protocol_destroyed or !try self.renderer.retireAll()) return;
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
        (try scaledSize(1920, 1080, 2)).width,
    );
    try std.testing.expectError(error.DimensionOverflow, scaledSize(std.math.maxInt(u32), 1, 2));
}
