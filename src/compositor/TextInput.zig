//! Protocol-resource-free text-input and input-method state for one seat.
//!
//! Frontends retain their resources and stable endpoint contexts. All endpoint
//! calls are synchronous and must not re-enter this owner; slices passed to
//! them are borrowed for the call. Conversely, request strings are borrowed
//! and copied before this owner returns. Seat is the sole authority that calls
//! `setKeyboardFocus`.

const TextInput = @This();

const std = @import("std");
const ClientRegistry = @import("ClientRegistry.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");
const slot_map = @import("slot_map.zig");

pub const ContentHint = packed struct(u32) {
    completion: bool = false,
    spellcheck: bool = false,
    auto_capitalization: bool = false,
    lower_case: bool = false,
    upper_case: bool = false,
    title_case: bool = false,
    hidden_text: bool = false,
    sensitive_data: bool = false,
    latin: bool = false,
    multiline: bool = false,
    _reserved: u22 = 0,
};
pub const ContentPurpose = enum { normal, alpha, digits, number, phone, url, email, name, password, pin, date, time, datetime, terminal };
pub const ChangeCause = enum { input_method, other };
pub const Rectangle = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Delete = struct { before_length: u32, after_length: u32 };

/// Protocol string limit shared by text-input and input-method requests.
pub const max_text_bytes = 4000;

pub const ResourceSnapshot = struct {
    inputs: usize,
    methods: usize,
    keyboard_grabs: usize,
    popups: usize,
};

pub const Snapshot = struct {
    surface: SurfaceRegistry.Id,
    surrounding_text: ?[:0]const u8,
    cursor: u32,
    anchor: u32,
    change_cause: ChangeCause,
    content_hint: ContentHint,
    content_purpose: ContentPurpose,
    cursor_rectangle: ?Rectangle,
    submit_available: bool,
    panel_visible: bool,
};

pub const InputEndpoint = struct {
    context: *anyopaque,
    enter: *const fn (*anyopaque, SurfaceRegistry.Id) void,
    leave: *const fn (*anyopaque, SurfaceRegistry.Id) void,
    preedit: *const fn (*anyopaque, ?[:0]const u8, i32, i32) void,
    commit_string: *const fn (*anyopaque, ?[:0]const u8) void,
    delete_surrounding: *const fn (*anyopaque, u32, u32) void,
    done: *const fn (*anyopaque, u32) void,
};
pub const MethodEndpoint = struct {
    context: *anyopaque,
    activate: *const fn (*anyopaque) void,
    deactivate: *const fn (*anyopaque) void,
    state: *const fn (*anyopaque, Snapshot) void,
    done: *const fn (*anyopaque, u32) void,
    unavailable: *const fn (*anyopaque) void,
};

const InputStore = slot_map.SlotMap(Input, enum { text_input });
const MethodStore = slot_map.SlotMap(Method, enum { input_method });
const GrabStore = slot_map.SlotMap(Owner, enum { keyboard_grab });
const PopupStore = slot_map.SlotMap(Popup, enum { input_popup });
pub const InputId = InputStore.Id;
pub const MethodId = MethodStore.Id;
pub const KeyboardGrabId = GrabStore.Id;
pub const PopupId = PopupStore.Id;

const Owner = struct { client: ClientRegistry.Id, method: MethodId };
const Popup = struct { owner: ClientRegistry.Id, method: MethodId, surface: SurfaceRegistry.Id };
const Surrounding = struct { text: [:0]u8, cursor: u32, anchor: u32 };
const State = struct {
    enabled: bool = false,
    surrounding: ?Surrounding = null,
    cause: ChangeCause = .input_method,
    hint: ContentHint = .{},
    purpose: ContentPurpose = .normal,
    rectangle: ?Rectangle = null,
    staged_rectangle: ?Rectangle = null,
    submit: bool = false,
};
const Transition = enum { enable, disable };
const PendingState = struct {
    transition: ?Transition = null,
    surrounding: ?Surrounding = null,
    cause: ?ChangeCause = null,
    hint: ?ContentHint = null,
    purpose: ?ContentPurpose = null,
    rectangle: ?Rectangle = null,
    defer_rectangle: bool = true,
    submit: ?bool = null,
};
const Input = struct {
    owner: ClientRegistry.Id,
    endpoint: InputEndpoint,
    current: State = .{},
    pending: PendingState = .{},
    commit_count: u32 = 0,
    panel_visible: bool = false,
};
const Edit = struct { preedit: ?OwnedPreedit = null, commit: ?[:0]u8 = null, delete: ?Delete = null };
const OwnedPreedit = struct { text: ?[:0]u8, begin: i32, end: i32 };
const Method = struct { owner: ClientRegistry.Id, endpoint: MethodEndpoint, available: bool, active: bool = false, done_count: u32 = 0, edit: Edit = .{} };

pub const Error = error{ OutOfMemory, InvalidClient, InvalidSurface, InvalidInput, InvalidMethod, InvalidGrab, InvalidPopup, WrongClient, InvalidUtf8, InvalidRange, InvalidSerial, Unavailable, NotFocused };

allocator: std.mem.Allocator,
clients: *const ClientRegistry,
surfaces: *const SurfaceRegistry,
inputs: InputStore = .{},
methods: MethodStore = .{},
grabs: GrabStore = .{},
popups: PopupStore = .{},
focus: ?struct { surface: SurfaceRegistry.Id, client: ClientRegistry.Id } = null,
active_input: ?InputId = null,
active_method: ?MethodId = null,
inhibited: bool = false,

