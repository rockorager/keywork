//! Runtime-selected renderer.

const std = @import("std");
const CpuRenderer = @import("cpu.zig");
const VulkanRenderer = @import("vulkan.zig");
const headless = @import("../backend/headless.zig");
const Region = @import("../region.zig");
const render_types = @import("types.zig");
const command_geometry = @import("command_geometry.zig");
const gpu_timing = @import("gpu_timing.zig");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    commands: std.ArrayList(render_types.Command),
    visible_commands: std.ArrayList(render_types.Command),
    sampled_tags: std.ArrayList(u64),
    active_frame: ?ActiveFrame,

    pub const Kind = enum {
        cpu,
        vulkan,
    };

    pub const WorkingFormat = enum {
        argb8888,
        rgba16f_linear,
    };

    pub const Error = CpuRenderer.Error || VulkanRenderer.Error;
    pub const GpuTiming = gpu_timing.Timing;
    pub const FrameCompletion = render_types.FrameCompletion;

    const Backend = union(enum) {
        cpu: CpuRenderer,
        vulkan: VulkanRenderer,
    };

    const ActiveFrame = struct {
        target: render_types.Target,
        damage: ?[]const render_types.Rect,
        scale: render_types.Scale,
        origin: render_types.Position,
        color_description: render_types.ColorDescription,
        output_calibration: ?render_types.OutputCalibration = null,
    };

    pub fn init(allocator: std.mem.Allocator, kind: Kind) VulkanRenderer.InitError!Renderer {
        return initForDevice(allocator, kind, null);
    }

    pub fn initForDevice(
        allocator: std.mem.Allocator,
        kind: Kind,
        drm_device_id: ?render_types.DrmDeviceId,
    ) VulkanRenderer.InitError!Renderer {
        return .{
            .allocator = allocator,
            .backend = switch (kind) {
                .cpu => .{ .cpu = CpuRenderer.init(allocator) },
                .vulkan => .{ .vulkan = try VulkanRenderer.init(allocator, drm_device_id) },
            },
            .commands = .empty,
            .visible_commands = .empty,
            .sampled_tags = .empty,
            .active_frame = null,
        };
    }

    pub fn deinit(self: *Renderer) void {
        std.debug.assert(self.active_frame == null);
        self.commands.deinit(self.allocator);
        self.visible_commands.deinit(self.allocator);
        self.sampled_tags.deinit(self.allocator);
        switch (self.backend) {
            .cpu => |*renderer| renderer.deinit(),
            .vulkan => |*renderer| renderer.deinit(),
        }
        self.* = undefined;
    }

    pub fn supportsPartialDamage(self: *const Renderer) bool {
        return switch (self.backend) {
            .cpu, .vulkan => true,
        };
    }

    pub fn supportsBackdropCaptureReuse(self: *const Renderer) bool {
        return switch (self.backend) {
            .cpu => false,
            .vulkan => true,
        };
    }

    pub fn supportsColorManagement(self: *const Renderer) bool {
        return switch (self.backend) {
            .cpu => false,
            .vulkan => true,
        };
    }

    pub fn workingFormat(self: *const Renderer) WorkingFormat {
        return switch (self.backend) {
            .cpu => .argb8888,
            .vulkan => .rgba16f_linear,
        };
    }

    pub fn beginFrame(
        self: *Renderer,
        target: render_types.Target,
        scale: render_types.Scale,
        origin: render_types.Position,
        damage: ?[]const render_types.Rect,
        color_description: render_types.ColorDescription,
    ) Error!void {
        // Damage and buffers referenced by appended commands must remain valid through finishFrame.
        std.debug.assert(self.active_frame == null);
        std.debug.assert(self.commands.items.len == 0);
        self.sampled_tags.clearRetainingCapacity();
        try validateTarget(target);
        if (scale.numerator == 0 or scale.numerator > std.math.maxInt(i32)) {
            return error.InvalidTarget;
        }
        self.active_frame = .{
            .target = target,
            .damage = damage,
            .scale = scale,
            .origin = origin,
            .color_description = color_description,
        };
    }

    pub fn dmabufAccess(self: *Renderer) ?render_types.DmabufRenderer {
        return switch (self.backend) {
            .cpu => null,
            .vulkan => |*renderer| renderer.dmabufAccess(),
        };
    }

    pub fn dmabufDeviceId(self: *const Renderer) ?render_types.DrmDeviceId {
        return switch (self.backend) {
            .cpu => null,
            .vulkan => |*renderer| renderer.dmabufDeviceId(),
        };
    }

    pub fn dmabufSourceFormats(self: *const Renderer) []const render_types.DmabufFormatModifier {
        return switch (self.backend) {
            .cpu => &.{
                .{ .format = @intFromEnum(render_types.DmabufFormat.argb8888), .modifier = 0 },
                .{ .format = @intFromEnum(render_types.DmabufFormat.xrgb8888), .modifier = 0 },
                .{ .format = @intFromEnum(render_types.DmabufFormat.abgr8888), .modifier = 0 },
                .{ .format = @intFromEnum(render_types.DmabufFormat.xbgr8888), .modifier = 0 },
            },
            .vulkan => |*renderer| renderer.dmabufSourceFormats(),
        };
    }

    pub fn dmabufSourceValidator(self: *Renderer) ?render_types.DmabufSourceValidator {
        return switch (self.backend) {
            .cpu => null,
            .vulkan => |*renderer| renderer.dmabufSourceValidator(),
        };
    }

    pub fn offscreenAccess(self: *Renderer) ?render_types.OffscreenRenderer {
        return switch (self.backend) {
            .cpu => null,
            .vulkan => |*renderer| renderer.offscreenAccess(),
        };
    }

    pub fn append(self: *Renderer, commands: []const render_types.Command) Error!void {
        const active = self.active_frame orelse unreachable;
        const command_count = std.math.add(
            usize,
            self.commands.items.len,
            commands.len,
        ) catch return error.OutOfMemory;
        try self.sampled_tags.ensureTotalCapacity(self.allocator, command_count);
        const translated = active.origin.x != 0 or active.origin.y != 0;
        const scaled = active.scale.numerator != render_types.Scale.denominator;
        if (!translated and !scaled) {
            try self.commands.appendSlice(self.allocator, commands);
            return;
        }

        for (commands) |command| {
            const local_command = translateCommand(command, active.origin);
            try self.commands.append(self.allocator, if (scaled)
                scaleCommand(local_command, active.scale)
            else
                local_command);
        }
    }

    pub fn finishFrame(self: *Renderer) Error!void {
        const active = self.active_frame orelse unreachable;
        self.active_frame = null;
        defer self.commands.clearRetainingCapacity();
        const commands = try pruneOccludedCommands(
            self.allocator,
            &self.visible_commands,
            self.commands.items,
            active.target.size(),
        );
        self.rememberSampledCommands(commands);
        try self.renderDirect(.{
            .size = active.target.size(),
            .commands = commands,
            .damage = active.damage,
            .output_color_description = active.color_description,
            .output_calibration = active.output_calibration,
        }, active.target);
    }

    /// Finish a frame whose CPU pixel target may be populated asynchronously.
    /// A returned sync-file remains owned by the caller. When it becomes
    /// readable, the caller must invoke completeFrameReadback with this target
    /// as the submission source and the current destination storage. A null
    /// descriptor means the target was populated before this function returned.
    pub fn finishFrameReadback(self: *Renderer) Error!FrameCompletion {
        const active = self.active_frame orelse unreachable;
        const target = switch (active.target) {
            .pixels => |pixels| pixels,
            .offscreen, .dmabuf => return error.InvalidTarget,
        };
        if (active.damage != null) return error.InvalidTarget;
        self.active_frame = null;
        defer self.commands.clearRetainingCapacity();
        const commands = try pruneOccludedCommands(
            self.allocator,
            &self.visible_commands,
            self.commands.items,
            target.size,
        );
        self.rememberSampledCommands(commands);
        const frame: render_types.Frame = .{
            .size = target.size,
            .commands = commands,
            .output_color_description = active.color_description,
            .output_calibration = active.output_calibration,
        };
        return switch (self.backend) {
            .cpu => |*renderer| completed: {
                try renderer.render(frame, target);
                break :completed .{};
            },
            .vulkan => |*renderer| renderer.renderFrameReadback(frame, target),
        };
    }

    /// Wait for a readback submitted with source and optionally copy it into
    /// destination. Source storage only identifies the pending submission and
    /// is not accessed.
    pub fn completeFrameReadback(
        self: *Renderer,
        source: render_types.PixelBuffer,
        destination: ?render_types.PixelBuffer,
    ) Error!void {
        return switch (self.backend) {
            .cpu => {},
            .vulkan => |*renderer| renderer.completeFrameReadback(source, destination),
        };
    }

    /// Export all or part of a retained, fully composed frame without replaying
    /// its scene commands. Source region is in source pixel coordinates and its
    /// size must match the target. Returns null when the selected backend or color
    /// conversion cannot use the retained frame directly.
    pub fn copyComposedFrame(
        self: *Renderer,
        source: render_types.Target,
        source_region: ?render_types.Rect,
        target: render_types.Target,
        color_description: render_types.ColorDescription,
    ) Error!?FrameCompletion {
        std.debug.assert(self.active_frame == null);
        try validateTarget(source);
        try validateTarget(target);
        return switch (self.backend) {
            .cpu => null,
            .vulkan => |*renderer| try renderer.copyComposedFrame(
                source,
                source_region,
                target,
                color_description,
            ),
        };
    }

    /// Returns the frame's buffer-path statistics and an owned sync-file when
    /// an external display consumer needs asynchronous completion. Rendering
    /// to a GPU-resident target without an external consumer may remain in
    /// flight without a descriptor; the renderer synchronizes before reuse.
    /// The caller must close a returned descriptor after handing it off.
    pub fn finishFrameScanout(
        self: *Renderer,
        gpu_sample_tag: ?u64,
    ) Error!FrameCompletion {
        return self.finishFrameScanoutCommands(gpu_sample_tag, false);
    }

    /// Finish a frame after its final image command was validated for an
    /// output overlay plane. The caller must not present the resulting primary
    /// buffer without that exact overlay state.
    pub fn finishFrameScanoutWithoutTopmost(
        self: *Renderer,
        gpu_sample_tag: ?u64,
    ) Error!FrameCompletion {
        return self.finishFrameScanoutCommands(gpu_sample_tag, true);
    }

    fn finishFrameScanoutCommands(
        self: *Renderer,
        gpu_sample_tag: ?u64,
        exclude_topmost: bool,
    ) Error!FrameCompletion {
        const active = self.active_frame orelse unreachable;
        self.active_frame = null;
        defer self.commands.clearRetainingCapacity();
        const unpruned_commands = if (exclude_topmost) commands: {
            const last_command = self.commands.getLastOrNull() orelse unreachable;
            switch (last_command) {
                .image => {},
                else => unreachable,
            }
            break :commands self.commands.items[0 .. self.commands.items.len - 1];
        } else self.commands.items;
        // An excluded overlay must not hide primary-plane content needed when
        // the overlay is removed or rejected by a later atomic commit.
        const commands = try pruneOccludedCommands(
            self.allocator,
            &self.visible_commands,
            unpruned_commands,
            active.target.size(),
        );
        self.rememberSampledCommands(commands);
        if (exclude_topmost) {
            self.rememberSampledCommand(self.commands.getLast());
        }
        const frame: render_types.Frame = .{
            .size = active.target.size(),
            .commands = commands,
            .damage = active.damage,
            .output_color_description = active.color_description,
            .output_calibration = active.output_calibration,
        };
        return switch (self.backend) {
            .cpu => |*renderer| switch (active.target) {
                .pixels => |pixels| blk: {
                    try renderer.render(frame, pixels);
                    break :blk .{};
                },
                .offscreen, .dmabuf => error.InvalidTarget,
            },
            .vulkan => |*renderer| renderer.renderFrameScanout(
                frame,
                active.target,
                gpu_sample_tag,
            ),
        };
    }

    pub fn takeGpuTiming(self: *Renderer) ?GpuTiming {
        return switch (self.backend) {
            .cpu => null,
            .vulkan => |*renderer| renderer.takeGpuTiming(),
        };
    }

    pub fn discardGpuTimings(self: *Renderer) void {
        switch (self.backend) {
            .cpu => {},
            .vulkan => |*renderer| renderer.discardGpuTimings(),
        }
    }

    pub fn directScanoutCandidate(self: *Renderer) render_types.DirectScanoutCandidate {
        const active = self.active_frame orelse return .{ .rejected = .no_fullscreen_surface };
        const last_command = self.commands.getLastOrNull() orelse
            return .{ .rejected = .no_fullscreen_surface };
        const image = switch (last_command) {
            .image => |image| image,
            else => return .{ .rejected = .no_fullscreen_surface },
        };
        if (image.x != 0 or image.y != 0 or
            !std.meta.eql(image.size, active.target.size()))
        {
            return .{ .rejected = .no_fullscreen_surface };
        }
        if (!image.is_opaque or image.alpha_multiplier != std.math.maxInt(u32)) {
            return .{ .rejected = .non_opaque_surface };
        }
        if (image.source != null or image.transform != .normal or
            image.rounded_clip != null or image.clip != null)
        {
            return .{ .rejected = .surface_transform };
        }
        const dmabuf = image.buffer.dmabuf orelse return .{ .rejected = .non_dmabuf };
        if (dmabuf.y_inverted) return .{ .rejected = .y_inverted };
        if (image.buffer.source_cache == null) {
            return .{ .rejected = .missing_buffer_identity };
        }
        if (!std.meta.eql(image.buffer.color_description, active.color_description)) {
            return .{ .rejected = .color_conversion };
        }
        if (active.output_calibration != null) return .{ .rejected = .color_conversion };
        return .{ .candidate = image.buffer };
    }

    pub fn overlayScanoutCandidate(self: *Renderer) render_types.OverlayScanoutCandidate {
        const active = self.active_frame orelse return .{ .rejected = .no_topmost_surface };
        const last_command = self.commands.getLastOrNull() orelse
            return .{ .rejected = .no_topmost_surface };
        const image = switch (last_command) {
            .image => |image| image,
            else => return .{ .rejected = .no_topmost_surface },
        };
        if (!image.is_opaque or image.alpha_multiplier != std.math.maxInt(u32)) {
            return .{ .rejected = .non_opaque_surface };
        }
        if (image.rounded_clip != null or image.clip != null) {
            return .{ .rejected = .clipped_surface };
        }
        if (image.source != null or image.transform != .normal) {
            return .{ .rejected = .transformed_surface };
        }
        if (!std.meta.eql(image.size, image.buffer.size)) {
            return .{ .rejected = .scaled_surface };
        }
        const right = @as(i64, image.x) + image.size.width;
        const bottom = @as(i64, image.y) + image.size.height;
        if (image.x < 0 or image.y < 0 or right > active.target.size().width or
            bottom > active.target.size().height or image.size.width == 0 or image.size.height == 0)
        {
            return .{ .rejected = .outside_output };
        }
        const dmabuf = image.buffer.dmabuf orelse return .{ .rejected = .non_dmabuf };
        const format = render_types.DmabufFormat.fromFourcc(dmabuf.format) orelse
            return .{ .rejected = .non_rgb_surface };
        const rgb_representation: render_types.ColorRepresentation = .{};
        if (format.isPackedRgb()) {
            if (!std.meta.eql(image.buffer.color_representation, rgb_representation)) {
                return .{ .rejected = .non_rgb_surface };
            }
        } else if (image.buffer.color_representation.coefficients == .identity or
            image.buffer.color_representation.chroma_location != .type_0)
        {
            return .{ .rejected = .color_conversion };
        }
        if (dmabuf.y_inverted) return .{ .rejected = .y_inverted };
        if (image.buffer.source_cache == null) {
            return .{ .rejected = .missing_buffer_identity };
        }
        if (!std.meta.eql(image.buffer.color_description, active.color_description) or
            active.output_calibration != null)
        {
            return .{ .rejected = .color_conversion };
        }

        var buffer = image.buffer;
        buffer.dmabuf.?.force_opaque = true;
        return .{ .candidate = .{
            .buffer = buffer,
            .destination = .{
                .x = image.x,
                .y = image.y,
                .width = image.size.width,
                .height = image.size.height,
            },
        } };
    }

    pub fn preferredOutputTransfer(self: *const Renderer) ?render_types.TransferFunction {
        std.debug.assert(self.active_frame != null);
        var hlg = false;
        for (self.commands.items) |command| switch (command) {
            .image => |image| switch (image.buffer.color_description.transfer_function) {
                .st2084_pq => return .st2084_pq,
                .hlg => hlg = true,
                .bt1886, .gamma22, .srgb, .power => {},
            },
            else => {},
        };
        return if (hlg) .hlg else null;
    }

    pub fn setOutputColorDescription(
        self: *Renderer,
        description: render_types.ColorDescription,
    ) void {
        const active = if (self.active_frame) |*frame| frame else unreachable;
        active.color_description = description;
    }

    pub fn setOutputCalibration(
        self: *Renderer,
        calibration: ?render_types.OutputCalibration,
    ) void {
        const active = if (self.active_frame) |*frame| frame else unreachable;
        active.output_calibration = calibration;
    }

    pub fn cancelFrame(self: *Renderer) void {
        std.debug.assert(self.active_frame != null);
        self.active_frame = null;
        self.commands.clearRetainingCapacity();
    }

    /// Finish a frame whose topmost image is presented directly by the output.
    pub fn finishFrameDirectScanout(self: *Renderer) void {
        std.debug.assert(self.active_frame != null);
        self.rememberSampledCommand(self.commands.getLast());
        self.cancelFrame();
    }

    pub fn wasSampled(self: *const Renderer, tag: u64) bool {
        std.debug.assert(self.active_frame == null);
        return std.mem.indexOfScalar(u64, self.sampled_tags.items, tag) != null;
    }

    fn rememberSampledCommands(
        self: *Renderer,
        commands: []const render_types.Command,
    ) void {
        for (commands) |command| self.rememberSampledCommand(command);
    }

    fn rememberSampledCommand(self: *Renderer, command: render_types.Command) void {
        const tag = switch (command) {
            .image => |image| image.sample_tag orelse return,
            else => return,
        };
        if (std.mem.indexOfScalar(u64, self.sampled_tags.items, tag) != null) return;
        self.sampled_tags.appendAssumeCapacity(tag);
    }

    pub fn render(
        self: *Renderer,
        frame: render_types.Frame,
        target: render_types.PixelBuffer,
    ) Error!void {
        try self.beginFrame(
            .{ .pixels = target },
            frame.scale,
            frame.origin,
            frame.damage,
            frame.output_color_description,
        );
        var active = true;
        errdefer if (active) self.cancelFrame();
        try self.append(frame.commands);
        active = false;
        try self.finishFrame();
    }

    fn renderDirect(
        self: *Renderer,
        frame: render_types.Frame,
        target: render_types.Target,
    ) Error!void {
        return switch (self.backend) {
            .cpu => |*renderer| switch (target) {
                .pixels => |pixels| renderer.render(frame, pixels),
                .offscreen, .dmabuf => error.InvalidTarget,
            },
            .vulkan => |*renderer| renderer.renderFrame(frame, target),
        };
    }
};

