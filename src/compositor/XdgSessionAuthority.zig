//! Frontend-neutral durable XDG toplevel session authority.

const Self = @This();

const std = @import("std");
const ClientRegistry = @import("ClientRegistry.zig");
const WindowManager = @import("window_manager.zig");
const XdgShell = @import("XdgShell.zig");

const log = std.log.scoped(.xdg_session_authority);
const maximum_state_file_size = 1024 * 1024;

pub const SessionEndpoint = struct {
    context: *anyopaque,
    replaced: *const fn (*anyopaque) void,
};

pub const AssociationEndpoint = struct {
    context: *anyopaque,
    restored: *const fn (*anyopaque) void,
    inert: *const fn (*anyopaque) void,
};

pub const SessionHandle = *StoredSession;
pub const AssociationHandle = *Association;
pub const AcquireResult = struct { session: SessionHandle, id: [:0]const u8, restored: bool };
pub const AddError = error{
    InactiveSession,
    InvalidClient,
    AlreadyMapped,
    AlreadyAdded,
    NameInUse,
    InvalidWindow,
    OutOfMemory,
};
pub const RenameError = error{ NameInUse, OutOfMemory };

const OwnedState = struct {
    output_name: []u8,
    workspace: u8,
    floating: bool,
    position: ?Position,
    width: u32,
    height: u32,
    maximized: bool,
    fullscreen: bool,
    minimized: bool,

    const Position = struct { x: i32, y: i32 };

    fn init(allocator: std.mem.Allocator, state: WindowManager.SessionState) !OwnedState {
        return .{ .output_name = try allocator.dupe(u8, state.output_name), .workspace = state.workspace, .floating = state.floating, .position = if (state.position) |p| .{ .x = p.x, .y = p.y } else null, .width = state.size.width, .height = state.size.height, .maximized = state.maximized, .fullscreen = state.fullscreen, .minimized = state.minimized };
    }
    fn deinit(self: *OwnedState, allocator: std.mem.Allocator) void {
        allocator.free(self.output_name);
        self.* = undefined;
    }
    fn eql(self: OwnedState, state: WindowManager.SessionState) bool {
        const position_matches = if (self.position) |p| state.position != null and p.x == state.position.?.x and p.y == state.position.?.y else state.position == null;
        return std.mem.eql(u8, self.output_name, state.output_name) and self.workspace == state.workspace and
            self.floating == state.floating and position_matches and self.width == state.size.width and
            self.height == state.size.height and self.maximized == state.maximized and
            self.fullscreen == state.fullscreen and self.minimized == state.minimized;
    }
    fn borrowed(self: *const OwnedState) WindowManager.SessionState {
        return .{ .output_name = self.output_name, .workspace = self.workspace, .floating = self.floating, .position = if (self.position) |p| .{ .x = p.x, .y = p.y } else null, .size = .{ .width = self.width, .height = self.height }, .maximized = self.maximized, .fullscreen = self.fullscreen, .minimized = self.minimized };
    }
};

const StoredToplevel = struct {
    name: []u8,
    state: ?OwnedState = null,
    fn deinit(self: *StoredToplevel, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.state) |*s| s.deinit(allocator);
        allocator.destroy(self);
    }
    fn update(self: *StoredToplevel, allocator: std.mem.Allocator, state: WindowManager.SessionState) !bool {
        if (self.state) |current| if (current.eql(state)) return false;
        var replacement = try OwnedState.init(allocator, state);
        errdefer replacement.deinit(allocator);
        if (self.state) |*current| current.deinit(allocator);
        self.state = replacement;
        return true;
    }
};
const Active = struct { client: ClientRegistry.Id, endpoint: SessionEndpoint };
const StoredSession = struct {
    id: [:0]u8,
    toplevels: std.StringHashMapUnmanaged(*StoredToplevel) = .empty,
    active: ?Active = null,
    fn deinit(self: *StoredSession, allocator: std.mem.Allocator) void {
        var it = self.toplevels.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(allocator);
        self.toplevels.deinit(allocator);
        allocator.free(self.id);
        allocator.destroy(self);
    }
};
const Association = struct { session: *StoredSession, toplevel: *StoredToplevel, window_id: XdgShell.WindowId, client: ClientRegistry.Id, endpoint: ?AssociationEndpoint };