pub fn init(allocator: std.mem.Allocator, clients: *const ClientRegistry, surfaces: *const SurfaceRegistry) TextInput {
    return .{ .allocator = allocator, .clients = clients, .surfaces = surfaces };
}

pub fn deinit(self: *TextInput) void {
    while (self.inputs.len() != 0) {
        var iterator = self.inputs.iterator();
        self.destroyInput(iterator.next().?.id);
    }
    while (self.methods.len() != 0) {
        var iterator = self.methods.iterator();
        self.destroyMethod(iterator.next().?.id);
    }
    while (self.grabs.len() != 0) {
        var iterator = self.grabs.iterator();
        _ = self.grabs.remove(iterator.next().?.id);
    }
    while (self.popups.len() != 0) {
        var iterator = self.popups.iterator();
        _ = self.popups.remove(iterator.next().?.id);
    }
    self.inputs.deinit(self.allocator);
    self.methods.deinit(self.allocator);
    self.grabs.deinit(self.allocator);
    self.popups.deinit(self.allocator);
    self.* = undefined;
}

pub fn createInput(self: *TextInput, owner: ClientRegistry.Id, endpoint: InputEndpoint) Error!InputId {
    if (!self.clients.contains(owner)) return error.InvalidClient;
    const id = self.inputs.insert(self.allocator, .{ .owner = owner, .endpoint = endpoint }) catch
        return error.OutOfMemory;
    if (self.focus) |focus| if (std.meta.eql(focus.client, owner))
        endpoint.enter(endpoint.context, focus.surface);
    return id;
}

pub fn destroyInput(self: *TextInput, id: InputId) void {
    if (self.active_input) |active| if (std.meta.eql(active, id)) self.deactivateInput();
    var input = self.inputs.remove(id) orelse return;
    freeState(self.allocator, &input.current);
    freePending(self.allocator, &input.pending);
}

pub fn enable(self: *TextInput, id: InputId) Error!void {
    const input = self.inputs.get(id) orelse return error.InvalidInput;
    resetPending(self.allocator, &input.pending);
    input.pending.transition = .enable;
}
pub fn disable(self: *TextInput, id: InputId) Error!void {
    const input = self.inputs.get(id) orelse return error.InvalidInput;
    resetPending(self.allocator, &input.pending);
    input.pending.transition = .disable;
}

pub fn setSurroundingText(self: *TextInput, id: InputId, text: []const u8, cursor: u32, anchor: u32) Error!void {
    const input = self.inputs.get(id) orelse return error.InvalidInput;
    if (text.len > max_text_bytes) return error.InvalidRange;
    try validateTextRange(text, cursor);
    try validateTextRange(text, anchor);
    const copy = self.allocator.dupeZ(u8, text) catch return error.OutOfMemory;
    if (input.pending.surrounding) |old| self.allocator.free(old.text);
    input.pending.surrounding = .{ .text = copy, .cursor = cursor, .anchor = anchor };
}
pub fn setTextChangeCause(self: *TextInput, id: InputId, cause: ChangeCause) Error!void {
    const input = self.inputs.get(id) orelse return error.InvalidInput;
    input.pending.cause = cause;
}
pub fn setContentType(self: *TextInput, id: InputId, hint: ContentHint, purpose: ContentPurpose) Error!void {
    const input = self.inputs.get(id) orelse return error.InvalidInput;
    if (hint._reserved != 0) return error.InvalidRange;
    input.pending.hint = hint;
    input.pending.purpose = purpose;
}
pub fn setCursorRectangle(
    self: *TextInput,
    id: InputId,
    rectangle: Rectangle,
    defer_until_surface_commit: bool,
) Error!void {
    const input = self.inputs.get(id) orelse return error.InvalidInput;
    input.pending.rectangle = rectangle;
    input.pending.defer_rectangle = defer_until_surface_commit;
}
pub fn setSubmitAvailable(self: *TextInput, id: InputId, value: bool) Error!void {
    const input = self.inputs.get(id) orelse return error.InvalidInput;
    input.pending.submit = value;
}
pub fn setPanelVisible(self: *TextInput, id: InputId, visible: bool) Error!void {
    const input = self.inputs.get(id) orelse return error.InvalidInput;
    if (input.panel_visible == visible) return;
    input.panel_visible = visible;
    self.syncActive();
}

pub fn activeSnapshot(self: *const TextInput) ?Snapshot {
    const focus = self.focus orelse return null;
    const input = self.inputs.getConst(self.active_input orelse return null) orelse return null;
    if (!input.current.enabled) return null;
    return snapshot(input, focus.surface);
}

pub fn activeCommitCount(self: *const TextInput) ?u32 {
    const input = self.inputs.getConst(self.active_input orelse return null) orelse return null;
    if (!input.current.enabled) return null;
    return input.commit_count;
}

pub fn activeInputId(self: *const TextInput) ?InputId {
    const id = self.active_input orelse return null;
    const input = self.inputs.getConst(id) orelse return null;
    return if (input.current.enabled) id else null;
}

