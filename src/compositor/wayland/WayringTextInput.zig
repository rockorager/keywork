//! Resource-only scanner-backed text-input-v3 frontend.
//!
//! TextInput owns all text-input and input-method semantics. This adapter only
//! validates generated object identities, translates wire values, and retains
//! resources needed by synchronous neutral endpoints.

const WayringTextInput = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const TextInput = @import("../TextInput.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const WayringClients = @import("WayringClients.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");

const Manager = struct {
    owner: *WayringTextInput,
    client: *wayring.server.Client,
    resource: protocol.zwp_text_input_manager_v3.Resource,
};
const Input = struct {
    owner: *WayringTextInput,
    client: *wayring.server.Client,
    resource: protocol.zwp_text_input_v3.Resource,
    neutral_id: TextInput.InputId,
    pending_enter: ?SurfaceRegistry.Id = null,
    materialized: bool = false,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
clients: *WayringClients,
seat: *WayringSeatAdapter,
compositor: *WayringCompositor,
neutral: *TextInput,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
inputs: std.ArrayList(*Input) = .empty,

pub fn init(self: *WayringTextInput, allocator: std.mem.Allocator, protocol_server: *wayring.server.Server, clients: *WayringClients, seat: *WayringSeatAdapter, compositor: *WayringCompositor, neutral: *TextInput) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .clients = clients, .seat = seat, .compositor = compositor, .neutral = neutral };
}

pub fn deinit(self: *WayringTextInput) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.inputs.items.len == 0);
    self.managers.deinit(self.allocator);
    self.inputs.deinit(self.allocator);
    self.* = undefined;
}

pub fn publish(self: *WayringTextInput) !void {
    self.global = try self.protocol_server.addGlobal(protocol.zwp_text_input_manager_v3, protocol.zwp_text_input_manager_v3.interface.version, WayringTextInput, self, bind);
}

pub fn unpublish(self: *WayringTextInput) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

fn bind(client: *wayring.server.Client, id: u32, version: u32, self: *WayringTextInput) !void {
    if (version == 0 or version > protocol.zwp_text_input_manager_v3.interface.version) return error.InvalidVersion;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn managerRequest(_: *protocol.zwp_text_input_manager_v3.Resource, request: protocol.zwp_text_input_manager_v3.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_text_input => |args| {
            if (manager.owner.seat.seatClientIdentity(manager.client, args.seat) == null) {
                manager.client.postImplementationError(&manager.resource.runtime, "text input requires the exact live same-client wl_seat");
                return;
            }
            try manager.owner.createInput(manager, args.id);
        },
    }
}

fn createInput(self: *WayringTextInput, manager: *Manager, id: u32) !void {
    try self.inputs.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Input);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
        .neutral_id = undefined,
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    const neutral_id = try self.neutral.createInput(self.clients.id(manager.client) orelse return error.InvalidClient, .{
        .context = value,
        .enter = endpointEnter,
        .leave = endpointLeave,
        .preedit = endpointPreedit,
        .commit_string = endpointCommit,
        .delete_surrounding = endpointDelete,
        .done = endpointDone,
    });
    errdefer self.neutral.destroyInput(neutral_id);
    value.neutral_id = neutral_id;
    try value.resource.setHandler(Input, value, inputRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    value.materialized = true;
    self.inputs.appendAssumeCapacity(value);
    if (value.pending_enter) |surface| endpointEnter(value, surface);
}

fn inputRequest(_: *protocol.zwp_text_input_v3.Resource, request: protocol.zwp_text_input_v3.Request, input: *Input) !void {
    const owner = input.owner.neutral;
    switch (request) {
        .destroy => input.owner.destroyInput(input),
        .enable => owner.enable(input.neutral_id) catch {},
        .disable => owner.disable(input.neutral_id) catch {},
        .set_surrounding_text => |args| {
            if (!validSurroundingText(args.text, args.cursor, args.anchor)) return;
            owner.setSurroundingText(input.neutral_id, args.text, @intCast(args.cursor), @intCast(args.anchor)) catch |err| if (err == error.OutOfMemory) {
                input.client.postOutOfMemory(&input.resource.runtime, "setting surrounding text");
            };
        },
        .set_text_change_cause => |args| if (args.cause <= @intFromEnum(TextInput.ChangeCause.other)) owner.setTextChangeCause(input.neutral_id, @enumFromInt(args.cause)) catch {},
        .set_content_type => |args| if (args.purpose <= @intFromEnum(TextInput.ContentPurpose.terminal)) owner.setContentType(input.neutral_id, @bitCast(args.hint), @enumFromInt(args.purpose)) catch {},
        .set_cursor_rectangle => |args| owner.setCursorRectangle(input.neutral_id, .{ .x = args.x, .y = args.y, .width = args.width, .height = args.height }, input.resource.version() >= 2) catch {},
        .commit => owner.commitState(input.neutral_id) catch {},
        .set_available_actions => |args| {
            const submit = parseAvailableActions(args.available_actions) catch {
                input.client.postProtocolError(&input.resource.runtime, @intCast(protocol.zwp_text_input_v3.@"error".invalid_action), "invalid or duplicate text-input action");
                return;
            };
            owner.setSubmitAvailable(input.neutral_id, submit) catch {};
        },
        .show_input_panel => owner.setPanelVisible(input.neutral_id, true) catch {},
        .hide_input_panel => owner.setPanelVisible(input.neutral_id, false) catch {},
    }
}

