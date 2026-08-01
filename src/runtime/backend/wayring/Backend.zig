//! Stable-address Wayring client, XDG window, and io_uring lifecycle owner.

const Backend = @This();

const std = @import("std");
const keywork_loop = @import("keywork-loop");
const keywork = @import("keywork-ui");
const wayring = @import("wayring");
const protocol = @import("wayring-protocols");
const wayring_transport = @import("wayring-uring");
const Client = @import("Client.zig");
const Clipboard = @import("Clipboard.zig");
const Input = @import("Input.zig");
const ProtocolWindow = @import("Window.zig");
const wayland_options = @import("../wayland/options.zig");
const wayland_window = @import("../wayland/window.zig");

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

pub const WindowOptions = struct {
    title: [:0]const u8 = "Keywork",
    app_id: [:0]const u8 = "dev.keywork.Keywork",
    width: u31 = 640,
    height: u31 = 480,
    decorations: wayland_options.Decorations = .server,
    layer_shell: ?wayland_options.LayerShellOptions = null,
    background_blur: bool = false,
    output: ?wayring.ObjectHandle = null,
    session_lock: ?*SessionLock = null,
};

pub const SessionLock = struct {
    handle: ?wayring.ObjectHandle,
    sync_callback: ?wayring.ObjectHandle = null,
    state: LockState = .pending,

    const LockState = enum { pending, locked, denied, unlocking, unlocked };
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
        // Wayring currently uses the full logical layer surface as its input
        // and opaque geometry. Content rects only affect the libwayland
        // background-effect integration.
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
owned_loop: ?*IoUringLoop = null,
client: Client,
input: ?Input = null,
clipboard: ?Clipboard = null,
session_lock: ?SessionLock = null,
windows: std.ArrayList(*Window) = .empty,
main_window: ?*Window = null,
options: Options,
event_context: *anyopaque,
event_notify: EventNotify,
auto_window: bool = true,
outputs_changed_context: ?*anyopaque = null,
outputs_changed_handler: ?*const fn (*anyopaque) void = null,
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
    return self.initConnection(
        allocator,
        path,
        loop,
        options,
        event_context,
        event_notify,
        true,
    );
}