pub fn activeMethodSnapshot(self: *const TextInput, id: MethodId) ?Snapshot {
    const active = self.active_method orelse return null;
    if (!std.meta.eql(active, id)) return null;
    const method = self.methods.getConst(id) orelse return null;
    if (!method.active or self.inhibited) return null;
    return self.activeSnapshot();
}

pub fn resourceSnapshot(self: *const TextInput) ResourceSnapshot {
    return .{
        .inputs = self.inputs.len(),
        .methods = self.methods.len(),
        .keyboard_grabs = self.grabs.len(),
        .popups = self.popups.len(),
    };
}

/// Atomically promotes pending state and publishes one method snapshot/done.
pub fn commitState(self: *TextInput, id: InputId) Error!void {
    const input = self.inputs.get(id) orelse return error.InvalidInput;
    input.commit_count +%= 1;
    const focus = self.focus orelse {
        resetPending(self.allocator, &input.pending);
        return;
    };
    if (!std.meta.eql(input.owner, focus.client)) {
        resetPending(self.allocator, &input.pending);
        return;
    }
    if (input.pending.transition) |transition| switch (transition) {
        .enable => {
            if (self.active_input) |active| if (!std.meta.eql(active, id)) {
                resetPending(self.allocator, &input.pending);
                return;
            };
            freeState(self.allocator, &input.current);
            input.current.enabled = true;
            self.active_input = id;
        },
        .disable => {
            freeState(self.allocator, &input.current);
            input.panel_visible = false;
            if (self.active_input) |active| if (std.meta.eql(active, id)) self.deactivateInput();
            resetPending(self.allocator, &input.pending);
            self.syncActive();
            return;
        },
    } else if (self.active_input == null or !std.meta.eql(self.active_input.?, id)) {
        resetPending(self.allocator, &input.pending);
        return;
    }
    applyPending(self.allocator, input);
    resetPending(self.allocator, &input.pending);
    self.syncActive();
}

/// Surface commit is deliberately separate from text-input commit.
pub fn surfaceCommitted(self: *TextInput, surface: SurfaceRegistry.Id) void {
    const focus = self.focus orelse return;
    if (!std.meta.eql(focus.surface, surface) or !self.surfaces.contains(surface)) return;
    if (self.active_input) |id| if (self.inputs.get(id)) |input| {
        if (input.current.staged_rectangle) |rectangle| {
            input.current.rectangle = rectangle;
            input.current.staged_rectangle = null;
        }
    };
    self.syncActive();
}

pub fn createMethod(self: *TextInput, owner: ClientRegistry.Id, endpoint: MethodEndpoint) Error!MethodId {
    return self.createMethodWithAvailability(owner, endpoint, true);
}

pub fn createMethodWithAvailability(
    self: *TextInput,
    owner: ClientRegistry.Id,
    endpoint: MethodEndpoint,
    may_be_available: bool,
) Error!MethodId {
    if (!self.clients.contains(owner)) return error.InvalidClient;
    const available = may_be_available and self.active_method == null;
    const id = self.methods.insert(self.allocator, .{ .owner = owner, .endpoint = endpoint, .available = available }) catch return error.OutOfMemory;
    if (available) self.active_method = id else endpoint.unavailable(endpoint.context);
    self.syncActive();
    return id;
}
pub fn destroyMethod(self: *TextInput, id: MethodId) void {
    if (self.methods.get(id) == null) return;
    if (self.active_method) |active| if (std.meta.eql(active, id)) {
        self.active_method = null;
    };
    while (true) {
        var found: ?KeyboardGrabId = null;
        var grabs = self.grabs.iterator();
        while (grabs.next()) |entry| if (std.meta.eql(entry.value.method, id)) {
            found = entry.id;
            break;
        };
        _ = self.grabs.remove(found orelse break);
    }
    while (true) {
        var found: ?PopupId = null;
        var popups = self.popups.iterator();
        while (popups.next()) |entry| if (std.meta.eql(entry.value.method, id)) {
            found = entry.id;
            break;
        };
        _ = self.popups.remove(found orelse break);
    }
    var method = self.methods.remove(id) orelse return;
    freeEdit(self.allocator, &method.edit);
}

pub fn setPreedit(self: *TextInput, id: MethodId, value: ?[]const u8, begin: i32, end: i32) Error!void {
    const method = try self.availableMethod(id);
    if (value) |text| {
        if (text.len > max_text_bytes) return error.InvalidRange;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (begin < -1 or end < -1) return error.InvalidRange;
        if ((begin == -1) != (end == -1)) return error.InvalidRange;
        if (begin >= 0) try validateTextRange(text, @intCast(begin));
        if (end >= 0) try validateTextRange(text, @intCast(end));
    }
    const copy = if (value) |text| self.allocator.dupeZ(u8, text) catch return error.OutOfMemory else null;
    if (method.edit.preedit) |old| if (old.text) |text| self.allocator.free(text);
    method.edit.preedit = .{ .text = copy, .begin = begin, .end = end };
}
pub fn setCommitString(self: *TextInput, id: MethodId, value: ?[]const u8) Error!void {
    const method = try self.availableMethod(id);
    if (value) |text| {
        if (text.len > max_text_bytes) return error.InvalidRange;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    }
    const copy = if (value) |text| self.allocator.dupeZ(u8, text) catch return error.OutOfMemory else null;
    if (method.edit.commit) |old| self.allocator.free(old);
    method.edit.commit = copy;
}
pub fn deleteSurrounding(self: *TextInput, id: MethodId, delete: Delete) Error!void {
    const method = try self.availableMethod(id);
    if (delete.before_length == 0 and delete.after_length == 0) {
        method.edit.delete = delete;
        return;
    }
    const input_id = self.active_input orelse return error.NotFocused;
    const surrounding = self.inputs.get(input_id).?.current.surrounding orelse return error.InvalidRange;
    const text_len: u32 = std.math.cast(u32, surrounding.text.len) orelse return error.InvalidRange;
    if (delete.before_length > surrounding.cursor or delete.after_length > text_len - surrounding.cursor) return error.InvalidRange;
    try validateTextRange(surrounding.text, surrounding.cursor - delete.before_length);
    try validateTextRange(surrounding.text, surrounding.cursor + delete.after_length);
    method.edit.delete = delete;
}

