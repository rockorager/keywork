//! Seat-focused `zwp_text_input_v3` state and edit delivery.

const TextInputGlobal = @This();
const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const SeatGlobal = @import("SeatGlobal.zig");
const CompositorGlobal = @import("CompositorGlobal.zig");

const maximum_text_size = 4000;

allocator: std.mem.Allocator,
server: *Server,
seat: *SeatGlobal,
global_name: u32,
inputs: std.ArrayList(*Input) = .empty,
active: ?*Input = null,
listener: ?Listener = null,
focused_client: ?*Server.Client = null,
focused_surface: ?wayring.ObjectHandle = null,

pub const Listener = struct { context: *anyopaque, changed: *const fn (*anyopaque) void };
pub const Surrounding = struct { text: []const u8, cursor: u32, anchor: u32 };
pub const State = struct { serial: u32, surrounding: ?Surrounding, cause: u32, hint: u32, purpose: u32 };
pub const Edit = struct {
    preedit: ?struct { text: []const u8, begin: i32, end: i32 } = null,
    commit: ?[]const u8 = null,
    delete_before: u32 = 0,
    delete_after: u32 = 0,
};
const Pending = struct {
    transition: ?bool = null,
    surrounding: ?OwnedSurrounding = null,
    cause: u32 = 0,
    hint: ?u32 = null,
    purpose: u32 = 0,
    fn reset(self: *Pending, allocator: std.mem.Allocator) void {
        if (self.surrounding) |value| allocator.free(value.text);
        self.* = .{};
    }
};
const OwnedSurrounding = struct { text: []u8, cursor: u32, anchor: u32 };
const Input = struct {
    owner: *TextInputGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    inert: bool,
    enabled: bool = false,
    serial: u32 = 0,
    surrounding: ?OwnedSurrounding = null,
    cause: u32 = 0,
    hint: u32 = 0,
    purpose: u32 = 0,
    pending: Pending = .{},
};

pub fn init(self: *TextInputGlobal, allocator: std.mem.Allocator, server: *Server, seat: *SeatGlobal) !void {
    self.* = .{ .allocator = allocator, .server = server, .seat = seat, .global_name = undefined };
    self.global_name = try server.createGlobal(&generated.zwp_text_input_manager_v3, 1, .{ .context = self, .bind = bind });
    errdefer server.removeGlobal(self.global_name) catch unreachable;
    try seat.addKeyboardFocusListener(.{ .context = self, .changed = focusChanged });
}

pub fn deinit(self: *TextInputGlobal) void {
    self.seat.removeKeyboardFocusListener(self);
    self.server.removeGlobal(self.global_name) catch unreachable;
    std.debug.assert(self.inputs.items.len == 0);
    self.inputs.deinit(self.allocator);
}

pub fn setListener(self: *TextInputGlobal, listener: Listener) void {
    self.listener = listener;
}
pub fn clearListener(self: *TextInputGlobal) void {
    self.listener = null;
}

pub fn activeState(self: *TextInputGlobal) ?State {
    const input = self.active orelse return null;
    if (!input.enabled or !accepts(input)) return null;
    return .{ .serial = input.serial, .surrounding = if (input.surrounding) |s| .{ .text = s.text, .cursor = s.cursor, .anchor = s.anchor } else null, .cause = input.cause, .hint = input.hint, .purpose = input.purpose };
}

