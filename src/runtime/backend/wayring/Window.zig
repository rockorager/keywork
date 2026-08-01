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

/// Call after disconnect, or after `renderer.retireAll` has reported true and
/// the protocol objects have been destroyed.
pub fn deinit(self: *Window) void {
    self.renderer.deinit();
    self.* = undefined;
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

fn destroyProtocol(client: *Client, handles: Client.Window) void {
    protocol.xdg_toplevel_types.requests.destroy(client.connectionPtr(), handles.toplevel) catch {};
    protocol.xdg_surface_types.requests.destroy(client.connectionPtr(), handles.xdg_surface) catch {};
    protocol.wl_surface_types.requests.destroy(client.connectionPtr(), handles.surface) catch {};
    client.flush() catch {};
}

test {
    std.testing.refAllDecls(Window);
}
