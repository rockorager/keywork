//! Vulkan GPU renderer for the Wayland backend.

const std = @import("std");
const keywork = @import("../../../ui.zig");
const TextRenderer = @import("../../../graphics/text.zig");
const wayland = @import("wayland");
const vk = @import("vulkan");

const wl = wayland.client.wl;

const log = std.log.scoped(.keywork_wayland_vulkan);

extern fn vkGetInstanceProcAddr(instance: vk.Instance, p_name: [*:0]const u8) vk.PfnVoidFunction;

const initial_atlas_size = 1024;
const max_atlas_size_cap = 8192;
const atlas_padding = 1;
const initial_staging_capacity = initial_atlas_size * initial_atlas_size;
const max_prepare_attempts = 8;
const frames_in_flight = 2;

const AtlasCapacityAction = union(enum) {
    grow: u32,
    reset,
};

fn atlasCapacityAction(current_size: u32, max_size: u32) AtlasCapacityAction {
    std.debug.assert(current_size <= max_size);
    if (current_size == max_size) return .reset;
    return .{ .grow = @min(current_size * 2, max_size) };
}

/// GPU resources cycled per in-flight frame so CPU recording of frame N
/// overlaps GPU execution of frame N-1.
const FrameResources = struct {
    command_pool: vk.CommandPool = .null_handle,
    command_buffer: vk.CommandBuffer = .null_handle,
    image_available: vk.Semaphore = .null_handle,
    in_flight: vk.Fence = .null_handle,
    staging_buffer: GpuBuffer = .{},
    vertex_buffer: GpuBuffer = .{},
};

const SwapchainResources = struct {
    swapchain: vk.SwapchainKHR,
    images: []vk.Image,
    image_views: []vk.ImageView,
    render_pass: vk.RenderPass,
    framebuffers: []vk.Framebuffer,
    render_finished_semaphores: []vk.Semaphore,
    present_fences: []vk.Fence,
    present_fence_pending: []bool,
};

const GpuBuffer = struct {
    buffer: vk.Buffer = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    mapped: ?*anyopaque = null,
    size: vk.DeviceSize = 0,
};

const GpuImage = struct {
    image: vk.Image = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    view: vk.ImageView = .null_handle,
    layout: vk.ImageLayout = .undefined,
};

const AtlasKey = union(enum) {
    glyph: Glyph,
    // Alpha and color images can share a display-list cache key (an SVG
    // painted both tinted and untinted), so the atlas must namespace them.
    color_image: u64,
    alpha_image: u64,
    solid,

    const Glyph = struct {
        font_id: u32,
        pixel_size: u31,
        glyph_index: u32,
        /// Subpixel bin baked into the rasterized coverage.
        subpixel: u2,
    };
};

/// Side length of the fully-opaque atlas block used to render solid
/// rectangles through the textured-quad pipeline.
const solid_block_size = 2;

const AtlasSlot = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Axis-aligned quad in pixel space with its atlas UV window.
const QuadBounds = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
};

/// Pixel-space clip bounds: x0/y0 inclusive, x1/y1 exclusive.
const ClipBounds = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    fn fromRect(rect: keywork.Rect, scale: f32) ClipBounds {
        return .{
            .x0 = rect.x * scale,
            .y0 = rect.y * scale,
            .x1 = (rect.x + rect.width) * scale,
            .y1 = (rect.y + rect.height) * scale,
        };
    }
};

/// Intersects the quad with the clip and remaps its UV window
/// proportionally, so clipping happens at vertex generation and the whole
/// display list stays a single ordered draw. Returns null when fully
/// clipped.
fn clipQuad(quad: QuadBounds, clip: ?ClipBounds) ?QuadBounds {
    const c = clip orelse return quad;
    const x0 = @max(quad.x0, c.x0);
    const y0 = @max(quad.y0, c.y0);
    const x1 = @min(quad.x1, c.x1);
    const y1 = @min(quad.y1, c.y1);
    if (x1 <= x0 or y1 <= y0) return null;

    const width = quad.x1 - quad.x0;
    const height = quad.y1 - quad.y0;
    const du = quad.uv_right - quad.uv_left;
    const dv = quad.uv_bottom - quad.uv_top;
    return .{
        .x0 = x0,
        .y0 = y0,
        .x1 = x1,
        .y1 = y1,
        .uv_left = quad.uv_left + (x0 - quad.x0) / width * du,
        .uv_top = quad.uv_top + (y0 - quad.y0) / height * dv,
        .uv_right = quad.uv_right - (quad.x1 - x1) / width * du,
        .uv_bottom = quad.uv_bottom - (quad.y1 - y1) / height * dv,
    };
}

const TextVertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

const PushConstants = extern struct {
    viewport: [2]f32,
};

