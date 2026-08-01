//! Stable-address Wayring client, XDG window, and io_uring lifecycle owner.

const Backend = @This();

const std = @import("std");
const keywork_loop = @import("keywork-loop");
const keywork = @import("keywork-ui");
const wayring = @import("wayring");
const protocol = @import("wayring-protocols");
const Client = @import("Client.zig");
const Clipboard = @import("Clipboard.zig");
const Input = @import("Input.zig");
const ProtocolWindow = @import("Window.zig");

const IoUringLoop = keywork_loop.IoUringLoop;

pub const State = enum { connecting, configuring, running, closing, closed, disconnected, fatal };
pub const Size = struct { width: u32, height: u32 };
pub const ResizeEdge = ProtocolWindow.ResizeEdge;
pub const PointerButtonHandler = *const fn (context: *anyopaque, event: keywork.PointerButtonEvent) void;
pub const PointerMoveHandler = *const fn (context: *anyopaque, point: ?keywork.Point) void;
pub const CursorShapeHandler = *const fn (context: *anyopaque, point: keywork.Point) keywork.CursorShape;
pub const KeyHandler = *const fn (context: *anyopaque, input: keywork.KeyInput) void;
pub const ScrollHandler = *const fn (context: *anyopaque, event: keywork.ScrollEvent) void;
pub const RepaintHandler = *const fn (context: *anyopaque, size: keywork.Size) void;
pub const FrameHandler = *const fn (context: *anyopaque) void;
pub const Event = union(enum) {
    configured: Size,
    repaint,
    close,
    disconnected,
    fatal,
    pointer_move: ?keywork.Point,
    pointer_button: keywork.PointerButtonEvent,
    scroll: keywork.ScrollEvent,
    key: keywork.KeyInput,
};
pub const EventNotify = *const fn (context: *anyopaque, backend: *Backend, event: Event) anyerror!void;

pub const Options = struct {
    title: []const u8 = "Keywork",
    app_id: []const u8 = "dev.keywork.Keywork",
    width: u32 = 640,
    height: u32 = 480,
};

const ActivationRequest = struct {
    handle: wayring.ObjectHandle,
    allocator: std.mem.Allocator,
    token: ?[]u8 = null,
    done: bool = false,
};

pub const Window = struct {
    backend: *Backend,
    protocol: ProtocolWindow,
    pointer_button_context: ?*anyopaque = null,
    pointer_button_handler: ?PointerButtonHandler = null,
    pointer_move_context: ?*anyopaque = null,
    pointer_move_handler: ?PointerMoveHandler = null,
    cursor_shape_context: ?*anyopaque = null,
    cursor_shape_handler: ?CursorShapeHandler = null,
    key_context: ?*anyopaque = null,
    key_handler: ?KeyHandler = null,
    scroll_context: ?*anyopaque = null,
    scroll_handler: ?ScrollHandler = null,
    repaint_context: ?*anyopaque = null,
    repaint_handler: ?RepaintHandler = null,
    frame_context: ?*anyopaque = null,
    frame_handler: ?FrameHandler = null,
    cursor_update_pending: bool = false,
    cursor_point: ?keywork.Point = null,

    pub fn renderBackend(self: *Window) keywork.RenderBackend {
        return self.protocol.renderBackend();
    }

    pub fn currentSize(self: *const Window) keywork.Size {
        const size = self.protocol.size();
        return .{ .width = @floatFromInt(size.width), .height = @floatFromInt(size.height) };
    }

    pub fn configureGeneration(self: *const Window) u64 {
        return self.protocol.configureGeneration();
    }

    pub fn isClosed(self: *const Window) bool {
        return self.protocol.isClosed();
    }

    pub fn suspendedOpaque(_: *anyopaque) bool {
        return false;
    }

    pub fn setPointerButtonHandler(self: *Window, context: *anyopaque, handler: PointerButtonHandler) void {
        self.pointer_button_context = context;
        self.pointer_button_handler = handler;
    }

    pub fn setPointerMoveHandler(self: *Window, context: *anyopaque, handler: PointerMoveHandler) void {
        self.pointer_move_context = context;
        self.pointer_move_handler = handler;
    }

    pub fn setCursorShapeHandler(self: *Window, context: *anyopaque, handler: CursorShapeHandler) void {
        self.cursor_shape_context = context;
        self.cursor_shape_handler = handler;
    }

    pub fn setKeyHandler(self: *Window, context: *anyopaque, handler: KeyHandler) void {
        self.key_context = context;
        self.key_handler = handler;
    }

    pub fn setScrollHandler(self: *Window, context: *anyopaque, handler: ScrollHandler) void {
        self.scroll_context = context;
        self.scroll_handler = handler;
    }

    pub fn setRepaintHandler(self: *Window, context: *anyopaque, handler: RepaintHandler) void {
        self.repaint_context = context;
        self.repaint_handler = handler;
    }

    pub fn setFrameHandler(self: *Window, context: *anyopaque, handler: FrameHandler) void {
        self.frame_context = context;
        self.frame_handler = handler;
    }

    pub fn setLayerContentRect(_: *Window, _: u31, _: u31, _: keywork.Rect) !void {
        return error.NotLayerSurface;
    }

    fn updateCursor(self: *Window) !void {
        if (!self.cursor_update_pending) return;
        self.cursor_update_pending = false;
        const point = self.cursor_point orelse return;
        const handler = self.cursor_shape_handler orelse return;
        const input = if (self.backend.input) |*value| value else return;
        try input.setCursorShape(handler(self.cursor_shape_context.?, point));
        try self.backend.client.flush();
    }
};

