//! Dialog and modal hints for generated XDG toplevels.

const WayringXdgDialog = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const XdgShell = @import("../XdgShell.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringXdgShell = @import("WayringXdgShell.zig");

const server = wayring.server;

const Manager = struct {
    owner: *WayringXdgDialog,
    client: *server.Client,
    resource: protocol.xdg_wm_dialog_v1.Resource,
};

const Dialog = struct {
    owner: *WayringXdgDialog,
    client: *server.Client,
    resource: protocol.xdg_dialog_v1.Resource,
    identity: WayringXdgShell.ToplevelIdentity,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
xdg_shell: *WayringXdgShell,
core_shell: *XdgShell,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
dialogs: std.ArrayList(*Dialog) = .empty,

pub fn init(
    self: *WayringXdgDialog,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    xdg_shell: *WayringXdgShell,
    core_shell: *XdgShell,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .xdg_shell = xdg_shell,
        .core_shell = core_shell,
    };
}

pub fn publish(self: *WayringXdgDialog) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(
        protocol.xdg_wm_dialog_v1,
        1,
        WayringXdgDialog,
        self,
        bind,
    );
}

pub fn unpublish(self: *WayringXdgDialog) void {
    const global = self.global orelse return;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringXdgDialog, client: *server.Client) void {
    var index = self.dialogs.items.len;
    while (index > 0) {
        index -= 1;
        if (self.dialogs.items[index].client == client) self.destroyDialog(self.dialogs.items[index]);
    }
    index = self.managers.items.len;
    while (index > 0) {
        index -= 1;
        if (self.managers.items[index].client == client) self.destroyManager(self.managers.items[index]);
    }
}

pub fn deinit(self: *WayringXdgDialog) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.dialogs.items.len == 0);
    self.dialogs.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringXdgDialog) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(Manager, manager, handleManagerRequest, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
}

fn handleManagerRequest(
    _: *protocol.xdg_wm_dialog_v1.Resource,
    request: protocol.xdg_wm_dialog_v1.Request,
    manager: *Manager,
) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_xdg_dialog => |args| try manager.owner.createDialog(manager, args.id, args.toplevel),
    }
}

fn createDialog(self: *WayringXdgDialog, manager: *Manager, id: u32, toplevel_id: u32) !void {
    try self.dialogs.ensureUnusedCapacity(self.allocator, 1);
    const dialog = try self.allocator.create(Dialog);
    errdefer self.allocator.destroy(dialog);
    dialog.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
        .identity = undefined,
    };
    errdefer {
        dialog.resource.destroy();
        dialog.resource.deinit();
    }
    try dialog.resource.setHandler(Dialog, dialog, handleDialogRequest, null);
    try manager.client.materialize(&dialog.resource.runtime);

    const identity = self.xdg_shell.toplevelIdentity(manager.client, toplevel_id) orelse {
        manager.client.postImplementationError(&manager.resource.runtime, "xdg_toplevel is not an exact live same-client generated object");
        dialog.resource.destroy();
        dialog.resource.deinit();
        self.allocator.destroy(dialog);
        return;
    };
    dialog.identity = identity;
    for (self.dialogs.items) |existing| {
        if (!sameIdentity(existing.identity, identity)) continue;
        manager.client.postProtocolError(
            &manager.resource.runtime,
            @intCast(protocol.xdg_wm_dialog_v1.@"error".already_used),
            "xdg_toplevel already has an xdg_dialog_v1 object",
        );
        dialog.resource.destroy();
        dialog.resource.deinit();
        self.allocator.destroy(dialog);
        return;
    }
    self.dialogs.appendAssumeCapacity(dialog);
    self.xdg_shell.setXdgDialogState(identity, true, false);
}

fn handleDialogRequest(
    _: *protocol.xdg_dialog_v1.Resource,
    request: protocol.xdg_dialog_v1.Request,
    dialog: *Dialog,
) !void {
    switch (request) {
        .destroy => dialog.owner.destroyDialog(dialog),
        .set_modal => setModal(dialog, true),
        .unset_modal => setModal(dialog, false),
    }
}

