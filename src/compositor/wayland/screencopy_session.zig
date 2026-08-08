//! Protocol-resource-free wlr-screencopy scheduling state.
//!
//! Frontends own wire resources, destinations, errors, and completion events.
//! This owner keeps the shared one-shot, per-manager damage baseline, and
//! per-output generation rules used by every screencopy frontend.

const std = @import("std");
const render = @import("../render/types.zig");
const OutputLayout = @import("../output_layout.zig");

const Owner = @This();

pub const Target = struct {
    output: OutputLayout.Id,
    region: ?render.Rect = null,
};

pub const Manager = struct {
    baselines: std.ArrayList(Baseline) = .empty,

    const Baseline = struct {
        output: OutputLayout.Id,
        generation: ?u64 = null,
    };

    pub fn deinit(self: *Manager, allocator: std.mem.Allocator) void {
        self.baselines.deinit(allocator);
        self.* = undefined;
    }

    fn ensureOutput(self: *Manager, allocator: std.mem.Allocator, output: OutputLayout.Id) !void {
        if (self.baseline(output) != null) return;
        try self.baselines.append(allocator, .{ .output = output });
    }

    fn baseline(self: *Manager, output: OutputLayout.Id) ?*Baseline {
        for (self.baselines.items) |*candidate| {
            if (std.meta.eql(candidate.output, output)) return candidate;
        }
        return null;
    }

    fn removeOutput(self: *Manager, output: OutputLayout.Id) void {
        for (self.baselines.items, 0..) |candidate, index| {
            if (!std.meta.eql(candidate.output, output)) continue;
            _ = self.baselines.swapRemove(index);
            return;
        }
    }

    fn invalidateOutput(self: *Manager, output: OutputLayout.Id) void {
        const current = self.baseline(output) orelse return;
        current.generation = null;
    }
};

pub const Frame = struct {
    manager: *Manager,
    target: ?Target,
    size: ?render.Size,
    overlay_cursor: bool,
    used: bool = false,
    finished: bool = false,
    with_damage: bool = false,
    capture_generation: ?u64 = null,

    pub fn start(self: *Frame, owner: *Owner, with_damage: bool) ?bool {
        if (self.finished or self.used) return null;
        const target = self.target orelse return false;
        if (self.size == null) return false;
        const generation = owner.outputGeneration(target.output) orelse return false;
        const baseline = self.manager.baseline(target.output) orelse return false;
        self.used = true;
        self.with_damage = with_damage;
        return with_damage and baseline.generation != null and baseline.generation.? == generation;
    }

    pub fn beginCapture(self: *Frame, generation: u64) bool {
        if (self.finished or !self.used or self.capture_generation != null) return false;
        self.capture_generation = generation;
        return true;
    }

    pub fn ready(self: *Frame) bool {
        if (self.finished) return false;
        const target = self.target orelse return false;
        const generation = self.capture_generation orelse return false;
        const baseline = self.manager.baseline(target.output) orelse return false;
        baseline.generation = generation;
        self.finished = true;
        return true;
    }

    pub fn fail(self: *Frame) bool {
        if (self.finished) return false;
        self.finished = true;
        self.target = null;
        return true;
    }
};

const OutputGeneration = struct {
    output: OutputLayout.Id,
    generation: u64 = 0,
};

allocator: std.mem.Allocator,
output_generations: std.ArrayList(OutputGeneration) = .empty,

pub fn init(allocator: std.mem.Allocator) Owner {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Owner) void {
    self.output_generations.deinit(self.allocator);
    self.* = undefined;
}

pub fn createFrame(
    self: *Owner,
    manager: *Manager,
    target: ?Target,
    size: ?render.Size,
    overlay_cursor: bool,
) !Frame {
    if (target) |value| {
        try self.ensureOutputGeneration(value.output);
        try manager.ensureOutput(self.allocator, value.output);
    }
    return .{
        .manager = manager,
        .target = target,
        .size = size,
        .overlay_cursor = overlay_cursor,
    };
}

/// Advances one composed output frame and returns its capture generation.
pub fn captureOutput(self: *Owner, output: OutputLayout.Id) ?u64 {
    const state = self.outputGenerationState(output) orelse return null;
    if (state.generation == std.math.maxInt(u64)) {
        state.generation = 1;
        // Callers invalidate every live manager before accepting another
        // damage-baselined request.
    } else {
        state.generation += 1;
    }
    return state.generation;
}

pub fn generationWillWrap(self: *Owner, output: OutputLayout.Id) bool {
    const state = self.outputGenerationState(output) orelse return false;
    return state.generation == std.math.maxInt(u64);
}

pub fn invalidateManager(self: *Owner, manager: *Manager, output: OutputLayout.Id) void {
    _ = self;
    manager.invalidateOutput(output);
}

pub fn removeManagerOutput(self: *Owner, manager: *Manager, output: OutputLayout.Id) void {
    _ = self;
    manager.removeOutput(output);
}

pub fn removeOutput(self: *Owner, output: OutputLayout.Id) void {
    for (self.output_generations.items, 0..) |state, index| {
        if (!std.meta.eql(state.output, output)) continue;
        _ = self.output_generations.swapRemove(index);
        break;
    }
}

fn ensureOutputGeneration(self: *Owner, output: OutputLayout.Id) !void {
    if (self.outputGenerationState(output) != null) return;
    try self.output_generations.append(self.allocator, .{ .output = output });
}

fn outputGeneration(self: *Owner, output: OutputLayout.Id) ?u64 {
    return (self.outputGenerationState(output) orelse return null).generation;
}

fn outputGenerationState(self: *Owner, output: OutputLayout.Id) ?*OutputGeneration {
    for (self.output_generations.items) |*state| {
        if (std.meta.eql(state.output, output)) return state;
    }
    return null;
}

test "one-shot scheduling and manager-local damage baselines" {
    const output: OutputLayout.Id = .{ .index = 1, .generation = 2 };
    var owner: Owner = .init(std.testing.allocator);
    defer owner.deinit();
    var manager: Manager = .{};
    defer manager.deinit(std.testing.allocator);
    var first = try owner.createFrame(&manager, .{ .output = output }, .{ .width = 2, .height = 1 }, false);
    try std.testing.expectEqual(false, first.start(&owner, true).?);
    try std.testing.expect(first.start(&owner, true) == null);
    const generation = owner.captureOutput(output).?;
    try std.testing.expect(first.beginCapture(generation));
    try std.testing.expect(first.ready());
    var second = try owner.createFrame(&manager, .{ .output = output }, .{ .width = 2, .height = 1 }, false);
    try std.testing.expectEqual(true, second.start(&owner, true).?);
    try std.testing.expect(!second.beginCapture(generation) or second.capture_generation == generation);
}

test "output removal invalidates generation and manager baseline" {
    const output: OutputLayout.Id = .{ .index = 3, .generation = 4 };
    var owner: Owner = .init(std.testing.allocator);
    defer owner.deinit();
    var manager: Manager = .{};
    defer manager.deinit(std.testing.allocator);
    var frame = try owner.createFrame(&manager, .{ .output = output }, .{ .width = 1, .height = 1 }, false);
    try std.testing.expectEqual(false, frame.start(&owner, false).?);
    owner.removeManagerOutput(&manager, output);
    owner.removeOutput(output);
    try std.testing.expect(owner.captureOutput(output) == null);
}
