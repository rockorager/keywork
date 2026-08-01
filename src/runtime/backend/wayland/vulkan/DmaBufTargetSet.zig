//! Vulkan images exported as one-plane DMA-BUF render targets.
//!
//! This type owns only Vulkan and file-descriptor resources. Wayland object
//! creation and `wl_buffer` lifetime remain with the Wayring presenter.

const DmaBufTargetSet = @This();

const std = @import("std");
const vk = @import("vulkan");

pub const format: vk.Format = .b8g8r8a8_unorm;
pub const image_count = 3;

pub const Plane = struct {
    target_index: usize,
    fd: i32,
    width: u32,
    height: u32,
    offset: u32,
    stride: u32,
    modifier: u64,
};

pub const RenderTarget = struct {
    framebuffer: vk.Framebuffer,
    render_pass: vk.RenderPass,
    format: vk.Format,
    extent: vk.Extent2D,
};

const Target = struct {
    image: vk.Image = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    view: vk.ImageView = .null_handle,
    framebuffer: vk.Framebuffer = .null_handle,
    fence: vk.Fence = .null_handle,
    fd: i32 = -1,
    offset: u32 = 0,
    stride: u32 = 0,
};

allocator: std.mem.Allocator,
vkd: vk.DeviceWrapper,
device: vk.Device,
extent: vk.Extent2D,
modifier: u64,
render_pass: vk.RenderPass,
targets: []Target,

/// Returns modifiers in the driver's order after enforcing every property
/// needed by the UI render pass and one-plane DMA-BUF export.
pub fn queryModifiers(
    allocator: std.mem.Allocator,
    vki: vk.InstanceWrapper,
    physical_device: vk.PhysicalDevice,
) ![]u64 {
    var modifier_list: vk.DrmFormatModifierPropertiesListEXT = .{};
    var format_properties: vk.FormatProperties2 = .{ .format_properties = undefined };
    format_properties.p_next = &modifier_list;
    vki.getPhysicalDeviceFormatProperties2(physical_device, format, &format_properties);

    const properties = try allocator.alloc(
        vk.DrmFormatModifierPropertiesEXT,
        modifier_list.drm_format_modifier_count,
    );
    defer allocator.free(properties);
    modifier_list.p_drm_format_modifier_properties = properties.ptr;
    vki.getPhysicalDeviceFormatProperties2(physical_device, format, &format_properties);

    var modifiers: std.ArrayList(u64) = .empty;
    defer modifiers.deinit(allocator);
    for (properties) |property| {
        if (!supportsRenderTarget(property)) continue;
        if (!supportsExport(vki, physical_device, property.drm_format_modifier)) continue;
        try modifiers.append(allocator, property.drm_format_modifier);
    }
    return modifiers.toOwnedSlice(allocator);
}

pub fn init(
    allocator: std.mem.Allocator,
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    extent: vk.Extent2D,
    modifier: u64,
) !DmaBufTargetSet {
    if (extent.width == 0 or extent.height == 0) return error.EmptyTarget;

    var self: DmaBufTargetSet = .{
        .allocator = allocator,
        .vkd = vkd,
        .device = device,
        .extent = extent,
        .modifier = modifier,
        .render_pass = try createRenderPass(vkd, device),
        .targets = &.{},
    };
    errdefer self.deinit();

    self.targets = try allocator.alloc(Target, image_count);
    @memset(self.targets, .{});
    for (self.targets) |*target| {
        target.* = try createTarget(
            vkd,
            device,
            memory_properties,
            self.render_pass,
            extent,
            modifier,
        );
    }
    return self;
}

pub fn deinit(self: *DmaBufTargetSet) void {
    for (self.targets) |*target| destroyTarget(self.vkd, self.device, target);
    if (self.targets.len > 0) self.allocator.free(self.targets);
    if (self.render_pass != .null_handle) self.vkd.destroyRenderPass(self.device, self.render_pass, null);
    self.* = undefined;
}

pub fn len(self: *const DmaBufTargetSet) usize {
    return self.targets.len;
}

pub fn plane(self: *const DmaBufTargetSet, index: usize) Plane {
    const target = self.targets[index];
    return .{
        .target_index = index,
        .fd = target.fd,
        .width = self.extent.width,
        .height = self.extent.height,
        .offset = target.offset,
        .stride = target.stride,
        .modifier = self.modifier,
    };
}