fn setModal(dialog: *Dialog, modal: bool) void {
    if (!dialog.owner.xdg_shell.identityIsCurrent(dialog.identity)) return;
    dialog.owner.xdg_shell.setXdgDialogState(dialog.identity, true, modal);
}

fn destroyDialog(self: *WayringXdgDialog, dialog: *Dialog) void {
    remove(Dialog, &self.dialogs, dialog);
    if (self.xdg_shell.identityIsCurrent(dialog.identity)) {
        self.xdg_shell.setXdgDialogState(dialog.identity, false, false);
    }
    dialog.resource.destroy();
    dialog.resource.deinit();
    self.allocator.destroy(dialog);
}

fn destroyManager(self: *WayringXdgDialog, manager: *Manager) void {
    remove(Manager, &self.managers, manager);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
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

const TestGtkModal = struct {
    modal: bool = false,

    fn eventCount(_: *anyopaque, _: *server.Client, _: WayringCompositor.SurfaceId) usize {
        return 0;
    }

    fn fillEvents(
        _: *anyopaque,
        _: *server.Client,
        _: WayringCompositor.SurfaceId,
        _: XdgShell.TiledEdges,
        _: []server.Client.PreparedEvent,
    ) usize {
        return 0;
    }

    fn isModal(context: *anyopaque, _: *server.Client, _: WayringCompositor.SurfaceId) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.modal;
    }
};

test "generated XDG dialog applies and removes canonical modal state" {
    var harness: WayringXdgShell.TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var adapter: WayringXdgDialog = undefined;
    adapter.init(std.testing.allocator, &harness.host, &harness.adapter, &harness.core_shell);
    try adapter.publish();
    defer {
        adapter.destroyClientResources(harness.client());
        adapter.unpublish();
        adapter.deinit();
    }
    var gtk: TestGtkModal = .{};
    harness.adapter.setGtkEndpoint(.{
        .context = &gtk,
        .event_count = TestGtkModal.eventCount,
        .fill_events = TestGtkModal.fillEvents,
        .modal = TestGtkModal.isModal,
    });
    defer harness.adapter.clearGtkEndpoint();
    try harness.createSurface();
    try harness.installManager(2);
    try harness.createToplevel();
    try harness.bindGlobal("xdg_wm_dialog_v1", 8, 1);
    try harness.send(8, 1, &protocol.xdg_wm_dialog_v1.request_messages[1], &.{
        .{ .new_id = .{ .typed = 9 } }, .{ .object = 7 },
    });

    const window_id = harness.adapter.toplevels.items[0].core_id;
    var info = harness.core_shell.windowInfo(window_id).?;
    try std.testing.expect(info.dialog);
    try std.testing.expect(!info.modal);
    try harness.send(9, 1, &protocol.xdg_dialog_v1.request_messages[1], &.{});
    info = harness.core_shell.windowInfo(window_id).?;
    try std.testing.expect(info.dialog and info.modal);
    gtk.modal = true;
    harness.adapter.setGtkModal(harness.client(), harness.adapter.surfaceIdentity(harness.client(), 4).?, true);
    try harness.send(9, 2, &protocol.xdg_dialog_v1.request_messages[2], &.{});
    info = harness.core_shell.windowInfo(window_id).?;
    try std.testing.expect(info.dialog and info.modal);
    gtk.modal = false;
    harness.adapter.setGtkModal(harness.client(), harness.adapter.surfaceIdentity(harness.client(), 4).?, false);
    info = harness.core_shell.windowInfo(window_id).?;
    try std.testing.expect(info.dialog and !info.modal);
    try harness.send(9, 0, &protocol.xdg_dialog_v1.request_messages[0], &.{});
    info = harness.core_shell.windowInfo(window_id).?;
    try std.testing.expect(!info.dialog and !info.modal);
}

test "XDG dialog descriptors preserve the already-used error" {
    try std.testing.expectEqual(@as(u32, 1), protocol.xdg_wm_dialog_v1.interface.version);
    try std.testing.expectEqual(@as(i64, 0), protocol.xdg_wm_dialog_v1.@"error".already_used);
    try std.testing.expectEqualStrings("get_xdg_dialog", protocol.xdg_wm_dialog_v1.request_messages[1].name);
}