/// Emits preedit, delete, commit, then done, matching text-input wire order.
pub fn commitEdit(self: *TextInput, id: MethodId, serial: u32) Error!void {
    const method = try self.availableMethod(id);
    defer freeEdit(self.allocator, &method.edit);
    if (!method.active or serial != method.done_count) return error.InvalidSerial;
    const input = self.inputs.get(self.active_input orelse return error.NotFocused) orelse return error.NotFocused;
    if (method.edit.preedit) |preedit| input.endpoint.preedit(input.endpoint.context, preedit.text, preedit.begin, preedit.end);
    if (method.edit.delete) |delete| input.endpoint.delete_surrounding(input.endpoint.context, delete.before_length, delete.after_length);
    if (method.edit.commit) |text| input.endpoint.commit_string(input.endpoint.context, text);
    input.endpoint.done(input.endpoint.context, input.commit_count);
}

pub fn setKeyboardFocus(self: *TextInput, surface: ?SurfaceRegistry.Id, client: ?ClientRegistry.Id) Error!void {
    if ((surface == null) != (client == null)) return error.InvalidSurface;
    if (surface) |id| if (!self.surfaces.contains(id)) return error.InvalidSurface;
    if (client) |id| if (!self.clients.contains(id)) return error.InvalidClient;
    if (self.focus) |old| {
        if (surface != null and std.meta.eql(old.surface, surface.?) and std.meta.eql(old.client, client.?)) return;
    } else if (surface == null) return;
    if (self.focus) |old| self.sendFocusEvent(old.client, old.surface, false);
    self.deactivateInput();
    var iterator = self.inputs.iterator();
    while (iterator.next()) |entry| {
        freeState(self.allocator, &entry.value.current);
        resetPending(self.allocator, &entry.value.pending);
        entry.value.panel_visible = false;
    }
    self.focus = if (surface) |s| .{ .surface = s, .client = client.? } else null;
    if (self.focus) |next| self.sendFocusEvent(next.client, next.surface, true);
    self.syncActive();
}
pub fn setInhibited(self: *TextInput, inhibited: bool) void {
    if (self.inhibited == inhibited) return;
    self.inhibited = inhibited;
    self.syncActive();
}

pub fn clientDisconnected(self: *TextInput, client: ClientRegistry.Id) void {
    // The registry removes client liveness before notifying us. Retiring the
    // endpoint contexts must therefore never invoke them.
    if (self.focus) |focus| {
        if (std.meta.eql(focus.client, client)) self.focus = null;
    }
    if (self.active_method) |id| {
        if (self.methods.get(id)) |method| {
            if (std.meta.eql(method.owner, client)) {
                method.active = false;
                self.active_method = null;
            }
        }
    }
    if (self.active_input) |id| if (self.inputs.get(id)) |input| {
        if (std.meta.eql(input.owner, client)) self.deactivateInput();
    };
    while (true) {
        var found: ?InputId = null;
        var inputs = self.inputs.iterator();
        while (inputs.next()) |entry| if (std.meta.eql(entry.value.owner, client)) {
            found = entry.id;
            break;
        };
        self.destroyInput(found orelse break);
    }
    while (true) {
        var found: ?MethodId = null;
        var methods = self.methods.iterator();
        while (methods.next()) |entry| if (std.meta.eql(entry.value.owner, client)) {
            found = entry.id;
            break;
        };
        self.destroyMethod(found orelse break);
    }
    while (true) {
        var found: ?KeyboardGrabId = null;
        var grabs = self.grabs.iterator();
        while (grabs.next()) |entry| if (std.meta.eql(entry.value.client, client)) {
            found = entry.id;
            break;
        };
        _ = self.grabs.remove(found orelse break);
    }
    while (true) {
        var found: ?PopupId = null;
        var popups = self.popups.iterator();
        while (popups.next()) |entry| if (std.meta.eql(entry.value.owner, client)) {
            found = entry.id;
            break;
        };
        _ = self.popups.remove(found orelse break);
    }
}
pub fn surfaceDestroyed(self: *TextInput, surface: SurfaceRegistry.Id) void {
    if (self.focus) |focus| if (std.meta.eql(focus.surface, surface)) {
        self.focus = null;
        self.deactivateInput();
        var inputs = self.inputs.iterator();
        while (inputs.next()) |entry| {
            freeState(self.allocator, &entry.value.current);
            resetPending(self.allocator, &entry.value.pending);
            entry.value.panel_visible = false;
        }
    };
    while (true) {
        var found: ?PopupId = null;
        var popups = self.popups.iterator();
        while (popups.next()) |entry| if (std.meta.eql(entry.value.surface, surface)) {
            found = entry.id;
            break;
        };
        _ = self.popups.remove(found orelse break);
    }
}

