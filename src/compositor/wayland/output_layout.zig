//! Stable protocol-output ownership and global logical layout.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const slot_map = @import("../slot_map.zig");
const Output = @import("output.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
display: *wl.Server,
surfaces: *Surface.Store,
outputs: Store,

const Store = slot_map.SlotMap(*Output, enum { output });
pub const Id = Store.Id;

pub const Config = Output.Config;

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
    surfaces: *Surface.Store,
) void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .surfaces = surfaces,
        .outputs = .{},
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.outputs.len() == 0);
    self.outputs.deinit(self.allocator);
    self.* = undefined;
}

pub fn add(self: *Self, config: Config) !Id {
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
        self.surfaces,
    );
    errdefer output.deinit();
    return self.outputs.insert(self.allocator, output);
}

pub fn remove(self: *Self, id: Id) bool {
    const output = self.outputs.remove(id) orelse return false;
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

test "output handles are stable across additions and stale after removal" {
    const display = try wl.Server.create();
    defer display.destroy();

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);

    var layout: Self = undefined;
    layout.init(std.testing.allocator, display, &surfaces);
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