const Persisted = struct { version: u32, sessions: []const PersistedSession };
const PersistedSession = struct { id: []const u8, toplevels: []const PersistedToplevel };
const PersistedToplevel = struct { name: []const u8, state: ?PersistedState = null };
const PersistedState = struct { output_name: []const u8, workspace: u8, floating: bool, position: ?OwnedState.Position = null, width: u32, height: u32, maximized: bool, fullscreen: bool, minimized: bool };

allocator: std.mem.Allocator,
io: std.Io,
core: *XdgShell,
window_manager: *WindowManager,
sessions: std.StringHashMapUnmanaged(*StoredSession) = .empty,
associations: std.ArrayList(*Association) = .empty,
storage_path: ?[]u8 = null,

pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, core: *XdgShell, window_manager: *WindowManager) !void {
    self.* = .{ .allocator = allocator, .io = io, .core = core, .window_manager = window_manager };
    errdefer self.sessions.deinit(allocator);
    errdefer self.associations.deinit(allocator);
    try core.addWindowObserver(.{ .context = self, .committed = windowCommitted, .unmapped = windowUnmapped, .destroyed = windowDestroyed, .metadata_changed = windowMetadataChanged, .state_changed = windowStateChanged });
    errdefer core.removeWindowObserver(self);
    window_manager.setSessionListener(.{ .context = self, .state_for_remap = windowStateForRemap, .restored = windowRestored, .changed = windowChanged });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.associations.items.len == 0);
    self.saveWarn();
    self.window_manager.clearSessionListener();
    self.core.removeWindowObserver(self);
    self.clearStoredSessions();
    self.sessions.deinit(self.allocator);
    self.associations.deinit(self.allocator);
    if (self.storage_path) |path| self.allocator.free(path);
    self.* = undefined;
}

pub fn configureStorage(self: *Self, runtime_directory: []const u8, instance_name: []const u8) !void {
    std.debug.assert(self.storage_path == null);
    std.debug.assert(self.sessions.count() == 0);
    if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
    if (!std.mem.eql(u8, std.fs.path.basename(instance_name), instance_name)) return error.InvalidInstanceName;
    const file_name = try std.fmt.allocPrint(self.allocator, "xdg-sessions-{s}.json", .{instance_name});
    defer self.allocator.free(file_name);
    self.storage_path = try std.fs.path.join(self.allocator, &.{ runtime_directory, "keywork", file_name });
    errdefer {
        self.allocator.free(self.storage_path.?);
        self.storage_path = null;
    }
    self.load() catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        error.OutOfMemory => return error.OutOfMemory,
        else => log.warn("ignoring unreadable XDG session state: {t}", .{err}),
    };
}

pub fn acquire(self: *Self, requested_id: ?[]const u8, client: ClientRegistry.Id, endpoint: SessionEndpoint) error{ OutOfMemory, InUse }!AcquireResult {
    var created: ?*StoredSession = null;
    defer if (created) |stored| self.removeStoredSession(stored);
    const stored = if (requested_id) |id| self.sessions.get(id) orelse blk: {
        const s = self.generateSession() catch return error.OutOfMemory;
        created = s;
        break :blk s;
    } else blk: {
        const s = self.generateSession() catch return error.OutOfMemory;
        created = s;
        break :blk s;
    };
    if (stored.active) |active| if (std.meta.eql(active.client, client)) return error.InUse;
    if (stored.active) |active| {
        active.endpoint.replaced(active.endpoint.context);
        self.endSession(stored, false);
    }
    const restored = created == null;
    stored.active = .{ .client = client, .endpoint = endpoint };
    created = null;
    self.saveWarn();
    return .{ .session = stored, .id = stored.id, .restored = restored };
}

pub fn release(self: *Self, session: SessionHandle, endpoint_context: *anyopaque, remove: bool) void {
    const active = session.active orelse return;
    if (active.endpoint.context != endpoint_context) return;
    self.endSession(session, remove);
}