pub fn createKeyboardGrab(self: *TextInput, method_id: MethodId) Error!KeyboardGrabId {
    const method = self.methods.get(method_id) orelse return error.InvalidMethod;
    return self.grabs.insert(self.allocator, .{ .client = method.owner, .method = method_id }) catch error.OutOfMemory;
}
pub fn destroyKeyboardGrab(self: *TextInput, id: KeyboardGrabId) void {
    _ = self.grabs.remove(id);
}
pub fn createPopup(self: *TextInput, method_id: MethodId, surface: SurfaceRegistry.Id) Error!PopupId {
    const method = self.methods.get(method_id) orelse return error.InvalidMethod;
    if (!self.surfaces.contains(surface)) return error.InvalidSurface;
    return self.popups.insert(self.allocator, .{ .owner = method.owner, .method = method_id, .surface = surface }) catch error.OutOfMemory;
}
pub fn destroyPopup(self: *TextInput, id: PopupId) void {
    _ = self.popups.remove(id);
}

fn availableMethod(self: *TextInput, id: MethodId) Error!*Method {
    const method = self.methods.get(id) orelse return error.InvalidMethod;
    if (!method.available) return error.Unavailable;
    return method;
}
fn sendFocusEvent(self: *TextInput, client: ClientRegistry.Id, surface: SurfaceRegistry.Id, enter: bool) void {
    var iterator = self.inputs.iterator();
    while (iterator.next()) |entry| if (std.meta.eql(entry.value.owner, client)) {
        const endpoint = entry.value.endpoint;
        if (enter) endpoint.enter(endpoint.context, surface) else endpoint.leave(endpoint.context, surface);
    };
}
fn deactivateInput(self: *TextInput) void {
    if (self.active_method) |id| if (self.methods.get(id)) |method| if (method.active) {
        method.endpoint.deactivate(method.endpoint.context);
        method.active = false;
        freeEdit(self.allocator, &method.edit);
        method.done_count +%= 1;
        method.endpoint.done(method.endpoint.context, method.done_count);
    };
    self.active_input = null;
}
fn syncActive(self: *TextInput) void {
    const focus = self.focus orelse {
        self.deactivateInput();
        return;
    };
    var selected: ?InputId = null;
    var iterator = self.inputs.iterator();
    while (iterator.next()) |entry| if (entry.value.current.enabled and std.meta.eql(entry.value.owner, focus.client)) {
        selected = entry.id;
    };
    if (self.active_input == null and selected != null) self.active_input = selected;
    const method_id = self.active_method orelse return;
    const method = self.methods.get(method_id) orelse return;
    if (self.inhibited or self.active_input == null) {
        if (method.active) self.deactivateInput();
        return;
    }
    const input = self.inputs.get(self.active_input.?).?;
    if (!method.active) {
        freeEdit(self.allocator, &method.edit);
        method.active = true;
        method.endpoint.activate(method.endpoint.context);
    }
    method.endpoint.state(method.endpoint.context, snapshot(input, focus.surface));
    method.done_count +%= 1;
    method.endpoint.done(method.endpoint.context, method.done_count);
}
fn snapshot(input: *const Input, surface: SurfaceRegistry.Id) Snapshot {
    const s = input.current.surrounding;
    return .{ .surface = surface, .surrounding_text = if (s) |v| v.text else null, .cursor = if (s) |v| v.cursor else 0, .anchor = if (s) |v| v.anchor else 0, .change_cause = input.current.cause, .content_hint = input.current.hint, .content_purpose = input.current.purpose, .cursor_rectangle = input.current.rectangle, .submit_available = input.current.submit, .panel_visible = input.panel_visible };
}
fn validateTextRange(text: []const u8, offset: u32) Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (offset > text.len or (offset < text.len and (text[offset] & 0xc0) == 0x80)) return error.InvalidRange;
}
fn freeState(allocator: std.mem.Allocator, state: *State) void {
    if (state.surrounding) |s| allocator.free(s.text);
    state.* = .{};
}
fn freePending(allocator: std.mem.Allocator, pending: *PendingState) void {
    if (pending.surrounding) |s| allocator.free(s.text);
    pending.* = .{};
}
fn resetPending(allocator: std.mem.Allocator, pending: *PendingState) void {
    freePending(allocator, pending);
}
fn applyPending(allocator: std.mem.Allocator, input: *Input) void {
    if (input.pending.surrounding) |surrounding| {
        if (input.current.surrounding) |old| allocator.free(old.text);
        input.current.surrounding = surrounding;
        input.pending.surrounding = null;
    }
    if (input.pending.cause) |cause| input.current.cause = cause;
    if (input.pending.hint) |hint| input.current.hint = hint;
    if (input.pending.purpose) |purpose| input.current.purpose = purpose;
    if (input.pending.rectangle) |rectangle| {
        if (input.pending.defer_rectangle) {
            input.current.staged_rectangle = rectangle;
        } else {
            input.current.rectangle = rectangle;
        }
    }
    if (input.pending.submit) |submit| input.current.submit = submit;
}
fn freeEdit(allocator: std.mem.Allocator, edit: *Edit) void {
    if (edit.preedit) |p| if (p.text) |text| allocator.free(text);
    if (edit.commit) |text| allocator.free(text);
    edit.* = .{};
}

