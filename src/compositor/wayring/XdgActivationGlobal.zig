//! Native XDG activation-token lifecycle and focus-stealing policy boundary.

const XdgActivationGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");

const advertised_version: u32 = 1;
const token_byte_count = 16;
const token_character_count = token_byte_count * 2;
const token_lifetime_nanoseconds: i96 = 30 * std.time.ns_per_s;
const maximum_issued_tokens = 1024;
const maximum_issued_tokens_per_client = 64;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

allocator: std.mem.Allocator,
server: *Server,
compositor: *CompositorGlobal,
seat: *SeatGlobal,
global_name: u32,
token_key: [Hmac.key_length]u8,
next_token: u64 = 1,
tokens: std.StringHashMapUnmanaged(*IssuedToken) = .empty,
issued_tokens: std.ArrayList(*IssuedToken) = .empty,
issued_head: usize = 0,
issued_by_client: std.AutoHashMapUnmanaged(u64, usize) = .empty,
token_resource_count: usize = 0,
clock: Clock,
activation_handler: ?ActivationHandler,

const IssuedToken = struct {
    key: [token_character_count]u8,
    expires_at: i96,
    client_identity: u64,
    proven_interaction: bool,
    active: bool = true,
};

pub const Clock = struct {
    context: *anyopaque,
    now: *const fn (*anyopaque) i96,
};

pub const ActivationHandler = struct {
    context: *anyopaque,
    requested: *const fn (*anyopaque, *CompositorGlobal.Surface, bool) anyerror!void,
};

const TokenResource = struct {
    owner: *XdgActivationGlobal,
    resource: wayring.ObjectHandle,
    surface: ?wayring.ObjectHandle = null,
    serial_set: bool = false,
    serial_valid: bool = false,
    committed: bool = false,
};

pub fn init(
    self: *XdgActivationGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    compositor: *CompositorGlobal,
    seat: *SeatGlobal,
    token_key: [Hmac.key_length]u8,
    clock: Clock,
    activation_handler: ?ActivationHandler,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .compositor = compositor,
        .seat = seat,
        .global_name = undefined,
        .token_key = token_key,
        .clock = clock,
        .activation_handler = activation_handler,
    };
    errdefer self.issued_by_client.deinit(allocator);
    errdefer self.issued_tokens.deinit(allocator);
    errdefer self.tokens.deinit(allocator);
    self.global_name = try server.createGlobal(
        &generated.xdg_activation_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *XdgActivationGlobal) void {
    std.debug.assert(self.token_resource_count == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.clearTokens();
    self.issued_by_client.deinit(self.allocator);
    self.issued_tokens.deinit(self.allocator);
    self.tokens.deinit(self.allocator);
    @memset(&self.token_key, 0);
    self.* = undefined;
}

/// Releases expired token storage. Token validity is checked independently
/// during activation, so delayed calls cannot extend a token's lifetime.
pub fn expireTokens(self: *XdgActivationGlobal) void {
    const timestamp = self.clock.now(self.clock.context);
    while (self.issued_head < self.issued_tokens.items.len) {
        const token = self.issued_tokens.items[self.issued_head];
        if (token.expires_at > timestamp) break;
        const removed = self.tokens.remove(&token.key);
        std.debug.assert(removed);
        self.decrementIssuedCount(token.client_identity);
        self.allocator.destroy(token);
        self.issued_head += 1;
    }
    self.compactIssuedTokens();
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *XdgActivationGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.xdg_activation_v1, version, .{
        .context = self,
        .dispatch = dispatchManager,
    }) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *XdgActivationGlobal = @ptrCast(@alignCast(context));
    switch (try generated.xdg_activation_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_activation_token => |request| try self.createTokenResource(
            client,
            request.id,
            try client.resourceVersion(resource, &generated.xdg_activation_v1),
        ),
        .activate => |request| try self.activate(client, request.token, request.surface),
    }
}

