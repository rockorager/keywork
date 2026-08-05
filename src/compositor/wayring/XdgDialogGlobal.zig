//! Native xdg-dialog-v1 toplevel dialog and modal hints.

const XdgDialogGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const XdgShell = @import("XdgShell.zig");

const advertised_version: u32 = 1;

allocator: std.mem.Allocator,
server: *Server,
shell: *XdgShell,
global_name: u32,
dialogs: std.ArrayList(*Dialog) = .empty,

const Dialog = struct {
    owner: *XdgDialogGlobal,
    toplevel: ?wayring.ObjectHandle,

    fn setModal(self: *Dialog, client: *Server.Client, modal: bool) !void {
        const toplevel = self.toplevel orelse return;
        self.owner.shell.setToplevelDialogModal(
            client,
            toplevel,
            self,
            modal,
        ) catch |err| switch (err) {
            error.UnknownResource, error.StaleObject => self.toplevel = null,
            else => return err,
        };
    }

    fn toplevelDestroyed(context: *anyopaque) void {
        const self: *Dialog = @ptrCast(@alignCast(context));
        self.toplevel = null;
    }

    fn deinit(self: *Dialog, client: *Server.Client) void {
        if (self.toplevel) |toplevel| {
            self.owner.shell.detachToplevelDialog(
                client,
                toplevel,
                self,
            ) catch |err| switch (err) {
                error.UnknownResource, error.StaleObject => {},
                else => unreachable,
            };
        }
        const owner = self.owner;
        for (owner.dialogs.items, 0..) |dialog, index| {
            if (dialog != self) continue;
            _ = owner.dialogs.orderedRemove(index);
            owner.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

pub fn init(
    self: *XdgDialogGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    shell: *XdgShell,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .shell = shell,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.xdg_wm_dialog_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *XdgDialogGlobal) void {
    std.debug.assert(self.dialogs.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.dialogs.deinit(self.allocator);
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *XdgDialogGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(
        id,
        &generated.xdg_wm_dialog_v1,
        version,
        .{ .context = self, .dispatch = dispatchManager },
    ) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *XdgDialogGlobal = @ptrCast(@alignCast(context));
    switch (try generated.xdg_wm_dialog_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_xdg_dialog => |request| try self.createDialog(
            client,
            resource,
            request.toplevel,
            request.id,
        ),
    }
}

fn createDialog(
    self: *XdgDialogGlobal,
    client: *Server.Client,
    manager_resource: wayring.ObjectHandle,
    toplevel_id: u32,
    id: u32,
) !void {
    const object = client.connection.object(toplevel_id) orelse
        return error.UnknownToplevel;
    const toplevel: wayring.ObjectHandle = .{
        .id = toplevel_id,
        .generation = object.generation,
    };
    const dialog = self.allocator.create(Dialog) catch
        return client.postNoMemory();
    errdefer self.allocator.destroy(dialog);
    self.dialogs.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    dialog.* = .{ .owner = self, .toplevel = toplevel };
    self.shell.attachToplevelDialog(client, toplevel, .{
        .context = dialog,
        .toplevel_destroyed = Dialog.toplevelDestroyed,
    }) catch |err| switch (err) {
        error.AlreadyExists => return client.postError(
            manager_resource,
            @intFromEnum(generated.xdg_wm_dialog_v1_types.@"error".already_used),
            "xdg_toplevel already has an xdg_dialog_v1 object",
        ),
        else => return err,
    };
    errdefer self.shell.detachToplevelDialog(client, toplevel, dialog) catch unreachable;
    const version = try client.resourceVersion(
        manager_resource,
        &generated.xdg_wm_dialog_v1,
    );
    _ = client.createResource(
        id,
        &generated.xdg_dialog_v1,
        version,
        .{
            .context = dialog,
            .dispatch = dispatchDialog,
            .destroy = destroyDialog,
        },
    ) catch return client.postNoMemory();
    self.dialogs.appendAssumeCapacity(dialog);
}

fn dispatchDialog(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const dialog: *Dialog = @ptrCast(@alignCast(context));
    switch (try generated.xdg_dialog_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_modal => try dialog.setModal(client, true),
        .unset_modal => try dialog.setModal(client, false),
    }
}

fn destroyDialog(
    context: *anyopaque,
    client: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const dialog: *Dialog = @ptrCast(@alignCast(context));
    dialog.deinit(client);
}

test "dialogs survive managers, track modal state, and become inert" {
    const core = @import("wayring-core");
    const CompositorGlobal = @import("CompositorGlobal.zig");
    const SurfaceTree = @import("SurfaceTree.zig");

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var tree = SurfaceTree.init(std.testing.allocator);
    defer tree.deinit();
    var shell: XdgShell = undefined;
    try shell.init(std.testing.allocator, &server, &tree, .{
        .context = &tree,
        .surface_size = testSurfaceSize,
        .output_bounds = testOutputBounds,
    });
    defer shell.deinit();
    var dialogs: XdgDialogGlobal = undefined;
    try dialogs.init(std.testing.allocator, &server, &shell);
    defer dialogs.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;

    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var compositor_name: u32 = 0;
    var shell_name: u32 = 0;
    var dialog_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.xdg_wm_base.name))
            shell_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.xdg_wm_dialog_v1.name)) {
            try std.testing.expectEqual(advertised_version, global.version);
            dialog_name = global.name;
        }
    }
    try std.testing.expect(compositor_name != 0);
    try std.testing.expect(shell_name != 0);
    try std.testing.expect(dialog_name != 0);

    const compositor_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const wm_base: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            shell_name,
            generated.xdg_wm_base.name,
            6,
            4,
            &generated.xdg_wm_base,
        ),
    };
    const manager: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            dialog_name,
            generated.xdg_wm_dialog_v1.name,
            advertised_version,
            5,
            &generated.xdg_wm_dialog_v1,
        ),
    };
    const surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const xdg_surface = try generated.xdg_wm_base_types.requests.get_xdg_surface(
        &peer,
        wm_base,
        surface,
    );
    const toplevel = try generated.xdg_surface_types.requests.get_toplevel(
        &peer,
        xdg_surface,
    );
    const dialog = try generated.xdg_wm_dialog_v1_types.requests.get_xdg_dialog(
        &peer,
        manager,
        toplevel,
    );
    try generated.xdg_wm_dialog_v1_types.requests.destroy(&peer, manager);
    try generated.xdg_dialog_v1_types.requests.set_modal(&peer, dialog);
    try transferToServer(&peer, client);

    const toplevel_handle: wayring.ObjectHandle = .{
        .id = toplevel.id,
        .generation = client.connection.object(toplevel.id).?.generation,
    };
    try std.testing.expectEqual(
        XdgShell.ToplevelDialogState{ .dialog = true, .modal = true },
        try shell.toplevelDialogState(client, toplevel_handle),
    );
    try generated.xdg_dialog_v1_types.requests.unset_modal(&peer, dialog);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(
        XdgShell.ToplevelDialogState{ .dialog = true, .modal = false },
        try shell.toplevelDialogState(client, toplevel_handle),
    );
    try generated.xdg_dialog_v1_types.requests.destroy(&peer, dialog);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(
        XdgShell.ToplevelDialogState{ .dialog = false, .modal = false },
        try shell.toplevelDialogState(client, toplevel_handle),
    );

    const replacement_manager: wayring.ObjectHandle = .{
        .id = 20,
        .generation = try core.bind(
            &peer,
            registry.id,
            dialog_name,
            generated.xdg_wm_dialog_v1.name,
            advertised_version,
            20,
            &generated.xdg_wm_dialog_v1,
        ),
    };
    const inert_dialog = try generated.xdg_wm_dialog_v1_types.requests.get_xdg_dialog(
        &peer,
        replacement_manager,
        toplevel,
    );
    try generated.xdg_toplevel_types.requests.destroy(&peer, toplevel);
    try generated.xdg_dialog_v1_types.requests.set_modal(&peer, inert_dialog);
    try generated.xdg_dialog_v1_types.requests.unset_modal(&peer, inert_dialog);
    try generated.xdg_dialog_v1_types.requests.destroy(&peer, inert_dialog);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
    try std.testing.expectEqual(@as(usize, 0), dialogs.dialogs.items.len);

    const duplicate_toplevel = try generated.xdg_surface_types.requests.get_toplevel(
        &peer,
        xdg_surface,
    );
    _ = try generated.xdg_wm_dialog_v1_types.requests.get_xdg_dialog(
        &peer,
        replacement_manager,
        duplicate_toplevel,
    );
    _ = try generated.xdg_wm_dialog_v1_types.requests.get_xdg_dialog(
        &peer,
        replacement_manager,
        duplicate_toplevel,
    );
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    try std.testing.expectEqual(Server.ClientState.protocol_error, client.state);
    try std.testing.expectEqual(@as(usize, 1), dialogs.dialogs.items.len);

    try transferFromServer(&peer, client);
    var got_already_used = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != 1) continue;
        switch (try core.decodeDisplayEvent(&message)) {
            .error_event => |event| if (event.object_id == replacement_manager.id and
                event.code == @intFromEnum(
                    generated.xdg_wm_dialog_v1_types.@"error".already_used,
                ))
            {
                got_already_used = true;
            },
            .delete_id => {},
        }
    }
    try std.testing.expect(got_already_used);
}

fn testSurfaceSize(
    _: *anyopaque,
    _: *const @import("CompositorGlobal.zig").Surface,
) ?@import("../render/types.zig").Size {
    return .{ .width = 1280, .height = 720 };
}

fn testOutputBounds(_: *anyopaque) @import("../render/types.zig").Rect {
    return .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
}

fn transferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