pub const Renderer = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    text_renderer: TextRenderer,
    swapchain_dirty: bool,

    vkb: vk.BaseWrapper,
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    instance: vk.Instance,
    surface_khr: vk.SurfaceKHR,
    physical_device: vk.PhysicalDevice,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    device: vk.Device,
    queue_family_index: u32,
    queue: vk.Queue,
    swapchain_maintenance: bool,
    swapchain: vk.SwapchainKHR,
    swapchain_extent: vk.Extent2D,
    swapchain_format: vk.Format,
    swapchain_images: []vk.Image,
    swapchain_image_views: []vk.ImageView,
    render_pass: vk.RenderPass,
    framebuffers: []vk.Framebuffer,
    text_descriptor_set_layout: vk.DescriptorSetLayout,
    text_descriptor_pool: vk.DescriptorPool,
    text_descriptor_set: vk.DescriptorSet,
    text_pipeline_layout: vk.PipelineLayout,
    text_pipeline: vk.Pipeline,
    atlas: GpuImage,
    atlas_size: u32,
    max_atlas_size: u32,
    atlas_sampler: vk.Sampler,
    text_pipeline_format: vk.Format,
    atlas_slots: std.AutoHashMapUnmanaged(AtlasKey, AtlasSlot),
    atlas_pen_x: u32,
    atlas_pen_y: u32,
    atlas_row_height: u32,
    staging_buffer: GpuBuffer,
    staging_used: vk.DeviceSize,
    vertex_buffer: GpuBuffer,
    text_vertices: std.ArrayList(TextVertex),
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    image_available: vk.Semaphore,
    in_flight: vk.Fence,
    frames: [frames_in_flight]FrameResources,
    frame_index: usize,
    /// One per swapchain image: a per-frame present semaphore could still
    /// be pending when its frame slot is reused.
    render_finished_semaphores: []vk.Semaphore,
    present_fences: []vk.Fence,
    present_fence_pending: []bool,
    retired_swapchains: std.ArrayList(SwapchainResources),

    pub fn init(allocator: std.mem.Allocator, display: *wl.Display, surface: *wl.Surface) !Self {
        var text_renderer_instance = try TextRenderer.init(allocator);
        errdefer text_renderer_instance.deinit();

        const vkb = vk.BaseWrapper.load(vkGetInstanceProcAddr);
        const loader_api_version = if (vkb.dispatch.vkEnumerateInstanceVersion != null)
            try vkb.enumerateInstanceVersion()
        else
            vk.API_VERSION_1_0.toU32();
        const instance_api_version = @min(loader_api_version, vk.API_VERSION_1_1.toU32());
        const instance_extension_properties = try vkb.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
        defer allocator.free(instance_extension_properties);
        const surface_maintenance =
            hasExtension(instance_extension_properties, vk.extensions.khr_get_surface_capabilities_2.name) and
            hasExtension(instance_extension_properties, vk.extensions.ext_surface_maintenance_1.name);
        const instance_extensions = [_][*:0]const u8{
            vk.extensions.khr_surface.name,
            vk.extensions.khr_wayland_surface.name,
            vk.extensions.khr_get_surface_capabilities_2.name,
            vk.extensions.ext_surface_maintenance_1.name,
        };
        const instance_extension_count: u32 = if (surface_maintenance) instance_extensions.len else 2;
        const app_info: vk.ApplicationInfo = .{
            .p_application_name = "Keywork",
            .application_version = vk.makeApiVersion(0, 0, 0, 0).toU32(),
            .p_engine_name = "Keywork",
            .engine_version = vk.makeApiVersion(0, 0, 0, 0).toU32(),
            .api_version = instance_api_version,
        };
        const instance = try vkb.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_extension_count = instance_extension_count,
            .pp_enabled_extension_names = &instance_extensions,
        }, null);

        const vki = vk.InstanceWrapper.load(instance, vkb.dispatch.vkGetInstanceProcAddr.?);
        errdefer vki.destroyInstance(instance, null);
        const surface_khr = try vki.createWaylandSurfaceKHR(instance, &.{
            .display = @ptrCast(display),
            .surface = @ptrCast(surface),
        }, null);
        errdefer vki.destroySurfaceKHR(instance, surface_khr, null);

        const selection = try selectPhysicalDevice(allocator, vki, instance, surface_khr);
        const memory_properties = vki.getPhysicalDeviceMemoryProperties(selection.physical_device);
        const physical_device_properties = vki.getPhysicalDeviceProperties(selection.physical_device);
        const device_limits = physical_device_properties.limits;
        const extension_properties = try vki.enumerateDeviceExtensionPropertiesAlloc(selection.physical_device, null, allocator);
        defer allocator.free(extension_properties);
        var maintenance_features: vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT = .{};
        const can_query_extended_features = instance_api_version >= vk.API_VERSION_1_1.toU32() and
            physical_device_properties.api_version >= vk.API_VERSION_1_1.toU32();
        const has_maintenance_extension = surface_maintenance and can_query_extended_features and
            hasExtension(extension_properties, vk.extensions.ext_swapchain_maintenance_1.name);
        if (has_maintenance_extension) {
            var features: vk.PhysicalDeviceFeatures2 = .{ .features = .{} };
            features.p_next = @ptrCast(&maintenance_features);
            vki.getPhysicalDeviceFeatures2(selection.physical_device, &features);
        }
        const swapchain_maintenance = has_maintenance_extension and maintenance_features.swapchain_maintenance_1 == .true;
        var requested_maintenance_features: vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT = .{
            .swapchain_maintenance_1 = .true,
        };
        const device_extension_names = [_][*:0]const u8{
            vk.extensions.khr_swapchain.name,
            vk.extensions.ext_swapchain_maintenance_1.name,
        };
        const device_extension_count: u32 = if (swapchain_maintenance) device_extension_names.len else 1;
        const queue_priority: f32 = 1.0;
        const queue_create_info: vk.DeviceQueueCreateInfo = .{
            .queue_family_index = selection.queue_family_index,
            .queue_count = 1,
            .p_queue_priorities = @ptrCast(&queue_priority),
        };
        const device = try vki.createDevice(selection.physical_device, &.{
            .p_next = if (swapchain_maintenance) @ptrCast(&requested_maintenance_features) else null,
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_create_info),
            .enabled_extension_count = device_extension_count,
            .pp_enabled_extension_names = &device_extension_names,
        }, null);

        const vkd = vk.DeviceWrapper.load(device, vki.dispatch.vkGetDeviceProcAddr.?);
        errdefer vkd.destroyDevice(device, null);
        const queue = vkd.getDeviceQueue(device, selection.queue_family_index, 0);
        var frames: [frames_in_flight]FrameResources = @splat(.{});
        errdefer for (&frames) |*frame| {
            if (frame.in_flight != .null_handle) vkd.destroyFence(device, frame.in_flight, null);
            if (frame.image_available != .null_handle) vkd.destroySemaphore(device, frame.image_available, null);
            if (frame.command_pool != .null_handle) vkd.destroyCommandPool(device, frame.command_pool, null);
        };
        for (&frames) |*frame| {
            frame.command_pool = try vkd.createCommandPool(device, &.{
                .flags = .{ .reset_command_buffer_bit = true },
                .queue_family_index = selection.queue_family_index,
            }, null);
            try vkd.allocateCommandBuffers(device, &.{
                .command_pool = frame.command_pool,
                .level = .primary,
                .command_buffer_count = 1,
            }, @ptrCast(&frame.command_buffer));
            frame.image_available = try vkd.createSemaphore(device, &.{}, null);
            frame.in_flight = try vkd.createFence(device, &.{ .flags = .{ .signaled_bit = true } }, null);
        }

        return .{
            .allocator = allocator,
            .text_renderer = text_renderer_instance,
            .swapchain_dirty = false,
            .vkb = vkb,
            .vki = vki,
            .vkd = vkd,
            .instance = instance,
            .surface_khr = surface_khr,
            .physical_device = selection.physical_device,
            .memory_properties = memory_properties,
            .device = device,
            .queue_family_index = selection.queue_family_index,
            .queue = queue,
            .swapchain_maintenance = swapchain_maintenance,
            .swapchain = .null_handle,
            .swapchain_extent = .{ .width = 0, .height = 0 },
            .swapchain_format = .undefined,
            .swapchain_images = &.{},
            .swapchain_image_views = &.{},
            .render_pass = .null_handle,
            .framebuffers = &.{},
            .text_descriptor_set_layout = .null_handle,
            .text_descriptor_pool = .null_handle,
            .text_descriptor_set = .null_handle,
            .text_pipeline_layout = .null_handle,
            .text_pipeline = .null_handle,
            .atlas = .{},
            .atlas_sampler = .null_handle,
            .atlas_slots = .{},
            .atlas_size = initial_atlas_size,
            .max_atlas_size = @min(max_atlas_size_cap, device_limits.max_image_dimension_2d),
            .text_pipeline_format = .undefined,
            .atlas_pen_x = atlas_padding,
            .atlas_pen_y = atlas_padding,
            .atlas_row_height = 0,
            .staging_buffer = .{},
            .staging_used = 0,
            .vertex_buffer = .{},
            .text_vertices = .empty,
            .command_pool = frames[0].command_pool,
            .command_buffer = frames[0].command_buffer,
            .image_available = frames[0].image_available,
            .in_flight = frames[0].in_flight,
            .frames = frames,
            .frame_index = 0,
            .render_finished_semaphores = &.{},
            .present_fences = &.{},
            .present_fence_pending = &.{},
            .retired_swapchains = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.vkd.deviceWaitIdle(self.device) catch {};
        self.waitForPendingPresents() catch {};
        self.destroyTextResources();
        self.destroySwapchain();
        for (self.retired_swapchains.items) |*resources| self.destroySwapchainResources(resources);
        self.retired_swapchains.deinit(self.allocator);
        self.text_vertices.deinit(self.allocator);
        self.atlas_slots.deinit(self.allocator);
        for (&self.frames) |*frame| {
            self.vkd.destroyFence(self.device, frame.in_flight, null);
            self.vkd.destroySemaphore(self.device, frame.image_available, null);
            self.vkd.destroyCommandPool(self.device, frame.command_pool, null);
        }
        self.vkd.destroyDevice(self.device, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface_khr, null);
        self.vki.destroyInstance(self.instance, null);
        self.text_renderer.deinit();
    }

    fn waitForPendingPresents(self: *Self) !void {
        try self.waitForPendingPresentFences(self.present_fences, self.present_fence_pending);
        for (self.retired_swapchains.items) |resources| {
            try self.waitForPendingPresentFences(resources.present_fences, resources.present_fence_pending);
        }
    }

    fn waitForPendingPresentFences(self: *Self, fences: []const vk.Fence, pending: []const bool) !void {
        for (fences, pending) |fence, is_pending| {
            if (!is_pending) continue;
            _ = try self.vkd.waitForFences(self.device, &.{fence}, .true, std.math.maxInt(u64));
        }
    }

    pub fn present(self: *Self, display_list: []const keywork.PaintCommand, scale: f32, width: u31, height: u31) !bool {
        if (!try self.ensureSwapchain(width, height)) return false;
        const result = try self.renderAndPresent(display_list, scale);
        if (result == .stale) {
            self.swapchain_dirty = true;
            log.info("Vulkan swapchain stale; recreating on next repaint", .{});
            return false;
        }
        return true;
    }

    pub fn measureText(self: *Self, scale: f32, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
        return self.text_renderer.measure(scale, value, style);
    }

    pub fn textMetrics(self: *Self, scale: f32, font_size: f32) !keywork.TextMetrics {
        return self.text_renderer.metrics(scale, font_size);
    }

    fn ensureSwapchain(self: *Self, width: u31, height: u31) !bool {
        if (!self.swapchain_dirty and self.swapchain != .null_handle and self.swapchain_extent.width == width and self.swapchain_extent.height == height) return true;
        try self.reapRetiredSwapchains();

        const caps = try self.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface_khr);
        const formats = try self.vki.getPhysicalDeviceSurfaceFormatsAllocKHR(self.physical_device, self.surface_khr, self.allocator);
        defer self.allocator.free(formats);
        if (formats.len == 0) return error.NoSurfaceFormats;
        const surface_format = chooseSurfaceFormat(formats);
        const composite_alpha = chooseCompositeAlpha(caps.supported_composite_alpha);

        const extent = chooseExtent(caps, width, height);
        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0) image_count = @min(image_count, caps.max_image_count);
        const usage: vk.ImageUsageFlags = .{ .transfer_dst_bit = true, .color_attachment_bit = true };
        if (!caps.supported_usage_flags.contains(usage)) return error.UnsupportedSwapchainUsage;

        if (extent.width == 0 or extent.height == 0) return false;
        // Present fences let old WSI resources retire asynchronously. Fall
        // back to the present queue only on drivers without maintenance1, or
        // for the rare format change that also replaces the graphics pipeline.
        if (self.swapchain != .null_handle and
            (!self.swapchain_maintenance or self.swapchain_format != surface_format.format))
        {
            try self.vkd.queueWaitIdle(self.queue);
        }
        const old_swapchain = try self.retireSwapchain();
        self.swapchain = try self.vkd.createSwapchainKHR(self.device, &.{
            .surface = self.surface_khr,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = usage,
            .image_sharing_mode = .exclusive,
            .pre_transform = caps.current_transform,
            .composite_alpha = composite_alpha,
            .present_mode = .fifo_khr,
            .clipped = .true,
            .old_swapchain = old_swapchain,
        }, null);
        errdefer self.destroySwapchain();

        self.swapchain_images = try self.vkd.getSwapchainImagesAllocKHR(self.device, self.swapchain, self.allocator);
        self.swapchain_extent = extent;
        self.swapchain_format = surface_format.format;
        self.render_finished_semaphores = try self.allocator.alloc(vk.Semaphore, self.swapchain_images.len);
        @memset(self.render_finished_semaphores, .null_handle);
        for (self.render_finished_semaphores) |*semaphore| semaphore.* = try self.vkd.createSemaphore(self.device, &.{}, null);
        if (self.swapchain_maintenance) {
            self.present_fences = try self.allocator.alloc(vk.Fence, self.swapchain_images.len);
            @memset(self.present_fences, .null_handle);
            self.present_fence_pending = try self.allocator.alloc(bool, self.swapchain_images.len);
            @memset(self.present_fence_pending, false);
            for (self.present_fences) |*fence| fence.* = try self.vkd.createFence(self.device, &.{}, null);
        }
        try self.createRenderTargets();
        try self.ensureTextResources();
        try self.ensureTextPipeline();
        self.swapchain_dirty = false;
        try self.reapRetiredSwapchains();
        log.info("Vulkan swapchain {d}x{d} images={d}", .{ extent.width, extent.height, self.swapchain_images.len });
        return true;
    }

    fn destroySwapchain(self: *Self) void {
        var resources = self.takeSwapchain();
        self.destroySwapchainResources(&resources);
    }

    fn retireSwapchain(self: *Self) !vk.SwapchainKHR {
        if (self.swapchain == .null_handle) return .null_handle;
        const resources = self.currentSwapchainResources();
        try self.retired_swapchains.append(self.allocator, resources);
        self.resetCurrentSwapchain();
        return resources.swapchain;
    }

    fn reapRetiredSwapchains(self: *Self) !void {
        var index: usize = 0;
        while (index < self.retired_swapchains.items.len) {
            const resources = &self.retired_swapchains.items[index];
            var complete = true;
            for (resources.present_fences, resources.present_fence_pending) |fence, pending| {
                if (!pending) continue;
                if (try self.vkd.getFenceStatus(self.device, fence) == .not_ready) {
                    complete = false;
                    break;
                }
            }
            if (!complete) {
                index += 1;
                continue;
            }
            var retired = self.retired_swapchains.swapRemove(index);
            self.destroySwapchainResources(&retired);
        }
    }

    fn currentSwapchainResources(self: *Self) SwapchainResources {
        return .{
            .swapchain = self.swapchain,
            .images = self.swapchain_images,
            .image_views = self.swapchain_image_views,
            .render_pass = self.render_pass,
            .framebuffers = self.framebuffers,
            .render_finished_semaphores = self.render_finished_semaphores,
            .present_fences = self.present_fences,
            .present_fence_pending = self.present_fence_pending,
        };
    }

    fn takeSwapchain(self: *Self) SwapchainResources {
        const resources = self.currentSwapchainResources();
        self.resetCurrentSwapchain();
        return resources;
    }

    fn resetCurrentSwapchain(self: *Self) void {
        self.swapchain = .null_handle;
        self.swapchain_extent = .{ .width = 0, .height = 0 };
        self.swapchain_format = .undefined;
        self.swapchain_images = &.{};
        self.swapchain_image_views = &.{};
        self.render_pass = .null_handle;
        self.framebuffers = &.{};
        self.render_finished_semaphores = &.{};
        self.present_fences = &.{};
        self.present_fence_pending = &.{};
    }

    fn destroySwapchainResources(self: *Self, resources: *SwapchainResources) void {
        for (resources.framebuffers) |framebuffer| {
            if (framebuffer != .null_handle) self.vkd.destroyFramebuffer(self.device, framebuffer, null);
        }
        if (resources.framebuffers.len > 0) self.allocator.free(resources.framebuffers);
        if (resources.render_pass != .null_handle) self.vkd.destroyRenderPass(self.device, resources.render_pass, null);
        for (resources.render_finished_semaphores) |semaphore| {
            if (semaphore != .null_handle) self.vkd.destroySemaphore(self.device, semaphore, null);
        }
        if (resources.render_finished_semaphores.len > 0) self.allocator.free(resources.render_finished_semaphores);
        for (resources.present_fences) |fence| {
            if (fence != .null_handle) self.vkd.destroyFence(self.device, fence, null);
        }
        if (resources.present_fences.len > 0) self.allocator.free(resources.present_fences);
        if (resources.present_fence_pending.len > 0) self.allocator.free(resources.present_fence_pending);
        for (resources.image_views) |view| {
            if (view != .null_handle) self.vkd.destroyImageView(self.device, view, null);
        }
        if (resources.image_views.len > 0) self.allocator.free(resources.image_views);
        if (resources.images.len > 0) self.allocator.free(resources.images);
        if (resources.swapchain != .null_handle) self.vkd.destroySwapchainKHR(self.device, resources.swapchain, null);
        resources.* = undefined;
    }

    fn createRenderTargets(self: *Self) !void {
        const color_attachment: vk.AttachmentDescription = .{
            .format = self.swapchain_format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        };
        const color_attachment_ref: vk.AttachmentReference = .{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        };
        const subpass: vk.SubpassDescription = .{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment_ref),
        };
        const dependencies = [_]vk.SubpassDependency{
            .{
                .src_subpass = vk.SUBPASS_EXTERNAL,
                .dst_subpass = 0,
                .src_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_access_mask = .{ .color_attachment_write_bit = true },
            },
            .{
                .src_subpass = 0,
                .dst_subpass = vk.SUBPASS_EXTERNAL,
                .src_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_stage_mask = .{ .bottom_of_pipe_bit = true },
                .src_access_mask = .{ .color_attachment_write_bit = true },
            },
        };

        self.render_pass = try self.vkd.createRenderPass(self.device, &.{
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_attachment),
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = dependencies.len,
            .p_dependencies = &dependencies,
        }, null);

        self.swapchain_image_views = try self.allocator.alloc(vk.ImageView, self.swapchain_images.len);
        @memset(self.swapchain_image_views, .null_handle);
        for (self.swapchain_images, self.swapchain_image_views) |image, *view| {
            view.* = try self.vkd.createImageView(self.device, &.{
                .image = image,
                .view_type = .@"2d",
                .format = self.swapchain_format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, null);
        }

        self.framebuffers = try self.allocator.alloc(vk.Framebuffer, self.swapchain_image_views.len);
        @memset(self.framebuffers, .null_handle);
        for (self.swapchain_image_views, self.framebuffers) |view, *framebuffer| {
            framebuffer.* = try self.vkd.createFramebuffer(self.device, &.{
                .render_pass = self.render_pass,
                .attachment_count = 1,
                .p_attachments = @ptrCast(&view),
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .layers = 1,
            }, null);
        }
    }

    fn ensureTextResources(self: *Self) !void {
        if (self.text_descriptor_set_layout != .null_handle) return;
        const binding: vk.DescriptorSetLayoutBinding = .{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
        };
        self.text_descriptor_set_layout = try self.vkd.createDescriptorSetLayout(self.device, &.{
            .binding_count = 1,
            .p_bindings = @ptrCast(&binding),
        }, null);

        const push_range: vk.PushConstantRange = .{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(PushConstants),
        };
        self.text_pipeline_layout = try self.vkd.createPipelineLayout(self.device, &.{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&self.text_descriptor_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_range),
        }, null);

        try self.createAtlasImage();
        self.atlas_sampler = try self.vkd.createSampler(self.device, &.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0,
            .anisotropy_enable = .false,
            .max_anisotropy = 1,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .float_transparent_black,
            .unnormalized_coordinates = .false,
        }, null);

        const pool_size: vk.DescriptorPoolSize = .{ .type = .combined_image_sampler, .descriptor_count = 1 };
        self.text_descriptor_pool = try self.vkd.createDescriptorPool(self.device, &.{
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast(&pool_size),
        }, null);
        try self.vkd.allocateDescriptorSets(self.device, &.{
            .descriptor_pool = self.text_descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&self.text_descriptor_set_layout),
        }, @ptrCast(&self.text_descriptor_set));

        self.updateAtlasDescriptor();
    }

    fn createAtlasImage(self: *Self) !void {
        self.atlas = try self.createImage(
            .b8g8r8a8_unorm,
            self.atlas_size,
            self.atlas_size,
            .{ .transfer_dst_bit = true, .sampled_bit = true },
            .{ .device_local_bit = true },
        );
        self.atlas.view = try self.vkd.createImageView(self.device, &.{
            .image = self.atlas.image,
            .view_type = .@"2d",
            .format = .b8g8r8a8_unorm,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = colorSubresourceRange(),
        }, null);
        if (self.text_descriptor_set != .null_handle) self.updateAtlasDescriptor();
    }

    fn updateAtlasDescriptor(self: *Self) void {
        const image_info: vk.DescriptorImageInfo = .{
            .sampler = self.atlas_sampler,
            .image_view = self.atlas.view,
            .image_layout = .shader_read_only_optimal,
        };
        self.vkd.updateDescriptorSets(self.device, &.{.{
            .dst_set = self.text_descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&image_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, null);
    }

    fn ensureTextPipeline(self: *Self) !void {
        if (self.text_pipeline != .null_handle and self.text_pipeline_format == self.swapchain_format) return;
        if (self.text_pipeline != .null_handle) {
            self.vkd.destroyPipeline(self.device, self.text_pipeline, null);
            self.text_pipeline = .null_handle;
        }
        try self.createTextPipeline();
        self.text_pipeline_format = self.swapchain_format;
    }

    fn resetAtlasPacking(self: *Self) void {
        self.atlas_slots.clearRetainingCapacity();
        self.atlas_pen_x = atlas_padding;
        self.atlas_pen_y = atlas_padding;
        self.atlas_row_height = 0;
    }

    /// Grows the atlas when possible. At the device limit, forgets historical
    /// slots so the retry repacks only assets used by the current frame. Safe
    /// mid-frame because the aborted command buffer is reset before retrying.
    fn recoverAtlasCapacity(self: *Self, atlas_layout_before: vk.ImageLayout) !void {
        // The other in-flight frame may still sample the old image.
        var fences: [frames_in_flight]vk.Fence = undefined;
        for (&self.frames, 0..) |*frame, index| fences[index] = frame.in_flight;
        _ = try self.vkd.waitForFences(self.device, &fences, .true, std.math.maxInt(u64));
        switch (atlasCapacityAction(self.atlas_size, self.max_atlas_size)) {
            .grow => |new_size| {
                self.atlas_size = new_size;
                self.destroyImage(&self.atlas);
                try self.createAtlasImage();
                self.resetAtlasPacking();
                log.info("glyph atlas grown to {d}x{d}", .{ new_size, new_size });
            },
            .reset => {
                self.resetAtlasPacking();
                // prepareQuads may have recorded an unsubmitted transition
                // before discovering the overflow. Restore the layout the GPU
                // actually has so the retry records the correct transition.
                self.atlas.layout = atlas_layout_before;
                log.info("glyph atlas full at {d}x{d}; repacking current frame", .{ self.atlas_size, self.atlas_size });
            },
        }
    }

    /// Doubles the staging buffer after an upload overflow. The atlas image
    /// survives, but slots recorded by the aborted attempt were never
    /// uploaded, so packing restarts and the tracked layout is restored to
    /// the last value the GPU actually saw.
    fn growStaging(self: *Self, atlas_layout_before: vk.ImageLayout) !void {
        const new_size = @max(initial_staging_capacity, self.staging_buffer.size * 2);
        self.destroyBuffer(&self.staging_buffer);
        self.staging_buffer = try self.createBuffer(
            new_size,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        self.resetAtlasPacking();
        self.atlas.layout = atlas_layout_before;
        log.info("glyph staging buffer grown to {d} bytes", .{new_size});
    }

    fn destroyTextResources(self: *Self) void {
        if (self.text_pipeline != .null_handle) self.vkd.destroyPipeline(self.device, self.text_pipeline, null);
        if (self.text_pipeline_layout != .null_handle) self.vkd.destroyPipelineLayout(self.device, self.text_pipeline_layout, null);
        if (self.text_descriptor_pool != .null_handle) self.vkd.destroyDescriptorPool(self.device, self.text_descriptor_pool, null);
        if (self.text_descriptor_set_layout != .null_handle) self.vkd.destroyDescriptorSetLayout(self.device, self.text_descriptor_set_layout, null);
        if (self.atlas_sampler != .null_handle) self.vkd.destroySampler(self.device, self.atlas_sampler, null);
        self.destroyImage(&self.atlas);
        // The single staging/vertex fields are views of the active frame
        // slot; write them back and destroy each slot exactly once, or the
        // active slot's buffers would be freed twice.
        self.storeFrameViews();
        for (&self.frames) |*frame| {
            self.destroyBuffer(&frame.staging_buffer);
            self.destroyBuffer(&frame.vertex_buffer);
        }
        self.staging_buffer = .{};
        self.vertex_buffer = .{};
        self.text_pipeline = .null_handle;
        self.text_pipeline_layout = .null_handle;
        self.text_descriptor_pool = .null_handle;
        self.text_descriptor_set_layout = .null_handle;
        self.text_descriptor_set = .null_handle;
        self.atlas_sampler = .null_handle;
        self.text_pipeline_format = .undefined;
        self.resetAtlasPacking();
        self.staging_used = 0;
        self.text_vertices.clearRetainingCapacity();
    }

    fn createTextPipeline(self: *Self) !void {
        const vert_module = try self.createShaderModule(@embedFile("../shaders/text.vert.spv"));
        defer self.vkd.destroyShaderModule(self.device, vert_module, null);
        const frag_module = try self.createShaderModule(@embedFile("../shaders/text.frag.spv"));
        defer self.vkd.destroyShaderModule(self.device, frag_module, null);

        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = .{ .vertex_bit = true }, .module = vert_module, .p_name = "main" },
            .{ .stage = .{ .fragment_bit = true }, .module = frag_module, .p_name = "main" },
        };
        const binding: vk.VertexInputBindingDescription = .{
            .binding = 0,
            .stride = @sizeOf(TextVertex),
            .input_rate = .vertex,
        };
        const attributes = [_]vk.VertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(TextVertex, "pos") },
            .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(TextVertex, "uv") },
            .{ .location = 2, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(TextVertex, "color") },
        };
        const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&binding),
            .vertex_attribute_description_count = attributes.len,
            .p_vertex_attribute_descriptions = &attributes,
        };
        const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        };
        // Dynamic viewport/scissor keep the pipeline independent of the
        // swapchain extent, so resize never recreates it.
        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const dynamic_state: vk.PipelineDynamicStateCreateInfo = .{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };
        const viewport_state: vk.PipelineViewportStateCreateInfo = .{
            .viewport_count = 1,
            .scissor_count = 1,
        };
        const rasterization: vk.PipelineRasterizationStateCreateInfo = .{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .counter_clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };
        const multisample: vk.PipelineMultisampleStateCreateInfo = .{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };
        // Atlas texels and vertex colors are premultiplied: linear
        // filtering then interpolates without dark or white fringes.
        const blend_attachment: vk.PipelineColorBlendAttachmentState = .{
            .blend_enable = .true,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };
        const color_blend: vk.PipelineColorBlendStateCreateInfo = .{
            .logic_op_enable = .false,
            .logic_op = .clear,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&blend_attachment),
            .blend_constants = .{ 0, 0, 0, 0 },
        };

        var pipeline: vk.Pipeline = undefined;
        _ = try self.vkd.createGraphicsPipelines(self.device, .null_handle, &.{.{
            .stage_count = stages.len,
            .p_stages = &stages,
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &input_assembly,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterization,
            .p_multisample_state = &multisample,
            .p_color_blend_state = &color_blend,
            .p_dynamic_state = &dynamic_state,
            .layout = self.text_pipeline_layout,
            .render_pass = self.render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }}, null, @ptrCast(&pipeline));
        self.text_pipeline = pipeline;
    }

    const PresentResult = enum {
        presented,
        stale,
    };

    fn renderAndPresent(self: *Self, display_list: []const keywork.PaintCommand, scale: f32) !PresentResult {
        self.loadFrameViews();
        defer self.storeFrameViews();
        _ = try self.vkd.waitForFences(self.device, &.{self.in_flight}, .true, std.math.maxInt(u64));

        const acquired = self.vkd.acquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.image_available, .null_handle) catch |err| switch (err) {
            error.OutOfDateKHR => return .stale,
            else => return err,
        };
        const suboptimal = acquired.result == .suboptimal_khr;
        const image_index = acquired.image_index;
        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            const atlas_layout_before = self.atlas.layout;
            try self.vkd.resetCommandPool(self.device, self.command_pool, .{});
            try self.vkd.beginCommandBuffer(self.command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

            self.prepareQuads(display_list, scale) catch |err| switch (err) {
                error.GlyphAtlasFull => {
                    if (attempts >= max_prepare_attempts) return err;
                    try self.recoverAtlasCapacity(atlas_layout_before);
                    continue;
                },
                error.GlyphUploadTooLarge, error.ImageUploadTooLarge => {
                    if (attempts >= max_prepare_attempts) return err;
                    try self.growStaging(atlas_layout_before);
                    continue;
                },
                else => return err,
            };
            break;
        }

        const clear_value: vk.ClearValue = .{ .color = colorClearValue(self.swapchain_format, keywork.colors.transparent) };
        self.vkd.cmdBeginRenderPass(self.command_buffer, &.{
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapchain_extent,
            },
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear_value),
        }, .@"inline");

        self.drawQuads();

        self.vkd.cmdEndRenderPass(self.command_buffer);
        try self.vkd.endCommandBuffer(self.command_buffer);

        const wait_stage: vk.PipelineStageFlags = .{ .color_attachment_output_bit = true };
        try self.vkd.resetFences(self.device, &.{self.in_flight});
        try self.vkd.queueSubmit(self.queue, &.{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.image_available),
            .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&self.command_buffer),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&self.render_finished_semaphores[image_index]),
        }}, self.in_flight);

        var present_fence_info: vk.SwapchainPresentFenceInfoEXT = undefined;
        var present_info: vk.PresentInfoKHR = .{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.render_finished_semaphores[image_index]),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain),
            .p_image_indices = @ptrCast(&image_index),
        };
        if (self.swapchain_maintenance) {
            const fence = self.present_fences[image_index];
            if (self.present_fence_pending[image_index]) {
                // Reacquiring the image means its previous presentation is
                // complete; normally this wait only observes a signaled fence.
                _ = try self.vkd.waitForFences(self.device, &.{fence}, .true, std.math.maxInt(u64));
            }
            try self.vkd.resetFences(self.device, &.{fence});
            present_fence_info = .{
                .swapchain_count = 1,
                .p_fences = @ptrCast(&fence),
            };
            present_info.p_next = @ptrCast(&present_fence_info);
            self.present_fence_pending[image_index] = true;
        }
        const present_result = self.vkd.queuePresentKHR(self.queue, &present_info) catch |err| switch (err) {
            error.OutOfDateKHR => return .stale,
            else => return err,
        };
        self.storeFrameViews();
        self.frame_index = (self.frame_index + 1) % frames_in_flight;
        self.loadFrameViews();
        if (suboptimal or present_result == .suboptimal_khr) return .stale;
        return .presented;
    }

    /// The single command/sync/upload fields act as views of the active
    /// frame slot so the recording helpers stay slot-agnostic.
    fn loadFrameViews(self: *Self) void {
        const frame = &self.frames[self.frame_index];
        self.command_pool = frame.command_pool;
        self.command_buffer = frame.command_buffer;
        self.image_available = frame.image_available;
        self.in_flight = frame.in_flight;
        self.staging_buffer = frame.staging_buffer;
        self.vertex_buffer = frame.vertex_buffer;
    }

    fn storeFrameViews(self: *Self) void {
        const frame = &self.frames[self.frame_index];
        frame.staging_buffer = self.staging_buffer;
        frame.vertex_buffer = self.vertex_buffer;
    }

    /// Batches the display list into one ordered quad stream so painter's
    /// order is preserved: rasterization order guarantees per-pixel blending
    /// follows primitive order within a single draw.
    fn prepareQuads(self: *Self, display_list: []const keywork.PaintCommand, scale: f32) !void {
        self.text_vertices.clearRetainingCapacity();
        self.staging_used = 0;
        if (self.atlas.layout == .undefined) {
            self.transitionAtlas(.undefined, .transfer_dst_optimal);
            self.atlas.layout = .transfer_dst_optimal;
            const clear: vk.ClearColorValue = .{ .float_32 = .{ 0, 0, 0, 0 } };
            self.vkd.cmdClearColorImage(self.command_buffer, self.atlas.image, .transfer_dst_optimal, &clear, &.{colorSubresourceRange()});
        }
        if (self.staging_buffer.size == 0) {
            self.staging_buffer = try self.createBuffer(
                initial_staging_capacity,
                .{ .transfer_src_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
        }

        var glyphs: std.ArrayList(TextRenderer.PositionedGlyph) = .empty;
        defer glyphs.deinit(self.allocator);

        var clip: ?ClipBounds = null;
        for (display_list) |command| {
            switch (command) {
                .text => |text| {
                    glyphs.clearRetainingCapacity();
                    try self.text_renderer.appendGlyphs(self.allocator, scale, text, &glyphs);
                    for (glyphs.items) |glyph| {
                        const slot = try self.ensureAtlasGlyph(glyph);
                        try self.appendGlyphVertices(glyph, slot, clip);
                    }
                },
                .alpha_image => |image| {
                    const slot = try self.ensureAtlasImage(image);
                    try self.appendImageVertices(image, slot, scale, clip);
                },
                .fill_rect => |fill| {
                    const slot = try self.ensureSolidSlot();
                    try self.appendRectVertices(fill, slot, scale, clip);
                },
                .color_image => |image| {
                    const slot = try self.ensureAtlasColorImage(image);
                    try self.appendColorImageVertices(image, slot, scale, clip);
                },
                .set_clip => |rect| clip = if (rect) |value| ClipBounds.fromRect(value, scale) else null,
            }
        }

        if (self.atlas.layout == .transfer_dst_optimal) {
            self.transitionAtlas(.transfer_dst_optimal, .shader_read_only_optimal);
            self.atlas.layout = .shader_read_only_optimal;
        }

        if (self.text_vertices.items.len > 0) try self.uploadTextVertices();
    }

    fn ensureAtlasGlyph(self: *Self, glyph: TextRenderer.PositionedGlyph) !AtlasSlot {
        const key: AtlasKey = .{ .glyph = .{
            .font_id = glyph.font_id,
            .pixel_size = glyph.pixel_size,
            .glyph_index = glyph.glyph_index,
            .subpixel = glyph.subpixel,
        } };
        if (self.atlas_slots.get(key)) |slot| return slot;

        const slot = try self.allocateAtlasSlot(glyph.width, glyph.rows);
        errdefer _ = self.atlas_slots.remove(key);
        try self.atlas_slots.put(self.allocator, key, slot);

        self.prepareAtlasUpload();

        const coverage_size: vk.DeviceSize = if (glyph.channels == 4)
            @intCast(glyph.coverage.len)
        else
            @intCast(glyph.coverage.len * 4);
        if (self.staging_used + coverage_size > self.staging_buffer.size) return error.GlyphUploadTooLarge;
        if (glyph.channels == 4) {
            // Color glyphs are already premultiplied BGRA.
            try self.writeBuffer(self.staging_buffer, self.staging_used, glyph.coverage);
        } else {
            try self.stageMaskTexels(glyph.coverage);
        }

        self.copyStagingToAtlas(slot, coverage_size);
        return slot;
    }

    /// Writes an alpha coverage mask into staging as premultiplied-white
    /// BGRA texels, so a single atlas format serves masks and color images.
    fn stageMaskTexels(self: *Self, coverage: []const u8) !void {
        const texels = try self.allocator.alloc(u8, coverage.len * 4);
        defer self.allocator.free(texels);
        for (coverage, 0..) |value, index| {
            texels[index * 4 + 0] = value;
            texels[index * 4 + 1] = value;
            texels[index * 4 + 2] = value;
            texels[index * 4 + 3] = value;
        }
        try self.writeBuffer(self.staging_buffer, self.staging_used, texels);
    }

    /// Uploads a straight-alpha color image as premultiplied BGRA texels.
    fn ensureAtlasColorImage(self: *Self, image: keywork.PaintCommand.ColorImage) !AtlasSlot {
        if (image.width == 0 or image.height == 0) return error.EmptyImage;
        if (image.pixels.len != @as(usize, image.width) * @as(usize, image.height)) return error.InvalidImage;

        const key: AtlasKey = .{ .color_image = image.cache_key };
        if (self.atlas_slots.get(key)) |slot| return slot;

        const slot = try self.allocateAtlasSlot(image.width, image.height);
        errdefer _ = self.atlas_slots.remove(key);
        try self.atlas_slots.put(self.allocator, key, slot);

        self.prepareAtlasUpload();

        const image_size: vk.DeviceSize = @intCast(image.pixels.len * 4);
        if (self.staging_used + image_size > self.staging_buffer.size) return error.ImageUploadTooLarge;
        const texels = try self.allocator.alloc(u8, image.pixels.len * 4);
        defer self.allocator.free(texels);
        for (image.pixels, 0..) |pixel, index| {
            const alpha: u32 = pixel.a;
            texels[index * 4 + 0] = @intCast((@as(u32, pixel.b) * alpha + 127) / 255);
            texels[index * 4 + 1] = @intCast((@as(u32, pixel.g) * alpha + 127) / 255);
            texels[index * 4 + 2] = @intCast((@as(u32, pixel.r) * alpha + 127) / 255);
            texels[index * 4 + 3] = pixel.a;
        }
        try self.writeBuffer(self.staging_buffer, self.staging_used, texels);

        self.copyStagingToAtlas(slot, image_size);
        return slot;
    }

    fn ensureAtlasImage(self: *Self, image: keywork.PaintCommand.AlphaImage) !AtlasSlot {
        if (image.width == 0 or image.height == 0) return error.EmptyImage;
        if (image.alpha.len != @as(usize, image.width) * @as(usize, image.height)) return error.InvalidImage;

        const key: AtlasKey = .{ .alpha_image = image.cache_key };
        if (self.atlas_slots.get(key)) |slot| return slot;

        const slot = try self.allocateAtlasSlot(image.width, image.height);
        errdefer _ = self.atlas_slots.remove(key);
        try self.atlas_slots.put(self.allocator, key, slot);

        self.prepareAtlasUpload();

        const image_size: vk.DeviceSize = @intCast(image.alpha.len * 4);
        if (self.staging_used + image_size > self.staging_buffer.size) return error.ImageUploadTooLarge;
        try self.stageMaskTexels(image.alpha);

        self.copyStagingToAtlas(slot, image_size);
        return slot;
    }

    fn ensureSolidSlot(self: *Self) !AtlasSlot {
        const key: AtlasKey = .solid;
        if (self.atlas_slots.get(key)) |slot| return slot;

        const slot = try self.allocateAtlasSlot(solid_block_size, solid_block_size);
        errdefer _ = self.atlas_slots.remove(key);
        try self.atlas_slots.put(self.allocator, key, slot);

        self.prepareAtlasUpload();

        const coverage = [_]u8{0xff} ** (solid_block_size * solid_block_size);
        if (self.staging_used + coverage.len * 4 > self.staging_buffer.size) return error.ImageUploadTooLarge;
        try self.stageMaskTexels(&coverage);

        self.copyStagingToAtlas(slot, coverage.len * 4);
        return slot;
    }

    fn prepareAtlasUpload(self: *Self) void {
        if (self.atlas.layout == .transfer_dst_optimal) return;
        self.transitionAtlas(self.atlas.layout, .transfer_dst_optimal);
        self.atlas.layout = .transfer_dst_optimal;
    }

    fn copyStagingToAtlas(self: *Self, slot: AtlasSlot, size: vk.DeviceSize) void {
        const copy: vk.BufferImageCopy = .{
            .buffer_offset = self.staging_used,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = @intCast(slot.x), .y = @intCast(slot.y), .z = 0 },
            .image_extent = .{ .width = slot.width, .height = slot.height, .depth = 1 },
        };
        self.vkd.cmdCopyBufferToImage(self.command_buffer, self.staging_buffer.buffer, self.atlas.image, .transfer_dst_optimal, &.{copy});
        self.staging_used += size;
    }

    fn allocateAtlasSlot(self: *Self, width: u32, height: u32) !AtlasSlot {
        if (width == 0 or height == 0) return error.EmptyGlyph;
        if (width + atlas_padding * 2 > self.max_atlas_size or height + atlas_padding * 2 > self.max_atlas_size) {
            log.err("glyph bitmap {d}x{d} exceeds max atlas {d}x{d}", .{ width, height, self.max_atlas_size, self.max_atlas_size });
            return error.GlyphTooLarge;
        }
        if (width + atlas_padding * 2 > self.atlas_size or height + atlas_padding * 2 > self.atlas_size) return error.GlyphAtlasFull;

        if (self.atlas_pen_x + width + atlas_padding > self.atlas_size) {
            self.atlas_pen_x = atlas_padding;
            self.atlas_pen_y += self.atlas_row_height + atlas_padding;
            self.atlas_row_height = 0;
        }
        if (self.atlas_pen_y + height + atlas_padding > self.atlas_size) return error.GlyphAtlasFull;

        const slot: AtlasSlot = .{
            .x = self.atlas_pen_x,
            .y = self.atlas_pen_y,
            .width = width,
            .height = height,
        };
        self.atlas_pen_x += width + atlas_padding;
        self.atlas_row_height = @max(self.atlas_row_height, height);
        return slot;
    }

    fn appendGlyphVertices(self: *Self, glyph: TextRenderer.PositionedGlyph, slot: AtlasSlot, clip: ?ClipBounds) !void {
        // Color glyphs carry their own color; the tint must be identity.
        const tint: [4]f32 = if (glyph.channels == 4) .{ 1, 1, 1, 1 } else colorFloats(self.swapchain_format, glyph.color);
        try self.appendQuad(.{
            .x0 = glyph.x,
            .y0 = glyph.y,
            .x1 = glyph.x + @as(f32, @floatFromInt(slot.width)),
            .y1 = glyph.y + @as(f32, @floatFromInt(slot.height)),
            .uv_left = @as(f32, @floatFromInt(slot.x)) / @as(f32, @floatFromInt(self.atlas_size)),
            .uv_top = @as(f32, @floatFromInt(slot.y)) / @as(f32, @floatFromInt(self.atlas_size)),
            .uv_right = @as(f32, @floatFromInt(slot.x + slot.width)) / @as(f32, @floatFromInt(self.atlas_size)),
            .uv_bottom = @as(f32, @floatFromInt(slot.y + slot.height)) / @as(f32, @floatFromInt(self.atlas_size)),
        }, tint, clip);
    }

    fn appendImageVertices(self: *Self, image: keywork.PaintCommand.AlphaImage, slot: AtlasSlot, scale: f32, clip: ?ClipBounds) !void {
        const x0 = image.rect.x * scale;
        const y0 = image.rect.y * scale;
        try self.appendQuad(.{
            .x0 = x0,
            .y0 = y0,
            .x1 = x0 + @as(f32, @floatFromInt(slot.width)),
            .y1 = y0 + @as(f32, @floatFromInt(slot.height)),
            .uv_left = @as(f32, @floatFromInt(slot.x)) / @as(f32, @floatFromInt(self.atlas_size)),
            .uv_top = @as(f32, @floatFromInt(slot.y)) / @as(f32, @floatFromInt(self.atlas_size)),
            .uv_right = @as(f32, @floatFromInt(slot.x + slot.width)) / @as(f32, @floatFromInt(self.atlas_size)),
            .uv_bottom = @as(f32, @floatFromInt(slot.y + slot.height)) / @as(f32, @floatFromInt(self.atlas_size)),
        }, colorFloats(self.swapchain_format, image.color), clip);
    }

    fn appendRectVertices(self: *Self, fill: keywork.PaintCommand.FillRect, slot: AtlasSlot, scale: f32, clip: ?ClipBounds) !void {
        // Sample the center of the opaque block so no neighboring atlas
        // texel can bleed into the fill.
        const u = (@as(f32, @floatFromInt(slot.x)) + @as(f32, @floatFromInt(slot.width)) / 2) / @as(f32, @floatFromInt(self.atlas_size));
        const v = (@as(f32, @floatFromInt(slot.y)) + @as(f32, @floatFromInt(slot.height)) / 2) / @as(f32, @floatFromInt(self.atlas_size));
        try self.appendQuad(.{
            .x0 = fill.rect.x * scale,
            .y0 = fill.rect.y * scale,
            .x1 = (fill.rect.x + fill.rect.width) * scale,
            .y1 = (fill.rect.y + fill.rect.height) * scale,
            .uv_left = u,
            .uv_top = v,
            .uv_right = u,
            .uv_bottom = v,
        }, colorFloats(self.swapchain_format, fill.color), clip);
    }

    fn appendColorImageVertices(self: *Self, image: keywork.PaintCommand.ColorImage, slot: AtlasSlot, scale: f32, clip: ?ClipBounds) !void {
        const x0 = image.rect.x * scale;
        const y0 = image.rect.y * scale;
        try self.appendQuad(.{
            .x0 = x0,
            .y0 = y0,
            .x1 = x0 + @as(f32, @floatFromInt(slot.width)),
            .y1 = y0 + @as(f32, @floatFromInt(slot.height)),
            .uv_left = @as(f32, @floatFromInt(slot.x)) / @as(f32, @floatFromInt(self.atlas_size)),
            .uv_top = @as(f32, @floatFromInt(slot.y)) / @as(f32, @floatFromInt(self.atlas_size)),
            .uv_right = @as(f32, @floatFromInt(slot.x + slot.width)) / @as(f32, @floatFromInt(self.atlas_size)),
            .uv_bottom = @as(f32, @floatFromInt(slot.y + slot.height)) / @as(f32, @floatFromInt(self.atlas_size)),
        }, .{ 1, 1, 1, 1 }, clip);
    }

    fn appendQuad(self: *Self, bounds: QuadBounds, color: [4]f32, clip: ?ClipBounds) !void {
        if (bounds.x1 <= bounds.x0 or bounds.y1 <= bounds.y0) return;
        const quad = clipQuad(bounds, clip) orelse return;
        // Vertex colors are premultiplied to match the atlas and blending.
        const premultiplied: [4]f32 = .{ color[0] * color[3], color[1] * color[3], color[2] * color[3], color[3] };

        try self.text_vertices.appendSlice(self.allocator, &.{
            .{ .pos = .{ quad.x0, quad.y0 }, .uv = .{ quad.uv_left, quad.uv_top }, .color = premultiplied },
            .{ .pos = .{ quad.x1, quad.y0 }, .uv = .{ quad.uv_right, quad.uv_top }, .color = premultiplied },
            .{ .pos = .{ quad.x1, quad.y1 }, .uv = .{ quad.uv_right, quad.uv_bottom }, .color = premultiplied },
            .{ .pos = .{ quad.x0, quad.y0 }, .uv = .{ quad.uv_left, quad.uv_top }, .color = premultiplied },
            .{ .pos = .{ quad.x1, quad.y1 }, .uv = .{ quad.uv_right, quad.uv_bottom }, .color = premultiplied },
            .{ .pos = .{ quad.x0, quad.y1 }, .uv = .{ quad.uv_left, quad.uv_bottom }, .color = premultiplied },
        });
    }

    fn uploadTextVertices(self: *Self) !void {
        const bytes = std.mem.sliceAsBytes(self.text_vertices.items);
        if (self.vertex_buffer.size < bytes.len) {
            self.destroyBuffer(&self.vertex_buffer);
            self.vertex_buffer = try self.createBuffer(
                @max(bytes.len, 4096),
                .{ .vertex_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
        }
        try self.writeBuffer(self.vertex_buffer, 0, bytes);
    }

    fn drawQuads(self: *Self) void {
        if (self.text_vertices.items.len == 0) return;

        const push: PushConstants = .{ .viewport = .{
            @floatFromInt(self.swapchain_extent.width),
            @floatFromInt(self.swapchain_extent.height),
        } };
        self.vkd.cmdBindPipeline(self.command_buffer, .graphics, self.text_pipeline);
        self.vkd.cmdSetViewport(self.command_buffer, 0, &.{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.swapchain_extent.width),
            .height = @floatFromInt(self.swapchain_extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }});
        self.vkd.cmdSetScissor(self.command_buffer, 0, &.{.{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        }});
        self.vkd.cmdBindDescriptorSets(self.command_buffer, .graphics, self.text_pipeline_layout, 0, &.{self.text_descriptor_set}, null);
        self.vkd.cmdPushConstants(self.command_buffer, self.text_pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstants), &push);
        self.vkd.cmdBindVertexBuffers(self.command_buffer, 0, &.{self.vertex_buffer.buffer}, &.{0});
        self.vkd.cmdDraw(self.command_buffer, @intCast(self.text_vertices.items.len), 1, 0, 0);
    }

    fn createBuffer(self: *Self, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags) !GpuBuffer {
        const buffer = try self.vkd.createBuffer(self.device, &.{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        }, null);
        errdefer self.vkd.destroyBuffer(self.device, buffer, null);

        const requirements = self.vkd.getBufferMemoryRequirements(self.device, buffer);
        const memory = try self.vkd.allocateMemory(self.device, &.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.memoryTypeIndex(requirements.memory_type_bits, properties),
        }, null);
        errdefer self.vkd.freeMemory(self.device, memory, null);

        try self.vkd.bindBufferMemory(self.device, buffer, memory, 0);
        const mapped = if (properties.host_visible_bit)
            (try self.vkd.mapMemory(self.device, memory, 0, size, .{})) orelse return error.MapFailed
        else
            null;
        return .{ .buffer = buffer, .memory = memory, .mapped = mapped, .size = size };
    }

    fn destroyBuffer(self: *Self, buffer: *GpuBuffer) void {
        if (buffer.mapped != null) self.vkd.unmapMemory(self.device, buffer.memory);
        if (buffer.buffer != .null_handle) self.vkd.destroyBuffer(self.device, buffer.buffer, null);
        if (buffer.memory != .null_handle) self.vkd.freeMemory(self.device, buffer.memory, null);
        buffer.* = .{};
    }

    fn writeBuffer(self: *Self, buffer: GpuBuffer, offset: vk.DeviceSize, bytes: []const u8) !void {
        _ = self;
        if (offset + bytes.len > buffer.size) return error.BufferOverflow;
        const mapped = buffer.mapped orelse return error.BufferNotMapped;
        const start: usize = @intCast(offset);
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[start..][0..bytes.len], bytes);
    }

    fn createImage(
        self: *Self,
        format: vk.Format,
        width: u32,
        height: u32,
        usage: vk.ImageUsageFlags,
        properties: vk.MemoryPropertyFlags,
    ) !GpuImage {
        const image = try self.vkd.createImage(self.device, &.{
            .image_type = .@"2d",
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = usage,
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        errdefer self.vkd.destroyImage(self.device, image, null);

        const requirements = self.vkd.getImageMemoryRequirements(self.device, image);
        const memory = try self.vkd.allocateMemory(self.device, &.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.memoryTypeIndex(requirements.memory_type_bits, properties),
        }, null);
        errdefer self.vkd.freeMemory(self.device, memory, null);

        try self.vkd.bindImageMemory(self.device, image, memory, 0);
        return .{ .image = image, .memory = memory, .layout = .undefined };
    }

    fn destroyImage(self: *Self, image: *GpuImage) void {
        if (image.view != .null_handle) self.vkd.destroyImageView(self.device, image.view, null);
        if (image.image != .null_handle) self.vkd.destroyImage(self.device, image.image, null);
        if (image.memory != .null_handle) self.vkd.freeMemory(self.device, image.memory, null);
        image.* = .{};
    }

    fn createShaderModule(self: *Self, bytes: []const u8) !vk.ShaderModule {
        if (bytes.len % 4 != 0) return error.InvalidShaderCode;
        const words = try self.allocator.alloc(u32, bytes.len / 4);
        defer self.allocator.free(words);
        @memcpy(std.mem.sliceAsBytes(words), bytes);
        return self.vkd.createShaderModule(self.device, &.{
            .code_size = bytes.len,
            .p_code = words.ptr,
        }, null);
    }

    fn memoryTypeIndex(self: *Self, type_bits: u32, required: vk.MemoryPropertyFlags) !u32 {
        var index: u32 = 0;
        while (index < self.memory_properties.memory_type_count) : (index += 1) {
            if ((type_bits & (@as(u32, 1) << @intCast(index))) == 0) continue;
            if (self.memory_properties.memory_types[index].property_flags.contains(required)) return index;
        }
        return error.NoSuitableMemoryType;
    }

    fn transitionAtlas(self: *Self, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) void {
        const barrier: vk.ImageMemoryBarrier = .{
            .src_access_mask = accessMaskForLayout(old_layout),
            .dst_access_mask = accessMaskForLayout(new_layout),
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.atlas.image,
            .subresource_range = colorSubresourceRange(),
        };
        self.vkd.cmdPipelineBarrier(
            self.command_buffer,
            stageMaskForLayout(old_layout),
            stageMaskForLayout(new_layout),
            .{},
            null,
            null,
            &.{barrier},
        );
    }
};

