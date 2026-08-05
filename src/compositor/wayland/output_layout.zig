//! Stable protocol-output ownership and global logical layout.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const slot_map = @import("../slot_map.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const Output = @import("output.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
display: *wl.Server,
surface_registry: *SurfaceRegistry,
surfaces: *Surface.Store,
outputs: Store,
listener: ?Listener,
notifying_listener: bool,

const Store = slot_map.SlotMap(*Output, enum { output });
pub const Id = Store.Id;

pub const Config = Output.Config;

/// Resource-free hotplug seam. Callbacks may inspect the announced output by
/// ID but must not mutate this layout while notification is active.
pub const Listener = struct {
    context: *anyopaque,
    added: *const fn (*anyopaque, Id) error{OutOfMemory}!void,
    removing: *const fn (*anyopaque, Id) void,
};

pub const Entry = struct {
    id: Id,
    output: *Output,
};

pub const Iterator = struct {
    inner: Store.Iterator,

    pub fn next(self: *Iterator) ?Entry {
        const entry = self.inner.next() orelse return null;
        return .{ .id = entry.id, .output = entry.value.* };
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    surface_registry: *SurfaceRegistry,
    surfaces: *Surface.Store,
) void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .surface_registry = surface_registry,
        .surfaces = surfaces,
        .outputs = .{},
        .listener = null,
        .notifying_listener = false,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.outputs.len() == 0);
    std.debug.assert(self.listener == null);
    std.debug.assert(!self.notifying_listener);
    self.outputs.deinit(self.allocator);
    self.* = undefined;
}

pub fn add(self: *Self, config: Config) !Id {
    std.debug.assert(!self.notifying_listener);
    var outputs = self.iterator();
    while (outputs.next()) |entry| {
        if (std.mem.eql(u8, entry.output.name(), config.name)) return error.DuplicateName;
    }

    const output = try self.allocator.create(Output);
    errdefer self.allocator.destroy(output);
    try output.init(
        self.allocator,
        self.display,
        config,
        self.surface_registry,
        self.surfaces,
    );
    errdefer {
        output.retire();
        output.deinit();
    }
    const id = try self.outputs.insert(self.allocator, output);
    errdefer std.debug.assert(self.outputs.remove(id) != null);
    if (self.listener) |listener| {
        self.notifying_listener = true;
        defer self.notifying_listener = false;
        try listener.added(listener.context, id);
    }
    return id;
}

pub fn remove(self: *Self, id: Id) bool {
    std.debug.assert(!self.notifying_listener);
    const output = (self.outputs.get(id) orelse return false).*;
    if (self.listener) |listener| {
        self.notifying_listener = true;
        listener.removing(listener.context, id);
        self.notifying_listener = false;
    }
    const removed = self.outputs.remove(id) orelse unreachable;
    std.debug.assert(removed == output);
    output.retire();
    output.deinit();
    self.allocator.destroy(output);
    return true;
}

pub fn get(self: *Self, id: Id) ?*Output {
    const output = self.outputs.get(id) orelse return null;
    return output.*;
}

pub fn getConst(self: *const Self, id: Id) ?*const Output {
    const output = self.outputs.getConst(id) orelse return null;
    return output.*;
}

pub fn findResource(self: *Self, resource: *wl.Output) ?Entry {
    var outputs = self.iterator();
    while (outputs.next()) |entry| {
        if (entry.output.ownsResource(resource)) return entry;
    }
    return null;
}

/// Returns the output whose half-open global logical bounds contain the point.
pub fn outputAt(self: *Self, x: f64, y: f64) ?Entry {
    var outputs = self.iterator();
    while (outputs.next()) |entry| {
        const rect = entry.output.logicalRect();
        if (x >= @as(f64, @floatFromInt(rect.x)) and
            y >= @as(f64, @floatFromInt(rect.y)) and
            x < @as(f64, @floatFromInt(@as(i64, rect.x) + rect.width)) and
            y < @as(f64, @floatFromInt(@as(i64, rect.y) + rect.height))) return entry;
    }
    return null;
}

pub fn iterator(self: *Self) Iterator {
    return .{ .inner = self.outputs.iterator() };
}

pub fn setListener(self: *Self, listener: Listener) void {
    std.debug.assert(self.listener == null);
    std.debug.assert(!self.notifying_listener);
    self.listener = listener;
}

pub fn clearListener(self: *Self) void {
    std.debug.assert(self.listener != null);
    std.debug.assert(!self.notifying_listener);
    self.listener = null;
}