pub fn renderTarget(self: *const DmaBufTargetSet, index: usize) RenderTarget {
    return .{
        .framebuffer = self.targets[index].framebuffer,
        .render_pass = self.render_pass,
        .format = format,
        .extent = self.extent,
    };
}

pub fn fence(self: *const DmaBufTargetSet, index: usize) vk.Fence {
    return self.targets[index].fence;
}

/// Releases a fully rendered image to the compositor. The render pass clears
/// the complete image from `UNDEFINED`, so reacquisition can discard prior
/// contents rather than preserving a foreign-owned layout.
pub fn recordForeignRelease(
    self: *const DmaBufTargetSet,
    command_buffer: vk.CommandBuffer,
    index: usize,
    queue_family_index: u32,
) void {
    const barrier: vk.ImageMemoryBarrier = .{
        .src_access_mask = .{ .color_attachment_write_bit = true },
        .dst_access_mask = .{},
        .old_layout = .color_attachment_optimal,
        .new_layout = .general,
        .src_queue_family_index = queue_family_index,
        .dst_queue_family_index = vk.QUEUE_FAMILY_FOREIGN_EXT,
        .image = self.targets[index].image,
        .subresource_range = colorSubresourceRange(),
    };
    self.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .color_attachment_output_bit = true },
        .{ .bottom_of_pipe_bit = true },
        .{},
        null,
        null,
        &.{barrier},
    );
}

fn supportsRenderTarget(property: vk.DrmFormatModifierPropertiesEXT) bool {
    const features = property.drm_format_modifier_tiling_features;
    return property.drm_format_modifier_plane_count == 1 and
        features.color_attachment_bit and features.color_attachment_blend_bit;
}

fn supportsExport(
    vki: vk.InstanceWrapper,
    physical_device: vk.PhysicalDevice,
    modifier: u64,
) bool {
    const modifier_info: vk.PhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .drm_format_modifier = modifier,
        .sharing_mode = .exclusive,
    };
    const external_info: vk.PhysicalDeviceExternalImageFormatInfo = .{
        .p_next = &modifier_info,
        .handle_type = .{ .dma_buf_bit_ext = true },
    };
    const image_info: vk.PhysicalDeviceImageFormatInfo2 = .{
        .p_next = &external_info,
        .format = format,
        .type = .@"2d",
        .tiling = .drm_format_modifier_ext,
        .usage = .{ .color_attachment_bit = true },
    };
    var external_properties: vk.ExternalImageFormatProperties = .{
        .external_memory_properties = undefined,
    };
    var properties: vk.ImageFormatProperties2 = .{
        .p_next = &external_properties,
        .image_format_properties = undefined,
    };
    vki.getPhysicalDeviceImageFormatProperties2(
        physical_device,
        &image_info,
        &properties,
    ) catch return false;
    const external = external_properties.external_memory_properties;
    return external.external_memory_features.exportable_bit and
        external.compatible_handle_types.dma_buf_bit_ext;
}

fn createRenderPass(vkd: vk.DeviceWrapper, device: vk.Device) !vk.RenderPass {
    const attachment: vk.AttachmentDescription = .{
        .format = format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .color_attachment_optimal,
    };
    const attachment_ref: vk.AttachmentReference = .{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };
    const subpass: vk.SubpassDescription = .{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&attachment_ref),
    };
    const dependency: vk.SubpassDependency = .{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .top_of_pipe_bit = true },
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
    };
    return vkd.createRenderPass(device, &.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 1,
        .p_dependencies = @ptrCast(&dependency),
    }, null);
}

