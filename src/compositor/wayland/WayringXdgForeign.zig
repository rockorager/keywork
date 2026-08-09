//! Scanner-backed xdg-foreign unstable-v2 resources.

const Self = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const XdgShell = @import("../XdgShell.zig");
const WayringXdgShell = @import("WayringXdgShell.zig");

const server = wayring.server;
const handle_length = 32;

const Manager = struct { owner: *Self, client: *server.Client, resource: protocol.zxdg_exporter_v2.Resource };
const ImportManager = struct { owner: *Self, client: *server.Client, resource: protocol.zxdg_importer_v2.Resource };
const Exported = struct { owner: *Self, client: *server.Client, resource: protocol.zxdg_exported_v2.Resource, identity: ?WayringXdgShell.ToplevelIdentity, handle: [handle_length]u8 };
const Imported = struct { owner: *Self, client: *server.Client, resource: protocol.zxdg_imported_v2.Resource, exported: ?*Exported };

allocator: std.mem.Allocator,
io: std.Io,
protocol_server: *server.Server,
xdg: *WayringXdgShell,
core: *XdgShell,
exporter_global: ?*const server.Server.Global = null,
importer_global: ?*const server.Server.Global = null,
exporters: std.ArrayList(*Manager) = .empty,
importers: std.ArrayList(*ImportManager) = .empty,
exports: std.ArrayList(*Exported) = .empty,
imports: std.ArrayList(*Imported) = .empty,

pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, protocol_server: *server.Server, xdg: *WayringXdgShell, core: *XdgShell) void {
    self.* = .{ .allocator = allocator, .io = io, .protocol_server = protocol_server, .xdg = xdg, .core = core };
    xdg.setForeignEndpoint(.{ .context = self, .destroyed = toplevelDestroyed });
}

pub fn publish(self: *Self) !void {
    self.exporter_global = try self.protocol_server.addGlobal(protocol.zxdg_exporter_v2, 1, Self, self, bindExporter);
    errdefer self.unpublish();
    self.importer_global = try self.protocol_server.addGlobal(protocol.zxdg_importer_v2, 1, Self, self, bindImporter);
}

pub fn unpublish(self: *Self) void {
    if (self.importer_global) |global| self.protocol_server.removeGlobal(global) catch {};
    if (self.exporter_global) |global| self.protocol_server.removeGlobal(global) catch {};
    self.importer_global = null;
    self.exporter_global = null;
}

pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    destroyClient(Imported, &self.imports, client, destroyImported);
    destroyClient(Exported, &self.exports, client, destroyExported);
    destroyClient(ImportManager, &self.importers, client, destroyImportManager);
    destroyClient(Manager, &self.exporters, client, destroyManager);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.exporters.items.len == 0 and self.importers.items.len == 0 and self.exports.items.len == 0 and self.imports.items.len == 0);
    self.xdg.clearForeignEndpoint();
    self.imports.deinit(self.allocator);
    self.exports.deinit(self.allocator);
    self.importers.deinit(self.allocator);
    self.exporters.deinit(self.allocator);
    self.* = undefined;
}

fn bindExporter(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    try self.createManager(client, id, version);
}
fn bindImporter(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    try self.createImportManager(client, id, version);
}

fn createManager(self: *Self, client: *server.Client, id: u32, version: u32) !void {
    try self.exporters.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, handleExporter, null);
    try client.materialize(&value.resource.runtime);
    self.exporters.appendAssumeCapacity(value);
}
fn createImportManager(self: *Self, client: *server.Client, id: u32, version: u32) !void {
    try self.importers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(ImportManager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(ImportManager, value, handleImporter, null);
    try client.materialize(&value.resource.runtime);
    self.importers.appendAssumeCapacity(value);
}
fn handleExporter(_: *protocol.zxdg_exporter_v2.Resource, request: protocol.zxdg_exporter_v2.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .export_toplevel => |args| try value.owner.createExport(value, args.id, args.surface),
    }
}
fn handleImporter(_: *protocol.zxdg_importer_v2.Resource, request: protocol.zxdg_importer_v2.Request, value: *ImportManager) !void {
    switch (request) {
        .destroy => value.owner.destroyImportManager(value),
        .import_toplevel => |args| try value.owner.createImport(value, args.id, args.handle),
    }
}