fn createTokenResource(
    self: *XdgActivationGlobal,
    client: *Server.Client,
    id: u32,
    version: u32,
) !void {
    const token = self.allocator.create(TokenResource) catch return client.postNoMemory();
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(token);
    token.* = .{ .owner = self, .resource = undefined };
    token.resource = client.createResource(
        id,
        &generated.xdg_activation_token_v1,
        @min(version, generated.xdg_activation_token_v1.version),
        .{
            .context = token,
            .dispatch = dispatchToken,
            .destroy = destroyToken,
        },
    ) catch return client.postNoMemory();
    self.token_resource_count += 1;
    registered = true;
}

fn activate(
    self: *XdgActivationGlobal,
    client: *Server.Client,
    token_text: []const u8,
    surface_id: u32,
) !void {
    const token = self.tokens.get(token_text) orelse return;
    if (!token.active) return;
    token.active = false;
    if (token.expires_at <= self.clock.now(self.clock.context)) return;
    const surface = try surfaceFor(client, surface_id);
    if (surface.owner != self.compositor) return;
    const handler = self.activation_handler orelse return;
    try handler.requested(
        handler.context,
        surface,
        token.proven_interaction,
    );
}

fn dispatchToken(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const token: *TokenResource = @ptrCast(@alignCast(context));
    const request = try generated.xdg_activation_token_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    );
    if (request == .destroy) return;
    if (token.committed) return client.postError(
        resource,
        @intFromEnum(generated.xdg_activation_token_v1_types.@"error".already_used),
        "activation token was already committed",
    );
    switch (request) {
        .destroy => unreachable,
        .set_serial => |set| {
            token.serial_set = true;
            token.serial_valid = token.owner.seat.acceptsActivationSerial(
                client,
                set.seat,
                set.serial,
            );
        },
        .set_app_id => |set| {
            if (!std.unicode.utf8ValidateSlice(set.app_id))
                return client.postImplementationError(
                    "xdg_activation_token_v1 app ID is not valid UTF-8",
                );
        },
        .set_surface => |set| {
            const surface = try surfaceFor(client, set.surface);
            token.surface = if (surface.owner == token.owner.compositor)
                surface.resource
            else
                null;
        },
        .commit => {
            token.committed = true;
            const surface_focused = if (token.surface) |handle| focused: {
                const surface = CompositorGlobal.surfaceFor(client, handle) catch
                    break :focused false;
                break :focused surface.owner == token.owner.compositor and
                    token.owner.seat.activationSurfaceFocused(surface);
            } else true;
            const proven_interaction = token.serial_set and
                token.serial_valid and surface_focused;
            try token.owner.issueToken(
                client,
                resource,
                !token.serial_set or proven_interaction,
                proven_interaction,
            );
        },
    }
}

fn issueToken(
    self: *XdgActivationGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    valid: bool,
    proven_interaction: bool,
) !void {
    self.expireTokens();
    const token = self.generateToken();
    const registered = if (valid and self.canIssue(client.identity()))
        self.registerToken(
            token,
            client.identity(),
            proven_interaction,
        ) catch return client.postNoMemory()
    else
        null;
    generated.xdg_activation_token_v1_types.events.done(
        &client.connection,
        resource,
        &token,
    ) catch {
        if (registered) |issued| self.discardLastIssued(issued);
        return client.postNoMemory();
    };
}

fn canIssue(self: *const XdgActivationGlobal, client_identity: u64) bool {
    return self.issued_tokens.items.len - self.issued_head < maximum_issued_tokens and
        (self.issued_by_client.get(client_identity) orelse 0) <
            maximum_issued_tokens_per_client;
}

fn registerToken(
    self: *XdgActivationGlobal,
    key: [token_character_count]u8,
    client_identity: u64,
    proven_interaction: bool,
) !*IssuedToken {
    try self.tokens.ensureUnusedCapacity(self.allocator, 1);
    try self.issued_tokens.ensureUnusedCapacity(self.allocator, 1);
    const count = self.issued_by_client.getPtr(client_identity);
    if (count == null)
        try self.issued_by_client.ensureUnusedCapacity(self.allocator, 1);
    const token = try self.allocator.create(IssuedToken);
    token.* = .{
        .key = key,
        .expires_at = self.clock.now(self.clock.context) + token_lifetime_nanoseconds,
        .client_identity = client_identity,
        .proven_interaction = proven_interaction,
    };
    self.tokens.putAssumeCapacityNoClobber(&token.key, token);
    self.issued_tokens.appendAssumeCapacity(token);
    if (count) |value|
        value.* += 1
    else
        self.issued_by_client.putAssumeCapacityNoClobber(client_identity, 1);
    return token;
}

