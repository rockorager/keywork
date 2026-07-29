//! Preferred fractional scale protocol for client surfaces.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");
const OutputLayout = @import("output_layout.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
global: *wl.Global,
outputs: *OutputLayout,
default_output_id: OutputLayout.Id,
by_surface: std.AutoHashMapUnmanaged(Surface.Id, *FractionalScale),
resource_count: usize,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    outputs: *OutputLayout,
    default_output_id: OutputLayout.Id,
) !void {
    if (outputs.get(default_output_id) == null) return error.InvalidOutput;
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            wp.FractionalScaleManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
        .outputs = outputs,
        .default_output_id = default_output_id,
        .by_surface = .empty,
        .resource_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.resource_count == 0);
    std.debug.assert(self.by_surface.count() == 0);
    self.global.destroy();
    self.by_surface.deinit(self.allocator);
    self.* = undefined;
}

pub fn setDefaultOutput(self: *Self, output_id: OutputLayout.Id) void {
    std.debug.assert(self.outputs.get(output_id) != null);
    self.default_output_id = output_id;
    self.refresh();
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.FractionalScaleManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *wp.FractionalScaleManagerV1,
    request: wp.FractionalScaleManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_fractional_scale => |get| self.createFractionalScale(
            resource,
            get.id,
            Surface.fromResource(get.surface),
        ),
    }
}

pub fn refresh(self: *Self) void {
    var fractional_scales = self.by_surface.iterator();
    while (fractional_scales.next()) |entry| {
        const fractional_scale = entry.value_ptr.*;
        // Hidden workspace surfaces are temporarily on no output. Preserve
        // their last scale until they become visible again rather than making
        // clients resize for the default output while suspended.
        const surface = fractional_scale.surface orelse continue;
        const preferred_scale = self.preferredScale(entry.key_ptr.*) orelse
            surface.rolePreferredScale() orelse continue;
        fractional_scale.update(preferred_scale);
    }
}

fn preferredScale(self: *Self, surface_id: Surface.Id) ?render.Scale {
    var preferred_scale: ?render.Scale = null;
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| {
        if (!entry.output.containsSurface(surface_id)) continue;
        const output_scale = entry.output.preferredScale();
        if (preferred_scale == null or
            output_scale.numerator > preferred_scale.?.numerator)
        {
            preferred_scale = output_scale;
        }
    }
    return preferred_scale;
}

fn createFractionalScale(
    self: *Self,
    manager: *wp.FractionalScaleManagerV1,
    id: u32,
    surface: *Surface,
) void {
    const surface_id = surface.handle();
    if (self.by_surface.contains(surface_id)) {
        manager.postError(
            .fractional_scale_exists,
            "wl_surface already has a fractional scale object",
        );
        return;
    }
    const resource = wp.FractionalScaleV1.create(
        manager.getClient(),
        manager.getVersion(),
        id,
    ) catch {
        manager.postNoMemory();
        return;
    };
    const fractional_scale = self.allocator.create(FractionalScale) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    const preferred_scale = self.preferredScale(surface_id) orelse
        surface.rolePreferredScale() orelse
        if (self.outputs.get(self.default_output_id)) |output|
            output.preferredScale()
        else
            render.Scale{};
    fractional_scale.* = .{
        .manager = self,
        .surface = surface,
        .surface_id = surface_id,
        .resource = resource,
        .preferred_scale = preferred_scale,
        .listener = undefined,
    };
    fractional_scale.listener = .{
        .context = fractional_scale,
        .applied = handleSurfaceApplied,
        .surface_destroyed = handleSurfaceDestroyed,
    };
    self.by_surface.put(self.allocator, surface_id, fractional_scale) catch {
        self.allocator.destroy(fractional_scale);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    surface.addCommitListener(&fractional_scale.listener) catch {
        _ = self.by_surface.remove(surface_id);
        self.allocator.destroy(fractional_scale);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    self.resource_count += 1;
    resource.setHandler(*FractionalScale, handleResourceRequest, handleResourceDestroy, fractional_scale);
    resource.sendPreferredScale(preferred_scale.numerator);
}

const FractionalScale = struct {
    manager: *Self,
    surface: ?*Surface,
    surface_id: Surface.Id,
    resource: *wp.FractionalScaleV1,
    preferred_scale: render.Scale,
    listener: Surface.CommitListener,

    fn update(self: *FractionalScale, preferred_scale: render.Scale) void {
        if (preferred_scale.numerator == self.preferred_scale.numerator) return;
        self.preferred_scale = preferred_scale;
        self.resource.sendPreferredScale(preferred_scale.numerator);
    }
};

fn handleResourceRequest(
    resource: *wp.FractionalScaleV1,
    request: wp.FractionalScaleV1.Request,
    _: *FractionalScale,
) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn handleResourceDestroy(_: *wp.FractionalScaleV1, self: *FractionalScale) void {
    if (self.surface) |surface| {
        surface.removeCommitListener(&self.listener);
        _ = self.manager.by_surface.remove(self.surface_id);
    }
    self.manager.resource_count -= 1;
    self.manager.allocator.destroy(self);
}

fn handleSurfaceApplied(context: *anyopaque) void {
    const self: *FractionalScale = @ptrCast(@alignCast(context));
    const surface = self.surface orelse return;
    const preferred_scale = self.manager.preferredScale(self.surface_id) orelse
        surface.rolePreferredScale() orelse return;
    self.update(preferred_scale);
}

fn handleSurfaceDestroyed(context: *anyopaque) void {
    const self: *FractionalScale = @ptrCast(@alignCast(context));
    const surface = self.surface orelse unreachable;
    surface.removeCommitListener(&self.listener);
    _ = self.manager.by_surface.remove(self.surface_id);
    self.surface = null;
}

test "hidden surface has no replacement preferred scale" {
    const display = try wl.Server.create();
    defer display.destroy();

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);

    var outputs: OutputLayout = undefined;
    outputs.init(std.testing.allocator, display, &surfaces);
    defer outputs.deinit();

    const output_id = try outputs.add(.{
        .size = .{ .width = 1920, .height = 1080 },
        .physical_size = .{ .width = 3840, .height = 2160 },
        .scale = 2,
        .preferred_scale = .{ .numerator = 150 },
        .name = "HEADLESS-1",
        .description = "Keywork headless output",
        .model = "headless",
    });
    defer std.debug.assert(outputs.remove(output_id));

    var manager: Self = undefined;
    manager.outputs = &outputs;
    try std.testing.expectEqual(
        @as(?render.Scale, null),
        manager.preferredScale(.{ .index = 1, .generation = 1 }),
    );
}
