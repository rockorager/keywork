//! Client-side output discovery and complete configuration transactions.

const OutputManager = @This();

const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

allocator: std.mem.Allocator,
resource: ?*zwlr.OutputManagerV1 = null,
heads: std.ArrayList(*Head) = .empty,
serial: ?u32 = null,
finished: bool = false,
failed: bool = false,

const Head = struct {
    manager: *OutputManager,
    resource: *zwlr.OutputHeadV1,
    name: ?[]u8 = null,
    enabled: bool = false,
    finished: bool = false,
    modes: std.ArrayList(*Mode) = .empty,
};

const Mode = struct {
    head: *Head,
    resource: *zwlr.OutputModeV1,
    finished: bool = false,
};

const Result = enum {
    pending,
    succeeded,
    failed,
    cancelled,
};

pub fn init(allocator: std.mem.Allocator) OutputManager {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *OutputManager) void {
    for (self.heads.items) |head| self.destroyHead(head);
    self.heads.deinit(self.allocator);
    if (self.resource) |resource| resource.destroy();
    self.* = undefined;
}

pub fn bindGlobal(
    self: *OutputManager,
    registry: *wl.Registry,
    name: u32,
    interface: []const u8,
    version: u32,
) !void {
    if (!std.mem.eql(u8, interface, std.mem.span(zwlr.OutputManagerV1.interface.name)) or
        self.resource != null)
    {
        return;
    }
    const resource = try registry.bind(
        name,
        zwlr.OutputManagerV1,
        @min(version, zwlr.OutputManagerV1.generated_version),
    );
    self.resource = resource;
    resource.setListener(*OutputManager, managerListener, self);
}

pub fn available(self: *const OutputManager) bool {
    return self.resource != null and self.serial != null and !self.finished and !self.failed;
}

pub fn apply(
    self: *OutputManager,
    display: *wl.Display,
    output_name: ?[]const u8,
    width: u32,
    height: u32,
    scale_v120: u32,
) !void {
    if (!self.available()) return error.OutputManagementUnavailable;
    var attempts: u8 = 0;
    while (attempts < 2) : (attempts += 1) {
        const result = try self.applyOnce(display, output_name, width, height, scale_v120);
        switch (result) {
            .succeeded => return,
            .cancelled => continue,
            .failed => return error.OutputConfigurationRejected,
            .pending => unreachable,
        }
    }
    return error.OutputConfigurationCancelled;
}

fn applyOnce(
    self: *OutputManager,
    display: *wl.Display,
    output_name: ?[]const u8,
    width: u32,
    height: u32,
    scale_v120: u32,
) !Result {
    const manager = self.resource orelse return error.OutputManagementUnavailable;
    const target = try self.targetHead(output_name);
    const configuration = try manager.createConfiguration(
        self.serial orelse return error.OutputManagementUnavailable,
    );
    defer configuration.destroy();
    var result: Result = .pending;
    configuration.setListener(*Result, configurationListener, &result);

    for (self.heads.items) |head| {
        if (head.finished) continue;
        if (!head.enabled) {
            configuration.disableHead(head.resource);
            continue;
        }
        const configured = try configuration.enableHead(head.resource);
        if (head == target) {
            configured.setCustomMode(@intCast(width), @intCast(height), 0);
            configured.setScale(scaleFromV120(scale_v120));
        }
    }
    configuration.apply();
    while (result == .pending) {
        if (display.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;
        if (self.failed or self.finished) return error.OutputManagementUnavailable;
    }
    return result;
}

fn targetHead(self: *OutputManager, output_name: ?[]const u8) !*Head {
    if (output_name) |name| {
        for (self.heads.items) |head| {
            if (head.finished or !head.enabled or head.name == null) continue;
            if (std.mem.eql(u8, head.name.?, name)) return head;
        }
        return error.OutputHeadNotFound;
    }

    var target: ?*Head = null;
    for (self.heads.items) |head| {
        if (head.finished or !head.enabled) continue;
        if (target != null) return error.AmbiguousOutputHead;
        target = head;
    }
    return target orelse error.OutputHeadNotFound;
}

fn destroyHead(self: *OutputManager, head: *Head) void {
    for (head.modes.items) |mode| {
        if (mode.resource.getVersion() >= zwlr.OutputModeV1.release_since_version) {
            mode.resource.release();
        } else {
            mode.resource.destroy();
        }
        self.allocator.destroy(mode);
    }
    head.modes.deinit(self.allocator);
    if (head.resource.getVersion() >= zwlr.OutputHeadV1.release_since_version) {
        head.resource.release();
    } else {
        head.resource.destroy();
    }
    if (head.name) |name| self.allocator.free(name);
    self.allocator.destroy(head);
}

fn managerListener(
    _: *zwlr.OutputManagerV1,
    event: zwlr.OutputManagerV1.Event,
    self: *OutputManager,
) void {
    switch (event) {
        .head => |advertised| {
            const head = self.allocator.create(Head) catch {
                self.failed = true;
                advertised.head.destroy();
                return;
            };
            head.* = .{ .manager = self, .resource = advertised.head };
            self.heads.append(self.allocator, head) catch {
                self.allocator.destroy(head);
                self.failed = true;
                advertised.head.destroy();
                return;
            };
            advertised.head.setListener(*Head, headListener, head);
        },
        .done => |done| self.serial = done.serial,
        .finished => self.finished = true,
    }
}

fn headListener(
    _: *zwlr.OutputHeadV1,
    event: zwlr.OutputHeadV1.Event,
    head: *Head,
) void {
    switch (event) {
        .name => |name| {
            const duplicate = head.manager.allocator.dupe(u8, std.mem.span(name.name)) catch {
                head.manager.failed = true;
                return;
            };
            if (head.name) |old| head.manager.allocator.free(old);
            head.name = duplicate;
        },
        .mode => |advertised| {
            const mode = head.manager.allocator.create(Mode) catch {
                head.manager.failed = true;
                advertised.mode.destroy();
                return;
            };
            mode.* = .{ .head = head, .resource = advertised.mode };
            head.modes.append(head.manager.allocator, mode) catch {
                head.manager.allocator.destroy(mode);
                head.manager.failed = true;
                advertised.mode.destroy();
                return;
            };
            advertised.mode.setListener(*Mode, modeListener, mode);
        },
        .enabled => |enabled| head.enabled = enabled.enabled != 0,
        .finished => head.finished = true,
        .description,
        .physical_size,
        .current_mode,
        .position,
        .transform,
        .scale,
        .make,
        .model,
        .serial_number,
        .adaptive_sync,
        => {},
    }
}

fn modeListener(_: *zwlr.OutputModeV1, event: zwlr.OutputModeV1.Event, mode: *Mode) void {
    switch (event) {
        .finished => mode.finished = true,
        .size, .refresh, .preferred => {},
    }
}

fn configurationListener(
    _: *zwlr.OutputConfigurationV1,
    event: zwlr.OutputConfigurationV1.Event,
    result: *Result,
) void {
    result.* = switch (event) {
        .succeeded => .succeeded,
        .failed => .failed,
        .cancelled => .cancelled,
    };
}

fn scaleFromV120(value: u32) wl.Fixed {
    const raw = (@as(u64, value) * 256 + 60) / 120;
    std.debug.assert(raw > 0 and raw <= std.math.maxInt(i32));
    return @enumFromInt(@as(i32, @intCast(raw)));
}

test "fractional output scale converts from v120 to Wayland fixed" {
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.5),
        scaleFromV120(180).toDouble(),
        1.0 / 256.0,
    );
}
