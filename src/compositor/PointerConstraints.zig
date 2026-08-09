//! Protocol-free pointer lock and confinement arbitration.
//!
//! Frontends retain protocol resources and committed region state. This
//! coordinator is the single owner of the cross-frontend invariant that at
//! most one live constraint exists per canonical surface and at most one is
//! active.

const PointerConstraints = @This();

const std = @import("std");
const Region = @import("region.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");

pub const Kind = enum { locked, confined };
pub const Lifetime = enum { persistent, oneshot };

pub const Focus = struct {
    surface: SurfaceRegistry.Id,
    x: f64,
    y: f64,
};

pub const Motion = struct {
    point: Region.Point,
    locked: bool = false,
};

pub const Constraint = struct {
    surface: SurfaceRegistry.Id,
    kind: Kind,
    lifetime: Lifetime,
    context: *anyopaque,
    eligible: *const fn (*anyopaque) bool,
    effective_region: *const fn (*anyopaque) *const Region,
    activated: *const fn (*anyopaque) void,
    deactivated: *const fn (*anyopaque) void,
    active: bool = false,
    defunct: bool = false,
};

allocator: std.mem.Allocator,
constraints: std.ArrayList(*Constraint) = .empty,

pub fn init(allocator: std.mem.Allocator) PointerConstraints {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *PointerConstraints) void {
    std.debug.assert(self.constraints.items.len == 0);
    self.constraints.deinit(self.allocator);
    self.* = undefined;
}

pub fn register(self: *PointerConstraints, constraint: *Constraint) error{ OutOfMemory, AlreadyConstrained }!void {
    for (self.constraints.items) |current| {
        if (!current.defunct and std.meta.eql(current.surface, constraint.surface))
            return error.AlreadyConstrained;
    }
    try self.constraints.append(self.allocator, constraint);
}

pub fn isConstrained(self: *const PointerConstraints, surface: SurfaceRegistry.Id) bool {
    for (self.constraints.items) |constraint| {
        if (!constraint.defunct and std.meta.eql(constraint.surface, surface)) return true;
    }
    return false;
}

/// Unregistration is silent, as required when a protocol object is destroyed.
pub fn unregister(self: *PointerConstraints, constraint: *Constraint) void {
    constraint.active = false;
    for (self.constraints.items, 0..) |current, index| if (current == constraint) {
        _ = self.constraints.orderedRemove(index);
        return;
    };
    unreachable;
}

pub fn surfaceDestroyed(self: *PointerConstraints, constraint: *Constraint) void {
    _ = self;
    deactivate(constraint);
    constraint.defunct = true;
}

pub fn syncFocus(self: *PointerConstraints, focus: ?Focus) void {
    for (self.constraints.items) |constraint| {
        if (constraint.active and !canRemainActive(constraint, focus)) deactivate(constraint);
    }
    if (self.activeConstraint() != null) return;
    for (self.constraints.items) |constraint| {
        if (!canActivate(constraint, focus)) continue;
        constraint.active = true;
        constraint.activated(constraint.context);
        return;
    }
}

pub fn deactivateAll(self: *PointerConstraints) void {
    for (self.constraints.items) |constraint| deactivate(constraint);
}

pub fn deactivateConstraint(self: *PointerConstraints, constraint: *Constraint) void {
    _ = self;
    deactivate(constraint);
}

pub fn constrainMotion(
    self: *PointerConstraints,
    focus: ?Focus,
    position: Region.Point,
    target: Region.Point,
) Motion {
    self.syncFocus(focus);
    const constraint = self.activeConstraint() orelse return .{ .point = target };
    if (constraint.kind == .locked) return .{ .point = position, .locked = true };
    const local = focus orelse return .{ .point = target };
    const start: Region.Point = .{ .x = local.x, .y = local.y };
    const local_target: Region.Point = .{
        .x = local.x + target.x - position.x,
        .y = local.y + target.y - position.y,
    };
    const confined = constraint.effective_region(constraint.context).confine(start, local_target) orelse
        return .{ .point = target };
    return .{ .point = .{
        .x = position.x + confined.x - local.x,
        .y = position.y + confined.y - local.y,
    } };
}

fn activeConstraint(self: *PointerConstraints) ?*Constraint {
    for (self.constraints.items) |constraint| if (constraint.active) return constraint;
    return null;
}

fn canActivate(constraint: *Constraint, focus: ?Focus) bool {
    if (constraint.defunct or !constraint.eligible(constraint.context)) return false;
    const current = focus orelse return false;
    return std.meta.eql(current.surface, constraint.surface) and
        constraint.effective_region(constraint.context).containsPoint(.{ .x = current.x, .y = current.y });
}

fn canRemainActive(constraint: *Constraint, focus: ?Focus) bool {
    if (constraint.defunct or !constraint.eligible(constraint.context)) return false;
    const current = focus orelse return false;
    if (!std.meta.eql(current.surface, constraint.surface)) return false;
    return constraint.kind == .locked or
        constraint.effective_region(constraint.context).containsPoint(.{ .x = current.x, .y = current.y });
}

fn deactivate(constraint: *Constraint) void {
    if (!constraint.active) return;
    constraint.active = false;
    if (constraint.lifetime == .oneshot) constraint.defunct = true;
    constraint.deactivated(constraint.context);
}

