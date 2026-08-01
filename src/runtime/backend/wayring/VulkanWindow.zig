//! Runtime bridge between the Vulkan DMA-BUF renderer and Wayring presenter.
//!
//! Target generations remain alive until every old `wl_buffer` is released.
//! This keeps resize independent from compositor pacing without exposing
//! Vulkan ownership to the protocol layer.

const VulkanWindow = @This();

const std = @import("std");
const keywork = @import("keywork-ui");
const wayring = @import("wayring");
const DmaBufPresenter = @import("DmaBufPresenter.zig");
const vulkan_renderer = @import("../wayland/vulkan/renderer.zig");
const VulkanRenderer = vulkan_renderer.Renderer;

const TargetSet = vulkan_renderer.DmaBufTargets;
pub const Candidate = DmaBufPresenter.Candidate;

const Generation = struct {
    id: u64,
    width: u32,
    height: u32,
    targets: TargetSet,
};

allocator: std.mem.Allocator,
renderer: VulkanRenderer,
presenter: DmaBufPresenter,
device_candidates: []DmaBufPresenter.Candidate,
generations: std.ArrayList(Generation) = .empty,

pub fn init(
    allocator: std.mem.Allocator,
    connection: *wayring.Connection,
    surface: wayring.ObjectHandle,
    factory: wayring.ObjectHandle,
    compositor_candidates: []const Candidate,
) !VulkanWindow {
    var renderer = try VulkanRenderer.initDmaBuf(allocator);
    errdefer renderer.deinit();

    const modifiers = try renderer.dmaBufModifiers(allocator);
    defer allocator.free(modifiers);
    if (modifiers.len == 0) return error.NoDmaBufModifiers;
    const candidates = try allocator.alloc(DmaBufPresenter.Candidate, modifiers.len);
    errdefer allocator.free(candidates);
    for (modifiers, candidates) |modifier, *candidate| {
        candidate.* = .{ .format = .argb8888, .modifier = modifier };
    }

    var presenter = try DmaBufPresenter.init(allocator, connection, surface, factory);
    errdefer presenter.deinit();
    for (compositor_candidates) |candidate| {
        try presenter.addCandidate(@intFromEnum(candidate.format), candidate.modifier);
    }
    return .{
        .allocator = allocator,
        .renderer = renderer,
        .presenter = presenter,
        .device_candidates = candidates,
    };
}

/// Call after the Wayland connection is no longer able to retain these
/// buffers. Normal live teardown should first use `retireAll` and drain
/// releases.
pub fn deinit(self: *VulkanWindow) void {
    for (self.generations.items) |*generation| generation.targets.deinit();
    self.generations.deinit(self.allocator);
    self.allocator.free(self.device_candidates);
    self.presenter.deinit();
    self.renderer.deinit();
    self.* = undefined;
}

pub fn handleMessage(self: *VulkanWindow, message: *const wayring.Message) !void {
    try self.presenter.handleMessage(message);
    self.reapRetiredGenerations();
}

pub fn configure(self: *VulkanWindow, width: u32, height: u32) !void {
    if (width == 0 or height == 0) return error.EmptyTarget;
    if (self.currentGeneration()) |current| {
        if (current.width == width and current.height == height) return;
    }
    const candidate = DmaBufPresenter.chooseCandidate(
        self.presenter.candidates(),
        self.device_candidates,
    ) orelse return error.NoSharedDmaBufModifier;

    try self.generations.ensureUnusedCapacity(self.allocator, 1);
    var targets = try self.renderer.createDmaBufTargets(width, height, candidate.modifier);
    errdefer targets.deinit();

    var planes: [TargetSet.image_count]DmaBufPresenter.ExportedPlane = undefined;
    for (&planes, 0..) |*exported, index| {
        const plane = targets.plane(index);
        exported.* = .{
            .target_index = plane.target_index,
            .fd = plane.fd,
            .width = plane.width,
            .height = plane.height,
            .offset = plane.offset,
            .stride = plane.stride,
            .format = candidate.format,
            .modifier = plane.modifier,
        };
    }
    const generation = try self.presenter.createGeneration(&planes);
    self.generations.appendAssumeCapacity(.{
        .id = generation,
        .width = width,
        .height = height,
        .targets = targets,
    });
    self.reapRetiredGenerations();
}

/// Returns false when every current-generation target is still held by the
/// compositor. That is normal backpressure rather than a rendering failure.
pub fn present(
    self: *VulkanWindow,
    display_list: []const keywork.PaintCommand,
    scale: f32,
) !bool {
    const lease = (try self.presenter.acquire()) orelse return false;
    const generation = self.findGeneration(lease.generation) orelse {
        self.presenter.cancel(lease) catch {};
        return error.MissingTargetGeneration;
    };
    self.renderer.renderDmaBuf(
        &generation.targets,
        lease.target_index,
        display_list,
        scale,
    ) catch |err| {
        self.presenter.cancel(lease) catch {};
        return err;
    };
    try self.presenter.present(lease);
    return true;
}

pub fn retireAll(self: *VulkanWindow) !bool {
    const retired = try self.presenter.retireAll();
    self.reapRetiredGenerations();
    if (!retired) return false;
    for (self.generations.items) |*generation| generation.targets.deinit();
    self.generations.clearRetainingCapacity();
    return true;
}

pub fn measureText(
    self: *VulkanWindow,
    scale: f32,
    value: []const u8,
    style: keywork.ResolvedTextStyle,
) !keywork.Size {
    return self.renderer.measureText(scale, value, style);
}

pub fn textMetrics(self: *VulkanWindow, scale: f32, font_size: f32) !keywork.TextMetrics {
    return self.renderer.textMetrics(scale, font_size);
}

fn currentGeneration(self: *VulkanWindow) ?*Generation {
    if (self.generations.items.len == 0) return null;
    const generation = &self.generations.items[self.generations.items.len - 1];
    std.debug.assert(generation.id == self.presenter.currentGeneration());
    return generation;
}

fn findGeneration(self: *VulkanWindow, id: u64) ?*Generation {
    for (self.generations.items) |*generation| {
        if (generation.id == id) return generation;
    }
    return null;
}

fn reapRetiredGenerations(self: *VulkanWindow) void {
    const current = self.presenter.currentGeneration();
    var index: usize = 0;
    while (index < self.generations.items.len) {
        const generation = &self.generations.items[index];
        if (generation.id == current or self.presenter.hasGeneration(generation.id)) {
            index += 1;
            continue;
        }
        generation.targets.deinit();
        _ = self.generations.orderedRemove(index);
    }
}

test {
    std.testing.refAllDecls(VulkanWindow);
}