test "output handles are stable across additions and stale after removal" {
    const display = try wl.Server.create();
    defer display.destroy();

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);

    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();

    var layout: Self = undefined;
    layout.init(std.testing.allocator, display, &surface_registry, &surfaces);
    defer layout.deinit();

    const first = try layout.add(.{
        .size = .{ .width = 1280, .height = 720 },
        .physical_size = .{ .width = 1280, .height = 720 },
        .scale = 1,
        .name = "HEADLESS-1",
        .description = "Keywork headless output",
        .model = "headless",
    });
    const first_output = layout.get(first).?;
    const second = try layout.add(.{
        .position = .{ .x = 1280 },
        .size = .{ .width = 1920, .height = 1080 },
        .physical_size = .{ .width = 3840, .height = 2160 },
        .scale = 2,
        .preferred_scale = .{ .numerator = 180 },
        .name = "HEADLESS-2",
        .description = "Keywork headless output 2",
        .model = "headless",
    });

    try std.testing.expect(layout.get(first).? == first_output);
    try std.testing.expectEqualStrings("HEADLESS-1", layout.get(first).?.name());
    try std.testing.expectEqualStrings("HEADLESS-2", layout.get(second).?.name());
    try std.testing.expectEqual(Output.Position{ .x = 1280 }, layout.get(second).?.logicalPosition());
    try std.testing.expectEqual(@as(u32, 180), layout.get(second).?.preferredScale().numerator);
    try std.testing.expectEqual(first, layout.outputAt(0, 0).?.id);
    try std.testing.expectEqual(first, layout.outputAt(1279.999, 719.999).?.id);
    try std.testing.expectEqual(second, layout.outputAt(1280, 0).?.id);
    try std.testing.expectEqual(@as(?Entry, null), layout.outputAt(-1, 0));
    try std.testing.expectEqual(@as(?Entry, null), layout.outputAt(0, 720));
    try std.testing.expectError(error.DuplicateName, layout.add(.{
        .position = .{ .x = 3200 },
        .size = .{ .width = 1024, .height = 768 },
        .physical_size = .{ .width = 1024, .height = 768 },
        .scale = 1,
        .name = "HEADLESS-2",
        .description = "Duplicate output",
        .model = "headless",
    }));
    try std.testing.expect(layout.remove(first));
    try std.testing.expectEqual(@as(?*Output, null), layout.get(first));
    try std.testing.expect(layout.remove(second));
}

test "listener observes live hotplug IDs rolls back failure and detaches cleanly" {
    const Probe = struct {
        layout: *Self,
        added_ids: [3]Id = undefined,
        added_count: usize = 0,
        removing_ids: [2]Id = undefined,
        removing_count: usize = 0,
        fail_added: bool = true,

        fn added(context: *anyopaque, id: Id) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(self.layout.get(id) != null);
            self.added_ids[self.added_count] = id;
            self.added_count += 1;
            if (self.fail_added) return error.OutOfMemory;
        }

        fn removing(context: *anyopaque, id: Id) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(self.layout.get(id) != null);
            self.removing_ids[self.removing_count] = id;
            self.removing_count += 1;
        }
    };

    const display = try wl.Server.create();
    defer display.destroy();
    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var layout: Self = undefined;
    layout.init(std.testing.allocator, display, &surface_registry, &surfaces);
    defer layout.deinit();
    var probe: Probe = .{ .layout = &layout };
    layout.setListener(.{
        .context = &probe,
        .added = Probe.added,
        .removing = Probe.removing,
    });
    var listener_live = true;
    defer if (listener_live) layout.clearListener();

    try std.testing.expectError(error.OutOfMemory, layout.add(.{
        .size = .{ .width = 640, .height = 480 },
        .physical_size = .{ .width = 320, .height = 240 },
        .scale = 1,
        .name = "FAILED",
        .description = "failed output",
        .model = "headless",
    }));
    try std.testing.expectEqual(@as(usize, 1), probe.added_count);
    try std.testing.expect(layout.get(probe.added_ids[0]) == null);

    probe.fail_added = false;
    const live = try layout.add(.{
        .size = .{ .width = 640, .height = 480 },
        .physical_size = .{ .width = 320, .height = 240 },
        .scale = 1,
        .name = "LIVE",
        .description = "live output",
        .model = "headless",
    });
    try std.testing.expectEqual(@as(usize, 2), probe.added_count);
    try std.testing.expectEqual(live, probe.added_ids[1]);
    try std.testing.expect(layout.remove(live));
    try std.testing.expectEqual(@as(usize, 1), probe.removing_count);
    try std.testing.expectEqual(live, probe.removing_ids[0]);

    const detached = try layout.add(.{
        .size = .{ .width = 800, .height = 600 },
        .physical_size = .{ .width = 400, .height = 300 },
        .scale = 1,
        .name = "DETACHED",
        .description = "detached listener output",
        .model = "headless",
    });
    try std.testing.expectEqual(@as(usize, 3), probe.added_count);
    layout.clearListener();
    listener_live = false;
    try std.testing.expect(layout.remove(detached));
    try std.testing.expectEqual(@as(usize, 1), probe.removing_count);
}
