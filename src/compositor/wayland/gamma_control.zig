//! Privileged per-output gamma ramp controls.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

allocator: std.mem.Allocator,
io: std.Io,
global: *wl.Global,
outputs: *OutputLayout,
security_context: *SecurityContext,
controls: std.ArrayList(*Control),
listener: Listener,

pub const Listener = struct {
    context: *anyopaque,
    gamma_size: *const fn (*anyopaque, OutputLayout.Id) ?u32,
    set_gamma: *const fn (*anyopaque, OutputLayout.Id, []const u16) bool,
    reset_gamma: *const fn (*anyopaque, OutputLayout.Id) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    outputs: *OutputLayout,
    security_context: *SecurityContext,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .global = undefined,
        .outputs = outputs,
        .security_context = security_context,
        .controls = .empty,
        .listener = listener,
    };
    errdefer self.controls.deinit(allocator);
    self.global = try wl.Global.create(
        display,
        zwlr.GammaControlManagerV1,
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
        self.failControl(control, true);
    }
}

pub fn refreshOutputs(self: *Self) void {
    for (self.controls.items) |control| {
        const output_id = control.output_id orelse continue;
        const gamma_size = self.listener.gamma_size(self.listener.context, output_id) orelse {
            self.failControl(control, true);
            continue;
        };
        if (gamma_size != control.gamma_size) self.failControl(control, true);
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwlr.GammaControlManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwlr.GammaControlManagerV1,
    request: zwlr.GammaControlManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_gamma_control => |get| self.createControl(resource, get.id, get.output),
    }
}