fn validateTarget(target: render_types.Target) Renderer.Error!void {
    const size = target.size();
    if (size.width == 0 or size.height == 0) return error.InvalidTarget;
    const pixels = switch (target) {
        .pixels => |pixels| pixels,
        .offscreen => |offscreen| {
            if (offscreen.id == 0) return error.InvalidTarget;
            return;
        },
        .dmabuf => |dmabuf| {
            if (dmabuf.id == 0) return error.InvalidTarget;
            return;
        },
    };
    if (pixels.dmabuf != null) return error.InvalidTarget;
    if (pixels.stride_pixels < pixels.size.width) return error.InvalidTarget;
    const last_row = std.math.mul(
        usize,
        pixels.size.height - 1,
        pixels.stride_pixels,
    ) catch return error.InvalidTarget;
    const required_pixels = std.math.add(usize, last_row, pixels.size.width) catch
        return error.InvalidTarget;
    if (pixels.pixels.len < required_pixels) return error.InvalidTarget;
}

/// Removes or clips commands where later opaque draws replace their output.
/// Commands preceding a backdrop capture are kept relative to that capture
/// because the capture observes the target at its command-stream position.
fn pruneOccludedCommands(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(render_types.Command),
    commands: []const render_types.Command,
    frame_size: render_types.Size,
) Renderer.Error![]const render_types.Command {
    const maximum_command_fragments = 16;
    result.clearRetainingCapacity();
    try result.ensureTotalCapacity(allocator, commands.len);

    var coverage = Region.init();
    defer coverage.deinit();
    var uncovered = Region.init();
    defer uncovered.deinit();

    var read = commands.len;
    while (read > 0) {
        read -= 1;
        const command = commands[read];
        if (std.meta.activeTag(command) == .backdrop_capture) {
            coverage.clear();
        } else if (command_geometry.visibleRect(command, frame_size)) |visible| {
            if (commandCanBePruned(command)) {
                uncovered.setRectangle(visible.x, visible.y, visible.width, visible.height);
                var covered_rectangles = coverage.rectangleIterator();
                while (covered_rectangles.next()) |covered| {
                    try uncovered.subtract(
                        covered.x,
                        covered.y,
                        @intCast(covered.width),
                        @intCast(covered.height),
                    );
                }
                if (uncovered.isEmpty()) continue;

                if (commandCanBeClipped(command)) {
                    var rectangle_count: usize = 0;
                    var rectangles = uncovered.rectangleIterator();
                    while (rectangles.next() != null) rectangle_count += 1;
                    if (rectangle_count <= maximum_command_fragments and
                        !(rectangle_count == 1 and uncovered.coversRectangle(
                            visible.x,
                            visible.y,
                            visible.width,
                            visible.height,
                        )))
                    {
                        var fragments: [maximum_command_fragments]render_types.Rect = undefined;
                        rectangles = uncovered.rectangleIterator();
                        var fragment_index: usize = 0;
                        while (rectangles.next()) |rectangle| : (fragment_index += 1) {
                            fragments[fragment_index] = .{
                                .x = rectangle.x,
                                .y = rectangle.y,
                                .width = rectangle.width,
                                .height = rectangle.height,
                            };
                        }
                        while (fragment_index > 0) {
                            fragment_index -= 1;
                            try result.append(
                                allocator,
                                clipCommand(command, fragments[fragment_index]),
                            );
                        }
                        try addOpaqueCommandCoverage(&coverage, command, frame_size);
                        continue;
                    }
                }
            }
        }

        try result.append(allocator, command);
        try addOpaqueCommandCoverage(&coverage, command, frame_size);
    }
    std.mem.reverse(render_types.Command, result.items);
    return result.items;
}

