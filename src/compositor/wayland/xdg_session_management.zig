//! Durable XDG toplevel session identity and window-management state.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const WindowManager = @import("../window_manager.zig");
const XdgShell = @import("../XdgShell.zig");
const MatureXdgShell = @import("xdg_shell.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;
const log = std.log.scoped(.xdg_session_management);
const maximum_state_file_size = 1024 * 1024;

allocator: std.mem.Allocator,
io: std.Io,
global: *wl.Global,
xdg_shell: *MatureXdgShell,
core: *XdgShell,
window_manager: *WindowManager,
sessions: std.StringHashMapUnmanaged(*StoredSession),
session_resources: std.ArrayList(*SessionResource),
toplevel_resources: std.ArrayList(*ToplevelResource),
associations: std.ArrayList(*Association),
storage_path: ?[]u8,

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
        return .{
            .output_name = try allocator.dupe(u8, state.output_name),
            .workspace = state.workspace,
            .floating = state.floating,
            .position = if (state.position) |position| .{ .x = position.x, .y = position.y } else null,
            .width = state.size.width,
            .height = state.size.height,
            .maximized = state.maximized,
            .fullscreen = state.fullscreen,
            .minimized = state.minimized,
        };
    }

    fn deinit(self: *OwnedState, allocator: std.mem.Allocator) void {
        allocator.free(self.output_name);
        self.* = undefined;
    }

    fn eql(self: OwnedState, state: WindowManager.SessionState) bool {
        const position_matches = if (self.position) |position|
            state.position != null and position.x == state.position.?.x and
                position.y == state.position.?.y
        else
            state.position == null;
        return std.mem.eql(u8, self.output_name, state.output_name) and
            self.workspace == state.workspace and self.floating == state.floating and
            position_matches and self.width == state.size.width and
            self.height == state.size.height and self.maximized == state.maximized and
            self.fullscreen == state.fullscreen and self.minimized == state.minimized;
    }

    fn borrowed(self: *const OwnedState) WindowManager.SessionState {
        return .{
            .output_name = self.output_name,
            .workspace = self.workspace,
            .floating = self.floating,
            .position = if (self.position) |position| .{ .x = position.x, .y = position.y } else null,
            .size = .{ .width = self.width, .height = self.height },
            .maximized = self.maximized,
            .fullscreen = self.fullscreen,
            .minimized = self.minimized,
        };
    }
};

const StoredToplevel = struct {
    name: []u8,
    state: ?OwnedState = null,

    fn deinit(self: *StoredToplevel, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.state) |*state| state.deinit(allocator);
        allocator.destroy(self);
    }

    fn update(
        self: *StoredToplevel,
        allocator: std.mem.Allocator,
        state: WindowManager.SessionState,
    ) !bool {
        if (self.state) |current| if (current.eql(state)) return false;
        var replacement = try OwnedState.init(allocator, state);
        errdefer replacement.deinit(allocator);
        if (self.state) |*current| current.deinit(allocator);
        self.state = replacement;
        return true;
    }
};

const StoredSession = struct {
    id: [:0]u8,
    toplevels: std.StringHashMapUnmanaged(*StoredToplevel) = .empty,
    active: ?*SessionResource = null,

    fn deinit(self: *StoredSession, allocator: std.mem.Allocator) void {
        var toplevels = self.toplevels.iterator();
        while (toplevels.next()) |entry| entry.value_ptr.*.deinit(allocator);
        self.toplevels.deinit(allocator);
        allocator.free(self.id);
        allocator.destroy(self);
    }
};

const Association = struct {
    session: *StoredSession,
    toplevel: *StoredToplevel,
    window_id: XdgShell.WindowId,
    client: *wl.Client,
    resource: ?*ToplevelResource,
};

const Persisted = struct {
    version: u32,
    sessions: []const PersistedSession,
};

const PersistedSession = struct {
    id: []const u8,
    toplevels: []const PersistedToplevel,
};

const PersistedToplevel = struct {
    name: []const u8,
    state: ?PersistedState = null,
};

