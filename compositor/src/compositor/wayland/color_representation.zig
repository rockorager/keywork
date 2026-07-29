//! Buffer color-model and quantization metadata.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
global: *wl.Global,
surface_count: usize,

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, wp.ColorRepresentationManagerV1, 1, *Self, self, bind),
        .surface_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.surface_count == 0);
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.ColorRepresentationManagerV1.create(client, version, id) catch return client.postNoMemory();
    resource.setHandler(*Self, managerRequest, null, self);
    resource.sendSupportedAlphaMode(.premultiplied_electrical);
    resource.sendSupportedCoefficientsAndRanges(.identity, .full);
    inline for (.{ .bt601, .bt709, .bt2020 }) |coefficients| {
        resource.sendSupportedCoefficientsAndRanges(coefficients, .full);
        resource.sendSupportedCoefficientsAndRanges(coefficients, .limited);
    }
    resource.sendDone();
}

fn managerRequest(resource: *wp.ColorRepresentationManagerV1, request: wp.ColorRepresentationManagerV1.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_surface => |get| Representation.create(self, resource, get.id, Surface.fromResource(get.surface)),
    }
}

const Representation = struct {
    manager: *Self,
    surface: ?*Surface,
    resource: *wp.ColorRepresentationSurfaceV1,
    state: Surface.ColorRepresentationState,

    fn create(manager: *Self, parent: *wp.ColorRepresentationManagerV1, id: u32, surface: *Surface) void {
        const resource = wp.ColorRepresentationSurfaceV1.create(parent.getClient(), parent.getVersion(), id) catch return parent.postNoMemory();
        const self = manager.allocator.create(Representation) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{
            .manager = manager,
            .surface = surface,
            .resource = resource,
            .state = surface.pendingColorRepresentation(),
        };
        surface.setColorRepresentationHandler(.{
            .context = self,
            .surface_destroyed = surfaceDestroyed,
            .validate_commit = validateCommit,
        }) catch {
            manager.allocator.destroy(self);
            resource.destroy();
            parent.postError(.surface_exists, "wl_surface already has a color representation object");
            return;
        };
        manager.surface_count += 1;
        resource.setHandler(*Representation, request, destroy, self);
    }

    fn request(resource: *wp.ColorRepresentationSurfaceV1, req: wp.ColorRepresentationSurfaceV1.Request, self: *Representation) void {
        switch (req) {
            .destroy => resource.destroy(),
            .set_alpha_mode => |set| {
                const surface = self.activeSurface(resource) orelse return;
                if (!supportedAlpha(set.alpha_mode)) return resource.postError(.alpha_mode, "unsupported alpha mode");
                self.state.alpha_mode = set.alpha_mode;
                surface.setPendingColorRepresentation(self.state);
            },
            .set_coefficients_and_range => |set| {
                const surface = self.activeSurface(resource) orelse return;
                if (!supportedCoefficients(set.coefficients, set.range)) return resource.postError(.coefficients, "unsupported coefficients and range");
                self.state.coefficients = set.coefficients;
                self.state.range = set.range;
                surface.setPendingColorRepresentation(self.state);
            },
            .set_chroma_location => |set| {
                const surface = self.activeSurface(resource) orelse return;
                if (!validChroma(set.chroma_location)) return resource.postError(.chroma_location, "invalid chroma location");
                self.state.chroma_location = set.chroma_location;
                surface.setPendingColorRepresentation(self.state);
            },
        }
    }

    fn activeSurface(self: *Representation, resource: *wp.ColorRepresentationSurfaceV1) ?*Surface {
        return self.surface orelse {
            resource.postError(.inert, "wl_surface has been destroyed");
            return null;
        };
    }

    fn destroy(_: *wp.ColorRepresentationSurfaceV1, self: *Representation) void {
        if (self.surface) |surface| surface.clearColorRepresentationHandler(self);
        self.manager.surface_count -= 1;
        self.manager.allocator.destroy(self);
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Representation = @ptrCast(@alignCast(context));
        self.surface = null;
    }

    fn validateCommit(
        context: *anyopaque,
        state: Surface.ColorRepresentationState,
        format: ?render.DmabufFormat,
    ) bool {
        const self: *Representation = @ptrCast(@alignCast(context));
        if (!commitCompatible(state, format)) {
            self.resource.postError(
                .pixel_format,
                "color representation is incompatible with the buffer format",
            );
            return false;
        }
        return true;
    }
};