fn commandCanBePruned(command: render_types.Command) bool {
    return switch (command) {
        .clear, .solid_rect, .image, .crossfade => true,
        .shadow, .backdrop_capture, .backdrop_blur => false,
    };
}

fn commandCanBeClipped(command: render_types.Command) bool {
    return switch (command) {
        .solid_rect, .image, .crossfade => true,
        .clear, .shadow, .backdrop_capture, .backdrop_blur => false,
    };
}

fn clipCommand(command: render_types.Command, clip: render_types.Rect) render_types.Command {
    return switch (command) {
        .solid_rect => |solid| clipped: {
            var result = solid;
            result.clip = clip;
            break :clipped .{ .solid_rect = result };
        },
        .image => |image| clipped: {
            var result = image;
            result.clip = clip;
            break :clipped .{ .image = result };
        },
        .crossfade => |fade| clipped: {
            var result = fade;
            result.clip = clip;
            break :clipped .{ .crossfade = result };
        },
        .clear, .shadow, .backdrop_capture, .backdrop_blur => unreachable,
    };
}

fn addOpaqueCommandCoverage(
    coverage: *Region,
    command: render_types.Command,
    frame_size: render_types.Size,
) Renderer.Error!void {
    switch (command) {
        .clear => |color| if (color.alpha != std.math.maxInt(u8)) return,
        .solid_rect => |solid| if (solid.color.alpha != std.math.maxInt(u8)) return,
        .image => |image| {
            if (image.alpha_multiplier != std.math.maxInt(u32) or
                image.rounded_clip != null) return;
            if (!image.is_opaque) {
                const visible = command_geometry.visibleRect(command, frame_size) orelse return;
                for (image.opaque_region.slice()) |rectangle| {
                    const clipped = rectangle.intersection(visible) orelse continue;
                    try addCoverageRectangle(coverage, clipped);
                }
                return;
            }
        },
        .crossfade, .shadow, .backdrop_capture, .backdrop_blur => return,
    }
    if (command_geometry.visibleRect(command, frame_size)) |rectangle| {
        try addCoverageRectangle(coverage, rectangle);
    }
}