test "neutral owner rejects stale clients surfaces and UTF-8 boundaries" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var owner = TextInput.init(std.testing.allocator, &clients, &surfaces);
    defer owner.deinit();
    const client = try clients.register(.mature_display);
    clients.unregister(client);
    const N = struct {
        fn no(_: *anyopaque, _: SurfaceRegistry.Id) void {}
        fn text(_: *anyopaque, _: ?[:0]const u8, _: i32, _: i32) void {}
        fn string(_: *anyopaque, _: ?[:0]const u8) void {}
        fn del(_: *anyopaque, _: u32, _: u32) void {}
        fn done(_: *anyopaque, _: u32) void {}
    };
    var byte: u8 = 0;
    const endpoint: InputEndpoint = .{ .context = &byte, .enter = N.no, .leave = N.no, .preedit = N.text, .commit_string = N.string, .delete_surrounding = N.del, .done = N.done };
    try std.testing.expectError(error.InvalidClient, owner.createInput(client, endpoint));
    const current = try clients.register(.mature_display);
    defer clients.unregister(current);
    const id = try owner.createInput(current, endpoint);
    try std.testing.expectError(error.InvalidRange, owner.setSurroundingText(id, "é", 1, 0));
    try owner.setSurroundingText(id, "é", 2, 0);
    try owner.setTextChangeCause(id, .other);
}

const TestProbe = struct {
    events: std.ArrayList(u8) = .empty,
    last_text: [max_text_bytes]u8 = undefined,
    last_text_len: usize = 0,
    last_serial: u32 = 0,
    callbacks: usize = 0,

    fn add(self: *TestProbe, allocator: std.mem.Allocator, event: []const u8) void {
        self.events.appendSlice(allocator, event) catch unreachable;
        self.callbacks += 1;
    }
    fn save(self: *TestProbe, text: ?[]const u8) void {
        const bytes = text orelse return;
        @memcpy(self.last_text[0..bytes.len], bytes);
        self.last_text_len = bytes.len;
    }
    fn enter(context: *anyopaque, _: SurfaceRegistry.Id) void {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        self.add(std.testing.allocator, "enter ");
    }
    fn leave(context: *anyopaque, _: SurfaceRegistry.Id) void {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        self.add(std.testing.allocator, "leave ");
    }
    fn preedit(context: *anyopaque, text: ?[:0]const u8, _: i32, _: i32) void {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        self.save(text);
        self.add(std.testing.allocator, "preedit ");
    }
    fn string(context: *anyopaque, text: ?[:0]const u8) void {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        self.save(text);
        self.add(std.testing.allocator, "commit ");
    }
    fn delete(context: *anyopaque, _: u32, _: u32) void {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        self.add(std.testing.allocator, "delete ");
    }
    fn inputDone(context: *anyopaque, serial: u32) void {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        self.last_serial = serial;
        self.add(std.testing.allocator, "input-done ");
    }
    fn activate(context: *anyopaque) void {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        self.add(std.testing.allocator, "activate ");
    }
    fn deactivate(context: *anyopaque) void {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        self.add(std.testing.allocator, "deactivate ");
    }
    fn state(context: *anyopaque, value: Snapshot) void {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        self.save(value.surrounding_text);
        self.add(std.testing.allocator, "state ");
    }
    fn methodDone(context: *anyopaque, serial: u32) void {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        self.last_serial = serial;
        self.add(std.testing.allocator, "method-done ");
    }
    fn unavailable(context: *anyopaque) void {
        const self: *TestProbe = @ptrCast(@alignCast(context));
        self.add(std.testing.allocator, "unavailable ");
    }
    fn inputEndpoint(self: *TestProbe) InputEndpoint {
        return .{ .context = self, .enter = enter, .leave = leave, .preedit = preedit, .commit_string = string, .delete_surrounding = delete, .done = inputDone };
    }
    fn methodEndpoint(self: *TestProbe) MethodEndpoint {
        return .{ .context = self, .activate = activate, .deactivate = deactivate, .state = state, .done = methodDone, .unavailable = unavailable };
    }
    fn clear(self: *TestProbe) void {
        self.events.clearRetainingCapacity();
        self.callbacks = 0;
    }
    fn deinit(self: *TestProbe) void {
        self.events.deinit(std.testing.allocator);
    }
};

fn testSurface(_: *anyopaque) ?SurfaceRegistry.RenderState {
    return null;
}