fn endpointEnter(context: *anyopaque, surface: SurfaceRegistry.Id) void {
    const input: *Input = @ptrCast(@alignCast(context));
    if (!input.materialized) {
        input.pending_enter = surface;
        return;
    }
    const endpoint = input.owner.compositor.surfaceEndpoint(surface) orelse return;
    if (endpoint.client == input.client) protocol.zwp_text_input_v3.@"send:enter"(&input.resource, endpoint.resource.id()) catch input.client.postOutOfMemory(&input.resource.runtime, "sending text input enter");
}
fn endpointLeave(context: *anyopaque, surface: SurfaceRegistry.Id) void {
    const input: *Input = @ptrCast(@alignCast(context));
    const endpoint = input.owner.compositor.surfaceEndpoint(surface) orelse return;
    if (endpoint.client == input.client) protocol.zwp_text_input_v3.@"send:leave"(&input.resource, endpoint.resource.id()) catch input.client.postOutOfMemory(&input.resource.runtime, "sending text input leave");
}
fn endpointPreedit(context: *anyopaque, text: ?[:0]const u8, begin: i32, end: i32) void {
    const input: *Input = @ptrCast(@alignCast(context));
    protocol.zwp_text_input_v3.@"send:preedit_string"(&input.resource, text, begin, end) catch input.client.postOutOfMemory(&input.resource.runtime, "sending preedit");
}
fn endpointCommit(context: *anyopaque, text: ?[:0]const u8) void {
    const input: *Input = @ptrCast(@alignCast(context));
    protocol.zwp_text_input_v3.@"send:commit_string"(&input.resource, text) catch input.client.postOutOfMemory(&input.resource.runtime, "sending commit string");
}
fn endpointDelete(context: *anyopaque, before: u32, after: u32) void {
    const input: *Input = @ptrCast(@alignCast(context));
    protocol.zwp_text_input_v3.@"send:delete_surrounding_text"(&input.resource, before, after) catch input.client.postOutOfMemory(&input.resource.runtime, "sending delete");
}
fn endpointDone(context: *anyopaque, serial: u32) void {
    const input: *Input = @ptrCast(@alignCast(context));
    protocol.zwp_text_input_v3.@"send:done"(&input.resource, serial) catch input.client.postOutOfMemory(&input.resource.runtime, "sending done");
}

