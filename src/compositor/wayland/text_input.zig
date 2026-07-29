//! Text-input state tied to the seat's keyboard-focused surface.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");
const slot_map = @import("../slot_map.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
display: *wl.Server,
global: *wl.Global,
seat: *Seat,
surface_store: *Surface.Store,
inputs: InputStore,
focused_surface: ?Surface.Id,
focused_client: ?*wl.Client,
observed_surface: ?*Surface,
surface_listener: Surface.CommitListener,
active: ?InputId,
listener: ?Listener,
language: ?[:0]u8,

const InputStore = slot_map.SlotMap(InputState, enum { text_input });
const InputId = InputStore.Id;

pub const Listener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
};

pub const SurroundingText = struct {
    text: [:0]const u8,
    cursor: u32,
    anchor: u32,
};

pub const ContentType = struct {
    hint: zwp.TextInputV3.ContentHint = .{},
    purpose: zwp.TextInputV3.ContentPurpose = .normal,
};

pub const CursorRectangle = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const ActiveState = struct {
    surface_id: Surface.Id,
    serial: u32,
    surrounding_text: ?SurroundingText,
    change_cause: zwp.TextInputV3.ChangeCause,
    content_type: ContentType,
    cursor_rectangle: ?CursorRectangle,
    submit_available: bool,
    input_panel_visible: bool,
};

pub const Edit = struct {
    preedit: ?Preedit = null,
    commit_string: ?[:0]const u8 = null,
    delete: ?Delete = null,

    pub const Preedit = struct {
        text: ?[:0]const u8,
        cursor_begin: i32,
        cursor_end: i32,
        hints: []const PreeditSection = &.{},
    };

    pub const PreeditSection = struct {
        start: u32,
        end: u32,
        hint: zwp.TextInputV3.PreeditHint,
    };

    pub const Delete = struct {
        before_length: u32,
        after_length: u32,
    };
};

const OwnedSurroundingText = struct {
    text: [:0]u8,
    cursor: u32,
    anchor: u32,

    fn deinit(self: *OwnedSurroundingText, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }

    fn view(self: *const OwnedSurroundingText) SurroundingText {
        return .{
            .text = self.text,
            .cursor = self.cursor,
            .anchor = self.anchor,
        };
    }
};

const CurrentState = struct {
    enabled: bool = false,
    surrounding_text: ?OwnedSurroundingText = null,
    change_cause: zwp.TextInputV3.ChangeCause = .input_method,
    content_type: ContentType = .{},
    cursor_rectangle: ?CursorRectangle = null,
    committed_cursor_rectangle: ?CursorRectangle = null,
    submit_available: bool = false,

    fn reset(self: *CurrentState, allocator: std.mem.Allocator) void {
        if (self.surrounding_text) |*surrounding| surrounding.deinit(allocator);
        self.* = .{};
    }
};

const PendingState = struct {
    transition: ?Transition = null,
    surrounding_text: ?OwnedSurroundingText = null,
    change_cause: zwp.TextInputV3.ChangeCause = .input_method,
    content_type: ?ContentType = null,
    cursor_rectangle: ?CursorRectangle = null,
    submit_available: ?bool = null,

    const Transition = enum {
        enable,
        disable,
    };

    fn reset(self: *PendingState, allocator: std.mem.Allocator) void {
        if (self.surrounding_text) |*surrounding| surrounding.deinit(allocator);
        self.* = .{};
    }

    fn setTransition(
        self: *PendingState,
        allocator: std.mem.Allocator,
        transition: Transition,
    ) void {
        self.reset(allocator);
        self.transition = transition;
    }
};

const InputState = struct {
    resource: *zwp.TextInputV3,
    current: CurrentState = .{},
    pending: PendingState = .{},
    commit_count: u32 = 0,
    input_panel_visible: bool = false,

    fn reset(self: *InputState, allocator: std.mem.Allocator) void {
        self.current.reset(allocator);
        self.pending.reset(allocator);
        self.input_panel_visible = false;
    }

    fn deinit(self: *InputState, allocator: std.mem.Allocator) void {
        self.reset(allocator);
        self.* = undefined;
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    seat: *Seat,
    surface_store: *Surface.Store,
) !void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .global = undefined,
        .seat = seat,
        .surface_store = surface_store,
        .inputs = .{},
        .focused_surface = null,
        .focused_client = null,
        .observed_surface = null,
        .surface_listener = .{
            .context = self,
            .applied = focusedSurfaceCommitted,
            .surface_destroyed = focusedSurfaceDestroyed,
        },
        .active = null,
        .listener = null,
        .language = null,
    };
    errdefer self.inputs.deinit(allocator);
    self.global = try wl.Global.create(display, zwp.TextInputManagerV3, 2, *Self, self, bind);
    errdefer self.global.destroy();
    try seat.addKeyboardFocusListener(.{
        .context = self,
        .changed = keyboardFocusChanged,
    });
}

