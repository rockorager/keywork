//! Parametric color-management-v1 descriptions and surface state.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const Surface = @import("surface.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const render = @import("../render/types.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

pub const Description = render.ColorDescription;
pub const sdr: Description = .{};
const sdr_identity: u64 = 1;
const DescriptionRecord = struct {
    description: Description,
    identity: u64,
};

allocator: std.mem.Allocator,
global: *wl.Global,
outputs: *OutputLayout,
output_objects: std.ArrayList(*ManagedOutput),
surface_states: std.ArrayList(*SurfaceState),
feedbacks: std.ArrayList(*Feedback),
references: std.ArrayList(*Reference),
object_count: usize,
next_identity: u64,
description_records: std.ArrayList(DescriptionRecord),
parametric_supported: bool,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    outputs: *OutputLayout,
    parametric_supported: bool,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, wp.ColorManagerV1, 3, *Self, self, bind),
        .outputs = outputs,
        .output_objects = .empty,
        .surface_states = .empty,
        .feedbacks = .empty,
        .references = .empty,
        .object_count = 0,
        .next_identity = sdr_identity + 1,
        .description_records = .empty,
        .parametric_supported = parametric_supported,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.object_count == 0);
    std.debug.assert(self.output_objects.items.len == 0);
    std.debug.assert(self.surface_states.items.len == 0);
    std.debug.assert(self.feedbacks.items.len == 0);
    std.debug.assert(self.references.items.len == 0);
    self.global.destroy();
    self.output_objects.deinit(self.allocator);
    self.surface_states.deinit(self.allocator);
    self.feedbacks.deinit(self.allocator);
    self.references.deinit(self.allocator);
    self.description_records.deinit(self.allocator);
    self.* = undefined;
}

pub fn removeOutput(self: *Self, output: *Output) void {
    for (self.output_objects.items) |managed| {
        if (managed.output == output) managed.output = null;
    }
}

pub fn refreshPreferred(self: *Self) void {
    for (self.feedbacks.items) |feedback| feedback.refreshPreferred();
}

pub fn updateOutputColorDescription(
    self: *Self,
    output: *Output,
    description: Description,
    identity: u64,
) void {
    if (!output.setColorDescription(description, identity)) return;
    for (self.output_objects.items) |managed| {
        if (managed.output == output) managed.resource.sendImageDescriptionChanged();
    }
    output.sendDone();
    self.refreshPreferred();
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.ColorManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, managerRequest, null, self);
    resource.sendSupportedIntent(.perceptual);
    if (!self.parametric_supported) return resource.sendDone();
    resource.sendSupportedFeature(.parametric);
    resource.sendSupportedFeature(.set_primaries);
    resource.sendSupportedFeature(.set_tf_power);
    resource.sendSupportedFeature(.set_luminances);
    resource.sendSupportedFeature(.set_mastering_display_primaries);
    resource.sendSupportedFeature(.extended_target_volume);
    resource.sendSupportedTfNamed(.bt1886);
    resource.sendSupportedTfNamed(.gamma22);
    if (version >= 2) {
        resource.sendSupportedTfNamed(.compound_power_2_4);
    } else {
        resource.sendSupportedTfNamed(.srgb);
    }
    resource.sendSupportedTfNamed(.st2084_pq);
    resource.sendSupportedTfNamed(.hlg);
    resource.sendSupportedPrimariesNamed(.srgb);
    resource.sendSupportedPrimariesNamed(.display_p3);
    resource.sendSupportedPrimariesNamed(.bt2020);
    resource.sendDone();
}

fn managerRequest(resource: *wp.ColorManagerV1, request: wp.ColorManagerV1.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_output => |get| ManagedOutput.create(self, resource, get.id, if (self.outputs.findResource(get.output)) |entry| entry.output else null),
        .get_surface => |get| SurfaceState.create(self, resource, get.id, Surface.fromResource(get.surface)),
        .get_surface_feedback => |get| Feedback.create(self, resource, get.id, Surface.fromResource(get.surface)),
        .get_image_description => |get| Image.createFromReference(self, resource, get.image_description, get.reference),
        .create_parametric_creator => |create| if (self.parametric_supported)
            ParametricCreator.create(self, resource, create.obj)
        else
            resource.postError(.unsupported_feature, "parametric color management is unavailable"),
        .create_icc_creator, .create_windows_scrgb, .create_windows_bt2100 => resource.postError(.unsupported_feature, "optional color-management feature is unsupported"),
    }
}

