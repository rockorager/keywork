//! Desktop platform services bridged from the windowing backend to the
//! embedding application: clipboard, xdg-activation tokens, and
//! compositor-driven interactive move/resize. Bound at runner startup
//! like the invalidator; absent on headless backends.

const std = @import("std");
const wayland_options = @import("../backend/wayland/options.zig");
const wayland_window = @import("../backend/wayland/window.zig");

pub const ResizeEdge = wayland_options.ResizeEdge;

pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Selection text, or null when the clipboard is empty or
        /// non-text. The caller owns the returned slice.
        clipboard_read: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8,
        clipboard_write: *const fn (ptr: *anyopaque, text: []const u8) anyerror!void,
        /// xdg-activation token for passing focus to another client, or
        /// null when the compositor lacks the protocol. The caller owns
        /// the returned slice. `app_id` hints which application will be
        /// activated.
        activation_token: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, app_id: ?[*:0]const u8) anyerror!?[]u8,
        /// Interactive move/resize of the window that received the most
        /// recent pointer press; call from a pointer-press handler.
        start_move: *const fn (ptr: *anyopaque) anyerror!void,
        start_resize: *const fn (ptr: *anyopaque, edge: ResizeEdge) anyerror!void,
    };

    pub fn clipboardRead(self: Platform, allocator: std.mem.Allocator) !?[]u8 {
        return self.vtable.clipboard_read(self.ptr, allocator);
    }

    pub fn clipboardWrite(self: Platform, text: []const u8) !void {
        return self.vtable.clipboard_write(self.ptr, text);
    }

    pub fn activationToken(self: Platform, allocator: std.mem.Allocator, app_id: ?[*:0]const u8) !?[]u8 {
        return self.vtable.activation_token(self.ptr, allocator, app_id);
    }

    pub fn startMove(self: Platform) !void {
        return self.vtable.start_move(self.ptr);
    }

    pub fn startResize(self: Platform, edge: ResizeEdge) !void {
        return self.vtable.start_resize(self.ptr, edge);
    }
};

/// Platform implementation shared by the Wayland backends: `Backend` is
/// `wayland/shm.Backend` or `wayland/vulkan.Backend`, which expose the
/// same `connection`, `input`, `clipboard`, and `Window.input_target`
/// shape.
pub fn WaylandPlatform(comptime Backend: type) type {
    return struct {
        const vtable: Platform.VTable = .{
            .clipboard_read = clipboardRead,
            .clipboard_write = clipboardWrite,
            .activation_token = activationToken,
            .start_move = startMove,
            .start_resize = startResize,
        };

        pub fn platform(backend: *Backend) Platform {
            return .{ .ptr = backend, .vtable = &vtable };
        }

        fn clipboardRead(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
            const backend: *Backend = @ptrCast(@alignCast(ptr));
            const clipboard = backend.clipboard orelse return null;
            return clipboard.read(allocator);
        }

        fn clipboardWrite(ptr: *anyopaque, text: []const u8) anyerror!void {
            const backend: *Backend = @ptrCast(@alignCast(ptr));
            const clipboard = backend.clipboard orelse return error.ClipboardUnavailable;
            // Compositors validate the selection claim against a recent
            // input serial, so writing before any user input fails.
            const serial = backend.input.last_input_serial orelse return error.NoInputSerial;
            try clipboard.write(text, serial);
        }

        fn activationToken(ptr: *anyopaque, allocator: std.mem.Allocator, app_id: ?[*:0]const u8) anyerror!?[]u8 {
            const backend: *Backend = @ptrCast(@alignCast(ptr));
            const surface = if (backend.input.keyboard_target) |target| target.surface else null;
            return wayland_window.requestActivationToken(
                backend.connection,
                allocator,
                backend.input.seat,
                backend.input.last_input_serial,
                surface,
                app_id,
            );
        }

        fn startMove(ptr: *anyopaque) anyerror!void {
            const backend: *Backend = @ptrCast(@alignCast(ptr));
            const win = try lastPressedWindow(backend);
            try win.protocol.startMove(backend.input.seat.?, backend.input.last_button_press_serial.?);
            _ = backend.connection.display.flush();
        }

        fn startResize(ptr: *anyopaque, edge: ResizeEdge) anyerror!void {
            const backend: *Backend = @ptrCast(@alignCast(ptr));
            const win = try lastPressedWindow(backend);
            try win.protocol.startResize(backend.input.seat.?, backend.input.last_button_press_serial.?, edge);
            _ = backend.connection.display.flush();
        }

        /// Interactive move/resize acts on the window the most recent
        /// pointer press landed in, which is the window whose press
        /// handler is calling us.
        fn lastPressedWindow(backend: *Backend) !*Backend.Window {
            if (backend.input.seat == null) return error.NoSeat;
            if (backend.input.last_button_press_serial == null) return error.NoRecentPress;
            const target = backend.input.last_button_press_target orelse return error.NoRecentPress;
            return @fieldParentPtr("input_target", target);
        }
    };
}

/// Parses a resize edge name as used by the Lua API ("top", "bottom_left",
/// "bottom-left", ...).
pub fn resizeEdgeFromName(name: []const u8) ?ResizeEdge {
    var buffer: [16]u8 = undefined;
    if (name.len > buffer.len) return null;
    for (name, 0..) |char, index| {
        buffer[index] = if (char == '-') '_' else char;
    }
    return std.meta.stringToEnum(ResizeEdge, buffer[0..name.len]);
}

test resizeEdgeFromName {
    try std.testing.expectEqual(ResizeEdge.top, resizeEdgeFromName("top").?);
    try std.testing.expectEqual(ResizeEdge.bottom_right, resizeEdgeFromName("bottom_right").?);
    try std.testing.expectEqual(ResizeEdge.bottom_right, resizeEdgeFromName("bottom-right").?);
    try std.testing.expectEqual(@as(?ResizeEdge, null), resizeEdgeFromName("diagonal"));
    try std.testing.expectEqual(@as(?ResizeEdge, null), resizeEdgeFromName("a-very-long-invalid-name"));
}