test "pending transactions preserve fields and disable clears active state" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var owner = TextInput.init(std.testing.allocator, &clients, &surfaces);
    defer owner.deinit();
    var probe: TestProbe = .{};
    defer probe.deinit();
    const client = try clients.register(.mature_display);
    const surface = try surfaces.add(.{ .context = &probe, .render_state = testSurface });
    const input = try owner.createInput(client, probe.inputEndpoint());
    try owner.setKeyboardFocus(surface, client);
    var text = [_]u8{ 'h', 'i' };
    try owner.enable(input);
    try owner.setSurroundingText(input, &text, 2, 1);
    try owner.setTextChangeCause(input, .other);
    try owner.setContentType(input, .{ .multiline = true }, .terminal);
    try owner.setCursorRectangle(input, .{ .x = 1, .y = 2, .width = 3, .height = 4 }, false);
    try owner.setSubmitAvailable(input, true);
    text = .{ 'n', 'o' };
    try owner.commitState(input);
    const first = owner.activeSnapshot().?;
    try std.testing.expectEqualStrings("hi", first.surrounding_text.?);
    try std.testing.expectEqual(ChangeCause.other, first.change_cause);
    try std.testing.expect(first.content_hint.multiline and first.submit_available);
    try owner.setSubmitAvailable(input, false);
    try owner.commitState(input);
    const second = owner.activeSnapshot().?;
    try std.testing.expectEqualStrings("hi", second.surrounding_text.?);
    try std.testing.expectEqual(ContentPurpose.terminal, second.content_purpose);
    try owner.disable(input);
    try owner.commitState(input);
    try std.testing.expectEqual(@as(?Snapshot, null), owner.activeSnapshot());
    owner.destroyInput(input);
    surfaces.remove(surface);
    clients.unregister(client);
}

test "focus method ordering serial validation inhibition and owned edit copies" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var owner = TextInput.init(std.testing.allocator, &clients, &surfaces);
    defer owner.deinit();
    var input_probe: TestProbe = .{};
    defer input_probe.deinit();
    var method_probe: TestProbe = .{};
    defer method_probe.deinit();
    const client = try clients.register(.mature_display);
    const method_client = try clients.register(.wayring_server);
    const surface = try surfaces.add(.{ .context = &input_probe, .render_state = testSurface });
    const first = try owner.createInput(client, input_probe.inputEndpoint());
    const second = try owner.createInput(client, input_probe.inputEndpoint());
    const method = try owner.createMethod(method_client, method_probe.methodEndpoint());
    try owner.setKeyboardFocus(surface, client);
    try std.testing.expectEqualStrings("enter enter ", input_probe.events.items);
    try owner.enable(first);
    try owner.setSurroundingText(first, "", 0, 0);
    try owner.commitState(first);
    try std.testing.expectEqualStrings("activate state method-done ", method_probe.events.items);
    method_probe.clear();
    input_probe.clear();
    var preedit = [_]u8{ 'o', 'k' };
    var commit = [_]u8{ '!', '!' };
    try owner.setPreedit(method, &preedit, 0, 2);
    try owner.deleteSurrounding(method, .{ .before_length = 0, .after_length = 0 });
    try owner.setCommitString(method, &commit);
    preedit = .{ 'x', 'x' };
    commit = .{ 'x', 'x' };
    try owner.commitEdit(method, 1);
    try std.testing.expectEqualStrings("preedit delete commit input-done ", input_probe.events.items);
    try std.testing.expectEqualStrings("!!", input_probe.last_text[0..input_probe.last_text_len]);
    try std.testing.expectEqual(@as(u32, 1), input_probe.last_serial);
    try owner.setCommitString(method, "stale");
    try std.testing.expectError(error.InvalidSerial, owner.commitEdit(method, 0));
    input_probe.clear();
    try owner.commitEdit(method, 1);
    try std.testing.expectEqualStrings("input-done ", input_probe.events.items);
    owner.setInhibited(true);
    try std.testing.expectEqual(@as(?Snapshot, null), owner.activeMethodSnapshot(method));
    try std.testing.expectEqualStrings("deactivate method-done ", method_probe.events.items);
    method_probe.clear();
    owner.setInhibited(false);
    try std.testing.expect(owner.activeMethodSnapshot(method) != null);
    try std.testing.expectEqualStrings("activate state method-done ", method_probe.events.items);
    try owner.setKeyboardFocus(null, null);
    try std.testing.expect(std.mem.count(u8, input_probe.events.items, "leave ") == 2);
    owner.destroyInput(second);
    owner.destroyInput(first);
    owner.destroyMethod(method);
    surfaces.remove(surface);
    clients.unregister(method_client);
    clients.unregister(client);
}

test "UTF-8 deletion preedit and protocol string limits are validated" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var owner = TextInput.init(std.testing.allocator, &clients, &surfaces);
    defer owner.deinit();
    var probe: TestProbe = .{};
    defer probe.deinit();
    const client = try clients.register(.mature_display);
    const surface = try surfaces.add(.{ .context = &probe, .render_state = testSurface });
    const input = try owner.createInput(client, probe.inputEndpoint());
    const method = try owner.createMethod(client, probe.methodEndpoint());
    try owner.setKeyboardFocus(surface, client);
    try owner.enable(input);
    try owner.setSurroundingText(input, "aéb", 3, 3);
    try owner.commitState(input);
    try std.testing.expectError(error.InvalidRange, owner.deleteSurrounding(method, .{ .before_length = 1, .after_length = 0 }));
    try std.testing.expectError(error.InvalidRange, owner.setPreedit(method, "abc", -1, 0));
    try std.testing.expectError(error.InvalidRange, owner.setPreedit(method, "é", 1, 2));
    var maximum: [max_text_bytes]u8 = @splat('a');
    try owner.setSurroundingText(input, &maximum, max_text_bytes, max_text_bytes);
    try owner.setPreedit(method, &maximum, 0, max_text_bytes);
    try owner.setCommitString(method, &maximum);
    var too_long: [max_text_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.InvalidRange, owner.setSurroundingText(input, &too_long, 0, 0));
    try std.testing.expectError(error.InvalidRange, owner.setPreedit(method, &too_long, 0, 0));
    try std.testing.expectError(error.InvalidRange, owner.setCommitString(method, &too_long));
    owner.destroyInput(input);
    owner.destroyMethod(method);
    surfaces.remove(surface);
    clients.unregister(client);
}