pub fn addToplevel(self: *Self, session: SessionHandle, client: ClientRegistry.Id, window_id: XdgShell.WindowId, name: []const u8, restore: bool, endpoint: AssociationEndpoint) AddError!AssociationHandle {
    const active = session.active orelse return error.InactiveSession;
    if (!std.meta.eql(active.client, client)) return error.InvalidClient;
    const info = self.core.windowInfo(window_id) orelse return error.InvalidWindow;
    if (!std.meta.eql(info.client, client)) return error.InvalidClient;
    if (restore and (info.ready or info.mapped)) return error.AlreadyMapped;
    for (self.associations.items) |a| if (std.meta.eql(a.client, client) and std.meta.eql(a.window_id, window_id)) return error.AlreadyAdded;
    var created: ?*StoredToplevel = null;
    defer if (created) |t| self.removeStoredToplevel(session, t);
    var known = session.toplevels.get(name);
    if (!restore and known != null) return error.NameInUse;
    if (known) |t| for (self.associations.items) |a| if (a.session == session and a.toplevel == t) return error.NameInUse;
    if (known == null) {
        known = self.createStoredToplevel(session, name) catch return error.OutOfMemory;
        created = known;
    }
    const toplevel = known.?;
    if (restore) if (toplevel.state) |*state| self.window_manager.prepareSessionRestore(window_id, state.borrowed()) catch |err| return switch (err) {
        error.AlreadyMapped => error.AlreadyMapped,
        error.InvalidWindow => error.InvalidWindow,
        error.OutOfMemory => error.OutOfMemory,
    };
    errdefer self.window_manager.cancelSessionRestore(window_id);
    const association = try self.allocator.create(Association);
    errdefer self.allocator.destroy(association);
    association.* = .{ .session = session, .toplevel = toplevel, .window_id = window_id, .client = client, .endpoint = endpoint };
    try self.associations.append(self.allocator, association);
    created = null;
    self.captureWindow(window_id);
    self.saveWarn();
    return association;
}

pub fn detachAssociationEndpoint(_: *Self, association: AssociationHandle, context: *anyopaque) void {
    if (association.endpoint) |endpoint| {
        if (endpoint.context == context) association.endpoint = null;
    }
}
pub fn rename(self: *Self, association: AssociationHandle, name: []const u8) RenameError!void {
    if (std.mem.eql(u8, association.toplevel.name, name)) return;
    if (association.session.toplevels.contains(name)) return error.NameInUse;
    const replacement = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(replacement);
    try association.session.toplevels.put(self.allocator, replacement, association.toplevel);
    const previous = association.toplevel.name;
    std.debug.assert(association.session.toplevels.remove(previous));
    association.toplevel.name = replacement;
    self.allocator.free(previous);
    self.saveWarn();
}
pub fn removeToplevel(self: *Self, session: SessionHandle, name: []const u8) void {
    const toplevel = session.toplevels.get(name) orelse return;
    var index = self.associations.items.len;
    while (index > 0) {
        index -= 1;
        const a = self.associations.items[index];
        if (a.session == session and a.toplevel == toplevel) self.removeAssociation(index);
    }
    self.removeStoredToplevel(session, toplevel);
    self.saveWarn();
}