const DeviceSelection = struct {
    physical_device: vk.PhysicalDevice,
    queue_family_index: u32,
};

fn selectPhysicalDevice(allocator: std.mem.Allocator, vki: vk.InstanceWrapper, instance: vk.Instance, surface: vk.SurfaceKHR) !DeviceSelection {
    const devices = try vki.enumeratePhysicalDevicesAlloc(instance, allocator);
    defer allocator.free(devices);
    for (devices) |physical_device| {
        const families = try vki.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, allocator);
        defer allocator.free(families);
        for (families, 0..) |family, index| {
            if (!family.queue_flags.graphics_bit) continue;
            const supported = try vki.getPhysicalDeviceSurfaceSupportKHR(physical_device, @intCast(index), surface);
            if (supported == .true) return .{ .physical_device = physical_device, .queue_family_index = @intCast(index) };
        }
    }
    return error.NoSuitableVulkanDevice;
}

fn hasExtension(properties: []const vk.ExtensionProperties, name: [:0]const u8) bool {
    for (properties) |property| {
        const property_name = std.mem.sliceTo(&property.extension_name, 0);
        if (std.mem.eql(u8, property_name, name)) return true;
    }
    return false;
}

fn chooseSurfaceFormat(formats: []const vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (formats) |format| {
        if (format.format == .b8g8r8a8_unorm and format.color_space == .srgb_nonlinear_khr) return format;
    }
    for (formats) |format| {
        if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) return format;
    }
    return formats[0];
}