fn addCoverageRectangle(coverage: *Region, rectangle: render_types.Rect) Renderer.Error!void {
    if (rectangle.width > std.math.maxInt(i32) or
        rectangle.height > std.math.maxInt(i32)) return;
    try coverage.add(
        rectangle.x,
        rectangle.y,
        @intCast(rectangle.width),
        @intCast(rectangle.height),
    );
}

fn translateCommand(
    command: render_types.Command,
    origin: render_types.Position,
) render_types.Command {
    return switch (command) {
        .clear => |color| .{ .clear = color },
        .solid_rect => |solid| .{ .solid_rect = .{
            .rect = translateRect(solid.rect, origin),
            .color = solid.color,
            .clip = if (solid.clip) |clip| translateRect(clip, origin) else null,
        } },
        .shadow => |shadow| .{ .shadow = .{
            .rect = translateRect(shadow.rect, origin),
            .corner_radius = shadow.corner_radius,
            .blur_radius = shadow.blur_radius,
            .spread = shadow.spread,
            .color = shadow.color,
            .cutout = if (shadow.cutout) |cutout| .{
                .rect = translateRect(cutout.rect, origin),
                .radius = cutout.radius,
            } else null,
            .clip = if (shadow.clip) |clip| translateRect(clip, origin) else null,
        } },
        .backdrop_capture => |capture| .{ .backdrop_capture = .{
            .id = capture.id,
            .rect = translateRect(capture.rect, origin),
            .radius = capture.radius,
            .downsample_level = capture.downsample_level,
            .finish = capture.finish,
            .base = capture.base,
        } },
        .backdrop_blur => |blur| .{ .backdrop_blur = .{
            .capture_id = blur.capture_id,
            .rect = translateRect(blur.rect, origin),
            .corner_radius = blur.corner_radius,
            .radius = blur.radius,
            .downsample_level = blur.downsample_level,
            .finish = blur.finish,
            .clip = if (blur.clip) |clip| translateRect(clip, origin) else null,
        } },
        .image => |image| .{ .image = .{
            .x = translateCoordinate(image.x, origin.x),
            .y = translateCoordinate(image.y, origin.y),
            .size = image.size,
            .buffer = image.buffer,
            .sample_tag = image.sample_tag,
            .source = image.source,
            .transform = image.transform,
            .is_opaque = image.is_opaque,
            .opaque_region = translateOpaqueRegion(image.opaque_region, origin),
            .alpha_multiplier = image.alpha_multiplier,
            .rounded_clip = if (image.rounded_clip) |clip| .{
                .rect = translateRect(clip.rect, origin),
                .radius = clip.radius,
            } else null,
            .clip = if (image.clip) |clip| translateRect(clip, origin) else null,
        } },
        .crossfade => |fade| .{ .crossfade = .{
            .destination = translateRect(fade.destination, origin),
            .old = fade.old,
            .new = fade.new,
            .old_source = fade.old_source,
            .new_source = fade.new_source,
            .factor = fade.factor,
            .rounded_clip = if (fade.rounded_clip) |clip| .{ .rect = translateRect(clip.rect, origin), .radius = clip.radius } else null,
            .clip = if (fade.clip) |clip| translateRect(clip, origin) else null,
        } },
    };
}

fn translateRect(rect: render_types.Rect, origin: render_types.Position) render_types.Rect {
    return .{
        .x = translateCoordinate(rect.x, origin.x),
        .y = translateCoordinate(rect.y, origin.y),
        .width = rect.width,
        .height = rect.height,
    };
}

