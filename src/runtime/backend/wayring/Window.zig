//! Wayring surface roles, presentation selection, scaling, and frame pacing.

const Window = @This();

const std = @import("std");
const keywork = @import("keywork-ui");
const wayring = @import("wayring");
const protocol = @import("wayring-protocols");
const Client = @import("Client.zig");
const ShmWindow = @import("ShmWindow.zig");
const VulkanWindow = @import("VulkanWindow.zig");
const wayland_options = @import("../wayland/options.zig");
const wayland_window = @import("../wayland/window.zig");

pub const Event = enum { configured, repaint, close };
pub const ResizeEdge = enum { top, bottom, left, right, top_left, top_right, bottom_left, bottom_right };
pub const Presentation = enum { dma_buf, shm };

const Role = union(enum) {
    toplevel: struct {
        xdg_surface: wayring.ObjectHandle,
        toplevel: wayring.ObjectHandle,
    },
    popup: struct {
        xdg_surface: wayring.ObjectHandle,
        popup: wayring.ObjectHandle,
    },
    layer: wayring.ObjectHandle,
    session_lock: wayring.ObjectHandle,
};

const Renderer = union(Presentation) {
    dma_buf: VulkanWindow,
    shm: ShmWindow,

    fn deinit(self: *Renderer) void {
        switch (self.*) {
            .dma_buf => |*renderer| renderer.deinit(),
            .shm => |*renderer| renderer.deinit(),
        }
    }

    fn configure(self: *Renderer, width: u32, height: u32) !void {
        switch (self.*) {
            .dma_buf => |*renderer| try renderer.configure(width, height),
            .shm => |*renderer| try renderer.configure(width, height),
        }
    }

    fn ownsObject(self: *const Renderer, id: u32) bool {
        return switch (self.*) {
            .dma_buf => |*renderer| renderer.ownsObject(id),
            .shm => |*renderer| renderer.ownsObject(id),
        };
    }

    fn handleMessage(self: *Renderer, message: *const wayring.Message) !void {
        switch (self.*) {
            .dma_buf => |*renderer| try renderer.handleMessage(message),
            .shm => |*renderer| try renderer.handleMessage(message),
        }
    }

    fn presentWithFrame(
        self: *Renderer,
        display_list: []const keywork.PaintCommand,
        scale: f32,
    ) !?wayring.ObjectHandle {
        return switch (self.*) {
            .dma_buf => |*renderer| renderer.presentWithFrame(display_list, scale),
            .shm => |*renderer| renderer.presentWithFrame(display_list, scale),
        };
    }

    fn retireAll(self: *Renderer) !bool {
        return switch (self.*) {
            .dma_buf => |*renderer| renderer.retireAll(),
            .shm => |*renderer| renderer.retireAll(),
        };
    }

    fn measureText(
        self: *Renderer,
        scale: f32,
        value: []const u8,
        style: keywork.ResolvedTextStyle,
    ) !keywork.Size {
        return switch (self.*) {
            .dma_buf => |*renderer| renderer.measureText(scale, value, style),
            .shm => |*renderer| renderer.measureText(scale, value, style),
        };
    }

    fn textMetrics(self: *Renderer, scale: f32, font_size: f32) !keywork.TextMetrics {
        return switch (self.*) {
            .dma_buf => |*renderer| renderer.textMetrics(scale, font_size),
            .shm => |*renderer| renderer.textMetrics(scale, font_size),
        };
    }
};

allocator: std.mem.Allocator,
client: *Client,
surface: wayring.ObjectHandle,
viewport: ?wayring.ObjectHandle,
fractional_scale: ?wayring.ObjectHandle,
role: Role,
renderer: Renderer,
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
popup_insets: wayland_window.SurfaceInsets = .{},
layer_keyboard_interactivity: ?wayland_options.LayerShellOptions.KeyboardInteractivity = null,