test "client and surface teardown retire resources and reject stale generations" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var owner = TextInput.init(std.testing.allocator, &clients, &surfaces);
    defer owner.deinit();
    var probe: TestProbe = .{};
    defer probe.deinit();
    const client = try clients.register(.mature_display);
    const surface = try surfaces.add(.{ .context = &probe, .render_state = testSurface });
    const input = try owner.createInput(client, probe.inputEndpoint());
    const method = try owner.createMethod(client, probe.methodEndpoint());
    const grab = try owner.createKeyboardGrab(method);
    const popup = try owner.createPopup(method, surface);
    try owner.setKeyboardFocus(surface, client);
    try owner.enable(input);
    try owner.commitState(input);
    owner.surfaceDestroyed(surface);
    try std.testing.expectEqual(@as(?InputId, null), owner.activeInputId());
    try std.testing.expectEqual(ResourceSnapshot{ .inputs = 1, .methods = 1, .keyboard_grabs = 1, .popups = 0 }, owner.resourceSnapshot());
    probe.clear();
    owner.clientDisconnected(client);
    try std.testing.expectEqual(ResourceSnapshot{ .inputs = 0, .methods = 0, .keyboard_grabs = 0, .popups = 0 }, owner.resourceSnapshot());
    try std.testing.expectEqual(@as(usize, 0), probe.callbacks);
    try std.testing.expectError(error.InvalidInput, owner.enable(input));
    try std.testing.expectError(error.InvalidMethod, owner.setCommitString(method, "x"));
    owner.destroyKeyboardGrab(grab);
    owner.destroyPopup(popup);
    surfaces.remove(surface);
    clients.unregister(client);
}

test "focused client disconnect deactivates a live input method without stale endpoint calls" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var owner = TextInput.init(std.testing.allocator, &clients, &surfaces);
    defer owner.deinit();
    var input_probe: TestProbe = .{};
    defer input_probe.deinit();
    var method_probe: TestProbe = .{};
    defer method_probe.deinit();
    const client = try clients.register(.mature_display);
    const method_client = try clients.register(.wayring_server);
    const surface = try surfaces.add(.{ .context = &input_probe, .render_state = testSurface });
    const input = try owner.createInput(client, input_probe.inputEndpoint());
    const method = try owner.createMethod(method_client, method_probe.methodEndpoint());
    try owner.setKeyboardFocus(surface, client);
    try owner.enable(input);
    try owner.commitState(input);
    input_probe.clear();
    method_probe.clear();

    clients.unregister(client);
    owner.clientDisconnected(client);
    try std.testing.expectEqualStrings("deactivate method-done ", method_probe.events.items);
    try std.testing.expectEqual(@as(usize, 0), input_probe.callbacks);
    try std.testing.expectEqual(ResourceSnapshot{ .inputs = 0, .methods = 1, .keyboard_grabs = 0, .popups = 0 }, owner.resourceSnapshot());
    try std.testing.expectEqual(@as(?InputId, null), owner.activeInputId());

    owner.destroyMethod(method);
    surfaces.remove(surface);
    clients.unregister(method_client);
}

test "allocation failures leave no resources and string replacement rolls back" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    const client = try clients.register(.mature_display);
    var probe: TestProbe = .{};
    defer probe.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var owner = TextInput.init(failing.allocator(), &clients, &surfaces);
    try std.testing.expectError(error.OutOfMemory, owner.createInput(client, probe.inputEndpoint()));
    try std.testing.expectError(error.OutOfMemory, owner.createMethod(client, probe.methodEndpoint()));
    try std.testing.expectEqual(ResourceSnapshot{ .inputs = 0, .methods = 0, .keyboard_grabs = 0, .popups = 0 }, owner.resourceSnapshot());
    owner.deinit();

    owner = TextInput.init(std.testing.allocator, &clients, &surfaces);
    defer owner.deinit();
    const input = try owner.createInput(client, probe.inputEndpoint());
    const method = try owner.createMethod(client, probe.methodEndpoint());
    const surface = try surfaces.add(.{ .context = &probe, .render_state = testSurface });
    try owner.setKeyboardFocus(surface, client);
    try owner.enable(input);
    try owner.setSurroundingText(input, "old", 3, 3);
    try owner.setCommitString(method, "old");
    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    owner.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, owner.createKeyboardGrab(method));
    try std.testing.expectError(error.OutOfMemory, owner.createPopup(method, surface));
    try std.testing.expectEqual(ResourceSnapshot{ .inputs = 1, .methods = 1, .keyboard_grabs = 0, .popups = 0 }, owner.resourceSnapshot());
    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    owner.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, owner.setSurroundingText(input, "new", 3, 3));
    owner.allocator = std.testing.allocator;
    try owner.commitState(input);
    try std.testing.expectEqualStrings("old", owner.activeSnapshot().?.surrounding_text.?);
    owner.destroyInput(input);
    owner.destroyMethod(method);
    surfaces.remove(surface);
    clients.unregister(client);
}