pub fn sendEdit(self: *TextInputGlobal, edit: Edit) bool {
    const input = self.active orelse return false;
    if (!input.enabled or !accepts(input)) return false;
    if (edit.preedit) |p| generated.zwp_text_input_v3_types.events.preedit_string(&input.client.connection, input.resource, p.text, p.begin, p.end) catch {
        input.client.postNoMemory() catch {};
        return false;
    };
    if (edit.delete_before != 0 or edit.delete_after != 0) generated.zwp_text_input_v3_types.events.delete_surrounding_text(&input.client.connection, input.resource, edit.delete_before, edit.delete_after) catch {
        input.client.postNoMemory() catch {};
        return false;
    };
    if (edit.commit) |text| generated.zwp_text_input_v3_types.events.commit_string(&input.client.connection, input.resource, text) catch {
        input.client.postNoMemory() catch {};
        return false;
    };
    generated.zwp_text_input_v3_types.events.done(&input.client.connection, input.resource, input.serial) catch {
        input.client.postNoMemory() catch {};
        return false;
    };
    return true;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *TextInputGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.zwp_text_input_manager_v3, @min(version, 1), .{ .context = self, .dispatch = dispatchManager }) catch return client.postNoMemory();
}
fn dispatchManager(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const self: *TextInputGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zwp_text_input_manager_v3_types.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
        .get_text_input => |r| try self.createInput(client, r.id, !self.seat.ownsResource(client, r.seat)),
    }
}
fn createInput(self: *TextInputGlobal, client: *Server.Client, id: u32, inert: bool) !void {
    self.inputs.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    const input = self.allocator.create(Input) catch return client.postNoMemory();
    var input_owned = true;
    errdefer if (input_owned) self.allocator.destroy(input);
    input.* = .{ .owner = self, .client = client, .resource = undefined, .inert = inert };
    input.resource = client.createResource(id, &generated.zwp_text_input_v3, 1, .{ .context = input, .dispatch = dispatchInput, .destroy = destroyInput }) catch return client.postNoMemory();
    self.inputs.appendAssumeCapacity(input);
    input_owned = false;
    errdefer client.destroyResource(input.resource) catch {};
    if (!inert) if (self.seat.keyboardFocus()) |surface| if (surface.resource_alive and surface.client == client) {
        try generated.zwp_text_input_v3_types.events.enter(&client.connection, input.resource, surface.resource);
    };
}
fn dispatchInput(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const input: *Input = @ptrCast(@alignCast(context));
    const owner = input.owner;
    switch (try generated.zwp_text_input_v3_types.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
        .enable => if (accepts(input)) {
            input.pending.reset(owner.allocator);
            input.pending.transition = true;
        },
        .disable => if (accepts(input)) {
            input.pending.reset(owner.allocator);
            input.pending.transition = false;
        },
        .set_surrounding_text => |r| if (accepts(input) and validSurrounding(r.text, r.cursor, r.anchor)) {
            const copy = owner.allocator.dupe(u8, r.text) catch return client.postNoMemory();
            if (input.pending.surrounding) |old| owner.allocator.free(old.text);
            input.pending.surrounding = .{ .text = copy, .cursor = @intCast(r.cursor), .anchor = @intCast(r.anchor) };
        },
        .set_text_change_cause => |r| {
            if (accepts(input)) input.pending.cause = r.cause;
        },
        .set_content_type => |r| if (accepts(input)) {
            input.pending.hint = r.hint;
            input.pending.purpose = r.purpose;
        },
        .set_cursor_rectangle, .set_available_actions, .show_input_panel, .hide_input_panel => {},
        .commit => if (!input.inert) {
            input.serial +%= 1;
            if (accepts(input)) {
                commit(input);
            } else {
                input.pending.reset(owner.allocator);
            }
        },
    }
}
fn accepts(input: *Input) bool {
    const focus = input.owner.seat.keyboardFocus() orelse return false;
    return !input.inert and focus.resource_alive and focus.client == input.client;
}
fn commit(input: *Input) void {
    const owner = input.owner;
    if (input.pending.transition) |enabled| {
        if (enabled and owner.active != null and owner.active != input) {
            input.pending.reset(owner.allocator);
            return;
        }
        resetCurrent(input);
        input.enabled = enabled;
    }
    if (input.pending.surrounding) |value| {
        if (input.surrounding) |old| owner.allocator.free(old.text);
        input.surrounding = value;
        input.pending.surrounding = null;
    }
    input.cause = input.pending.cause;
    if (input.pending.hint) |hint| {
        input.hint = hint;
        input.purpose = input.pending.purpose;
    }
    input.pending.reset(owner.allocator);
    owner.active = if (input.enabled) input else if (owner.active == input) null else owner.active;
    notify(owner);
}
fn focusChanged(context: *anyopaque, surface: ?*CompositorGlobal.Surface) !void {
    const self: *TextInputGlobal = @ptrCast(@alignCast(context));
    self.active = null;
    for (self.inputs.items) |input| {
        if (input.inert) continue;
        if (self.focused_client == input.client) if (self.focused_surface) |old_surface| if (surfaceResourceAlive(input.client, old_surface))
            generated.zwp_text_input_v3_types.events.leave(&input.client.connection, input.resource, old_surface) catch input.client.postNoMemory() catch {};
        if (surface) |focused| {
            if (focused.resource_alive and focused.client == input.client)
                generated.zwp_text_input_v3_types.events.enter(&input.client.connection, input.resource, focused.resource) catch input.client.postNoMemory() catch {};
        }
        resetCurrent(input);
        input.pending.reset(self.allocator);
    }
    self.focused_client = if (surface) |focused| focused.client else null;
    self.focused_surface = if (surface) |focused| focused.resource else null;
    notify(self);
}
fn destroyInput(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const input: *Input = @ptrCast(@alignCast(context));
    const owner = input.owner;
    const was_active = owner.active == input;
    if (was_active) owner.active = null;
    for (owner.inputs.items, 0..) |item, i| if (item == input) {
        _ = owner.inputs.orderedRemove(i);
        break;
    };
    input.pending.reset(owner.allocator);
    resetCurrent(input);
    owner.allocator.destroy(input);
    if (was_active) notify(owner);
}
fn resetCurrent(input: *Input) void {
    if (input.surrounding) |old| input.owner.allocator.free(old.text);
    input.surrounding = null;
    input.enabled = false;
    input.cause = 0;
    input.hint = 0;
    input.purpose = 0;
}
fn notify(self: *TextInputGlobal) void {
    if (self.listener) |listener| listener.changed(listener.context);
}
fn surfaceResourceAlive(client: *const Server.Client, resource: wayring.ObjectHandle) bool {
    _ = client.connection.objectForHandle(resource, &generated.wl_surface) catch return false;
    return true;
}
fn validIndex(text: []const u8, index: usize) bool {
    return index <= text.len and (index == text.len or text[index] & 0xc0 != 0x80);
}
fn validSurrounding(text: []const u8, cursor: i32, anchor: i32) bool {
    return text.len <= maximum_text_size and std.unicode.utf8ValidateSlice(text) and cursor >= 0 and anchor >= 0 and validIndex(text, @intCast(cursor)) and validIndex(text, @intCast(anchor));
}

test "text validation rejects hostile bounds" {
    try std.testing.expect(validSurrounding("hé", 3, 0));
    try std.testing.expect(!validSurrounding("hé", 2, 0));
    try std.testing.expect(!validSurrounding("x", -1, 0));
    try std.testing.expect(!validSurrounding(&[_]u8{0xff}, 0, 0));
}