fn discardLastIssued(self: *XdgActivationGlobal, token: *IssuedToken) void {
    std.debug.assert(self.issued_tokens.items.len > self.issued_head);
    std.debug.assert(self.issued_tokens.getLast() == token);
    _ = self.issued_tokens.pop().?;
    const removed = self.tokens.remove(&token.key);
    std.debug.assert(removed);
    self.decrementIssuedCount(token.client_identity);
    self.allocator.destroy(token);
}

fn decrementIssuedCount(self: *XdgActivationGlobal, client_identity: u64) void {
    const count = self.issued_by_client.getPtr(client_identity) orelse unreachable;
    std.debug.assert(count.* > 0);
    count.* -= 1;
    if (count.* == 0) std.debug.assert(self.issued_by_client.remove(client_identity));
}

fn compactIssuedTokens(self: *XdgActivationGlobal) void {
    if (self.issued_head == 0) return;
    if (self.issued_head == self.issued_tokens.items.len) {
        self.issued_tokens.clearRetainingCapacity();
        self.issued_head = 0;
    } else if (self.issued_head >= 256 and
        self.issued_head >= self.issued_tokens.items.len / 2)
    {
        self.issued_tokens.replaceRangeAssumeCapacity(0, self.issued_head, &.{});
        self.issued_head = 0;
    }
}

fn generateToken(self: *XdgActivationGlobal) [token_character_count]u8 {
    while (true) {
        var counter_bytes: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &counter_bytes, self.next_token, .little);
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;
        var digest: [Hmac.mac_length]u8 = undefined;
        Hmac.create(&digest, &counter_bytes, &self.token_key);
        const token = std.fmt.bytesToHex(digest[0..token_byte_count].*, .lower);
        if (!self.tokens.contains(&token)) return token;
    }
}

fn surfaceFor(client: *Server.Client, id: u32) !*CompositorGlobal.Surface {
    const object = client.connection.object(id) orelse return error.UnknownSurface;
    return CompositorGlobal.surfaceFor(client, .{
        .id = id,
        .generation = object.generation,
    });
}

fn destroyToken(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const token: *TokenResource = @ptrCast(@alignCast(context));
    const owner = token.owner;
    owner.token_resource_count -= 1;
    owner.allocator.destroy(token);
}

fn clearTokens(self: *XdgActivationGlobal) void {
    self.tokens.clearRetainingCapacity();
    for (self.issued_tokens.items[self.issued_head..]) |token|
        self.allocator.destroy(token);
    self.issued_tokens.clearRetainingCapacity();
    self.issued_by_client.clearRetainingCapacity();
    self.issued_head = 0;
}

test "issued activation tokens are bounded and expire in issue order" {
    const TestClock = struct {
        now_nanoseconds: i96 = 1,

        fn now(context: *anyopaque) i96 {
            return @as(*@This(), @ptrCast(@alignCast(context))).now_nanoseconds;
        }
    };

    var clock: TestClock = .{};
    var activation: XdgActivationGlobal = undefined;
    activation.allocator = std.testing.allocator;
    activation.token_key = [_]u8{0xa5} ** Hmac.key_length;
    activation.next_token = 1;
    activation.tokens = .empty;
    activation.issued_tokens = .empty;
    activation.issued_head = 0;
    activation.issued_by_client = .empty;
    activation.clock = .{ .context = &clock, .now = TestClock.now };
    defer {
        activation.clearTokens();
        activation.issued_by_client.deinit(std.testing.allocator);
        activation.issued_tokens.deinit(std.testing.allocator);
        activation.tokens.deinit(std.testing.allocator);
    }

    const first_client: u64 = 1;
    for (0..maximum_issued_tokens_per_client) |_| {
        try std.testing.expect(activation.canIssue(first_client));
        _ = try activation.registerToken(
            activation.generateToken(),
            first_client,
            false,
        );
    }
    try std.testing.expect(!activation.canIssue(first_client));
    try std.testing.expect(activation.canIssue(2));

    for (maximum_issued_tokens_per_client..maximum_issued_tokens) |index| {
        const client_identity: u64 = @intCast(2 +
            (index - maximum_issued_tokens_per_client) /
                maximum_issued_tokens_per_client);
        _ = try activation.registerToken(
            activation.generateToken(),
            client_identity,
            false,
        );
    }
    try std.testing.expectEqual(maximum_issued_tokens, activation.tokens.count());
    try std.testing.expect(!activation.canIssue(std.math.maxInt(u64)));

    clock.now_nanoseconds += token_lifetime_nanoseconds;
    activation.expireTokens();
    try std.testing.expectEqual(@as(usize, 0), activation.tokens.count());
    try std.testing.expectEqual(@as(usize, 0), activation.issued_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 0), activation.issued_by_client.count());
    try std.testing.expect(activation.canIssue(first_client));
}