pub fn deinit(self: *Self) void {
    if (self.observed_surface) |surface| surface.removeCommitListener(&self.surface_listener);
    self.seat.removeKeyboardFocusListener(self);
    self.global.destroy();
    std.debug.assert(self.inputs.len() == 0);
    self.inputs.deinit(self.allocator);
    if (self.language) |language| self.allocator.free(language);
    self.* = undefined;
}

/// Copies the listener and retains its context until clearListener or deinit.
pub fn setListener(self: *Self, listener: Listener) void {
    std.debug.assert(self.listener == null);
    self.listener = listener;
}

pub fn clearListener(self: *Self) void {
    std.debug.assert(self.listener != null);
    self.listener = null;
}

pub fn activeState(self: *Self) ?ActiveState {
    const surface_id = self.focused_surface orelse return null;
    const state = self.inputs.get(self.active orelse return null) orelse return null;
    if (!state.current.enabled) return null;
    return .{
        .surface_id = surface_id,
        .serial = state.commit_count,
        .surrounding_text = if (state.current.surrounding_text) |*surrounding|
            surrounding.view()
        else
            null,
        .change_cause = state.current.change_cause,
        .content_type = state.current.content_type,
        .cursor_rectangle = state.current.cursor_rectangle,
        .submit_available = state.current.submit_available,
        .input_panel_visible = state.input_panel_visible,
    };
}

pub fn sendEdit(self: *Self, edit: Edit) bool {
    const state = self.inputs.get(self.active orelse return false) orelse return false;
    if (!state.current.enabled) return false;
    if (edit.preedit) |preedit| {
        state.resource.sendPreeditString(
            if (preedit.text) |text| text.ptr else null,
            preedit.cursor_begin,
            preedit.cursor_end,
        );
        if (state.resource.getVersion() >= 2) {
            const text = if (preedit.text) |value| value else "";
            for (preedit.hints) |hint| {
                if (!validUtf8Index(text, hint.start) or
                    !validUtf8Index(text, hint.end) or hint.start > hint.end) continue;
                state.resource.sendPreeditHint(hint.start, hint.end, hint.hint);
            }
        }
    }
    if (edit.delete) |delete| state.resource.sendDeleteSurroundingText(
        delete.before_length,
        delete.after_length,
    );
    if (edit.commit_string) |text| state.resource.sendCommitString(text.ptr);
    state.resource.sendDone(state.commit_count);
    return true;
}

pub fn performSubmit(self: *Self) bool {
    const state = self.inputs.get(self.active orelse return false) orelse return false;
    if (!state.current.enabled or !state.current.submit_available or
        state.resource.getVersion() < 2) return false;
    state.resource.sendAction(.submit, self.display.nextSerial());
    state.resource.sendDone(state.commit_count);
    return true;
}

pub fn setLanguage(self: *Self, language: []const u8) error{OutOfMemory}!void {
    const copy = try self.allocator.dupeZ(u8, language);
    if (self.language) |old| self.allocator.free(old);
    self.language = copy;
    var iterator = self.inputs.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getVersion() >= 2) entry.value.resource.sendLanguage(copy.ptr);
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.TextInputManagerV3.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwp.TextInputManagerV3,
    request: zwp.TextInputManagerV3.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_text_input => |get| {
            if (!self.seat.ownsResource(get.seat)) {
                createInertInput(
                    resource.getClient(),
                    resource.getVersion(),
                    get.id,
                ) catch resource.postNoMemory();
                return;
            }
            InputResource.create(
                self,
                resource.getClient(),
                resource.getVersion(),
                get.id,
            ) catch resource.postNoMemory();
        },
    }
}

fn createInertInput(client: *wl.Client, version: u32, id: u32) !void {
    const resource = try zwp.TextInputV3.create(client, version, id);
    resource.setHandler(?*anyopaque, inertInputRequest, null, null);
}

fn inertInputRequest(
    resource: *zwp.TextInputV3,
    request: zwp.TextInputV3.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        else => {},
    }
}

const InputResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: InputId,

    fn create(
        manager: *Self,
        client: *wl.Client,
        version: u32,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try zwp.TextInputV3.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = manager.allocator.create(InputResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        const id = manager.inputs.insert(manager.allocator, .{ .resource = resource }) catch
            return error.OutOfMemory;
        errdefer _ = manager.inputs.remove(id);
        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = id,
        };
        resource.setHandler(
            *InputResource,
            handleRequest,
            handleDestroy,
            self,
        );
        if (manager.focused_client == client) {
            if (Surface.resourceFor(manager.surface_store, manager.focused_surface.?)) |surface| {
                resource.sendEnter(surface);
            }
        }
        if (version >= 2) if (manager.language) |language| resource.sendLanguage(language.ptr);
    }

    fn handleRequest(
        resource: *zwp.TextInputV3,
        request: zwp.TextInputV3.Request,
        self: *InputResource,
    ) void {
        const state = self.manager.inputs.get(self.id) orelse return;
        switch (request) {
            .destroy => resource.destroy(),
            .commit => self.manager.commit(self.id),
            .set_available_actions => |set| {
                const submit_available = parseAvailableActions(set.available_actions) catch {
                    resource.postError(.invalid_action, "invalid or duplicate text-input action");
                    return;
                };
                if (self.manager.acceptsRequests(resource.getClient())) {
                    state.pending.submit_available = submit_available;
                }
            },
            else => {
                if (!self.manager.acceptsRequests(resource.getClient())) return;
                switch (request) {
                    .enable => state.pending.setTransition(self.allocator, .enable),
                    .disable => state.pending.setTransition(self.allocator, .disable),
                    .set_surrounding_text => |set| self.setSurroundingText(
                        resource,
                        state,
                        set.text,
                        set.cursor,
                        set.anchor,
                    ),
                    .set_text_change_cause => |set| state.pending.change_cause = set.cause,
                    .set_content_type => |set| state.pending.content_type = .{
                        .hint = set.hint,
                        .purpose = set.purpose,
                    },
                    .set_cursor_rectangle => |set| state.pending.cursor_rectangle = .{
                        .x = set.x,
                        .y = set.y,
                        .width = set.width,
                        .height = set.height,
                    },
                    .show_input_panel => {
                        if (state.input_panel_visible) return;
                        state.input_panel_visible = true;
                        self.manager.notify();
                    },
                    .hide_input_panel => {
                        if (!state.input_panel_visible) return;
                        state.input_panel_visible = false;
                        self.manager.notify();
                    },
                    .destroy, .commit, .set_available_actions => unreachable,
                }
            },
        }
    }

    fn setSurroundingText(
        self: *InputResource,
        resource: *zwp.TextInputV3,
        state: *InputState,
        text: [*:0]const u8,
        cursor: i32,
        anchor: i32,
    ) void {
        const value = std.mem.span(text);
        if (!validSurroundingText(value, cursor, anchor)) return;
        const copy = self.allocator.dupeZ(u8, value) catch {
            resource.postNoMemory();
            return;
        };
        if (state.pending.surrounding_text) |*old| old.deinit(self.allocator);
        state.pending.surrounding_text = .{
            .text = copy,
            .cursor = @intCast(cursor),
            .anchor = @intCast(anchor),
        };
    }

    fn handleDestroy(_: *zwp.TextInputV3, self: *InputResource) void {
        if (self.manager.active) |active| {
            if (std.meta.eql(active, self.id)) {
                self.manager.active = null;
                self.manager.notify();
            }
        }
        var state = self.manager.inputs.remove(self.id) orelse {
            self.allocator.destroy(self);
            return;
        };
        state.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn acceptsRequests(self: *Self, client: *wl.Client) bool {
    return self.focused_surface != null and self.focused_client == client;
}

fn commit(self: *Self, id: InputId) void {
    const state = self.inputs.get(id) orelse return;
    state.commit_count +%= 1;
    if (!self.acceptsRequests(state.resource.getClient())) {
        state.pending.reset(self.allocator);
        return;
    }

    const transition = state.pending.transition;
    if (transition == null) {
        const active = self.active orelse {
            state.pending.reset(self.allocator);
            return;
        };
        if (!std.meta.eql(active, id)) {
            state.pending.reset(self.allocator);
            return;
        }
        applyPending(self.allocator, state);
        state.pending.reset(self.allocator);
        self.notify();
        return;
    }

    switch (transition.?) {
        .enable => {
            if (self.active) |active| {
                if (!std.meta.eql(active, id)) {
                    state.pending.reset(self.allocator);
                    return;
                }
            }
            state.current.reset(self.allocator);
            state.current.enabled = true;
            self.active = id;
        },
        .disable => {
            state.current.reset(self.allocator);
            state.input_panel_visible = false;
            if (self.active) |active| {
                if (std.meta.eql(active, id)) self.active = null;
            }
            state.pending.reset(self.allocator);
            self.notify();
            return;
        },
    }

    applyPending(self.allocator, state);
    state.pending.reset(self.allocator);
    self.notify();
}

fn applyPending(allocator: std.mem.Allocator, state: *InputState) void {
    if (state.pending.surrounding_text) |surrounding| {
        if (state.current.surrounding_text) |*old| old.deinit(allocator);
        state.current.surrounding_text = surrounding;
        state.pending.surrounding_text = null;
    }
    state.current.change_cause = state.pending.change_cause;
    if (state.pending.content_type) |content_type| state.current.content_type = content_type;
    if (state.pending.submit_available) |available| state.current.submit_available = available;
    if (state.pending.cursor_rectangle) |rectangle| {
        if (state.resource.getVersion() >= 2) {
            state.current.committed_cursor_rectangle = rectangle;
        } else {
            state.current.cursor_rectangle = rectangle;
        }
    }
}

fn keyboardFocusChanged(context: *anyopaque, _: ?*wl.Client) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.setFocus(self.seat.keyboardFocusedSurface());
}