pub fn init(
    allocator: std.mem.Allocator,
    client: *Client,
    title: []const u8,
    app_id: []const u8,
    default_width: u32,
    default_height: u32,
    presentation: Presentation,
) !Window {
    if (default_width == 0 or default_height == 0) return error.EmptyWindow;
    const handles = try client.createXdgWindow(title, app_id);
    errdefer destroyProtocol(client, handles);

    return initSurface(
        allocator,
        client,
        .{
            .surface = handles.surface,
            .viewport = handles.viewport,
            .fractional_scale = handles.fractional_scale,
        },
        .{ .toplevel = .{
            .xdg_surface = handles.xdg_surface,
            .toplevel = handles.toplevel,
        } },
        default_width,
        default_height,
        .{},
        null,
        presentation,
    );
}

pub fn initLayer(
    allocator: std.mem.Allocator,
    client: *Client,
    options: wayland_options.LayerShellOptions,
    output: ?wayring.ObjectHandle,
    default_width: u32,
    default_height: u32,
    presentation: Presentation,
) !Window {
    const shell = client.layerShell() orelse return error.MissingLayerShell;
    const base = try client.createSurface();
    errdefer client.destroySurface(base);
    const layer_surface = try protocol.zwlr_layer_shell_v1_types.requests.get_layer_surface(
        client.connectionPtr(),
        shell,
        base.surface,
        output,
        @intFromEnum(layer(options.layer)),
        options.namespace,
    );
    errdefer protocol.zwlr_layer_surface_v1_types.requests.destroy(
        client.connectionPtr(),
        layer_surface,
    ) catch {};
    try protocol.zwlr_layer_surface_v1_types.requests.set_size(
        client.connectionPtr(),
        layer_surface,
        default_width,
        default_height,
    );
    try protocol.zwlr_layer_surface_v1_types.requests.set_anchor(
        client.connectionPtr(),
        layer_surface,
        layerAnchor(options.anchors),
    );
    try protocol.zwlr_layer_surface_v1_types.requests.set_exclusive_zone(
        client.connectionPtr(),
        layer_surface,
        options.exclusive_zone,
    );
    try protocol.zwlr_layer_surface_v1_types.requests.set_margin(
        client.connectionPtr(),
        layer_surface,
        options.margin.top,
        options.margin.right,
        options.margin.bottom,
        options.margin.left,
    );
    try protocol.zwlr_layer_surface_v1_types.requests.set_keyboard_interactivity(
        client.connectionPtr(),
        layer_surface,
        @intFromEnum(keyboardInteractivity(options.keyboard_interactivity)),
    );
    if (options.pointer_interactivity == .none) try setEmptyInputRegion(client, base.surface);
    try protocol.wl_surface_types.requests.commit(client.connectionPtr(), base.surface);
    try client.flush();
    return initSurface(
        allocator,
        client,
        base,
        .{ .layer = layer_surface },
        default_width,
        default_height,
        .{},
        options.keyboard_interactivity,
        presentation,
    );
}

pub fn initPopup(
    allocator: std.mem.Allocator,
    client: *Client,
    parent: *Window,
    options: wayland_window.PopupOptions,
    presentation: Presentation,
) !Window {
    const wm_base = client.wmBaseHandle() orelse return error.MissingXdgWmBase;
    const parent_xdg_surface = switch (parent.role) {
        .toplevel => |role| role.xdg_surface,
        .popup => |role| role.xdg_surface,
        .layer => null,
        .session_lock => return error.PopupUnsupported,
    };
    const base = try client.createSurface();
    errdefer client.destroySurface(base);
    const xdg_surface = try protocol.xdg_wm_base_types.requests.get_xdg_surface(
        client.connectionPtr(),
        wm_base,
        base.surface,
    );
    errdefer protocol.xdg_surface_types.requests.destroy(client.connectionPtr(), xdg_surface) catch {};
    const positioner = try protocol.xdg_wm_base_types.requests.create_positioner(
        client.connectionPtr(),
        wm_base,
    );
    errdefer protocol.xdg_positioner_types.requests.destroy(client.connectionPtr(), positioner) catch {};
    try configurePopupPositioner(client, positioner, options);
    const popup = try protocol.xdg_surface_types.requests.get_popup(
        client.connectionPtr(),
        xdg_surface,
        parent_xdg_surface,
        positioner,
    );
    errdefer protocol.xdg_popup_types.requests.destroy(client.connectionPtr(), popup) catch {};
    if (parent.role == .layer) try protocol.zwlr_layer_surface_v1_types.requests.get_popup(
        client.connectionPtr(),
        parent.role.layer,
        popup,
    );
    try protocol.xdg_positioner_types.requests.destroy(client.connectionPtr(), positioner);
    try configurePopupGeometry(client, base.surface, xdg_surface, options);
    try protocol.wl_surface_types.requests.commit(client.connectionPtr(), base.surface);
    try client.flush();
    const width = try options.insets.bufferWidth(options.width);
    const height = try options.insets.bufferHeight(options.height);
    return initSurface(
        allocator,
        client,
        base,
        .{ .popup = .{ .xdg_surface = xdg_surface, .popup = popup } },
        width,
        height,
        options.insets,
        null,
        presentation,
    );
}