fn createTarget(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    render_pass: vk.RenderPass,
    extent: vk.Extent2D,
    modifier: u64,
) !Target {
    var target: Target = .{};
    errdefer destroyTarget(vkd, device, &target);

    const modifier_info: vk.ImageDrmFormatModifierListCreateInfoEXT = .{
        .drm_format_modifier_count = 1,
        .p_drm_format_modifiers = @ptrCast(&modifier),
    };
    const external_info: vk.ExternalMemoryImageCreateInfo = .{
        .p_next = &modifier_info,
        .handle_types = .{ .dma_buf_bit_ext = true },
    };
    target.image = try vkd.createImage(device, &.{
        .p_next = &external_info,
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .drm_format_modifier_ext,
        .usage = .{ .color_attachment_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);

    const requirements = vkd.getImageMemoryRequirements(device, target.image);
    const export_info: vk.ExportMemoryAllocateInfo = .{
        .handle_types = .{ .dma_buf_bit_ext = true },
    };
    const dedicated_info: vk.MemoryDedicatedAllocateInfo = .{
        .p_next = &export_info,
        .image = target.image,
    };
    target.memory = try vkd.allocateMemory(device, &.{
        .p_next = &dedicated_info,
        .allocation_size = requirements.size,
        .memory_type_index = try memoryTypeIndex(
            memory_properties,
            requirements.memory_type_bits,
        ),
    }, null);
    try vkd.bindImageMemory(device, target.image, target.memory, 0);

    var modifier_properties: vk.ImageDrmFormatModifierPropertiesEXT = .{
        .drm_format_modifier = undefined,
    };
    try vkd.getImageDrmFormatModifierPropertiesEXT(
        device,
        target.image,
        &modifier_properties,
    );
    if (modifier_properties.drm_format_modifier != modifier) return error.UnexpectedModifier;

    const subresource: vk.ImageSubresource = .{
        .aspect_mask = .{ .color_bit = true },
        .mip_level = 0,
        .array_layer = 0,
    };
    const layout = vkd.getImageSubresourceLayout(device, target.image, &subresource);
    target.offset = std.math.cast(u32, layout.offset) orelse return error.PlaneLayoutTooLarge;
    target.stride = std.math.cast(u32, layout.row_pitch) orelse return error.PlaneLayoutTooLarge;

    target.fd = try vkd.getMemoryFdKHR(device, &.{
        .memory = target.memory,
        .handle_type = .{ .dma_buf_bit_ext = true },
    });
    if (target.fd < 0) return error.InvalidDmaBufFd;

    target.view = try vkd.createImageView(device, &.{
        .image = target.image,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = colorSubresourceRange(),
    }, null);
    target.framebuffer = try vkd.createFramebuffer(device, &.{
        .render_pass = render_pass,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&target.view),
        .width = extent.width,
        .height = extent.height,
        .layers = 1,
    }, null);
    target.fence = try vkd.createFence(device, &.{ .flags = .{ .signaled_bit = true } }, null);
    return target;
}

fn destroyTarget(vkd: vk.DeviceWrapper, device: vk.Device, target: *Target) void {
    if (target.fence != .null_handle) vkd.destroyFence(device, target.fence, null);
    if (target.framebuffer != .null_handle) vkd.destroyFramebuffer(device, target.framebuffer, null);
    if (target.view != .null_handle) vkd.destroyImageView(device, target.view, null);
    if (target.fd >= 0) _ = std.c.close(target.fd);
    if (target.image != .null_handle) vkd.destroyImage(device, target.image, null);
    if (target.memory != .null_handle) vkd.freeMemory(device, target.memory, null);
    target.* = .{};
}

fn memoryTypeIndex(properties: vk.PhysicalDeviceMemoryProperties, type_bits: u32) !u32 {
    var index: u32 = 0;
    while (index < properties.memory_type_count) : (index += 1) {
        if ((type_bits & (@as(u32, 1) << @intCast(index))) != 0) return index;
    }
    return error.NoSuitableMemoryType;
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

test "render-target modifier properties require one blendable color plane" {
    const supported: vk.DrmFormatModifierPropertiesEXT = .{
        .drm_format_modifier = 7,
        .drm_format_modifier_plane_count = 1,
        .drm_format_modifier_tiling_features = .{
            .color_attachment_bit = true,
            .color_attachment_blend_bit = true,
        },
    };
    try std.testing.expect(supportsRenderTarget(supported));

    var unsupported = supported;
    unsupported.drm_format_modifier_plane_count = 2;
    try std.testing.expect(!supportsRenderTarget(unsupported));
    unsupported = supported;
    unsupported.drm_format_modifier_tiling_features.color_attachment_blend_bit = false;
    try std.testing.expect(!supportsRenderTarget(unsupported));
}

test {
    std.testing.refAllDecls(DmaBufTargetSet);
}