fn setFocus(self: *Self, next: ?Surface.Id) void {
    if (std.meta.eql(self.focused_surface, next)) return;
    const old_surface = if (self.focused_surface) |id|
        Surface.resourceFor(self.surface_store, id)
    else
        null;
    const old_client = self.focused_client;
    if (self.observed_surface) |surface| surface.removeCommitListener(&self.surface_listener);
    self.observed_surface = null;
    self.focused_surface = null;
    self.focused_client = null;
    self.active = null;
    self.resetInputs();
    if (old_surface) |surface| if (old_client) |client| self.sendLeave(client, surface);

    const surface_id = next orelse {
        self.notify();
        return;
    };
    const resource = Surface.resourceFor(self.surface_store, surface_id) orelse {
        self.notify();
        return;
    };
    const surface = Surface.fromResource(resource);
    surface.addCommitListener(&self.surface_listener) catch {
        resource.postNoMemory();
        self.notify();
        return;
    };
    self.observed_surface = surface;
    self.focused_surface = surface_id;
    self.focused_client = resource.getClient();
    self.sendEnter(resource.getClient(), resource);
    self.notify();
}

fn sendEnter(self: *Self, client: *wl.Client, surface: *wl.Surface) void {
    var iterator = self.inputs.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getClient() == client) entry.value.resource.sendEnter(surface);
    }
}

fn sendLeave(self: *Self, client: *wl.Client, surface: *wl.Surface) void {
    var iterator = self.inputs.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getClient() == client) entry.value.resource.sendLeave(surface);
    }
}

fn resetInputs(self: *Self) void {
    var iterator = self.inputs.iterator();
    while (iterator.next()) |entry| entry.value.reset(self.allocator);
}

fn focusedSurfaceCommitted(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const state = self.inputs.get(self.active orelse return) orelse return;
    const rectangle = state.current.committed_cursor_rectangle orelse return;
    state.current.cursor_rectangle = rectangle;
    state.current.committed_cursor_rectangle = null;
    self.notify();
}

fn focusedSurfaceDestroyed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const surface = self.observed_surface orelse return;
    surface.removeCommitListener(&self.surface_listener);
    self.observed_surface = null;
    self.focused_surface = null;
    self.focused_client = null;
    self.active = null;
    self.resetInputs();
    self.notify();
}

fn notify(self: *Self) void {
    if (self.listener) |listener| listener.changed(listener.context);
}

fn validSurroundingText(text: []const u8, cursor: i32, anchor: i32) bool {
    if (text.len > 4000 or cursor < 0 or anchor < 0 or !std.unicode.utf8ValidateSlice(text)) {
        return false;
    }
    const cursor_index: usize = @intCast(cursor);
    const anchor_index: usize = @intCast(anchor);
    return validUtf8Index(text, cursor_index) and validUtf8Index(text, anchor_index);
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
        while (previous < offset) : (previous += @sizeOf(u32)) {
            if (readArrayU32(bytes, previous) == value) return error.InvalidAction;
        }
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
