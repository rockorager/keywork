//! Cross-client xdg-toplevel handles and transient parent relationships.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Surface = @import("surface.zig");
const XdgShell = @import("xdg_shell.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;
const zxdg = wayland.server.zxdg;

const handle_length = 32;

allocator: std.mem.Allocator,
io: std.Io,
exporter_global: *wl.Global,
importer_global: *wl.Global,
xdg_shell: *XdgShell,
exports: std.ArrayList(*Exported),
imports: std.ArrayList(*Imported),

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    xdg_shell: *XdgShell,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .exporter_global = try wl.Global.create(
            display,
            zxdg.ExporterV2,
            1,
            *Self,
            self,
            bindExporter,
        ),
        .importer_global = undefined,
        .xdg_shell = xdg_shell,
        .exports = .empty,
        .imports = .empty,
    };
    errdefer self.exporter_global.destroy();
    errdefer self.exports.deinit(allocator);
    errdefer self.imports.deinit(allocator);
    self.importer_global = try wl.Global.create(
        display,
        zxdg.ImporterV2,
        1,
        *Self,
        self,
        bindImporter,
    );
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.exports.items.len == 0);
    std.debug.assert(self.imports.items.len == 0);
    self.importer_global.destroy();
    self.exporter_global.destroy();
    self.imports.deinit(self.allocator);
    self.exports.deinit(self.allocator);
    self.* = undefined;
}

fn bindExporter(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zxdg.ExporterV2.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleExporterRequest, null, self);
}

fn handleExporterRequest(
    resource: *zxdg.ExporterV2,
    request: zxdg.ExporterV2.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .export_toplevel => |export_request| {
            const surface_id = Surface.fromResource(export_request.surface).handle();
            const toplevel = self.xdg_shell.toplevelForSurface(surface_id) orelse {
                resource.postError(.invalid_surface, "surface is not an xdg_toplevel");
                return;
            };
            Exported.create(self, resource, export_request.id, toplevel) catch
                resource.postNoMemory();
        },
    }
}

fn bindImporter(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zxdg.ImporterV2.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleImporterRequest, null, self);
}

fn handleImporterRequest(
    resource: *zxdg.ImporterV2,
    request: zxdg.ImporterV2.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .import_toplevel => |import_request| Imported.create(
            self,
            resource,
            import_request.id,
            self.exportForHandle(std.mem.span(import_request.handle)),
        ) catch resource.postNoMemory(),
    }
}

fn exportForHandle(self: *Self, handle: []const u8) ?*Exported {
    if (handle.len != handle_length) return null;
    for (self.exports.items) |exported| {
        if (exported.target_resource != null and
            std.mem.eql(u8, exported.handle[0..handle_length], handle)) return exported;
    }
    return null;
}

fn invalidateImports(self: *Self, exported: *Exported) void {
    for (self.imports.items) |imported| {
        if (imported.exported == exported) imported.invalidate();
    }
}

fn generateHandle(self: *Self) [handle_length + 1]u8 {
    while (true) {
        var random_bytes: [handle_length / 2]u8 = undefined;
        self.io.random(&random_bytes);
        const encoded = std.fmt.bytesToHex(random_bytes, .lower);
        var unique = true;
        for (self.exports.items) |exported| {
            if (std.mem.eql(u8, exported.handle[0..handle_length], &encoded)) {
                unique = false;
                break;
            }
        }
        if (!unique) continue;
        var handle: [handle_length + 1]u8 = undefined;
        @memcpy(handle[0..handle_length], &encoded);
        handle[handle_length] = 0;
        return handle;
    }
}