allocator: std.mem.Allocator,
loop: *IoUringLoop,
client: Client,
input: ?Input = null,
clipboard: ?Clipboard = null,
windows: std.ArrayList(*Window) = .empty,
main_window: ?*Window = null,
options: Options,
event_context: *anyopaque,
event_notify: EventNotify,
state: State = .connecting,
shutdown_started: bool = false,
activation_request: ?ActivationRequest = null,

/// The backend and `loop` must remain at stable addresses until `deinit`.
pub fn initConnect(
    self: *Backend,
    allocator: std.mem.Allocator,
    path: []const u8,
    loop: *IoUringLoop,
    options: Options,
    event_context: *anyopaque,
    event_notify: EventNotify,
) !void {
    if (options.width == 0 or options.height == 0) return error.EmptyWindow;
    self.* = .{
        .allocator = allocator,
        .loop = loop,
        .client = undefined,
        .options = options,
        .event_context = event_context,
        .event_notify = event_notify,
    };
    try self.client.initConnect(
        allocator,
        path,
        loop,
        self,
        clientNotify,
        clientMessage,
    );
    try self.client.flush();
}

/// Drives bootstrap with the same submit/wait/drain turns used at runtime.
pub fn waitConfigured(self: *Backend) !void {
    while (self.state == .connecting or self.state == .configuring) {
        if (!self.loop.hasActiveOperations()) return error.ConnectionStopped;
        try self.loop.runOnce();
    }
    return switch (self.state) {
        .running => {},
        .disconnected => error.WaylandDisconnected,
        .fatal => error.WaylandTransportFailed,
        else => error.WindowClosed,
    };
}

pub fn runOnce(self: *Backend) !void {
    if (!self.loop.hasActiveOperations()) {
        self.updateClosed();
        return;
    }
    try self.loop.runOnce();
    self.updateClosed();
}

/// Runs deferred application-facing work after a completion turn has fully
/// drained. CQ callbacks may enqueue handlers but never call into a runtime.
pub fn drainDeferred(self: *Backend) !void {
    for (self.windows.items) |window| try window.updateCursor();
}

pub fn beginClose(self: *Backend) !void {
    switch (self.state) {
        .closed, .disconnected, .fatal => return,
        .closing => return self.advanceClose(),
        else => {},
    }
    self.state = .closing;
    for (self.windows.items) |window| try window.protocol.beginClose();
    try self.advanceClose();
}

pub fn runUntilClosed(self: *Backend) !void {
    try self.beginClose();
    while (!self.readyToDeinit()) {
        if (!self.loop.hasActiveOperations()) return error.ShutdownStopped;
        try self.runOnce();
    }
}

