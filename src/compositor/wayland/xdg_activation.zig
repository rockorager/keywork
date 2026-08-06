//! Activation-token lifecycle and focus-stealing-prevention boundary.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;

const token_byte_count = 16;
pub const token_character_count = token_byte_count * 2;
const token_lifetime_nanoseconds: i96 = 30 * std.time.ns_per_s;
const expiry_check_milliseconds = 1000;

const Token = struct {
    expires_at: i96,
    proven_interaction: bool,
};

allocator: std.mem.Allocator,
io: std.Io,
global: *wl.Global,
seat: *Seat,
tokens: std.StringHashMapUnmanaged(Token),
expiry_timer: *wl.EventSource,
token_resource_count: usize,
activation_listener: ?ActivationListener,

pub const ActivationListener = struct {
    context: *anyopaque,
    requested: *const fn (*anyopaque, Surface.Id, bool) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    seat: *Seat,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .global = undefined,
        .seat = seat,
        .tokens = .empty,
        .expiry_timer = undefined,
        .token_resource_count = 0,
        .activation_listener = null,
    };
    errdefer self.tokens.deinit(allocator);
    self.expiry_timer = try display.getEventLoop().addTimer(*Self, expireTokens, self);
    errdefer self.expiry_timer.remove();
    self.global = try wl.Global.create(display, xdg.ActivationV1, 1, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.token_resource_count == 0);
    std.debug.assert(self.activation_listener == null);
    self.global.destroy();
    self.expiry_timer.remove();
    self.clearTokens();
    self.tokens.deinit(self.allocator);
    self.* = undefined;
}

/// Copies the listener and retains its context until clearActivationListener.
pub fn setActivationListener(self: *Self, listener: ActivationListener) void {
    std.debug.assert(self.activation_listener == null);
    self.activation_listener = listener;
}

pub fn clearActivationListener(self: *Self) void {
    std.debug.assert(self.activation_listener != null);
    self.activation_listener = null;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = xdg.ActivationV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *xdg.ActivationV1,
    request: xdg.ActivationV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_activation_token => |get| TokenResource.create(
            self,
            resource,
            get.id,
        ) catch resource.postNoMemory(),
        .activate => |request_activate| self.activateToken(
            std.mem.span(request_activate.token),
            Surface.fromResource(request_activate.surface).handle(),
        ),
    }
}

pub fn activateToken(self: *Self, token: []const u8, surface_id: Surface.Id) void {
    const removed = self.tokens.fetchRemove(token) orelse return;
    defer self.allocator.free(removed.key);
    if (removed.value.expires_at <= now(self.io)) return;
    const listener = self.activation_listener orelse return;
    listener.requested(listener.context, surface_id, removed.value.proven_interaction);
}

/// Revokes a token whose delivery failed before the requesting client could
/// observe it. Unknown and intentionally invalid tokens are harmless no-ops.
pub fn revokeToken(self: *Self, token: []const u8) void {
    const removed = self.tokens.fetchRemove(token) orelse return;
    self.allocator.free(removed.key);
}

fn issueToken(
    self: *Self,
    resource: *xdg.ActivationTokenV1,
    valid: bool,
    proven_interaction: bool,
) void {
    const token = self.issue(valid, proven_interaction) catch |err| switch (err) {
        error.Canceled, error.EntropyUnavailable => {
            resource.getClient().postImplementationError("secure token generation failed");
            return;
        },
        error.OutOfMemory => {
            resource.postNoMemory();
            return;
        },
        else => {
            resource.getClient().postImplementationError("activation token expiry scheduling failed");
            return;
        },
    };
    resource.sendDone(&token);
}

/// Issues an opaque token using the shared mature/generated security store.
/// Invalid requests still receive an indistinguishable token, but it is not
/// registered and therefore can never authorize activation.
pub fn issue(
    self: *Self,
    valid: bool,
    proven_interaction: bool,
) (std.Io.RandomSecureError || std.mem.Allocator.Error || error{TimerUpdateFailed})![token_character_count:0]u8 {
    const token = try self.generateToken();
    if (valid) self.registerToken(&token, proven_interaction) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TimerUpdateFailed,
    };
    return token;
}

fn generateToken(self: *Self) std.Io.RandomSecureError![token_character_count:0]u8 {
    while (true) {
        var bytes: [token_byte_count]u8 = undefined;
        try self.io.randomSecure(&bytes);
        const token = encodeToken(bytes);
        if (!self.tokens.contains(token[0..token_character_count])) return token;
    }
}

fn registerToken(
    self: *Self,
    token: *const [token_character_count:0]u8,
    proven_interaction: bool,
) !void {
    const key = try self.allocator.dupe(u8, token[0..token_character_count]);
    errdefer self.allocator.free(key);
    const start_timer = self.tokens.count() == 0;
    try self.tokens.put(self.allocator, key, .{
        .expires_at = now(self.io) + token_lifetime_nanoseconds,
        .proven_interaction = proven_interaction,
    });
    if (!start_timer) return;
    self.expiry_timer.timerUpdate(expiry_check_milliseconds) catch |err| {
        _ = self.tokens.fetchRemove(key) orelse unreachable;
        return err;
    };
}

