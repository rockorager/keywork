//! Privileged DRM output power controls.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");

const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

allocator: std.mem.Allocator,
global: *wl.Global,
outputs: *OutputLayout,
security_context: *SecurityContext,
controls: std.ArrayList(*Control),
listener: Listener,

pub const Listener = struct {
    context: *anyopaque,
    powered: *const fn (*anyopaque, OutputLayout.Id) ?bool,
    set_powered: *const fn (*anyopaque, OutputLayout.Id, bool) bool,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    outputs: *OutputLayout,
    security_context: *SecurityContext,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .outputs = outputs,
        .security_context = security_context,
        .controls = .empty,
        .listener = listener,
    };
    errdefer self.controls.deinit(allocator);
    self.global = try wl.Global.create(
        display,
        zwlr.OutputPowerManagerV1,
        1,
        *Self,
        self,
        bind,
    );
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.controls.items.len == 0);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.controls.deinit(self.allocator);
    self.* = undefined;
}

pub fn removeOutput(self: *Self, output_id: OutputLayout.Id) void {
    for (self.controls.items) |control| {
        const controlled = control.output_id orelse continue;
        if (!std.meta.eql(controlled, output_id)) continue;
        control.output_id = null;
        control.resource.sendFailed();
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwlr.OutputPowerManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwlr.OutputPowerManagerV1,
    request: zwlr.OutputPowerManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_output_power => |get| self.createControl(resource, get.id, get.output),
    }
}

fn createControl(
    self: *Self,
    manager: *zwlr.OutputPowerManagerV1,
    id: u32,
    output_resource: *wl.Output,
) void {
    const resource = zwlr.OutputPowerV1.create(
        manager.getClient(),
        manager.getVersion(),
        id,
    ) catch {
        manager.postNoMemory();
        return;
    };
    const control = self.allocator.create(Control) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    const entry = self.outputs.findResource(output_resource);
    const output_id = if (entry) |output|
        if (self.controlForOutput(output.id) == null) output.id else null
    else
        null;
    control.* = .{
        .manager = self,
        .resource = resource,
        .output_id = output_id,
    };
    self.controls.append(self.allocator, control) catch {
        self.allocator.destroy(control);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Control, handleControlRequest, handleControlDestroy, control);
    if (output_id) |controlled| {
        const powered = self.listener.powered(self.listener.context, controlled) orelse {
            control.output_id = null;
            resource.sendFailed();
            return;
        };
        resource.sendMode(if (powered) .on else .off);
    } else {
        resource.sendFailed();
    }
}

fn controlForOutput(self: *Self, output_id: OutputLayout.Id) ?*Control {
    for (self.controls.items) |control| {
        const controlled = control.output_id orelse continue;
        if (std.meta.eql(controlled, output_id)) return control;
    }
    return null;
}

fn handleControlRequest(
    resource: *zwlr.OutputPowerV1,
    request: zwlr.OutputPowerV1.Request,
    control: *Control,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_mode => |set| {
            const powered = switch (set.mode) {
                .on => true,
                .off => false,
                else => {
                    resource.postError(.invalid_mode, "invalid output power mode");
                    return;
                },
            };
            const output_id = control.output_id orelse return;
            const current = control.manager.listener.powered(
                control.manager.listener.context,
                output_id,
            ) orelse {
                control.output_id = null;
                resource.sendFailed();
                return;
            };
            if (current == powered) return;
            if (!control.manager.listener.set_powered(
                control.manager.listener.context,
                output_id,
                powered,
            )) {
                control.output_id = null;
                resource.sendFailed();
                return;
            }
            resource.sendMode(if (powered) .on else .off);
        },
    }
}

fn handleControlDestroy(_: *zwlr.OutputPowerV1, control: *Control) void {
    for (control.manager.controls.items, 0..) |candidate, index| {
        if (candidate != control) continue;
        _ = control.manager.controls.orderedRemove(index);
        control.manager.allocator.destroy(control);
        return;
    }
    unreachable;
}

const Control = struct {
    manager: *Self,
    resource: *zwlr.OutputPowerV1,
    output_id: ?OutputLayout.Id,
};
