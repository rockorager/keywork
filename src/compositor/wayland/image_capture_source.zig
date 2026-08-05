//! Privileged opaque sources shared by image capture protocols.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const ForeignToplevelList = @import("foreign_toplevel_list.zig");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");
const XdgShell = @import("../XdgShell.zig");

const wl = wayland.server.wl;
const ext = wayland.server.ext;

allocator: std.mem.Allocator,
output_global: *wl.Global,
toplevel_global: *wl.Global,
security_context: *SecurityContext,
outputs: *OutputLayout,
foreign_toplevels: *ForeignToplevelList,
xdg_shell: *XdgShell,
sources: std.ArrayList(*Source),
listener: ?InvalidationListener,

pub const Target = union(enum) {
    output: OutputLayout.Id,
    toplevel: XdgShell.WindowId,
};

pub const InvalidationListener = struct {
    context: *anyopaque,
    invalidated: *const fn (*anyopaque, Target) void,
};

const Source = struct {
    owner: *Self,
    resource: *ext.ImageCaptureSourceV1,
    target: ?Target,

    fn create(owner: *Self, client: *wl.Client, id: u32, target: ?Target) !void {
        const resource = try ext.ImageCaptureSourceV1.create(client, 1, id);
        errdefer resource.destroy();
        const self = try owner.allocator.create(Source);
        errdefer owner.allocator.destroy(self);
        self.* = .{ .owner = owner, .resource = resource, .target = target };
        try owner.sources.append(owner.allocator, self);
        resource.setHandler(*Source, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *ext.ImageCaptureSourceV1,
        request: ext.ImageCaptureSourceV1.Request,
        _: *Source,
    ) void {
        if (request == .destroy) resource.destroy();
    }

    fn handleDestroy(_: *ext.ImageCaptureSourceV1, self: *Source) void {
        for (self.owner.sources.items, 0..) |source, index| {
            if (source != self) continue;
            _ = self.owner.sources.swapRemove(index);
            break;
        }
        self.owner.allocator.destroy(self);
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    outputs: *OutputLayout,
    foreign_toplevels: *ForeignToplevelList,
    xdg_shell: *XdgShell,
) !void {
    self.* = .{
        .allocator = allocator,
        .output_global = undefined,
        .toplevel_global = undefined,
        .security_context = security_context,
        .outputs = outputs,
        .foreign_toplevels = foreign_toplevels,
        .xdg_shell = xdg_shell,
        .sources = .empty,
        .listener = null,
    };
    errdefer self.sources.deinit(allocator);
    self.output_global = try wl.Global.create(
        display,
        ext.OutputImageCaptureSourceManagerV1,
        1,
        *Self,
        self,
        bindOutputManager,
    );
    errdefer self.output_global.destroy();
    try security_context.restrictGlobal(self.output_global);
    errdefer security_context.unrestrictGlobal(self.output_global);
    self.toplevel_global = try wl.Global.create(
        display,
        ext.ForeignToplevelImageCaptureSourceManagerV1,
        1,
        *Self,
        self,
        bindToplevelManager,
    );
    errdefer self.toplevel_global.destroy();
    try security_context.restrictGlobal(self.toplevel_global);
    errdefer security_context.unrestrictGlobal(self.toplevel_global);
    try xdg_shell.addWindowObserver(.{
        .context = self,
        .committed = windowCommitted,
        .unmapped = windowUnmapped,
        .destroyed = windowDestroyed,
        .metadata_changed = windowMetadataChanged,
        .state_changed = windowStateChanged,
    });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.listener == null);
    self.xdg_shell.removeWindowObserver(self);
    self.security_context.unrestrictGlobal(self.toplevel_global);
    self.toplevel_global.destroy();
    self.security_context.unrestrictGlobal(self.output_global);
    self.output_global.destroy();
    std.debug.assert(self.sources.items.len == 0);
    self.sources.deinit(self.allocator);
    self.* = undefined;
}

/// Copies the listener and retains its context until clearInvalidationListener.
pub fn setInvalidationListener(self: *Self, listener: InvalidationListener) void {
    std.debug.assert(self.listener == null);
    self.listener = listener;
}

pub fn clearInvalidationListener(self: *Self) void {
    std.debug.assert(self.listener != null);
    self.listener = null;
}

pub fn targetForResource(
    self: *Self,
    resource: *ext.ImageCaptureSourceV1,
) ?Target {
    for (self.sources.items) |source| {
        if (source.resource == resource) return source.target;
    }
    return null;
}

pub fn removeOutput(self: *Self, output_id: OutputLayout.Id) void {
    self.invalidate(.{ .output = output_id });
}

fn bindOutputManager(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = ext.OutputImageCaptureSourceManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleOutputManagerRequest, null, self);
}

fn handleOutputManagerRequest(
    resource: *ext.OutputImageCaptureSourceManagerV1,
    request: ext.OutputImageCaptureSourceManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .create_source => |create| {
            const entry = self.outputs.findResource(create.output);
            const target: ?Target = if (entry) |output| .{ .output = output.id } else null;
            Source.create(self, resource.getClient(), create.source, target) catch
                resource.postNoMemory();
        },
    }
}

fn bindToplevelManager(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = ext.ForeignToplevelImageCaptureSourceManagerV1.create(
        client,
        version,
        id,
    ) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleToplevelManagerRequest, null, self);
}

fn handleToplevelManagerRequest(
    resource: *ext.ForeignToplevelImageCaptureSourceManagerV1,
    request: ext.ForeignToplevelImageCaptureSourceManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .create_source => |create| {
            const window_id = self.foreign_toplevels.windowForExtHandle(create.toplevel_handle);
            const target: ?Target = if (window_id) |window| .{ .toplevel = window } else null;
            Source.create(self, resource.getClient(), create.source, target) catch
                resource.postNoMemory();
        },
    }
}

fn invalidate(self: *Self, target: Target) void {
    for (self.sources.items) |source| {
        const current = source.target orelse continue;
        if (!std.meta.eql(current, target)) continue;
        source.target = null;
    }
    if (self.listener) |listener| listener.invalidated(listener.context, target);
}

fn windowCommitted(_: *anyopaque, _: XdgShell.WindowId) void {}

fn windowUnmapped(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.invalidate(.{ .toplevel = window_id });
}

fn windowDestroyed(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.invalidate(.{ .toplevel = window_id });
}

fn windowMetadataChanged(_: *anyopaque, _: XdgShell.WindowId) void {}

fn windowStateChanged(_: *anyopaque, _: XdgShell.WindowId) void {}