pub fn destroyClientResources(self: *WayringTextInput, client: *wayring.server.Client) void {
    var i = self.inputs.items.len;
    while (i > 0) : (i -= 1) if (self.inputs.items[i - 1].client == client) self.destroyInput(self.inputs.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}
fn destroyInput(self: *WayringTextInput, value: *Input) void {
    self.neutral.destroyInput(value.neutral_id);
    remove(Input, &self.inputs, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *WayringTextInput, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, index| if (item == value) {
        _ = list.orderedRemove(index);
        return;
    };
}

fn validSurroundingText(text: []const u8, cursor: i32, anchor: i32) bool {
    if (text.len > TextInput.max_text_bytes or cursor < 0 or anchor < 0 or !std.unicode.utf8ValidateSlice(text)) return false;
    return validUtf8Index(text, @intCast(cursor)) and validUtf8Index(text, @intCast(anchor));
}

fn validUtf8Index(text: []const u8, index: usize) bool {
    if (index > text.len) return false;
    return index == text.len or text[index] & 0xc0 != 0x80;
}

fn parseAvailableActions(bytes: []const u8) error{InvalidAction}!bool {
    if (bytes.len % @sizeOf(u32) != 0) return error.InvalidAction;
    var submit = false;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += @sizeOf(u32)) {
        const value = std.mem.readInt(u32, bytes[offset..][0..@sizeOf(u32)], .native);
        if (value == protocol.zwp_text_input_v3.action.none) return error.InvalidAction;
        var previous: usize = 0;
        while (previous < offset) : (previous += @sizeOf(u32))
            if (std.mem.readInt(u32, bytes[previous..][0..@sizeOf(u32)], .native) == value) return error.InvalidAction;
        if (value == protocol.zwp_text_input_v3.action.submit) submit = true;
    }
    return submit;
}

test "official text input descriptor and protocol values stay pinned" {
    try std.testing.expectEqual(@as(u32, 2), protocol.zwp_text_input_manager_v3.interface.version);
    try std.testing.expectEqual(@as(u32, 2), protocol.zwp_text_input_v3.interface.version);
    try std.testing.expectEqual(@as(usize, 2), protocol.zwp_text_input_manager_v3.request_messages.len);
    try std.testing.expectEqual(@as(usize, 11), protocol.zwp_text_input_v3.request_messages.len);
    try std.testing.expectEqualStrings("set_available_actions", protocol.zwp_text_input_v3.request_messages[8].name);
    try std.testing.expectEqual(@as(u32, 2), protocol.zwp_text_input_v3.request_messages[8].since);
    try std.testing.expectEqual(@as(i64, 0), protocol.zwp_text_input_v3.@"error".invalid_action);
    try std.testing.expectEqual(@as(i64, 1), protocol.zwp_text_input_v3.action.submit);
}

test "official input method v2 descriptor family stays pinned" {
    try std.testing.expectEqual(@as(u32, 1), protocol.zwp_input_method_manager_v2.interface.version);
    try std.testing.expectEqual(@as(u32, 1), protocol.zwp_input_method_v2.interface.version);
    try std.testing.expectEqual(@as(u32, 1), protocol.zwp_input_method_keyboard_grab_v2.interface.version);
    try std.testing.expectEqual(@as(u32, 1), protocol.zwp_input_popup_surface_v2.interface.version);
    try std.testing.expectEqual(@as(i64, 0), protocol.zwp_input_method_v2.@"error".role);
    try std.testing.expectEqualStrings("get_input_method", protocol.zwp_input_method_manager_v2.request_messages[0].name);
    try std.testing.expectEqualStrings("grab_keyboard", protocol.zwp_input_method_v2.request_messages[5].name);
    try std.testing.expectEqualStrings("text_input_rectangle", protocol.zwp_input_popup_surface_v2.event_messages[0].name);
}

test "surrounding text validation rejects negative non-UTF-8 and split ranges" {
    try std.testing.expect(validSurroundingText("hé", 0, 3));
    try std.testing.expect(!validSurroundingText("hé", -1, 0));
    try std.testing.expect(!validSurroundingText("hé", 2, 0));
    try std.testing.expect(!validSurroundingText(&.{0xff}, 0, 0));
    try std.testing.expect(!validSurroundingText("x", 2, 0));
}

test "available actions validates none duplicates and malformed arrays" {
    try std.testing.expect(!(try parseAvailableActions("")));
    try std.testing.expect(try parseAvailableActions(&.{ 1, 0, 0, 0 }));
    try std.testing.expectError(error.InvalidAction, parseAvailableActions(&.{ 0, 0, 0, 0 }));
    try std.testing.expectError(error.InvalidAction, parseAvailableActions(&.{ 1, 0, 0, 0, 1, 0, 0, 0 }));
    try std.testing.expectError(error.InvalidAction, parseAvailableActions(&.{1}));
    // Unknown actions are permitted by the official extensible enum.
    try std.testing.expect(!(try parseAvailableActions(&.{ 99, 0, 0, 0 })));
}

test "manager publication is singular v2" {
    var host: wayring.server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var adapter: WayringTextInput = undefined;
    adapter.init(std.testing.allocator, &host, undefined, undefined, undefined, undefined);
    defer adapter.deinit();
    try adapter.publish();
    defer adapter.unpublish();
    var count: usize = 0;
    var globals = host.iterator();
    while (globals.next()) |global| if (std.mem.eql(u8, global.interface().name, "zwp_text_input_manager_v3")) {
        count += 1;
        try std.testing.expectEqual(@as(u32, 2), global.version());
    };
    try std.testing.expectEqual(@as(usize, 1), count);
}