const PersistedState = struct {
    output_name: []const u8,
    workspace: u8,
    floating: bool,
    position: ?OwnedState.Position = null,
    width: u32,
    height: u32,
    maximized: bool,
    fullscreen: bool,
    minimized: bool,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    xdg_shell: *MatureXdgShell,
    core: *XdgShell,
    window_manager: *WindowManager,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .global = undefined,
        .xdg_shell = xdg_shell,
        .core = core,
        .window_manager = window_manager,
        .sessions = .empty,
        .session_resources = .empty,
        .toplevel_resources = .empty,
        .associations = .empty,
        .storage_path = null,
    };
    errdefer self.sessions.deinit(allocator);
    errdefer self.session_resources.deinit(allocator);
    errdefer self.toplevel_resources.deinit(allocator);
    errdefer self.associations.deinit(allocator);
    self.global = try wl.Global.create(display, xdg.SessionManagerV1, 1, *Self, self, bind);
    errdefer self.global.destroy();
    try core.addWindowObserver(.{
        .context = self,
        .committed = windowCommitted,
        .unmapped = windowUnmapped,
        .destroyed = windowDestroyed,
        .metadata_changed = windowMetadataChanged,
        .state_changed = windowStateChanged,
    });
    errdefer core.removeWindowObserver(self);
    window_manager.setSessionListener(.{
        .context = self,
        .state_for_remap = windowStateForRemap,
        .restored = windowRestored,
        .changed = windowChanged,
    });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.session_resources.items.len == 0);
    std.debug.assert(self.toplevel_resources.items.len == 0);
    std.debug.assert(self.associations.items.len == 0);
    self.save() catch |err| log.warn("failed to save XDG sessions: {t}", .{err});
    self.window_manager.clearSessionListener();
    self.core.removeWindowObserver(self);
    self.global.destroy();
    self.clearStoredSessions();
    self.sessions.deinit(self.allocator);
    self.session_resources.deinit(self.allocator);
    self.toplevel_resources.deinit(self.allocator);
    self.associations.deinit(self.allocator);
    if (self.storage_path) |path| self.allocator.free(path);
    self.* = undefined;
}

pub fn configureStorage(
    self: *Self,
    runtime_directory: []const u8,
    instance_name: []const u8,
) !void {
    std.debug.assert(self.storage_path == null);
    std.debug.assert(self.sessions.count() == 0);
    if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
    if (!std.mem.eql(u8, std.fs.path.basename(instance_name), instance_name))
        return error.InvalidInstanceName;
    const file_name = try std.fmt.allocPrint(
        self.allocator,
        "xdg-sessions-{s}.json",
        .{instance_name},
    );
    defer self.allocator.free(file_name);
    self.storage_path = try std.fs.path.join(
        self.allocator,
        &.{ runtime_directory, "keywork", file_name },
    );
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

fn clearStoredSessions(self: *Self) void {
    var sessions = self.sessions.iterator();
    while (sessions.next()) |entry| entry.value_ptr.*.deinit(self.allocator);
    self.sessions.clearRetainingCapacity();
}

fn load(self: *Self) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        self.io,
        self.storage_path.?,
        self.allocator,
        .limited(maximum_state_file_size),
    );
    defer self.allocator.free(source);
    var parsed = try std.json.parseFromSlice(Persisted, self.allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value.version != 1) return error.UnsupportedVersion;
    errdefer self.clearStoredSessions();
    for (parsed.value.sessions) |persisted_session| {
        if (!std.unicode.utf8ValidateSlice(persisted_session.id) or
            self.sessions.contains(persisted_session.id)) return error.InvalidState;
        const session = try self.createStoredSession(persisted_session.id);
        for (persisted_session.toplevels) |persisted_toplevel| {
            if (!std.unicode.utf8ValidateSlice(persisted_toplevel.name) or
                session.toplevels.contains(persisted_toplevel.name)) return error.InvalidState;
            const toplevel = try self.createStoredToplevel(session, persisted_toplevel.name);
            if (persisted_toplevel.state) |state| {
                if (!std.unicode.utf8ValidateSlice(state.output_name) or state.workspace == 0 or
                    state.width == 0 or state.height == 0) return error.InvalidState;
                toplevel.state = .{
                    .output_name = try self.allocator.dupe(u8, state.output_name),
                    .workspace = state.workspace,
                    .floating = state.floating,
                    .position = state.position,
                    .width = state.width,
                    .height = state.height,
                    .maximized = state.maximized,
                    .fullscreen = state.fullscreen,
                    .minimized = state.minimized,
                };
            }
        }
    }
}