fn translateCoordinate(value: i32, origin: i32) i32 {
    return @intCast(std.math.clamp(
        @as(i64, value) - origin,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn scaleCommand(command: render_types.Command, scale: render_types.Scale) render_types.Command {
    std.debug.assert(scale.numerator > 0 and scale.numerator <= std.math.maxInt(i32));
    return switch (command) {
        .clear => |color| .{ .clear = color },
        .solid_rect => |solid| .{ .solid_rect = .{
            .rect = scaleRect(solid.rect, scale),
            .color = solid.color,
            .clip = if (solid.clip) |clip| scaleRect(clip, scale) else null,
        } },
        .shadow => |shadow| .{ .shadow = .{
            .rect = scaleRect(shadow.rect, scale),
            .corner_radius = scaleUnsigned(shadow.corner_radius, scale),
            .blur_radius = scaleUnsigned(shadow.blur_radius, scale),
            .spread = scaleSigned(shadow.spread, scale),
            .color = shadow.color,
            .cutout = if (shadow.cutout) |cutout| .{
                .rect = scaleRect(cutout.rect, scale),
                .radius = scaleUnsigned(cutout.radius, scale),
            } else null,
            .clip = if (shadow.clip) |clip| scaleRect(clip, scale) else null,
        } },
        .backdrop_capture => |capture| .{ .backdrop_capture = .{
            .id = capture.id,
            .rect = scaleRect(capture.rect, scale),
            .radius = scaleUnsigned(capture.radius, scale),
            .downsample_level = capture.downsample_level,
            .finish = capture.finish,
            .base = capture.base,
        } },
        .backdrop_blur => |blur| .{ .backdrop_blur = .{
            .capture_id = blur.capture_id,
            .rect = scaleRect(blur.rect, scale),
            .corner_radius = scaleUnsigned(blur.corner_radius, scale),
            .radius = scaleUnsigned(blur.radius, scale),
            .downsample_level = blur.downsample_level,
            .finish = blur.finish,
            .clip = if (blur.clip) |clip| scaleRect(clip, scale) else null,
        } },
        .image => |image| scaled: {
            const rect = scaleRect(.{
                .x = image.x,
                .y = image.y,
                .width = image.size.width,
                .height = image.size.height,
            }, scale);
            break :scaled .{ .image = .{
                .x = rect.x,
                .y = rect.y,
                .size = .{ .width = rect.width, .height = rect.height },
                .buffer = image.buffer,
                .sample_tag = image.sample_tag,
                .source = image.source,
                .transform = image.transform,
                .is_opaque = image.is_opaque,
                .opaque_region = scaleOpaqueRegion(image.opaque_region, scale),
                .alpha_multiplier = image.alpha_multiplier,
                .rounded_clip = if (image.rounded_clip) |clip| .{
                    .rect = scaleRect(clip.rect, scale),
                    .radius = scaleUnsigned(clip.radius, scale),
                } else null,
                .clip = if (image.clip) |clip| scaleRect(clip, scale) else null,
            } };
        },
        .crossfade => |fade| .{ .crossfade = .{
            .destination = scaleRect(fade.destination, scale),
            .old = fade.old,
            .new = fade.new,
            .old_source = fade.old_source,
            .new_source = fade.new_source,
            .factor = fade.factor,
            .rounded_clip = if (fade.rounded_clip) |clip| .{ .rect = scaleRect(clip.rect, scale), .radius = scaleUnsigned(clip.radius, scale) } else null,
            .clip = if (fade.clip) |clip| scaleRect(clip, scale) else null,
        } },
    };
}

fn translateOpaqueRegion(
    region: render_types.OpaqueRegion,
    origin: render_types.Position,
) render_types.OpaqueRegion {
    var result: render_types.OpaqueRegion = .{};
    for (region.slice()) |rectangle| {
        _ = result.append(translateRect(rectangle, origin));
    }
    return result;
}

fn scaleOpaqueRegion(
    region: render_types.OpaqueRegion,
    scale: render_types.Scale,
) render_types.OpaqueRegion {
    var result: render_types.OpaqueRegion = .{};
    for (region.slice()) |rectangle| {
        const left = scaleCeil(@as(i64, rectangle.x), scale);
        const top = scaleCeil(@as(i64, rectangle.y), scale);
        const right = scaleFloor(@as(i64, rectangle.x) + rectangle.width, scale);
        const bottom = scaleFloor(@as(i64, rectangle.y) + rectangle.height, scale);
        if (left >= right or top >= bottom) continue;
        _ = result.append(.{
            .x = left,
            .y = top,
            .width = @intCast(@as(i64, right) - left),
            .height = @intCast(@as(i64, bottom) - top),
        });
    }
    return result;
}

fn scaleFloor(value: i64, scale: render_types.Scale) i32 {
    const product = @as(i128, value) * scale.numerator;
    return @intCast(std.math.clamp(
        @divFloor(product, render_types.Scale.denominator),
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn scaleCeil(value: i64, scale: render_types.Scale) i32 {
    const product = @as(i128, value) * scale.numerator;
    return @intCast(std.math.clamp(
        -@divFloor(-product, render_types.Scale.denominator),
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn scaleRect(rect: render_types.Rect, scale: render_types.Scale) render_types.Rect {
    const left = scaleSigned(rect.x, scale);
    const top = scaleSigned(rect.y, scale);
    const right = scaleSigned(@as(i64, rect.x) + rect.width, scale);
    const bottom = scaleSigned(@as(i64, rect.y) + rect.height, scale);
    return .{
        .x = left,
        .y = top,
        .width = @intCast(@max(@as(i64, right) - left, 0)),
        .height = @intCast(@max(@as(i64, bottom) - top, 0)),
    };
}

fn scaleSigned(value: i64, scale: render_types.Scale) i32 {
    const product = @as(i128, value) * scale.numerator;
    const rounded = if (product >= 0)
        @divTrunc(
            product + render_types.Scale.denominator / 2,
            render_types.Scale.denominator,
        )
    else
        -@divTrunc(
            -product + render_types.Scale.denominator / 2,
            render_types.Scale.denominator,
        );
    return @intCast(std.math.clamp(
        rounded,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn scaleUnsigned(value: u32, scale: render_types.Scale) u32 {
    const product = @as(u64, value) * scale.numerator;
    return @intCast(@min(
        (product + render_types.Scale.denominator / 2) / render_types.Scale.denominator,
        std.math.maxInt(u32),
    ));
}

test "renderer transforms image opaque regions with their commands" {
    var region: render_types.OpaqueRegion = .{};
    try std.testing.expect(region.append(.{ .x = 11, .y = -3, .width = 2, .height = 4 }));

    const translated = translateOpaqueRegion(region, .{ .x = 10, .y = -4 });
    try std.testing.expectEqualSlices(
        render_types.Rect,
        &.{.{ .x = 1, .y = 1, .width = 2, .height = 4 }},
        translated.slice(),
    );

    const scaled = scaleOpaqueRegion(translated, .{ .numerator = 180 });
    try std.testing.expectEqualSlices(
        render_types.Rect,
        &.{.{ .x = 2, .y = 2, .width = 2, .height = 5 }},
        scaled.slice(),
    );
}

test "renderer prunes commands completely hidden by an opaque image" {
    const size: render_types.Size = .{ .width = 4, .height = 2 };
    var result: std.ArrayList(render_types.Command) = .empty;
    defer result.deinit(std.testing.allocator);
    var pixels = [_]u32{0xffffffff} ** 8;
    const image: render_types.Command = .{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{
            .size = size,
            .stride_pixels = size.width,
            .pixels = &pixels,
        },
        .is_opaque = true,
    } };
    var commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 0, .y = 0, .width = 4, .height = 2 },
            .color = render_types.Color.rgba(255, 0, 0, 128),
        } },
        image,
    };

    const pruned = try pruneOccludedCommands(
        std.testing.allocator,
        &result,
        &commands,
        size,
    );
    try std.testing.expectEqual(@as(usize, 1), pruned.len);
    try std.testing.expectEqual(.image, std.meta.activeTag(pruned[0]));

    var translucent = [_]render_types.Command{ commands[0], image };
    translucent[1].image.is_opaque = false;
    try std.testing.expectEqual(
        @as(usize, 2),
        (try pruneOccludedCommands(
            std.testing.allocator,
            &result,
            &translucent,
            size,
        )).len,
    );

    var multiplied = [_]render_types.Command{ commands[0], image };
    multiplied[1].image.alpha_multiplier = 0x8000_0000;
    try std.testing.expectEqual(
        @as(usize, 2),
        (try pruneOccludedCommands(
            std.testing.allocator,
            &result,
            &multiplied,
            size,
        )).len,
    );

    var rounded = [_]render_types.Command{ commands[0], image };
    rounded[1].image.rounded_clip = .{
        .rect = .{ .x = 0, .y = 0, .width = 4, .height = 2 },
        .radius = 1,
    };
    try std.testing.expectEqual(
        @as(usize, 2),
        (try pruneOccludedCommands(
            std.testing.allocator,
            &result,
            &rounded,
            size,
        )).len,
    );
}

test "renderer reports only sampled image tags after occlusion pruning" {
    const size: render_types.Size = .{ .width = 2, .height = 1 };
    var lower_pixels = [_]u32{0xffff0000} ** 2;
    var upper_pixels = [_]u32{0xff00ff00} ** 2;
    const commands = [_]render_types.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = size.width,
                .pixels = &lower_pixels,
            },
            .sample_tag = 1,
            .is_opaque = true,
        } },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = size.width,
                .pixels = &upper_pixels,
            },
            .sample_tag = 2,
            .is_opaque = true,
        } },
    };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();
    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();

    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expect(!renderer.wasSampled(1));
    try std.testing.expect(renderer.wasSampled(2));
}

