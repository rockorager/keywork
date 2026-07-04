//! Experimental Wayland/Vulkan render backend.

const std = @import("std");
const event_loop = @import("event_loop.zig");
const keywork = @import("core.zig");
const TextRenderer = @import("text_renderer.zig");
const WaylandInput = @import("wayland_input.zig");
const wayland = @import("wayland");
const vk = @import("vulkan");

const linux = std.os.linux;
const wp = wayland.client.wp;
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const log = std.log.scoped(.keywork_wayland_vulkan);

extern fn vkGetInstanceProcAddr(instance: vk.Instance, p_name: [*:0]const u8) vk.PfnVoidFunction;

const atlas_width = 1024;
const atlas_height = 1024;
const atlas_padding = 1;
const initial_staging_capacity = atlas_width * atlas_height;

const GpuBuffer = struct {
    buffer: vk.Buffer = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    size: vk.DeviceSize = 0,
};

const GpuImage = struct {
    image: vk.Image = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    view: vk.ImageView = .null_handle,
    layout: vk.ImageLayout = .undefined,
};

const AtlasKey = struct {
    font_id: u32,
    pixel_size: u31,
    glyph_index: u32,
};

const AtlasSlot = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

const TextVertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

const PushConstants = extern struct {
    viewport: [2]f32,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: *wl.Compositor,
    wm_base: *xdg.WmBase,
    viewporter: ?*wp.Viewporter,
    fractional_scale_manager: ?*wp.FractionalScaleManagerV1,
    cursor_shape_manager: ?*wp.CursorShapeManagerV1,
    input: WaylandInput,
    surface: *wl.Surface,
    viewport: ?*wp.Viewport,
    fractional_scale: ?*wp.FractionalScaleV1,
    xdg_surface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    text_renderer: TextRenderer,
    configured: bool,
    closed: bool,
    width: u31,
    height: u31,
    scale: f32,
    scale_changed: bool,
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
    atlas_sampler: vk.Sampler,
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
    render_finished: vk.Semaphore,
    in_flight: vk.Fence,

    repaint_handler: ?RepaintHandler,
    repaint_context: ?*anyopaque,
    frame_handler: ?FrameHandler,
    frame_context: ?*anyopaque,
    frame_callback: ?*wl.Callback,

    pub const ClickHandler = WaylandInput.ClickHandler;
    pub const PointerMoveHandler = WaylandInput.PointerMoveHandler;
    pub const CursorShapeHandler = WaylandInput.CursorShapeHandler;
    pub const KeyHandler = WaylandInput.KeyHandler;
    pub const RepaintHandler = *const fn (ctx: *anyopaque, size: keywork.Size) void;
    pub const FrameHandler = *const fn (ctx: *anyopaque) void;

    pub const Options = struct {
        title: [:0]const u8 = "Keywork Vulkan",
        app_id: [:0]const u8 = "dev.keywork.Keywork",
        width: u31 = 640,
        height: u31 = 480,
    };

    const Globals = struct {
        compositor: ?*wl.Compositor = null,
        wm_base: ?*xdg.WmBase = null,
        viewporter: ?*wp.Viewporter = null,
        fractional_scale_manager: ?*wp.FractionalScaleManagerV1 = null,
        cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
        seat: ?*wl.Seat = null,
    };

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Backend {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();

        const registry = try display.getRegistry();
        var globals: Globals = .{};
        registry.setListener(*Globals, registryListener, &globals);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const compositor = globals.compositor orelse return error.NoWlCompositor;
        const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
        const viewporter = globals.viewporter;
        const fractional_scale_manager = globals.fractional_scale_manager;
        const cursor_shape_manager = globals.cursor_shape_manager;
        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const xdg_surface = try wm_base.getXdgSurface(surface);
        errdefer xdg_surface.destroy();
        const toplevel = try xdg_surface.getToplevel();
        errdefer toplevel.destroy();
        toplevel.setAppId(options.app_id);
        toplevel.setTitle(options.title);
        const viewport = if (viewporter) |manager| try manager.getViewport(surface) else null;
        errdefer if (viewport) |surface_viewport| surface_viewport.destroy();
        const fractional_scale = if (fractional_scale_manager) |manager| try manager.getFractionalScale(surface) else null;
        errdefer if (fractional_scale) |surface_scale| surface_scale.destroy();

        var text_renderer_instance = try TextRenderer.init(allocator);
        errdefer text_renderer_instance.deinit();
        var input = try WaylandInput.init(globals.seat, cursor_shape_manager);
        errdefer input.deinit();

        const vkb = vk.BaseWrapper.load(vkGetInstanceProcAddr);
        const instance_extensions = [_][*:0]const u8{
            vk.extensions.khr_surface.name,
            vk.extensions.khr_wayland_surface.name,
        };
        const app_info: vk.ApplicationInfo = .{
            .p_application_name = "Keywork",
            .application_version = vk.makeApiVersion(0, 0, 0, 0).toU32(),
            .p_engine_name = "Keywork",
            .engine_version = vk.makeApiVersion(0, 0, 0, 0).toU32(),
            .api_version = vk.API_VERSION_1_0.toU32(),
        };
        const instance = try vkb.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_extension_count = instance_extensions.len,
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
        const device_extension_names = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
        const queue_priority: f32 = 1.0;
        const queue_create_info: vk.DeviceQueueCreateInfo = .{
            .queue_family_index = selection.queue_family_index,
            .queue_count = 1,
            .p_queue_priorities = @ptrCast(&queue_priority),
        };
        const device = try vki.createDevice(selection.physical_device, &.{
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_create_info),
            .enabled_extension_count = device_extension_names.len,
            .pp_enabled_extension_names = &device_extension_names,
        }, null);

        const vkd = vk.DeviceWrapper.load(device, vki.dispatch.vkGetDeviceProcAddr.?);
        errdefer vkd.destroyDevice(device, null);
        const queue = vkd.getDeviceQueue(device, selection.queue_family_index, 0);
        const command_pool = try vkd.createCommandPool(device, &.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = selection.queue_family_index,
        }, null);
        errdefer vkd.destroyCommandPool(device, command_pool, null);

        var command_buffer: vk.CommandBuffer = undefined;
        try vkd.allocateCommandBuffers(device, &.{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer));

        const image_available = try vkd.createSemaphore(device, &.{}, null);
        errdefer vkd.destroySemaphore(device, image_available, null);
        const render_finished = try vkd.createSemaphore(device, &.{}, null);
        errdefer vkd.destroySemaphore(device, render_finished, null);
        const in_flight = try vkd.createFence(device, &.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer vkd.destroyFence(device, in_flight, null);

        const self = try allocator.create(Backend);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .compositor = compositor,
            .wm_base = wm_base,
            .viewporter = viewporter,
            .fractional_scale_manager = fractional_scale_manager,
            .cursor_shape_manager = cursor_shape_manager,
            .input = input,
            .surface = surface,
            .viewport = viewport,
            .fractional_scale = fractional_scale,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .text_renderer = text_renderer_instance,
            .configured = false,
            .closed = false,
            .width = options.width,
            .height = options.height,
            .scale = 1,
            .scale_changed = false,
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
            .atlas_pen_x = atlas_padding,
            .atlas_pen_y = atlas_padding,
            .atlas_row_height = 0,
            .staging_buffer = .{},
            .staging_used = 0,
            .vertex_buffer = .{},
            .text_vertices = .empty,
            .command_pool = command_pool,
            .command_buffer = command_buffer,
            .image_available = image_available,
            .render_finished = render_finished,
            .in_flight = in_flight,
            .repaint_handler = null,
            .repaint_context = null,
            .frame_handler = null,
            .frame_context = null,
            .frame_callback = null,
        };

        wm_base.setListener(*Backend, wmBaseListener, self);
        xdg_surface.setListener(*Backend, xdgSurfaceListener, self);
        toplevel.setListener(*Backend, toplevelListener, self);
        if (fractional_scale) |surface_scale| surface_scale.setListener(*Backend, fractionalScaleListener, self);
        self.input.attachListeners(Backend, self);
        surface.commit();

        return self;
    }

    pub fn destroy(self: *Backend) void {
        self.vkd.deviceWaitIdle(self.device) catch {};
        if (self.frame_callback) |callback| callback.destroy();
        self.destroySwapchain();
        self.text_vertices.deinit(self.allocator);
        self.atlas_slots.deinit(self.allocator);
        self.vkd.destroyFence(self.device, self.in_flight, null);
        self.vkd.destroySemaphore(self.device, self.render_finished, null);
        self.vkd.destroySemaphore(self.device, self.image_available, null);
        self.vkd.destroyCommandPool(self.device, self.command_pool, null);
        self.vkd.destroyDevice(self.device, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface_khr, null);
        self.vki.destroyInstance(self.instance, null);
        self.text_renderer.deinit();
        self.input.deinit();
        if (self.fractional_scale) |fractional_scale| fractional_scale.destroy();
        if (self.viewport) |viewport| viewport.destroy();
        self.toplevel.destroy();
        self.xdg_surface.destroy();
        self.surface.destroy();
        if (self.cursor_shape_manager) |manager| manager.destroy();
        if (self.fractional_scale_manager) |manager| manager.destroy();
        if (self.viewporter) |viewporter| viewporter.destroy();
        self.wm_base.destroy();
        self.compositor.destroy();
        self.registry.destroy();
        self.display.disconnect();
        self.allocator.destroy(self);
    }

    pub fn renderBackend(self: *Backend) keywork.RenderBackend {
        return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText } };
    }

    pub fn setClickHandler(self: *Backend, context: *anyopaque, handler: ClickHandler) void {
        self.input.setClickHandler(context, handler);
    }

    pub fn setPointerMoveHandler(self: *Backend, context: *anyopaque, handler: PointerMoveHandler) void {
        self.input.setPointerMoveHandler(context, handler);
    }

    pub fn setCursorShapeHandler(self: *Backend, context: *anyopaque, handler: CursorShapeHandler) void {
        self.input.setCursorShapeHandler(context, handler);
    }

    pub fn setKeyHandler(self: *Backend, context: *anyopaque, handler: KeyHandler) void {
        self.input.setKeyHandler(context, handler);
    }

    pub fn installKeyRepeat(self: *Backend, loop: *event_loop.EventLoop) !void {
        try self.input.installKeyRepeat(loop);
    }

    pub fn uninstallKeyRepeat(self: *Backend) void {
        self.input.uninstallKeyRepeat();
    }

    pub fn setRepaintHandler(self: *Backend, context: *anyopaque, handler: RepaintHandler) void {
        self.repaint_context = context;
        self.repaint_handler = handler;
    }

    pub fn setFrameHandler(self: *Backend, context: *anyopaque, handler: FrameHandler) void {
        self.frame_context = context;
        self.frame_handler = handler;
    }

    pub fn eventLoopFd(self: *Backend) i32 {
        return self.display.getFd();
    }

    pub fn eventLoopPrepare(ctx: *anyopaque) !u32 {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        while (!self.display.prepareRead()) {
            if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }

        return switch (self.display.flush()) {
            .SUCCESS => linux.EPOLL.IN,
            .AGAIN => linux.EPOLL.IN | linux.EPOLL.OUT,
            else => {
                self.display.cancelRead();
                return error.FlushFailed;
            },
        };
    }

    pub fn eventLoopFinish(ctx: *anyopaque, events: u32) !bool {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        if (events & linux.EPOLL.IN != 0) {
            if (self.display.readEvents() != .SUCCESS) return error.ReadEventsFailed;
        } else {
            self.display.cancelRead();
        }

        if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        if (self.scale_changed) {
            self.scale_changed = false;
            self.notifyRepaint();
        }
        return !self.closed;
    }

    fn present(ptr: *anyopaque, frame: keywork.RenderBackend.Frame) !bool {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        while (!self.configured and !self.closed) {
            if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        if (self.closed) return error.WindowClosed;

        const logical_width = try frameLogicalWidth(frame, self.width);
        const logical_height = try frameLogicalHeight(frame, self.height);
        const width = try scaledFrameDimension(logical_width, self.scale);
        const height = try scaledFrameDimension(logical_height, self.scale);
        self.surface.setBufferScale(1);
        if (self.viewport) |viewport| viewport.setDestination(logical_width, logical_height);
        if (!try self.ensureSwapchain(width, height)) return false;
        try self.armFrameCallback();
        const result = try self.renderAndPresent(frame.display_list, self.scale);
        if (result == .stale) {
            self.swapchain_dirty = true;
            log.info("Vulkan swapchain stale; recreating on next repaint", .{});
            return false;
        }
        self.surface.commit();
        _ = self.display.flush();
        return true;
    }

    fn measureText(ptr: *anyopaque, value: []const u8) !keywork.Size {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        return self.text_renderer.measure(self.scale, value);
    }

    fn notifyRepaint(self: *Backend) void {
        if (self.repaint_handler) |handler| handler(self.repaint_context.?, .{
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(self.height),
        });
    }

    fn armFrameCallback(self: *Backend) !void {
        if (self.frame_callback != null) return;
        const callback = try self.surface.frame();
        callback.setListener(*Backend, frameListener, self);
        self.frame_callback = callback;
    }

    fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, self: *Backend) void {
        switch (event) {
            .done => {
                if (self.frame_callback == callback) self.frame_callback = null;
                callback.destroy();
                if (self.frame_handler) |handler| handler(self.frame_context.?);
            },
        }
    }

    fn ensureSwapchain(self: *Backend, width: u31, height: u31) !bool {
        if (!self.swapchain_dirty and self.swapchain != .null_handle and self.swapchain_extent.width == width and self.swapchain_extent.height == height) return true;
        try self.vkd.deviceWaitIdle(self.device);
        self.destroySwapchain();
        self.swapchain_dirty = false;

        const caps = try self.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface_khr);
        const formats = try self.vki.getPhysicalDeviceSurfaceFormatsAllocKHR(self.physical_device, self.surface_khr, self.allocator);
        defer self.allocator.free(formats);
        if (formats.len == 0) return error.NoSurfaceFormats;
        const surface_format = chooseSurfaceFormat(formats);

        const extent = chooseExtent(caps, width, height);
        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0) image_count = @min(image_count, caps.max_image_count);
        const usage: vk.ImageUsageFlags = .{ .transfer_dst_bit = true, .color_attachment_bit = true };
        if (!caps.supported_usage_flags.contains(usage)) return error.UnsupportedSwapchainUsage;

        if (extent.width == 0 or extent.height == 0) return false;
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
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = .fifo_khr,
            .clipped = .true,
        }, null);
        errdefer self.destroySwapchain();

        self.swapchain_images = try self.vkd.getSwapchainImagesAllocKHR(self.device, self.swapchain, self.allocator);
        self.swapchain_extent = extent;
        self.swapchain_format = surface_format.format;
        try self.createRenderTargets();
        try self.createTextResources();
        log.info("Vulkan swapchain {d}x{d} images={d}", .{ extent.width, extent.height, self.swapchain_images.len });
        return true;
    }

    fn destroySwapchain(self: *Backend) void {
        self.destroyTextResources();
        for (self.framebuffers) |framebuffer| self.vkd.destroyFramebuffer(self.device, framebuffer, null);
        if (self.framebuffers.len > 0) self.allocator.free(self.framebuffers);
        if (self.render_pass != .null_handle) self.vkd.destroyRenderPass(self.device, self.render_pass, null);
        for (self.swapchain_image_views) |view| self.vkd.destroyImageView(self.device, view, null);
        if (self.swapchain_image_views.len > 0) self.allocator.free(self.swapchain_image_views);
        if (self.swapchain_images.len > 0) self.allocator.free(self.swapchain_images);
        self.framebuffers = &.{};
        self.render_pass = .null_handle;
        self.swapchain_image_views = &.{};
        self.swapchain_images = &.{};
        if (self.swapchain != .null_handle) self.vkd.destroySwapchainKHR(self.device, self.swapchain, null);
        self.swapchain = .null_handle;
        self.swapchain_extent = .{ .width = 0, .height = 0 };
        self.swapchain_format = .undefined;
    }

    fn createRenderTargets(self: *Backend) !void {
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

    fn createTextResources(self: *Backend) !void {
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

        self.atlas = try self.createImage(
            .r8_unorm,
            atlas_width,
            atlas_height,
            .{ .transfer_dst_bit = true, .sampled_bit = true },
            .{ .device_local_bit = true },
        );
        self.atlas.view = try self.vkd.createImageView(self.device, &.{
            .image = self.atlas.image,
            .view_type = .@"2d",
            .format = .r8_unorm,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = colorSubresourceRange(),
        }, null);
        self.atlas_sampler = try self.vkd.createSampler(self.device, &.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
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

        self.staging_buffer = try self.createBuffer(
            initial_staging_capacity,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        try self.createTextPipeline();
    }

    fn destroyTextResources(self: *Backend) void {
        if (self.text_pipeline != .null_handle) self.vkd.destroyPipeline(self.device, self.text_pipeline, null);
        if (self.text_pipeline_layout != .null_handle) self.vkd.destroyPipelineLayout(self.device, self.text_pipeline_layout, null);
        if (self.text_descriptor_pool != .null_handle) self.vkd.destroyDescriptorPool(self.device, self.text_descriptor_pool, null);
        if (self.text_descriptor_set_layout != .null_handle) self.vkd.destroyDescriptorSetLayout(self.device, self.text_descriptor_set_layout, null);
        if (self.atlas_sampler != .null_handle) self.vkd.destroySampler(self.device, self.atlas_sampler, null);
        self.destroyImage(&self.atlas);
        self.destroyBuffer(&self.staging_buffer);
        self.destroyBuffer(&self.vertex_buffer);
        self.text_pipeline = .null_handle;
        self.text_pipeline_layout = .null_handle;
        self.text_descriptor_pool = .null_handle;
        self.text_descriptor_set_layout = .null_handle;
        self.text_descriptor_set = .null_handle;
        self.atlas_sampler = .null_handle;
        self.atlas_slots.clearRetainingCapacity();
        self.atlas_pen_x = atlas_padding;
        self.atlas_pen_y = atlas_padding;
        self.atlas_row_height = 0;
        self.staging_used = 0;
        self.text_vertices.clearRetainingCapacity();
    }

    fn createTextPipeline(self: *Backend) !void {
        const vert_module = try self.createShaderModule(@embedFile("shaders/text.vert.spv"));
        defer self.vkd.destroyShaderModule(self.device, vert_module, null);
        const frag_module = try self.createShaderModule(@embedFile("shaders/text.frag.spv"));
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
        const viewport: vk.Viewport = .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.swapchain_extent.width),
            .height = @floatFromInt(self.swapchain_extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        const scissor: vk.Rect2D = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        };
        const viewport_state: vk.PipelineViewportStateCreateInfo = .{
            .viewport_count = 1,
            .p_viewports = @ptrCast(&viewport),
            .scissor_count = 1,
            .p_scissors = @ptrCast(&scissor),
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
        const blend_attachment: vk.PipelineColorBlendAttachmentState = .{
            .blend_enable = .true,
            .src_color_blend_factor = .src_alpha,
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

    fn renderAndPresent(self: *Backend, display_list: []const keywork.PaintCommand, scale: f32) !PresentResult {
        _ = try self.vkd.waitForFences(self.device, &.{self.in_flight}, .true, std.math.maxInt(u64));

        const acquired = self.vkd.acquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.image_available, .null_handle) catch |err| switch (err) {
            error.OutOfDateKHR => return .stale,
            else => return err,
        };
        const suboptimal = acquired.result == .suboptimal_khr;
        const image_index = acquired.image_index;
        try self.vkd.resetCommandPool(self.device, self.command_pool, .{});
        try self.vkd.beginCommandBuffer(self.command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

        try self.prepareText(display_list, scale);

        const clear_value: vk.ClearValue = .{ .color = colorClearValue(self.swapchain_format, keywork.colors.panel) };
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

        self.renderFillRects(display_list, scale);
        self.drawText();

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
            .p_signal_semaphores = @ptrCast(&self.render_finished),
        }}, self.in_flight);

        const present_result = self.vkd.queuePresentKHR(self.queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain),
            .p_image_indices = @ptrCast(&image_index),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => return .stale,
            else => return err,
        };
        if (suboptimal or present_result == .suboptimal_khr) return .stale;
        return .presented;
    }

    fn renderFillRects(self: *Backend, display_list: []const keywork.PaintCommand, scale: f32) void {
        for (display_list) |command| {
            switch (command) {
                .fill_rect => |fill| {
                    const x0 = clampPixel(@floor(fill.rect.x * scale), self.swapchain_extent.width);
                    const y0 = clampPixel(@floor(fill.rect.y * scale), self.swapchain_extent.height);
                    const x1 = clampPixel(@ceil((fill.rect.x + fill.rect.width) * scale), self.swapchain_extent.width);
                    const y1 = clampPixel(@ceil((fill.rect.y + fill.rect.height) * scale), self.swapchain_extent.height);
                    if (x0 >= x1 or y0 >= y1) continue;

                    const attachment: vk.ClearAttachment = .{
                        .aspect_mask = .{ .color_bit = true },
                        .color_attachment = 0,
                        .clear_value = .{ .color = colorClearValue(self.swapchain_format, fill.color) },
                    };
                    const rect: vk.ClearRect = .{
                        .rect = .{
                            .offset = .{ .x = @intCast(x0), .y = @intCast(y0) },
                            .extent = .{ .width = x1 - x0, .height = y1 - y0 },
                        },
                        .base_array_layer = 0,
                        .layer_count = 1,
                    };
                    self.vkd.cmdClearAttachments(self.command_buffer, &.{attachment}, &.{rect});
                },
                .text => {},
            }
        }
    }

    fn prepareText(self: *Backend, display_list: []const keywork.PaintCommand, scale: f32) !void {
        self.text_vertices.clearRetainingCapacity();
        self.staging_used = 0;

        var glyphs: std.ArrayList(TextRenderer.PositionedGlyph) = .empty;
        defer glyphs.deinit(self.allocator);

        for (display_list) |command| {
            switch (command) {
                .text => |text| {
                    glyphs.clearRetainingCapacity();
                    try self.text_renderer.appendGlyphs(self.allocator, scale, text, &glyphs);
                    for (glyphs.items) |glyph| {
                        const slot = try self.ensureAtlasGlyph(glyph);
                        try self.appendGlyphVertices(glyph, slot);
                    }
                },
                .fill_rect => {},
            }
        }

        if (self.atlas.layout == .transfer_dst_optimal) {
            self.transitionAtlas(.transfer_dst_optimal, .shader_read_only_optimal);
            self.atlas.layout = .shader_read_only_optimal;
        }

        if (self.text_vertices.items.len > 0) try self.uploadTextVertices();
    }

    fn ensureAtlasGlyph(self: *Backend, glyph: TextRenderer.PositionedGlyph) !AtlasSlot {
        const key: AtlasKey = .{
            .font_id = glyph.font_id,
            .pixel_size = glyph.pixel_size,
            .glyph_index = glyph.glyph_index,
        };
        if (self.atlas_slots.get(key)) |slot| return slot;

        const slot = try self.allocateAtlasSlot(glyph.width, glyph.rows);
        errdefer _ = self.atlas_slots.remove(key);
        try self.atlas_slots.put(self.allocator, key, slot);

        if (self.atlas.layout != .transfer_dst_optimal) {
            self.transitionAtlas(self.atlas.layout, .transfer_dst_optimal);
            self.atlas.layout = .transfer_dst_optimal;
        }

        const coverage_size: vk.DeviceSize = @intCast(glyph.coverage.len);
        if (self.staging_used + coverage_size > self.staging_buffer.size) return error.GlyphUploadTooLarge;
        try self.writeBuffer(self.staging_buffer, self.staging_used, glyph.coverage);

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
        self.staging_used += coverage_size;
        return slot;
    }

    fn allocateAtlasSlot(self: *Backend, width: u32, height: u32) !AtlasSlot {
        if (width == 0 or height == 0) return error.EmptyGlyph;
        if (width + atlas_padding * 2 > atlas_width or height + atlas_padding * 2 > atlas_height) {
            log.err("glyph bitmap {d}x{d} exceeds atlas {d}x{d}", .{ width, height, atlas_width, atlas_height });
            return error.GlyphTooLarge;
        }

        if (self.atlas_pen_x + width + atlas_padding > atlas_width) {
            self.atlas_pen_x = atlas_padding;
            self.atlas_pen_y += self.atlas_row_height + atlas_padding;
            self.atlas_row_height = 0;
        }
        if (self.atlas_pen_y + height + atlas_padding > atlas_height) return error.GlyphAtlasFull;

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

    fn appendGlyphVertices(self: *Backend, glyph: TextRenderer.PositionedGlyph, slot: AtlasSlot) !void {
        const x0 = glyph.x;
        const y0 = glyph.y;
        const x1 = x0 + @as(f32, @floatFromInt(slot.width));
        const y1 = y0 + @as(f32, @floatFromInt(slot.height));
        const uv_left = @as(f32, @floatFromInt(slot.x)) / atlas_width;
        const uv_top = @as(f32, @floatFromInt(slot.y)) / atlas_height;
        const uv_right = @as(f32, @floatFromInt(slot.x + slot.width)) / atlas_width;
        const uv_bottom = @as(f32, @floatFromInt(slot.y + slot.height)) / atlas_height;
        const color = colorFloats(self.swapchain_format, glyph.color);

        try self.text_vertices.appendSlice(self.allocator, &.{
            .{ .pos = .{ x0, y0 }, .uv = .{ uv_left, uv_top }, .color = color },
            .{ .pos = .{ x1, y0 }, .uv = .{ uv_right, uv_top }, .color = color },
            .{ .pos = .{ x1, y1 }, .uv = .{ uv_right, uv_bottom }, .color = color },
            .{ .pos = .{ x0, y0 }, .uv = .{ uv_left, uv_top }, .color = color },
            .{ .pos = .{ x1, y1 }, .uv = .{ uv_right, uv_bottom }, .color = color },
            .{ .pos = .{ x0, y1 }, .uv = .{ uv_left, uv_bottom }, .color = color },
        });
    }

    fn uploadTextVertices(self: *Backend) !void {
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

    fn drawText(self: *Backend) void {
        if (self.text_vertices.items.len == 0) return;

        const push: PushConstants = .{ .viewport = .{
            @floatFromInt(self.swapchain_extent.width),
            @floatFromInt(self.swapchain_extent.height),
        } };
        self.vkd.cmdBindPipeline(self.command_buffer, .graphics, self.text_pipeline);
        self.vkd.cmdBindDescriptorSets(self.command_buffer, .graphics, self.text_pipeline_layout, 0, &.{self.text_descriptor_set}, null);
        self.vkd.cmdPushConstants(self.command_buffer, self.text_pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstants), &push);
        self.vkd.cmdBindVertexBuffers(self.command_buffer, 0, &.{self.vertex_buffer.buffer}, &.{0});
        self.vkd.cmdDraw(self.command_buffer, @intCast(self.text_vertices.items.len), 1, 0, 0);
    }

    fn createBuffer(self: *Backend, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags) !GpuBuffer {
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
        return .{ .buffer = buffer, .memory = memory, .size = size };
    }

    fn destroyBuffer(self: *Backend, buffer: *GpuBuffer) void {
        if (buffer.buffer != .null_handle) self.vkd.destroyBuffer(self.device, buffer.buffer, null);
        if (buffer.memory != .null_handle) self.vkd.freeMemory(self.device, buffer.memory, null);
        buffer.* = .{};
    }

    fn writeBuffer(self: *Backend, buffer: GpuBuffer, offset: vk.DeviceSize, bytes: []const u8) !void {
        if (offset + bytes.len > buffer.size) return error.BufferOverflow;
        const mapped = (try self.vkd.mapMemory(self.device, buffer.memory, offset, bytes.len, .{})) orelse return error.MapFailed;
        defer self.vkd.unmapMemory(self.device, buffer.memory);
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..bytes.len], bytes);
    }

    fn createImage(
        self: *Backend,
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

    fn destroyImage(self: *Backend, image: *GpuImage) void {
        if (image.view != .null_handle) self.vkd.destroyImageView(self.device, image.view, null);
        if (image.image != .null_handle) self.vkd.destroyImage(self.device, image.image, null);
        if (image.memory != .null_handle) self.vkd.freeMemory(self.device, image.memory, null);
        image.* = .{};
    }

    fn createShaderModule(self: *Backend, bytes: []const u8) !vk.ShaderModule {
        if (bytes.len % 4 != 0) return error.InvalidShaderCode;
        const words = try self.allocator.alloc(u32, bytes.len / 4);
        defer self.allocator.free(words);
        @memcpy(std.mem.sliceAsBytes(words), bytes);
        return self.vkd.createShaderModule(self.device, &.{
            .code_size = bytes.len,
            .p_code = words.ptr,
        }, null);
    }

    fn memoryTypeIndex(self: *Backend, type_bits: u32, required: vk.MemoryPropertyFlags) !u32 {
        var index: u32 = 0;
        while (index < self.memory_properties.memory_type_count) : (index += 1) {
            if ((type_bits & (@as(u32, 1) << @intCast(index))) == 0) continue;
            if (self.memory_properties.memory_types[index].property_flags.contains(required)) return index;
        }
        return error.NoSuitableMemoryType;
    }

    fn transitionAtlas(self: *Backend, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) void {
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

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
        switch (event) {
            .global => |global| {
                if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    globals.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
                } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                    globals.wm_base = registry.bind(global.name, xdg.WmBase, @min(global.version, 6)) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                    globals.viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.FractionalScaleManagerV1.interface.name) == .eq) {
                    globals.fractional_scale_manager = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.CursorShapeManagerV1.interface.name) == .eq) {
                    globals.cursor_shape_manager = registry.bind(global.name, wp.CursorShapeManagerV1, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                    globals.seat = registry.bind(global.name, wl.Seat, @min(global.version, 8)) catch return;
                }
            },
            .global_remove => {},
        }
    }

    fn fractionalScaleListener(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, self: *Backend) void {
        switch (event) {
            .preferred_scale => |preferred| {
                if (preferred.scale == 0) return;
                const scale = @as(f32, @floatFromInt(preferred.scale)) / 120.0;
                if (scale == self.scale) return;
                self.scale = scale;
                self.scale_changed = true;
                log.info("fractional scale {d}", .{scale});
            },
        }
    }

    fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Backend) void {
        switch (event) {
            .ping => |ping| wm_base.pong(ping.serial),
        }
    }

    fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, self: *Backend) void {
        switch (event) {
            .configure => |configure| {
                xdg_surface.ackConfigure(configure.serial);
                self.configured = true;
                self.notifyRepaint();
            },
        }
    }

    fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Backend) void {
        switch (event) {
            .configure => |configure| {
                if (configure.width > 0) self.width = @intCast(configure.width);
                if (configure.height > 0) self.height = @intCast(configure.height);
            },
            .close => self.closed = true,
            .configure_bounds => {},
            .wm_capabilities => {},
        }
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

fn chooseSurfaceFormat(formats: []const vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (formats) |format| {
        if (format.format == .b8g8r8a8_unorm and format.color_space == .srgb_nonlinear_khr) return format;
    }
    for (formats) |format| {
        if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) return format;
    }
    return formats[0];
}