const TestConstraint = struct {
    region: Region,
    eligible: bool = true,
    activations: usize = 0,
    deactivations: usize = 0,
    constraint: Constraint,

    fn init(surface: SurfaceRegistry.Id, kind: Kind, lifetime: Lifetime) TestConstraint {
        return .{
            .region = Region.init(),
            .constraint = .{
                .surface = surface,
                .kind = kind,
                .lifetime = lifetime,
                .context = undefined,
                .eligible = isEligible,
                .effective_region = effectiveRegion,
                .activated = activated,
                .deactivated = deactivated,
            },
        };
    }

    fn bind(self: *TestConstraint) void {
        self.constraint.context = self;
        self.region.setRectangle(0, 0, 100, 100);
    }

    fn isEligible(context: *anyopaque) bool {
        const self: *TestConstraint = @ptrCast(@alignCast(context));
        return self.eligible;
    }

    fn effectiveRegion(context: *anyopaque) *const Region {
        const self: *TestConstraint = @ptrCast(@alignCast(context));
        return &self.region;
    }

    fn activated(context: *anyopaque) void {
        const self: *TestConstraint = @ptrCast(@alignCast(context));
        self.activations += 1;
    }

    fn deactivated(context: *anyopaque) void {
        const self: *TestConstraint = @ptrCast(@alignCast(context));
        self.deactivations += 1;
    }
};

fn testId(index: u32) SurfaceRegistry.Id {
    return .{ .index = index, .generation = 1 };
}

test "duplicate canonical surface and only one active constraint" {
    var coordinator = PointerConstraints.init(std.testing.allocator);
    defer coordinator.deinit();
    var first = TestConstraint.init(testId(1), .locked, .persistent);
    defer first.region.deinit();
    first.bind();
    var duplicate = TestConstraint.init(testId(1), .confined, .persistent);
    defer duplicate.region.deinit();
    duplicate.bind();
    var second = TestConstraint.init(testId(2), .locked, .persistent);
    defer second.region.deinit();
    second.bind();
    try coordinator.register(&first.constraint);
    defer coordinator.unregister(&first.constraint);
    try std.testing.expectError(error.AlreadyConstrained, coordinator.register(&duplicate.constraint));
    try coordinator.register(&second.constraint);
    defer coordinator.unregister(&second.constraint);
    coordinator.syncFocus(.{ .surface = testId(1), .x = 10, .y = 10 });
    try std.testing.expect(first.constraint.active);
    try std.testing.expect(!second.constraint.active);
    coordinator.syncFocus(.{ .surface = testId(2), .x = 10, .y = 10 });
    try std.testing.expect(!first.constraint.active);
    try std.testing.expect(second.constraint.active);
}

test "lock and confine motion" {
    var coordinator = PointerConstraints.init(std.testing.allocator);
    defer coordinator.deinit();
    var lock = TestConstraint.init(testId(1), .locked, .persistent);
    defer lock.region.deinit();
    lock.bind();
    try coordinator.register(&lock.constraint);
    const focus: Focus = .{ .surface = testId(1), .x = 50, .y = 50 };
    const locked = coordinator.constrainMotion(focus, .{ .x = 200, .y = 200 }, .{ .x = 220, .y = 220 });
    try std.testing.expect(locked.locked);
    try std.testing.expectEqual(@as(f64, 200), locked.point.x);
    coordinator.unregister(&lock.constraint);

    var confine = TestConstraint.init(testId(1), .confined, .persistent);
    defer confine.region.deinit();
    confine.bind();
    try coordinator.register(&confine.constraint);
    defer coordinator.unregister(&confine.constraint);
    const confined = coordinator.constrainMotion(focus, .{ .x = 200, .y = 200 }, .{ .x = 300, .y = 200 });
    try std.testing.expect(!confined.locked);
    try std.testing.expect(confined.point.x < 250);
    try std.testing.expect(confined.point.x >= 200);
}

test "persistent reactivates and oneshot becomes defunct" {
    var coordinator = PointerConstraints.init(std.testing.allocator);
    defer coordinator.deinit();
    var persistent = TestConstraint.init(testId(1), .locked, .persistent);
    defer persistent.region.deinit();
    persistent.bind();
    try coordinator.register(&persistent.constraint);
    coordinator.syncFocus(.{ .surface = testId(1), .x = 1, .y = 1 });
    coordinator.syncFocus(null);
    coordinator.syncFocus(.{ .surface = testId(1), .x = 1, .y = 1 });
    try std.testing.expectEqual(@as(usize, 2), persistent.activations);
    try std.testing.expectEqual(@as(usize, 1), persistent.deactivations);

    coordinator.unregister(&persistent.constraint);
    var oneshot = TestConstraint.init(testId(2), .locked, .oneshot);
    defer oneshot.region.deinit();
    oneshot.bind();
    try coordinator.register(&oneshot.constraint);
    defer coordinator.unregister(&oneshot.constraint);
    coordinator.syncFocus(.{ .surface = testId(2), .x = 1, .y = 1 });
    coordinator.syncFocus(null);
    coordinator.syncFocus(.{ .surface = testId(2), .x = 1, .y = 1 });
    try std.testing.expect(oneshot.constraint.defunct);
    try std.testing.expectEqual(@as(usize, 1), oneshot.activations);
}