fn supportedAlpha(alpha_mode: wp.ColorRepresentationSurfaceV1.AlphaMode) bool {
    return alpha_mode == .premultiplied_electrical;
}

fn supportedCoefficients(coefficients: wp.ColorRepresentationSurfaceV1.Coefficients, range: wp.ColorRepresentationSurfaceV1.Range) bool {
    return switch (coefficients) {
        .identity => range == .full,
        .bt601, .bt709, .bt2020 => range == .full or range == .limited,
        else => false,
    };
}

fn validChroma(chroma: wp.ColorRepresentationSurfaceV1.ChromaLocation) bool {
    return switch (chroma) {
        .type_0, .type_1, .type_2, .type_3, .type_4, .type_5 => true,
        _ => false,
    };
}

fn commitCompatible(
    state: Surface.ColorRepresentationState,
    format: ?render.DmabufFormat,
) bool {
    const buffer_format = format orelse return true;
    if ((state.coefficients == null) != (state.range == null)) return false;
    if (buffer_format.isPackedRgb()) {
        return state.chroma_location == null and
            (state.coefficients == null or
                (state.coefficients == .identity and state.range == .full));
    }
    return state.coefficients == null or
        (state.coefficients != .identity and
            supportedCoefficients(state.coefficients.?, state.range.?));
}

test "RGB and YCbCr capabilities match buffer formats" {
    try std.testing.expect(supportedAlpha(.premultiplied_electrical));
    try std.testing.expect(!supportedAlpha(.premultiplied_optical));
    try std.testing.expect(!supportedAlpha(.straight));
    try std.testing.expect(supportedCoefficients(.identity, .full));
    try std.testing.expect(supportedCoefficients(.bt709, .full));
    try std.testing.expect(supportedCoefficients(.bt709, .limited));
    try std.testing.expect(supportedCoefficients(.bt601, .limited));
    try std.testing.expect(supportedCoefficients(.bt2020, .limited));
    try std.testing.expect(!supportedCoefficients(.bt2020_cl, .limited));
    try std.testing.expect(!supportedCoefficients(.identity, .limited));
    inline for (.{ .type_0, .type_1, .type_2, .type_3, .type_4, .type_5 }) |chroma| {
        try std.testing.expect(validChroma(chroma));
    }
    var state: Surface.ColorRepresentationState = .{ .chroma_location = .type_3 };
    try std.testing.expect(commitCompatible(state, null));
    try std.testing.expect(!commitCompatible(state, .argb8888));
    try std.testing.expect(commitCompatible(state, .nv12));
    state.chroma_location = null;
    try std.testing.expect(commitCompatible(state, .argb8888));
    state.coefficients = .bt709;
    state.range = .limited;
    try std.testing.expect(!commitCompatible(state, .argb8888));
    try std.testing.expect(commitCompatible(state, .p010));
    state.coefficients = .identity;
    state.range = .full;
    try std.testing.expect(commitCompatible(state, .argb8888));
    try std.testing.expect(!commitCompatible(state, .nv12));

    const default_video = (Surface.ColorRepresentationState{}).toRender(.nv12);
    try std.testing.expectEqual(render.ColorCoefficients.bt709, default_video.coefficients);
    try std.testing.expectEqual(render.ColorRange.limited, default_video.range);
    try std.testing.expectEqual(render.ChromaLocation.type_0, default_video.chroma_location.?);

    const explicit_video: Surface.ColorRepresentationState = .{
        .coefficients = .bt2020,
        .range = .full,
        .chroma_location = .type_3,
    };
    try std.testing.expectEqual(
        render.ColorRepresentation{
            .coefficients = .bt2020,
            .range = .full,
            .chroma_location = .type_3,
        },
        explicit_video.toRender(.p010),
    );
}