fn expireTokens(self: *Self) c_int {
    const timestamp = now(self.io);
    while (true) {
        var expired: ?[]const u8 = null;
        var iterator = self.tokens.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.expires_at <= timestamp) {
                expired = entry.key_ptr.*;
                break;
            }
        }
        const key = expired orelse break;
        const removed = self.tokens.fetchRemove(key) orelse unreachable;
        self.allocator.free(removed.key);
    }
    if (self.tokens.count() > 0) {
        self.expiry_timer.timerUpdate(expiry_check_milliseconds) catch self.clearTokens();
    }
    return 0;
}

fn clearTokens(self: *Self) void {
    var iterator = self.tokens.iterator();
    while (iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
    self.tokens.clearRetainingCapacity();
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn encodeToken(bytes: [token_byte_count]u8) [token_character_count:0]u8 {
    var token: [token_character_count:0]u8 = undefined;
    const encoded = std.fmt.bytesToHex(bytes, .lower);
    @memcpy(token[0..token_character_count], &encoded);
    token[token_character_count] = 0;
    return token;
}

const TokenResource = struct {
    manager: *Self,
    resource: *xdg.ActivationTokenV1,
    surface_id: ?Surface.Id,
    serial_set: bool,
    serial_valid: bool,
    committed: bool,

    fn create(
        manager: *Self,
        factory: *xdg.ActivationV1,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try xdg.ActivationTokenV1.create(
            factory.getClient(),
            factory.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = manager.allocator.create(TokenResource) catch return error.OutOfMemory;
        self.* = .{
            .manager = manager,
            .resource = resource,
            .surface_id = null,
            .serial_set = false,
            .serial_valid = false,
            .committed = false,
        };
        manager.token_resource_count += 1;
        resource.setHandler(
            *TokenResource,
            TokenResource.handleRequest,
            TokenResource.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *xdg.ActivationTokenV1,
        request: xdg.ActivationTokenV1.Request,
        self: *TokenResource,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        if (self.committed) {
            resource.postError(.already_used, "activation token was already committed");
            return;
        }
        switch (request) {
            .destroy => unreachable,
            .set_serial => |set| {
                self.serial_set = true;
                self.serial_valid = self.manager.seat.acceptsActivationSerial(
                    set.seat,
                    resource.getClient(),
                    set.serial,
                );
            },
            .set_app_id => |set| {
                if (!std.unicode.utf8ValidateSlice(std.mem.span(set.app_id))) {
                    resource.getClient().postImplementationError(
                        "xdg_activation_token_v1 app ID is not valid UTF-8",
                    );
                }
            },
            .set_surface => |set| {
                self.surface_id = Surface.fromResource(set.surface).handle();
            },
            .commit => {
                self.committed = true;
                const surface_focused = self.surface_id == null or
                    self.manager.seat.activationSurfaceFocused(self.surface_id.?);
                const proven_interaction = self.serial_set and
                    self.serial_valid and surface_focused;
                self.manager.issueToken(
                    resource,
                    !self.serial_set or proven_interaction,
                    proven_interaction,
                );
            },
        }
    }

    fn handleDestroy(_: *xdg.ActivationTokenV1, self: *TokenResource) void {
        self.manager.token_resource_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

test "activation tokens use lowercase 128-bit hexadecimal identifiers" {
    const bytes = [_]u8{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    };
    try std.testing.expectEqualStrings(
        "00112233445566778899aabbccddeeff",
        &encodeToken(bytes),
    );
}

test "valid activation tokens forward their target and interaction provenance once" {
    const Capture = struct {
        count: usize = 0,
        surface_id: ?Surface.Id = null,
        proven_interaction: bool = false,

        fn requested(context: *anyopaque, surface_id: Surface.Id, proven_interaction: bool) void {
            const capture: *@This() = @ptrCast(@alignCast(context));
            capture.count += 1;
            capture.surface_id = surface_id;
            capture.proven_interaction = proven_interaction;
        }
    };

    var capture: Capture = .{};
    var manager: Self = undefined;
    manager.allocator = std.testing.allocator;
    manager.io = std.testing.io;
    manager.tokens = .empty;
    manager.activation_listener = .{
        .context = &capture,
        .requested = Capture.requested,
    };
    defer manager.tokens.deinit(std.testing.allocator);

    const token: [:0]const u8 = "valid-token";
    const key = try std.testing.allocator.dupe(u8, token);
    errdefer std.testing.allocator.free(key);
    try manager.tokens.put(std.testing.allocator, key, .{
        .expires_at = std.math.maxInt(i96),
        .proven_interaction = true,
    });
    const target: Surface.Id = .{ .index = 7, .generation = 3 };

    manager.activateToken(token, target);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(target, capture.surface_id.?);
    try std.testing.expect(capture.proven_interaction);
    try std.testing.expectEqual(@as(usize, 0), manager.tokens.count());

    manager.activateToken(token, target);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
}