pub fn initSessionLock(
    allocator: std.mem.Allocator,
    client: *Client,
    lock: wayring.ObjectHandle,
    output: wayring.ObjectHandle,
    default_width: u32,
    default_height: u32,
    presentation: Presentation,
) !Window {
    const base = try client.createSurface();
    errdefer client.destroySurface(base);
    const lock_surface = try protocol.ext_session_lock_v1_types.requests.get_lock_surface(
        client.connectionPtr(),
        lock,
        base.surface,
        output,
    );
    errdefer protocol.ext_session_lock_surface_v1_types.requests.destroy(
        client.connectionPtr(),
        lock_surface,
    ) catch {};
    try client.flush();
    return initSurface(
        allocator,
        client,
        base,
        .{ .session_lock = lock_surface },
        default_width,
        default_height,
        .{},
        null,
        presentation,
    );
}

fn initSurface(
    allocator: std.mem.Allocator,
    client: *Client,
    base: Client.Surface,
    role: Role,
    default_width: u32,
    default_height: u32,
    popup_insets: wayland_window.SurfaceInsets,
    layer_keyboard_interactivity: ?wayland_options.LayerShellOptions.KeyboardInteractivity,
    presentation: Presentation,
) !Window {
    var renderer = try initRenderer(allocator, client, base.surface, presentation);
    errdefer renderer.deinit();
    return .{
        .allocator = allocator,
        .client = client,
        .surface = base.surface,
        .viewport = base.viewport,
        .fractional_scale = base.fractional_scale,
        .role = role,
        .renderer = renderer,
        .width = default_width,
        .height = default_height,
        .pending_width = default_width,
        .pending_height = default_height,
        .popup_insets = popup_insets,
        .layer_keyboard_interactivity = layer_keyboard_interactivity,
    };
}

fn initRenderer(
    allocator: std.mem.Allocator,
    client: *Client,
    surface: wayring.ObjectHandle,
    presentation: Presentation,
) !Renderer {
    if (presentation == .shm) {
        return .{ .shm = try ShmWindow.init(
            allocator,
            client.connectionPtr(),
            surface,
            client.shmHandle() orelse return error.MissingShm,
        ) };
    }

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

    return .{ .dma_buf = try VulkanWindow.init(
        allocator,
        client.connectionPtr(),
        surface,
        client.dmaBufFactory() orelse return error.MissingDmaBufFactory,
        candidates[0..candidate_count],
    ) };
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
    if (self.role != .session_lock) {
        try protocol.wl_surface_types.requests.attach(
            self.client.connectionPtr(),
            self.surface,
            null,
            0,
            0,
        );
        try protocol.wl_surface_types.requests.commit(
            self.client.connectionPtr(),
            self.surface,
        );
    }
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
    return id == self.surface.id or
        self.roleOwnsObject(id) or
        (self.fractional_scale != null and id == self.fractional_scale.?.id) or
        (self.frame_callback != null and id == self.frame_callback.?.id) or
        self.renderer.ownsObject(id);
}