pub fn readyToDeinit(self: *Backend) bool {
    if (!self.client.readyToDeinit()) return false;
    return switch (self.state) {
        .closed, .disconnected, .fatal => true,
        else => false,
    };
}

pub fn deinit(self: *Backend) void {
    std.debug.assert(self.readyToDeinit());
    for (self.windows.items) |window| {
        window.protocol.deinit();
        self.allocator.destroy(window);
    }
    self.windows.deinit(self.allocator);
    if (self.clipboard) |*clipboard| clipboard.deinit();
    if (self.input) |*input| input.deinit();
    if (self.activation_request) |request| if (request.token) |token|
        request.allocator.free(token);
    self.client.deinit();
    self.* = undefined;
}

pub fn renderBackend(self: *Backend) !keywork.RenderBackend {
    const window = self.main_window orelse return error.WindowNotReady;
    return window.protocol.renderBackend();
}

pub fn currentSize(self: *const Backend) !Size {
    const window = self.main_window orelse return error.WindowNotReady;
    const size = window.protocol.size();
    return .{ .width = size.width, .height = size.height };
}

pub fn isClosing(self: *const Backend) bool {
    return switch (self.state) {
        .closing, .closed, .disconnected, .fatal => true,
        else => false,
    };
}

pub fn setCursorShape(self: *Backend, shape: keywork.CursorShape) !void {
    if (self.input) |*input| {
        try input.setCursorShape(shape);
        try self.client.flush();
    }
}

pub fn clipboardRead(self: *Backend, allocator: std.mem.Allocator) !?[]u8 {
    const clipboard = if (self.clipboard) |*value| value else return null;
    return clipboard.read(allocator);
}

pub fn clipboardWrite(self: *Backend, text: []const u8) !void {
    const clipboard = if (self.clipboard) |*value| value else return error.ClipboardUnavailable;
    const input = if (self.input) |*value| value else return error.NoInputSerial;
    const serial = input.lastInputSerial() orelse return error.NoInputSerial;
    try clipboard.write(text, serial);
}

pub fn startMove(self: *Backend) !void {
    const input = if (self.input) |*value| value else return error.NoSeat;
    const serial = input.lastButtonPressSerial() orelse return error.NoRecentPress;
    const surface_id = input.lastButtonPressSurfaceId() orelse return error.NoRecentPress;
    const window = self.findWindowBySurfaceId(surface_id) orelse return error.WindowNotReady;
    try window.protocol.startMove(input.seatHandle(), serial);
}

pub fn startResize(self: *Backend, edge: ResizeEdge) !void {
    const input = if (self.input) |*value| value else return error.NoSeat;
    const serial = input.lastButtonPressSerial() orelse return error.NoRecentPress;
    const surface_id = input.lastButtonPressSurfaceId() orelse return error.NoRecentPress;
    const window = self.findWindowBySurfaceId(surface_id) orelse return error.WindowNotReady;
    try window.protocol.startResize(input.seatHandle(), serial, edge);
}

/// Requests an xdg-activation token while continuing to drain completion
/// events. User callbacks are queued by the runner, so this does not re-enter
/// application code while waiting for the compositor's reply.
pub fn activationToken(
    self: *Backend,
    allocator: std.mem.Allocator,
    app_id: ?[*:0]const u8,
) !?[]u8 {
    const manager = self.client.activationManager() orelse return null;
    if (self.activation_request != null) return error.ActivationRequestPending;
    const token_handle = try protocol.xdg_activation_v1_types.requests.get_activation_token(
        self.client.connectionPtr(),
        manager,
    );
    self.activation_request = .{ .handle = token_handle, .allocator = allocator };
    errdefer self.cancelActivationRequest();

    if (self.input) |*input| if (input.lastInputSerial()) |serial| {
        try protocol.xdg_activation_token_v1_types.requests.set_serial(
            self.client.connectionPtr(),
            token_handle,
            serial,
            input.seatHandle(),
        );
    };
    const activation_window = if (self.input) |*input|
        if (input.keyboardSurfaceId()) |surface_id|
            self.findWindowBySurfaceId(surface_id) orelse self.main_window
        else
            self.main_window
    else
        self.main_window;
    if (activation_window) |window| try protocol.xdg_activation_token_v1_types.requests.set_surface(
        self.client.connectionPtr(),
        token_handle,
        window.protocol.surfaceHandle(),
    );
    if (app_id) |value| try protocol.xdg_activation_token_v1_types.requests.set_app_id(
        self.client.connectionPtr(),
        token_handle,
        std.mem.span(value),
    );
    try protocol.xdg_activation_token_v1_types.requests.commit(
        self.client.connectionPtr(),
        token_handle,
    );
    try self.client.flush();

    while (!self.activation_request.?.done) {
        switch (self.state) {
            .disconnected => return error.WaylandDisconnected,
            .fatal => return error.WaylandTransportFailed,
            .closing, .closed => return error.WindowClosed,
            else => {},
        }
        if (!self.loop.hasActiveOperations()) return error.ConnectionStopped;
        try self.runOnce();
    }
    const token = self.activation_request.?.token;
    self.activation_request = null;
    return token;
}