fn chooseExtent(caps: vk.SurfaceCapabilitiesKHR, width: u31, height: u31) vk.Extent2D {
    if (caps.current_extent.width != std.math.maxInt(u32)) return caps.current_extent;
    return .{
        .width = std.math.clamp(@as(u32, width), caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(@as(u32, height), caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

fn frameLogicalWidth(frame: keywork.RenderBackend.Frame, fallback: u31) !u31 {
    const value = if (frame.size.width > 0) frame.size.width else @as(f32, @floatFromInt(fallback));
    return positiveU31(value);
}

fn frameLogicalHeight(frame: keywork.RenderBackend.Frame, fallback: u31) !u31 {
    const value = if (frame.size.height > 0) frame.size.height else @as(f32, @floatFromInt(fallback));
    return positiveU31(value);
}

fn scaledFrameDimension(logical_dimension: u31, scale: f32) !u31 {
    if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidScale;
    const value = @as(f32, @floatFromInt(logical_dimension)) * scale;
    return positiveU31(value);
}

fn positiveU31(value: f32) !u31 {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidFrameSize;
    const rounded = @ceil(value);
    if (rounded > @as(f32, @floatFromInt(std.math.maxInt(u31)))) return error.InvalidFrameSize;
    return @intFromFloat(rounded);
}

fn clampPixel(value: f32, limit: u32) u32 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    const max: f32 = @floatFromInt(limit);
    if (value >= max) return limit;
    return @intFromFloat(value);
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
