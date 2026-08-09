//! Scanner-backed GTK shell compatibility metadata and configure fanout.

const Self = @This();
const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const XdgShell = @import("../XdgShell.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");
const WayringXdgShell = @import("WayringXdgShell.zig");
const server = wayring.server;
const wire = wayring.wire;

const Binding = struct { owner: *Self, client: *server.Client, resource: protocol.gtk_shell1.Resource, startup_id: ?[]u8 = null };
const Surface = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.gtk_surface1.Resource,
    surface_id: WayringCompositor.SurfaceId,
    surface_object_id: u32,
    modal: bool = false,
    strings: [6]?[]u8 = .{null} ** 6,
    state_values: [5]u32 = undefined,
    edge_values: [4]u32 = undefined,
    state_wire: [1]wire.Value = undefined,
    edge_wire: [1]wire.Value = undefined,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
xdg: *WayringXdgShell,
seat: *WayringSeatAdapter,
global: ?*const server.Server.Global = null,
bindings: std.ArrayList(*Binding) = .empty,
surfaces: std.ArrayList(*Surface) = .empty,

pub fn init(self: *Self, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor, xdg: *WayringXdgShell, seat: *WayringSeatAdapter) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor, .xdg = xdg, .seat = seat };
    xdg.setGtkEndpoint(.{ .context = self, .event_count = eventCount, .fill_events = fillEvents, .modal = modalForSurface });
}
pub fn publish(self: *Self) !void {
    self.global = try self.protocol_server.addGlobal(protocol.gtk_shell1, 5, Self, self, bind);
}
pub fn unpublish(self: *Self) void {
    self.protocol_server.removeGlobal(self.global.?) catch {};
    self.global = null;
}
pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null and self.bindings.items.len == 0 and self.surfaces.items.len == 0);
    self.xdg.clearGtkEndpoint();
    self.bindings.deinit(self.allocator);
    self.surfaces.deinit(self.allocator);
    self.* = undefined;
}
pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var i = self.surfaces.items.len;
    while (i > 0) {
        i -= 1;
        if (self.surfaces.items[i].client == client) self.destroySurface(self.surfaces.items[i]);
    }
    i = self.bindings.items.len;
    while (i > 0) {
        i -= 1;
        if (self.bindings.items[i].client == client) self.destroyBinding(self.bindings.items[i]);
    }
}
fn bind(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    try self.bindings.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Binding);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Binding, value, handleBinding, null);
    try client.materialize(&value.resource.runtime);
    self.bindings.appendAssumeCapacity(value);
    protocol.gtk_shell1.@"send:capabilities"(&value.resource, 0) catch |err| {
        eventFailure(value.client, &value.resource.runtime, err, "queueing gtk_shell1.capabilities");
    };
}
fn handleBinding(resource: *protocol.gtk_shell1.Resource, request: protocol.gtk_shell1.Request, value: *Binding) !void {
    switch (request) {
        .get_gtk_surface => |v| try value.owner.createSurface(value, v.gtk_surface, v.surface),
        .set_startup_id => |v| try replaceText(value.owner.allocator, &value.startup_id, v.startup_id, value.client, &resource.runtime),
        .notify_launch => |v| validateText(v.startup_id, value.client, &resource.runtime),
        .system_bell => {},
    }
}
fn createSurface(self: *Self, binding: *Binding, id: u32, surface_object: u32) !void {
    const sid = self.compositor.surfaceId(binding.client, surface_object) orelse {
        binding.client.postImplementationError(&binding.resource.runtime, "gtk_surface requires a live same-client wl_surface");
        return;
    };
    try self.surfaces.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Surface);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = binding.client, .resource = .init(self.allocator, id, binding.resource.version(), .client, binding.client.ownerHooks()), .surface_id = sid, .surface_object_id = surface_object };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Surface, value, handleSurface, null);
    try binding.client.materialize(&value.resource.runtime);
    self.surfaces.appendAssumeCapacity(value);
}
fn handleSurface(resource: *protocol.gtk_surface1.Resource, request: protocol.gtk_surface1.Request, value: *Surface) !void {
    switch (request) {
        .release => value.owner.destroySurface(value),
        .present => {},
        .set_modal => setModal(value, true),
        .unset_modal => setModal(value, false),
        .request_focus => |v| if (v.startup_id) |text| validateText(text, value.client, &resource.runtime),
        .set_dbus_properties => |v| {
            const input = [_]?[]const u8{ v.application_id, v.app_menu_path, v.menubar_path, v.window_object_path, v.application_object_path, v.unique_bus_name };
            replaceDbusProperties(value.owner.allocator, &value.strings, input) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => {
                    value.client.postImplementationError(&resource.runtime, "GTK D-Bus property is not valid UTF-8");
                    return;
                },
            };
        },
        .titlebar_gesture => |v| {
            if (v.gesture < 1 or v.gesture > 3) {
                value.client.postProtocolError(&resource.runtime, 0, "invalid GTK titlebar gesture");
                return;
            }
            if (!live(value)) return;
            _ = value.owner.seat.acceptsXdgPointerGrab(value.client, v.seat, v.serial, value.surface_id);
        },
    }
}
fn live(value: *Surface) bool {
    const current = value.owner.compositor.surfaceId(value.client, value.surface_object_id) orelse return false;
    return std.meta.eql(current, value.surface_id);
}
fn setModal(value: *Surface, modal: bool) void {
    if (!live(value)) return;
    value.modal = modal;
    value.owner.applyModal(value.client, value.surface_id);
}
fn modalForSurface(context: *anyopaque, client: *server.Client, id: WayringCompositor.SurfaceId) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.surfaces.items) |s| {
        if (s.client == client and std.meta.eql(s.surface_id, id) and live(s) and s.modal) return true;
    }
    return false;
}
fn applyModal(self: *Self, client: *server.Client, id: WayringCompositor.SurfaceId) void {
    self.xdg.setGtkModal(client, id, modalForSurface(self, client, id));
}
fn eventCount(context: *anyopaque, client: *server.Client, id: WayringCompositor.SurfaceId) usize {
    const self: *Self = @ptrCast(@alignCast(context));
    var n: usize = 0;
    for (self.surfaces.items) |s| {
        if (s.client == client and std.meta.eql(s.surface_id, id) and live(s))
            n += if (s.resource.version() >= 2) 2 else 1;
    }
    return n;
}
fn fillEvents(context: *anyopaque, client: *server.Client, id: WayringCompositor.SurfaceId, tiled: XdgShell.TiledEdges, out: []server.Client.PreparedEvent) usize {
    const self: *Self = @ptrCast(@alignCast(context));
    var n: usize = 0;
    for (self.surfaces.items) |s| {
        if (s.client != client or !std.meta.eql(s.surface_id, id) or !live(s)) continue;
        var c: usize = 0;
        if (tiled.top or tiled.right or tiled.bottom or tiled.left) {
            s.state_values[c] = 1;
            c += 1;
        }
        if (s.resource.version() >= 2) {
            if (tiled.top) {
                s.state_values[c] = 2;
                c += 1;
            }
            if (tiled.right) {
                s.state_values[c] = 3;
                c += 1;
            }
            if (tiled.bottom) {
                s.state_values[c] = 4;
                c += 1;
            }
            if (tiled.left) {
                s.state_values[c] = 5;
                c += 1;
            }
        }
        s.state_wire[0] = .{ .array = std.mem.sliceAsBytes(s.state_values[0..c]) };
        out[n] = .{ .resource = &s.resource.runtime, .opcode = 0, .descriptor = &protocol.gtk_surface1.event_messages[0], .values = &s.state_wire };
        n += 1;
        if (s.resource.version() >= 2) {
            c = 0;
            if (!(tiled.top or tiled.right or tiled.bottom or tiled.left)) {
                for (1..5) |x| {
                    s.edge_values[c] = @intCast(x);
                    c += 1;
                }
            }
            s.edge_wire[0] = .{ .array = std.mem.sliceAsBytes(s.edge_values[0..c]) };
            out[n] = .{ .resource = &s.resource.runtime, .opcode = 1, .descriptor = &protocol.gtk_surface1.event_messages[1], .values = &s.edge_wire };
            n += 1;
        }
    }
    return n;
}
fn replaceText(a: std.mem.Allocator, dst: *?[]u8, text: ?[]const u8, client: *server.Client, r: *wayring.server.Resource) !void {
    if (text) |x| {
        if (!std.unicode.utf8ValidateSlice(x)) {
            client.postImplementationError(r, "GTK startup ID is not valid UTF-8");
            return;
        }
        const copy = try a.dupe(u8, x);
        if (dst.*) |old| a.free(old);
        dst.* = copy;
    } else {
        if (dst.*) |old| a.free(old);
        dst.* = null;
    }
}
fn validateText(text: []const u8, client: *server.Client, r: *wayring.server.Resource) void {
    if (!std.unicode.utf8ValidateSlice(text)) client.postImplementationError(r, "GTK startup ID is not valid UTF-8");
}
fn replaceDbusProperties(allocator: std.mem.Allocator, dst: *[6]?[]u8, input: [6]?[]const u8) error{ InvalidUtf8, OutOfMemory }!void {
    for (input) |text| if (text) |value| if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    var replacement: [6]?[]u8 = .{null} ** 6;
    errdefer for (replacement) |text| if (text) |value| allocator.free(value);
    for (input, 0..) |text, index| if (text) |value| {
        replacement[index] = try allocator.dupe(u8, value);
    };
    for (dst.*) |text| if (text) |value| allocator.free(value);
    dst.* = replacement;
}
fn destroySurface(self: *Self, v: *Surface) void {
    const client = v.client;
    const id = v.surface_id;
    for (v.strings) |s| if (s) |x| self.allocator.free(x);
    for (self.surfaces.items, 0..) |x, i| {
        if (x == v) {
            _ = self.surfaces.swapRemove(i);
            v.resource.destroy();
            v.resource.deinit();
            self.allocator.destroy(v);
            self.applyModal(client, id);
            return;
        }
    }
    unreachable;
}

