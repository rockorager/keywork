//! Mature text-input-v3 frontend for the protocol-neutral seat owner.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const NeutralTextInput = @import("../TextInput.zig");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");
const MatureSerials = @import("mature_serials.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
display: *wl.Server,
global: *wl.Global,
seat: *Seat,
surface_store: *Surface.Store,
owner: *NeutralTextInput,
inputs: std.ArrayList(*InputResource),
observed_surface: ?*Surface,
surface_listener: Surface.CommitListener,
language: ?[:0]u8,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    seat: *Seat,
    surface_store: *Surface.Store,
    owner: *NeutralTextInput,
) !void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .global = undefined,
        .seat = seat,
        .surface_store = surface_store,
        .owner = owner,
        .inputs = .empty,
        .observed_surface = null,
        .surface_listener = .{
            .context = self,
            .applied = focusedSurfaceCommitted,
            .surface_destroyed = focusedSurfaceDestroyed,
        },
        .language = null,
    };
    errdefer self.inputs.deinit(allocator);
    self.global = try wl.Global.create(display, zwp.TextInputManagerV3, 2, *Self, self, bind);
    errdefer self.global.destroy();
    try seat.addKeyboardFocusListener(.{ .context = self, .changed = keyboardFocusChanged });
}

pub fn deinit(self: *Self) void {
    if (self.observed_surface) |surface| surface.removeCommitListener(&self.surface_listener);
    self.seat.removeKeyboardFocusListener(self);
    self.global.destroy();
    std.debug.assert(self.inputs.items.len == 0);
    self.inputs.deinit(self.allocator);
    if (self.language) |language| self.allocator.free(language);
    self.* = undefined;
}

pub fn performSubmit(self: *Self) bool {
    const state = self.owner.activeSnapshot() orelse return false;
    if (!state.submit_available) return false;
    const input = self.activeResource() orelse return false;
    if (input.resource.getVersion() < 2) return false;
    input.resource.sendAction(.submit, MatureSerials.issueWire(self.display));
    input.resource.sendDone(self.owner.activeCommitCount() orelse return false);
    return true;
}

pub fn setLanguage(self: *Self, language: []const u8) error{OutOfMemory}!void {
    const copy = try self.allocator.dupeZ(u8, language);
    if (self.language) |old| self.allocator.free(old);
    self.language = copy;
    for (self.inputs.items) |input| if (input.resource.getVersion() >= 2)
        input.resource.sendLanguage(copy.ptr);
}

fn activeResource(self: *Self) ?*InputResource {
    const active_id = self.owner.activeInputId() orelse return null;
    for (self.inputs.items) |input|
        if (std.meta.eql(input.neutral_id, active_id)) return input;
    return null;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.TextInputManagerV3.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(resource: *zwp.TextInputManagerV3, request: zwp.TextInputManagerV3.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_text_input => |get| {
            if (!self.seat.ownsResource(get.seat)) {
                createInertInput(resource.getClient(), resource.getVersion(), get.id) catch resource.postNoMemory();
                return;
            }
            InputResource.create(self, resource.getClient(), resource.getVersion(), get.id) catch resource.postNoMemory();
        },
    }
}

fn createInertInput(client: *wl.Client, version: u32, id: u32) !void {
    const resource = try zwp.TextInputV3.create(client, version, id);
    resource.setHandler(?*anyopaque, inertInputRequest, null, null);
}
fn inertInputRequest(resource: *zwp.TextInputV3, request: zwp.TextInputV3.Request, _: ?*anyopaque) void {
    if (request == .destroy) resource.destroy();
}

