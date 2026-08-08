//! Protocol-neutral output-management epochs and configuration transactions.
//!
//! Frontends retain their own wire objects, but all of them use this authority
//! to bind a configuration to an exact client, manager, and output generation.

const OutputManagement = @This();

const std = @import("std");
const DrmOutput = @import("backend/drm.zig");
const render = @import("render/types.zig");
const Output = @import("wayland/output.zig");

pub const Client = u64;
pub const Manager = u64;
pub const Head = u64;

pub const Target = union(enum) {
    drm: *DrmOutput,
    virtual: *Output,
};

pub const Change = struct {
    target: Target,
    was_enabled: bool,
    enabled: bool,
    old_x: i32,
    old_y: i32,
    old_scale: render.Scale,
    old_mode_index: usize,
    x: i32,
    y: i32,
    scale: render.Scale,
    mode_index: usize,
    custom_mode: ?CustomMode,
};

pub const Listener = struct {
    context: *anyopaque,
    test_configuration: *const fn (*anyopaque, []const Change) bool,
    apply: *const fn (*anyopaque, []const Change) bool,
};

pub const HeadRef = struct {
    id: Head,
    generation: u64,
};

pub const Position = struct { x: i32, y: i32 };

pub const HeadState = struct {
    reference: HeadRef,
    connected: bool = true,
    target: ?Target = null,
    enabled: bool = true,
    x: i32 = 0,
    y: i32 = 0,
    scale: render.Scale = .{},
    mode_count: usize = 1,
    current_mode_index: usize = 0,
};

pub const ConfiguredHead = struct {
    reference: HeadRef,
    enabled: bool,
    position: ?Position = null,
    scale: ?render.Scale = null,
    mode_index: ?usize = null,
    custom_mode: ?CustomMode = null,
    transform_supported: bool = true,
    adaptive_sync_supported: bool = true,
};

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    changes: []Change,

    pub fn deinit(self: *Prepared) void {
        self.allocator.free(self.changes);
        self.* = undefined;
    }
};

pub const CustomMode = struct {
    width: u32,
    height: u32,
    refresh_millihertz: i32,
};