test "activation tokens preserve child lifetime and prove focused input once" {
    const core = @import("wayring-core");

    const TestClock = struct {
        now_nanoseconds: i96 = 1,

        fn now(context: *anyopaque) i96 {
            return @as(*@This(), @ptrCast(@alignCast(context))).now_nanoseconds;
        }
    };
    const Capture = struct {
        calls: usize = 0,
        surface: ?*CompositorGlobal.Surface = null,
        proven_interaction: bool = false,

        fn requested(
            context: *anyopaque,
            surface: *CompositorGlobal.Surface,
            proven_interaction: bool,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.surface = surface;
            self.proven_interaction = proven_interaction;
        }
    };

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(
        std.testing.allocator,
        &server,
        "default",
        SeatGlobal.Capability.keyboard,
        null,
    );
    defer seat.deinit();
    var clock: TestClock = .{};
    var capture: Capture = .{};
    var activation: XdgActivationGlobal = undefined;
    try activation.init(
        std.testing.allocator,
        &server,
        &compositor,
        &seat,
        [_]u8{0x5a} ** Hmac.key_length,
        .{ .context = &clock, .now = TestClock.now },
        .{ .context = &capture, .requested = Capture.requested },
    );
    defer activation.deinit();

    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;
    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);

    var compositor_name: u32 = 0;
    var seat_name: u32 = 0;
    var activation_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wl_seat.name))
            seat_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.xdg_activation_v1.name)) {
            try std.testing.expectEqual(advertised_version, global.version);
            activation_name = global.name;
        }
    }
    try std.testing.expect(compositor_name != 0);
    try std.testing.expect(seat_name != 0);
    try std.testing.expect(activation_name != 0);

    const compositor_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const seat_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            seat_name,
            generated.wl_seat.name,
            10,
            4,
            &generated.wl_seat,
        ),
    };
    const first_manager: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            activation_name,
            generated.xdg_activation_v1.name,
            advertised_version,
            5,
            &generated.xdg_activation_v1,
        ),
    };
    const second_manager: wayring.ObjectHandle = .{
        .id = 6,
        .generation = try core.bind(
            &peer,
            registry.id,
            activation_name,
            generated.xdg_activation_v1.name,
            advertised_version,
            6,
            &generated.xdg_activation_v1,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == seat_resource.id)
            _ = try generated.wl_seat_types.decodeEvent(&peer, seat_resource, &message)
        else if (message.object_id == 1)
            _ = try core.decodeDisplayEvent(&message)
        else
            return error.UnexpectedActivationSetupEvent;
    }

    const requesting_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const target_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    try transferToServer(&peer, client);
    const requesting_surface = try surfaceFor(client, requesting_handle.id);
    const target_surface = try surfaceFor(client, target_handle.id);
    const undelivered_serial = try seat.keyboardEnter(requesting_surface, &.{});
    try std.testing.expect(!seat.acceptsActivationSerial(
        client,
        seat_resource.id,
        undelivered_serial,
    ));
    const keyboard = try generated.wl_seat_types.requests.get_keyboard(
        &peer,
        seat_resource,
    );
    try transferToServer(&peer, client);
    const serial = try seat.keyboardEnter(requesting_surface, &.{});
    try std.testing.expect(seat.acceptsActivationSerial(
        client,
        seat_resource.id,
        serial,
    ));
    try transferFromServer(&peer, client);
    var got_keyboard_enter = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != keyboard.id) return error.UnexpectedActivationInputEvent;
        switch (try generated.wl_keyboard_types.decodeEvent(&peer, keyboard, &message)) {
            .enter => |event| {
                try std.testing.expectEqual(serial, event.serial);
                got_keyboard_enter = true;
            },
            else => return error.UnexpectedActivationInputEvent,
        }
    }
    try std.testing.expect(got_keyboard_enter);

    const token_resource = try generated.xdg_activation_v1_types.requests.get_activation_token(
        &peer,
        first_manager,
    );
    try generated.xdg_activation_token_v1_types.requests.set_serial(
        &peer,
        token_resource,
        serial,
        seat_resource,
    );
    try generated.xdg_activation_token_v1_types.requests.set_surface(
        &peer,
        token_resource,
        requesting_handle,
    );
    try generated.xdg_activation_v1_types.requests.destroy(&peer, first_manager);
    try generated.xdg_activation_token_v1_types.requests.commit(&peer, token_resource);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
    try std.testing.expectEqual(@as(usize, 1), activation.token_resource_count);

    const token_text = try receiveToken(&peer, client, token_resource);

    try generated.xdg_activation_v1_types.requests.activate(
        &peer,
        second_manager,
        &token_text,
        target_handle,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(target_surface, capture.surface.?);
    try std.testing.expect(capture.proven_interaction);

    try generated.xdg_activation_v1_types.requests.activate(
        &peer,
        second_manager,
        &token_text,
        target_handle,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    const ineffective = try generated.xdg_activation_v1_types.requests.get_activation_token(
        &peer,
        second_manager,
    );
    try generated.xdg_activation_token_v1_types.requests.set_serial(
        &peer,
        ineffective,
        serial +% 1,
        seat_resource,
    );
    try generated.xdg_activation_token_v1_types.requests.commit(&peer, ineffective);
    try transferToServer(&peer, client);
    const ineffective_text = try receiveToken(&peer, client, ineffective);
    try generated.xdg_activation_v1_types.requests.activate(
        &peer,
        second_manager,
        &ineffective_text,
        target_handle,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    const unproven = try generated.xdg_activation_v1_types.requests.get_activation_token(
        &peer,
        second_manager,
    );
    try generated.xdg_activation_token_v1_types.requests.commit(&peer, unproven);
    try transferToServer(&peer, client);
    const unproven_text = try receiveToken(&peer, client, unproven);
    try generated.xdg_activation_v1_types.requests.activate(
        &peer,
        second_manager,
        &unproven_text,
        target_handle,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expect(!capture.proven_interaction);

    const expiring = try generated.xdg_activation_v1_types.requests.get_activation_token(
        &peer,
        second_manager,
    );
    try generated.xdg_activation_token_v1_types.requests.commit(&peer, expiring);
    try transferToServer(&peer, client);
    const expiring_text = try receiveToken(&peer, client, expiring);
    clock.now_nanoseconds += token_lifetime_nanoseconds;
    activation.expireTokens();
    try std.testing.expectEqual(@as(usize, 0), activation.tokens.count());
    try generated.xdg_activation_v1_types.requests.activate(
        &peer,
        second_manager,
        &expiring_text,
        target_handle,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
}

fn receiveToken(
    peer: *wayring.Connection,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
) ![token_character_count]u8 {
    const core = @import("wayring-core");
    var token: [token_character_count]u8 = undefined;
    var found = false;
    try transferFromServer(peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == resource.id) {
            const event = try generated.xdg_activation_token_v1_types.decodeEvent(
                peer,
                resource,
                &message,
            );
            @memcpy(&token, event.done.token);
            found = true;
        } else if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
        } else return error.UnexpectedActivationTokenEvent;
    }
    if (!found) return error.MissingActivationToken;
    return token;
}

fn transferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
