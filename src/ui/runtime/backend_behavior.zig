//! Repaint and backend presentation behavior for the UI runtime.

const std = @import("std");
const keywork = @import("../../ui.zig");
const lifecycle_reconciliation = @import("lifecycle_reconciliation.zig");

const log = std.log.scoped(.keywork);

pub fn renderScale(self: anytype) f32 {
    return self.backend.scale();
}

pub fn setFrameBackground(self: anytype, color: ?keywork.Color) void {
    self.frame_background = color;
}

pub fn frameBackground(self: anytype) keywork.Color {
    return self.frame_background orelse keywork.Theme.fromColorScheme(self.color_scheme.name()).color_scheme.background;
}

pub fn presentFrame(self: anytype) !void {
    if (self.rendering) {
        self.repaint_pending = true;
        return;
    }

    self.rendering = true;
    defer self.rendering = false;
    // Consume the request that triggered this frame; requests raised
    // during rebuild or paint survive to trigger the next one.
    self.repaint_pending = false;
    errdefer self.repaint_pending = true;

    // Advance animations to this frame's time before building, writing
    // values and damage straight into the retained render nodes: ticks
    // repaint without rebuilding or re-laying-out anything.
    if (self.element_root) |*element_root| {
        _ = keywork.advanceAnimations(element_root, self.clock.now());
    }

    try lifecycle_reconciliation.flushInteractionRefresh(self);
    // Consume pending flags before rebuilding so invalidations raised by
    // callbacks during the rebuild are observed on the next pass instead
    // of being cleared and dropped.
    const max_rebuild_passes = 8;
    var pass: usize = 0;
    while (self.rebuild_pending or self.state_rebuild_pending) : (pass += 1) {
        if (pass >= max_rebuild_passes) return error.RebuildDidNotStabilize;
        const full_rebuild = self.rebuild_pending;
        self.rebuild_pending = false;
        self.state_rebuild_pending = false;
        if (full_rebuild) {
            try lifecycle_reconciliation.rebuild(self);
        } else {
            try lifecycle_reconciliation.rebuildDirtyState(self);
        }
        // Layout may discover that a virtualized list's built window
        // drifted; another dirty-state pass rebuilds it.
        if (self.element_root) |*element_root| {
            if (keywork.anyListRangeStale(element_root)) self.state_rebuild_pending = true;
        }
    }

    // Query demand after the rebuild loop so animations created by this
    // frame's build register even though they were not advanced yet.
    self.animations_active = if (self.element_root) |*element_root|
        keywork.anyAnimationsActive(element_root)
    else
        false;
    if (self.animations_active) self.repaint_pending = true;

    const root = self.root orelse return error.NotBuilt;
    // Content-sized hosts observe the authoritative retained root here,
    // after rebuild/layout but before damage collection or paint. A native
    // resize request defers this frame so no stale clipped buffer is shown.
    if (!try self.reconsiderRootSize()) return;
    const frame_size = self.frameSize();
    const render_scale = self.renderScale();
    const full_frame: keywork.Rect = .{ .x = 0, .y = 0, .width = frame_size.width, .height = frame_size.height };
    // Damage accumulated by relayout since the last collection. Painted
    // nodes damage whenever they re-lay out, so no damage at an unchanged
    // size and scale means the frame is pixel-identical to the last
    // present: skip it, so app-wide state invalidations don't repaint
    // clean windows. A size or scale change (or first frame) still
    // repaints the full frame conservatively.
    const collected = keywork.collectDamage(root);
    if (collected == null and !self.animations_active) {
        // Never skip while animating: the present's frame callback is
        // what sustains the animation loop, so skipping would stall it.
        if (self.presented_size) |presented| {
            if (std.meta.eql(presented, frame_size) and self.presented_scale == render_scale) return;
        }
    }
    const damage = if (collected) |dirty| dirty.intersect(full_frame) else full_frame;
    self.display_list.clearRetainingCapacity(self.allocator);
    const raster_cache = self.rasterCache();
    raster_cache.beginFrame();
    defer raster_cache.endFrame(self.allocator);
    const background = self.frameBackground();
    if (background.a > 0) try self.display_list.fillRect(self.allocator, full_frame, background);
    const partial_paint_bounds = try self.backend.partialPaintBounds(frame_size, render_scale, &.{damage});
    if (partial_paint_bounds) |paint_bounds| {
        try keywork.paintDamagedScaled(self.allocator, root, &self.display_list, raster_cache, render_scale, paint_bounds);
    } else {
        try keywork.paintScaled(self.allocator, root, &self.display_list, raster_cache, render_scale);
    }
    self.frame_pending = try self.backend.present(.{
        .size = frame_size,
        .scale = render_scale,
        .damage = &.{damage},
        .display_list = self.display_list.commands.items,
        .partial_display_list = partial_paint_bounds != null,
    });
    self.presented_size = frame_size;
    self.presented_scale = render_scale;
}