pub fn handleMessage(self: *Window, message: *const wayring.Message) !?Event {
    if (self.renderer.ownsObject(message.object_id)) {
        try self.renderer.handleMessage(message);
        if (self.closing) try self.finishClose();
        return null;
    }
    if (self.role == .toplevel and message.object_id == self.role.toplevel.toplevel.id) {
        const role = self.role.toplevel;
        switch (try protocol.xdg_toplevel_types.decodeEvent(
            self.client.connectionPtr(),
            role.toplevel,
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
    if (self.role == .toplevel and message.object_id == self.role.toplevel.xdg_surface.id) {
        const role = self.role.toplevel;
        const configure = (try protocol.xdg_surface_types.decodeEvent(
            self.client.connectionPtr(),
            role.xdg_surface,
            message,
        )).configure;
        try protocol.xdg_surface_types.requests.ack_configure(
            self.client.connectionPtr(),
            role.xdg_surface,
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
    if (self.role == .popup and message.object_id == self.role.popup.popup.id) {
        switch (try protocol.xdg_popup_types.decodeEvent(
            self.client.connectionPtr(),
            self.role.popup.popup,
            message,
        )) {
            .configure => |configure| {
                if (configure.width > 0) self.pending_width = try self.popup_insets.bufferWidth(@intCast(configure.width));
                if (configure.height > 0) self.pending_height = try self.popup_insets.bufferHeight(@intCast(configure.height));
            },
            .popup_done => {
                self.closed = true;
                return .close;
            },
            .repositioned => {},
        }
        return null;
    }
    if (self.role == .popup and message.object_id == self.role.popup.xdg_surface.id) {
        const configure = (try protocol.xdg_surface_types.decodeEvent(
            self.client.connectionPtr(),
            self.role.popup.xdg_surface,
            message,
        )).configure;
        try protocol.xdg_surface_types.requests.ack_configure(
            self.client.connectionPtr(),
            self.role.popup.xdg_surface,
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
    if (self.role == .layer and message.object_id == self.role.layer.id) {
        switch (try protocol.zwlr_layer_surface_v1_types.decodeEvent(
            self.client.connectionPtr(),
            self.role.layer,
            message,
        )) {
            .configure => |configure| {
                const width = if (configure.width == 0) self.pending_width else configure.width;
                const height = if (configure.height == 0) self.pending_height else configure.height;
                if (width == 0 or height == 0) return error.EmptyLayerConfigure;
                try protocol.zwlr_layer_surface_v1_types.requests.ack_configure(
                    self.client.connectionPtr(),
                    self.role.layer,
                    configure.serial,
                );
                self.width = width;
                self.height = height;
                self.pending_width = width;
                self.pending_height = height;
                try self.configureScale();
                self.configured = true;
                self.configure_generation +%= 1;
                try self.client.flush();
                return .configured;
            },
            .closed => {
                self.closed = true;
                return .close;
            },
        }
    }
    if (self.role == .session_lock and message.object_id == self.role.session_lock.id) {
        const configure = (try protocol.ext_session_lock_surface_v1_types.decodeEvent(
            self.client.connectionPtr(),
            self.role.session_lock,
            message,
        )).configure;
        if (configure.width == 0 or configure.height == 0) return error.EmptySessionLockConfigure;
        try protocol.ext_session_lock_surface_v1_types.requests.ack_configure(
            self.client.connectionPtr(),
            self.role.session_lock,
            configure.serial,
        );
        self.width = configure.width;
        self.height = configure.height;
        self.pending_width = configure.width;
        self.pending_height = configure.height;
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
    if (message.object_id == self.surface.id) {
        switch (try protocol.wl_surface_types.decodeEvent(
            self.client.connectionPtr(),
            self.surface,
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
    if (self.fractional_scale) |fractional_scale| {
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
    return self.surface.id;
}

pub fn surfaceHandle(self: *const Window) wayring.ObjectHandle {
    return self.surface;
}

pub fn cursorScale(self: *const Window) u32 {
    return self.scale_120 / 120 + @intFromBool(self.scale_120 % 120 != 0);
}

pub fn startMove(self: *Window, seat: wayring.ObjectHandle, serial: u32) !void {
    const role = switch (self.role) {
        .toplevel => |value| value,
        else => return error.NotToplevel,
    };
    try protocol.xdg_toplevel_types.requests.move(
        self.client.connectionPtr(),
        role.toplevel,
        seat,
        serial,
    );
    try self.client.flush();
}

pub fn startResize(self: *Window, seat: wayring.ObjectHandle, serial: u32, edge: ResizeEdge) !void {
    const role = switch (self.role) {
        .toplevel => |value| value,
        else => return error.NotToplevel,
    };
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
        role.toplevel,
        seat,
        serial,
        @intFromEnum(protocol_edge),
    );
    try self.client.flush();
}

pub fn outputScaleChanged(self: *Window) !?Event {
    if (self.fractional_scale != null or self.preferred_buffer_scale != null) return null;
    return self.applyScale();
}

pub fn requestLayerSize(self: *Window, width: u31, height: u31) !void {
    const role = switch (self.role) {
        .layer => |value| value,
        else => return error.NotLayerSurface,
    };
    try protocol.zwlr_layer_surface_v1_types.requests.set_size(
        self.client.connectionPtr(),
        role,
        width,
        height,
    );
    try protocol.wl_surface_types.requests.commit(self.client.connectionPtr(), self.surface);
    try self.client.flush();
}

pub fn grabPopup(self: *Window, seat: wayring.ObjectHandle, serial: u32) !void {
    const role = switch (self.role) {
        .popup => |value| value,
        else => return error.NotPopup,
    };
    try protocol.xdg_popup_types.requests.grab(
        self.client.connectionPtr(),
        role.popup,
        seat,
        serial,
    );
    try self.client.flush();
}

pub fn setPopupKeyboardFocus(self: *Window, focused: bool) !void {
    if (self.layer_keyboard_interactivity != .none) return;
    const role = switch (self.role) {
        .layer => |value| value,
        else => return,
    };
    try protocol.zwlr_layer_surface_v1_types.requests.set_keyboard_interactivity(
        self.client.connectionPtr(),
        role,
        @intFromEnum(if (focused)
            protocol.zwlr_layer_surface_v1_types.keyboard_interactivity.exclusive
        else
            protocol.zwlr_layer_surface_v1_types.keyboard_interactivity.none),
    );
    try protocol.wl_surface_types.requests.commit(self.client.connectionPtr(), self.surface);
    try self.client.flush();
}

pub fn repositionPopup(self: *Window, options: wayland_window.PopupOptions, token: u32) !void {
    const role = switch (self.role) {
        .popup => |value| value,
        else => return error.NotPopup,
    };
    const wm_base = self.client.wmBaseHandle() orelse return error.MissingXdgWmBase;
    const positioner = try protocol.xdg_wm_base_types.requests.create_positioner(
        self.client.connectionPtr(),
        wm_base,
    );
    errdefer protocol.xdg_positioner_types.requests.destroy(
        self.client.connectionPtr(),
        positioner,
    ) catch {};
    try configurePopupPositioner(self.client, positioner, options);
    try configurePopupGeometry(self.client, self.surface, role.xdg_surface, options);
    try protocol.xdg_popup_types.requests.reposition(
        self.client.connectionPtr(),
        role.popup,
        positioner,
        token,
    );
    try protocol.xdg_positioner_types.requests.destroy(self.client.connectionPtr(), positioner);
    self.popup_insets = options.insets;
    try self.client.flush();
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
    if (self.fractional_scale != null) return null;
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
        self.surface,
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
    if (self.viewport) |viewport| {
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
    if (self.frame_callback) |callback| {
        try self.client.connectionPtr().retireObject(callback);
        self.frame_callback = null;
    }
    if (self.fractional_scale) |fractional_scale| {
        try protocol.wp_fractional_scale_v1_types.requests.destroy(
            self.client.connectionPtr(),
            fractional_scale,
        );
    }
    if (self.viewport) |viewport| {
        try protocol.wp_viewport_types.requests.destroy(
            self.client.connectionPtr(),
            viewport,
        );
    }
    try self.destroyRole();
    try protocol.wl_surface_types.requests.destroy(
        self.client.connectionPtr(),
        self.surface,
    );
    self.protocol_destroyed = true;
}

fn roleOwnsObject(self: *const Window, id: u32) bool {
    return switch (self.role) {
        .toplevel => |role| id == role.xdg_surface.id or id == role.toplevel.id,
        .popup => |role| id == role.xdg_surface.id or id == role.popup.id,
        .layer => |role| id == role.id,
        .session_lock => |role| id == role.id,
    };
}

fn destroyRole(self: *Window) !void {
    switch (self.role) {
        .toplevel => |role| {
            try protocol.xdg_toplevel_types.requests.destroy(self.client.connectionPtr(), role.toplevel);
            try protocol.xdg_surface_types.requests.destroy(self.client.connectionPtr(), role.xdg_surface);
        },
        .popup => |role| {
            try protocol.xdg_popup_types.requests.destroy(self.client.connectionPtr(), role.popup);
            try protocol.xdg_surface_types.requests.destroy(self.client.connectionPtr(), role.xdg_surface);
        },
        .layer => |role| try protocol.zwlr_layer_surface_v1_types.requests.destroy(
            self.client.connectionPtr(),
            role,
        ),
        .session_lock => |role| try protocol.ext_session_lock_surface_v1_types.requests.destroy(
            self.client.connectionPtr(),
            role,
        ),
    }
}

fn setEmptyInputRegion(client: *Client, surface: wayring.ObjectHandle) !void {
    const compositor = client.compositorHandle() orelse return error.MissingCompositor;
    const region = try protocol.wl_compositor_types.requests.create_region(
        client.connectionPtr(),
        compositor,
    );
    errdefer protocol.wl_region_types.requests.destroy(client.connectionPtr(), region) catch {};
    try protocol.wl_surface_types.requests.set_input_region(
        client.connectionPtr(),
        surface,
        region,
    );
    try protocol.wl_region_types.requests.destroy(client.connectionPtr(), region);
}

fn layer(value: wayland_options.LayerShellOptions.Layer) protocol.zwlr_layer_shell_v1_types.layer {
    return switch (value) {
        .background => .background,
        .bottom => .bottom,
        .top => .top,
        .overlay => .overlay,
    };
}

fn layerAnchor(value: wayland_options.LayerShellOptions.AnchorSet) u32 {
    const anchor = protocol.zwlr_layer_surface_v1_types.anchor;
    var result: u32 = 0;
    if (value.top) result |= anchor.top;
    if (value.bottom) result |= anchor.bottom;
    if (value.left) result |= anchor.left;
    if (value.right) result |= anchor.right;
    return result;
}

fn keyboardInteractivity(
    value: wayland_options.LayerShellOptions.KeyboardInteractivity,
) protocol.zwlr_layer_surface_v1_types.keyboard_interactivity {
    return switch (value) {
        .none => .none,
        .exclusive => .exclusive,
        .on_demand => .on_demand,
    };
}

fn configurePopupPositioner(
    client: *Client,
    positioner: wayring.ObjectHandle,
    options: wayland_window.PopupOptions,
) !void {
    const connection = client.connectionPtr();
    try protocol.xdg_positioner_types.requests.set_size(
        connection,
        positioner,
        @intCast(options.width),
        @intCast(options.height),
    );
    try protocol.xdg_positioner_types.requests.set_anchor_rect(
        connection,
        positioner,
        options.anchor_x,
        options.anchor_y,
        @max(options.anchor_width, 1),
        @max(options.anchor_height, 1),
    );
    try protocol.xdg_positioner_types.requests.set_anchor(
        connection,
        positioner,
        @intFromEnum(popupAnchor(options.edge, options.alignment)),
    );
    try protocol.xdg_positioner_types.requests.set_gravity(
        connection,
        positioner,
        @intFromEnum(popupGravity(options.edge, options.alignment)),
    );
    const adjustment = protocol.xdg_positioner_types.constraint_adjustment;
    try protocol.xdg_positioner_types.requests.set_constraint_adjustment(
        connection,
        positioner,
        adjustment.slide_x | adjustment.slide_y | adjustment.flip_x | adjustment.flip_y,
    );
    const offset = popupOffset(options.edge, options.gap);
    try protocol.xdg_positioner_types.requests.set_offset(
        connection,
        positioner,
        offset.x,
        offset.y,
    );
}

fn configurePopupGeometry(
    client: *Client,
    surface: wayring.ObjectHandle,
    xdg_surface: wayring.ObjectHandle,
    options: wayland_window.PopupOptions,
) !void {
    const left: i32 = @intCast(options.insets.left);
    const top: i32 = @intCast(options.insets.top);
    const width: i32 = @intCast(options.width);
    const height: i32 = @intCast(options.height);
    try protocol.xdg_surface_types.requests.set_window_geometry(
        client.connectionPtr(),
        xdg_surface,
        left,
        top,
        width,
        height,
    );
    const compositor = client.compositorHandle() orelse return error.MissingCompositor;
    const region = try protocol.wl_compositor_types.requests.create_region(
        client.connectionPtr(),
        compositor,
    );
    errdefer protocol.wl_region_types.requests.destroy(client.connectionPtr(), region) catch {};
    try protocol.wl_region_types.requests.add(
        client.connectionPtr(),
        region,
        left,
        top,
        width,
        height,
    );
    try protocol.wl_surface_types.requests.set_input_region(
        client.connectionPtr(),
        surface,
        region,
    );
    try protocol.wl_region_types.requests.destroy(client.connectionPtr(), region);
}

fn popupAnchor(
    edge: keywork.Widget.PopupPlacement.Edge,
    alignment: keywork.Widget.Alignment,
) protocol.xdg_positioner_types.anchor {
    return switch (edge) {
        .bottom => switch (alignment) {
            .start => .bottom_left,
            .center => .bottom,
            .end => .bottom_right,
        },
        .top => switch (alignment) {
            .start => .top_left,
            .center => .top,
            .end => .top_right,
        },
        .right => switch (alignment) {
            .start => .top_right,
            .center => .right,
            .end => .bottom_right,
        },
        .left => switch (alignment) {
            .start => .top_left,
            .center => .left,
            .end => .bottom_left,
        },
    };
}

fn popupGravity(
    edge: keywork.Widget.PopupPlacement.Edge,
    alignment: keywork.Widget.Alignment,
) protocol.xdg_positioner_types.gravity {
    return switch (edge) {
        .bottom => switch (alignment) {
            .start => .bottom_right,
            .center => .bottom,
            .end => .bottom_left,
        },
        .top => switch (alignment) {
            .start => .top_right,
            .center => .top,
            .end => .top_left,
        },
        .right => switch (alignment) {
            .start => .bottom_right,
            .center => .right,
            .end => .top_right,
        },
        .left => switch (alignment) {
            .start => .bottom_left,
            .center => .left,
            .end => .top_left,
        },
    };
}

fn popupOffset(
    edge: keywork.Widget.PopupPlacement.Edge,
    gap: i32,
) struct { x: i32, y: i32 } {
    return switch (edge) {
        .bottom => .{ .x = 0, .y = gap },
        .top => .{ .x = 0, .y = -gap },
        .right => .{ .x = gap, .y = 0 },
        .left => .{ .x = -gap, .y = 0 },
    };
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
    try std.testing.expectEqual(
        protocol.zwlr_layer_surface_v1_types.anchor.top |
            protocol.zwlr_layer_surface_v1_types.anchor.left,
        layerAnchor(.{ .top = true, .left = true }),
    );
    try std.testing.expectEqual(
        protocol.xdg_positioner_types.anchor.bottom_right,
        popupAnchor(.bottom, .end),
    );
    const expected_offset: @TypeOf(popupOffset(.left, 8)) = .{ .x = -8, .y = 0 };
    try std.testing.expectEqualDeep(expected_offset, popupOffset(.left, 8));
}