fn initConnection(
    self: *Backend,
    allocator: std.mem.Allocator,
    path: []const u8,
    loop: *IoUringLoop,
    options: Options,
    event_context: *anyopaque,
    event_notify: EventNotify,
    auto_window: bool,
) !void {
    if (options.width == 0 or options.height == 0) return error.EmptyWindow;
    self.* = .{
        .allocator = allocator,
        .loop = loop,
        .client = undefined,
        .options = options,
        .event_context = event_context,
        .event_notify = event_notify,
        .auto_window = auto_window,
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

/// Creates a managed Wayring connection with an internally owned io_uring.
/// Windows are created explicitly through `createWindow`.
pub fn create(allocator: std.mem.Allocator) !*Backend {
    const display = processEnvironment("WAYLAND_DISPLAY") orelse "wayland-0";
    const socket_path = try wayring_transport.waylandSocketPathFrom(
        allocator,
        processEnvironment("XDG_RUNTIME_DIR"),
        display,
    );
    defer allocator.free(socket_path);

    const loop = try allocator.create(IoUringLoop);
    errdefer allocator.destroy(loop);
    loop.* = try IoUringLoop.init(allocator);
    errdefer loop.deinit();

    const self = try allocator.create(Backend);
    errdefer allocator.destroy(self);
    try self.initConnection(
        allocator,
        socket_path,
        loop,
        .{},
        self,
        noopEvent,
        false,
    );
    self.owned_loop = loop;
    errdefer {
        self.beginClose() catch {};
        while (!self.readyToDeinit() and loop.hasActiveOperations()) self.runOnce() catch break;
        if (self.readyToDeinit()) self.deinit();
    }
    try self.waitConfigured();
    return self;
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
    try self.closeSessionLock();
    var index = self.windows.items.len;
    while (index > 0) {
        index -= 1;
        try self.windows.items[index].protocol.beginClose();
    }
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

pub fn destroy(self: *Backend) void {
    const allocator = self.allocator;
    const loop = self.owned_loop orelse @panic("destroy requires Backend.create");
    self.beginClose() catch {};
    while (!self.readyToDeinit() and loop.hasActiveOperations()) self.runOnce() catch break;
    std.debug.assert(self.readyToDeinit());
    while (loop.hasActiveOperations()) loop.runOnce() catch break;
    self.deinit();
    loop.deinit();
    allocator.destroy(loop);
    allocator.destroy(self);
}

pub fn createWindow(self: *Backend, window_options: WindowOptions) !*Window {
    if (self.state != .running) return error.ConnectionNotReady;
    if (window_options.session_lock) |lock| {
        if (self.sessionLockHandle() != lock) return error.ForeignSessionLock;
        const handle = lock.handle orelse return error.SessionLockFinished;
        const output = window_options.output orelse return error.SessionLockRequiresOutput;
        try self.windows.ensureUnusedCapacity(self.allocator, 1);
        const window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(window);
        window.* = .{
            .backend = self,
            .protocol = try ProtocolWindow.initSessionLock(
                self.allocator,
                &self.client,
                handle,
                output,
                window_options.width,
                window_options.height,
            ),
        };
        self.windows.appendAssumeCapacity(window);
        return window;
    }
    if (window_options.layer_shell) |layer_options| {
        try self.windows.ensureUnusedCapacity(self.allocator, 1);
        const window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(window);
        window.* = .{
            .backend = self,
            .protocol = try ProtocolWindow.initLayer(
                self.allocator,
                &self.client,
                layer_options,
                window_options.output,
                window_options.width,
                window_options.height,
            ),
        };
        self.windows.appendAssumeCapacity(window);
        return window;
    }
    return self.createXdgWindow(.{
        .title = window_options.title,
        .app_id = window_options.app_id,
        .width = window_options.width,
        .height = window_options.height,
    });
}

pub fn destroyWindow(self: *Backend, window: *Window) void {
    window.pointer_button_handler = null;
    window.pointer_move_handler = null;
    window.cursor_shape_handler = null;
    window.key_handler = null;
    window.scroll_handler = null;
    window.repaint_handler = null;
    window.frame_handler = null;
    window.protocol.beginClose() catch return;
    while (!window.protocol.readyToDeinit() and self.loop.hasActiveOperations()) self.runOnce() catch break;
    if (!window.protocol.readyToDeinit()) return;
    self.removeWindow(window);
}

pub fn waitForConfigured(self: *Backend, window: *Window) !void {
    while (!window.protocol.isConfigured() and !window.protocol.isClosed() and !self.sessionLockFinished()) {
        if (!self.loop.hasActiveOperations()) return error.ConnectionStopped;
        try self.runOnce();
    }
    if (self.sessionLockFinished()) return error.SessionLockFinished;
    if (window.protocol.isClosed()) return error.WindowClosed;
}

pub fn waitForConfigureAfter(self: *Backend, window: *Window, generation: u64) !void {
    while (window.protocol.configureGeneration() == generation and !window.protocol.isClosed() and !self.sessionLockFinished()) {
        if (!self.loop.hasActiveOperations()) return error.ConnectionStopped;
        try self.runOnce();
    }
    if (self.sessionLockFinished()) return error.SessionLockFinished;
    if (window.protocol.isClosed()) return error.WindowClosed;
}

pub fn outputCount(self: *const Backend) usize {
    return self.client.outputCount();
}

pub fn outputAt(self: *const Backend, index: usize) wayring.ObjectHandle {
    return self.client.outputAt(index);
}

pub fn outputInfoAt(self: *const Backend, index: usize) wayland_options.OutputInfo {
    const info = self.client.outputInfoAt(index);
    return .{ .name = info.name, .width = info.width, .height = info.height, .scale = info.scale };
}

pub fn findOutputByName(self: *const Backend, name: []const u8) ?wayring.ObjectHandle {
    return self.client.findOutputByName(name);
}

pub fn setOutputsChangedHandler(
    self: *Backend,
    context: *anyopaque,
    handler: *const fn (*anyopaque) void,
) void {
    self.outputs_changed_context = context;
    self.outputs_changed_handler = handler;
}

pub fn ioLoop(self: *Backend) *IoUringLoop {
    return self.loop;
}

pub fn beginSessionLock(self: *Backend) !void {
    if (self.session_lock != null) return error.SessionLockAlreadyStarted;
    const manager = self.client.sessionLockManager() orelse return error.NoSessionLock;
    const handle = try protocol.ext_session_lock_manager_v1_types.requests.lock(
        self.client.connectionPtr(),
        manager,
    );
    self.session_lock = .{ .handle = handle };
    try self.client.flush();
}

pub fn sessionLockHandle(self: *Backend) ?*SessionLock {
    return if (self.session_lock) |*lock| lock else null;
}

pub fn sessionLockFinished(self: *const Backend) bool {
    return if (self.session_lock) |lock|
        lock.state == .denied or lock.state == .unlocked
    else
        false;
}

pub fn sessionLockDenied(self: *const Backend) bool {
    return if (self.session_lock) |lock| lock.state == .denied else false;
}

pub fn sessionLocked(self: *const Backend) bool {
    return if (self.session_lock) |lock| lock.state == .locked else false;
}

pub fn unlockSession(self: *Backend) !void {
    const lock = if (self.session_lock) |*value| value else return error.NoSessionLock;
    if (lock.state != .locked) return error.SessionNotLocked;
    try self.beginSessionUnlock(lock);
}

pub fn createPopup(
    self: *Backend,
    parent: *Window,
    popup_options: wayland_window.PopupOptions,
) !*Window {
    try self.windows.ensureUnusedCapacity(self.allocator, 1);
    const window = try self.allocator.create(Window);
    errdefer self.allocator.destroy(window);
    window.* = .{
        .backend = self,
        .protocol = try ProtocolWindow.initPopup(
            self.allocator,
            &self.client,
            &parent.protocol,
            popup_options,
        ),
    };
    if (self.input) |*input| if (input.lastButtonPressSerial()) |serial| {
        window.protocol.grabPopup(input.seatHandle(), serial) catch |err| {
            window.protocol.beginClose() catch {};
            window.protocol.deinit();
            return err;
        };
    };
    self.windows.appendAssumeCapacity(window);
    return window;
}

pub fn setPopupKeyboardFocus(_: *Backend, window: *Window, focused: bool) void {
    window.protocol.setPopupKeyboardFocus(focused) catch {};
}

pub fn repositionPopup(
    _: *Backend,
    window: *Window,
    popup_options: wayland_window.PopupOptions,
    token: u32,
) !void {
    try window.protocol.repositionPopup(popup_options, token);
}

pub fn requestLayerSize(_: *Backend, window: *Window, width: u31, height: u31) !void {
    try window.protocol.requestLayerSize(width, height);
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
            if (self.auto_window) {
                self.main_window = try self.createXdgWindow(self.options);
                self.state = .configuring;
            } else {
                self.state = .running;
            }
        },
        .outputs_changed => {
            for (self.windows.items) |window| {
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
            }
            if (self.outputs_changed_handler) |handler| handler(self.outputs_changed_context.?);
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
    if (try self.handleSessionLockMessage(message)) {
        if (self.state == .closing) try self.advanceClose();
        return;
    }
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
    if (self.session_lock) |lock| {
        if (lock.state != .denied and lock.state != .unlocked) return;
    }
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

fn handleSessionLockMessage(self: *Backend, message: *wayring.Message) !bool {
    const lock = if (self.session_lock) |*value| value else return false;
    if (lock.handle) |handle| {
        if (message.object_id == handle.id) {
            switch (try protocol.ext_session_lock_v1_types.decodeEvent(
                self.client.connectionPtr(),
                handle,
                message,
            )) {
                .locked => {
                    lock.state = .locked;
                    if (self.state == .closing) try self.beginSessionUnlock(lock);
                },
                .finished => if (lock.state == .locked) {
                    try self.beginSessionUnlock(lock);
                } else {
                    try protocol.ext_session_lock_v1_types.requests.destroy(
                        self.client.connectionPtr(),
                        handle,
                    );
                    lock.handle = null;
                    lock.state = .denied;
                    try self.client.flush();
                },
            }
            return true;
        }
    }
    if (lock.sync_callback) |callback| {
        if (message.object_id == callback.id) {
            _ = try protocol.wl_callback_types.decodeEvent(
                self.client.connectionPtr(),
                callback,
                message,
            );
            lock.sync_callback = null;
            lock.state = .unlocked;
            return true;
        }
    }
    return false;
}

fn beginSessionUnlock(self: *Backend, lock: *SessionLock) !void {
    const handle = lock.handle orelse return error.SessionLockFinished;
    try protocol.ext_session_lock_v1_types.requests.unlock_and_destroy(
        self.client.connectionPtr(),
        handle,
    );
    lock.handle = null;
    lock.state = .unlocking;
    lock.sync_callback = protocol.wl_display_types.requests.sync(
        self.client.connectionPtr(),
        self.client.displayHandle(),
    ) catch {
        try self.client.flush();
        lock.state = .unlocked;
        return;
    };
    try self.client.flush();
}

fn closeSessionLock(self: *Backend) !void {
    const lock = if (self.session_lock) |*value| value else return;
    switch (lock.state) {
        // Destroying a pending lock races an in-flight `locked` event and can
        // leave the session locked without a client able to unlock it. Wait
        // for either `locked` or `finished` and handle that event above.
        .pending => {},
        .locked => try self.beginSessionUnlock(lock),
        .denied, .unlocking, .unlocked => {},
    }
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

fn removeWindow(self: *Backend, window: *Window) void {
    for (self.windows.items, 0..) |candidate, index| {
        if (candidate != window) continue;
        _ = self.windows.orderedRemove(index);
        break;
    }
    if (self.main_window == window) self.main_window = null;
    window.protocol.deinit();
    self.allocator.destroy(window);
}

fn processEnvironment(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn noopEvent(_: *anyopaque, _: *Backend, _: Event) !void {}

test {
    std.testing.refAllDecls(Backend);
}