fn endSession(self: *Self, session: *StoredSession, remove: bool) void {
    var index = self.associations.items.len;
    while (index > 0) {
        index -= 1;
        const a = self.associations.items[index];
        if (a.session != session) continue;
        _ = self.captureAssociation(a);
        self.removeAssociation(index);
    }
    session.active = null;
    if (remove) self.removeStoredSession(session);
    self.saveWarn();
}
fn removeAssociation(self: *Self, index: usize) void {
    const a = self.associations.orderedRemove(index);
    self.window_manager.cancelSessionRestore(a.window_id);
    if (a.endpoint) |e| e.inert(e.context);
    self.allocator.destroy(a);
}
fn captureAssociation(self: *Self, a: *Association) bool {
    const state = self.window_manager.sessionState(a.window_id) orelse return false;
    return a.toplevel.update(self.allocator, state) catch |err| {
        log.warn("failed to update XDG toplevel session state: {t}", .{err});
        return false;
    };
}
fn captureWindow(self: *Self, window: XdgShell.WindowId) void {
    var changed = false;
    for (self.associations.items) |a| if (std.meta.eql(a.window_id, window)) {
        changed = self.captureAssociation(a) or changed;
    };
    if (changed) self.saveWarn();
}
fn createStoredSession(self: *Self, id: []const u8) !*StoredSession {
    const s = try self.allocator.create(StoredSession);
    errdefer self.allocator.destroy(s);
    const owned = try self.allocator.dupeSentinel(u8, id, 0);
    errdefer self.allocator.free(owned);
    s.* = .{ .id = owned };
    errdefer s.toplevels.deinit(self.allocator);
    try self.sessions.put(self.allocator, s.id, s);
    return s;
}
fn createStoredToplevel(self: *Self, session: *StoredSession, name: []const u8) !*StoredToplevel {
    const t = try self.allocator.create(StoredToplevel);
    errdefer self.allocator.destroy(t);
    const owned = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(owned);
    t.* = .{ .name = owned };
    try session.toplevels.put(self.allocator, t.name, t);
    return t;
}
fn removeStoredSession(self: *Self, session: *StoredSession) void {
    std.debug.assert(session.active == null);
    std.debug.assert(self.sessions.remove(session.id));
    session.deinit(self.allocator);
}
fn removeStoredToplevel(self: *Self, session: *StoredSession, toplevel: *StoredToplevel) void {
    for (self.associations.items) |a| std.debug.assert(a.session != session or a.toplevel != toplevel);
    std.debug.assert(session.toplevels.remove(toplevel.name));
    toplevel.deinit(self.allocator);
}
fn clearStoredSessions(self: *Self) void {
    var it = self.sessions.iterator();
    while (it.next()) |entry| entry.value_ptr.*.deinit(self.allocator);
    self.sessions.clearRetainingCapacity();
}
fn generateSession(self: *Self) !*StoredSession {
    while (true) {
        var bytes: [16]u8 = undefined;
        try self.io.randomSecure(&bytes);
        const encoded = std.fmt.bytesToHex(bytes, .lower);
        if (!self.sessions.contains(&encoded)) return self.createStoredSession(&encoded);
    }
}
fn saveWarn(self: *Self) void {
    self.save() catch |err| log.warn("failed to save XDG sessions: {t}", .{err});
}

fn load(self: *Self) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(self.io, self.storage_path.?, self.allocator, .limited(maximum_state_file_size));
    defer self.allocator.free(source);
    var parsed = try std.json.parseFromSlice(Persisted, self.allocator, source, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.version != 1) return error.UnsupportedVersion;
    errdefer self.clearStoredSessions();
    for (parsed.value.sessions) |ps| {
        if (!std.unicode.utf8ValidateSlice(ps.id) or self.sessions.contains(ps.id)) return error.InvalidState;
        const session = try self.createStoredSession(ps.id);
        for (ps.toplevels) |pt| {
            if (!std.unicode.utf8ValidateSlice(pt.name) or session.toplevels.contains(pt.name)) return error.InvalidState;
            const t = try self.createStoredToplevel(session, pt.name);
            if (pt.state) |s| {
                if (!std.unicode.utf8ValidateSlice(s.output_name) or s.workspace == 0 or s.width == 0 or s.height == 0) return error.InvalidState;
                t.state = .{ .output_name = try self.allocator.dupe(u8, s.output_name), .workspace = s.workspace, .floating = s.floating, .position = s.position, .width = s.width, .height = s.height, .maximized = s.maximized, .fullscreen = s.fullscreen, .minimized = s.minimized };
            }
        }
    }
}
fn save(self: *Self) !void {
    const path = self.storage_path orelse return;
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    try json.objectField("version");
    try json.write(1);
    try json.objectField("sessions");
    try json.beginArray();
    var sessions = self.sessions.iterator();
    while (sessions.next()) |se| {
        const s = se.value_ptr.*;
        try json.beginObject();
        try json.objectField("id");
        try json.write(s.id);
        try json.objectField("toplevels");
        try json.beginArray();
        var tops = s.toplevels.iterator();
        while (tops.next()) |te| {
            const t = te.value_ptr.*;
            try json.beginObject();
            try json.objectField("name");
            try json.write(t.name);
            try json.objectField("state");
            if (t.state) |v| try json.write(PersistedState{ .output_name = v.output_name, .workspace = v.workspace, .floating = v.floating, .position = v.position, .width = v.width, .height = v.height, .maximized = v.maximized, .fullscreen = v.fullscreen, .minimized = v.minimized }) else try json.write(null);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(self.io);
    try atomic.file.writeStreamingAll(self.io, output.written());
    try atomic.replace(self.io);
}

fn windowStateForRemap(context: *anyopaque, window: XdgShell.WindowId) ?WindowManager.SessionState {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.associations.items) |a| if (std.meta.eql(a.window_id, window)) return if (a.toplevel.state) |*s| s.borrowed() else null;
    return null;
}
fn windowRestored(context: *anyopaque, window: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.associations.items) |a| if (std.meta.eql(a.window_id, window) and a.toplevel.state != null) {
        if (a.endpoint) |e| e.restored(e.context);
        return;
    };
}
fn windowChanged(context: *anyopaque, window: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.captureWindow(window);
}
fn windowCommitted(_: *anyopaque, _: XdgShell.WindowId) void {}
fn windowUnmapped(_: *anyopaque, _: XdgShell.WindowId) void {}
fn windowDestroyed(context: *anyopaque, window: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    var i = self.associations.items.len;
    while (i > 0) {
        i -= 1;
        if (!std.meta.eql(self.associations.items[i].window_id, window)) continue;
        _ = self.captureAssociation(self.associations.items[i]);
        self.removeAssociation(i);
    }
    self.saveWarn();
}
fn windowMetadataChanged(_: *anyopaque, _: XdgShell.WindowId) void {}
fn windowStateChanged(_: *anyopaque, _: XdgShell.WindowId) void {}