const InputResource = struct {
    manager: *Self,
    resource: *zwp.TextInputV3,
    neutral_id: NeutralTextInput.InputId,

    fn create(manager: *Self, client: *wl.Client, version: u32, protocol_id: u32) !void {
        const resource = try zwp.TextInputV3.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = try manager.allocator.create(InputResource);
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource, .neutral_id = undefined };
        const client_id = manager.seat.matureClientId(client) orelse return error.InvalidClient;
        self.neutral_id = try manager.owner.createInput(client_id, .{
            .context = self,
            .enter = endpointEnter,
            .leave = endpointLeave,
            .preedit = endpointPreedit,
            .commit_string = endpointCommit,
            .delete_surrounding = endpointDelete,
            .done = endpointDone,
        });
        errdefer manager.owner.destroyInput(self.neutral_id);
        try manager.inputs.append(manager.allocator, self);
        resource.setHandler(*InputResource, handleRequest, handleDestroy, self);
        if (version >= 2) if (manager.language) |language| resource.sendLanguage(language.ptr);
    }

    fn handleRequest(resource: *zwp.TextInputV3, request: zwp.TextInputV3.Request, self: *InputResource) void {
        const owner = self.manager.owner;
        switch (request) {
            .destroy => resource.destroy(),
            .commit => owner.commitState(self.neutral_id) catch {},
            .enable => owner.enable(self.neutral_id) catch {},
            .disable => owner.disable(self.neutral_id) catch {},
            .set_surrounding_text => |set| {
                const text = std.mem.span(set.text);
                if (!validSurroundingText(text, set.cursor, set.anchor)) return;
                owner.setSurroundingText(self.neutral_id, text, @intCast(set.cursor), @intCast(set.anchor)) catch |err| {
                    if (err == error.OutOfMemory) resource.postNoMemory();
                };
            },
            .set_text_change_cause => |set| {
                const raw = @intFromEnum(set.cause);
                if (raw > @intFromEnum(NeutralTextInput.ChangeCause.other)) return;
                owner.setTextChangeCause(self.neutral_id, @enumFromInt(raw)) catch {};
            },
            .set_content_type => |set| {
                const raw = @intFromEnum(set.purpose);
                if (raw > @intFromEnum(NeutralTextInput.ContentPurpose.terminal)) return;
                owner.setContentType(self.neutral_id, @bitCast(set.hint), @enumFromInt(raw)) catch {};
            },
            .set_cursor_rectangle => |set| owner.setCursorRectangle(self.neutral_id, .{
                .x = set.x,
                .y = set.y,
                .width = set.width,
                .height = set.height,
            }, resource.getVersion() >= 2) catch {},
            .show_input_panel => owner.setPanelVisible(self.neutral_id, true) catch {},
            .hide_input_panel => owner.setPanelVisible(self.neutral_id, false) catch {},
            .set_available_actions => |set| {
                const submit = parseAvailableActions(set.available_actions) catch {
                    resource.postError(.invalid_action, "invalid or duplicate text-input action");
                    return;
                };
                owner.setSubmitAvailable(self.neutral_id, submit) catch {};
            },
        }
    }

    fn handleDestroy(_: *zwp.TextInputV3, self: *InputResource) void {
        const manager = self.manager;
        manager.owner.destroyInput(self.neutral_id);
        for (manager.inputs.items, 0..) |input, index| if (input == self) {
            _ = manager.inputs.orderedRemove(index);
            break;
        };
        manager.allocator.destroy(self);
    }

    fn endpointEnter(context: *anyopaque, surface_id: Surface.Id) void {
        const self: *InputResource = @ptrCast(@alignCast(context));
        if (Surface.resourceFor(self.manager.surface_store, surface_id)) |surface| self.resource.sendEnter(surface);
    }
    fn endpointLeave(context: *anyopaque, surface_id: Surface.Id) void {
        const self: *InputResource = @ptrCast(@alignCast(context));
        if (Surface.resourceFor(self.manager.surface_store, surface_id)) |surface| self.resource.sendLeave(surface);
    }
    fn endpointPreedit(context: *anyopaque, text: ?[:0]const u8, begin: i32, end: i32) void {
        const self: *InputResource = @ptrCast(@alignCast(context));
        self.resource.sendPreeditString(if (text) |value| value.ptr else null, begin, end);
    }
    fn endpointDelete(context: *anyopaque, before: u32, after: u32) void {
        const self: *InputResource = @ptrCast(@alignCast(context));
        self.resource.sendDeleteSurroundingText(before, after);
    }
    fn endpointCommit(context: *anyopaque, text: ?[:0]const u8) void {
        const self: *InputResource = @ptrCast(@alignCast(context));
        self.resource.sendCommitString(if (text) |value| value.ptr else null);
    }
    fn endpointDone(context: *anyopaque, serial: u32) void {
        const self: *InputResource = @ptrCast(@alignCast(context));
        self.resource.sendDone(serial);
    }
};

fn keyboardFocusChanged(context: *anyopaque, _: ?*wl.Client) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.setFocus(self.seat.keyboardFocusedSurface());
}