test "renderer reports direct and overlay scanout image tags" {
    const size: render_types.Size = .{ .width = 1, .height = 1 };
    var source_pixel = [_]u32{0xffffffff};
    const image: render_types.Command = .{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{
            .size = size,
            .stride_pixels = size.width,
            .pixels = &source_pixel,
        },
        .sample_tag = 42,
        .is_opaque = true,
    } };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();
    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();

    try renderer.beginFrame(.{ .pixels = output.target() }, .{}, .{}, null, .{});
    try renderer.append(&.{image});
    renderer.finishFrameDirectScanout();
    try std.testing.expect(renderer.wasSampled(42));

    try renderer.beginFrame(.{ .pixels = output.target() }, .{}, .{}, null, .{});
    try renderer.append(&.{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        image,
    });
    _ = try renderer.finishFrameScanoutWithoutTopmost(null);
    try std.testing.expect(renderer.wasSampled(42));
}

test "renderer clips lower commands around partial opaque coverage" {
    const size: render_types.Size = .{ .width = 4, .height = 2 };
    var result: std.ArrayList(render_types.Command) = .empty;
    defer result.deinit(std.testing.allocator);
    const lower: render_types.Command = .{ .solid_rect = .{
        .rect = .{ .x = 0, .y = 0, .width = 4, .height = 2 },
        .color = render_types.Color.rgba(255, 0, 0, 128),
    } };
    const left: render_types.Command = .{ .solid_rect = .{
        .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .color = render_types.Color.rgba(0, 255, 0, 255),
    } };
    const right: render_types.Command = .{ .solid_rect = .{
        .rect = .{ .x = 2, .y = 0, .width = 2, .height = 2 },
        .color = render_types.Color.rgba(0, 0, 255, 255),
    } };
    var covered = [_]render_types.Command{ lower, left, right };
    try std.testing.expectEqual(
        @as(usize, 2),
        (try pruneOccludedCommands(
            std.testing.allocator,
            &result,
            &covered,
            size,
        )).len,
    );

    var partial = [_]render_types.Command{ lower, left, right };
    partial[2].solid_rect.rect.width = 1;
    const clipped = try pruneOccludedCommands(
        std.testing.allocator,
        &result,
        &partial,
        size,
    );
    try std.testing.expectEqual(@as(usize, 3), clipped.len);
    try std.testing.expectEqual(
        render_types.Rect{ .x = 3, .y = 0, .width = 1, .height = 2 },
        clipped[0].solid_rect.clip.?,
    );
}

test "renderer uses partial image opaque regions as coverage" {
    const size: render_types.Size = .{ .width = 4, .height = 2 };
    var result: std.ArrayList(render_types.Command) = .empty;
    defer result.deinit(std.testing.allocator);
    var pixels = [_]u32{0xffffffff} ** 8;
    var opaque_region: render_types.OpaqueRegion = .{};
    try std.testing.expect(opaque_region.append(.{
        .x = 1,
        .y = 0,
        .width = 2,
        .height = 2,
    }));
    const commands = [_]render_types.Command{
        .{ .solid_rect = .{
            .rect = .{ .x = 0, .y = 0, .width = 4, .height = 2 },
            .color = render_types.Color.rgba(255, 0, 0, 128),
        } },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = size.width,
                .pixels = &pixels,
            },
            .opaque_region = opaque_region,
        } },
    };

    const clipped = try pruneOccludedCommands(
        std.testing.allocator,
        &result,
        &commands,
        size,
    );
    try std.testing.expectEqual(@as(usize, 3), clipped.len);
    try std.testing.expectEqual(
        render_types.Rect{ .x = 0, .y = 0, .width = 1, .height = 2 },
        clipped[0].solid_rect.clip.?,
    );
    try std.testing.expectEqual(
        render_types.Rect{ .x = 3, .y = 0, .width = 1, .height = 2 },
        clipped[1].solid_rect.clip.?,
    );
    try std.testing.expectEqual(.image, std.meta.activeTag(clipped[2]));
}

test "renderer preserves content observed by a backdrop capture" {
    const size: render_types.Size = .{ .width = 4, .height = 2 };
    var result: std.ArrayList(render_types.Command) = .empty;
    defer result.deinit(std.testing.allocator);
    var commands = [_]render_types.Command{
        .{ .solid_rect = .{
            .rect = .{ .x = 0, .y = 0, .width = 4, .height = 2 },
            .color = render_types.Color.rgba(255, 0, 0, 255),
        } },
        .{ .backdrop_capture = .{
            .id = 1,
            .rect = .{ .x = 0, .y = 0, .width = 4, .height = 2 },
            .radius = 4,
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 0, .y = 0, .width = 4, .height = 2 },
            .color = render_types.Color.rgba(0, 0, 255, 255),
        } },
    };

    try std.testing.expectEqual(
        @as(usize, 3),
        (try pruneOccludedCommands(
            std.testing.allocator,
            &result,
            &commands,
            size,
        )).len,
    );
}

test "renderer dispatches to the selected implementation" {
    const size: render_types.Size = .{ .width = 2, .height = 2 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(10, 20, 30, 255) },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{ .size = size, .commands = &commands },
        output.target(),
    );

    try std.testing.expectEqual(@as(u32, 0xff0a141e), output.pixel(1, 1));
}