fn allocateIdentity(self: *Self) u64 {
    const identity = self.next_identity;
    self.next_identity +%= 1;
    std.debug.assert(identity != 0 and self.next_identity != 0);
    return identity;
}

pub fn identityForDescription(self: *Self, description: Description) !u64 {
    if (std.meta.eql(description, sdr)) return sdr_identity;
    for (self.description_records.items) |record| {
        if (std.meta.eql(record.description, description)) return record.identity;
    }
    const identity = self.allocateIdentity();
    try self.description_records.append(self.allocator, .{
        .description = description,
        .identity = identity,
    });
    return identity;
}

test "known color descriptions need no further allocation" {
    var manager: Self = undefined;
    manager.allocator = std.testing.allocator;
    manager.next_identity = sdr_identity + 1;
    manager.description_records = .empty;
    defer manager.description_records.deinit(std.testing.allocator);

    var description = sdr;
    description.primaries = render.display_p3_chromaticities;
    description.named_primaries = .display_p3;
    const identity = try manager.identityForDescription(description);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    manager.allocator = failing.allocator();
    try std.testing.expectEqual(identity, try manager.identityForDescription(description));
    try std.testing.expect(!failing.has_induced_failure);
}

const ParametricCreator = struct {
    manager: *Self,
    description: Description = .{},
    transfer_set: bool = false,
    primaries_set: bool = false,
    luminances_set: bool = false,
    mastering_primaries_set: bool = false,
    mastering_luminance_set: bool = false,
    max_cll_set: bool = false,
    max_fall_set: bool = false,
    requested_luminances: ?struct { min: u32, max: u32, reference: u32 } = null,

    fn create(manager: *Self, parent: *wp.ColorManagerV1, id: u32) void {
        const resource = wp.ImageDescriptionCreatorParamsV1.create(
            parent.getClient(),
            parent.getVersion(),
            id,
        ) catch return parent.postNoMemory();
        const self = manager.allocator.create(ParametricCreator) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager };
        manager.object_count += 1;
        resource.setHandler(*ParametricCreator, request, destroy, self);
    }

    fn request(
        resource: *wp.ImageDescriptionCreatorParamsV1,
        req: wp.ImageDescriptionCreatorParamsV1.Request,
        self: *ParametricCreator,
    ) void {
        switch (req) {
            .create => |create_request| {
                if (!self.transfer_set or !self.primaries_set) {
                    return resource.postError(.incomplete_set, "transfer function and primaries are required");
                }
                var description = self.description;
                setDefaultLuminances(&description, description.transfer_function);
                if (self.requested_luminances) |requested| {
                    description.min_luminance = requested.min;
                    description.max_luminance = if (description.transfer_function == .st2084_pq)
                        @intCast(@as(u64, requested.min) / 10000 + 10000)
                    else
                        requested.max;
                    description.reference_luminance = requested.reference;
                }
                if (description.max_cll != null and description.max_fall != null and
                    description.max_fall.? > description.max_cll.?)
                {
                    return resource.postError(.invalid_luminance, "max_fall exceeds max_cll");
                }
                if (resource.getVersion() == 1 and !validVersionOneContentLightLevels(description)) {
                    return resource.postError(.invalid_luminance, "content light level is outside the mastering range");
                }
                _ = Image.create(
                    self.manager,
                    resource,
                    create_request.image_description,
                    description,
                    false,
                    null,
                );
                resource.destroy();
            },
            .set_tf_named => |set| {
                if (self.transfer_set) return resource.postError(.already_set, "transfer function is already set");
                const transfer = transferFromProtocol(set.tf, resource.getVersion()) orelse
                    return resource.postError(.invalid_tf, "unsupported named transfer function");
                self.description.transfer_function = transfer;
                self.transfer_set = true;
            },
            .set_tf_power => |set| {
                if (self.transfer_set) return resource.postError(.already_set, "transfer function is already set");
                if (set.eexp < 10000 or set.eexp > 100000) {
                    return resource.postError(.invalid_tf, "power exponent must be between 1 and 10");
                }
                self.description.transfer_function = .{ .power = set.eexp };
                self.transfer_set = true;
            },
            .set_primaries_named => |set| {
                if (self.primaries_set) return resource.postError(.already_set, "primaries are already set");
                const named = primariesFromProtocol(set.primaries) orelse
                    return resource.postError(.invalid_primaries_named, "unsupported named primaries");
                self.description.named_primaries = named;
                self.description.primaries = chromaticitiesFor(named);
                self.primaries_set = true;
            },
            .set_primaries => |set| {
                if (self.primaries_set) return resource.postError(.already_set, "primaries are already set");
                self.description.primaries = .{
                    .red_x = set.r_x,
                    .red_y = set.r_y,
                    .green_x = set.g_x,
                    .green_y = set.g_y,
                    .blue_x = set.b_x,
                    .blue_y = set.b_y,
                    .white_x = set.w_x,
                    .white_y = set.w_y,
                };
                self.description.named_primaries = null;
                self.primaries_set = true;
            },
            .set_luminances => |set| {
                if (self.luminances_set) return resource.postError(.already_set, "luminances are already set");
                if (!validLuminanceRange(set.min_lum, set.max_lum) or
                    !validLuminanceRange(set.min_lum, set.reference_lum))
                {
                    return resource.postError(.invalid_luminance, "invalid primary luminance range");
                }
                self.requested_luminances = .{
                    .min = set.min_lum,
                    .max = set.max_lum,
                    .reference = set.reference_lum,
                };
                self.luminances_set = true;
            },
            .set_mastering_display_primaries => |set| {
                if (self.mastering_primaries_set) return resource.postError(.already_set, "mastering primaries are already set");
                self.description.mastering_primaries = .{
                    .red_x = set.r_x,
                    .red_y = set.r_y,
                    .green_x = set.g_x,
                    .green_y = set.g_y,
                    .blue_x = set.b_x,
                    .blue_y = set.b_y,
                    .white_x = set.w_x,
                    .white_y = set.w_y,
                };
                self.mastering_primaries_set = true;
            },
            .set_mastering_luminance => |set| {
                if (self.mastering_luminance_set) return resource.postError(.already_set, "mastering luminance is already set");
                if (!validLuminanceRange(set.min_lum, set.max_lum)) {
                    return resource.postError(.invalid_luminance, "invalid mastering luminance range");
                }
                self.description.mastering_min_luminance = set.min_lum;
                self.description.mastering_max_luminance = set.max_lum;
                self.mastering_luminance_set = true;
            },
            .set_max_cll => |set| {
                if (self.max_cll_set) return resource.postError(.already_set, "max_cll is already set");
                self.description.max_cll = set.max_cll;
                self.max_cll_set = true;
            },
            .set_max_fall => |set| {
                if (self.max_fall_set) return resource.postError(.already_set, "max_fall is already set");
                self.description.max_fall = set.max_fall;
                self.max_fall_set = true;
            },
        }
    }

    fn destroy(_: *wp.ImageDescriptionCreatorParamsV1, self: *ParametricCreator) void {
        self.manager.object_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

fn validVersionOneContentLightLevels(description: Description) bool {
    const min_luminance = description.targetMinLuminance();
    const max_luminance = description.targetMaxLuminance();
    if (description.max_cll) |value| {
        if (!validLuminanceRange(min_luminance, value) or value > max_luminance) return false;
    }
    if (description.max_fall) |value| {
        if (!validLuminanceRange(min_luminance, value) or value > max_luminance) return false;
    }
    return true;
}

fn primariesFromProtocol(value: wp.ColorManagerV1.Primaries) ?render.Primaries {
    return switch (value) {
        .srgb => .srgb,
        .display_p3 => .display_p3,
        .bt2020 => .bt2020,
        else => null,
    };
}

fn chromaticitiesFor(primaries: render.Primaries) render.Chromaticities {
    return switch (primaries) {
        .srgb => render.srgb_chromaticities,
        .display_p3 => render.display_p3_chromaticities,
        .bt2020 => render.bt2020_chromaticities,
    };
}

fn transferFromProtocol(
    value: wp.ColorManagerV1.TransferFunction,
    version: u32,
) ?render.TransferFunction {
    return switch (value) {
        .bt1886 => .bt1886,
        .gamma22 => .gamma22,
        .srgb => if (version == 1) .srgb else null,
        .compound_power_2_4 => if (version >= 2) .srgb else null,
        .st2084_pq => .st2084_pq,
        .hlg => .hlg,
        else => null,
    };
}

fn setDefaultLuminances(description: *Description, transfer: render.TransferFunction) void {
    const defaults: struct { min: u32, max: u32, reference: u32 } = switch (transfer) {
        .bt1886 => .{ .min = 100, .max = 100, .reference = 100 },
        .st2084_pq => .{ .min = 50, .max = 10000, .reference = 203 },
        .hlg => .{ .min = 50, .max = 1000, .reference = 203 },
        .gamma22, .srgb, .power => .{ .min = 2000, .max = 80, .reference = 80 },
    };
    description.min_luminance = defaults.min;
    description.max_luminance = defaults.max;
    description.reference_luminance = defaults.reference;
}

fn validLuminanceRange(min_luminance: u32, max_luminance: u32) bool {
    return @as(u64, max_luminance) * 10000 > min_luminance;
}

const Image = struct {
    manager: *Self,
    ready: bool,
    information: bool,
    identity: u64,
    description: Description,

    fn create(
        manager: *Self,
        parent: anytype,
        id: u32,
        description: ?Description,
        information: bool,
        identity: ?u64,
    ) ?*wp.ImageDescriptionV1 {
        const resource = wp.ImageDescriptionV1.create(parent.getClient(), parent.getVersion(), id) catch {
            parent.postNoMemory();
            return null;
        };
        const resolved_identity = identity orelse if (description) |value|
            manager.identityForDescription(value) catch {
                resource.postNoMemory();
                resource.destroy();
                return null;
            }
        else
            sdr_identity;
        const self = manager.allocator.create(Image) catch {
            resource.postNoMemory();
            resource.destroy();
            return null;
        };
        self.* = .{
            .manager = manager,
            .ready = description != null,
            .information = information,
            .identity = resolved_identity,
            .description = description orelse .{},
        };
        manager.object_count += 1;
        resource.setHandler(*Image, request, destroy, self);
        if (description != null) self.sendReady(resource) else resource.sendFailed(.no_output, "output no longer exists");
        return resource;
    }

    fn createFromReference(manager: *Self, parent: *wp.ColorManagerV1, id: u32, reference: *wp.ImageDescriptionReferenceV1) void {
        const data = reference.getUserData() orelse {
            parent.postError(.unsupported_feature, "unknown image-description reference");
            return;
        };
        const ref = for (manager.references.items) |candidate| {
            if (@intFromPtr(candidate) == @intFromPtr(data)) break candidate;
        } else {
            parent.postError(.unsupported_feature, "unknown image-description reference");
            return;
        };
        _ = create(manager, parent, id, ref.description, ref.information, ref.identity);
    }

    fn sendReady(self: *const Image, resource: *wp.ImageDescriptionV1) void {
        if (resource.getVersion() >= 2) {
            resource.sendReady2(@intCast(self.identity >> 32), @truncate(self.identity));
        } else {
            resource.sendReady(@truncate(self.identity));
        }
    }

    fn request(resource: *wp.ImageDescriptionV1, req: wp.ImageDescriptionV1.Request, self: *Image) void {
        switch (req) {
            .destroy => resource.destroy(),
            .get_information => |get| {
                if (!self.ready) return resource.postError(.not_ready, "image description failed");
                if (!self.information) return resource.postError(.no_information, "information is not permitted");
                const info = wp.ImageDescriptionInfoV1.create(resource.getClient(), resource.getVersion(), get.information) catch return resource.postNoMemory();
                sendInformation(info, self.description);
            },
        }
    }

    fn destroy(_: *wp.ImageDescriptionV1, self: *Image) void {
        self.manager.object_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

fn sendInformation(info: *wp.ImageDescriptionInfoV1, description: Description) void {
    const p = description.primaries.values();
    info.sendPrimaries(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    if (description.named_primaries) |named| info.sendPrimariesNamed(protocolPrimaries(named));
    switch (description.transfer_function) {
        .power => |exponent| info.sendTfPower(exponent),
        .srgb => info.sendTfNamed(if (info.getVersion() >= 2) .compound_power_2_4 else .srgb),
        else => info.sendTfNamed(protocolTransfer(description.transfer_function)),
    }
    info.sendLuminances(
        description.min_luminance,
        description.max_luminance,
        description.reference_luminance,
    );
    const target = description.targetPrimaries().values();
    info.sendTargetPrimaries(
        target[0],
        target[1],
        target[2],
        target[3],
        target[4],
        target[5],
        target[6],
        target[7],
    );
    info.sendTargetLuminance(
        description.targetMinLuminance(),
        description.targetMaxLuminance(),
    );
    if (description.max_cll) |max_cll| info.sendTargetMaxCll(max_cll);
    if (description.max_fall) |max_fall| info.sendTargetMaxFall(max_fall);
    info.destroySendDone();
}

fn protocolPrimaries(primaries: render.Primaries) wp.ColorManagerV1.Primaries {
    return switch (primaries) {
        .srgb => .srgb,
        .display_p3 => .display_p3,
        .bt2020 => .bt2020,
    };
}

fn protocolTransfer(transfer: render.TransferFunction) wp.ColorManagerV1.TransferFunction {
    return switch (transfer) {
        .bt1886 => .bt1886,
        .gamma22 => .gamma22,
        .srgb => unreachable,
        .st2084_pq => .st2084_pq,
        .hlg => .hlg,
        .power => unreachable,
    };
}

pub const Reference = struct {
    manager: *Self,
    information: bool,
    identity: u64,
    description: Description,

    /// Registers a reference created by another protocol module for the fixed SDR record.
    pub fn attach(manager: *Self, resource: *wp.ImageDescriptionReferenceV1, information: bool) !void {
        const self = try manager.allocator.create(Reference);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .information = information,
            .identity = sdr_identity,
            .description = sdr,
        };
        try manager.references.append(manager.allocator, self);
        resource.setHandler(*Reference, request, destroy, self);
    }

    fn request(resource: *wp.ImageDescriptionReferenceV1, req: wp.ImageDescriptionReferenceV1.Request, _: *Reference) void {
        switch (req) {
            .destroy => resource.destroy(),
        }
    }

    fn destroy(_: *wp.ImageDescriptionReferenceV1, self: *Reference) void {
        removePtr(Reference, &self.manager.references, self);
        self.manager.allocator.destroy(self);
    }
};

const ManagedOutput = struct {
    manager: *Self,
    output: ?*Output,
    resource: *wp.ColorManagementOutputV1,

    fn create(manager: *Self, parent: *wp.ColorManagerV1, id: u32, output: ?*Output) void {
        const resource = wp.ColorManagementOutputV1.create(parent.getClient(), parent.getVersion(), id) catch return parent.postNoMemory();
        const self = manager.allocator.create(ManagedOutput) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager, .output = output, .resource = resource };
        manager.output_objects.append(manager.allocator, self) catch {
            manager.allocator.destroy(self);
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        resource.setHandler(*ManagedOutput, request, destroy, self);
    }
    fn request(resource: *wp.ColorManagementOutputV1, req: wp.ColorManagementOutputV1.Request, self: *ManagedOutput) void {
        switch (req) {
            .destroy => resource.destroy(),
            .get_image_description => |get| _ = Image.create(
                self.manager,
                resource,
                get.image_description,
                if (self.output) |output| output.colorDescription() else null,
                self.output != null,
                if (self.output) |output| output.colorIdentity() else null,
            ),
        }
    }
    fn destroy(_: *wp.ColorManagementOutputV1, self: *ManagedOutput) void {
        removePtr(ManagedOutput, &self.manager.output_objects, self);
        self.manager.allocator.destroy(self);
    }
};

const SurfaceState = struct {
    manager: *Self,
    surface: ?*Surface,
    resource: ?*wp.ColorManagementSurfaceV1,
    listener: Surface.CommitListener,

    fn create(manager: *Self, parent: *wp.ColorManagerV1, id: u32, surface: *Surface) void {
        var existing: ?*SurfaceState = null;
        for (manager.surface_states.items) |state| {
            if (state.surface != surface) continue;
            if (state.resource != null) {
                parent.postError(.surface_exists, "wl_surface already has a color-management object");
                return;
            }
            std.debug.assert(existing == null);
            existing = state;
        }
        const resource = wp.ColorManagementSurfaceV1.create(parent.getClient(), parent.getVersion(), id) catch return parent.postNoMemory();
        if (existing) |state| {
            state.resource = resource;
            resource.setHandler(*SurfaceState, request, destroyed, state);
            return;
        }
        const self = manager.allocator.create(SurfaceState) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager, .surface = surface, .resource = resource, .listener = undefined };
        self.listener = .{ .context = self, .applied = applied, .surface_destroyed = surfaceDestroyed };
        surface.addCommitListener(&self.listener) catch {
            manager.allocator.destroy(self);
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        manager.surface_states.append(manager.allocator, self) catch {
            surface.removeCommitListener(&self.listener);
            manager.allocator.destroy(self);
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        resource.setHandler(*SurfaceState, request, destroyed, self);
    }
    fn request(resource: *wp.ColorManagementSurfaceV1, req: wp.ColorManagementSurfaceV1.Request, self: *SurfaceState) void {
        switch (req) {
            .destroy => resource.destroy(),
            .set_image_description => |set| {
                const surface = self.surface orelse return resource.postError(.inert, "wl_surface no longer exists");
                if (set.render_intent != .perceptual) return resource.postError(.render_intent, "unsupported rendering intent");
                const data = set.image_description.getUserData() orelse return resource.postError(.image_description, "invalid image description");
                const image: *Image = @ptrCast(@alignCast(data));
                if (image.manager != self.manager or !image.ready) return resource.postError(.image_description, "image description is not ready");
                surface.setPendingColorDescription(image.description);
            },
            .unset_image_description => {
                const surface = self.surface orelse return resource.postError(.inert, "wl_surface no longer exists");
                surface.setPendingColorDescription(.{});
            },
        }
    }
    fn destroyed(_: *wp.ColorManagementSurfaceV1, self: *SurfaceState) void {
        self.resource = null;
        if (self.surface) |surface| surface.setPendingColorDescription(.{});
        self.maybeDestroy();
    }
    fn applied(_: *anyopaque) void {}
    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *SurfaceState = @ptrCast(@alignCast(context));
        const surface = self.surface orelse unreachable;
        surface.removeCommitListener(&self.listener);
        self.surface = null;
        self.maybeDestroy();
    }
    fn maybeDestroy(self: *SurfaceState) void {
        if (self.resource != null or self.surface != null) return;
        removePtr(SurfaceState, &self.manager.surface_states, self);
        self.manager.allocator.destroy(self);
    }
};

const Feedback = struct {
    manager: *Self,
    surface: ?*Surface,
    resource: *wp.ColorManagementSurfaceFeedbackV1,
    listener: Surface.CommitListener,
    preferred_identity: u64,

    fn preferred(self: *const Feedback) struct { description: Description, identity: u64 } {
        const surface = self.surface orelse return .{ .description = sdr, .identity = sdr_identity };
        var outputs = self.manager.outputs.iterator();
        while (outputs.next()) |entry| {
            if (!entry.output.containsSurface(surface.id)) continue;
            return .{
                .description = entry.output.colorDescription(),
                .identity = entry.output.colorIdentity(),
            };
        }
        return .{ .description = sdr, .identity = sdr_identity };
    }

    fn create(manager: *Self, parent: *wp.ColorManagerV1, id: u32, surface: *Surface) void {
        const resource = wp.ColorManagementSurfaceFeedbackV1.create(parent.getClient(), parent.getVersion(), id) catch return parent.postNoMemory();
        const self = manager.allocator.create(Feedback) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{
            .manager = manager,
            .surface = surface,
            .resource = resource,
            .listener = undefined,
            .preferred_identity = sdr_identity,
        };
        self.preferred_identity = self.preferred().identity;
        self.listener = .{ .context = self, .applied = applied, .surface_destroyed = surfaceDestroyed };
        surface.addCommitListener(&self.listener) catch {
            manager.allocator.destroy(self);
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        manager.feedbacks.append(manager.allocator, self) catch {
            surface.removeCommitListener(&self.listener);
            manager.allocator.destroy(self);
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        resource.setHandler(*Feedback, request, destroy, self);
    }

    fn refreshPreferred(self: *Feedback) void {
        if (self.surface == null) return;
        const identity = self.preferred().identity;
        if (identity == self.preferred_identity) return;
        self.preferred_identity = identity;
        if (self.resource.getVersion() >= 2) {
            self.resource.sendPreferredChanged2(
                @intCast(identity >> 32),
                @truncate(identity),
            );
        } else {
            self.resource.sendPreferredChanged(@truncate(identity));
        }
    }

    fn request(resource: *wp.ColorManagementSurfaceFeedbackV1, req: wp.ColorManagementSurfaceFeedbackV1.Request, self: *Feedback) void {
        switch (req) {
            .destroy => resource.destroy(),
            .get_preferred => |get| {
                if (self.surface == null) return resource.postError(.inert, "wl_surface no longer exists");
                const value = self.preferred();
                _ = Image.create(self.manager, resource, get.image_description, value.description, true, value.identity);
            },
            .get_preferred_parametric => |get| {
                if (self.surface == null) return resource.postError(.inert, "wl_surface no longer exists");
                if (!self.manager.parametric_supported) {
                    return resource.postError(.unsupported_feature, "parametric color management is unavailable");
                }
                const value = self.preferred();
                _ = Image.create(self.manager, resource, get.image_description, value.description, true, value.identity);
            },
        }
    }
    fn applied(_: *anyopaque) void {}
    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Feedback = @ptrCast(@alignCast(context));
        const surface = self.surface orelse unreachable;
        surface.removeCommitListener(&self.listener);
        self.surface = null;
    }
    fn destroy(_: *wp.ColorManagementSurfaceFeedbackV1, self: *Feedback) void {
        if (self.surface) |surface| surface.removeCommitListener(&self.listener);
        removePtr(Feedback, &self.manager.feedbacks, self);
        self.manager.allocator.destroy(self);
    }
};

fn removePtr(comptime T: type, list: *std.ArrayList(*T), ptr: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == ptr) {
        _ = list.orderedRemove(index);
        return;
    };
    unreachable;
}

test "default SDR metadata is internally consistent" {
    try std.testing.expectEqual(@as(u32, 2000), sdr.min_luminance);
    try std.testing.expectEqual(sdr.max_luminance, sdr.reference_luminance);
    try std.testing.expectEqual(@as(i32, 640000), sdr.primaries.red_x);
    try std.testing.expectEqual(render.Primaries.srgb, sdr.named_primaries.?);
    try std.testing.expectEqual(render.TransferFunction.gamma22, sdr.transfer_function);
}

test "parametric named values and luminance defaults are validated" {
    try std.testing.expectEqual(render.Primaries.display_p3, primariesFromProtocol(.display_p3).?);
    try std.testing.expectEqual(render.TransferFunction.st2084_pq, transferFromProtocol(.st2084_pq, 3).?);
    try std.testing.expect(transferFromProtocol(.srgb, 3) == null);
    try std.testing.expectEqual(render.TransferFunction.srgb, transferFromProtocol(.srgb, 1).?);
    try std.testing.expect(validLuminanceRange(2000, 80));
    try std.testing.expect(!validLuminanceRange(800000, 80));

    var description: Description = .{};
    setDefaultLuminances(&description, .st2084_pq);
    try std.testing.expectEqual(@as(u32, 50), description.min_luminance);
    try std.testing.expectEqual(@as(u32, 10000), description.max_luminance);
    try std.testing.expectEqual(@as(u32, 203), description.reference_luminance);
}

test "output objects become inert independently of protocol resources" {
    const output: *Output = @ptrFromInt(@alignOf(Output));
    var managed: ManagedOutput = .{
        .manager = undefined,
        .output = output,
        .resource = undefined,
    };
    var manager: Self = undefined;
    manager.output_objects = .empty;
    defer manager.output_objects.deinit(std.testing.allocator);
    try manager.output_objects.append(std.testing.allocator, &managed);

    manager.removeOutput(output);
    try std.testing.expect(managed.output == null);
    try std.testing.expectEqual(@as(usize, 1), manager.output_objects.items.len);
}

test "surface color state survives extension recreation and becomes inert" {
    const display = try wl.Server.create();
    defer display.destroy();

    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &sockets),
    );
    defer _ = std.c.close(sockets[1]);
    const client = wl.Client.create(display, sockets[0]) orelse return error.OutOfMemory;

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var outputs: OutputLayout = undefined;
    outputs.init(std.testing.allocator, display, &surfaces);
    defer outputs.deinit();
    var manager: Self = undefined;
    try manager.init(std.testing.allocator, display, &outputs, true);
    defer manager.deinit();
    defer client.destroy();

    const p3: Description = .{
        .primaries = render.display_p3_chromaticities,
        .named_primaries = .display_p3,
    };
    const p3_identity = try manager.identityForDescription(p3);
    try std.testing.expectEqual(p3_identity, try manager.identityForDescription(p3));
    const bt2020: Description = .{
        .primaries = render.bt2020_chromaticities,
        .named_primaries = .bt2020,
    };
    const bt2020_identity = try manager.identityForDescription(bt2020);
    try std.testing.expect(p3_identity != bt2020_identity);

    const surface = try Surface.create(
        std.testing.allocator,
        &surface_registry,
        &surfaces,
        client,
        7,
        1,
    );
    const manager_resource = try wp.ColorManagerV1.create(client, 3, 2);

    SurfaceState.create(&manager, manager_resource, 3, surface);
    try std.testing.expectEqual(@as(usize, 1), manager.surface_states.items.len);
    const state = manager.surface_states.items[0];
    state.resource.?.destroy();
    try std.testing.expectEqual(sdr, surface.pendingColorDescription());

    SurfaceState.create(&manager, manager_resource, 4, surface);
    try std.testing.expectEqual(@as(usize, 1), manager.surface_states.items.len);
    try std.testing.expect(manager.surface_states.items[0] == state);
    Feedback.create(&manager, manager_resource, 5, surface);
    const manager_v1 = try wp.ColorManagerV1.create(client, 1, 6);
    Feedback.create(&manager, manager_v1, 7, surface);
    try std.testing.expectEqual(@as(usize, 2), manager.feedbacks.items.len);

    const output_id = try outputs.add(.{
        .size = .{ .width = 1280, .height = 720 },
        .physical_size = .{ .width = 1280, .height = 720 },
        .scale = 1,
        .color_description = p3,
        .color_identity = p3_identity,
        .name = "COLOR-1",
        .description = "Color-managed test output",
        .model = "color-test",
    });
    const output = outputs.get(output_id).?;
    ManagedOutput.create(&manager, manager_resource, 8, output);
    output.beginFrame();
    try output.markSurfaceVisible(surface.id);
    output.endFrame();
    manager.refreshPreferred();
    for (manager.feedbacks.items) |feedback| {
        try std.testing.expectEqual(p3_identity, feedback.preferred_identity);
    }

    manager.updateOutputColorDescription(output, bt2020, bt2020_identity);
    try std.testing.expectEqual(bt2020, output.colorDescription());
    for (manager.feedbacks.items) |feedback| {
        try std.testing.expectEqual(bt2020_identity, feedback.preferred_identity);
    }

    output.beginFrame();
    output.endFrame();
    manager.refreshPreferred();
    for (manager.feedbacks.items) |feedback| {
        try std.testing.expectEqual(sdr_identity, feedback.preferred_identity);
    }
    manager.removeOutput(output);
    try std.testing.expect(outputs.remove(output_id));

    surface.waylandResource().destroy();
    try std.testing.expect(state.surface == null);
    for (manager.feedbacks.items) |feedback| {
        try std.testing.expect(feedback.surface == null);
    }

    state.resource.?.destroy();
    try std.testing.expectEqual(@as(usize, 0), manager.surface_states.items.len);
}