fn setFocus(self: *Self, next: ?Surface.Id) void {
    if (self.observed_surface) |surface| if (next) |surface_id| {
        if (std.meta.eql(surface.handle(), surface_id)) return;
    };
    if (self.observed_surface) |surface| surface.removeCommitListener(&self.surface_listener);
    self.observed_surface = null;
    if (next) |surface_id| if (Surface.resourceFor(self.surface_store, surface_id)) |resource| {
        const surface = Surface.fromResource(resource);
        surface.addCommitListener(&self.surface_listener) catch {
            resource.postNoMemory();
            self.owner.setKeyboardFocus(null, null) catch unreachable;
            return;
        };
        self.observed_surface = surface;
    };
    if (next != null and self.observed_surface == null) {
        self.owner.setKeyboardFocus(null, null) catch unreachable;
        return;
    }
    const client = if (next) |surface| self.seat.matureSurfaceOwner(surface) else null;
    self.owner.setKeyboardFocus(next, client) catch {
        if (self.observed_surface) |surface| surface.removeCommitListener(&self.surface_listener);
        self.observed_surface = null;
        self.owner.setKeyboardFocus(null, null) catch unreachable;
    };
}

fn focusedSurfaceCommitted(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const surface = self.seat.keyboardFocusedSurface() orelse return;
    self.owner.surfaceCommitted(surface);
}
fn focusedSurfaceDestroyed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const observed = self.observed_surface orelse return;
    const surface = observed.handle();
    observed.removeCommitListener(&self.surface_listener);
    self.observed_surface = null;
    self.owner.surfaceDestroyed(surface);
}

fn validSurroundingText(text: []const u8, cursor: i32, anchor: i32) bool {
    if (text.len > 4000 or cursor < 0 or anchor < 0 or !std.unicode.utf8ValidateSlice(text)) return false;
    return validUtf8Index(text, @intCast(cursor)) and validUtf8Index(text, @intCast(anchor));
}
fn validUtf8Index(text: []const u8, index: usize) bool {
    if (index > text.len) return false;
    return index == text.len or text[index] & 0xc0 != 0x80;
}
fn parseAvailableActions(array: *const wl.Array) error{InvalidAction}!bool {
    if (array.size % @sizeOf(u32) != 0) return error.InvalidAction;
    if (array.size == 0) return false;
    const data = array.data orelse return error.InvalidAction;
    const bytes: [*]const u8 = @ptrCast(data);
    var submit = false;
    var offset: usize = 0;
    while (offset < array.size) : (offset += @sizeOf(u32)) {
        const value = readArrayU32(bytes, offset);
        if (value == @intFromEnum(zwp.TextInputV3.Action.none)) return error.InvalidAction;
        var previous: usize = 0;
        while (previous < offset) : (previous += @sizeOf(u32))
            if (readArrayU32(bytes, previous) == value) return error.InvalidAction;
        if (value == @intFromEnum(zwp.TextInputV3.Action.submit)) submit = true;
    }
    return submit;
}
fn readArrayU32(bytes: [*]const u8, offset: usize) u32 {
    var value: u32 = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[offset..][0..@sizeOf(u32)]);
    return value;
}

test "surrounding text validates UTF-8 byte boundaries" {
    const text = "aéz";
    try std.testing.expect(validSurroundingText(text, 1, 3));
    try std.testing.expect(!validSurroundingText(text, 2, 3));
    try std.testing.expect(!validSurroundingText(text, -1, 0));
}

test "available actions reject none and duplicate values" {
    const submit = [_]u32{1};
    const duplicate = [_]u32{ 1, 1 };
    const none = [_]u32{0};
    const unknown = [_]u32{2};
    try std.testing.expect(try parseAvailableActions(&arrayFromU32s(&submit)));
    try std.testing.expectError(error.InvalidAction, parseAvailableActions(&arrayFromU32s(&duplicate)));
    try std.testing.expectError(error.InvalidAction, parseAvailableActions(&arrayFromU32s(&none)));
    try std.testing.expect(!(try parseAvailableActions(&arrayFromU32s(&unknown))));
}
fn arrayFromU32s(values: []const u32) wl.Array {
    return .{
        .size = values.len * @sizeOf(u32),
        .alloc = values.len * @sizeOf(u32),
        .data = if (values.len == 0) null else @ptrCast(@constCast(values.ptr)),
    };
}