test "renderer submits accumulated commands as one frame" {
    const size: render_types.Size = .{ .width = 2, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();
    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();

    try renderer.beginFrame(.{ .pixels = output.target() }, .{}, .{}, null, .{});
    try renderer.append(&.{.{ .clear = render_types.Color.rgba(10, 20, 30, 255) }});
    try std.testing.expectEqual(@as(u32, 0), output.pixel(0, 0));
    try renderer.append(&.{.{ .solid_rect = .{
        .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
        .color = render_types.Color.rgba(40, 50, 60, 255),
    } }});
    try renderer.finishFrame();

    try std.testing.expectEqual(@as(u32, 0xff0a141e), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff28323c), output.pixel(1, 0));
}

test "cancelled renderer frame does not leak commands" {
    const size: render_types.Size = .{ .width = 1, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();
    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();

    try renderer.beginFrame(.{ .pixels = output.target() }, .{}, .{}, null, .{});
    try renderer.append(&.{.{ .clear = render_types.Color.rgba(255, 0, 0, 255) }});
    renderer.cancelFrame();
    try renderer.render(
        .{ .size = size, .commands = &.{.{ .clear = render_types.Color.rgba(0, 0, 255, 255) }} },
        output.target(),
    );

    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(0, 0));
}

test "renderer prefers PQ then HLG output for visible HDR images" {
    const size: render_types.Size = .{ .width = 1, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();
    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    var pixel: u32 = 0;
    var image: render_types.Command = .{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{
            .size = size,
            .stride_pixels = size.width,
            .pixels = @as(*[1]u32, &pixel),
        },
    } };

    try renderer.beginFrame(.{ .pixels = output.target() }, .{}, .{}, null, .{});
    try renderer.append(&.{image});
    try std.testing.expect(renderer.preferredOutputTransfer() == null);
    renderer.cancelFrame();

    image.image.buffer.color_description.transfer_function = .hlg;
    try renderer.beginFrame(.{ .pixels = output.target() }, .{}, .{}, null, .{});
    try renderer.append(&.{image});
    const hlg: render_types.TransferFunction = .hlg;
    try std.testing.expectEqual(
        hlg,
        renderer.preferredOutputTransfer().?,
    );
    image.image.buffer.color_description.transfer_function = .st2084_pq;
    try renderer.append(&.{image});
    const pq: render_types.TransferFunction = .st2084_pq;
    try std.testing.expectEqual(
        pq,
        renderer.preferredOutputTransfer().?,
    );
    renderer.cancelFrame();
}

test "reproducible scene: direct scanout requires a final exact opaque DMA-BUF image" {
    const NoopSource = struct {
        fn retain(_: *anyopaque) void {}
        fn release(_: *anyopaque) void {}
        fn begin(_: *anyopaque) bool {
            return true;
        }
        fn end(_: *anyopaque) bool {
            return true;
        }
        fn exportFence(_: *anyopaque, _: u8) ?std.posix.fd_t {
            return null;
        }
    };

    const size: render_types.Size = .{ .width = 2, .height = 2 };
    var target_pixels = [_]u32{0} ** 4;
    var source_context: u8 = 0;
    const source_buffer: render_types.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .dmabuf = .{
            .context = &source_context,
            .format = @intFromEnum(render_types.DmabufFormat.xrgb8888),
            .modifier = 0,
            .planes = .{
                .{
                    .fd = -1,
                    .stride = size.width * @sizeOf(u32),
                    .offset = 0,
                    .required_bytes = target_pixels.len * @sizeOf(u32),
                },
                .{},
                .{},
                .{},
            },
            .plane_count = 1,
            .y_inverted = false,
            .force_opaque = false,
            .retain = NoopSource.retain,
            .release = NoopSource.release,
            .begin_cpu_read = NoopSource.begin,
            .end_cpu_read = NoopSource.end,
            .export_read_fence = NoopSource.exportFence,
        },
        .source_cache = .{ .id = 1, .version = 1 },
    };
    const target: render_types.Target = .{ .pixels = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &target_pixels,
    } };
    const direct_commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = source_buffer,
            .is_opaque = true,
        } },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&direct_commands);
    try expectDirectScanoutCandidate(renderer.directScanoutCandidate());
    const overlay = try expectOverlayScanoutCandidate(renderer.overlayScanoutCandidate());
    try std.testing.expectEqual(
        render_types.Rect{ .x = 0, .y = 0, .width = 2, .height = 2 },
        overlay.destination,
    );
    try std.testing.expect(overlay.buffer.dmabuf.?.force_opaque);
    renderer.cancelFrame();

    var video_commands = direct_commands;
    video_commands[1].image.buffer.dmabuf.?.format = @intFromEnum(render_types.DmabufFormat.nv12);
    video_commands[1].image.buffer.dmabuf.?.plane_count = 2;
    video_commands[1].image.buffer.color_representation = .{
        .coefficients = .bt709,
        .range = .limited,
        .chroma_location = .type_0,
    };
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&video_commands);
    const video_overlay = try expectOverlayScanoutCandidate(renderer.overlayScanoutCandidate());
    try std.testing.expectEqual(@as(u8, 2), video_overlay.buffer.dmabuf.?.plane_count);
    renderer.cancelFrame();

    video_commands[1].image.buffer.color_representation.chroma_location = .type_1;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&video_commands);
    try expectOverlayScanoutRejection(.color_conversion, renderer.overlayScanoutCandidate());
    renderer.cancelFrame();

    const p3: render_types.ColorDescription = .{
        .primaries = render_types.display_p3_chromaticities,
        .named_primaries = .display_p3,
    };
    try renderer.beginFrame(target, .{}, .{}, null, p3);
    try renderer.append(&direct_commands);
    try expectDirectScanoutRejection(.color_conversion, renderer.directScanoutCandidate());
    try expectOverlayScanoutRejection(.color_conversion, renderer.overlayScanoutCandidate());
    renderer.cancelFrame();

    var matching_color_commands = direct_commands;
    matching_color_commands[1].image.buffer.color_description = p3;
    try renderer.beginFrame(target, .{}, .{}, null, p3);
    try renderer.append(&matching_color_commands);
    try expectDirectScanoutCandidate(renderer.directScanoutCandidate());
    renderer.cancelFrame();

    try renderer.beginFrame(target, .{}, .{}, null, p3);
    renderer.setOutputCalibration(.{
        .identity = 1,
        .edge_length = 33,
        .values = &.{},
    });
    try renderer.append(&matching_color_commands);
    try expectDirectScanoutRejection(.color_conversion, renderer.directScanoutCandidate());
    renderer.cancelFrame();

    const covered_commands = [_]render_types.Command{
        .{ .solid_rect = .{
            .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .color = render_types.Color.rgba(255, 255, 255, 255),
        } },
        direct_commands[1],
    };
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&covered_commands);
    try expectDirectScanoutCandidate(renderer.directScanoutCandidate());
    renderer.cancelFrame();

    var scaled_commands = direct_commands;
    scaled_commands[1].image.buffer.size = .{ .width = 3, .height = 3 };
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&scaled_commands);
    try expectDirectScanoutCandidate(renderer.directScanoutCandidate());
    try expectOverlayScanoutRejection(.scaled_surface, renderer.overlayScanoutCandidate());
    renderer.cancelFrame();

    var transparent_commands = direct_commands;
    transparent_commands[1].image.is_opaque = false;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&transparent_commands);
    try expectDirectScanoutRejection(.non_opaque_surface, renderer.directScanoutCandidate());
    try expectOverlayScanoutRejection(.non_opaque_surface, renderer.overlayScanoutCandidate());
    renderer.cancelFrame();

    var alpha_commands = direct_commands;
    alpha_commands[1].image.alpha_multiplier = 0x8000_0000;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&alpha_commands);
    try expectDirectScanoutRejection(.non_opaque_surface, renderer.directScanoutCandidate());
    renderer.cancelFrame();

    var transformed_commands = direct_commands;
    transformed_commands[1].image.transform = .rotate_90;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&transformed_commands);
    try expectDirectScanoutRejection(.surface_transform, renderer.directScanoutCandidate());
    try expectOverlayScanoutRejection(.transformed_surface, renderer.overlayScanoutCandidate());
    renderer.cancelFrame();

    var non_dmabuf_commands = direct_commands;
    non_dmabuf_commands[1].image.buffer.dmabuf = null;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&non_dmabuf_commands);
    try expectDirectScanoutRejection(.non_dmabuf, renderer.directScanoutCandidate());
    try expectOverlayScanoutRejection(.non_dmabuf, renderer.overlayScanoutCandidate());
    renderer.cancelFrame();

    var inverted_commands = direct_commands;
    inverted_commands[1].image.buffer.dmabuf.?.y_inverted = true;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&inverted_commands);
    try expectDirectScanoutRejection(.y_inverted, renderer.directScanoutCandidate());
    renderer.cancelFrame();

    var unidentified_commands = direct_commands;
    unidentified_commands[1].image.buffer.source_cache = null;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&unidentified_commands);
    try expectDirectScanoutRejection(.missing_buffer_identity, renderer.directScanoutCandidate());
    renderer.cancelFrame();

    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&direct_commands);
    try renderer.append(&.{.{ .solid_rect = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .color = render_types.Color.rgba(255, 255, 255, 255),
    } }});
    try expectDirectScanoutRejection(.no_fullscreen_surface, renderer.directScanoutCandidate());
    try expectOverlayScanoutRejection(.no_topmost_surface, renderer.overlayScanoutCandidate());
    renderer.cancelFrame();
}