pub fn installEventTimers(self: *Backend, loop: *keywork_loop.EventLoop) !void {
    if (self.input) |*input| try input.installEventTimer(loop);
}

pub fn uninstallEventTimers(self: *Backend) void {
    if (self.input) |*input| input.uninstallEventTimer();
}

fn clientNotify(context: *anyopaque, _: *Client, notification: Client.Notification) !void {
    const self: *Backend = @ptrCast(@alignCast(context));
    switch (notification) {
        .ready => {
            if (self.state != .connecting) return error.UnexpectedClientReady;
            if (self.client.takeSeat()) |seat| {
                if (self.client.dataDeviceManager()) |manager| {
                    self.clipboard = try Clipboard.init(
                        self.allocator,
                        &self.client,
                        manager,
                        seat.handle,
                    );
                }
                var input: Input = undefined;
                try input.init(
                    self.allocator,
                    self.client.connectionPtr(),
                    seat,
                    self.client.compositorHandle(),
                    self.client.shmHandle(),
                    self.client.cursorShapeManager(),
                    self,
                    inputEvent,
                );
                self.input = input;
            }
            self.main_window = try self.createXdgWindow(self.options);
            self.state = .configuring;
        },
        .outputs_changed => for (self.windows.items) |window| {
            if (try window.protocol.outputScaleChanged()) |_| {
                if (self.input) |*input| if (input.pointerSurfaceId() == window.protocol.surfaceId())
                    try input.setCursorScale(window.protocol.cursorScale());
                const size = window.protocol.size();
                const logical_size: keywork.Size = .{
                    .width = @floatFromInt(size.width),
                    .height = @floatFromInt(size.height),
                };
                if (window.repaint_handler) |handler| handler(window.repaint_context.?, logical_size);
                if (window == self.main_window) try self.event_notify(self.event_context, self, .{ .configured = .{
                    .width = size.width,
                    .height = size.height,
                } });
            }
        },
        .eof => {
            self.state = .disconnected;
            try self.startTransportShutdown();
            try self.event_notify(self.event_context, self, .disconnected);
        },
        .fatal => {
            self.state = .fatal;
            try self.startTransportShutdown();
            try self.event_notify(self.event_context, self, .fatal);
        },
    }
}