pub const Transaction = struct {
    allocator: std.mem.Allocator,
    source_client: Client,
    source_manager: Manager,
    serial: u32,
    used: bool = false,
    heads: std.ArrayList(ConfiguredHead) = .empty,

    pub fn deinit(self: *Transaction) void {
        self.heads.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn configure(self: *Transaction, value: ConfiguredHead) error{ OutOfMemory, AlreadyConfigured }!void {
        for (self.heads.items) |head| if (head.reference.id == value.reference.id)
            return error.AlreadyConfigured;
        try self.heads.append(self.allocator, value);
    }

    pub fn consume(
        self: *Transaction,
        authority: *const OutputManagement,
        source_client: Client,
        source_manager: Manager,
        live_heads: []const HeadState,
    ) error{ AlreadyUsed, ForeignSource, Stale, MissingHead }![]const ConfiguredHead {
        if (self.used) return error.AlreadyUsed;
        self.used = true;
        if (self.source_client != source_client or self.source_manager != source_manager)
            return error.ForeignSource;
        if (self.serial != authority.serial) return error.Stale;
        for (live_heads) |live| {
            if (!live.connected) continue;
            var found = false;
            for (self.heads.items) |configured| {
                if (configured.reference.id != live.reference.id) continue;
                if (configured.reference.generation != live.reference.generation) return error.Stale;
                found = true;
                break;
            }
            if (!found) return error.MissingHead;
        }
        for (self.heads.items) |configured| {
            var found = false;
            for (live_heads) |live| if (live.connected and std.meta.eql(live.reference, configured.reference)) {
                found = true;
                break;
            };
            if (!found) return error.Stale;
        }
        return self.heads.items;
    }

    /// Validates a complete transaction and allocates the immutable canonical
    /// changes before any backend or observer can be entered.
    pub fn prepare(
        self: *Transaction,
        authority: *const OutputManagement,
        source_client: Client,
        source_manager: Manager,
        live_heads: []const HeadState,
    ) error{ OutOfMemory, AlreadyUsed, ForeignSource, Stale, MissingHead, InvalidConfiguration }!Prepared {
        const configured_heads = try self.consume(authority, source_client, source_manager, live_heads);
        var enabled_count: usize = 0;
        const changes = try self.allocator.alloc(Change, configured_heads.len);
        errdefer self.allocator.free(changes);
        for (configured_heads, changes) |configured, *change| {
            var live: ?HeadState = null;
            for (live_heads) |candidate| if (std.meta.eql(candidate.reference, configured.reference)) {
                live = candidate;
                break;
            };
            const head = live orelse return error.Stale;
            const target = head.target orelse return error.InvalidConfiguration;
            if (!configured.transform_supported or !configured.adaptive_sync_supported)
                return error.InvalidConfiguration;
            if (configured.enabled) enabled_count += 1;
            const mode_index = configured.mode_index orelse head.current_mode_index;
            if (mode_index >= head.mode_count) return error.InvalidConfiguration;
            change.* = .{
                .target = target,
                .was_enabled = head.enabled,
                .enabled = configured.enabled,
                .old_x = head.x,
                .old_y = head.y,
                .old_scale = head.scale,
                .old_mode_index = head.current_mode_index,
                .x = if (configured.position) |position| position.x else head.x,
                .y = if (configured.position) |position| position.y else head.y,
                .scale = configured.scale orelse head.scale,
                .mode_index = mode_index,
                .custom_mode = configured.custom_mode,
            };
        }
        if (enabled_count == 0) return error.InvalidConfiguration;
        return .{ .allocator = self.allocator, .changes = changes };
    }
};

serial: u32 = 1,
next_generation: ?u64 = 1,

pub fn changed(self: *OutputManagement) u32 {
    self.serial = changedSerial(self.serial);
    return self.serial;
}

pub fn nextSerial(self: *const OutputManagement) u32 {
    return changedSerial(self.serial);
}

fn changedSerial(serial: u32) u32 {
    const next = serial +% 1;
    return if (next == 0) 1 else next;
}

pub fn generation(self: *OutputManagement, id: Head) error{GenerationExhausted}!HeadRef {
    const value = self.next_generation orelse return error.GenerationExhausted;
    self.next_generation = if (value == std.math.maxInt(u64)) null else value + 1;
    return .{ .id = id, .generation = value };
}

pub fn transaction(self: *const OutputManagement, allocator: std.mem.Allocator, client: Client, manager: Manager) Transaction {
    return .{ .allocator = allocator, .source_client = client, .source_manager = manager, .serial = self.serial };
}

pub fn scaleFromFixed(raw: i32) error{InvalidScale}!render.Scale {
    if (raw <= 0) return error.InvalidScale;
    const numerator = (@as(u64, @intCast(raw)) * render.Scale.denominator + 128) / 256;
    if (numerator == 0 or numerator > std.math.maxInt(u32)) return error.InvalidScale;
    return .{ .numerator = @intCast(numerator) };
}

test "transaction binds source serial and exact head generation" {
    var authority: OutputManagement = .{};
    const first = try authority.generation(9);
    var transaction_value = authority.transaction(std.testing.allocator, 2, 3);
    defer transaction_value.deinit();
    try transaction_value.configure(.{ .reference = first, .enabled = true });
    try std.testing.expectError(error.ForeignSource, transaction_value.consume(&authority, 2, 4, &.{.{ .reference = first }}));

    var stale = authority.transaction(std.testing.allocator, 2, 3);
    defer stale.deinit();
    try stale.configure(.{ .reference = first, .enabled = true });
    _ = authority.changed();
    try std.testing.expectError(error.Stale, stale.consume(&authority, 2, 3, &.{.{ .reference = first }}));

    const replacement = try authority.generation(9);
    var replaced = authority.transaction(std.testing.allocator, 2, 3);
    defer replaced.deinit();
    try replaced.configure(.{ .reference = first, .enabled = true });
    try std.testing.expectError(error.Stale, replaced.consume(&authority, 2, 3, &.{.{ .reference = replacement }}));
}

test "transaction rejects duplicate and missing heads without partial mutation" {
    var authority: OutputManagement = .{};
    const one = try authority.generation(1);
    const two = try authority.generation(2);
    var value = authority.transaction(std.testing.allocator, 5, 6);
    defer value.deinit();
    try value.configure(.{ .reference = one, .enabled = true, .scale = .{ .numerator = 150 }, .custom_mode = .{ .width = 1920, .height = 1080, .refresh_millihertz = 60_000 } });
    try std.testing.expectError(error.AlreadyConfigured, value.configure(.{ .reference = one, .enabled = false }));
    try std.testing.expectEqual(@as(usize, 1), value.heads.items.len);
    try std.testing.expectError(error.MissingHead, value.consume(&authority, 5, 6, &.{ .{ .reference = one }, .{ .reference = two } }));
}