fn save(self: *Self) !void {
    const path = self.storage_path orelse return;
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{
        .writer = &output.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.beginObject();
    try json.objectField("version");
    try json.write(1);
    try json.objectField("sessions");
    try json.beginArray();
    var sessions = self.sessions.iterator();
    while (sessions.next()) |session_entry| {
        const session = session_entry.value_ptr.*;
        try json.beginObject();
        try json.objectField("id");
        try json.write(session.id);
        try json.objectField("toplevels");
        try json.beginArray();
        var toplevels = session.toplevels.iterator();
        while (toplevels.next()) |toplevel_entry| {
            const toplevel = toplevel_entry.value_ptr.*;
            try json.beginObject();
            try json.objectField("name");
            try json.write(toplevel.name);
            try json.objectField("state");
            if (toplevel.state) |state| {
                try json.write(PersistedState{
                    .output_name = state.output_name,
                    .workspace = state.workspace,
                    .floating = state.floating,
                    .position = state.position,
                    .width = state.width,
                    .height = state.height,
                    .maximized = state.maximized,
                    .fullscreen = state.fullscreen,
                    .minimized = state.minimized,
                });
            } else try json.write(null);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();

    var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(self.io);
    try atomic.file.writeStreamingAll(self.io, output.written());
    try atomic.replace(self.io);
}

fn createStoredSession(self: *Self, id: []const u8) !*StoredSession {
    const stored = try self.allocator.create(StoredSession);
    errdefer self.allocator.destroy(stored);
    const owned_id = try self.allocator.dupeSentinel(u8, id, 0);
    errdefer self.allocator.free(owned_id);
    stored.* = .{ .id = owned_id };
    errdefer stored.toplevels.deinit(self.allocator);
    try self.sessions.put(self.allocator, stored.id, stored);
    return stored;
}

fn createStoredToplevel(
    self: *Self,
    session: *StoredSession,
    name: []const u8,
) !*StoredToplevel {
    const stored = try self.allocator.create(StoredToplevel);
    errdefer self.allocator.destroy(stored);
    const owned_name = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(owned_name);
    stored.* = .{ .name = owned_name };
    try session.toplevels.put(self.allocator, stored.name, stored);
    return stored;
}

fn removeStoredSession(self: *Self, stored: *StoredSession) void {
    std.debug.assert(stored.active == null);
    std.debug.assert(self.sessions.remove(stored.id));
    stored.deinit(self.allocator);
}

fn removeStoredToplevel(
    self: *Self,
    session: *StoredSession,
    stored: *StoredToplevel,
) void {
    for (self.associations.items) |association| {
        std.debug.assert(association.session != session or association.toplevel != stored);
    }
    std.debug.assert(session.toplevels.remove(stored.name));
    stored.deinit(self.allocator);
}

fn generateSession(self: *Self) !*StoredSession {
    while (true) {
        var bytes: [16]u8 = undefined;
        try self.io.randomSecure(&bytes);
        const encoded = std.fmt.bytesToHex(bytes, .lower);
        if (!self.sessions.contains(&encoded)) return self.createStoredSession(&encoded);
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = xdg.SessionManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *xdg.SessionManagerV1,
    request: xdg.SessionManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_session => |get| self.getSession(resource, get.id, get.reason, get.session_id),
    }
}

fn getSession(
    self: *Self,
    manager_resource: *xdg.SessionManagerV1,
    id: u32,
    reason: xdg.SessionManagerV1.Reason,
    requested_id_z: ?[*:0]const u8,
) void {
    switch (reason) {
        .launch, .recover, .session_restore => {},
        _ => {
            manager_resource.postError(.invalid_reason, "invalid session reason");
            return;
        },
    }
    const requested_id = if (requested_id_z) |value| std.mem.span(value) else null;
    if (requested_id) |value| if (!std.unicode.utf8ValidateSlice(value)) {
        manager_resource.postError(.invalid_session_id, "session identifier is not valid UTF-8");
        return;
    };
    var created: ?*StoredSession = null;
    defer if (created) |stored| self.removeStoredSession(stored);
    const stored = if (requested_id) |value|
        self.sessions.get(value) orelse new_session: {
            const new = self.generateSession() catch {
                manager_resource.postNoMemory();
                return;
            };
            created = new;
            break :new_session new;
        }
    else new_session: {
        const new = self.generateSession() catch {
            manager_resource.postNoMemory();
            return;
        };
        created = new;
        break :new_session new;
    };
    if (stored.active) |active| {
        if (active.resource.getClient() == manager_resource.getClient()) {
            manager_resource.postError(.in_use, "session is already in use by this client");
            return;
        }
    }
    SessionResource.create(self, manager_resource, id, stored, created == null) catch |err| {
        switch (err) {
            error.OutOfMemory, error.ResourceCreateFailed => manager_resource.postNoMemory(),
        }
        return;
    };
    created = null;
}

const SessionResource = struct {
    manager: *Self,
    resource: *xdg.SessionV1,
    stored: ?*StoredSession,
    remove_on_destroy: bool = false,

    fn create(
        manager: *Self,
        manager_resource: *xdg.SessionManagerV1,
        id: u32,
        stored: *StoredSession,
        restored: bool,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try xdg.SessionV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(SessionResource);
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource, .stored = stored };
        try manager.session_resources.append(manager.allocator, self);
        if (stored.active) |active| active.replace();
        stored.active = self;
        resource.setHandler(*SessionResource, handleRequest, handleDestroy, self);
        if (restored) resource.sendRestored() else resource.sendCreated(stored.id.ptr);
        manager.save() catch |err| log.warn("failed to save XDG sessions: {t}", .{err});
    }

    fn handleRequest(
        resource: *xdg.SessionV1,
        request: xdg.SessionV1.Request,
        self: *SessionResource,
    ) void {
        const stored = self.stored orelse {
            switch (request) {
                .destroy, .remove => resource.destroy(),
                .add_toplevel => |add| self.manager.createInertToplevel(
                    resource.getClient(),
                    resource.getVersion(),
                    add.id,
                ),
                .restore_toplevel => |restore| self.manager.createInertToplevel(
                    resource.getClient(),
                    resource.getVersion(),
                    restore.id,
                ),
                .remove_toplevel => {},
            }
            return;
        };
        switch (request) {
            .destroy => resource.destroy(),
            .remove => {
                self.remove_on_destroy = true;
                resource.destroy();
            },
            .add_toplevel => |add| self.addToplevel(add.id, add.toplevel, add.name, false),
            .restore_toplevel => |restore| self.addToplevel(
                restore.id,
                restore.toplevel,
                restore.name,
                true,
            ),
            .remove_toplevel => |remove| self.manager.removeToplevel(
                self.resource,
                stored,
                std.mem.span(remove.name),
            ),
        }
    }

    fn addToplevel(
        self: *SessionResource,
        id: u32,
        toplevel_resource: *xdg.Toplevel,
        name_z: [*:0]const u8,
        restore: bool,
    ) void {
        const stored_session = self.stored orelse {
            self.manager.createInertToplevel(
                self.resource.getClient(),
                self.resource.getVersion(),
                id,
            );
            return;
        };
        const name = std.mem.span(name_z);
        if (!std.unicode.utf8ValidateSlice(name)) {
            self.resource.postError(.invalid_name, "toplevel name is not valid UTF-8");
            return;
        }
        if (toplevel_resource.getClient() != self.resource.getClient()) {
            self.resource.getClient().postImplementationError("xdg_toplevel belongs to another client");
            return;
        }
        const toplevel = self.manager.xdg_shell.toplevelFromResource(toplevel_resource) orelse {
            self.resource.getClient().postImplementationError("invalid xdg_toplevel resource");
            return;
        };
        if (restore) {
            const info = self.manager.core.windowInfo(toplevel.window_id) orelse {
                self.manager.createInertToplevel(
                    self.resource.getClient(),
                    self.resource.getVersion(),
                    id,
                );
                return;
            };
            if (info.ready or info.mapped) {
                self.resource.postError(.already_mapped, "xdg_toplevel was already mapped");
                return;
            }
        }
        for (self.manager.associations.items) |association| {
            if (association.client == self.resource.getClient() and
                std.meta.eql(association.window_id, toplevel.window_id))
            {
                self.resource.postError(.already_added, "xdg_toplevel is already in a session");
                return;
            }
        }
        var created: ?*StoredToplevel = null;
        defer if (created) |stored| self.manager.removeStoredToplevel(
            stored_session,
            stored,
        );
        var known = stored_session.toplevels.get(name);
        if (!restore and known != null) {
            self.resource.postError(.name_in_use, "toplevel name is already in use");
            return;
        }
        if (known) |stored_toplevel| {
            for (self.manager.associations.items) |association| {
                if (association.session == stored_session and association.toplevel == stored_toplevel) {
                    self.resource.postError(.name_in_use, "toplevel name is already in use");
                    return;
                }
            }
        } else {
            known = self.manager.createStoredToplevel(stored_session, name) catch {
                self.resource.postNoMemory();
                return;
            };
            created = known;
        }
        const stored_toplevel = known.?;
        if (restore) if (stored_toplevel.state) |*state| {
            self.manager.window_manager.prepareSessionRestore(
                toplevel.window_id,
                state.borrowed(),
            ) catch |err| switch (err) {
                error.AlreadyMapped => {
                    self.resource.postError(.already_mapped, "xdg_toplevel was already mapped");
                    return;
                },
                error.InvalidWindow => {
                    self.manager.createInertToplevel(
                        self.resource.getClient(),
                        self.resource.getVersion(),
                        id,
                    );
                    return;
                },
                error.OutOfMemory => {
                    self.resource.postNoMemory();
                    return;
                },
            };
        };
        self.manager.createAssociation(
            stored_session,
            stored_toplevel,
            toplevel.window_id,
            self.resource.getClient(),
            id,
        ) catch {
            self.manager.window_manager.cancelSessionRestore(toplevel.window_id);
            self.resource.postNoMemory();
            return;
        };
        created = null;
        self.manager.captureWindow(toplevel.window_id);
        self.manager.save() catch |err| log.warn("failed to save XDG sessions: {t}", .{err});
    }

    fn replace(self: *SessionResource) void {
        self.resource.sendReplaced();
        self.manager.endSession(self, false);
    }

    fn handleDestroy(_: *xdg.SessionV1, self: *SessionResource) void {
        self.manager.endSession(self, self.remove_on_destroy);
        for (self.manager.session_resources.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = self.manager.session_resources.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

const ToplevelResource = struct {
    manager: *Self,
    resource: *xdg.ToplevelSessionV1,
    association: ?*Association,

    fn handleRequest(
        resource: *xdg.ToplevelSessionV1,
        request: xdg.ToplevelSessionV1.Request,
        self: *ToplevelResource,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .rename => |request_rename| self.rename(std.mem.span(request_rename.name)),
        }
    }

    fn rename(self: *ToplevelResource, name: []const u8) void {
        const association = self.association orelse return;
        const session_resource = association.session.active orelse return;
        if (!std.unicode.utf8ValidateSlice(name)) {
            session_resource.resource.postError(.invalid_name, "toplevel name is not valid UTF-8");
            return;
        }
        if (std.mem.eql(u8, association.toplevel.name, name)) return;
        if (association.session.toplevels.contains(name)) {
            session_resource.resource.postError(.name_in_use, "toplevel name is already in use");
            return;
        }
        const replacement = self.manager.allocator.dupe(u8, name) catch {
            self.resource.postNoMemory();
            return;
        };
        association.session.toplevels.put(
            self.manager.allocator,
            replacement,
            association.toplevel,
        ) catch {
            self.manager.allocator.free(replacement);
            self.resource.postNoMemory();
            return;
        };
        const previous = association.toplevel.name;
        std.debug.assert(association.session.toplevels.remove(previous));
        association.toplevel.name = replacement;
        self.manager.allocator.free(previous);
        self.manager.save() catch |err| log.warn("failed to save XDG sessions: {t}", .{err});
    }

    fn handleDestroy(_: *xdg.ToplevelSessionV1, self: *ToplevelResource) void {
        if (self.association) |association| {
            if (association.resource == self) association.resource = null;
        }
        for (self.manager.toplevel_resources.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = self.manager.toplevel_resources.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

fn createInertToplevel(self: *Self, client: *wl.Client, version: u32, id: u32) void {
    const resource = xdg.ToplevelSessionV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    const adapter = self.allocator.create(ToplevelResource) catch {
        resource.destroy();
        client.postNoMemory();
        return;
    };
    adapter.* = .{ .manager = self, .resource = resource, .association = null };
    self.toplevel_resources.append(self.allocator, adapter) catch {
        self.allocator.destroy(adapter);
        resource.destroy();
        client.postNoMemory();
        return;
    };
    resource.setHandler(
        *ToplevelResource,
        ToplevelResource.handleRequest,
        ToplevelResource.handleDestroy,
        adapter,
    );
}

fn createAssociation(
    self: *Self,
    session: *StoredSession,
    toplevel: *StoredToplevel,
    window_id: XdgShell.WindowId,
    client: *wl.Client,
    resource_id: u32,
) !void {
    const resource = try xdg.ToplevelSessionV1.create(client, 1, resource_id);
    errdefer resource.destroy();
    const association = try self.allocator.create(Association);
    errdefer self.allocator.destroy(association);
    const adapter = try self.allocator.create(ToplevelResource);
    errdefer self.allocator.destroy(adapter);
    association.* = .{
        .session = session,
        .toplevel = toplevel,
        .window_id = window_id,
        .client = client,
        .resource = adapter,
    };
    adapter.* = .{ .manager = self, .resource = resource, .association = association };
    try self.associations.append(self.allocator, association);
    errdefer _ = self.associations.pop();
    try self.toplevel_resources.append(self.allocator, adapter);
    resource.setHandler(*ToplevelResource, ToplevelResource.handleRequest, ToplevelResource.handleDestroy, adapter);
}

fn endSession(self: *Self, resource: *SessionResource, remove: bool) void {
    const stored = resource.stored orelse return;
    var index = self.associations.items.len;
    while (index > 0) {
        index -= 1;
        const association = self.associations.items[index];
        if (association.session != stored) continue;
        _ = self.captureAssociation(association);
        self.removeAssociation(index);
    }
    if (stored.active == resource) stored.active = null;
    resource.stored = null;
    if (remove) self.removeStoredSession(stored);
    self.save() catch |err| log.warn("failed to save XDG sessions: {t}", .{err});
}

fn removeToplevel(
    self: *Self,
    resource: *xdg.SessionV1,
    session: *StoredSession,
    name: []const u8,
) void {
    if (!std.unicode.utf8ValidateSlice(name)) {
        resource.postError(.invalid_name, "toplevel name is not valid UTF-8");
        return;
    }
    const toplevel = session.toplevels.get(name) orelse return;
    var index = self.associations.items.len;
    while (index > 0) {
        index -= 1;
        const association = self.associations.items[index];
        if (association.session == session and association.toplevel == toplevel) {
            self.removeAssociation(index);
        }
    }
    self.removeStoredToplevel(session, toplevel);
    self.save() catch |err| log.warn("failed to save XDG sessions: {t}", .{err});
}

fn removeAssociation(self: *Self, index: usize) void {
    const association = self.associations.orderedRemove(index);
    self.window_manager.cancelSessionRestore(association.window_id);
    if (association.resource) |resource| resource.association = null;
    self.allocator.destroy(association);
}

fn captureAssociation(self: *Self, association: *Association) bool {
    const state = self.window_manager.sessionState(association.window_id) orelse return false;
    return association.toplevel.update(self.allocator, state) catch |err| {
        log.warn("failed to update XDG toplevel session state: {t}", .{err});
        return false;
    };
}

fn captureWindow(self: *Self, window_id: XdgShell.WindowId) void {
    var changed = false;
    for (self.associations.items) |association| {
        if (!std.meta.eql(association.window_id, window_id)) continue;
        changed = self.captureAssociation(association) or changed;
    }
    if (changed) self.save() catch |err| log.warn("failed to save XDG sessions: {t}", .{err});
}

fn windowStateForRemap(
    context: *anyopaque,
    window_id: XdgShell.WindowId,
) ?WindowManager.SessionState {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.associations.items) |association| {
        if (!std.meta.eql(association.window_id, window_id)) continue;
        return if (association.toplevel.state) |*state| state.borrowed() else null;
    }
    return null;
}

fn windowRestored(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.associations.items) |association| {
        if (!std.meta.eql(association.window_id, window_id) or association.toplevel.state == null)
            continue;
        if (association.resource) |resource| resource.resource.sendRestored();
        return;
    }
}

fn windowChanged(context: *anyopaque, window_id: XdgShell.WindowId) void {
    captureWindow(@ptrCast(@alignCast(context)), window_id);
}

fn windowCommitted(_: *anyopaque, _: XdgShell.WindowId) void {}

fn windowUnmapped(_: *anyopaque, _: XdgShell.WindowId) void {}

fn windowDestroyed(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    var index = self.associations.items.len;
    while (index > 0) {
        index -= 1;
        if (!std.meta.eql(self.associations.items[index].window_id, window_id)) continue;
        _ = self.captureAssociation(self.associations.items[index]);
        self.removeAssociation(index);
    }
    self.save() catch |err| log.warn("failed to save XDG sessions: {t}", .{err});
}

fn windowMetadataChanged(_: *anyopaque, _: XdgShell.WindowId) void {}

fn windowStateChanged(_: *anyopaque, _: XdgShell.WindowId) void {}

test "owned session state detects window management changes" {
    const initial: WindowManager.SessionState = .{
        .output_name = "HEADLESS-1",
        .workspace = 4,
        .floating = true,
        .position = .{ .x = 20, .y = 30 },
        .size = .{ .width = 800, .height = 600 },
        .maximized = false,
        .fullscreen = false,
        .minimized = false,
    };
    var state = try OwnedState.init(std.testing.allocator, initial);
    defer state.deinit(std.testing.allocator);
    try std.testing.expect(state.eql(initial));
    var changed = initial;
    changed.workspace = 5;
    try std.testing.expect(!state.eql(changed));
    try std.testing.expectEqualStrings("HEADLESS-1", state.borrowed().output_name);
}

fn exerciseStoredRecordRollback(allocator: std.mem.Allocator) !void {
    var manager: Self = undefined;
    manager.allocator = allocator;
    manager.sessions = .empty;
    manager.associations = .empty;
    defer {
        manager.clearStoredSessions();
        manager.sessions.deinit(allocator);
        manager.associations.deinit(allocator);
    }

    const session = try manager.createStoredSession("session");
    const toplevel = try manager.createStoredToplevel(session, "window");
    manager.removeStoredToplevel(session, toplevel);
    try std.testing.expectEqual(@as(usize, 0), session.toplevels.count());
    manager.removeStoredSession(session);
    try std.testing.expectEqual(@as(usize, 0), manager.sessions.count());
}

test "stored record rollback releases all ownership" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseStoredRecordRollback,
        .{},
    );
}
