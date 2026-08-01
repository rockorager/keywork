//! XDG window state and frame pacing for the Wayring Vulkan path.

const Window = @This();

const std = @import("std");
const keywork = @import("keywork-ui");
const wayring = @import("wayring");
const protocol = @import("wayring-protocols");
const Client = @import("Client.zig");
const VulkanWindow = @import("VulkanWindow.zig");

pub const Event = enum { configured, repaint, close };

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
        try self.renderer.configure(self.pending_width, self.pending_height);
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
        _ = try protocol.wl_surface_types.decodeEvent(
            self.client.connectionPtr(),
            self.handles.surface,
            message,
        );
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
    return self.renderer.measureText(1, value, style);
}

fn renderBackendScale(_: *anyopaque) f32 {
    // Output and fractional-scale negotiation are intentionally not guessed:
    // the core-only bootstrap uses one logical pixel per buffer pixel.
    return 1;
}

fn renderBackendTextMetrics(context: *anyopaque, font_size: f32) !keywork.TextMetrics {
    const self: *Window = @ptrCast(@alignCast(context));
    return self.renderer.textMetrics(1, font_size);
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
}