const Exported = struct {
    manager: *Self,
    resource: *zxdg.ExportedV2,
    handle: [handle_length + 1]u8,
    target_window: ?XdgShell.WindowId,
    surface_resource: ?*wl.Surface,
    xdg_surface_resource: ?*xdg.Surface,
    target_resource: ?*xdg.Toplevel,
    surface_destroy_listener: wl.Listener(*wl.Resource),
    xdg_surface_destroy_listener: wl.Listener(*wl.Resource),
    target_destroy_listener: wl.Listener(*wl.Resource),

    fn create(
        manager: *Self,
        manager_resource: *zxdg.ExporterV2,
        id: u32,
        toplevel: XdgShell.ToplevelInfo,
    ) !void {
        const resource = try zxdg.ExportedV2.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Exported);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .handle = manager.generateHandle(),
            .target_window = toplevel.window_id,
            .surface_resource = toplevel.surface_resource,
            .xdg_surface_resource = toplevel.xdg_surface_resource,
            .target_resource = toplevel.resource,
            .surface_destroy_listener = wl.Listener(*wl.Resource).init(handleSurfaceDestroyed),
            .xdg_surface_destroy_listener = wl.Listener(*wl.Resource).init(handleXdgSurfaceDestroyed),
            .target_destroy_listener = wl.Listener(*wl.Resource).init(handleToplevelDestroyed),
        };
        @as(*wl.Resource, @ptrCast(toplevel.surface_resource)).addDestroyListener(
            &self.surface_destroy_listener,
        );
        errdefer self.surface_destroy_listener.link.remove();
        @as(*wl.Resource, @ptrCast(toplevel.xdg_surface_resource)).addDestroyListener(
            &self.xdg_surface_destroy_listener,
        );
        errdefer self.xdg_surface_destroy_listener.link.remove();
        @as(*wl.Resource, @ptrCast(toplevel.resource)).addDestroyListener(
            &self.target_destroy_listener,
        );
        errdefer self.target_destroy_listener.link.remove();
        try manager.exports.append(manager.allocator, self);
        resource.setHandler(*Exported, handleRequest, handleDestroy, self);
        resource.sendHandle(@ptrCast(&self.handle));
    }

    fn handleRequest(
        resource: *zxdg.ExportedV2,
        request: zxdg.ExportedV2.Request,
        _: *Exported,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zxdg.ExportedV2, self: *Exported) void {
        self.detachTarget();
        self.manager.invalidateImports(self);
        for (self.manager.exports.items, 0..) |exported, index| {
            if (exported != self) continue;
            _ = self.manager.exports.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }

    fn handleSurfaceDestroyed(listener: *wl.Listener(*wl.Resource), _: *wl.Resource) void {
        const self: *Exported = @fieldParentPtr("surface_destroy_listener", listener);
        self.handleTargetDestroyed();
    }

    fn handleXdgSurfaceDestroyed(listener: *wl.Listener(*wl.Resource), _: *wl.Resource) void {
        const self: *Exported = @fieldParentPtr("xdg_surface_destroy_listener", listener);
        self.handleTargetDestroyed();
    }

    fn handleToplevelDestroyed(listener: *wl.Listener(*wl.Resource), _: *wl.Resource) void {
        const self: *Exported = @fieldParentPtr("target_destroy_listener", listener);
        self.handleTargetDestroyed();
    }

    fn handleTargetDestroyed(self: *Exported) void {
        self.detachTarget();
        self.manager.invalidateImports(self);
    }

    fn detachTarget(self: *Exported) void {
        if (self.surface_resource != null) self.surface_destroy_listener.link.remove();
        if (self.xdg_surface_resource != null) self.xdg_surface_destroy_listener.link.remove();
        if (self.target_resource != null) self.target_destroy_listener.link.remove();
        self.target_window = null;
        self.surface_resource = null;
        self.xdg_surface_resource = null;
        self.target_resource = null;
    }
};

const Imported = struct {
    manager: *Self,
    resource: *zxdg.ImportedV2,
    exported: ?*Exported,

    fn create(
        manager: *Self,
        manager_resource: *zxdg.ImporterV2,
        id: u32,
        exported: ?*Exported,
    ) !void {
        const resource = try zxdg.ImportedV2.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Imported);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .exported = exported,
        };
        try manager.imports.append(manager.allocator, self);
        resource.setHandler(*Imported, handleRequest, handleDestroy, self);
        if (exported == null) resource.sendDestroyed();
    }

    fn handleRequest(
        resource: *zxdg.ImportedV2,
        request: zxdg.ImportedV2.Request,
        self: *Imported,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_parent_of => |set| self.setParent(resource, set.surface),
        }
    }

    fn setParent(self: *Imported, resource: *zxdg.ImportedV2, surface: *wl.Surface) void {
        const child_surface_id = Surface.fromResource(surface).handle();
        const child = self.manager.xdg_shell.toplevelForSurface(child_surface_id) orelse {
            resource.postError(.invalid_surface, "surface is not an xdg_toplevel");
            return;
        };
        const exported = self.exported orelse return;
        const parent_id = exported.target_window orelse {
            self.invalidate();
            return;
        };
        self.manager.xdg_shell.setForeignParent(
            child_surface_id,
            parent_id,
            self,
        ) catch |err| switch (err) {
            error.InvalidSurface => resource.postError(
                .invalid_surface,
                "surface is not an xdg_toplevel",
            ),
            error.InvalidParent => child.resource.postError(
                .invalid_parent,
                "xdg-foreign parent cycle",
            ),
        };
    }

    fn invalidate(self: *Imported) void {
        if (self.exported == null) return;
        self.exported = null;
        self.manager.xdg_shell.clearForeignParents(self);
        self.resource.sendDestroyed();
    }

    fn handleDestroy(_: *zxdg.ImportedV2, self: *Imported) void {
        self.manager.xdg_shell.clearForeignParents(self);
        for (self.manager.imports.items, 0..) |imported, index| {
            if (imported != self) continue;
            _ = self.manager.imports.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};