fn clientMessage(
    context: *anyopaque,
    _: *Client,
    message: *wayring.Message,
) !void {
    const self: *Backend = @ptrCast(@alignCast(context));
    if (self.activation_request) |request| {
        if (message.object_id == request.handle.id) {
            const done = (try protocol.xdg_activation_token_v1_types.decodeEvent(
                self.client.connectionPtr(),
                request.handle,
                message,
            )).done;
            const token = try request.allocator.dupe(u8, done.token);
            errdefer request.allocator.free(token);
            try protocol.xdg_activation_token_v1_types.requests.destroy(
                self.client.connectionPtr(),
                request.handle,
            );
            self.activation_request.?.token = token;
            self.activation_request.?.done = true;
            try self.client.flush();
            return;
        }
    }
    if (self.clipboard) |*clipboard| {
        if (clipboard.ownsObject(message.object_id)) {
            try clipboard.handleMessage(message);
            try self.client.flush();
            return;
        }
    }
    if (self.input) |*input| {
        if (input.ownsObject(message.object_id)) {
            try input.handleMessage(message);
            try self.client.flush();
            return;
        }
    }
    const window = self.findWindowOwningObject(message.object_id) orelse
        return error.MessageBeforeWindow;
    const event = try window.protocol.handleMessage(message) orelse {
        if (self.state == .closing) try self.advanceClose();
        return;
    };
    switch (event) {
        .configured => {
            if (self.state == .closing) {
                try self.advanceClose();
                return;
            }
            self.state = .running;
            if (self.input) |*input| try input.setCursorScale(window.protocol.cursorScale());
            const size = window.protocol.size();
            if (window.repaint_handler) |handler| handler(window.repaint_context.?, .{
                .width = @floatFromInt(size.width),
                .height = @floatFromInt(size.height),
            });
            if (window == self.main_window) try self.event_notify(self.event_context, self, .{ .configured = .{
                .width = size.width,
                .height = size.height,
            } });
        },
        .repaint => {
            if (window.frame_handler) |handler| handler(window.frame_context.?);
            if (window == self.main_window) try self.event_notify(self.event_context, self, .repaint);
        },
        .close => {
            if (window == self.main_window) {
                try self.event_notify(self.event_context, self, .close);
                try self.beginClose();
            }
        },
    }
    if (self.state == .closing) try self.advanceClose();
}

fn inputEvent(context: *anyopaque, _: *Input, event: Input.Event) !void {
    const self: *Backend = @ptrCast(@alignCast(context));
    const window = self.findWindowBySurfaceId(event.surface_id) orelse return;
    switch (event.value) {
        .pointer_move => |value| {
            window.cursor_point = value;
            window.cursor_update_pending = true;
            if (window.pointer_move_handler) |handler| handler(window.pointer_move_context.?, value);
        },
        .pointer_button => |value| if (window.pointer_button_handler) |handler|
            handler(window.pointer_button_context.?, value),
        .scroll => |value| if (window.scroll_handler) |handler| handler(window.scroll_context.?, value),
        .key => |value| if (window.key_handler) |handler| handler(window.key_context.?, value),
    }
    if (window == self.main_window) try self.event_notify(self.event_context, self, switch (event.value) {
        .pointer_move => |value| .{ .pointer_move = value },
        .pointer_button => |value| .{ .pointer_button = value },
        .scroll => |value| .{ .scroll = value },
        .key => |value| .{ .key = value },
    });
}

fn advanceClose(self: *Backend) !void {
    for (self.windows.items) |window| if (!window.protocol.readyToDeinit()) return;
    try self.startTransportShutdown();
    self.updateClosed();
}

fn startTransportShutdown(self: *Backend) !void {
    if (self.shutdown_started) return;
    self.shutdown_started = true;
    try self.client.shutdown();
}

fn updateClosed(self: *Backend) void {
    if (self.state == .closing and self.client.readyToDeinit()) self.state = .closed;
}

fn cancelActivationRequest(self: *Backend) void {
    if (self.activation_request) |request| {
        if (request.token) |token| request.allocator.free(token);
        protocol.xdg_activation_token_v1_types.requests.destroy(
            self.client.connectionPtr(),
            request.handle,
        ) catch {};
    }
    self.activation_request = null;
}

fn createXdgWindow(self: *Backend, window_options: Options) !*Window {
    try self.windows.ensureUnusedCapacity(self.allocator, 1);
    const window = try self.allocator.create(Window);
    errdefer self.allocator.destroy(window);
    window.* = .{
        .backend = self,
        .protocol = try ProtocolWindow.init(
            self.allocator,
            &self.client,
            window_options.title,
            window_options.app_id,
            window_options.width,
            window_options.height,
        ),
    };
    self.windows.appendAssumeCapacity(window);
    return window;
}

fn findWindowBySurfaceId(self: *Backend, surface_id: u32) ?*Window {
    for (self.windows.items) |window| {
        if (window.protocol.surfaceId() == surface_id) return window;
    }
    return null;
}

fn findWindowOwningObject(self: *Backend, object_id: u32) ?*Window {
    for (self.windows.items) |window| {
        if (window.protocol.ownsObject(object_id)) return window;
    }
    return null;
}

test {
    std.testing.refAllDecls(Backend);
}