fn eventFailure(client: *server.Client, resource: *server.Resource, err: anyerror, detail: []const u8) void {
    if (client.fatal() != null) return;
    switch (err) {
        error.OutOfMemory, error.WriteFailed => client.postOutOfMemory(resource, detail),
        error.OutputSealed, error.ClientFatal => {},
        else => client.postImplementationError(resource, detail),
    }
}
fn destroyBinding(self: *Self, v: *Binding) void {
    if (v.startup_id) |x| self.allocator.free(x);
    for (self.bindings.items, 0..) |x, i| {
        if (x == v) {
            _ = self.bindings.swapRemove(i);
            v.resource.destroy();
            v.resource.deinit();
            self.allocator.destroy(v);
            return;
        }
    }
    unreachable;
}

test "GTK scanner descriptors pin version five" {
    try std.testing.expectEqual(@as(u32, 5), protocol.gtk_shell1.interface.version);
    try std.testing.expectEqual(@as(usize, 5), protocol.gtk_surface1.request_messages.len);
}

test "GTK D-Bus replacement validates every string before copying" {
    var strings: [6]?[]u8 = .{null} ** 6;
    strings[0] = try std.testing.allocator.dupe(u8, "preserved");
    defer for (strings) |text| if (text) |value| std.testing.allocator.free(value);
    const invalid = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, replaceDbusProperties(std.testing.allocator, &strings, .{
        "valid", null, null, null, null, &invalid,
    }));
    try std.testing.expectEqualStrings("preserved", strings[0].?);
    try std.testing.expect(strings[1] == null);
}

test "GTK D-Bus replacement preserves prior values on allocation failure" {
    var strings: [6]?[]u8 = .{null} ** 6;
    strings[0] = try std.testing.allocator.dupe(u8, "preserved");
    defer for (strings) |text| if (text) |value| std.testing.allocator.free(value);
    var storage: [3]u8 = undefined;
    var failing = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.OutOfMemory, replaceDbusProperties(failing.allocator(), &strings, .{
        "one", "two", null, null, null, null,
    }));
    try std.testing.expectEqualStrings("preserved", strings[0].?);
    try std.testing.expect(strings[1] == null);
}