pub fn frameDone(self: anytype) !void {
    self.frame_pending = false;
    if (self.repaint_pending) {
        if (self.defer_repaint_until_flush) return;
        if (self.repaint_scheduler) |scheduler| {
            try scheduler(self.repaint_scheduler_context.?);
        } else {
            try presentFrame(self);
        }
    }
}

pub fn configure(self: anytype, size: keywork.Size) !void {
    if (size.width > 0 and size.height > 0) {
        self.configured_size = size;
        if (!self.content_axes.any()) {
            self.constraints = .{ .max_width = size.width, .max_height = size.height };
        } else {
            if (!self.content_axes.width) {
                self.constraints.min_width = size.width;
                self.constraints.max_width = size.width;
            }
            if (!self.content_axes.height) {
                self.constraints.min_height = size.height;
                self.constraints.max_height = size.height;
            }
        }
    }
    try self.invalidate();
}

pub fn requestRepaint(self: anytype) !void {
    self.repaint_pending = true;
    if (self.defer_repaint_until_flush) {
        if (self.repaint_scheduler) |scheduler| try scheduler(self.repaint_scheduler_context.?);
        return;
    }
    if (self.repaint_scheduler) |scheduler| {
        try scheduler(self.repaint_scheduler_context.?);
        return;
    }
    if (!self.frame_pending and !self.rendering) try presentFrame(self);
}

pub fn setDeferredRepaint(self: anytype, enabled: bool) void {
    self.defer_repaint_until_flush = enabled;
}

pub fn flushPendingRepaint(self: anytype) !void {
    if (!self.repaint_pending or self.frame_pending or self.rendering) return;
    try presentFrame(self);
}

pub fn setRepaintScheduler(self: anytype, context: *anyopaque, scheduler: @TypeOf(self.*).RepaintScheduler) void {
    self.repaint_scheduler_context = context;
    self.repaint_scheduler = scheduler;
}

pub fn invalidate(self: anytype) !void {
    self.rebuild_pending = true;
    try requestRepaint(self);
}

pub fn invalidateState(self: anytype) !void {
    self.state_rebuild_pending = true;
    try requestRepaint(self);
}

pub fn setColorScheme(self: anytype, color_scheme: @TypeOf(self.color_scheme)) !void {
    if (self.color_scheme == color_scheme) return;
    self.color_scheme = color_scheme;
    try self.invalidate();
}

pub fn waylandConfigure(comptime Runtime: type, ctx: *anyopaque, size: keywork.Size) void {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    configure(self, size) catch |err| {
        log.err("configure invalidate failed: {}", .{err});
    };
}

pub fn waylandFrameDone(comptime Runtime: type, ctx: *anyopaque) void {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    frameDone(self) catch |err| {
        log.err("frame repaint failed: {}", .{err});
    };
}

pub fn colorSchemeChanged(comptime Runtime: type, ctx: *anyopaque, color_scheme: anytype) void {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    setColorScheme(self, color_scheme) catch |err| {
        log.err("desktop settings invalidate failed: {}", .{err});
    };
}