fn createExport(self: *Self, manager: *Manager, id: u32, surface: u32) !void {
    const identity = self.xdg.toplevelIdentityForSurface(manager.client, surface) orelse {
        manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.zxdg_exporter_v2.@"error".invalid_surface), "surface is not an exact live generated xdg_toplevel");
        return;
    };
    try self.exports.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Exported);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()), .identity = identity, .handle = self.generateHandle() };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Exported, value, handleExported, null);
    try manager.client.materialize(&value.resource.runtime);
    try protocol.zxdg_exported_v2.@"send:handle"(&value.resource, &value.handle);
    self.exports.appendAssumeCapacity(value);
}
fn createImport(self: *Self, manager: *ImportManager, id: u32, handle: []const u8) !void {
    try self.imports.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Imported);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()), .exported = self.findExport(handle) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Imported, value, handleImported, null);
    try manager.client.materialize(&value.resource.runtime);
    if (value.exported == null) try protocol.zxdg_imported_v2.@"send:destroyed"(&value.resource);
    self.imports.appendAssumeCapacity(value);
}
fn handleExported(_: *protocol.zxdg_exported_v2.Resource, request: protocol.zxdg_exported_v2.Request, value: *Exported) !void {
    switch (request) {
        .destroy => value.owner.destroyExported(value),
    }
}
fn handleImported(_: *protocol.zxdg_imported_v2.Resource, request: protocol.zxdg_imported_v2.Request, value: *Imported) !void {
    switch (request) {
        .destroy => value.owner.destroyImported(value),
        .set_parent_of => |args| setParent(value, args.surface),
    }
}
fn setParent(value: *Imported, surface: u32) void {
    const child = value.owner.xdg.toplevelIdentityForSurface(value.client, surface) orelse {
        value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.zxdg_imported_v2.@"error".invalid_surface), "surface is not an exact live generated xdg_toplevel");
        return;
    };
    const exported = value.exported orelse return;
    const parent = exported.identity orelse return;
    value.owner.xdg.setForeignParent(child, parent.core_id, value) catch {
        value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.zxdg_imported_v2.@"error".invalid_surface), "surface is not an exact live generated xdg_toplevel");
    };
}
fn invalidate(value: *Imported) void {
    if (value.exported == null) return;
    value.exported = null;
    value.owner.core.clearForeignParents(value);
    protocol.zxdg_imported_v2.@"send:destroyed"(&value.resource) catch |err| eventFailure(value, err);
}
fn toplevelDestroyed(context: *anyopaque, identity: WayringXdgShell.ToplevelIdentity) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.exports.items) |value| if (value.identity) |current| if (sameIdentity(current, identity)) {
        value.identity = null;
        for (self.imports.items) |imported| if (imported.exported == value) invalidate(imported);
    };
}
fn findExport(self: *Self, handle: []const u8) ?*Exported {
    if (handle.len != handle_length) return null;
    for (self.exports.items) |value| if (value.identity != null and std.mem.eql(u8, &value.handle, handle)) return value;
    return null;
}
fn generateHandle(self: *Self) [handle_length]u8 {
    while (true) {
        var bytes: [16]u8 = undefined;
        self.io.random(&bytes);
        const result = std.fmt.bytesToHex(bytes, .lower);
        if (!self.handleInUse(&result)) return result;
    }
}
fn handleInUse(self: *Self, handle: []const u8) bool {
    for (self.exports.items) |value| if (std.mem.eql(u8, &value.handle, handle)) return true;
    return false;
}
fn destroyExported(self: *Self, value: *Exported) void {
    for (self.imports.items) |imported| if (imported.exported == value) invalidate(imported);
    remove(Exported, &self.exports, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyImported(self: *Self, value: *Imported) void {
    self.core.clearForeignParents(value);
    remove(Imported, &self.imports, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *Self, value: *Manager) void {
    remove(Manager, &self.exporters, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyImportManager(self: *Self, value: *ImportManager) void {
    remove(ImportManager, &self.importers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn sameIdentity(a: WayringXdgShell.ToplevelIdentity, b: WayringXdgShell.ToplevelIdentity) bool {
    return a.client == b.client and a.object_id == b.object_id and a.generation == b.generation and std.meta.eql(a.core_id, b.core_id);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, index| if (item == value) {
        _ = list.swapRemove(index);
        return;
    };
    unreachable;
}
fn destroyClient(comptime T: type, list: *std.ArrayList(*T), client: *server.Client, comptime destroy: fn (*Self, *T) void) void {
    var index = list.items.len;
    while (index > 0) {
        index -= 1;
        const value = list.items[index];
        if (value.client == client) destroy(value.owner, value);
    }
}

fn eventFailure(value: *Imported, err: anyerror) void {
    if (value.client.fatal() != null) return;
    switch (err) {
        error.OutOfMemory, error.WriteFailed => value.client.postOutOfMemory(&value.resource.runtime, "queueing xdg-foreign destroyed event"),
        error.OutputSealed, error.ClientFatal => {},
        else => value.client.postImplementationError(&value.resource.runtime, "queueing xdg-foreign destroyed event"),
    }
}

test "foreign scanner descriptors pin unstable v2" {
    try std.testing.expectEqual(@as(u32, 1), protocol.zxdg_exporter_v2.interface.version);
    try std.testing.expectEqual(@as(u32, 1), protocol.zxdg_importer_v2.interface.version);
}