fn chooseCompositeAlpha(supported: vk.CompositeAlphaFlagsKHR) vk.CompositeAlphaFlagsKHR {
    if (supported.pre_multiplied_bit_khr) return .{ .pre_multiplied_bit_khr = true };
    if (supported.post_multiplied_bit_khr) return .{ .post_multiplied_bit_khr = true };
    if (supported.inherit_bit_khr) return .{ .inherit_bit_khr = true };
    return .{ .opaque_bit_khr = true };
}

fn chooseExtent(caps: vk.SurfaceCapabilitiesKHR, width: u31, height: u31) vk.Extent2D {
    if (caps.current_extent.width != std.math.maxInt(u32)) return caps.current_extent;
    return .{
        .width = std.math.clamp(@as(u32, width), caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(@as(u32, height), caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

fn colorClearValue(format: vk.Format, color: keywork.Color) vk.ClearColorValue {
    const values = colorFloats(format, color);
    return .{ .float_32 = values };
}

fn colorFloats(format: vk.Format, color: keywork.Color) [4]f32 {
    const scale = 1.0 / 255.0;
    const red = @as(f32, @floatFromInt(color.r)) * scale;
    const green = @as(f32, @floatFromInt(color.g)) * scale;
    const blue = @as(f32, @floatFromInt(color.b)) * scale;
    return .{
        if (isSrgbFormat(format)) srgbToLinear(red) else red,
        if (isSrgbFormat(format)) srgbToLinear(green) else green,
        if (isSrgbFormat(format)) srgbToLinear(blue) else blue,
        @as(f32, @floatFromInt(color.a)) * scale,
    };
}

fn isSrgbFormat(format: vk.Format) bool {
    return switch (format) {
        .r8_srgb,
        .r8g8_srgb,
        .r8g8b8_srgb,
        .b8g8r8_srgb,
        .r8g8b8a8_srgb,
        .b8g8r8a8_srgb,
        .a8b8g8r8_srgb_pack32,
        => true,
        else => false,
    };
}

fn srgbToLinear(value: f32) f32 {
    if (value <= 0.04045) return value / 12.92;
    return std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

fn colorSubresourceRange() vk.ImageSubresourceRange {
    return .{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
}

fn accessMaskForLayout(layout: vk.ImageLayout) vk.AccessFlags {
    return switch (layout) {
        .transfer_dst_optimal => .{ .transfer_write_bit = true },
        .shader_read_only_optimal => .{ .shader_read_bit = true },
        else => .{},
    };
}

fn stageMaskForLayout(layout: vk.ImageLayout) vk.PipelineStageFlags {
    return switch (layout) {
        .transfer_dst_optimal => .{ .transfer_bit = true },
        .shader_read_only_optimal => .{ .fragment_shader_bit = true },
        else => .{ .top_of_pipe_bit = true },
    };
}

test "clipQuad intersects bounds and remaps uv window" {
    const quad: QuadBounds = .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 10,
        .y1 = 10,
        .uv_left = 0,
        .uv_top = 0,
        .uv_right = 1,
        .uv_bottom = 1,
    };

    const clipped = clipQuad(quad, .{ .x0 = 5, .y0 = 2.5, .x1 = 20, .y1 = 7.5 }).?;
    try std.testing.expectEqual(@as(f32, 5), clipped.x0);
    try std.testing.expectEqual(@as(f32, 2.5), clipped.y0);
    try std.testing.expectEqual(@as(f32, 10), clipped.x1);
    try std.testing.expectEqual(@as(f32, 7.5), clipped.y1);
    try std.testing.expectEqual(@as(f32, 0.5), clipped.uv_left);
    try std.testing.expectEqual(@as(f32, 0.25), clipped.uv_top);
    try std.testing.expectEqual(@as(f32, 1), clipped.uv_right);
    try std.testing.expectEqual(@as(f32, 0.75), clipped.uv_bottom);
}

test "clipQuad returns quad unchanged without clip" {
    const quad: QuadBounds = .{
        .x0 = 1,
        .y0 = 2,
        .x1 = 3,
        .y1 = 4,
        .uv_left = 0.1,
        .uv_top = 0.2,
        .uv_right = 0.3,
        .uv_bottom = 0.4,
    };
    try std.testing.expectEqual(quad, clipQuad(quad, null).?);
}

test "clipQuad culls quads fully outside the clip" {
    const quad: QuadBounds = .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 10,
        .y1 = 10,
        .uv_left = 0,
        .uv_top = 0,
        .uv_right = 1,
        .uv_bottom = 1,
    };
    try std.testing.expectEqual(@as(?QuadBounds, null), clipQuad(quad, .{ .x0 = 10, .y0 = 0, .x1 = 20, .y1 = 10 }));
}

test "atlas capacity grows to the device limit then resets" {
    try std.testing.expectEqual(AtlasCapacityAction{ .grow = 2048 }, atlasCapacityAction(1024, 8192));
    try std.testing.expectEqual(AtlasCapacityAction{ .grow = 5000 }, atlasCapacityAction(4096, 5000));
    try std.testing.expectEqual(AtlasCapacityAction.reset, atlasCapacityAction(8192, 8192));
}
