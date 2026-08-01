//! Stable-address Wayring client, XDG window, and io_uring lifecycle owner.

const Backend = @This();

const std = @import("std");
const keywork_loop = @import("keywork-loop");
const keywork = @import("keywork-ui");
const wayring = @import("wayring");
const Client = @import("Client.zig");
const Input = @import("Input.zig");
const Window = @import("Window.zig");

const IoUringLoop = keywork_loop.IoUringLoop;

pub const State = enum { connecting, configuring, running, closing, closed, disconnected, fatal };
pub const Size = struct { width: u32, height: u32 };
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

allocator: std.mem.Allocator,
loop: *IoUringLoop,
client: Client,
input: ?Input = null,
window: ?Window = null,
options: Options,
event_context: *anyopaque,
event_notify: EventNotify,
state: State = .connecting,
shutdown_started: bool = false,

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

pub fn beginClose(self: *Backend) !void {
    switch (self.state) {
        .closed, .disconnected, .fatal => return,
        .closing => return self.advanceClose(),
        else => {},
    }
    self.state = .closing;
    if (self.window) |*window| try window.beginClose();
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
    if (self.window) |*window| window.deinit();
    if (self.input) |*input| input.deinit();
    self.client.deinit();
    self.* = undefined;
}

pub fn renderBackend(self: *Backend) !keywork.RenderBackend {
    const window = if (self.window) |*value| value else return error.WindowNotReady;
    return window.renderBackend();
}

pub fn currentSize(self: *const Backend) !Size {
    const window = if (self.window) |*value| value else return error.WindowNotReady;
    const size = window.size();
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
                var input: Input = undefined;
                try input.init(
                    self.client.connectionPtr(),
                    seat,
                    self.client.cursorShapeManager(),
                    self,
                    inputEvent,
                );
                self.input = input;
            }
            self.window = try Window.init(
                self.allocator,
                &self.client,
                self.options.title,
                self.options.app_id,
                self.options.width,
                self.options.height,
            );
            if (self.input) |*input| input.setSurface(self.window.?.surfaceId());
            self.state = .configuring;
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
    if (self.input) |*input| {
        if (input.ownsObject(message.object_id)) {
            try input.handleMessage(message);
            try self.client.flush();
            return;
        }
    }
    const window = if (self.window) |*value| value else return error.MessageBeforeWindow;
    const event = try window.handleMessage(message) orelse {
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
            const size = window.size();
            try self.event_notify(self.event_context, self, .{ .configured = .{
                .width = size.width,
                .height = size.height,
            } });
        },
        .repaint => try self.event_notify(self.event_context, self, .repaint),
        .close => {
            try self.event_notify(self.event_context, self, .close);
            try self.beginClose();
        },
    }
    if (self.state == .closing) try self.advanceClose();
}

fn inputEvent(context: *anyopaque, _: *Input, event: Input.Event) !void {
    const self: *Backend = @ptrCast(@alignCast(context));
    try self.event_notify(self.event_context, self, switch (event) {
        .pointer_move => |value| .{ .pointer_move = value },
        .pointer_button => |value| .{ .pointer_button = value },
        .scroll => |value| .{ .scroll = value },
        .key => |value| .{ .key = value },
    });
}

fn advanceClose(self: *Backend) !void {
    const window_done = if (self.window) |*window| window.readyToDeinit() else true;
    if (window_done) try self.startTransportShutdown();
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

test {
    std.testing.refAllDecls(Backend);
}