test "owned session state detects window management changes" {
    const initial: WindowManager.SessionState = .{ .output_name = "HEADLESS-1", .workspace = 4, .floating = true, .position = .{ .x = 20, .y = 30 }, .size = .{ .width = 800, .height = 600 }, .maximized = false, .fullscreen = false, .minimized = false };
    var state = try OwnedState.init(std.testing.allocator, initial);
    defer state.deinit(std.testing.allocator);
    try std.testing.expect(state.eql(initial));
    var changed = initial;
    changed.workspace = 5;
    try std.testing.expect(!state.eql(changed));
    try std.testing.expectEqualStrings("HEADLESS-1", state.borrowed().output_name);
}

test "cross-client acquisition replaces the active endpoint" {
    const Endpoint = struct {
        replaced_count: usize = 0,
        fn replaced(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.replaced_count += 1;
        }
    };
    var authority: Self = undefined;
    authority.allocator = std.testing.allocator;
    authority.sessions = .empty;
    authority.associations = .empty;
    authority.storage_path = null;
    defer {
        authority.clearStoredSessions();
        authority.sessions.deinit(std.testing.allocator);
        authority.associations.deinit(std.testing.allocator);
    }
    const stored = try authority.createStoredSession("session");
    var first: Endpoint = .{};
    var second: Endpoint = .{};
    const client_a: ClientRegistry.Id = .{ .index = 1, .generation = 1 };
    const client_b: ClientRegistry.Id = .{ .index = 2, .generation = 1 };
    stored.active = .{ .client = client_a, .endpoint = .{ .context = &first, .replaced = Endpoint.replaced } };
    const acquired = try authority.acquire("session", client_b, .{ .context = &second, .replaced = Endpoint.replaced });
    try std.testing.expect(acquired.restored);
    try std.testing.expectEqual(@as(usize, 1), first.replaced_count);
    try std.testing.expectEqual(@as(usize, 0), second.replaced_count);
    try std.testing.expectError(error.InUse, authority.acquire("session", client_b, .{ .context = &second, .replaced = Endpoint.replaced }));
    authority.release(acquired.session, &second, false);
}

fn exerciseStoredRecordRollback(allocator: std.mem.Allocator) !void {
    var authority: Self = undefined;
    authority.allocator = allocator;
    authority.sessions = .empty;
    authority.associations = .empty;
    defer {
        authority.clearStoredSessions();
        authority.sessions.deinit(allocator);
        authority.associations.deinit(allocator);
    }
    const session = try authority.createStoredSession("session");
    const toplevel = try authority.createStoredToplevel(session, "window");
    authority.removeStoredToplevel(session, toplevel);
    try std.testing.expectEqual(@as(usize, 0), session.toplevels.count());
    authority.removeStoredSession(session);
    try std.testing.expectEqual(@as(usize, 0), authority.sessions.count());
}

test "stored record rollback releases all ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseStoredRecordRollback, .{});
}