fn expectDirectScanoutCandidate(candidate: render_types.DirectScanoutCandidate) !void {
    switch (candidate) {
        .candidate => {},
        .rejected => |reason| {
            std.debug.print("unexpected direct scanout rejection: {t}\n", .{reason});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectDirectScanoutRejection(
    expected: render_types.DirectScanoutRejection,
    candidate: render_types.DirectScanoutCandidate,
) !void {
    switch (candidate) {
        .candidate => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(expected, reason),
    }
}

fn expectOverlayScanoutCandidate(
    candidate: render_types.OverlayScanoutCandidate,
) !render_types.OverlayScanout {
    return switch (candidate) {
        .candidate => |overlay| overlay,
        .rejected => |reason| {
            std.debug.print("unexpected overlay scanout rejection: {t}\n", .{reason});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectOverlayScanoutRejection(
    expected: render_types.OverlayScanoutRejection,
    candidate: render_types.OverlayScanoutCandidate,
) !void {
    switch (candidate) {
        .candidate => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(expected, reason),
    }
}

test "validated overlay image is omitted from primary composition" {
    var target_pixels = [_]u32{0};
    var source_pixels = [_]u32{0xffffffff};
    const size: render_types.Size = .{ .width = 1, .height = 1 };
    const target: render_types.Target = .{ .pixels = .{
        .size = size,
        .stride_pixels = 1,
        .pixels = &target_pixels,
    } };
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = 1,
                .pixels = &source_pixels,
            },
            .is_opaque = true,
        } },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&commands);
    _ = try renderer.finishFrameScanoutWithoutTopmost(null);
    try std.testing.expectEqual(@as(u32, 0xff000000), target_pixels[0]);
}

test "renderer scales logical commands into a physical target" {
    const logical_size: render_types.Size = .{ .width = 2, .height = 2 };
    var output = try headless.init(std.testing.allocator, .{ .width = 3, .height = 3 });
    defer output.deinit();
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .color = render_types.Color.rgba(255, 0, 0, 255),
        } },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{ .size = logical_size, .commands = &commands, .scale = .{ .numerator = 180 } },
        output.target(),
    );

    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(1, 1));
    try std.testing.expectEqual(@as(u32, 0xffff0000), output.pixel(2, 1));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(2, 2));
}

test "renderer fills a physical target when fractional logical size is truncated" {
    var output = try headless.init(std.testing.allocator, .{ .width = 10, .height = 1 });
    defer output.deinit();
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(10, 20, 30, 255) },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{
            .size = .{ .width = 7, .height = 1 },
            .commands = &commands,
            .scale = .{ .numerator = 156 },
        },
        output.target(),
    );

    try std.testing.expectEqual(@as(u32, 0xff0a141e), output.pixel(9, 0));
}

test "renderer translates global commands into an output-local target" {
    const size: render_types.Size = .{ .width = 2, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 10, .y = -4, .width = 1, .height = 1 },
            .color = render_types.Color.rgba(255, 0, 0, 255),
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 11, .y = -4, .width = 1, .height = 1 },
            .color = render_types.Color.rgba(0, 255, 0, 255),
        } },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{
            .size = size,
            .commands = &commands,
            .origin = .{ .x = 10, .y = -4 },
        },
        output.target(),
    );

    try std.testing.expectEqual(@as(u32, 0xffff0000), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff00ff00), output.pixel(1, 0));
}

test "fractional rendering preserves an exact-scale tagged image" {
    var output = try headless.init(std.testing.allocator, .{ .width = 3, .height = 3 });
    defer output.deinit();
    var source_pixels = [_]u32{
        0xffff0000, 0xff00ff00, 0xff0000ff,
        0xffffffff, 0xff808080, 0xff000000,
        0xff102030, 0xff405060, 0xff708090,
    };
    const commands = [_]render_types.Command{
        .{ .image = .{
            .x = 10,
            .y = -4,
            .size = .{ .width = 2, .height = 2 },
            .buffer = .{
                .size = .{ .width = 3, .height = 3 },
                .stride_pixels = 3,
                .pixels = &source_pixels,
            },
            .sample_tag = 42,
        } },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{
            .size = .{ .width = 2, .height = 2 },
            .commands = &commands,
            .scale = .{ .numerator = 180 },
            .origin = .{ .x = 10, .y = -4 },
        },
        output.target(),
    );

    try std.testing.expectEqualSlices(u32, &source_pixels, output.target().pixels);
    try std.testing.expect(renderer.wasSampled(42));
}

test "fractional rendering scales rounded clips independently from images" {
    var source_pixels = [_]u32{0xffffffff} ** 16;
    const scaled = scaleCommand(.{ .image = .{
        .x = 0,
        .y = 0,
        .size = .{ .width = 4, .height = 4 },
        .buffer = .{
            .size = .{ .width = 4, .height = 4 },
            .stride_pixels = 4,
            .pixels = &source_pixels,
        },
        .rounded_clip = .{
            .rect = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
            .radius = 1,
        },
    } }, .{ .numerator = 180 });

    try std.testing.expectEqual(render_types.Rect{
        .x = 2,
        .y = 2,
        .width = 3,
        .height = 3,
    }, scaled.image.rounded_clip.?.rect);
    try std.testing.expectEqual(@as(u32, 2), scaled.image.rounded_clip.?.radius);
}