fn createControl(
    self: *Self,
    manager: *zwlr.GammaControlManagerV1,
    id: u32,
    output_resource: *wl.Output,
) void {
    const resource = zwlr.GammaControlV1.create(
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
    const gamma_size = if (output_id) |controlled|
        self.listener.gamma_size(self.listener.context, controlled)
    else
        null;
    control.* = .{
        .manager = self,
        .resource = resource,
        .output_id = if (gamma_size != null) output_id else null,
        .gamma_size = gamma_size orelse 0,
    };
    self.controls.append(self.allocator, control) catch {
        self.allocator.destroy(control);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Control, handleControlRequest, handleControlDestroy, control);
    if (gamma_size) |size| {
        resource.sendGammaSize(size);
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

fn failControl(self: *Self, control: *Control, reset: bool) void {
    const output_id = control.output_id orelse return;
    control.output_id = null;
    if (reset) self.listener.reset_gamma(self.listener.context, output_id);
    control.resource.sendFailed();
}

fn handleControlRequest(
    resource: *zwlr.GammaControlV1,
    request: zwlr.GammaControlV1.Request,
    control: *Control,
) void {
    switch (request) {
        .destroy => {
            if (control.output_id) |output_id| {
                control.manager.listener.reset_gamma(
                    control.manager.listener.context,
                    output_id,
                );
                control.output_id = null;
            }
            resource.destroy();
        },
        .set_gamma => |set| {
            defer _ = std.c.close(set.fd);
            const output_id = control.output_id orelse return;
            const table = readGammaTable(
                control.manager.io,
                control.manager.allocator,
                set.fd,
                control.gamma_size,
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    resource.postNoMemory();
                    return;
                },
                error.InvalidGamma => {
                    resource.postError(.invalid_gamma, "invalid gamma table size");
                    return;
                },
                error.ReadGammaFailed => {
                    control.manager.failControl(control, true);
                    return;
                },
            };
            defer control.manager.allocator.free(table);
            if (!control.manager.listener.set_gamma(
                control.manager.listener.context,
                output_id,
                table,
            )) control.manager.failControl(control, true);
        },
    }
}

fn handleControlDestroy(_: *zwlr.GammaControlV1, control: *Control) void {
    if (control.output_id) |output_id| {
        control.manager.listener.reset_gamma(control.manager.listener.context, output_id);
    }
    for (control.manager.controls.items, 0..) |candidate, index| {
        if (candidate != control) continue;
        _ = control.manager.controls.orderedRemove(index);
        control.manager.allocator.destroy(control);
        return;
    }
    unreachable;
}

fn readGammaTable(
    io: std.Io,
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    gamma_size: u32,
) error{ OutOfMemory, InvalidGamma, ReadGammaFailed }![]u16 {
    const value_count = std.math.mul(usize, gamma_size, 3) catch
        return error.InvalidGamma;
    const byte_count = std.math.mul(usize, value_count, @sizeOf(u16)) catch
        return error.InvalidGamma;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch return error.ReadGammaFailed;
    if (stat.kind != .file or stat.size != byte_count) return error.InvalidGamma;
    const table = allocator.alloc(u16, value_count) catch return error.OutOfMemory;
    errdefer allocator.free(table);
    const bytes = std.mem.sliceAsBytes(table);
    const bytes_read = file.readPositionalAll(io, bytes, 0) catch
        return error.ReadGammaFailed;
    if (bytes_read != bytes.len) return error.InvalidGamma;
    return table;
}

const Control = struct {
    manager: *Self,
    resource: *zwlr.GammaControlV1,
    output_id: ?OutputLayout.Id,
    gamma_size: u32,
};

const TestListenerState = struct {
    reset_count: usize = 0,

    fn gammaSize(_: *anyopaque, _: OutputLayout.Id) ?u32 {
        return 256;
    }

    fn setGamma(_: *anyopaque, _: OutputLayout.Id, _: []const u16) bool {
        return true;
    }

    fn resetGamma(context: *anyopaque, _: OutputLayout.Id) void {
        const self: *TestListenerState = @ptrCast(@alignCast(context));
        self.reset_count += 1;
    }
};

test "removed output fails its control and resets gamma once" {
    const display = try wl.Server.create();
    defer display.destroy();

    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &sockets),
    );
    defer _ = std.c.close(sockets[1]);
    const client = wl.Client.create(display, sockets[0]) orelse return error.OutOfMemory;
    defer client.destroy();

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var outputs: OutputLayout = undefined;
    outputs.init(std.testing.allocator, display, &surface_registry, &surfaces);
    defer outputs.deinit();
    const output_id = try outputs.add(.{
        .size = .{ .width = 1280, .height = 720 },
        .physical_size = .{ .width = 1280, .height = 720 },
        .scale = 1,
        .name = "TEST-1",
        .description = "Test output",
        .model = "test",
    });
    defer std.debug.assert(outputs.remove(output_id));

    var state: TestListenerState = .{};
    var manager: Self = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .global = undefined,
        .outputs = &outputs,
        .security_context = undefined,
        .controls = .empty,
        .listener = .{
            .context = &state,
            .gamma_size = TestListenerState.gammaSize,
            .set_gamma = TestListenerState.setGamma,
            .reset_gamma = TestListenerState.resetGamma,
        },
    };
    defer manager.controls.deinit(std.testing.allocator);
    const resource = try zwlr.GammaControlV1.create(client, 1, 0);
    const control = try std.testing.allocator.create(Control);
    control.* = .{
        .manager = &manager,
        .resource = resource,
        .output_id = output_id,
        .gamma_size = 256,
    };
    try manager.controls.append(std.testing.allocator, control);
    resource.setHandler(*Control, handleControlRequest, handleControlDestroy, control);

    manager.removeOutput(output_id);
    try std.testing.expectEqual(@as(usize, 1), state.reset_count);
    try std.testing.expect(control.output_id == null);
    try std.testing.expect(client.getObject(resource.getId()) != null);

    resource.destroy();
    try std.testing.expectEqual(@as(usize, 1), state.reset_count);
    try std.testing.expectEqual(@as(usize, 0), manager.controls.items.len);
}

test "gamma table reader accepts three native-endian ramps" {
    const fd = try std.posix.memfd_create("keywork-gamma-test", 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(std.testing.io);
    const expected = [_]u16{ 0, 65535, 10, 20, 30, 40 };
    try file.writePositionalAll(std.testing.io, std.mem.asBytes(&expected), 0);

    const actual = try readGammaTable(std.testing.io, std.testing.allocator, fd, 2);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u16, &expected, actual);
}

test "gamma table reader rejects a short payload" {
    const fd = try std.posix.memfd_create("keywork-gamma-short-test", 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(std.testing.io);
    const short = [_]u16{ 0, 1, 2, 3, 4 };
    try file.writePositionalAll(std.testing.io, std.mem.asBytes(&short), 0);

    try std.testing.expectError(
        error.InvalidGamma,
        readGammaTable(std.testing.io, std.testing.allocator, fd, 2),
    );
}

test "gamma table reader rejects a trailing payload" {
    const fd = try std.posix.memfd_create("keywork-gamma-long-test", 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(std.testing.io);
    const long = [_]u16{ 0, 1, 2, 3, 4, 5, 6 };
    try file.writePositionalAll(std.testing.io, std.mem.asBytes(&long), 0);

    try std.testing.expectError(
        error.InvalidGamma,
        readGammaTable(std.testing.io, std.testing.allocator, fd, 2),
    );
}
