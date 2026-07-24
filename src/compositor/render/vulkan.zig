//! Vulkan-backed renderer with CPU fallbacks for commands not yet ported.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan");
const CpuRenderer = @import("cpu.zig");
const render = @import("types.zig");
const backdrop_cache_key = @import("backdrop_cache_key.zig");
const blur_geometry = @import("blur_geometry.zig");
const command_geometry = @import("command_geometry.zig");
const color_math = @import("color_math.zig");
const gpu_timing = @import("gpu_timing.zig");
const shaders = @import("vulkan_shaders.zig");
const vulkan_format = @import("vulkan_format.zig");
const sync = @cImport({
    @cInclude("linux/dma-buf.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/stat.h");
});
const log = std.log.scoped(.vulkan);
const GpuTiming = gpu_timing.Timing;
const GpuTimingCategory = gpu_timing.Category;
const GpuTimingPlan = gpu_timing.Plan;
const timestamp_query_count = gpu_timing.query_count;
const ManualYcbcr = vulkan_format.ManualYcbcr;
const VideoGraphicsKey = vulkan_format.GraphicsKey;

allocator: std.mem.Allocator,
loader: std.DynLib,
instance_wrapper: vk.InstanceWrapper,
device_wrapper: vk.DeviceWrapper,
instance: vk.Instance,
physical_device: vk.PhysicalDevice,
device: vk.Device,
queue: vk.Queue,
queue_family_index: u32,
command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
timestamp_valid_bits: u32,
timestamp_period: f32,
scanout_sync_enabled: bool,
completed_gpu_timings: [4]GpuTiming,
completed_gpu_timing_count: usize,
format: vk.Format,
swap_red_blue: bool,
render_pass: vk.RenderPass,
scratch_render_pass: vk.RenderPass,
output_render_pass: vk.RenderPass,
output_10bit: ?OutputGraphics,
descriptor_set_layout: vk.DescriptorSetLayout,
descriptor_pool: vk.DescriptorPool,
pipeline_layout: vk.PipelineLayout,
replace_pipeline: vk.Pipeline,
blend_pipeline: vk.Pipeline,
image_pipeline: vk.Pipeline,
crossfade_pipeline: vk.Pipeline,
opaque_image_pipeline: vk.Pipeline,
nearest_image_pipeline: vk.Pipeline,
opaque_nearest_image_pipeline: vk.Pipeline,
nearest_gamma22_image_pipeline: vk.Pipeline,
opaque_nearest_gamma22_image_pipeline: vk.Pipeline,
backdrop_image_pipeline: vk.Pipeline,
reconstruction_image_pipeline: vk.Pipeline,
opaque_reconstruction_image_pipeline: vk.Pipeline,
area_image_pipeline: vk.Pipeline,
opaque_area_image_pipeline: vk.Pipeline,
shadow_pipeline: vk.Pipeline,
downsample_pipeline: vk.Pipeline,
blur_downsample_pipeline: vk.Pipeline,
blur_upsample_pipeline: vk.Pipeline,
blur_composite_pipeline: vk.Pipeline,
encode_pipeline: vk.Pipeline,
encode_calibrated_pipeline: vk.Pipeline,
sampler: vk.Sampler,
instances: std.ArrayList(Instance) = .empty,
draw_runs: std.ArrayList(DrawRun) = .empty,
blur_ops: std.ArrayList(BlurOp) = .empty,
prepared_images: std.ArrayList(PreparedImage) = .empty,
dmabuf_modifiers: []u64,
dmabuf_sampled_modifiers: []u64,
dmabuf_10bit_modifiers: []u64,
dmabuf_10bit_sampled_modifiers: []u64,
dmabuf_target_formats: []render.DmabufFormatModifier,
dmabuf_source_modifiers: []u64,
dmabuf_rgba_source_modifiers: []u64,
dmabuf_nv12_source_modifiers: []u64,
dmabuf_p010_source_modifiers: []u64,
dmabuf_source_formats: []render.DmabufFormatModifier,
dmabuf_device_id: ?render.DrmDeviceId,
outputs: std.AutoHashMapUnmanaged(TargetKey, Output) = .empty,
textures: std.AutoHashMapUnmanaged(u64, Texture) = .empty,
calibrations: std.AutoHashMapUnmanaged(u64, CalibrationTexture) = .empty,
video_graphics: std.AutoHashMapUnmanaged(VideoGraphicsKey, VideoGraphics) = .empty,
frame_number: u64,
resource_epoch: u64,
fallback: CpuRenderer,

const max_cached_textures = 4096;
const descriptor_set_capacity = max_cached_textures + 512;
const stale_frame_count = 120;

const TargetKey = union(enum) {
    pixels: struct {
        pointer: usize,
        width: u32,
        height: u32,
        stride_pixels: u32,
    },
    offscreen: u64,
    dmabuf: u64,
};

const Submission = struct {
    fence: vk.Fence,
    scanout_semaphore: vk.Semaphore,
    timestamp_query_pool: vk.QueryPool,
    fence_pending: bool = false,
    pending_gpu_sample_tag: ?u64 = null,
    pending_gpu_timing_plan: GpuTimingPlan = .{},
    work_buffer: vk.Buffer = .null_handle,
    work_memory: vk.DeviceMemory = .null_handle,
    work_mapped: ?[*]u8 = null,
    work_capacity: usize = 0,
    instance_buffer: vk.Buffer = .null_handle,
    instance_memory: vk.DeviceMemory = .null_handle,
    instance_mapped: ?[*]u8 = null,
    instance_capacity: usize = 0,
    pending_wait_semaphores: std.ArrayList(vk.Semaphore) = .empty,
    pending_textures: std.ArrayList(Texture) = .empty,
};

const OutputKind = enum {
    pixels,
    offscreen,
    dmabuf,
};

const Output = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    descriptor_set: vk.DescriptorSet,
    framebuffer: vk.Framebuffer,
    format: vk.Format,
    size: render.Size,
    color_description: render.ColorDescription = .{},
    calibration_identity: ?u64 = null,
    kind: OutputKind = .pixels,
    initialized: bool = false,
    linear_initialized: bool = false,
    last_used: u64,
    command_buffer: vk.CommandBuffer = .null_handle,
    recorded_frame: RecordedFrame = .{},
    blur: ?BlurScratch = null,
    blur_initialized: u16 = 0,
    backdrop_cache: std.ArrayList(BackdropCache) = .empty,
    linear: WorkingImage,
    submission: Submission,
};

const WorkingImage = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    descriptor_set: vk.DescriptorSet,
    framebuffer: vk.Framebuffer,
};

const BlurImage = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    descriptor_set: vk.DescriptorSet,
};

const BlurScratch = struct {
    levels: [blur_level_count]?BlurLevel = @splat(null),
};

const BlurLevel = struct {
    size: render.Size,
    a: BlurImage,
    b: BlurImage,
    a_framebuffer: vk.Framebuffer,
    b_framebuffer: vk.Framebuffer,
};

const BackdropCache = struct {
    size: render.Size,
    image: BlurImage,
    framebuffer: vk.Framebuffer,
    key: ?u64 = null,
    geometry_key: u64 = 0,
    initialized: bool = false,

    fn matches(self: BackdropCache, key: ?u64) bool {
        return self.initialized and key != null and self.key == key;
    }
};

const blur_level_count = blur_geometry.level_count;

const Texture = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    secondary_view: ?vk.ImageView = null,
    descriptor_set: vk.DescriptorSet,
    pipeline: vk.Pipeline = .null_handle,
    pipeline_layout: vk.PipelineLayout = .null_handle,
    video_representation: ?render.ColorRepresentation = null,
    manual_ycbcr: ?ManualYcbcr = null,
    size: render.Size,
    version: u64 = 0,
    initialized: bool = false,
    imported: bool = false,
    last_used: u64,
};

const PreparedImage = struct {
    texture: Texture,
    buffer: render.PixelBuffer,
    upload_offset: ?usize,
    upload_damage: ?[]const render.Rect,
    cache_id: ?u64,
    desired_version: u64,
    newly_imported: bool = false,
};

const CalibrationTexture = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    descriptor_set: vk.DescriptorSet,
    initialized: bool = false,
    last_used: u64,
};

const PreparedCalibration = struct {
    identity: u64,
    texture: CalibrationTexture,
    upload_offset: ?usize,
};

const Instance = extern struct {
    destination: [4]f32,
    source: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    rounded: [4]f32,
    parameters: [4]f32,
};

const FramePush = extern struct {
    target_size: [2]f32,
    texture_size: [2]f32,
    swap_red_blue: f32,
    quantization_levels: f32 = 255,
    ycbcr_coefficients: [2]f32 = @splat(0),
    color_matrix_0: [4]f32 = .{ 1, 0, 0, 0 },
    color_matrix_1: [4]f32 = .{ 0, 1, 0, 0 },
    color_matrix_2: [4]f32 = .{ 0, 0, 1, 0 },
    transfer: [4]f32 = .{ 0, 1, 1, 1 },
    output_transfer: [4]f32 = .{ 1, 0, 80, 80 },
    transfer_aux: [4]f32 = .{ 0.2, 0.2126, 0.7152, 0.0722 },
};

const PipelineKind = enum {
    replace,
    blend,
    image,
    crossfade,
    backdrop_image,
    shadow,
    downsample,
    blur_downsample,
    blur_upsample,
    blur_composite,
};

const GpuTimingRecorder = struct {
    plan: GpuTimingPlan,
    segment_index: u16 = 0,

    fn switchTo(
        self: *GpuTimingRecorder,
        renderer: *Self,
        submission: *const Submission,
        command_buffer: vk.CommandBuffer,
        category: GpuTimingCategory,
    ) void {
        if (!self.plan.pass_timings_available) return;
        std.debug.assert(self.segment_index < self.plan.segment_count);
        if (self.plan.segments[self.segment_index] == category) return;
        std.debug.assert(self.segment_index + 1 < self.plan.segment_count);
        std.debug.assert(self.plan.segments[self.segment_index + 1] == category);
        renderer.writeGpuTimestamp(submission, command_buffer, @as(u32, self.segment_index) + 2);
        self.segment_index += 1;
    }

    fn finish(self: GpuTimingRecorder) void {
        if (!self.plan.pass_timings_available) return;
        std.debug.assert(self.segment_index + 1 == self.plan.segment_count);
    }
};

const BlurOp = struct {
    run_index: u32,
    cache_index: u32 = 0,
    cache_key: ?u64 = null,
    cache_hit: bool = false,
    cache_rekey: bool = false,
    geometry_key: u64 = 0,
    used: bool = false,
    base_capture: bool = false,
    reuse_op_index: ?u32 = null,
    level: u8 = 0,
    downsample_instances: [blur_level_count]u32 = @splat(0),
    upsample_instances: [blur_level_count]u32 = @splat(0),
    sample_rect: render.Rect,
    level_rects: [blur_level_count]render.Rect = @splat(.{ .x = 0, .y = 0, .width = 0, .height = 0 }),
    upsample_rects: [blur_level_count]render.Rect = @splat(.{ .x = 0, .y = 0, .width = 0, .height = 0 }),
};

const CompiledBackdropCapture = struct {
    id: u32,
    command_index: usize,
    op_index: u32,
    radius: u32,
    downsample_level: ?u8,
    finish: render.BackdropBlurFinish,
    key: ?u64,
    level: u8,
    sample_rect: render.Rect,
};

const PendingBackdropComposite = struct {
    capture: CompiledBackdropCapture,
};

const DrawRun = struct {
    pipeline: PipelineKind,
    pipeline_handle: vk.Pipeline = .null_handle,
    pipeline_layout: vk.PipelineLayout = .null_handle,
    descriptor_set: ?vk.DescriptorSet,
    secondary_descriptor_set: ?vk.DescriptorSet = null,
    texture_size: render.Size,
    first_instance: u32,
    instance_count: u32,
    color_transform: color_math.ColorTransform = .{},
    manual_ycbcr: ?ManualYcbcr = null,
    backdrop_op_index: ?u32 = null,
};

const UploadRun = struct {
    image: vk.Image,
    initialized: bool,
    buffer_size: render.Size,
    stride_pixels: u32,
    offset: usize,
    first_rectangle: usize,
    rectangle_count: usize,
};

const RecordedFrame = struct {
    // Mapped pixels and instances may change between submissions. Everything
    // stored here is state baked into the Vulkan command buffer itself.
    valid: bool = false,
    resource_epoch: u64 = 0,
    output_initialized: bool = false,
    blur_initialized: u16 = 0,
    render_area: render.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    work_buffer: vk.Buffer = .null_handle,
    instance_buffer: vk.Buffer = .null_handle,
    timestamp_query_pool: vk.QueryPool = .null_handle,
    uploads: std.ArrayList(UploadRun) = .empty,
    upload_rectangles: std.ArrayList(render.Rect) = .empty,
    draw_runs: std.ArrayList(DrawRun) = .empty,
    blur_ops: std.ArrayList(BlurOp) = .empty,

    fn deinit(self: *RecordedFrame, allocator: std.mem.Allocator) void {
        self.uploads.deinit(allocator);
        self.upload_rectangles.deinit(allocator);
        self.draw_runs.deinit(allocator);
        self.blur_ops.deinit(allocator);
        self.* = undefined;
    }
};

comptime {
    std.debug.assert(@sizeOf(Instance) == 96);
    std.debug.assert(@sizeOf(FramePush) == 128);
}

pub const InitError = error{
    OutOfMemory,
    VulkanUnavailable,
    NoPhysicalDevice,
    NoQueueFamily,
};

pub const Error = CpuRenderer.Error || error{
    InvalidTarget,
    OutOfMemory,
    VulkanFailure,
};

const Graphics = struct {
    render_pass: vk.RenderPass,
    scratch_render_pass: vk.RenderPass,
    output_render_pass: vk.RenderPass,
    output_10bit: ?OutputGraphics,
    descriptor_set_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    pipeline_layout: vk.PipelineLayout,
    replace_pipeline: vk.Pipeline,
    blend_pipeline: vk.Pipeline,
    image_pipeline: vk.Pipeline,
    crossfade_pipeline: vk.Pipeline,
    opaque_image_pipeline: vk.Pipeline,
    nearest_image_pipeline: vk.Pipeline,
    opaque_nearest_image_pipeline: vk.Pipeline,
    nearest_gamma22_image_pipeline: vk.Pipeline,
    opaque_nearest_gamma22_image_pipeline: vk.Pipeline,
    backdrop_image_pipeline: vk.Pipeline,
    reconstruction_image_pipeline: vk.Pipeline,
    opaque_reconstruction_image_pipeline: vk.Pipeline,
    area_image_pipeline: vk.Pipeline,
    opaque_area_image_pipeline: vk.Pipeline,
    shadow_pipeline: vk.Pipeline,
    downsample_pipeline: vk.Pipeline,
    blur_downsample_pipeline: vk.Pipeline,
    blur_upsample_pipeline: vk.Pipeline,
    blur_composite_pipeline: vk.Pipeline,
    encode_pipeline: vk.Pipeline,
    encode_calibrated_pipeline: vk.Pipeline,
    sampler: vk.Sampler,
};

const OutputGraphics = struct {
    render_pass: vk.RenderPass,
    encode_pipeline: vk.Pipeline,
    encode_calibrated_pipeline: vk.Pipeline,
};

const working_format: vk.Format = .r16g16b16a16_sfloat;

fn chooseFormat(
    wrapper: vk.InstanceWrapper,
    physical_device: vk.PhysicalDevice,
) ?vk.Format {
    for ([_]vk.Format{ .b8g8r8a8_unorm, .r8g8b8a8_unorm }) |format| {
        const features = wrapper.getPhysicalDeviceFormatProperties(
            physical_device,
            format,
        ).optimal_tiling_features;
        if (features.color_attachment_bit and
            features.color_attachment_blend_bit and
            features.sampled_image_bit and
            features.sampled_image_filter_linear_bit and
            features.transfer_src_bit and
            features.transfer_dst_bit)
        {
            return format;
        }
    }
    return null;
}

fn initGraphics(
    wrapper: vk.DeviceWrapper,
    device: vk.Device,
    format: vk.Format,
    enable_10bit_output: bool,
    ycbcr_descriptor_count: u32,
) !Graphics {
    const binding: vk.DescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
    };
    const descriptor_set_layout = try wrapper.createDescriptorSetLayout(device, &.{
        .binding_count = 1,
        .p_bindings = @ptrCast(&binding),
    }, null);
    errdefer wrapper.destroyDescriptorSetLayout(device, descriptor_set_layout, null);

    const pool_size: vk.DescriptorPoolSize = .{
        .type = .combined_image_sampler,
        .descriptor_count = descriptorPoolCount(ycbcr_descriptor_count) orelse
            return error.OutOfDeviceMemory,
    };
    const descriptor_pool = try wrapper.createDescriptorPool(device, &.{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = descriptor_set_capacity,
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
    }, null);
    errdefer wrapper.destroyDescriptorPool(device, descriptor_pool, null);

    const push_range: vk.PushConstantRange = .{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = @sizeOf(FramePush),
    };
    const pipeline_layout = try wrapper.createPipelineLayout(device, &.{
        .set_layout_count = 2,
        .p_set_layouts = &.{ descriptor_set_layout, descriptor_set_layout },
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&push_range),
    }, null);
    errdefer wrapper.destroyPipelineLayout(device, pipeline_layout, null);

    const attachment: vk.AttachmentDescription = .{
        .format = working_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .load,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .color_attachment_optimal,
        .final_layout = .color_attachment_optimal,
    };
    const attachment_reference: vk.AttachmentReference = .{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };
    const subpass: vk.SubpassDescription = .{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&attachment_reference),
    };
    const render_pass = try wrapper.createRenderPass(device, &.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    }, null);
    errdefer wrapper.destroyRenderPass(device, render_pass, null);
    var scratch_attachment = attachment;
    scratch_attachment.load_op = .dont_care;
    const scratch_render_pass = try wrapper.createRenderPass(device, &.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&scratch_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    }, null);
    errdefer wrapper.destroyRenderPass(device, scratch_render_pass, null);
    var output_attachment = attachment;
    output_attachment.format = format;
    const output_render_pass = try wrapper.createRenderPass(device, &.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&output_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    }, null);
    errdefer wrapper.destroyRenderPass(device, output_render_pass, null);

    const sampler = try wrapper.createSampler(device, &.{
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
    errdefer wrapper.destroySampler(device, sampler, null);

    const vertex_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.quad_instanced)),
        .p_code = &shaders.quad_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, vertex_shader, null);
    const solid_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.solid_instanced)),
        .p_code = &shaders.solid_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, solid_shader, null);
    const image_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.image_alpha_instanced)),
        .p_code = &shaders.image_alpha_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, image_shader, null);
    const crossfade_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.crossfade_instanced)),
        .p_code = &shaders.crossfade_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, crossfade_shader, null);
    const nearest_image_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.image_nearest_instanced)),
        .p_code = &shaders.image_nearest_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, nearest_image_shader, null);
    const nearest_gamma22_image_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.image_nearest_gamma22_instanced)),
        .p_code = &shaders.image_nearest_gamma22_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, nearest_gamma22_image_shader, null);
    const backdrop_image_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.backdrop_image_instanced)),
        .p_code = &shaders.backdrop_image_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, backdrop_image_shader, null);
    const reconstruction_image_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.image_catmull_rom_instanced)),
        .p_code = &shaders.image_catmull_rom_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, reconstruction_image_shader, null);
    const area_image_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.image_area_instanced)),
        .p_code = &shaders.image_area_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, area_image_shader, null);
    const shadow_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.shadow_instanced)),
        .p_code = &shaders.shadow_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, shadow_shader, null);
    const blur_downsample_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.blur_downsample)),
        .p_code = &shaders.blur_downsample,
    }, null);
    defer wrapper.destroyShaderModule(device, blur_downsample_shader, null);
    const blur_upsample_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.blur_upsample)),
        .p_code = &shaders.blur_upsample,
    }, null);
    defer wrapper.destroyShaderModule(device, blur_upsample_shader, null);
    const encode_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.output_encode)),
        .p_code = &shaders.output_encode,
    }, null);
    defer wrapper.destroyShaderModule(device, encode_shader, null);
    const encode_calibrated_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.output_encode_calibrated)),
        .p_code = &shaders.output_encode_calibrated,
    }, null);
    defer wrapper.destroyShaderModule(device, encode_calibrated_shader, null);
    const replace_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        solid_shader,
        false,
    ) catch |err| {
        log.err("failed to create Vulkan replace pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, replace_pipeline, null);
    const blend_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        solid_shader,
        true,
    ) catch |err| {
        log.err("failed to create Vulkan blend pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, blend_pipeline, null);
    const image_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        image_shader,
        true,
    ) catch |err| {
        log.err("failed to create Vulkan image pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, image_pipeline, null);
    const crossfade_pipeline = try createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        crossfade_shader,
        true,
    );
    errdefer wrapper.destroyPipeline(device, crossfade_pipeline, null);
    const opaque_image_pipeline = try createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        image_shader,
        false,
    );
    errdefer wrapper.destroyPipeline(device, opaque_image_pipeline, null);
    const nearest_image_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        nearest_image_shader,
        true,
    ) catch |err| {
        log.err("failed to create Vulkan nearest image pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, nearest_image_pipeline, null);
    const opaque_nearest_image_pipeline = try createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        nearest_image_shader,
        false,
    );
    errdefer wrapper.destroyPipeline(device, opaque_nearest_image_pipeline, null);
    const nearest_gamma22_image_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        nearest_gamma22_image_shader,
        true,
    ) catch |err| {
        log.err("failed to create Vulkan nearest gamma 2.2 image pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, nearest_gamma22_image_pipeline, null);
    const opaque_nearest_gamma22_image_pipeline = try createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        nearest_gamma22_image_shader,
        false,
    );
    errdefer wrapper.destroyPipeline(device, opaque_nearest_gamma22_image_pipeline, null);
    const reconstruction_image_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        reconstruction_image_shader,
        true,
    ) catch |err| {
        log.err("failed to create Vulkan reconstruction image pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, reconstruction_image_pipeline, null);
    const opaque_reconstruction_image_pipeline = try createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        reconstruction_image_shader,
        false,
    );
    errdefer wrapper.destroyPipeline(device, opaque_reconstruction_image_pipeline, null);
    const area_image_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        area_image_shader,
        true,
    ) catch |err| {
        log.err("failed to create Vulkan area image pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, area_image_pipeline, null);
    const opaque_area_image_pipeline = try createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        area_image_shader,
        false,
    );
    errdefer wrapper.destroyPipeline(device, opaque_area_image_pipeline, null);
    const shadow_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        shadow_shader,
        true,
    ) catch |err| {
        log.err("failed to create Vulkan shadow pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, shadow_pipeline, null);
    const downsample_pipeline = try createPipeline(wrapper, device, render_pass, pipeline_layout, vertex_shader, image_shader, false);
    errdefer wrapper.destroyPipeline(device, downsample_pipeline, null);
    const blur_downsample_pipeline = try createPipeline(wrapper, device, render_pass, pipeline_layout, vertex_shader, blur_downsample_shader, false);
    errdefer wrapper.destroyPipeline(device, blur_downsample_pipeline, null);
    const blur_upsample_pipeline = try createPipeline(wrapper, device, render_pass, pipeline_layout, vertex_shader, blur_upsample_shader, false);
    errdefer wrapper.destroyPipeline(device, blur_upsample_pipeline, null);
    const blur_composite_pipeline = try createPipeline(wrapper, device, render_pass, pipeline_layout, vertex_shader, image_shader, true);
    errdefer wrapper.destroyPipeline(device, blur_composite_pipeline, null);
    const backdrop_image_pipeline = try createPipeline(wrapper, device, render_pass, pipeline_layout, vertex_shader, backdrop_image_shader, true);
    errdefer wrapper.destroyPipeline(device, backdrop_image_pipeline, null);
    const encode_pipeline = try createPipeline(
        wrapper,
        device,
        output_render_pass,
        pipeline_layout,
        vertex_shader,
        encode_shader,
        false,
    );
    errdefer wrapper.destroyPipeline(device, encode_pipeline, null);
    const encode_calibrated_pipeline = try createPipeline(
        wrapper,
        device,
        output_render_pass,
        pipeline_layout,
        vertex_shader,
        encode_calibrated_shader,
        false,
    );
    errdefer wrapper.destroyPipeline(device, encode_calibrated_pipeline, null);
    const output_10bit: ?OutputGraphics = if (enable_10bit_output) output: {
        var ten_bit_attachment = output_attachment;
        ten_bit_attachment.format = .a2r10g10b10_unorm_pack32;
        const ten_bit_render_pass = try wrapper.createRenderPass(device, &.{
            .attachment_count = 1,
            .p_attachments = @ptrCast(&ten_bit_attachment),
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
        }, null);
        errdefer wrapper.destroyRenderPass(device, ten_bit_render_pass, null);
        const ten_bit_pipeline = try createPipeline(
            wrapper,
            device,
            ten_bit_render_pass,
            pipeline_layout,
            vertex_shader,
            encode_shader,
            false,
        );
        errdefer wrapper.destroyPipeline(device, ten_bit_pipeline, null);
        const ten_bit_calibrated_pipeline = try createPipeline(
            wrapper,
            device,
            ten_bit_render_pass,
            pipeline_layout,
            vertex_shader,
            encode_calibrated_shader,
            false,
        );
        break :output .{
            .render_pass = ten_bit_render_pass,
            .encode_pipeline = ten_bit_pipeline,
            .encode_calibrated_pipeline = ten_bit_calibrated_pipeline,
        };
    } else null;
    errdefer if (output_10bit) |output| destroyOutputGraphics(wrapper, device, output);
    return .{
        .render_pass = render_pass,
        .scratch_render_pass = scratch_render_pass,
        .output_render_pass = output_render_pass,
        .output_10bit = output_10bit,
        .descriptor_set_layout = descriptor_set_layout,
        .descriptor_pool = descriptor_pool,
        .pipeline_layout = pipeline_layout,
        .replace_pipeline = replace_pipeline,
        .blend_pipeline = blend_pipeline,
        .image_pipeline = image_pipeline,
        .crossfade_pipeline = crossfade_pipeline,
        .opaque_image_pipeline = opaque_image_pipeline,
        .nearest_image_pipeline = nearest_image_pipeline,
        .opaque_nearest_image_pipeline = opaque_nearest_image_pipeline,
        .nearest_gamma22_image_pipeline = nearest_gamma22_image_pipeline,
        .opaque_nearest_gamma22_image_pipeline = opaque_nearest_gamma22_image_pipeline,
        .backdrop_image_pipeline = backdrop_image_pipeline,
        .reconstruction_image_pipeline = reconstruction_image_pipeline,
        .opaque_reconstruction_image_pipeline = opaque_reconstruction_image_pipeline,
        .area_image_pipeline = area_image_pipeline,
        .opaque_area_image_pipeline = opaque_area_image_pipeline,
        .shadow_pipeline = shadow_pipeline,
        .downsample_pipeline = downsample_pipeline,
        .blur_downsample_pipeline = blur_downsample_pipeline,
        .blur_upsample_pipeline = blur_upsample_pipeline,
        .blur_composite_pipeline = blur_composite_pipeline,
        .encode_pipeline = encode_pipeline,
        .encode_calibrated_pipeline = encode_calibrated_pipeline,
        .sampler = sampler,
    };
}

fn createPipeline(
    wrapper: vk.DeviceWrapper,
    device: vk.Device,
    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    vertex_shader: vk.ShaderModule,
    fragment_shader: vk.ShaderModule,
    blend: bool,
) !vk.Pipeline {
    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vertex_shader,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = fragment_shader,
            .p_name = "main",
        },
    };
    const vertex_binding: vk.VertexInputBindingDescription = .{
        .binding = 0,
        .stride = @sizeOf(Instance),
        .input_rate = .instance,
    };
    const vertex_attributes = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "destination") },
        .{ .location = 1, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "source") },
        .{ .location = 2, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "clip") },
        .{ .location = 3, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "color") },
        .{ .location = 4, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "rounded") },
        .{ .location = 5, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "parameters") },
    };
    const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast(&vertex_binding),
        .vertex_attribute_description_count = vertex_attributes.len,
        .p_vertex_attribute_descriptions = &vertex_attributes,
    };
    const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = .triangle_strip,
        .primitive_restart_enable = .false,
    };
    const viewport: vk.PipelineViewportStateCreateInfo = .{
        .viewport_count = 1,
        .scissor_count = 1,
    };
    const rasterization: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    const multisample: vk.PipelineMultisampleStateCreateInfo = .{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 0,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };
    const blend_attachment: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = if (blend) .true else .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{
            .r_bit = true,
            .g_bit = true,
            .b_bit = true,
            .a_bit = true,
        },
    };
    const color_blend: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&blend_attachment),
        .blend_constants = @splat(0),
    };
    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };
    const create_info: vk.GraphicsPipelineCreateInfo = .{
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport,
        .p_rasterization_state = &rasterization,
        .p_multisample_state = &multisample,
        .p_color_blend_state = &color_blend,
        .p_dynamic_state = &dynamic,
        .layout = pipeline_layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = undefined;
    _ = try wrapper.createGraphicsPipelines(
        device,
        .null_handle,
        &.{create_info},
        null,
        @ptrCast(&pipeline),
    );
    return pipeline;
}

fn destroyGraphics(wrapper: vk.DeviceWrapper, device: vk.Device, graphics: Graphics) void {
    if (graphics.output_10bit) |output| destroyOutputGraphics(wrapper, device, output);
    wrapper.destroyPipeline(device, graphics.encode_calibrated_pipeline, null);
    wrapper.destroyPipeline(device, graphics.encode_pipeline, null);
    wrapper.destroyPipeline(device, graphics.backdrop_image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.blur_composite_pipeline, null);
    wrapper.destroyPipeline(device, graphics.blur_upsample_pipeline, null);
    wrapper.destroyPipeline(device, graphics.blur_downsample_pipeline, null);
    wrapper.destroyPipeline(device, graphics.downsample_pipeline, null);
    wrapper.destroyPipeline(device, graphics.shadow_pipeline, null);
    wrapper.destroyPipeline(device, graphics.opaque_area_image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.area_image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.opaque_reconstruction_image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.reconstruction_image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.opaque_nearest_gamma22_image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.nearest_gamma22_image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.opaque_nearest_image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.nearest_image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.opaque_image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.crossfade_pipeline, null);
    wrapper.destroyPipeline(device, graphics.blend_pipeline, null);
    wrapper.destroyPipeline(device, graphics.replace_pipeline, null);
    wrapper.destroySampler(device, graphics.sampler, null);
    wrapper.destroyRenderPass(device, graphics.output_render_pass, null);
    wrapper.destroyRenderPass(device, graphics.scratch_render_pass, null);
    wrapper.destroyRenderPass(device, graphics.render_pass, null);
    wrapper.destroyPipelineLayout(device, graphics.pipeline_layout, null);
    wrapper.destroyDescriptorPool(device, graphics.descriptor_pool, null);
    wrapper.destroyDescriptorSetLayout(device, graphics.descriptor_set_layout, null);
}

fn destroyOutputGraphics(
    wrapper: vk.DeviceWrapper,
    device: vk.Device,
    graphics: OutputGraphics,
) void {
    wrapper.destroyPipeline(device, graphics.encode_calibrated_pipeline, null);
    wrapper.destroyPipeline(device, graphics.encode_pipeline, null);
    wrapper.destroyRenderPass(device, graphics.render_pass, null);
}

const instance_extensions = [_][*:0]const u8{
    "VK_KHR_get_physical_device_properties2",
    "VK_KHR_external_memory_capabilities",
    "VK_KHR_external_semaphore_capabilities",
};
const dmabuf_device_extensions = [_][*:0]const u8{
    "VK_EXT_physical_device_drm",
    "VK_KHR_maintenance1",
    "VK_KHR_get_memory_requirements2",
    "VK_KHR_bind_memory2",
    "VK_KHR_sampler_ycbcr_conversion",
    "VK_KHR_image_format_list",
    "VK_KHR_external_memory",
    "VK_KHR_external_memory_fd",
    "VK_KHR_external_semaphore",
    "VK_KHR_external_semaphore_fd",
    "VK_EXT_external_memory_dma_buf",
    "VK_KHR_dedicated_allocation",
    "VK_EXT_queue_family_foreign",
    "VK_EXT_image_drm_format_modifier",
};

fn hasExtension(properties: []const vk.ExtensionProperties, name: []const u8) bool {
    for (properties) |property| {
        const extension_name = std.mem.sliceTo(&property.extension_name, 0);
        if (std.mem.eql(u8, extension_name, name)) return true;
    }
    return false;
}

const VideoGraphics = struct {
    conversion: ?vk.SamplerYcbcrConversion,
    sampler: vk.Sampler,
    descriptor_set_layout: vk.DescriptorSetLayout,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
};

fn getVideoGraphics(self: *Self, key: VideoGraphicsKey) Error!VideoGraphics {
    if (self.video_graphics.get(key)) |graphics| return graphics;
    const graphics = try self.createVideoGraphics(key);
    self.video_graphics.put(self.allocator, key, graphics) catch {
        self.destroyVideoGraphics(graphics);
        return error.OutOfMemory;
    };
    return graphics;
}

fn createVideoGraphics(self: *Self, key: VideoGraphicsKey) Error!VideoGraphics {
    const conversion: ?vk.SamplerYcbcrConversion = if (key.manual)
        null
    else
        self.device_wrapper.createSamplerYcbcrConversionKHR(self.device, &.{
            .format = key.format,
            .ycbcr_model = key.model,
            .ycbcr_range = key.range,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .x_chroma_offset = key.x_chroma_offset,
            .y_chroma_offset = key.y_chroma_offset,
            .chroma_filter = .linear,
            .force_explicit_reconstruction = .false,
        }, null) catch return error.VulkanFailure;
    errdefer if (conversion) |value| self.device_wrapper.destroySamplerYcbcrConversionKHR(
        self.device,
        value,
        null,
    );
    const conversion_info: vk.SamplerYcbcrConversionInfo = .{
        .conversion = conversion orelse .null_handle,
    };
    const sampler = self.device_wrapper.createSampler(self.device, &.{
        .p_next = if (conversion != null) &conversion_info else null,
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
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroySampler(self.device, sampler, null);
    const automatic_bindings = [_]vk.DescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
        .p_immutable_samplers = @ptrCast(&sampler),
    }};
    const manual_bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
        },
        .{
            .binding = 1,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
        },
    };
    const bindings: []const vk.DescriptorSetLayoutBinding = if (key.manual)
        &manual_bindings
    else
        &automatic_bindings;
    const descriptor_set_layout = self.device_wrapper.createDescriptorSetLayout(self.device, &.{
        .binding_count = @intCast(bindings.len),
        .p_bindings = bindings.ptr,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyDescriptorSetLayout(
        self.device,
        descriptor_set_layout,
        null,
    );
    const push_range: vk.PushConstantRange = .{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = @sizeOf(FramePush),
    };
    const pipeline_layout = self.device_wrapper.createPipelineLayout(self.device, &.{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&descriptor_set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&push_range),
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyPipelineLayout(self.device, pipeline_layout, null);
    const vertex_shader = self.device_wrapper.createShaderModule(self.device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.quad_instanced)),
        .p_code = &shaders.quad_instanced,
    }, null) catch return error.VulkanFailure;
    defer self.device_wrapper.destroyShaderModule(self.device, vertex_shader, null);
    const image_shader = self.device_wrapper.createShaderModule(self.device, &.{
        .code_size = if (key.manual)
            @sizeOf(@TypeOf(shaders.video_manual_instanced))
        else
            @sizeOf(@TypeOf(shaders.image_alpha_instanced)),
        .p_code = if (key.manual)
            &shaders.video_manual_instanced
        else
            &shaders.image_alpha_instanced,
    }, null) catch return error.VulkanFailure;
    defer self.device_wrapper.destroyShaderModule(self.device, image_shader, null);
    const pipeline = createPipeline(
        self.device_wrapper,
        self.device,
        self.render_pass,
        pipeline_layout,
        vertex_shader,
        image_shader,
        true,
    ) catch return error.VulkanFailure;
    return .{
        .conversion = conversion,
        .sampler = sampler,
        .descriptor_set_layout = descriptor_set_layout,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
    };
}

fn destroyVideoGraphics(self: *Self, graphics: VideoGraphics) void {
    self.device_wrapper.destroyPipeline(self.device, graphics.pipeline, null);
    self.device_wrapper.destroyPipelineLayout(self.device, graphics.pipeline_layout, null);
    self.device_wrapper.destroyDescriptorSetLayout(
        self.device,
        graphics.descriptor_set_layout,
        null,
    );
    self.device_wrapper.destroySampler(self.device, graphics.sampler, null);
    if (graphics.conversion) |conversion| {
        self.device_wrapper.destroySamplerYcbcrConversionKHR(
            self.device,
            conversion,
            null,
        );
    }
}

test "Vulkan caches immutable YCbCr sampler pipelines" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    if (renderer.dmabuf_nv12_source_modifiers.len == 0) return error.SkipZigTest;

    const parameters = vulkan_format.automaticConversion(vulkan_format.defaultRepresentation()).?;
    const key = vulkan_format.automaticGraphicsKey(.g8_b8r8_2plane_420_unorm, parameters);
    const first = try renderer.getVideoGraphics(key);
    const second = try renderer.getVideoGraphics(key);
    try std.testing.expectEqual(first.conversion, second.conversion);
    try std.testing.expectEqual(first.sampler, second.sampler);
    try std.testing.expectEqual(first.descriptor_set_layout, second.descriptor_set_layout);
    try std.testing.expectEqual(first.pipeline_layout, second.pipeline_layout);
    try std.testing.expectEqual(first.pipeline, second.pipeline);

    const manual_key = vulkan_format.manualGraphicsKey(.g8_b8r8_2plane_420_unorm);
    const manual_first = try renderer.getVideoGraphics(manual_key);
    const manual_second = try renderer.getVideoGraphics(manual_key);
    try std.testing.expect(manual_first.conversion == null);
    try std.testing.expectEqual(manual_first.sampler, manual_second.sampler);
    try std.testing.expectEqual(
        manual_first.descriptor_set_layout,
        manual_second.descriptor_set_layout,
    );
    try std.testing.expectEqual(manual_first.pipeline_layout, manual_second.pipeline_layout);
    try std.testing.expectEqual(manual_first.pipeline, manual_second.pipeline);
    try std.testing.expectEqual(@as(usize, 2), renderer.video_graphics.count());
}

fn dmabufPlanesShareAllocation(planes: []const render.DmabufPlane) bool {
    if (planes.len == 0) return false;
    var first: sync.struct_stat = undefined;
    if (sync.fstat(planes[0].fd, &first) != 0) return false;
    for (planes[1..]) |plane| {
        var current: sync.struct_stat = undefined;
        if (sync.fstat(plane.fd, &current) != 0 or
            current.st_dev != first.st_dev or current.st_ino != first.st_ino)
        {
            return false;
        }
    }
    return true;
}

test "DMA-BUF plane allocation identity follows the underlying file" {
    var first_pipe: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe2(&first_pipe, .{ .CLOEXEC = true }));
    defer {
        for (first_pipe) |fd| _ = std.c.close(fd);
    }
    var second_pipe: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe2(&second_pipe, .{ .CLOEXEC = true }));
    defer {
        for (second_pipe) |fd| _ = std.c.close(fd);
    }
    const duplicate = std.c.dup(first_pipe[0]);
    try std.testing.expect(duplicate >= 0);
    defer _ = std.c.close(duplicate);

    try std.testing.expect(dmabufPlanesShareAllocation(&.{
        .{ .fd = first_pipe[0] },
        .{ .fd = duplicate },
    }));
    try std.testing.expect(!dmabufPlanesShareAllocation(&.{
        .{ .fd = first_pipe[0] },
        .{ .fd = second_pipe[0] },
    }));
}

fn dmabufSourceModifierImportable(
    instance_wrapper: vk.InstanceWrapper,
    physical_device: vk.PhysicalDevice,
    format: vk.Format,
    modifier: u64,
) ?u32 {
    const modifier_info: vk.PhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .drm_format_modifier = modifier,
        .sharing_mode = .exclusive,
    };
    var plane_view_formats = vulkan_format.planeViewFormats(format);
    var format_list: vk.ImageFormatListCreateInfo = .{ .p_next = &modifier_info };
    if (plane_view_formats) |*formats| {
        format_list.view_format_count = formats.len;
        format_list.p_view_formats = formats;
    }
    const external_info: vk.PhysicalDeviceExternalImageFormatInfo = .{
        .p_next = if (plane_view_formats != null) &format_list else &modifier_info,
        .handle_type = .{ .dma_buf_bit_ext = true },
    };
    const format_info: vk.PhysicalDeviceImageFormatInfo2 = .{
        .p_next = &external_info,
        .format = format,
        .type = .@"2d",
        .tiling = .drm_format_modifier_ext,
        .usage = .{ .sampled_bit = true },
        .flags = .{ .mutable_format_bit = plane_view_formats != null },
    };
    var external_properties: vk.ExternalImageFormatProperties = .{
        .external_memory_properties = undefined,
    };
    var ycbcr_properties: vk.SamplerYcbcrConversionImageFormatProperties = .{
        .combined_image_sampler_descriptor_count = 0,
    };
    external_properties.p_next = &ycbcr_properties;
    var format_properties: vk.ImageFormatProperties2 = .{
        .p_next = &external_properties,
        .image_format_properties = undefined,
    };
    instance_wrapper.getPhysicalDeviceImageFormatProperties2KHR(
        physical_device,
        &format_info,
        &format_properties,
    ) catch return null;
    if (!external_properties.external_memory_properties.external_memory_features.importable_bit) {
        return null;
    }
    return @max(
        ycbcr_properties.combined_image_sampler_descriptor_count,
        @as(u32, if (plane_view_formats != null) 2 else 1),
    );
}

const DmabufTargetModifiers = struct {
    supported: []u64,
    sampleable: []u64,
};

const DmabufSourceModifiers = struct {
    modifiers: []u64,
    max_descriptor_count: u32,
};

fn descriptorPoolCount(ycbcr_descriptor_count: u32) ?u32 {
    return std.math.mul(
        u32,
        descriptor_set_capacity,
        @max(ycbcr_descriptor_count, 1),
    ) catch null;
}

test "descriptor pool accounts for multi-descriptor YCbCr samplers" {
    try std.testing.expectEqual(
        @as(u32, descriptor_set_capacity),
        descriptorPoolCount(0).?,
    );
    try std.testing.expectEqual(
        @as(u32, descriptor_set_capacity * 3),
        descriptorPoolCount(3).?,
    );
    try std.testing.expect(descriptorPoolCount(std.math.maxInt(u32)) == null);
}

fn queryDmabufTargetModifiers(
    allocator: std.mem.Allocator,
    instance_wrapper: vk.InstanceWrapper,
    physical_device: vk.PhysicalDevice,
    format: vk.Format,
) error{OutOfMemory}!DmabufTargetModifiers {
    var modifier_list: vk.DrmFormatModifierPropertiesListEXT = .{};
    var format_properties: vk.FormatProperties2 = .{ .format_properties = undefined };
    format_properties.p_next = &modifier_list;
    instance_wrapper.getPhysicalDeviceFormatProperties2KHR(
        physical_device,
        format,
        &format_properties,
    );
    const properties = allocator.alloc(
        vk.DrmFormatModifierPropertiesEXT,
        modifier_list.drm_format_modifier_count,
    ) catch return error.OutOfMemory;
    defer allocator.free(properties);
    modifier_list.p_drm_format_modifier_properties = properties.ptr;
    instance_wrapper.getPhysicalDeviceFormatProperties2KHR(
        physical_device,
        format,
        &format_properties,
    );

    var supported: std.ArrayList(u64) = .empty;
    defer supported.deinit(allocator);
    var fallback: std.ArrayList(u64) = .empty;
    defer fallback.deinit(allocator);
    var sampleable: std.ArrayList(u64) = .empty;
    defer sampleable.deinit(allocator);
    for (properties) |property| {
        const features = property.drm_format_modifier_tiling_features;
        if (property.drm_format_modifier_plane_count != 1 or
            !features.color_attachment_bit or !features.color_attachment_blend_bit or
            !features.transfer_dst_bit or (!features.transfer_src_bit and
            (!features.sampled_image_bit or !features.sampled_image_filter_linear_bit)))
        {
            continue;
        }
        if (features.sampled_image_bit and features.sampled_image_filter_linear_bit) {
            try supported.append(allocator, property.drm_format_modifier);
            try sampleable.append(allocator, property.drm_format_modifier);
        } else {
            try fallback.append(allocator, property.drm_format_modifier);
        }
    }
    try supported.appendSlice(allocator, fallback.items);
    const supported_owned = try supported.toOwnedSlice(allocator);
    errdefer allocator.free(supported_owned);
    return .{
        .supported = supported_owned,
        .sampleable = try sampleable.toOwnedSlice(allocator),
    };
}

fn queryDmabufSourceModifiers(
    allocator: std.mem.Allocator,
    instance_wrapper: vk.InstanceWrapper,
    physical_device: vk.PhysicalDevice,
    format: vk.Format,
    plane_count: u32,
    require_ycbcr: bool,
) error{OutOfMemory}!DmabufSourceModifiers {
    var modifier_list: vk.DrmFormatModifierPropertiesListEXT = .{};
    var format_properties: vk.FormatProperties2 = .{ .format_properties = undefined };
    format_properties.p_next = &modifier_list;
    instance_wrapper.getPhysicalDeviceFormatProperties2KHR(
        physical_device,
        format,
        &format_properties,
    );
    const properties = allocator.alloc(
        vk.DrmFormatModifierPropertiesEXT,
        modifier_list.drm_format_modifier_count,
    ) catch return error.OutOfMemory;
    defer allocator.free(properties);
    modifier_list.p_drm_format_modifier_properties = properties.ptr;
    instance_wrapper.getPhysicalDeviceFormatProperties2KHR(
        physical_device,
        format,
        &format_properties,
    );

    var modifiers: std.ArrayList(u64) = .empty;
    defer modifiers.deinit(allocator);
    var max_descriptor_count: u32 = 1;
    for (properties) |property| {
        const features = property.drm_format_modifier_tiling_features;
        if (property.drm_format_modifier_plane_count == plane_count and
            features.sampled_image_bit and features.sampled_image_filter_linear_bit and
            (!require_ycbcr or
                (features.cosited_chroma_samples_bit and
                    features.midpoint_chroma_samples_bit and
                    features.sampled_image_ycbcr_conversion_linear_filter_bit)))
        {
            const descriptor_count = dmabufSourceModifierImportable(
                instance_wrapper,
                physical_device,
                format,
                property.drm_format_modifier,
            ) orelse continue;
            modifiers.append(allocator, property.drm_format_modifier) catch
                return error.OutOfMemory;
            max_descriptor_count = @max(max_descriptor_count, descriptor_count);
        }
    }
    return .{
        .modifiers = modifiers.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .max_descriptor_count = max_descriptor_count,
    };
}

pub fn init(allocator: std.mem.Allocator, drm_device_id: ?render.DrmDeviceId) InitError!Self {
    var loader = std.DynLib.open("libvulkan.so.1") catch return error.VulkanUnavailable;
    errdefer loader.close();
    const get_instance_proc_addr = loader.lookup(
        vk.PfnGetInstanceProcAddr,
        "vkGetInstanceProcAddr",
    ) orelse return error.VulkanUnavailable;
    const base_wrapper = vk.BaseWrapper.load(get_instance_proc_addr);
    const application_info: vk.ApplicationInfo = .{
        .p_application_name = "keywork-compositor",
        .application_version = 0,
        .p_engine_name = "keywork",
        .engine_version = 0,
        .api_version = vk.API_VERSION_1_0.toU32(),
    };
    const available_instance_extensions = base_wrapper.enumerateInstanceExtensionPropertiesAlloc(
        null,
        allocator,
    ) catch return error.VulkanUnavailable;
    defer allocator.free(available_instance_extensions);
    const dmabuf_instance_capable =
        hasExtension(available_instance_extensions, std.mem.span(instance_extensions[0])) and
        hasExtension(available_instance_extensions, std.mem.span(instance_extensions[1])) and
        hasExtension(available_instance_extensions, std.mem.span(instance_extensions[2]));
    const enabled_instance_extensions: []const [*:0]const u8 = if (dmabuf_instance_capable)
        &instance_extensions
    else
        &.{};
    const instance = base_wrapper.createInstance(&.{
        .p_application_info = &application_info,
        .enabled_extension_count = @intCast(enabled_instance_extensions.len),
        .pp_enabled_extension_names = enabled_instance_extensions.ptr,
    }, null) catch return error.VulkanUnavailable;
    errdefer {
        const wrapper = vk.InstanceWrapper.load(
            instance,
            base_wrapper.dispatch.vkGetInstanceProcAddr.?,
        );
        wrapper.destroyInstance(instance, null);
    }

    const instance_wrapper = vk.InstanceWrapper.load(
        instance,
        base_wrapper.dispatch.vkGetInstanceProcAddr.?,
    );
    const physical_devices = instance_wrapper.enumeratePhysicalDevicesAlloc(
        instance,
        allocator,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.VulkanUnavailable,
    };
    defer allocator.free(physical_devices);
    if (physical_devices.len == 0) return error.NoPhysicalDevice;
    var physical_device = physical_devices[0];
    var dmabuf_capable = false;
    var dmabuf_device_id: ?render.DrmDeviceId = null;
    if (dmabuf_instance_capable) find: for (physical_devices) |candidate| {
        const extensions = instance_wrapper.enumerateDeviceExtensionPropertiesAlloc(
            candidate,
            null,
            allocator,
        ) catch continue;
        defer allocator.free(extensions);
        for (dmabuf_device_extensions) |name| {
            if (!hasExtension(extensions, std.mem.span(name))) continue :find;
        }
        var drm_properties: vk.PhysicalDeviceDrmPropertiesEXT = undefined;
        drm_properties.s_type = .physical_device_drm_properties_ext;
        drm_properties.p_next = null;
        var properties: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
        properties.p_next = &drm_properties;
        instance_wrapper.getPhysicalDeviceProperties2KHR(candidate, &properties);
        if (drm_device_id) |wanted| {
            const primary_matches = drm_properties.has_primary == .true and
                drm_properties.primary_major == wanted.major and
                drm_properties.primary_minor == wanted.minor;
            const render_matches = drm_properties.has_render == .true and
                drm_properties.render_major == wanted.major and
                drm_properties.render_minor == wanted.minor;
            if (!primary_matches and !render_matches) continue;
        } else if (drm_properties.has_render != .true) {
            // Headless rendering needs an unprivileged render node to identify
            // the same device to DMA-BUF clients.
            continue;
        }
        physical_device = candidate;
        dmabuf_capable = true;
        dmabuf_device_id = if (drm_properties.has_render == .true) .{
            .major = @intCast(drm_properties.render_major),
            .minor = @intCast(drm_properties.render_minor),
        } else .{
            .major = @intCast(drm_properties.primary_major),
            .minor = @intCast(drm_properties.primary_minor),
        };
        break;
    };

    const queue_families = instance_wrapper.getPhysicalDeviceQueueFamilyPropertiesAlloc(
        physical_device,
        allocator,
    ) catch return error.OutOfMemory;
    defer allocator.free(queue_families);
    const queue_family_index = for (queue_families, 0..) |family, index| {
        if (family.queue_count > 0 and family.queue_flags.graphics_bit) {
            break @as(u32, @intCast(index));
        }
    } else return error.NoQueueFamily;
    const timestamp_valid_bits = queue_families[queue_family_index].timestamp_valid_bits;
    const timestamp_period = instance_wrapper.getPhysicalDeviceProperties(
        physical_device,
    ).limits.timestamp_period;

    const queue_priority: f32 = 1.0;
    const queue_create_info: vk.DeviceQueueCreateInfo = .{
        .queue_family_index = queue_family_index,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&queue_priority),
    };
    const enabled_device_extensions: []const [*:0]const u8 = if (dmabuf_capable)
        &dmabuf_device_extensions
    else
        &.{};
    var supported_ycbcr: vk.PhysicalDeviceSamplerYcbcrConversionFeatures = .{};
    var physical_features: vk.PhysicalDeviceFeatures2 = .{ .features = undefined };
    if (dmabuf_capable) {
        physical_features.p_next = &supported_ycbcr;
        instance_wrapper.getPhysicalDeviceFeatures2KHR(physical_device, &physical_features);
    }
    const ycbcr_capable = dmabuf_capable and supported_ycbcr.sampler_ycbcr_conversion == .true;
    var enabled_ycbcr: vk.PhysicalDeviceSamplerYcbcrConversionFeatures = .{
        .sampler_ycbcr_conversion = .true,
    };
    const device = instance_wrapper.createDevice(physical_device, &.{
        .p_next = if (ycbcr_capable) &enabled_ycbcr else null,
        .queue_create_info_count = 1,
        .p_queue_create_infos = @ptrCast(&queue_create_info),
        .enabled_extension_count = @intCast(enabled_device_extensions.len),
        .pp_enabled_extension_names = enabled_device_extensions.ptr,
    }, null) catch return error.VulkanUnavailable;
    errdefer {
        const wrapper = vk.DeviceWrapper.load(
            device,
            instance_wrapper.dispatch.vkGetDeviceProcAddr.?,
        );
        wrapper.destroyDevice(device, null);
    }

    const device_wrapper = vk.DeviceWrapper.load(
        device,
        instance_wrapper.dispatch.vkGetDeviceProcAddr.?,
    );
    const command_pool = device_wrapper.createCommandPool(device, &.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = queue_family_index,
    }, null) catch return error.VulkanUnavailable;
    errdefer device_wrapper.destroyCommandPool(device, command_pool, null);

    var command_buffer: vk.CommandBuffer = undefined;
    device_wrapper.allocateCommandBuffers(device, &.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer)) catch return error.VulkanUnavailable;

    var sync_fd_properties: vk.ExternalSemaphoreProperties = .{
        .export_from_imported_handle_types = .{},
        .compatible_handle_types = .{},
    };
    if (dmabuf_capable) instance_wrapper.getPhysicalDeviceExternalSemaphorePropertiesKHR(
        physical_device,
        &.{ .handle_type = .{ .sync_fd_bit = true } },
        &sync_fd_properties,
    );
    const sync_fd_capable = dmabuf_capable and
        sync_fd_properties.external_semaphore_features.exportable_bit and
        sync_fd_properties.external_semaphore_features.importable_bit;

    const format = chooseFormat(instance_wrapper, physical_device) orelse
        return error.VulkanUnavailable;
    const working_features = instance_wrapper.getPhysicalDeviceFormatProperties(
        physical_device,
        working_format,
    ).optimal_tiling_features;
    if (!working_features.color_attachment_bit or
        !working_features.color_attachment_blend_bit or
        !working_features.sampled_image_bit or
        !working_features.sampled_image_filter_linear_bit)
    {
        return error.VulkanUnavailable;
    }
    if (format != .b8g8r8a8_unorm) {
        dmabuf_capable = false;
        dmabuf_device_id = null;
    }
    var dmabuf_modifiers: []u64 = &.{};
    var dmabuf_sampled_modifiers: []u64 = &.{};
    var dmabuf_10bit_modifiers: []u64 = &.{};
    var dmabuf_10bit_sampled_modifiers: []u64 = &.{};
    var dmabuf_target_formats: []render.DmabufFormatModifier = &.{};
    var dmabuf_source_modifiers: []u64 = &.{};
    var dmabuf_rgba_source_modifiers: []u64 = &.{};
    var dmabuf_nv12_source_modifiers: []u64 = &.{};
    var dmabuf_p010_source_modifiers: []u64 = &.{};
    var dmabuf_source_formats: []render.DmabufFormatModifier = &.{};
    var ycbcr_descriptor_count: u32 = 1;
    if (dmabuf_capable) {
        var modifier_list: vk.DrmFormatModifierPropertiesListEXT = .{};
        var format_properties: vk.FormatProperties2 = .{ .format_properties = undefined };
        format_properties.p_next = &modifier_list;
        instance_wrapper.getPhysicalDeviceFormatProperties2KHR(
            physical_device,
            .b8g8r8a8_unorm,
            &format_properties,
        );
        const properties = allocator.alloc(
            vk.DrmFormatModifierPropertiesEXT,
            modifier_list.drm_format_modifier_count,
        ) catch return error.OutOfMemory;
        defer allocator.free(properties);
        modifier_list.p_drm_format_modifier_properties = properties.ptr;
        instance_wrapper.getPhysicalDeviceFormatProperties2KHR(
            physical_device,
            .b8g8r8a8_unorm,
            &format_properties,
        );
        var modifiers: std.ArrayList(u64) = .empty;
        defer modifiers.deinit(allocator);
        var fallback_modifiers: std.ArrayList(u64) = .empty;
        defer fallback_modifiers.deinit(allocator);
        var sampled_modifiers: std.ArrayList(u64) = .empty;
        defer sampled_modifiers.deinit(allocator);
        var source_modifiers: std.ArrayList(u64) = .empty;
        defer source_modifiers.deinit(allocator);
        for (properties) |property| {
            const features = property.drm_format_modifier_tiling_features;
            if (property.drm_format_modifier_plane_count == 1 and
                features.color_attachment_bit and features.color_attachment_blend_bit and
                features.transfer_dst_bit and (features.transfer_src_bit or
                (features.sampled_image_bit and features.sampled_image_filter_linear_bit)))
            {
                if (features.sampled_image_bit and features.sampled_image_filter_linear_bit) {
                    modifiers.append(allocator, property.drm_format_modifier) catch
                        return error.OutOfMemory;
                    sampled_modifiers.append(allocator, property.drm_format_modifier) catch
                        return error.OutOfMemory;
                } else {
                    fallback_modifiers.append(allocator, property.drm_format_modifier) catch
                        return error.OutOfMemory;
                }
            }
            if (property.drm_format_modifier_plane_count == 1 and
                features.sampled_image_bit and features.sampled_image_filter_linear_bit and
                dmabufSourceModifierImportable(
                    instance_wrapper,
                    physical_device,
                    .b8g8r8a8_unorm,
                    property.drm_format_modifier,
                ) != null)
            {
                source_modifiers.append(allocator, property.drm_format_modifier) catch
                    return error.OutOfMemory;
            }
        }
        modifiers.appendSlice(allocator, fallback_modifiers.items) catch return error.OutOfMemory;
        dmabuf_modifiers = modifiers.toOwnedSlice(allocator) catch return error.OutOfMemory;
        errdefer if (dmabuf_modifiers.len != 0) allocator.free(dmabuf_modifiers);
        dmabuf_sampled_modifiers = sampled_modifiers.toOwnedSlice(allocator) catch
            return error.OutOfMemory;
        errdefer if (dmabuf_sampled_modifiers.len != 0) allocator.free(dmabuf_sampled_modifiers);
        const ten_bit = try queryDmabufTargetModifiers(
            allocator,
            instance_wrapper,
            physical_device,
            .a2r10g10b10_unorm_pack32,
        );
        dmabuf_10bit_modifiers = ten_bit.supported;
        errdefer if (dmabuf_10bit_modifiers.len != 0) allocator.free(dmabuf_10bit_modifiers);
        dmabuf_10bit_sampled_modifiers = ten_bit.sampleable;
        errdefer if (dmabuf_10bit_sampled_modifiers.len != 0) {
            allocator.free(dmabuf_10bit_sampled_modifiers);
        };
        dmabuf_target_formats = try allocator.alloc(
            render.DmabufFormatModifier,
            dmabuf_10bit_modifiers.len + dmabuf_modifiers.len * 2,
        );
        errdefer allocator.free(dmabuf_target_formats);
        for (dmabuf_10bit_modifiers, dmabuf_target_formats[0..dmabuf_10bit_modifiers.len]) |modifier, *target| target.* = .{
            .format = @intFromEnum(render.DmabufFormat.xrgb2101010),
            .modifier = modifier,
        };
        const xrgb_start = dmabuf_10bit_modifiers.len;
        const argb_start = xrgb_start + dmabuf_modifiers.len;
        for (dmabuf_modifiers, dmabuf_target_formats[xrgb_start..argb_start]) |modifier, *target| target.* = .{
            .format = @intFromEnum(render.DmabufFormat.xrgb8888),
            .modifier = modifier,
        };
        for (dmabuf_modifiers, dmabuf_target_formats[argb_start..]) |modifier, *target| target.* = .{
            .format = @intFromEnum(render.DmabufFormat.argb8888),
            .modifier = modifier,
        };
        dmabuf_source_modifiers = source_modifiers.toOwnedSlice(allocator) catch
            return error.OutOfMemory;
        errdefer if (dmabuf_source_modifiers.len != 0) allocator.free(dmabuf_source_modifiers);
        const rgba_source = try queryDmabufSourceModifiers(
            allocator,
            instance_wrapper,
            physical_device,
            .r8g8b8a8_unorm,
            1,
            false,
        );
        dmabuf_rgba_source_modifiers = rgba_source.modifiers;
        errdefer if (dmabuf_rgba_source_modifiers.len != 0) {
            allocator.free(dmabuf_rgba_source_modifiers);
        };
        if (ycbcr_capable) {
            const nv12_source = try queryDmabufSourceModifiers(
                allocator,
                instance_wrapper,
                physical_device,
                .g8_b8r8_2plane_420_unorm,
                2,
                true,
            );
            dmabuf_nv12_source_modifiers = nv12_source.modifiers;
            ycbcr_descriptor_count = @max(
                ycbcr_descriptor_count,
                nv12_source.max_descriptor_count,
            );
            errdefer if (dmabuf_nv12_source_modifiers.len != 0) {
                allocator.free(dmabuf_nv12_source_modifiers);
            };
            const p010_source = try queryDmabufSourceModifiers(
                allocator,
                instance_wrapper,
                physical_device,
                .g10x6_b10x6r10x6_2plane_420_unorm_3pack16,
                2,
                true,
            );
            dmabuf_p010_source_modifiers = p010_source.modifiers;
            ycbcr_descriptor_count = @max(
                ycbcr_descriptor_count,
                p010_source.max_descriptor_count,
            );
            errdefer if (dmabuf_p010_source_modifiers.len != 0) {
                allocator.free(dmabuf_p010_source_modifiers);
            };
        }
        var pairs: std.ArrayList(render.DmabufFormatModifier) = .empty;
        defer pairs.deinit(allocator);
        for (dmabuf_source_modifiers) |modifier| for ([_]render.DmabufFormat{
            .argb8888, .xrgb8888,
        }) |source_format| try pairs.append(allocator, .{
            .format = @intFromEnum(source_format),
            .modifier = modifier,
        });
        for (dmabuf_rgba_source_modifiers) |modifier| for ([_]render.DmabufFormat{
            .abgr8888, .xbgr8888,
        }) |source_format| try pairs.append(allocator, .{
            .format = @intFromEnum(source_format),
            .modifier = modifier,
        });
        for (dmabuf_nv12_source_modifiers) |modifier| try pairs.append(allocator, .{
            .format = @intFromEnum(render.DmabufFormat.nv12),
            .modifier = modifier,
        });
        for (dmabuf_p010_source_modifiers) |modifier| try pairs.append(allocator, .{
            .format = @intFromEnum(render.DmabufFormat.p010),
            .modifier = modifier,
        });
        dmabuf_source_formats = try pairs.toOwnedSlice(allocator);
    }
    errdefer if (dmabuf_modifiers.len != 0) allocator.free(dmabuf_modifiers);
    errdefer if (dmabuf_sampled_modifiers.len != 0) allocator.free(dmabuf_sampled_modifiers);
    errdefer if (dmabuf_10bit_modifiers.len != 0) allocator.free(dmabuf_10bit_modifiers);
    errdefer if (dmabuf_10bit_sampled_modifiers.len != 0) {
        allocator.free(dmabuf_10bit_sampled_modifiers);
    };
    errdefer if (dmabuf_target_formats.len != 0) allocator.free(dmabuf_target_formats);
    errdefer if (dmabuf_source_modifiers.len != 0) allocator.free(dmabuf_source_modifiers);
    errdefer if (dmabuf_rgba_source_modifiers.len != 0) {
        allocator.free(dmabuf_rgba_source_modifiers);
    };
    errdefer if (dmabuf_nv12_source_modifiers.len != 0) {
        allocator.free(dmabuf_nv12_source_modifiers);
    };
    errdefer if (dmabuf_p010_source_modifiers.len != 0) {
        allocator.free(dmabuf_p010_source_modifiers);
    };
    errdefer if (dmabuf_source_formats.len != 0) allocator.free(dmabuf_source_formats);
    const graphics = initGraphics(
        device_wrapper,
        device,
        format,
        dmabuf_10bit_modifiers.len != 0,
        ycbcr_descriptor_count,
    ) catch |err| {
        log.err("failed to initialize Vulkan graphics pipelines: {t}", .{err});
        return error.VulkanUnavailable;
    };
    errdefer destroyGraphics(device_wrapper, device, graphics);

    return .{
        .allocator = allocator,
        .loader = loader,
        .instance_wrapper = instance_wrapper,
        .device_wrapper = device_wrapper,
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .queue = device_wrapper.getDeviceQueue(device, queue_family_index, 0),
        .queue_family_index = queue_family_index,
        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .timestamp_valid_bits = timestamp_valid_bits,
        .timestamp_period = timestamp_period,
        .scanout_sync_enabled = sync_fd_capable,
        .completed_gpu_timings = undefined,
        .completed_gpu_timing_count = 0,
        .format = format,
        .swap_red_blue = format == .r8g8b8a8_unorm,
        .render_pass = graphics.render_pass,
        .scratch_render_pass = graphics.scratch_render_pass,
        .output_render_pass = graphics.output_render_pass,
        .output_10bit = graphics.output_10bit,
        .descriptor_set_layout = graphics.descriptor_set_layout,
        .descriptor_pool = graphics.descriptor_pool,
        .pipeline_layout = graphics.pipeline_layout,
        .replace_pipeline = graphics.replace_pipeline,
        .blend_pipeline = graphics.blend_pipeline,
        .image_pipeline = graphics.image_pipeline,
        .crossfade_pipeline = graphics.crossfade_pipeline,
        .opaque_image_pipeline = graphics.opaque_image_pipeline,
        .nearest_image_pipeline = graphics.nearest_image_pipeline,
        .opaque_nearest_image_pipeline = graphics.opaque_nearest_image_pipeline,
        .nearest_gamma22_image_pipeline = graphics.nearest_gamma22_image_pipeline,
        .opaque_nearest_gamma22_image_pipeline = graphics.opaque_nearest_gamma22_image_pipeline,
        .backdrop_image_pipeline = graphics.backdrop_image_pipeline,
        .reconstruction_image_pipeline = graphics.reconstruction_image_pipeline,
        .opaque_reconstruction_image_pipeline = graphics.opaque_reconstruction_image_pipeline,
        .area_image_pipeline = graphics.area_image_pipeline,
        .opaque_area_image_pipeline = graphics.opaque_area_image_pipeline,
        .shadow_pipeline = graphics.shadow_pipeline,
        .downsample_pipeline = graphics.downsample_pipeline,
        .blur_downsample_pipeline = graphics.blur_downsample_pipeline,
        .blur_upsample_pipeline = graphics.blur_upsample_pipeline,
        .blur_composite_pipeline = graphics.blur_composite_pipeline,
        .encode_pipeline = graphics.encode_pipeline,
        .encode_calibrated_pipeline = graphics.encode_calibrated_pipeline,
        .sampler = graphics.sampler,
        .dmabuf_modifiers = if (dmabuf_capable) dmabuf_modifiers else &.{},
        .dmabuf_sampled_modifiers = if (dmabuf_capable) dmabuf_sampled_modifiers else &.{},
        .dmabuf_10bit_modifiers = if (dmabuf_capable) dmabuf_10bit_modifiers else &.{},
        .dmabuf_10bit_sampled_modifiers = if (dmabuf_capable)
            dmabuf_10bit_sampled_modifiers
        else
            &.{},
        .dmabuf_target_formats = if (dmabuf_capable) dmabuf_target_formats else &.{},
        .dmabuf_source_modifiers = if (dmabuf_capable) dmabuf_source_modifiers else &.{},
        .dmabuf_rgba_source_modifiers = if (dmabuf_capable)
            dmabuf_rgba_source_modifiers
        else
            &.{},
        .dmabuf_nv12_source_modifiers = if (dmabuf_capable)
            dmabuf_nv12_source_modifiers
        else
            &.{},
        .dmabuf_p010_source_modifiers = if (dmabuf_capable)
            dmabuf_p010_source_modifiers
        else
            &.{},
        .dmabuf_source_formats = if (dmabuf_capable) dmabuf_source_formats else &.{},
        .dmabuf_device_id = dmabuf_device_id,
        .frame_number = 0,
        .resource_epoch = 1,
        .fallback = CpuRenderer.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.device_wrapper.deviceWaitIdle(self.device) catch {};
    self.releaseAllPendingAfterDeviceIdle();
    self.fallback.deinit();
    self.destroyCachedResources();
    if (self.dmabuf_modifiers.len != 0) self.allocator.free(self.dmabuf_modifiers);
    if (self.dmabuf_sampled_modifiers.len != 0) self.allocator.free(self.dmabuf_sampled_modifiers);
    if (self.dmabuf_10bit_modifiers.len != 0) self.allocator.free(self.dmabuf_10bit_modifiers);
    if (self.dmabuf_10bit_sampled_modifiers.len != 0) {
        self.allocator.free(self.dmabuf_10bit_sampled_modifiers);
    }
    if (self.dmabuf_target_formats.len != 0) self.allocator.free(self.dmabuf_target_formats);
    if (self.dmabuf_source_modifiers.len != 0) self.allocator.free(self.dmabuf_source_modifiers);
    if (self.dmabuf_rgba_source_modifiers.len != 0) {
        self.allocator.free(self.dmabuf_rgba_source_modifiers);
    }
    if (self.dmabuf_nv12_source_modifiers.len != 0) {
        self.allocator.free(self.dmabuf_nv12_source_modifiers);
    }
    if (self.dmabuf_p010_source_modifiers.len != 0) {
        self.allocator.free(self.dmabuf_p010_source_modifiers);
    }
    if (self.dmabuf_source_formats.len != 0) self.allocator.free(self.dmabuf_source_formats);
    self.instances.deinit(self.allocator);
    self.draw_runs.deinit(self.allocator);
    self.blur_ops.deinit(self.allocator);
    self.prepared_images.deinit(self.allocator);
    destroyGraphics(self.device_wrapper, self.device, .{
        .render_pass = self.render_pass,
        .scratch_render_pass = self.scratch_render_pass,
        .output_render_pass = self.output_render_pass,
        .output_10bit = self.output_10bit,
        .descriptor_set_layout = self.descriptor_set_layout,
        .descriptor_pool = self.descriptor_pool,
        .pipeline_layout = self.pipeline_layout,
        .replace_pipeline = self.replace_pipeline,
        .blend_pipeline = self.blend_pipeline,
        .image_pipeline = self.image_pipeline,
        .crossfade_pipeline = self.crossfade_pipeline,
        .opaque_image_pipeline = self.opaque_image_pipeline,
        .nearest_image_pipeline = self.nearest_image_pipeline,
        .opaque_nearest_image_pipeline = self.opaque_nearest_image_pipeline,
        .nearest_gamma22_image_pipeline = self.nearest_gamma22_image_pipeline,
        .opaque_nearest_gamma22_image_pipeline = self.opaque_nearest_gamma22_image_pipeline,
        .backdrop_image_pipeline = self.backdrop_image_pipeline,
        .reconstruction_image_pipeline = self.reconstruction_image_pipeline,
        .opaque_reconstruction_image_pipeline = self.opaque_reconstruction_image_pipeline,
        .area_image_pipeline = self.area_image_pipeline,
        .opaque_area_image_pipeline = self.opaque_area_image_pipeline,
        .shadow_pipeline = self.shadow_pipeline,
        .downsample_pipeline = self.downsample_pipeline,
        .blur_downsample_pipeline = self.blur_downsample_pipeline,
        .blur_upsample_pipeline = self.blur_upsample_pipeline,
        .blur_composite_pipeline = self.blur_composite_pipeline,
        .encode_pipeline = self.encode_pipeline,
        .encode_calibrated_pipeline = self.encode_calibrated_pipeline,
        .sampler = self.sampler,
    });
    self.device_wrapper.destroyCommandPool(self.device, self.command_pool, null);
    self.device_wrapper.destroyDevice(self.device, null);
    self.instance_wrapper.destroyInstance(self.instance, null);
    self.loader.close();
    self.* = undefined;
}

pub fn dmabufAccess(self: *Self) ?render.DmabufRenderer {
    if (self.dmabuf_target_formats.len == 0) return null;
    return .{
        .context = self,
        .target_formats = self.dmabuf_target_formats,
        .supports_target = supportsTargetCallback,
        .import_target = importTargetCallback,
        .release_target = releaseTargetCallback,
    };
}

fn outputGraphics(self: *const Self, format: vk.Format) OutputGraphics {
    if (format == self.format) return .{
        .render_pass = self.output_render_pass,
        .encode_pipeline = self.encode_pipeline,
        .encode_calibrated_pipeline = self.encode_calibrated_pipeline,
    };
    if (format == .a2r10g10b10_unorm_pack32) return self.output_10bit orelse unreachable;
    unreachable;
}

pub fn dmabufDeviceId(self: *const Self) ?render.DrmDeviceId {
    if (self.dmabuf_source_modifiers.len == 0 and
        self.dmabuf_rgba_source_modifiers.len == 0) return null;
    return self.dmabuf_device_id;
}

pub fn dmabufSourceFormats(self: *const Self) []const render.DmabufFormatModifier {
    return self.dmabuf_source_formats;
}

pub fn dmabufSourceValidator(self: *Self) ?render.DmabufSourceValidator {
    if (self.dmabuf_source_formats.len == 0) return null;
    return .{ .context = self, .validate = validateSourceCallback };
}

fn validateSourceCallback(
    context: *anyopaque,
    descriptor: render.DmabufSourceDescriptor,
) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(context));
    std.debug.assert(descriptor.modifier != 0);
    const source_format = render.DmabufFormat.fromFourcc(descriptor.format) orelse
        return error.InvalidTarget;
    const Noop = struct {
        fn retain(_: *anyopaque) void {}
        fn release(_: *anyopaque) void {}
        fn sync(_: *anyopaque) bool {
            return true;
        }
        fn exportFence(_: *anyopaque, _: u8) ?std.posix.fd_t {
            return null;
        }
    };
    var source_context: u8 = 0;
    const texture = try self.createImportedTexture(
        descriptor.size,
        .{
            .context = &source_context,
            .format = descriptor.format,
            .modifier = descriptor.modifier,
            .planes = descriptor.planes,
            .plane_count = descriptor.plane_count,
            .y_inverted = false,
            .force_opaque = descriptor.force_opaque,
            .retain = Noop.retain,
            .release = Noop.release,
            .begin_cpu_read = Noop.sync,
            .end_cpu_read = Noop.sync,
            .export_read_fence = Noop.exportFence,
        },
        if (source_format.isPackedRgb()) .{} else vulkan_format.defaultRepresentation(),
    );
    self.destroyTexture(texture);
}

pub fn offscreenAccess(self: *Self) render.OffscreenRenderer {
    return .{
        .context = self,
        .create_target = createOffscreenTargetCallback,
        .release_target = releaseOffscreenTargetCallback,
    };
}

fn createOffscreenTargetCallback(context: *anyopaque, size: render.Size) anyerror!render.OffscreenTarget {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.createOffscreenTarget(size);
}

fn releaseOffscreenTargetCallback(context: *anyopaque, id: u64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.releaseOutput(.{ .offscreen = id });
}

fn createOffscreenTarget(self: *Self, size: render.Size) Error!render.OffscreenTarget {
    if (size.width == 0 or size.height == 0) return error.InvalidTarget;
    const id = render.allocateRenderTargetId();
    const key: TargetKey = .{ .offscreen = id };
    std.debug.assert(!self.outputs.contains(key));
    var output = try self.createOutput(size);
    errdefer self.destroyOutput(output);
    output.kind = .offscreen;
    self.outputs.put(self.allocator, key, output) catch return error.OutOfMemory;
    return .{ .id = id, .size = size };
}

fn supportsTargetCallback(
    context: *anyopaque,
    size: render.Size,
    format: u32,
    modifier: u64,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.supportsDmabufTarget(size, format, modifier);
}

fn importTargetCallback(context: *anyopaque, descriptor: render.DmabufDescriptor) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(context));
    try self.importTarget(descriptor);
}

fn releaseTargetCallback(context: *anyopaque, id: u64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.releaseTarget(id);
}

fn importTarget(self: *Self, descriptor: render.DmabufDescriptor) Error!void {
    const target_format = vulkan_format.targetVkFormat(descriptor.format) orelse
        return error.InvalidTarget;
    if (descriptor.id == 0 or
        descriptor.size.width == 0 or descriptor.size.height == 0 or
        @as(u64, descriptor.stride) < @as(u64, descriptor.size.width) * @sizeOf(u32) or
        self.outputs.contains(.{ .dmabuf = descriptor.id }) or
        !self.supportsDmabufTarget(descriptor.size, descriptor.format, descriptor.modifier))
        return error.InvalidTarget;

    const sampleable = self.dmabufTargetSampleable(descriptor.format, descriptor.modifier);
    const image_usage = dmabufTargetUsage(sampleable);

    const duplicate_fd = std.c.dup(descriptor.fd);
    if (duplicate_fd < 0) return error.VulkanFailure;
    var fd_owned = true;
    defer if (fd_owned) {
        _ = std.c.close(duplicate_fd);
    };
    const plane: vk.SubresourceLayout = .{
        .offset = descriptor.offset,
        .size = 0,
        .row_pitch = descriptor.stride,
        .array_pitch = 0,
        .depth_pitch = 0,
    };
    var modifier_info: vk.ImageDrmFormatModifierExplicitCreateInfoEXT = .{
        .drm_format_modifier = descriptor.modifier,
        .drm_format_modifier_plane_count = 1,
        .p_plane_layouts = @ptrCast(&plane),
    };
    const external_info: vk.ExternalMemoryImageCreateInfo = .{
        .p_next = &modifier_info,
        .handle_types = .{ .dma_buf_bit_ext = true },
    };
    const image = self.device_wrapper.createImage(self.device, &.{
        .p_next = &external_info,
        .image_type = .@"2d",
        .format = target_format,
        .extent = extent(descriptor.size),
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .drm_format_modifier_ext,
        .usage = image_usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImage(self.device, image, null);
    const requirements = self.device_wrapper.getImageMemoryRequirements(self.device, image);
    var fd_properties: vk.MemoryFdPropertiesKHR = .{ .memory_type_bits = 0 };
    self.device_wrapper.getMemoryFdPropertiesKHR(
        self.device,
        .{ .dma_buf_bit_ext = true },
        duplicate_fd,
        &fd_properties,
    ) catch return error.VulkanFailure;
    const memory_type = self.deviceMemoryType(
        requirements.memory_type_bits & fd_properties.memory_type_bits,
    ) orelse
        return error.VulkanFailure;
    const dedicated: vk.MemoryDedicatedAllocateInfo = .{ .image = image };
    const import_info: vk.ImportMemoryFdInfoKHR = .{
        .p_next = &dedicated,
        .handle_type = .{ .dma_buf_bit_ext = true },
        .fd = duplicate_fd,
    };
    const memory = self.device_wrapper.allocateMemory(self.device, &.{
        .p_next = &import_info,
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    }, null) catch return error.VulkanFailure;
    fd_owned = false;
    errdefer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindImageMemory(self.device, image, memory, 0) catch
        return error.VulkanFailure;
    const view = self.device_wrapper.createImageView(self.device, &.{
        .image = image,
        .view_type = .@"2d",
        .format = target_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = colorSubresourceRange(),
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImageView(self.device, view, null);
    const descriptor_set = if (sampleable) try self.createImageDescriptor(view) else vk.DescriptorSet.null_handle;
    errdefer if (descriptor_set != .null_handle) self.destroyImageDescriptor(descriptor_set);
    const framebuffer = self.device_wrapper.createFramebuffer(self.device, &.{
        .render_pass = self.outputGraphics(target_format).render_pass,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&view),
        .width = descriptor.size.width,
        .height = descriptor.size.height,
        .layers = 1,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyFramebuffer(self.device, framebuffer, null);
    const linear = try self.createWorkingTarget(descriptor.size);
    errdefer self.destroyWorkingTarget(linear);
    const command_buffer = try self.allocateCommandBuffer();
    errdefer self.device_wrapper.freeCommandBuffers(
        self.device,
        self.command_pool,
        &.{command_buffer},
    );
    const submission = try self.createSubmission();
    errdefer self.destroySubmission(submission);
    self.outputs.put(self.allocator, .{ .dmabuf = descriptor.id }, .{
        .image = image,
        .memory = memory,
        .view = view,
        .descriptor_set = descriptor_set,
        .framebuffer = framebuffer,
        .format = target_format,
        .size = descriptor.size,
        .kind = .dmabuf,
        .last_used = self.frame_number,
        .command_buffer = command_buffer,
        .linear = linear,
        .submission = submission,
    }) catch return error.OutOfMemory;
}

fn allocateCommandBuffer(self: *Self) Error!vk.CommandBuffer {
    var command_buffer: vk.CommandBuffer = undefined;
    self.device_wrapper.allocateCommandBuffers(self.device, &.{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer)) catch return error.VulkanFailure;
    return command_buffer;
}

fn createSubmission(self: *Self) Error!Submission {
    const fence = self.device_wrapper.createFence(self.device, &.{}, null) catch
        return error.VulkanFailure;
    errdefer self.device_wrapper.destroyFence(self.device, fence, null);

    const timestamp_query_pool = if (self.timestamp_valid_bits == 0)
        vk.QueryPool.null_handle
    else
        self.device_wrapper.createQueryPool(self.device, &.{
            .query_type = .timestamp,
            .query_count = timestamp_query_count,
        }, null) catch |err| pool: {
            log.warn("failed to create Vulkan timestamp query pool: {t}", .{err});
            break :pool vk.QueryPool.null_handle;
        };
    errdefer if (timestamp_query_pool != .null_handle) {
        self.device_wrapper.destroyQueryPool(self.device, timestamp_query_pool, null);
    };

    var scanout_semaphore = vk.Semaphore.null_handle;
    if (self.scanout_sync_enabled) {
        const export_info: vk.ExportSemaphoreCreateInfo = .{
            .handle_types = .{ .sync_fd_bit = true },
        };
        scanout_semaphore = self.device_wrapper.createSemaphore(self.device, &.{
            .p_next = &export_info,
        }, null) catch .null_handle;
    }
    return .{
        .fence = fence,
        .scanout_semaphore = scanout_semaphore,
        .timestamp_query_pool = timestamp_query_pool,
    };
}

fn supportsDmabufTarget(self: *Self, size: render.Size, format: u32, modifier: u64) bool {
    const target_format = vulkan_format.targetVkFormat(format) orelse return false;
    if (size.width == 0 or size.height == 0 or
        !render.DmabufFormatModifier.contains(self.dmabuf_target_formats, format, modifier) or
        (target_format == .a2r10g10b10_unorm_pack32 and self.output_10bit == null))
        return false;

    const modifier_info: vk.PhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .drm_format_modifier = modifier,
        .sharing_mode = .exclusive,
    };
    const external_info: vk.PhysicalDeviceExternalImageFormatInfo = .{
        .p_next = &modifier_info,
        .handle_type = .{ .dma_buf_bit_ext = true },
    };
    const sampleable = self.dmabufTargetSampleable(format, modifier);
    const format_info: vk.PhysicalDeviceImageFormatInfo2 = .{
        .p_next = &external_info,
        .format = target_format,
        .type = .@"2d",
        .tiling = .drm_format_modifier_ext,
        .usage = dmabufTargetUsage(sampleable),
    };
    var external_properties: vk.ExternalImageFormatProperties = .{
        .external_memory_properties = undefined,
    };
    var format_properties: vk.ImageFormatProperties2 = .{
        .p_next = &external_properties,
        .image_format_properties = undefined,
    };
    self.instance_wrapper.getPhysicalDeviceImageFormatProperties2KHR(
        self.physical_device,
        &format_info,
        &format_properties,
    ) catch return false;
    const maximum = format_properties.image_format_properties.max_extent;
    return external_properties.external_memory_properties.external_memory_features.importable_bit and
        size.width <= maximum.width and size.height <= maximum.height;
}

fn dmabufTargetSampleable(self: *const Self, format: u32, modifier: u64) bool {
    const modifiers = switch (render.DmabufFormat.fromFourcc(format) orelse return false) {
        .xrgb8888 => self.dmabuf_sampled_modifiers,
        .xrgb2101010 => self.dmabuf_10bit_sampled_modifiers,
        .argb8888, .abgr8888, .xbgr8888, .nv12, .p010 => return false,
    };
    return std.mem.indexOfScalar(u64, modifiers, modifier) != null;
}

fn dmabufTargetUsage(sampleable: bool) vk.ImageUsageFlags {
    return if (sampleable)
        .{ .color_attachment_bit = true, .transfer_dst_bit = true, .sampled_bit = true }
    else
        .{ .color_attachment_bit = true, .transfer_dst_bit = true, .transfer_src_bit = true };
}

fn supportsDmabufSource(self: *Self, size: render.Size, source: render.DmabufSource) bool {
    const source_format_info = render.DmabufFormat.fromFourcc(source.format) orelse return false;
    if (!vulkan_format.sourceExtentValid(source_format_info, size) or
        source.plane_count != source_format_info.planeCount()) return false;
    const source_format = vulkan_format.sourceVkFormat(source.format) orelse return false;
    const modifiers = switch (source_format) {
        .b8g8r8a8_unorm => self.dmabuf_source_modifiers,
        .r8g8b8a8_unorm => self.dmabuf_rgba_source_modifiers,
        .g8_b8r8_2plane_420_unorm => self.dmabuf_nv12_source_modifiers,
        .g10x6_b10x6r10x6_2plane_420_unorm_3pack16 => self.dmabuf_p010_source_modifiers,
        else => unreachable,
    };
    if (std.mem.indexOfScalar(u64, modifiers, source.modifier) == null) return false;

    const modifier_info: vk.PhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .drm_format_modifier = source.modifier,
        .sharing_mode = .exclusive,
    };
    const external_info: vk.PhysicalDeviceExternalImageFormatInfo = .{
        .p_next = &modifier_info,
        .handle_type = .{ .dma_buf_bit_ext = true },
    };
    const format_info: vk.PhysicalDeviceImageFormatInfo2 = .{
        .p_next = &external_info,
        .format = source_format,
        .type = .@"2d",
        .tiling = .drm_format_modifier_ext,
        .usage = .{ .sampled_bit = true },
    };
    var external_properties: vk.ExternalImageFormatProperties = .{
        .external_memory_properties = undefined,
    };
    var format_properties: vk.ImageFormatProperties2 = .{
        .p_next = &external_properties,
        .image_format_properties = undefined,
    };
    self.instance_wrapper.getPhysicalDeviceImageFormatProperties2KHR(
        self.physical_device,
        &format_info,
        &format_properties,
    ) catch return false;
    const maximum = format_properties.image_format_properties.max_extent;
    return external_properties.external_memory_properties.external_memory_features.importable_bit and
        size.width <= maximum.width and size.height <= maximum.height;
}

fn releaseTarget(self: *Self, id: u64) void {
    self.releaseOutput(.{ .dmabuf = id });
}

fn releaseOutput(self: *Self, key: TargetKey) void {
    if (!self.outputs.contains(key)) return;
    // A composed-frame export may still be sampling this output from another
    // output's submission. Every submission shares one queue, so draining all
    // of them is sufficient before releasing either side of that dependency.
    self.drainAllPending() catch {};
    if (self.outputs.fetchRemove(key)) |removed| self.destroyOutput(removed.value);
}

fn drainSubmission(self: *Self, submission: *Submission) Error!void {
    if (!submission.fence_pending) {
        std.debug.assert(submission.pending_wait_semaphores.items.len == 0);
        std.debug.assert(submission.pending_textures.items.len == 0);
        std.debug.assert(submission.pending_gpu_sample_tag == null);
        return;
    }
    const result = self.device_wrapper.waitForFences(
        self.device,
        &.{submission.fence},
        .true,
        std.math.maxInt(u64),
    ) catch {
        self.device_wrapper.deviceWaitIdle(self.device) catch {};
        submission.fence_pending = false;
        submission.pending_gpu_sample_tag = null;
        self.releasePendingResources(submission);
        return error.VulkanFailure;
    };
    if (result != .success) {
        self.device_wrapper.deviceWaitIdle(self.device) catch {};
        submission.fence_pending = false;
        submission.pending_gpu_sample_tag = null;
        self.releasePendingResources(submission);
        return error.VulkanFailure;
    }
    submission.fence_pending = false;
    self.finishPendingGpuTiming(submission);
    self.releasePendingResources(submission);
}

fn drainAllPending(self: *Self) Error!void {
    var iterator = self.outputs.valueIterator();
    while (iterator.next()) |output| try self.drainSubmission(&output.submission);
}

fn writeGpuTimestamp(
    self: *Self,
    submission: *const Submission,
    command_buffer: vk.CommandBuffer,
    query: u32,
) void {
    std.debug.assert(query < timestamp_query_count);
    if (submission.timestamp_query_pool == .null_handle) return;
    self.device_wrapper.cmdWriteTimestamp(
        command_buffer,
        .{ .bottom_of_pipe_bit = true },
        submission.timestamp_query_pool,
        query,
    );
}

fn finishPendingGpuTiming(self: *Self, submission: *Submission) void {
    const tag = submission.pending_gpu_sample_tag orelse return;
    submission.pending_gpu_sample_tag = null;
    std.debug.assert(submission.timestamp_query_pool != .null_handle);
    const plan = submission.pending_gpu_timing_plan;
    const query_count = plan.queryCount();
    var timestamps: [timestamp_query_count]u64 = undefined;
    const result = self.device_wrapper.getQueryPoolResults(
        self.device,
        submission.timestamp_query_pool,
        0,
        query_count,
        query_count * @sizeOf(u64),
        &timestamps,
        @sizeOf(u64),
        .{ .@"64_bit" = true },
    ) catch |err| {
        log.warn("failed to read Vulkan timestamp queries: {t}", .{err});
        return;
    };
    if (result != .success) {
        log.warn("Vulkan timestamp queries were unavailable after fence completion", .{});
        return;
    }
    if (self.completed_gpu_timing_count == self.completed_gpu_timings.len) {
        log.warn("dropping Vulkan GPU timestamp because the completion queue is full", .{});
        return;
    }
    self.completed_gpu_timings[self.completed_gpu_timing_count] = gpu_timing.fromTimestamps(
        tag,
        timestamps[0..query_count],
        plan,
        self.timestamp_valid_bits,
        self.timestamp_period,
    );
    self.completed_gpu_timing_count += 1;
}

pub fn takeGpuTiming(self: *Self) ?GpuTiming {
    if (self.completed_gpu_timing_count == 0) return null;
    const timing = self.completed_gpu_timings[0];
    if (self.completed_gpu_timing_count > 1) {
        @memmove(
            self.completed_gpu_timings[0 .. self.completed_gpu_timing_count - 1],
            self.completed_gpu_timings[1..self.completed_gpu_timing_count],
        );
    }
    self.completed_gpu_timing_count -= 1;
    return timing;
}

pub fn discardGpuTimings(self: *Self) void {
    var iterator = self.outputs.valueIterator();
    while (iterator.next()) |output| output.submission.pending_gpu_sample_tag = null;
    self.completed_gpu_timing_count = 0;
}

fn releasePendingResources(self: *Self, submission: *Submission) void {
    for (submission.pending_wait_semaphores.items) |semaphore| {
        self.device_wrapper.destroySemaphore(self.device, semaphore, null);
    }
    submission.pending_wait_semaphores.clearRetainingCapacity();
    for (submission.pending_textures.items) |texture| self.destroyTexture(texture);
    submission.pending_textures.clearRetainingCapacity();
}

fn disableScanoutSynchronization(self: *Self) void {
    self.scanout_sync_enabled = false;
    var iterator = self.outputs.valueIterator();
    while (iterator.next()) |output| {
        std.debug.assert(!output.submission.fence_pending);
        if (output.submission.scanout_semaphore == .null_handle) continue;
        self.device_wrapper.destroySemaphore(
            self.device,
            output.submission.scanout_semaphore,
            null,
        );
        output.submission.scanout_semaphore = .null_handle;
    }
}

fn releaseAllPendingAfterDeviceIdle(self: *Self) void {
    var iterator = self.outputs.valueIterator();
    while (iterator.next()) |output| {
        output.submission.fence_pending = false;
        output.submission.pending_gpu_sample_tag = null;
        self.releasePendingResources(&output.submission);
    }
}

fn destroySubmission(self: *Self, value: Submission) void {
    var submission = value;
    std.debug.assert(!submission.fence_pending);
    self.releasePendingResources(&submission);
    submission.pending_wait_semaphores.deinit(self.allocator);
    submission.pending_textures.deinit(self.allocator);
    self.destroyInstanceBuffer(&submission);
    self.destroyWorkBuffer(&submission);
    if (submission.scanout_semaphore != .null_handle) {
        self.device_wrapper.destroySemaphore(self.device, submission.scanout_semaphore, null);
    }
    if (submission.timestamp_query_pool != .null_handle) {
        self.device_wrapper.destroyQueryPool(self.device, submission.timestamp_query_pool, null);
    }
    self.device_wrapper.destroyFence(self.device, submission.fence, null);
}

pub fn renderFrame(self: *Self, frame: render.Frame, target: render.Target) Error!void {
    const completion = try self.renderFrameWithCompletion(frame, target, .wait, null);
    std.debug.assert(completion.sync_file_fd == null);
}

pub fn renderFrameReadback(
    self: *Self,
    frame: render.Frame,
    target: render.PixelBuffer,
) Error!render.FrameCompletion {
    std.debug.assert(frame.damage == null);
    return self.renderFrameWithCompletion(frame, .{ .pixels = target }, .readback, null);
}

pub fn completeFrameReadback(
    self: *Self,
    source: render.PixelBuffer,
    destination: ?render.PixelBuffer,
) Error!void {
    const key = targetKey(.{ .pixels = source });
    const output = self.outputs.getPtr(key) orelse return error.InvalidTarget;
    if (output.kind != .pixels) return error.InvalidTarget;
    try self.drainSubmission(&output.submission);
    const target = destination orelse return;
    if (!std.meta.eql(source.size, target.size) or
        source.stride_pixels != target.stride_pixels) return error.InvalidTarget;
    _ = try requiredBufferPixels(target);
    const mapped = output.submission.work_mapped orelse return error.InvalidTarget;
    copyMappedRect(target, mapped, .{
        .x = 0,
        .y = 0,
        .width = target.size.width,
        .height = target.size.height,
    });
}

pub fn copyComposedFrame(
    self: *Self,
    source_target: render.Target,
    source_region: ?render.Rect,
    target: render.Target,
    color_description: render.ColorDescription,
) Error!?render.FrameCompletion {
    const source_size = source_target.size();
    const size = target.size();
    const required_pixels = try validateTarget(.{
        .size = size,
        .commands = &.{},
    }, target);
    const source_rect = source_region orelse render.Rect{
        .x = 0,
        .y = 0,
        .width = source_size.width,
        .height = source_size.height,
    };
    if (source_rect.x < 0 or source_rect.y < 0 or
        @as(i64, source_rect.x) + source_rect.width > source_size.width or
        @as(i64, source_rect.y) + source_rect.height > source_size.height or
        source_rect.width != size.width or source_rect.height != size.height)
    {
        return error.InvalidTarget;
    }
    if (target == .offscreen) return null;

    const source_key = targetKey(source_target);
    const target_key = targetKey(target);
    if (std.meta.eql(source_key, target_key)) return error.InvalidTarget;

    self.frame_number +%= 1;
    try self.reclaimStaleResources();
    _ = try self.getOutput(target_key);
    const source = self.outputs.getPtr(source_key) orelse return null;
    const output = self.outputs.getPtr(target_key) orelse unreachable;
    if (!source.linear_initialized) return null;
    const convert_color = !std.meta.eql(source.color_description, color_description);
    if (convert_color and
        (source.color_description.transfer_function.isHdr() or
            color_description.transfer_function.isHdr() or
            source.color_description.min_luminance != color_description.min_luminance or
            source.color_description.max_luminance != color_description.max_luminance or
            source.color_description.reference_luminance != color_description.reference_luminance))
    {
        return null;
    }

    const submission = &output.submission;
    try self.drainSubmission(submission);
    if (!std.meta.eql(output.size, size)) return error.InvalidTarget;
    source.last_used = self.frame_number;
    output.last_used = self.frame_number;
    output.recorded_frame.valid = false;

    const pixel_target: ?render.PixelBuffer = switch (target) {
        .pixels => |pixels| pixels,
        .dmabuf => null,
        .offscreen => unreachable,
    };
    if (pixel_target != null) {
        const work_size = std.math.mul(usize, required_pixels, @sizeOf(u32)) catch
            return error.InvalidTarget;
        try self.ensureWorkBuffer(submission, work_size);
    }

    const full_output: render.Rect = .{
        .x = 0,
        .y = 0,
        .width = size.width,
        .height = size.height,
    };
    const prepare_linear = source_region != null or convert_color;
    const instances = [_]Instance{
        imageInstance(full_output, source_rect),
        imageInstance(full_output, full_output),
    };
    const instance_bytes = std.mem.sliceAsBytes(instances[0..@as(usize, if (prepare_linear) 2 else 1)]);
    try self.ensureInstanceBuffer(submission, instance_bytes.len);
    @memcpy(submission.instance_mapped.?[0..instance_bytes.len], instance_bytes);

    var frame_succeeded = false;
    defer if (!frame_succeeded) {
        self.device_wrapper.deviceWaitIdle(self.device) catch {};
        self.releaseAllPendingAfterDeviceIdle();
        self.resetCommandBufferForTarget(target_key);
        self.invalidateOutput(target_key);
    };

    std.debug.assert(output.command_buffer != .null_handle);
    self.device_wrapper.resetCommandBuffer(output.command_buffer, .{}) catch
        return error.VulkanFailure;
    self.device_wrapper.resetFences(self.device, &.{submission.fence}) catch
        return error.VulkanFailure;
    self.device_wrapper.beginCommandBuffer(output.command_buffer, &.{
        .flags = .{ .one_time_submit_bit = true },
    }) catch return error.VulkanFailure;

    const encode_descriptor = if (prepare_linear) descriptor: {
        self.transitionImage(
            output.command_buffer,
            output.linear.image,
            if (output.linear_initialized) .shader_read_only_optimal else .undefined,
            .color_attachment_optimal,
            if (output.linear_initialized) .{ .shader_read_bit = true } else .{},
            .{ .color_attachment_write_bit = true },
            if (output.linear_initialized)
                .{ .fragment_shader_bit = true }
            else
                .{ .top_of_pipe_bit = true },
            .{ .color_attachment_output_bit = true },
        );
        const conversion_pass: vk.RenderPassBeginInfo = .{
            .render_pass = self.render_pass,
            .framebuffer = output.linear.framebuffer,
            .render_area = rect2D(full_output),
        };
        self.device_wrapper.cmdBeginRenderPass(
            output.command_buffer,
            &conversion_pass,
            .@"inline",
        );
        self.setViewportAndScissor(output.command_buffer, size);
        self.device_wrapper.cmdBindVertexBuffers(
            output.command_buffer,
            0,
            &.{submission.instance_buffer},
            &.{0},
        );
        self.device_wrapper.cmdBindPipeline(
            output.command_buffer,
            .graphics,
            self.opaque_image_pipeline,
        );
        self.device_wrapper.cmdBindDescriptorSets(
            output.command_buffer,
            .graphics,
            self.pipeline_layout,
            0,
            &.{source.linear.descriptor_set},
            null,
        );
        var transform = color_math.sourceTransform(source.color_description, color_description);
        transform.transfer = @splat(0);
        const conversion_push: FramePush = .{
            .target_size = sizeFloats(size),
            .texture_size = sizeFloats(source_size),
            .swap_red_blue = 0,
            .color_matrix_0 = transform.color_matrix_0,
            .color_matrix_1 = transform.color_matrix_1,
            .color_matrix_2 = transform.color_matrix_2,
            .transfer = transform.transfer,
            .output_transfer = transform.output_transfer,
            .transfer_aux = transform.transfer_aux,
        };
        self.device_wrapper.cmdPushConstants(
            output.command_buffer,
            self.pipeline_layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(FramePush),
            &conversion_push,
        );
        self.device_wrapper.cmdDraw(output.command_buffer, 4, 1, 0, 0);
        self.device_wrapper.cmdEndRenderPass(output.command_buffer);
        self.transitionImage(
            output.command_buffer,
            output.linear.image,
            .color_attachment_optimal,
            .shader_read_only_optimal,
            .{ .color_attachment_write_bit = true },
            .{ .shader_read_bit = true },
            .{ .color_attachment_output_bit = true },
            .{ .fragment_shader_bit = true },
        );
        break :descriptor output.linear.descriptor_set;
    } else source.linear.descriptor_set;

    if (output.kind == .dmabuf) {
        self.transitionExternalToRender(output.command_buffer, output.*);
    } else {
        std.debug.assert(output.kind == .pixels);
        self.transitionImage(
            output.command_buffer,
            output.image,
            if (output.initialized) .color_attachment_optimal else .undefined,
            .color_attachment_optimal,
            if (output.initialized) .{ .color_attachment_write_bit = true } else .{},
            .{ .color_attachment_write_bit = true },
            if (output.initialized)
                .{ .color_attachment_output_bit = true }
            else
                .{ .top_of_pipe_bit = true },
            .{ .color_attachment_output_bit = true },
        );
    }

    const output_graphics = self.outputGraphics(output.format);
    const pass_info: vk.RenderPassBeginInfo = .{
        .render_pass = output_graphics.render_pass,
        .framebuffer = output.framebuffer,
        .render_area = rect2D(full_output),
    };
    self.device_wrapper.cmdBeginRenderPass(output.command_buffer, &pass_info, .@"inline");
    self.setViewportAndScissor(output.command_buffer, size);
    self.device_wrapper.cmdBindVertexBuffers(
        output.command_buffer,
        0,
        &.{submission.instance_buffer},
        &.{0},
    );
    self.device_wrapper.cmdBindPipeline(
        output.command_buffer,
        .graphics,
        output_graphics.encode_pipeline,
    );
    self.device_wrapper.cmdBindDescriptorSets(
        output.command_buffer,
        .graphics,
        self.pipeline_layout,
        0,
        &.{encode_descriptor},
        null,
    );
    const output_push: FramePush = .{
        .target_size = sizeFloats(size),
        .texture_size = sizeFloats(if (prepare_linear) size else source_size),
        .swap_red_blue = @floatFromInt(@intFromBool(output.format == .r8g8b8a8_unorm)),
        .quantization_levels = if (output.format == .a2r10g10b10_unorm_pack32) 1023 else 255,
        .transfer = .{ 1, 80, 80, 0 },
        .output_transfer = color_math.outputTransfer(color_description),
        .transfer_aux = color_math.transferAux(color_description),
    };
    self.device_wrapper.cmdPushConstants(
        output.command_buffer,
        self.pipeline_layout,
        .{ .vertex_bit = true, .fragment_bit = true },
        0,
        @sizeOf(FramePush),
        &output_push,
    );
    self.device_wrapper.cmdDraw(
        output.command_buffer,
        4,
        1,
        0,
        @intFromBool(prepare_linear),
    );
    self.device_wrapper.cmdEndRenderPass(output.command_buffer);

    if (output.kind == .dmabuf) {
        self.transitionRenderToExternal(output.command_buffer, output.image);
    } else {
        self.transitionImage(
            output.command_buffer,
            output.image,
            .color_attachment_optimal,
            .transfer_src_optimal,
            .{ .color_attachment_write_bit = true },
            .{ .transfer_read_bit = true },
            .{ .color_attachment_output_bit = true },
            .{ .transfer_bit = true },
        );
        const copy_frame: render.Frame = .{ .size = size, .commands = &.{} };
        self.copyOutputDamage(
            submission.work_buffer,
            output.command_buffer,
            copy_frame,
            pixel_target.?,
            output.image,
        );
        self.transitionImage(
            output.command_buffer,
            output.image,
            .transfer_src_optimal,
            .color_attachment_optimal,
            .{ .transfer_read_bit = true },
            .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
            .{ .transfer_bit = true },
            .{ .color_attachment_output_bit = true },
        );
        self.transferToHostBarrier(output.command_buffer);
    }
    self.device_wrapper.endCommandBuffer(output.command_buffer) catch
        return error.VulkanFailure;

    const export_completion = submission.scanout_semaphore != .null_handle;
    const submit_info: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&output.command_buffer),
        .signal_semaphore_count = @intFromBool(export_completion),
        .p_signal_semaphores = if (export_completion)
            @ptrCast(&submission.scanout_semaphore)
        else
            null,
    };
    self.device_wrapper.queueSubmit(self.queue, &.{submit_info}, submission.fence) catch
        return error.VulkanFailure;
    submission.fence_pending = true;
    output.initialized = true;
    output.linear_initialized = prepare_linear;
    output.color_description = color_description;

    if (export_completion) {
        const completion_fd = self.device_wrapper.getSemaphoreFdKHR(self.device, &.{
            .semaphore = submission.scanout_semaphore,
            .handle_type = .{ .sync_fd_bit = true },
        }) catch {
            try self.drainAllPending();
            self.disableScanoutSynchronization();
            if (pixel_target) |pixels| {
                copyMappedRect(pixels, submission.work_mapped.?, full_output);
            }
            frame_succeeded = true;
            return .{};
        };
        if (completion_fd >= 0) {
            frame_succeeded = true;
            return .{ .sync_file_fd = completion_fd };
        }
    }

    try self.drainSubmission(submission);
    if (pixel_target) |pixels| {
        copyMappedRect(pixels, submission.work_mapped.?, full_output);
    }
    frame_succeeded = true;
    return .{};
}

pub fn renderFrameScanout(
    self: *Self,
    frame: render.Frame,
    target: render.Target,
    gpu_sample_tag: ?u64,
) Error!render.FrameCompletion {
    return self.renderFrameWithCompletion(frame, target, .sync_fd, gpu_sample_tag);
}

const CompletionMode = enum {
    wait,
    sync_fd,
    readback,
};

fn renderFrameWithCompletion(
    self: *Self,
    frame: render.Frame,
    target: render.Target,
    completion_mode: CompletionMode,
    gpu_sample_tag: ?u64,
) Error!render.FrameCompletion {
    const required_pixels = validateTarget(frame, target) catch |err| {
        const target_size = target.size();
        log.err(
            "Vulkan render target validation failed: frame={d}x{d} target={d}x{d}: {t}",
            .{ frame.size.width, frame.size.height, target_size.width, target_size.height, err },
        );
        return err;
    };
    const target_key = targetKey(target);
    if (!supports(frame.commands)) {
        var completion: render.FrameCompletion = .{};
        switch (target) {
            .pixels => |pixels| {
                if (self.outputs.getPtr(target_key)) |output| {
                    try self.drainSubmission(&output.submission);
                }
                self.invalidateOutput(target_key);
                try self.fallback.render(frame, pixels);
            },
            .offscreen, .dmabuf => {
                try self.renderGpuFallback(frame, target_key);
                completion.cpu_uploads = 1;
            },
        }
        return completion;
    }

    self.frame_number +%= 1;
    try self.reclaimStaleResources();
    const output = self.getOutput(target_key) catch |err| {
        log.err("Vulkan output target lookup failed: {t}", .{err});
        return err;
    };
    const submission = &output.submission;
    try self.drainSubmission(submission);
    if (!std.meta.eql(output.size, frame.size)) {
        log.err(
            "Vulkan output target size changed: frame={d}x{d} output={d}x{d}",
            .{ frame.size.width, frame.size.height, output.size.width, output.size.height },
        );
        return error.InvalidTarget;
    }
    output.last_used = self.frame_number;
    for (frame.commands) |command| switch (command) {
        .crossfade => |fade| {
            const sources = [_]render.ImageSource{ fade.old, fade.new };
            for (sources) |source| {
                const retained = switch (source) {
                    .offscreen => |value| value,
                    .pixels => return error.InvalidTarget,
                };
                const source_key: TargetKey = .{ .offscreen = retained.id };
                if (std.meta.eql(source_key, target_key)) return error.InvalidTarget;
                const source_output = self.outputs.getPtr(source_key) orelse return error.InvalidTarget;
                if (source_output.kind != .offscreen or
                    !std.meta.eql(source_output.size, retained.size) or
                    !source_output.linear_initialized) return error.InvalidTarget;
                try self.drainSubmission(&source_output.submission);
                source_output.last_used = self.frame_number;
            }
            output.recorded_frame.valid = false;
        },
        else => {},
    };
    std.debug.assert(
        self.instances.items.len == 0 and
            self.draw_runs.items.len == 0 and
            self.blur_ops.items.len == 0 and
            self.prepared_images.items.len == 0,
    );
    var temporary_textures_pending = false;
    defer {
        self.instances.clearRetainingCapacity();
        self.draw_runs.clearRetainingCapacity();
        self.blur_ops.clearRetainingCapacity();
        if (!temporary_textures_pending) {
            for (self.prepared_images.items) |prepared| {
                if (prepared.cache_id == null) self.destroyTexture(prepared.texture);
            }
        }
        self.prepared_images.clearRetainingCapacity();
    }

    var frame_succeeded = false;
    var new_calibration_identity: ?u64 = null;
    defer if (!frame_succeeded) {
        self.device_wrapper.deviceWaitIdle(self.device) catch {};
        self.releaseAllPendingAfterDeviceIdle();
        self.resetCommandBufferForTarget(target_key);
        self.invalidateOutput(target_key);
        self.invalidatePreparedTextures(self.prepared_images.items);
        if (new_calibration_identity) |identity| {
            if (self.calibrations.fetchRemove(identity)) |removed| {
                self.destroyCalibrationTexture(removed.value);
            }
        }
    };
    var work_size = switch (target) {
        .pixels => std.math.mul(usize, required_pixels, @sizeOf(u32)) catch
            return error.InvalidTarget,
        .offscreen, .dmabuf => 0,
    };
    for (frame.commands, 0..) |command, command_index| switch (command) {
        .image => |image| {
            validateImage(image) catch |err| {
                if (image.buffer.dmabuf) |dmabuf| {
                    log.err(
                        "Vulkan image command {d} validation failed: image={d}x{d} buffer={d}x{d} format=0x{x} modifier=0x{x} planes={d}: {t}",
                        .{
                            command_index,
                            image.size.width,
                            image.size.height,
                            image.buffer.size.width,
                            image.buffer.size.height,
                            dmabuf.format,
                            dmabuf.modifier,
                            dmabuf.plane_count,
                            err,
                        },
                    );
                } else {
                    log.err(
                        "Vulkan image command {d} validation failed: image={d}x{d} buffer={d}x{d} stride={d}: {t}",
                        .{
                            command_index,
                            image.size.width,
                            image.size.height,
                            image.buffer.size.width,
                            image.buffer.size.height,
                            image.buffer.stride_pixels,
                            err,
                        },
                    );
                }
                return err;
            };
            try self.prepared_images.ensureUnusedCapacity(self.allocator, 1);
            self.prepared_images.appendAssumeCapacity(try self.prepareTexture(
                image.buffer,
                self.prepared_images.items,
                &work_size,
            ));
        },
        else => {},
    };
    const prepared_calibration = self.prepareCalibration(
        frame.output_calibration,
        &work_size,
    ) catch |err| {
        log.err("Vulkan output calibration preparation failed: {t}", .{err});
        return err;
    };
    if (prepared_calibration) |prepared| {
        if (prepared.upload_offset != null) new_calibration_identity = prepared.identity;
    }

    try self.ensureWorkBuffer(submission, work_size);
    var compiled_frame = frame;
    const calibration_identity = if (frame.output_calibration) |calibration|
        calibration.identity
    else
        null;
    if (output.initialized and
        (!std.meta.eql(output.color_description, frame.output_color_description) or
            output.calibration_identity != calibration_identity))
    {
        // The retained image is expressed in the output's linear RGB space.
        // Reusing any of it after the output description changes would mix
        // incompatible primaries and reference luminances in one frame.
        compiled_frame.damage = null;
        output.recorded_frame.valid = false;
        for (output.backdrop_cache.items) |*cache| {
            cache.key = null;
            cache.initialized = false;
        }
    }
    output.color_description = frame.output_color_description;
    output.calibration_identity = calibration_identity;
    // The retained linear image, rather than the scanout image, is the source
    // of truth for partial redraws. Initialize all of it from the complete
    // scene before accepting damage-limited updates.
    if (!output.linear_initialized and
        (output.kind != .pixels or output.initialized)) compiled_frame.damage = null;
    try self.compileDrawRuns(
        compiled_frame,
        self.prepared_images.items,
        frame.output_color_description,
    );
    if (try self.prepareBackdropCaches(output, compiled_frame.damage) and
        compiled_frame.damage != null)
    {
        self.instances.clearRetainingCapacity();
        self.draw_runs.clearRetainingCapacity();
        self.blur_ops.clearRetainingCapacity();
        compiled_frame.damage = null;
        try self.compileDrawRuns(
            compiled_frame,
            self.prepared_images.items,
            frame.output_color_description,
        );
        _ = try self.prepareBackdropCaches(output, compiled_frame.damage);
    }
    if (self.instances.items.len >= std.math.maxInt(u32)) return error.InvalidTarget;
    const encode_instance: u32 = @intCast(self.instances.items.len);
    const full_output: render.Rect = .{ .x = 0, .y = 0, .width = frame.size.width, .height = frame.size.height };
    try self.instances.append(self.allocator, imageInstance(full_output, full_output));
    const instance_bytes = std.mem.sliceAsBytes(self.instances.items);
    try self.ensureInstanceBuffer(submission, instance_bytes.len);
    if (instance_bytes.len > 0) {
        @memcpy(submission.instance_mapped.?[0..instance_bytes.len], instance_bytes);
    }
    var blur_initialized = output.blur_initialized;
    if (!output.initialized and output.kind == .pixels) {
        const pixels = switch (target) {
            .pixels => |value| value,
            else => unreachable,
        };
        copyPixelsToMapped(submission.work_mapped.?, 0, pixels, null);
    }
    var prepared_index: usize = 0;
    for (frame.commands) |command| switch (command) {
        .image => |image| {
            const prepared = &self.prepared_images.items[prepared_index];
            prepared_index += 1;
            if (prepared.upload_offset) |offset| {
                try copySourceToMapped(
                    submission.work_mapped.?,
                    offset,
                    image.buffer,
                    prepared.upload_damage,
                );
            }
        },
        else => {},
    };
    if (prepared_calibration) |prepared| {
        if (prepared.upload_offset) |offset| {
            const bytes = std.mem.sliceAsBytes(frame.output_calibration.?.values);
            @memcpy(submission.work_mapped.?[offset..][0..bytes.len], bytes);
        }
    }

    std.debug.assert(!submission.fence_pending);
    self.device_wrapper.resetFences(self.device, &.{submission.fence}) catch
        return error.VulkanFailure;
    const reusable = output.kind != .pixels;
    const frame_render_area = damageBounds(compiled_frame.damage, full_output) orelse full_output;
    const gpu_timing_plan = buildGpuTimingPlan(self.draw_runs.items, self.blur_ops.items);
    std.debug.assert(gpu_timing_plan.queryCount() <= timestamp_query_count);
    const cache_hit = reusable and self.recordedFrameMatches(
        submission,
        &output.recorded_frame,
        output.initialized,
        output.blur_initialized,
        frame_render_area,
        self.prepared_images.items,
    );
    std.debug.assert(!reusable or output.command_buffer != .null_handle);
    const command_buffer = output.command_buffer;
    if (!cache_hit) {
        var gpu_timing_recorder: GpuTimingRecorder = .{ .plan = gpu_timing_plan };
        self.device_wrapper.beginCommandBuffer(command_buffer, &.{
            .flags = if (reusable) .{} else .{ .one_time_submit_bit = true },
        }) catch return error.VulkanFailure;
        if (submission.timestamp_query_pool != .null_handle) {
            self.device_wrapper.cmdResetQueryPool(
                command_buffer,
                submission.timestamp_query_pool,
                0,
                timestamp_query_count,
            );
            self.device_wrapper.cmdWriteTimestamp(
                command_buffer,
                .{ .top_of_pipe_bit = true },
                submission.timestamp_query_pool,
                gpu_timing_plan.frameStartQuery(),
            );
        }

        if (prepared_calibration) |prepared| {
            if (prepared.upload_offset) |offset| {
                self.transitionImage(
                    command_buffer,
                    prepared.texture.image,
                    .undefined,
                    .transfer_dst_optimal,
                    .{},
                    .{ .transfer_write_bit = true },
                    .{ .top_of_pipe_bit = true },
                    .{ .transfer_bit = true },
                );
                const upload: vk.BufferImageCopy = .{
                    .buffer_offset = offset,
                    .buffer_row_length = 0,
                    .buffer_image_height = 0,
                    .image_subresource = colorSubresourceLayers(),
                    .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                    .image_extent = .{
                        .width = render.output_calibration_edge_length,
                        .height = render.output_calibration_edge_length,
                        .depth = render.output_calibration_edge_length,
                    },
                };
                self.device_wrapper.cmdCopyBufferToImage(
                    command_buffer,
                    submission.work_buffer,
                    prepared.texture.image,
                    .transfer_dst_optimal,
                    &.{upload},
                );
                self.transitionImage(
                    command_buffer,
                    prepared.texture.image,
                    .transfer_dst_optimal,
                    .shader_read_only_optimal,
                    .{ .transfer_write_bit = true },
                    .{ .shader_read_bit = true },
                    .{ .transfer_bit = true },
                    .{ .fragment_shader_bit = true },
                );
            }
        }

        if (!output.initialized and output.kind == .pixels) {
            const pixels = switch (target) {
                .pixels => |value| value,
                else => unreachable,
            };
            self.transitionImage(command_buffer, output.image, .undefined, .transfer_dst_optimal, .{}, .{ .transfer_write_bit = true }, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true });
            const upload: vk.BufferImageCopy = .{
                .buffer_offset = 0,
                .buffer_row_length = pixels.stride_pixels,
                .buffer_image_height = pixels.size.height,
                .image_subresource = colorSubresourceLayers(),
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .image_extent = extent(pixels.size),
            };
            self.device_wrapper.cmdCopyBufferToImage(command_buffer, submission.work_buffer, output.image, .transfer_dst_optimal, &.{upload});
            self.transitionImage(command_buffer, output.image, .transfer_dst_optimal, .shader_read_only_optimal, .{ .transfer_write_bit = true }, .{ .shader_read_bit = true }, .{ .transfer_bit = true }, .{ .fragment_shader_bit = true });
        }

        self.transitionImage(
            command_buffer,
            output.linear.image,
            if (output.linear_initialized) .shader_read_only_optimal else .undefined,
            .color_attachment_optimal,
            if (output.linear_initialized) .{ .shader_read_bit = true } else .{},
            .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
            if (output.linear_initialized)
                .{ .fragment_shader_bit = true }
            else
                .{ .top_of_pipe_bit = true },
            .{ .color_attachment_output_bit = true },
        );

        if (!output.initialized and output.kind == .pixels) {
            const initialize_pass: vk.RenderPassBeginInfo = .{
                .render_pass = self.render_pass,
                .framebuffer = output.linear.framebuffer,
                .render_area = rect2D(full_output),
            };
            self.device_wrapper.cmdBeginRenderPass(command_buffer, &initialize_pass, .@"inline");
            self.setViewportAndScissor(command_buffer, frame.size);
            self.device_wrapper.cmdBindVertexBuffers(command_buffer, 0, &.{submission.instance_buffer}, &.{0});
            self.device_wrapper.cmdBindPipeline(command_buffer, .graphics, self.downsample_pipeline);
            self.device_wrapper.cmdBindDescriptorSets(command_buffer, .graphics, self.pipeline_layout, 0, &.{output.descriptor_set}, null);
            const initialize_push: FramePush = .{
                .target_size = sizeFloats(frame.size),
                .texture_size = sizeFloats(frame.size),
                .swap_red_blue = @floatFromInt(@intFromBool(self.swap_red_blue)),
                .color_matrix_0 = .{ 1, 0, 0, 0 },
                .color_matrix_1 = .{ 0, 1, 0, 0 },
                .color_matrix_2 = .{ 0, 0, 1, 0 },
                .transfer = .{ 1, 0, 80, 80 },
                .output_transfer = .{ 1, 0, 80, 80 },
                .transfer_aux = color_math.transferAux(.{}),
            };
            self.device_wrapper.cmdPushConstants(command_buffer, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(FramePush), &initialize_push);
            self.device_wrapper.cmdDraw(command_buffer, 4, 1, 0, encode_instance);
            self.device_wrapper.cmdEndRenderPass(command_buffer);
        }

        for (self.prepared_images.items, 0..) |prepared, index| {
            if (!prepared.texture.imported or
                !isFirstImportedTexture(self.prepared_images.items, index)) continue;
            self.transitionExternalSourceToSample(command_buffer, prepared.texture.image);
        }

        for (self.prepared_images.items) |prepared| {
            const offset = prepared.upload_offset orelse continue;
            const old_layout: vk.ImageLayout = if (prepared.texture.initialized)
                .shader_read_only_optimal
            else
                .undefined;
            self.transitionImage(
                command_buffer,
                prepared.texture.image,
                old_layout,
                .transfer_dst_optimal,
                if (prepared.texture.initialized) .{ .shader_read_bit = true } else .{},
                .{ .transfer_write_bit = true },
                if (prepared.texture.initialized)
                    .{ .fragment_shader_bit = true }
                else
                    .{ .top_of_pipe_bit = true },
                .{ .transfer_bit = true },
            );
            const source_buffer = prepared.buffer;
            if (prepared.upload_damage) |damage| {
                for (damage) |rect| self.copyTextureRect(
                    submission.work_buffer,
                    command_buffer,
                    prepared.texture.image,
                    source_buffer,
                    offset,
                    rect,
                );
            } else {
                self.copyTextureRect(submission.work_buffer, command_buffer, prepared.texture.image, source_buffer, offset, .{
                    .x = 0,
                    .y = 0,
                    .width = source_buffer.size.width,
                    .height = source_buffer.size.height,
                });
            }
            self.transitionImage(
                command_buffer,
                prepared.texture.image,
                .transfer_dst_optimal,
                .shader_read_only_optimal,
                .{ .transfer_write_bit = true },
                .{ .shader_read_bit = true },
                .{ .transfer_bit = true },
                .{ .fragment_shader_bit = true },
            );
        }

        self.writeGpuTimestamp(submission, command_buffer, gpu_timing_plan.compositionStartQuery());

        const render_pass_info: vk.RenderPassBeginInfo = .{
            .render_pass = self.render_pass,
            .framebuffer = output.linear.framebuffer,
            .render_area = rect2D(frame_render_area),
        };
        self.device_wrapper.cmdBeginRenderPass(
            command_buffer,
            &render_pass_info,
            .@"inline",
        );
        self.device_wrapper.cmdSetViewport(command_buffer, 0, &.{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(frame.size.width),
            .height = @floatFromInt(frame.size.height),
            .min_depth = 0,
            .max_depth = 1,
        }});
        self.device_wrapper.cmdSetScissor(command_buffer, 0, &.{.{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = frame.size.width, .height = frame.size.height },
        }});
        if (self.instances.items.len > 0) {
            self.device_wrapper.cmdBindVertexBuffers(
                command_buffer,
                0,
                &.{submission.instance_buffer},
                &.{0},
            );
        }
        var bound_pipeline = vk.Pipeline.null_handle;
        var bound_pipeline_layout = vk.PipelineLayout.null_handle;
        var bound_descriptors: [2]?vk.DescriptorSet = @splat(null);
        for (self.draw_runs.items, 0..) |run, run_index| {
            if (self.blurOpAt(run_index)) |blur_op| {
                if (!blur_op.used) continue;
                const backdrop_cache = output.backdrop_cache.items[blur_op.cache_index];
                if (!blur_op.cache_hit) {
                    const scratch = output.blur.?;
                    gpu_timing_recorder.switchTo(self, submission, command_buffer, .blur_downsample);
                    self.device_wrapper.cmdEndRenderPass(command_buffer);
                    self.transitionImage(command_buffer, output.linear.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_write_bit = true }, .{ .shader_read_bit = true }, .{ .color_attachment_output_bit = true }, .{ .fragment_shader_bit = true });

                    if (blur_op.level == 0) {
                        const destination_level = scratch.levels[0].?;
                        const destination_bit: u16 = 1;
                        self.transitionScratchForWrite(command_buffer, destination_level.a.image, blur_initialized & destination_bit != 0, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                        self.drawScratchPass(command_buffer, destination_level.a_framebuffer, destination_level.size, blur_op.level_rects[0], .blur_downsample, output.linear.descriptor_set, frame.size, blur_op.downsample_instances[0]);
                        self.transitionScratchToRead(command_buffer, destination_level.a.image, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                        blur_initialized |= destination_bit;
                    } else {
                        for (0..blur_op.level) |index| {
                            const destination_index = index + 1;
                            const destination_level = scratch.levels[destination_index].?;
                            const destination_bit: u16 = @as(u16, 1) << @intCast(destination_index * 2);
                            self.transitionScratchForWrite(command_buffer, destination_level.a.image, blur_initialized & destination_bit != 0, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                            const source_descriptor = if (index == 0)
                                output.linear.descriptor_set
                            else
                                scratch.levels[index].?.a.descriptor_set;
                            const source_size = if (index == 0)
                                frame.size
                            else
                                scratch.levels[index].?.size;
                            self.drawScratchPass(command_buffer, destination_level.a_framebuffer, destination_level.size, blur_op.level_rects[destination_index], .blur_downsample, source_descriptor, source_size, blur_op.downsample_instances[destination_index]);
                            self.transitionScratchToRead(command_buffer, destination_level.a.image, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                            blur_initialized |= destination_bit;
                        }
                    }

                    gpu_timing_recorder.switchTo(self, submission, command_buffer, .blur_upsample);
                    const final_level = scratch.levels[blur_op.level].?;
                    if (blur_op.level == 0) {
                        self.transitionScratchForWrite(command_buffer, backdrop_cache.image.image, backdrop_cache.initialized, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                        self.drawScratchPass(command_buffer, backdrop_cache.framebuffer, backdrop_cache.size, blur_op.upsample_rects[0], .blur_upsample, final_level.a.descriptor_set, final_level.size, blur_op.upsample_instances[0]);
                        self.transitionScratchToRead(command_buffer, backdrop_cache.image.image, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                    } else {
                        var source_level: usize = blur_op.level;
                        while (source_level > 0) : (source_level -= 1) {
                            const destination_index = source_level - 1;
                            const destination_is_cache = destination_index == 0;
                            const destination_level = if (destination_is_cache) null else scratch.levels[destination_index].?;
                            const destination_image = if (destination_is_cache) backdrop_cache.image.image else destination_level.?.b.image;
                            const destination_framebuffer = if (destination_is_cache) backdrop_cache.framebuffer else destination_level.?.b_framebuffer;
                            const destination_size = if (destination_is_cache) backdrop_cache.size else destination_level.?.size;
                            const destination_bit: u16 = @as(u16, 1) << @intCast(destination_index * 2 + 1);
                            self.transitionScratchForWrite(command_buffer, destination_image, if (destination_is_cache) backdrop_cache.initialized else blur_initialized & destination_bit != 0, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                            const source_descriptor = if (source_level == blur_op.level)
                                final_level.a.descriptor_set
                            else
                                scratch.levels[source_level].?.b.descriptor_set;
                            self.drawScratchPass(command_buffer, destination_framebuffer, destination_size, blur_op.upsample_rects[destination_index], .blur_upsample, source_descriptor, scratch.levels[source_level].?.size, blur_op.upsample_instances[destination_index]);
                            self.transitionScratchToRead(command_buffer, destination_image, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                            if (!destination_is_cache) blur_initialized |= destination_bit;
                        }
                    }
                    gpu_timing_recorder.switchTo(self, submission, command_buffer, gpuTimingCategory(run.pipeline));
                    self.transitionImage(command_buffer, output.linear.image, .shader_read_only_optimal, .color_attachment_optimal, .{ .shader_read_bit = true }, .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .color_attachment_output_bit = true });
                    self.device_wrapper.cmdBeginRenderPass(command_buffer, &render_pass_info, .@"inline");
                    self.setViewportAndScissor(command_buffer, frame.size);
                    bound_pipeline = .null_handle;
                    bound_pipeline_layout = .null_handle;
                    bound_descriptors = @splat(null);
                }
            }
            gpu_timing_recorder.switchTo(self, submission, command_buffer, gpuTimingCategory(run.pipeline));
            const run_pipeline = if (run.pipeline_handle != .null_handle)
                run.pipeline_handle
            else
                self.pipelineForKind(run.pipeline);
            const run_pipeline_layout = if (run.pipeline_layout != .null_handle)
                run.pipeline_layout
            else
                self.pipeline_layout;
            if (bound_pipeline != run_pipeline) {
                self.device_wrapper.cmdBindPipeline(
                    command_buffer,
                    .graphics,
                    run_pipeline,
                );
                bound_pipeline = run_pipeline;
            }
            if (bound_pipeline_layout != run_pipeline_layout) {
                bound_pipeline_layout = run_pipeline_layout;
                bound_descriptors = @splat(null);
            }
            const backdrop_descriptor = if (run.backdrop_op_index) |op_index| blk: {
                const blur_op = self.blur_ops.items[op_index];
                break :blk output.backdrop_cache.items[blur_op.cache_index].image.descriptor_set;
            } else null;
            const primary_descriptor = if (run.pipeline == .blur_composite)
                backdrop_descriptor
            else
                run.descriptor_set;
            if (primary_descriptor) |descriptor_set| {
                if (bound_descriptors[0] != descriptor_set) {
                    self.device_wrapper.cmdBindDescriptorSets(
                        command_buffer,
                        .graphics,
                        run_pipeline_layout,
                        0,
                        &.{descriptor_set},
                        null,
                    );
                    bound_descriptors[0] = descriptor_set;
                }
            }
            if (run.pipeline == .backdrop_image or run.secondary_descriptor_set != null) {
                const descriptor_set = if (run.pipeline == .backdrop_image)
                    backdrop_descriptor orelse return error.InvalidTarget
                else
                    run.secondary_descriptor_set.?;
                if (bound_descriptors[1] != descriptor_set) {
                    self.device_wrapper.cmdBindDescriptorSets(
                        command_buffer,
                        .graphics,
                        run_pipeline_layout,
                        1,
                        &.{descriptor_set},
                        null,
                    );
                    bound_descriptors[1] = descriptor_set;
                }
            }
            const push: FramePush = .{
                .target_size = sizeFloats(frame.size),
                .texture_size = sizeFloats(run.texture_size),
                // Scratch images use the output's format, so their sampled and
                // attachment component order already agrees on every device.
                .swap_red_blue = if (run.manual_ycbcr) |manual|
                    @floatFromInt(@intFromEnum(manual.chroma_location))
                else if (run.pipeline == .blur_composite or run.pipeline == .crossfade)
                    0
                else
                    @floatFromInt(@intFromBool(self.swap_red_blue)),
                .quantization_levels = if (run.manual_ycbcr) |manual|
                    if (manual.narrow_range)
                        -manual.quantization_levels
                    else
                        manual.quantization_levels
                else
                    255,
                .ycbcr_coefficients = if (run.manual_ycbcr) |manual|
                    manual.coefficients
                else
                    @splat(0),
                .color_matrix_0 = run.color_transform.color_matrix_0,
                .color_matrix_1 = run.color_transform.color_matrix_1,
                .color_matrix_2 = run.color_transform.color_matrix_2,
                .transfer = run.color_transform.transfer,
                .output_transfer = run.color_transform.output_transfer,
                .transfer_aux = run.color_transform.transfer_aux,
            };
            self.device_wrapper.cmdPushConstants(
                command_buffer,
                run_pipeline_layout,
                .{ .vertex_bit = true, .fragment_bit = true },
                0,
                @sizeOf(FramePush),
                &push,
            );
            self.device_wrapper.cmdDraw(
                command_buffer,
                4,
                run.instance_count,
                0,
                run.first_instance,
            );
        }
        gpu_timing_recorder.switchTo(self, submission, command_buffer, .composition_overhead);
        self.device_wrapper.cmdEndRenderPass(command_buffer);

        self.transitionImage(command_buffer, output.linear.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_write_bit = true }, .{ .shader_read_bit = true }, .{ .color_attachment_output_bit = true }, .{ .fragment_shader_bit = true });
        gpu_timing_recorder.finish();
        self.writeGpuTimestamp(submission, command_buffer, gpu_timing_plan.compositionEndQuery());
        if (output.kind == .dmabuf) {
            self.transitionExternalToRender(command_buffer, output.*);
        } else if (!output.initialized) {
            if (output.kind == .pixels) {
                self.transitionImage(command_buffer, output.image, .shader_read_only_optimal, .color_attachment_optimal, .{ .shader_read_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .color_attachment_output_bit = true });
            } else {
                self.transitionImage(command_buffer, output.image, .undefined, .color_attachment_optimal, .{}, .{ .color_attachment_write_bit = true }, .{ .top_of_pipe_bit = true }, .{ .color_attachment_output_bit = true });
            }
        }
        const output_pass_info: vk.RenderPassBeginInfo = .{
            .render_pass = self.outputGraphics(output.format).render_pass,
            .framebuffer = output.framebuffer,
            .render_area = rect2D(frame_render_area),
        };
        self.device_wrapper.cmdBeginRenderPass(command_buffer, &output_pass_info, .@"inline");
        self.setViewportAndScissor(command_buffer, frame.size);
        self.device_wrapper.cmdSetScissor(command_buffer, 0, &.{rect2D(frame_render_area)});
        const output_graphics = self.outputGraphics(output.format);
        self.device_wrapper.cmdBindPipeline(
            command_buffer,
            .graphics,
            if (prepared_calibration != null)
                output_graphics.encode_calibrated_pipeline
            else
                output_graphics.encode_pipeline,
        );
        if (prepared_calibration) |prepared| {
            self.device_wrapper.cmdBindDescriptorSets(
                command_buffer,
                .graphics,
                self.pipeline_layout,
                0,
                &.{ output.linear.descriptor_set, prepared.texture.descriptor_set },
                null,
            );
        } else {
            self.device_wrapper.cmdBindDescriptorSets(
                command_buffer,
                .graphics,
                self.pipeline_layout,
                0,
                &.{output.linear.descriptor_set},
                null,
            );
        }
        const output_push: FramePush = .{
            .target_size = sizeFloats(frame.size),
            .texture_size = sizeFloats(frame.size),
            .swap_red_blue = @floatFromInt(@intFromBool(output.format == .r8g8b8a8_unorm)),
            .quantization_levels = if (output.format == .a2r10g10b10_unorm_pack32) 1023 else 255,
            .color_matrix_0 = .{ 1, 0, 0, 0 },
            .color_matrix_1 = .{ 0, 1, 0, 0 },
            .color_matrix_2 = .{ 0, 0, 1, 0 },
            .transfer = .{ 1, 80, 80, 0 },
            .output_transfer = color_math.outputTransfer(frame.output_color_description),
            .transfer_aux = color_math.transferAux(frame.output_color_description),
        };
        self.device_wrapper.cmdPushConstants(command_buffer, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(FramePush), &output_push);
        self.device_wrapper.cmdDraw(command_buffer, 4, 1, 0, encode_instance);
        self.device_wrapper.cmdEndRenderPass(command_buffer);
        self.writeGpuTimestamp(submission, command_buffer, gpu_timing_plan.outputEncodeEndQuery());

        for (self.prepared_images.items, 0..) |prepared, index| {
            if (!prepared.texture.imported or
                !isFirstImportedTexture(self.prepared_images.items, index)) continue;
            self.transitionSampleToExternal(command_buffer, prepared.texture.image);
        }

        if (output.kind == .dmabuf) self.transitionRenderToExternal(command_buffer, output.image);

        if (output.kind == .pixels) self.transitionImage(
            command_buffer,
            output.image,
            .color_attachment_optimal,
            .transfer_src_optimal,
            .{ .color_attachment_write_bit = true },
            .{ .transfer_read_bit = true },
            .{ .color_attachment_output_bit = true },
            .{ .transfer_bit = true },
        );
        if (output.kind == .pixels) self.copyOutputDamage(
            submission.work_buffer,
            command_buffer,
            compiled_frame,
            target.pixels,
            output.image,
        );
        if (output.kind == .pixels) self.transitionImage(
            command_buffer,
            output.image,
            .transfer_src_optimal,
            .color_attachment_optimal,
            .{ .transfer_read_bit = true },
            .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
            .{ .transfer_bit = true },
            .{ .color_attachment_output_bit = true },
        );
        if (output.kind == .pixels) self.transferToHostBarrier(command_buffer);
        self.writeGpuTimestamp(submission, command_buffer, gpu_timing_plan.frameEndQuery());
        self.device_wrapper.endCommandBuffer(command_buffer) catch return error.VulkanFailure;
        if (reusable) {
            const uploaded_calibration = if (prepared_calibration) |prepared|
                prepared.upload_offset != null
            else
                false;
            if (uploaded_calibration or output.initialized != output.linear_initialized) {
                // The staging offset belongs to this frame and cannot be
                // replayed safely after the mapped work buffer is reused. A
                // direct composed-frame copy can also initialize only the
                // encoded image, making this frame's initial layouts unique.
                output.recorded_frame.valid = false;
            } else try self.rememberRecordedFrame(
                submission,
                &output.recorded_frame,
                output.initialized,
                output.blur_initialized,
                frame_render_area,
                self.prepared_images.items,
            );
        }
    }

    var wait_stages: std.ArrayList(vk.PipelineStageFlags) = .empty;
    defer wait_stages.deinit(self.allocator);
    const maximum_waits = std.math.mul(
        usize,
        self.prepared_images.items.len,
        render.max_dmabuf_planes,
    ) catch return error.OutOfMemory;
    submission.pending_wait_semaphores.ensureTotalCapacity(
        self.allocator,
        maximum_waits,
    ) catch return error.OutOfMemory;
    wait_stages.ensureTotalCapacity(self.allocator, maximum_waits) catch
        return error.OutOfMemory;
    var temporary_texture_count: usize = 0;
    for (self.prepared_images.items) |prepared| {
        if (prepared.cache_id == null) temporary_texture_count += 1;
    }
    submission.pending_textures.ensureTotalCapacity(self.allocator, temporary_texture_count) catch
        return error.OutOfMemory;
    for (self.prepared_images.items, 0..) |prepared, index| {
        if (!prepared.texture.imported or
            !isFirstImportedTexture(self.prepared_images.items, index)) continue;
        const source = prepared.buffer.dmabuf.?;
        plane_waits: for (source.planeSlice(), 0..) |_, plane_index| {
            const sync_fd = (source.export_read_fence)(source.context, @intCast(plane_index)) orelse {
                if (!(source.begin_cpu_read)(source.context)) return error.VulkanFailure;
                if (!(source.end_cpu_read)(source.context)) return error.VulkanFailure;
                break :plane_waits;
            };
            const semaphore = self.device_wrapper.createSemaphore(self.device, &.{}, null) catch {
                _ = std.c.close(sync_fd);
                if (!(source.begin_cpu_read)(source.context)) return error.VulkanFailure;
                if (!(source.end_cpu_read)(source.context)) return error.VulkanFailure;
                break :plane_waits;
            };
            self.device_wrapper.importSemaphoreFdKHR(self.device, &.{
                .semaphore = semaphore,
                .flags = .{ .temporary_bit = true },
                .handle_type = .{ .sync_fd_bit = true },
                .fd = sync_fd,
            }) catch {
                _ = std.c.close(sync_fd);
                self.device_wrapper.destroySemaphore(self.device, semaphore, null);
                if (!(source.begin_cpu_read)(source.context)) return error.VulkanFailure;
                if (!(source.end_cpu_read)(source.context)) return error.VulkanFailure;
                break :plane_waits;
            };
            submission.pending_wait_semaphores.appendAssumeCapacity(semaphore);
            wait_stages.appendAssumeCapacity(.{ .all_commands_bit = true });
        }
    }

    const export_completion = submission.scanout_semaphore != .null_handle and switch (completion_mode) {
        .wait => false,
        .sync_fd => output.kind == .dmabuf,
        .readback => output.kind == .pixels,
    };
    // A GPU-resident offscreen output has no external consumer to synchronize.
    // Keep its work in flight and drain before the target is reused instead of
    // delaying headless presentation and frame callbacks on GPU completion.
    const async_submission = completion_mode != .wait and
        (output.kind == .offscreen or export_completion);
    // Queue submission makes prior coherent mapped writes visible to every
    // device access in the submission; no host pipeline barrier is needed.
    const submit_info: vk.SubmitInfo = .{
        .wait_semaphore_count = @intCast(submission.pending_wait_semaphores.items.len),
        .p_wait_semaphores = submission.pending_wait_semaphores.items.ptr,
        .p_wait_dst_stage_mask = wait_stages.items.ptr,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&command_buffer),
        .signal_semaphore_count = @intFromBool(export_completion),
        .p_signal_semaphores = if (export_completion)
            @ptrCast(&submission.scanout_semaphore)
        else
            null,
    };
    self.device_wrapper.queueSubmit(self.queue, &.{submit_info}, submission.fence) catch
        return error.VulkanFailure;
    submission.fence_pending = true;
    std.debug.assert(submission.pending_gpu_sample_tag == null);
    if (submission.timestamp_query_pool != .null_handle) {
        submission.pending_gpu_sample_tag = gpu_sample_tag;
        submission.pending_gpu_timing_plan = gpu_timing_plan;
    }
    for (self.prepared_images.items) |prepared| {
        if (prepared.cache_id == null) {
            submission.pending_textures.appendAssumeCapacity(prepared.texture);
        }
    }
    temporary_textures_pending = true;
    output.initialized = true;
    output.linear_initialized = true;
    if (new_calibration_identity) |identity| {
        self.calibrations.getPtr(identity).?.initialized = true;
    }
    if (self.blur_ops.items.len != 0) output.blur_initialized = blur_initialized;
    for (self.blur_ops.items) |blur_op| {
        if (!blur_op.used) continue;
        const cache = &output.backdrop_cache.items[blur_op.cache_index];
        if (blur_op.cache_hit) {
            if (blur_op.cache_rekey) cache.key = blur_op.cache_key;
            continue;
        }
        cache.key = blur_op.cache_key;
        cache.geometry_key = blur_op.geometry_key;
        cache.initialized = true;
    }
    for (self.prepared_images.items) |prepared| {
        if (prepared.cache_id) |cache_id| {
            const texture = self.textures.getPtr(cache_id) orelse continue;
            texture.initialized = true;
            texture.version = prepared.desired_version;
        }
    }
    var completion = frameCompletion(self.prepared_images.items);

    if (export_completion) {
        const completion_fd = self.device_wrapper.getSemaphoreFdKHR(self.device, &.{
            .semaphore = submission.scanout_semaphore,
            .handle_type = .{ .sync_fd_bit = true },
        }) catch {
            try self.drainAllPending();
            self.disableScanoutSynchronization();
            log.warn("Vulkan sync-file export failed; using blocking scanout", .{});
            if (output.kind == .pixels) {
                copyDamageToTarget(compiled_frame, target.pixels, submission.work_mapped.?);
            }
            frame_succeeded = true;
            return completion;
        };
        if (completion_fd < 0) {
            try self.drainSubmission(submission);
            if (output.kind == .pixels) {
                copyDamageToTarget(compiled_frame, target.pixels, submission.work_mapped.?);
            }
            frame_succeeded = true;
            return completion;
        }
        var completion_fd_owned = true;
        defer if (completion_fd_owned) {
            _ = std.c.close(completion_fd);
        };
        for (self.prepared_images.items, 0..) |prepared, index| {
            if (!prepared.texture.imported or
                !isFirstImportedTexture(self.prepared_images.items, index)) continue;
            for (prepared.buffer.dmabuf.?.planeSlice()) |plane| {
                if (!importDmaBufSyncFile(
                    plane.fd,
                    completion_fd,
                    sync.DMA_BUF_SYNC_READ,
                )) {
                    try self.drainAllPending();
                    self.disableScanoutSynchronization();
                    log.warn("DMA-BUF sync-file import failed; using blocking scanout", .{});
                    if (output.kind == .pixels) {
                        copyDamageToTarget(
                            compiled_frame,
                            target.pixels,
                            submission.work_mapped.?,
                        );
                    }
                    frame_succeeded = true;
                    return completion;
                }
            }
        }
        frame_succeeded = true;
        completion_fd_owned = false;
        completion.sync_file_fd = completion_fd;
        return completion;
    }

    if (async_submission) {
        frame_succeeded = true;
        return completion;
    }

    try self.drainSubmission(submission);
    frame_succeeded = true;
    if (output.kind == .pixels) {
        copyDamageToTarget(compiled_frame, target.pixels, submission.work_mapped.?);
    }
    return completion;
}

fn frameCompletion(prepared_images: []const PreparedImage) render.FrameCompletion {
    var result: render.FrameCompletion = .{};
    for (prepared_images) |prepared| {
        if (prepared.upload_offset != null) result.cpu_uploads +|= 1;
        if (prepared.newly_imported) result.dmabuf_imports +|= 1;
    }
    return result;
}

fn importDmaBufSyncFile(
    dmabuf_fd: std.posix.fd_t,
    sync_file_fd: std.posix.fd_t,
    flags: u32,
) bool {
    var import_sync_file: sync.dma_buf_import_sync_file = .{
        .flags = flags,
        .fd = sync_file_fd,
    };
    while (true) {
        const result = sync.ioctl(
            dmabuf_fd,
            sync.DMA_BUF_IOCTL_IMPORT_SYNC_FILE,
            &import_sync_file,
        );
        if (result >= 0) return true;
        switch (std.posix.errno(result)) {
            .INTR, .AGAIN => continue,
            else => return false,
        }
    }
}

fn isFirstImportedTexture(prepared_images: []const PreparedImage, index: usize) bool {
    const image = prepared_images[index].texture.image;
    for (prepared_images[0..index]) |prepared| {
        if (prepared.texture.imported and prepared.texture.image == image) return false;
    }
    return true;
}

fn supports(commands: []const render.Command) bool {
    for (commands) |command| switch (command) {
        .clear => {},
        .solid_rect, .image, .shadow, .backdrop_capture, .backdrop_blur => {},
        .crossfade => |fade| switch (fade.old) {
            .pixels => switch (fade.new) {
                .pixels => return false,
                .offscreen => {},
            },
            .offscreen => {},
        },
    };
    return true;
}

fn renderGpuFallback(self: *Self, frame: render.Frame, key: TargetKey) Error!void {
    const output = self.outputs.getPtr(key) orelse return error.InvalidTarget;
    if (output.kind == .pixels or !std.meta.eql(output.size, frame.size)) return error.InvalidTarget;
    const submission = &output.submission;
    try self.drainSubmission(submission);
    const pixel_count = frame.size.pixelCount() catch return error.InvalidTarget;
    const byte_count = std.math.mul(usize, pixel_count, @sizeOf(u32)) catch
        return error.InvalidTarget;
    try self.ensureWorkBuffer(submission, byte_count);
    const pixels: [*]u32 = @ptrCast(@alignCast(submission.work_mapped.?));
    const cpu_target: render.PixelBuffer = .{
        .size = frame.size,
        .stride_pixels = frame.size.width,
        .pixels = pixels[0..pixel_count],
    };
    try self.fallback.render(frame, cpu_target);

    std.debug.assert(output.command_buffer != .null_handle);
    output.recorded_frame.valid = false;
    self.device_wrapper.resetCommandBuffer(output.command_buffer, .{}) catch
        return error.VulkanFailure;
    self.device_wrapper.resetFences(self.device, &.{submission.fence}) catch
        return error.VulkanFailure;
    self.device_wrapper.beginCommandBuffer(output.command_buffer, &.{
        .flags = .{ .one_time_submit_bit = true },
    }) catch return error.VulkanFailure;
    if (output.kind == .dmabuf) {
        self.transitionExternal(
            output.command_buffer,
            output.*,
            if (output.initialized) .general else .undefined,
            .transfer_dst_optimal,
            if (output.initialized) vk.QUEUE_FAMILY_FOREIGN_EXT else vk.QUEUE_FAMILY_IGNORED,
            self.queue_family_index,
            .{},
            .{ .transfer_write_bit = true },
            if (output.initialized) .{ .all_commands_bit = true } else .{ .top_of_pipe_bit = true },
            .{ .transfer_bit = true },
        );
    } else {
        std.debug.assert(output.kind == .offscreen);
        self.transitionImage(
            output.command_buffer,
            output.image,
            if (output.initialized) .color_attachment_optimal else .undefined,
            .transfer_dst_optimal,
            if (output.initialized) .{ .color_attachment_write_bit = true } else .{},
            .{ .transfer_write_bit = true },
            if (output.initialized) .{ .color_attachment_output_bit = true } else .{ .top_of_pipe_bit = true },
            .{ .transfer_bit = true },
        );
    }
    if (frame.damage) |damage| {
        for (damage) |rect| {
            const clipped = rect.clipTo(frame.size) orelse continue;
            self.copyTextureRect(
                submission.work_buffer,
                output.command_buffer,
                output.image,
                cpu_target,
                0,
                clipped,
            );
        }
    } else self.copyTextureRect(submission.work_buffer, output.command_buffer, output.image, cpu_target, 0, .{
        .x = 0,
        .y = 0,
        .width = frame.size.width,
        .height = frame.size.height,
    });
    if (output.kind == .dmabuf) {
        self.transitionExternal(
            output.command_buffer,
            output.*,
            .transfer_dst_optimal,
            .general,
            self.queue_family_index,
            vk.QUEUE_FAMILY_FOREIGN_EXT,
            .{ .transfer_write_bit = true },
            .{},
            .{ .transfer_bit = true },
            .{ .bottom_of_pipe_bit = true },
        );
    } else {
        self.transitionImage(
            output.command_buffer,
            output.image,
            .transfer_dst_optimal,
            .color_attachment_optimal,
            .{ .transfer_write_bit = true },
            .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
            .{ .transfer_bit = true },
            .{ .color_attachment_output_bit = true },
        );
    }
    self.device_wrapper.endCommandBuffer(output.command_buffer) catch return error.VulkanFailure;
    const submit: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&output.command_buffer),
    };
    self.device_wrapper.queueSubmit(self.queue, &.{submit}, submission.fence) catch
        return error.VulkanFailure;
    submission.fence_pending = true;
    try self.drainSubmission(submission);
    output.initialized = true;
}

fn validateTarget(frame: render.Frame, target: render.Target) Error!usize {
    if (frame.size.width == 0 or frame.size.height == 0) return error.InvalidTarget;
    if (!std.meta.eql(frame.size, target.size())) return error.InvalidTarget;
    const pixels = switch (target) {
        .offscreen => |offscreen| {
            if (offscreen.id == 0) return error.InvalidTarget;
            return frame.size.pixelCount() catch return error.InvalidTarget;
        },
        .dmabuf => |dmabuf| {
            if (dmabuf.id == 0) return error.InvalidTarget;
            return frame.size.pixelCount() catch return error.InvalidTarget;
        },
        .pixels => |pixels| pixels,
    };
    if (pixels.stride_pixels < pixels.size.width) return error.InvalidTarget;
    if (pixels.dmabuf != null) return error.InvalidTarget;
    const last_row = std.math.mul(
        usize,
        pixels.size.height - 1,
        pixels.stride_pixels,
    ) catch return error.InvalidTarget;
    const required_pixels = std.math.add(usize, last_row, pixels.size.width) catch
        return error.InvalidTarget;
    if (pixels.pixels.len < required_pixels) return error.InvalidTarget;
    return required_pixels;
}

fn validateImage(image: render.Image) Error!void {
    if (image.size.width == 0 or image.size.height == 0) return error.InvalidTarget;
    _ = try requiredBufferPixels(image.buffer);
    if (image.buffer.source_damage) |damage| {
        for (damage) |rect| {
            const clipped = rect.clipTo(image.buffer.size) orelse return error.InvalidTarget;
            if (!std.meta.eql(rect, clipped)) return error.InvalidTarget;
        }
    }
    const transformed_size = image.transform.applyToSize(image.buffer.size);
    const source = image.source orelse render.SourceRect{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(transformed_size.width),
        .height = @floatFromInt(transformed_size.height),
    };
    if (!std.math.isFinite(source.x) or !std.math.isFinite(source.y) or
        !std.math.isFinite(source.width) or !std.math.isFinite(source.height) or
        source.x < 0 or source.y < 0 or source.width <= 0 or source.height <= 0 or
        source.x + source.width > @as(f64, @floatFromInt(transformed_size.width)) or
        source.y + source.height > @as(f64, @floatFromInt(transformed_size.height)))
    {
        return error.InvalidTarget;
    }
}

fn requiredBufferPixels(buffer: render.PixelBuffer) Error!usize {
    if (buffer.size.width == 0 or buffer.size.height == 0) return error.InvalidTarget;
    if (buffer.dmabuf) |dmabuf| {
        const format = render.DmabufFormat.fromFourcc(dmabuf.format) orelse
            return error.InvalidTarget;
        if (dmabuf.modifier != 0 or !format.isPackedRgb() or dmabuf.plane_count != 1) {
            return buffer.size.pixelCount() catch return error.InvalidTarget;
        }
    }
    if (buffer.stride_pixels < buffer.size.width) return error.InvalidTarget;
    const last_row = std.math.mul(
        usize,
        buffer.size.height - 1,
        buffer.stride_pixels,
    ) catch return error.InvalidTarget;
    const required = std.math.add(usize, last_row, buffer.size.width) catch
        return error.InvalidTarget;
    if (buffer.dmabuf) |dmabuf| {
        const plane = dmabuf.planes[0];
        const stride_bytes = std.math.mul(u64, buffer.stride_pixels, @sizeOf(u32)) catch
            return error.InvalidTarget;
        const last_row_bytes = std.math.mul(u64, buffer.size.height - 1, stride_bytes) catch
            return error.InvalidTarget;
        const required_bytes = std.math.add(
            u64,
            std.math.add(u64, plane.offset, last_row_bytes) catch return error.InvalidTarget,
            @as(u64, buffer.size.width) * @sizeOf(u32),
        ) catch return error.InvalidTarget;
        if (plane.stride != stride_bytes or required_bytes > plane.required_bytes or
            plane.offset % @alignOf(u32) != 0)
        {
            return error.InvalidTarget;
        }
        return required;
    }
    if (buffer.pixels.len < required) return error.InvalidTarget;
    return required;
}

fn targetKey(target: render.Target) TargetKey {
    return switch (target) {
        .pixels => |pixels| .{ .pixels = .{
            .pointer = @intFromPtr(pixels.pixels.ptr),
            .width = pixels.size.width,
            .height = pixels.size.height,
            .stride_pixels = pixels.stride_pixels,
        } },
        .offscreen => |offscreen| .{ .offscreen = offscreen.id },
        .dmabuf => |dmabuf| .{ .dmabuf = dmabuf.id },
    };
}

fn getOutput(self: *Self, key: TargetKey) Error!*Output {
    if (self.outputs.getPtr(key)) |output| return output;
    const pixels = switch (key) {
        .pixels => |pixels| pixels,
        .offscreen, .dmabuf => return error.InvalidTarget,
    };
    const output = try self.createOutput(.{ .width = pixels.width, .height = pixels.height });
    errdefer self.destroyOutput(output);
    self.outputs.put(self.allocator, key, output) catch return error.OutOfMemory;
    return self.outputs.getPtr(key).?;
}

fn createOutput(self: *Self, size: render.Size) Error!Output {
    const allocation = try self.createImage(size, .{
        .transfer_src_bit = true,
        .transfer_dst_bit = true,
        .color_attachment_bit = true,
        .sampled_bit = true,
    });
    errdefer self.destroyImageAllocation(allocation);
    const descriptor_set = try self.createImageDescriptor(allocation.view);
    errdefer self.destroyImageDescriptor(descriptor_set);
    const attachments = [_]vk.ImageView{allocation.view};
    const framebuffer = self.device_wrapper.createFramebuffer(self.device, &.{
        .render_pass = self.output_render_pass,
        .attachment_count = 1,
        .p_attachments = &attachments,
        .width = size.width,
        .height = size.height,
        .layers = 1,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyFramebuffer(self.device, framebuffer, null);
    const linear = try self.createWorkingTarget(size);
    errdefer self.destroyWorkingTarget(linear);
    const command_buffer = try self.allocateCommandBuffer();
    errdefer self.device_wrapper.freeCommandBuffers(
        self.device,
        self.command_pool,
        &.{command_buffer},
    );
    const submission = try self.createSubmission();
    errdefer self.destroySubmission(submission);
    return .{
        .image = allocation.image,
        .memory = allocation.memory,
        .view = allocation.view,
        .descriptor_set = descriptor_set,
        .framebuffer = framebuffer,
        .format = self.format,
        .size = size,
        .last_used = self.frame_number,
        .command_buffer = command_buffer,
        .linear = linear,
        .submission = submission,
    };
}

fn invalidateOutput(self: *Self, key: TargetKey) void {
    if (self.outputs.getPtr(key)) |output| {
        if (output.kind != .pixels) {
            output.initialized = false;
            output.linear_initialized = false;
            output.blur_initialized = 0;
            for (output.backdrop_cache.items) |*cache| {
                cache.key = null;
                cache.initialized = false;
            }
            output.recorded_frame.valid = false;
            return;
        }
    }
    if (self.outputs.fetchRemove(key)) |entry| self.destroyOutput(entry.value);
}

fn resetCommandBufferForTarget(self: *Self, key: TargetKey) void {
    if (self.outputs.getPtr(key)) |output| {
        self.device_wrapper.resetCommandBuffer(output.command_buffer, .{}) catch {};
        output.recorded_frame.valid = false;
        return;
    }
    self.device_wrapper.resetCommandBuffer(self.command_buffer, .{}) catch {};
}

fn destroyOutput(self: *Self, value: Output) void {
    var output = value;
    self.drainSubmission(&output.submission) catch {};
    self.destroySubmission(output.submission);
    if (output.blur) |blur| self.destroyBlurScratch(blur);
    for (output.backdrop_cache.items) |cache| self.destroyBackdropCache(cache);
    output.backdrop_cache.deinit(self.allocator);
    output.recorded_frame.deinit(self.allocator);
    if (output.command_buffer != .null_handle) {
        self.device_wrapper.freeCommandBuffers(
            self.device,
            self.command_pool,
            &.{output.command_buffer},
        );
    }
    self.device_wrapper.destroyFramebuffer(self.device, output.framebuffer, null);
    if (output.descriptor_set != .null_handle) self.destroyImageDescriptor(output.descriptor_set);
    self.destroyWorkingTarget(output.linear);
    self.destroyImageAllocation(.{
        .image = output.image,
        .memory = output.memory,
        .view = output.view,
    });
}

fn createBlurImage(self: *Self, size: render.Size, usage: vk.ImageUsageFlags) Error!BlurImage {
    const allocation = try self.createWorkingImage(size, usage);
    errdefer self.destroyImageAllocation(allocation);
    const descriptor_set = try self.createImageDescriptor(allocation.view);
    return .{ .image = allocation.image, .memory = allocation.memory, .view = allocation.view, .descriptor_set = descriptor_set };
}

fn createImageDescriptor(self: *Self, view: vk.ImageView) Error!vk.DescriptorSet {
    var descriptor_set: vk.DescriptorSet = undefined;
    self.device_wrapper.allocateDescriptorSets(self.device, &.{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
    }, @ptrCast(&descriptor_set)) catch return error.VulkanFailure;
    self.updateImageDescriptor(descriptor_set, self.sampler, view);
    return descriptor_set;
}

fn updateImageDescriptor(
    self: *Self,
    descriptor_set: vk.DescriptorSet,
    sampler: vk.Sampler,
    view: vk.ImageView,
) void {
    const image_info: vk.DescriptorImageInfo = .{
        .sampler = sampler,
        .image_view = view,
        .image_layout = .shader_read_only_optimal,
    };
    self.device_wrapper.updateDescriptorSets(self.device, &.{.{
        .dst_set = descriptor_set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = @ptrCast(&image_info),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    }}, null);
}

fn destroyImageDescriptor(self: *Self, descriptor_set: vk.DescriptorSet) void {
    _ = self.device_wrapper.freeDescriptorSets(self.device, self.descriptor_pool, &.{descriptor_set}) catch {};
}

fn ensureBlurLevel(self: *Self, scratch: *BlurScratch, output_size: render.Size, index: usize) Error!void {
    std.debug.assert(index < blur_level_count);
    if (scratch.levels[index] != null) return;
    const level_size = blur_geometry.levelSize(output_size, @intCast(index));
    const a = try self.createBlurImage(level_size, .{ .color_attachment_bit = true, .sampled_bit = true });
    errdefer self.destroyBlurImage(a);
    const b = try self.createBlurImage(level_size, .{ .color_attachment_bit = true, .sampled_bit = true });
    errdefer self.destroyBlurImage(b);
    const a_framebuffer = self.device_wrapper.createFramebuffer(self.device, &.{ .render_pass = self.scratch_render_pass, .attachment_count = 1, .p_attachments = @ptrCast(&a.view), .width = level_size.width, .height = level_size.height, .layers = 1 }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyFramebuffer(self.device, a_framebuffer, null);
    const b_framebuffer = self.device_wrapper.createFramebuffer(self.device, &.{ .render_pass = self.scratch_render_pass, .attachment_count = 1, .p_attachments = @ptrCast(&b.view), .width = level_size.width, .height = level_size.height, .layers = 1 }, null) catch return error.VulkanFailure;
    scratch.levels[index] = .{ .size = level_size, .a = a, .b = b, .a_framebuffer = a_framebuffer, .b_framebuffer = b_framebuffer };
}

fn prepareBackdropCaches(
    self: *Self,
    output: *Output,
    damage: ?[]const render.Rect,
) Error!bool {
    var cache_changed = false;
    var next_cache_index: usize = 0;
    var incomplete_capture_damage = false;
    for (self.blur_ops.items, 0..) |*blur_op, op_index| {
        if (!blur_op.used) continue;
        if (blur_op.reuse_op_index) |source_index| {
            std.debug.assert(source_index < op_index);
            blur_op.cache_index = self.blur_ops.items[source_index].cache_index;
            blur_op.cache_hit = true;
            continue;
        }

        const cache_size = output.size;
        blur_op.cache_index = @intCast(next_cache_index);
        cache_changed = selectBackdropCache(
            output,
            next_cache_index,
            cache_size,
            blur_op.cache_key,
        ) or cache_changed;
        const cache = try self.ensureBackdropCache(output, next_cache_index, cache_size);
        blur_op.cache_hit = cache.matches(blur_op.cache_key);
        if (!blur_op.cache_hit and cache.initialized and
            blur_op.cache_key != null and cache.geometry_key == blur_op.geometry_key)
        {
            if (damage) |rectangles| {
                if (!damageIntersectsRect(rectangles, blur_op.sample_rect)) {
                    blur_op.cache_hit = true;
                    blur_op.cache_rekey = true;
                }
            }
        }
        next_cache_index += 1;
        if (!blur_op.cache_hit) {
            if (damage) |rectangles| {
                if (!try damageCoversRect(self.allocator, rectangles, blur_op.sample_rect)) {
                    incomplete_capture_damage = true;
                }
            }
        }
        if (blur_op.cache_hit) continue;

        if (output.blur == null) output.blur = .{};
        if (blur_op.level == 0) {
            try self.ensureBlurLevel(&output.blur.?, output.size, 0);
        }
        for (1..@as(usize, blur_op.level) + 1) |level| {
            try self.ensureBlurLevel(&output.blur.?, output.size, level);
        }
    }

    while (output.backdrop_cache.items.len > next_cache_index) {
        self.destroyBackdropCache(output.backdrop_cache.pop().?);
        cache_changed = true;
    }
    if (cache_changed) output.recorded_frame.valid = false;
    return incomplete_capture_damage;
}

fn damageCoversRect(
    allocator: std.mem.Allocator,
    damage: []const render.Rect,
    rect: render.Rect,
) error{OutOfMemory}!bool {
    var uncovered: std.ArrayList(render.Rect) = .empty;
    defer uncovered.deinit(allocator);
    var next: std.ArrayList(render.Rect) = .empty;
    defer next.deinit(allocator);
    try uncovered.append(allocator, rect);

    for (damage) |damaged| {
        next.clearRetainingCapacity();
        for (uncovered.items) |fragment| {
            const overlap = fragment.intersection(damaged) orelse {
                try next.append(allocator, fragment);
                continue;
            };
            const fragment_right = @as(i64, fragment.x) + fragment.width;
            const fragment_bottom = @as(i64, fragment.y) + fragment.height;
            const overlap_right = @as(i64, overlap.x) + overlap.width;
            const overlap_bottom = @as(i64, overlap.y) + overlap.height;
            if (overlap.y > fragment.y) try next.append(allocator, .{
                .x = fragment.x,
                .y = fragment.y,
                .width = fragment.width,
                .height = @intCast(overlap.y - fragment.y),
            });
            if (overlap_bottom < fragment_bottom) try next.append(allocator, .{
                .x = fragment.x,
                .y = @intCast(overlap_bottom),
                .width = fragment.width,
                .height = @intCast(fragment_bottom - overlap_bottom),
            });
            if (overlap.x > fragment.x) try next.append(allocator, .{
                .x = fragment.x,
                .y = overlap.y,
                .width = @intCast(overlap.x - fragment.x),
                .height = overlap.height,
            });
            if (overlap_right < fragment_right) try next.append(allocator, .{
                .x = @intCast(overlap_right),
                .y = overlap.y,
                .width = @intCast(fragment_right - overlap_right),
                .height = overlap.height,
            });
        }
        std.mem.swap(std.ArrayList(render.Rect), &uncovered, &next);
        if (uncovered.items.len == 0) return true;
    }
    return false;
}

fn damageIntersectsRect(damage: []const render.Rect, rect: render.Rect) bool {
    for (damage) |damaged| {
        if (damaged.intersection(rect) != null) return true;
    }
    return false;
}

fn ensureBackdropCache(
    self: *Self,
    output: *Output,
    index: usize,
    size: render.Size,
) Error!*BackdropCache {
    while (output.backdrop_cache.items.len <= index) {
        const cache = try self.createBackdropCache(size);
        output.backdrop_cache.append(self.allocator, cache) catch |err| {
            self.destroyBackdropCache(cache);
            return err;
        };
        output.recorded_frame.valid = false;
    }
    const cache = &output.backdrop_cache.items[index];
    if (std.meta.eql(cache.size, size)) return cache;
    const replacement = try self.createBackdropCache(size);
    self.destroyBackdropCache(cache.*);
    cache.* = replacement;
    output.recorded_frame.valid = false;
    return cache;
}

fn selectBackdropCache(
    output: *Output,
    index: usize,
    size: render.Size,
    key: ?u64,
) bool {
    const stable_key = key orelse return false;
    if (index >= output.backdrop_cache.items.len) return false;
    for (output.backdrop_cache.items[index..], index..) |cache, candidate| {
        if (!std.meta.eql(cache.size, size) or !cache.matches(stable_key)) continue;
        if (candidate == index) return false;
        std.mem.swap(
            BackdropCache,
            &output.backdrop_cache.items[index],
            &output.backdrop_cache.items[candidate],
        );
        return true;
    }
    return false;
}

fn createBackdropCache(self: *Self, size: render.Size) Error!BackdropCache {
    const image = try self.createBlurImage(size, .{
        .color_attachment_bit = true,
        .sampled_bit = true,
    });
    errdefer self.destroyBlurImage(image);
    const framebuffer = self.device_wrapper.createFramebuffer(self.device, &.{
        .render_pass = self.scratch_render_pass,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&image.view),
        .width = size.width,
        .height = size.height,
        .layers = 1,
    }, null) catch return error.VulkanFailure;
    return .{ .size = size, .image = image, .framebuffer = framebuffer };
}

fn destroyBackdropCache(self: *Self, cache: BackdropCache) void {
    self.device_wrapper.destroyFramebuffer(self.device, cache.framebuffer, null);
    self.destroyBlurImage(cache.image);
}

fn destroyBlurImage(self: *Self, image: BlurImage) void {
    self.destroyImageDescriptor(image.descriptor_set);
    self.destroyImageAllocation(.{ .image = image.image, .memory = image.memory, .view = image.view });
}

fn destroyBlurScratch(self: *Self, blur: BlurScratch) void {
    for (blur.levels) |level| if (level) |value| self.destroyBlurLevel(value);
}

fn destroyBlurLevel(self: *Self, level: BlurLevel) void {
    self.device_wrapper.destroyFramebuffer(self.device, level.b_framebuffer, null);
    self.device_wrapper.destroyFramebuffer(self.device, level.a_framebuffer, null);
    self.destroyBlurImage(level.b);
    self.destroyBlurImage(level.a);
}

const ImageAllocation = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
};

fn createImage(
    self: *Self,
    size: render.Size,
    usage: vk.ImageUsageFlags,
) Error!ImageAllocation {
    return self.createImageForFormat(size, usage, self.format);
}

fn createWorkingImage(
    self: *Self,
    size: render.Size,
    usage: vk.ImageUsageFlags,
) Error!ImageAllocation {
    return self.createImageForFormat(size, usage, working_format);
}

fn createImageForFormat(
    self: *Self,
    size: render.Size,
    usage: vk.ImageUsageFlags,
    format: vk.Format,
) Error!ImageAllocation {
    const image = self.device_wrapper.createImage(self.device, &.{
        .image_type = .@"2d",
        .format = format,
        .extent = extent(size),
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImage(self.device, image, null);
    const requirements = self.device_wrapper.getImageMemoryRequirements(self.device, image);
    const memory_type = self.deviceMemoryType(requirements.memory_type_bits) orelse
        return error.VulkanFailure;
    const memory = self.device_wrapper.allocateMemory(self.device, &.{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    }, null) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        else => return error.VulkanFailure,
    };
    errdefer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindImageMemory(self.device, image, memory, 0) catch
        return error.VulkanFailure;
    const view = self.device_wrapper.createImageView(self.device, &.{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = colorSubresourceRange(),
    }, null) catch return error.VulkanFailure;
    return .{ .image = image, .memory = memory, .view = view };
}

fn createCalibrationTexture(self: *Self, edge_length: u32) Error!CalibrationTexture {
    const image = self.device_wrapper.createImage(self.device, &.{
        .image_type = .@"3d",
        .format = working_format,
        .extent = .{ .width = edge_length, .height = edge_length, .depth = edge_length },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImage(self.device, image, null);
    const requirements = self.device_wrapper.getImageMemoryRequirements(self.device, image);
    const memory_type = self.deviceMemoryType(requirements.memory_type_bits) orelse
        return error.VulkanFailure;
    const memory = self.device_wrapper.allocateMemory(self.device, &.{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    }, null) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        else => return error.VulkanFailure,
    };
    errdefer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindImageMemory(self.device, image, memory, 0) catch
        return error.VulkanFailure;
    const view = self.device_wrapper.createImageView(self.device, &.{
        .image = image,
        .view_type = .@"3d",
        .format = working_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = colorSubresourceRange(),
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImageView(self.device, view, null);
    const descriptor_set = try self.createImageDescriptor(view);
    return .{
        .image = image,
        .memory = memory,
        .view = view,
        .descriptor_set = descriptor_set,
        .last_used = self.frame_number,
    };
}

fn destroyCalibrationTexture(self: *Self, texture: CalibrationTexture) void {
    self.advanceResourceEpoch();
    self.destroyImageDescriptor(texture.descriptor_set);
    self.destroyImageAllocation(.{
        .image = texture.image,
        .memory = texture.memory,
        .view = texture.view,
    });
}

fn createWorkingTarget(self: *Self, size: render.Size) Error!WorkingImage {
    const allocation = try self.createWorkingImage(size, .{
        .color_attachment_bit = true,
        .sampled_bit = true,
    });
    errdefer self.destroyImageAllocation(allocation);
    const descriptor_set = try self.createImageDescriptor(allocation.view);
    errdefer self.destroyImageDescriptor(descriptor_set);
    const framebuffer = self.device_wrapper.createFramebuffer(self.device, &.{
        .render_pass = self.render_pass,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&allocation.view),
        .width = size.width,
        .height = size.height,
        .layers = 1,
    }, null) catch return error.VulkanFailure;
    return .{
        .image = allocation.image,
        .memory = allocation.memory,
        .view = allocation.view,
        .descriptor_set = descriptor_set,
        .framebuffer = framebuffer,
    };
}

fn destroyWorkingTarget(self: *Self, target: WorkingImage) void {
    self.device_wrapper.destroyFramebuffer(self.device, target.framebuffer, null);
    self.destroyImageDescriptor(target.descriptor_set);
    self.destroyImageAllocation(.{
        .image = target.image,
        .memory = target.memory,
        .view = target.view,
    });
}

fn destroyImageAllocation(self: *Self, allocation: ImageAllocation) void {
    self.device_wrapper.destroyImageView(self.device, allocation.view, null);
    self.device_wrapper.destroyImage(self.device, allocation.image, null);
    self.device_wrapper.freeMemory(self.device, allocation.memory, null);
}

fn prepareTexture(
    self: *Self,
    buffer: render.PixelBuffer,
    previously_prepared: []const PreparedImage,
    work_size: *usize,
) Error!PreparedImage {
    const required_pixels = try requiredBufferPixels(buffer);
    const byte_size = std.math.mul(usize, required_pixels, @sizeOf(u32)) catch
        return error.InvalidTarget;
    if (buffer.dmabuf) |dmabuf| {
        if (self.supportsDmabufSource(buffer.size, dmabuf)) {
            const imported = self.prepareImportedTexture(buffer, previously_prepared) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (dmabuf.modifier != 0) {
                    log.err(
                        "Vulkan DMA-BUF source import failed: size={d}x{d} format=0x{x} modifier=0x{x} planes={d}: {t}",
                        .{
                            buffer.size.width,
                            buffer.size.height,
                            dmabuf.format,
                            dmabuf.modifier,
                            dmabuf.plane_count,
                            err,
                        },
                    );
                    return error.InvalidTarget;
                }
                log.warn("Vulkan linear DMA-BUF source import failed; using CPU upload fallback: {t}", .{err});
                break :blk null;
            };
            if (imported) |prepared| return prepared;
        }
        if (dmabuf.modifier != 0 or dmabuf.plane_count != 1) {
            log.err(
                "Vulkan DMA-BUF source is not importable: size={d}x{d} format=0x{x} modifier=0x{x} planes={d}",
                .{
                    buffer.size.width,
                    buffer.size.height,
                    dmabuf.format,
                    dmabuf.modifier,
                    dmabuf.plane_count,
                },
            );
            return error.InvalidTarget;
        }
    }
    if (buffer.source_cache) |source| {
        for (previously_prepared) |prepared| {
            if (prepared.cache_id == source.id) {
                std.debug.assert(prepared.desired_version == source.version);
                return .{
                    .texture = prepared.texture,
                    .buffer = buffer,
                    .upload_offset = null,
                    .upload_damage = null,
                    .cache_id = source.id,
                    .desired_version = source.version,
                };
            }
        }
        if (self.textures.get(source.id)) |existing| {
            if (existing.imported or !std.meta.eql(existing.size, buffer.size)) {
                try self.drainAllPending();
                const removed = self.textures.fetchRemove(source.id).?;
                self.destroyTexture(removed.value);
            }
        }
        if (self.textures.getPtr(source.id)) |texture| {
            texture.last_used = self.frame_number;
            const unchanged = texture.initialized and texture.version == source.version;
            const upload_damage = if (!unchanged and texture.initialized and
                texture.version +% 1 == source.version)
                buffer.source_damage
            else
                null;
            const upload_offset = if (unchanged or
                (upload_damage != null and upload_damage.?.len == 0))
                null
            else
                try reserveWork(work_size, byte_size);
            return .{
                .texture = texture.*,
                .buffer = buffer,
                .upload_offset = upload_offset,
                .upload_damage = upload_damage,
                .cache_id = source.id,
                .desired_version = source.version,
            };
        }

        const upload_offset = try reserveWork(work_size, byte_size);
        self.makeTextureRoom() catch return error.VulkanFailure;
        const texture = try self.createTexture(buffer.size);
        errdefer self.destroyTexture(texture);
        self.textures.put(self.allocator, source.id, texture) catch return error.OutOfMemory;
        return .{
            .texture = texture,
            .buffer = buffer,
            .upload_offset = upload_offset,
            .upload_damage = null,
            .cache_id = source.id,
            .desired_version = source.version,
        };
    }

    const upload_offset = try reserveWork(work_size, byte_size);
    const texture = try self.createTexture(buffer.size);
    return .{
        .texture = texture,
        .buffer = buffer,
        .upload_offset = upload_offset,
        .upload_damage = null,
        .cache_id = null,
        .desired_version = 0,
    };
}

fn prepareImportedTexture(
    self: *Self,
    buffer: render.PixelBuffer,
    previously_prepared: []const PreparedImage,
) Error!PreparedImage {
    const source = buffer.source_cache orelse return error.InvalidTarget;
    const format = render.DmabufFormat.fromFourcc(buffer.dmabuf.?.format) orelse
        return error.InvalidTarget;
    const video_representation: ?render.ColorRepresentation = if (format.isPackedRgb())
        null
    else
        buffer.color_representation;
    for (previously_prepared) |prepared| {
        if (prepared.cache_id == source.id) {
            if (!prepared.texture.imported) return error.InvalidTarget;
            if (!std.meta.eql(prepared.texture.video_representation, video_representation)) {
                const texture = try self.createImportedTexture(
                    buffer.size,
                    buffer.dmabuf.?,
                    buffer.color_representation,
                );
                return .{
                    .texture = texture,
                    .buffer = buffer,
                    .upload_offset = null,
                    .upload_damage = null,
                    .cache_id = null,
                    .desired_version = source.version,
                    .newly_imported = true,
                };
            }
            return .{
                .texture = prepared.texture,
                .buffer = buffer,
                .upload_offset = null,
                .upload_damage = null,
                .cache_id = source.id,
                .desired_version = source.version,
            };
        }
    }
    if (self.textures.get(source.id)) |existing| {
        if (!existing.imported or
            !std.meta.eql(existing.size, buffer.size) or
            !std.meta.eql(existing.video_representation, video_representation))
        {
            try self.drainAllPending();
            const removed = self.textures.fetchRemove(source.id).?;
            self.destroyTexture(removed.value);
        }
    }
    if (self.textures.getPtr(source.id)) |texture| {
        texture.last_used = self.frame_number;
        return .{
            .texture = texture.*,
            .buffer = buffer,
            .upload_offset = null,
            .upload_damage = null,
            .cache_id = source.id,
            .desired_version = source.version,
        };
    }

    self.makeTextureRoom() catch return error.VulkanFailure;
    const texture = try self.createImportedTexture(
        buffer.size,
        buffer.dmabuf.?,
        buffer.color_representation,
    );
    errdefer self.destroyTexture(texture);
    self.textures.put(self.allocator, source.id, texture) catch return error.OutOfMemory;
    return .{
        .texture = texture,
        .buffer = buffer,
        .upload_offset = null,
        .upload_damage = null,
        .cache_id = source.id,
        .desired_version = source.version,
        .newly_imported = true,
    };
}

fn recordedFrameMatches(
    self: *const Self,
    submission: *const Submission,
    recorded: *const RecordedFrame,
    output_initialized: bool,
    blur_initialized: u16,
    render_area: render.Rect,
    prepared_images: []const PreparedImage,
) bool {
    if (!recorded.valid or
        recorded.resource_epoch != self.resource_epoch or
        recorded.output_initialized != output_initialized or
        recorded.blur_initialized != blur_initialized or
        !std.meta.eql(recorded.render_area, render_area) or
        recorded.work_buffer != submission.work_buffer or
        recorded.instance_buffer != submission.instance_buffer or
        recorded.timestamp_query_pool != submission.timestamp_query_pool or
        recorded.draw_runs.items.len != self.draw_runs.items.len or
        recorded.blur_ops.items.len != self.blur_ops.items.len)
    {
        return false;
    }
    for (recorded.draw_runs.items, self.draw_runs.items) |recorded_run, run| {
        if (!std.meta.eql(recorded_run, run)) return false;
    }
    for (recorded.blur_ops.items, self.blur_ops.items) |recorded_op, op| {
        if (!std.meta.eql(recorded_op, op)) return false;
    }

    var upload_index: usize = 0;
    var rectangle_index: usize = 0;
    for (prepared_images) |prepared| {
        const offset = prepared.upload_offset orelse continue;
        if (upload_index >= recorded.uploads.items.len) return false;
        const upload = recorded.uploads.items[upload_index];
        upload_index += 1;
        const rectangle_count = uploadRectangleCount(prepared);
        if (upload.image != prepared.texture.image or
            upload.initialized != prepared.texture.initialized or
            !std.meta.eql(upload.buffer_size, prepared.buffer.size) or
            upload.stride_pixels != prepared.buffer.stride_pixels or
            upload.offset != offset or
            upload.first_rectangle != rectangle_index or
            upload.rectangle_count != rectangle_count)
        {
            return false;
        }
        for (0..rectangle_count) |index| {
            if (rectangle_index >= recorded.upload_rectangles.items.len or
                !std.meta.eql(
                    recorded.upload_rectangles.items[rectangle_index],
                    uploadRectangle(prepared, index),
                ))
            {
                return false;
            }
            rectangle_index += 1;
        }
    }
    return upload_index == recorded.uploads.items.len and
        rectangle_index == recorded.upload_rectangles.items.len;
}

fn rememberRecordedFrame(
    self: *Self,
    submission: *const Submission,
    recorded: *RecordedFrame,
    output_initialized: bool,
    blur_initialized: u16,
    render_area: render.Rect,
    prepared_images: []const PreparedImage,
) error{OutOfMemory}!void {
    recorded.valid = false;
    recorded.uploads.clearRetainingCapacity();
    recorded.upload_rectangles.clearRetainingCapacity();
    recorded.draw_runs.clearRetainingCapacity();
    recorded.blur_ops.clearRetainingCapacity();

    for (prepared_images) |prepared| {
        const offset = prepared.upload_offset orelse continue;
        const first_rectangle = recorded.upload_rectangles.items.len;
        const rectangle_count = uploadRectangleCount(prepared);
        for (0..rectangle_count) |index| {
            try recorded.upload_rectangles.append(self.allocator, uploadRectangle(prepared, index));
        }
        try recorded.uploads.append(self.allocator, .{
            .image = prepared.texture.image,
            .initialized = prepared.texture.initialized,
            .buffer_size = prepared.buffer.size,
            .stride_pixels = prepared.buffer.stride_pixels,
            .offset = offset,
            .first_rectangle = first_rectangle,
            .rectangle_count = rectangle_count,
        });
    }
    try recorded.draw_runs.appendSlice(self.allocator, self.draw_runs.items);
    try recorded.blur_ops.appendSlice(self.allocator, self.blur_ops.items);
    recorded.resource_epoch = self.resource_epoch;
    recorded.output_initialized = output_initialized;
    recorded.blur_initialized = blur_initialized;
    recorded.render_area = render_area;
    recorded.work_buffer = submission.work_buffer;
    recorded.instance_buffer = submission.instance_buffer;
    recorded.timestamp_query_pool = submission.timestamp_query_pool;
    recorded.valid = true;
}

fn uploadRectangleCount(prepared: PreparedImage) usize {
    if (prepared.upload_damage) |damage| {
        std.debug.assert(damage.len > 0);
        return damage.len;
    }
    return 1;
}

fn uploadRectangle(prepared: PreparedImage, index: usize) render.Rect {
    if (prepared.upload_damage) |damage| return damage[index];
    std.debug.assert(index == 0);
    return .{
        .x = 0,
        .y = 0,
        .width = prepared.buffer.size.width,
        .height = prepared.buffer.size.height,
    };
}

fn reserveWork(work_size: *usize, byte_size: usize) Error!usize {
    const aligned = std.mem.alignForward(usize, work_size.*, @alignOf(u32));
    work_size.* = std.math.add(usize, aligned, byte_size) catch return error.InvalidTarget;
    return aligned;
}

fn prepareCalibration(
    self: *Self,
    calibration: ?render.OutputCalibration,
    work_size: *usize,
) Error!?PreparedCalibration {
    const value = calibration orelse return null;
    const edge = render.output_calibration_edge_length;
    if (value.edge_length != edge or value.values.len != edge * edge * edge) {
        return error.InvalidTarget;
    }
    if (self.calibrations.getPtr(value.identity)) |texture| {
        std.debug.assert(texture.initialized);
        texture.last_used = self.frame_number;
        return .{
            .identity = value.identity,
            .texture = texture.*,
            .upload_offset = null,
        };
    }

    work_size.* = std.mem.alignForward(usize, work_size.*, @sizeOf([4]f16));
    const upload_offset = try reserveWork(work_size, std.mem.sliceAsBytes(value.values).len);
    const texture = try self.createCalibrationTexture(value.edge_length);
    errdefer self.destroyCalibrationTexture(texture);
    self.calibrations.put(self.allocator, value.identity, texture) catch
        return error.OutOfMemory;
    self.advanceResourceEpoch();
    return .{
        .identity = value.identity,
        .texture = texture,
        .upload_offset = upload_offset,
    };
}

fn createTexture(self: *Self, size: render.Size) Error!Texture {
    const allocation = try self.createImage(size, .{
        .transfer_dst_bit = true,
        .sampled_bit = true,
    });
    errdefer self.destroyImageAllocation(allocation);
    const descriptor_set = try self.createImageDescriptor(allocation.view);
    errdefer self.destroyImageDescriptor(descriptor_set);
    const texture: Texture = .{
        .image = allocation.image,
        .memory = allocation.memory,
        .view = allocation.view,
        .descriptor_set = descriptor_set,
        .size = size,
        .last_used = self.frame_number,
    };
    self.advanceResourceEpoch();
    return texture;
}

fn createImportedTexture(
    self: *Self,
    size: render.Size,
    source: render.DmabufSource,
    representation: render.ColorRepresentation,
) Error!Texture {
    if (!self.supportsDmabufSource(size, source)) return error.InvalidTarget;
    const format_info = render.DmabufFormat.fromFourcc(source.format) orelse
        return error.InvalidTarget;
    const source_format = vulkan_format.sourceVkFormat(source.format) orelse return error.InvalidTarget;
    const conversion_parameters: ?vulkan_format.YcbcrConversion = if (format_info.isPackedRgb())
        null
    else
        vulkan_format.automaticConversion(representation);
    const manual_parameters: ?ManualYcbcr = if (format_info.isPackedRgb() or
        conversion_parameters != null)
        null
    else
        vulkan_format.manualConversion(source_format, representation) orelse
            return error.InvalidTarget;
    if (!format_info.isPackedRgb() and !dmabufPlanesShareAllocation(source.planeSlice())) {
        return error.InvalidTarget;
    }
    const video_graphics: ?VideoGraphics = if (conversion_parameters) |parameters|
        try self.getVideoGraphics(vulkan_format.automaticGraphicsKey(source_format, parameters))
    else if (manual_parameters != null)
        try self.getVideoGraphics(vulkan_format.manualGraphicsKey(source_format))
    else
        null;
    const duplicate_fd = std.c.dup(source.planes[0].fd);
    if (duplicate_fd < 0) return error.VulkanFailure;
    var fd_owned = true;
    defer if (fd_owned) {
        _ = std.c.close(duplicate_fd);
    };
    var plane_layouts: [render.max_dmabuf_planes]vk.SubresourceLayout = undefined;
    for (source.planeSlice(), plane_layouts[0..source.plane_count]) |source_plane, *plane| {
        plane.* = .{
            .offset = source_plane.offset,
            .size = 0,
            .row_pitch = source_plane.stride,
            .array_pitch = 0,
            .depth_pitch = 0,
        };
    }
    const modifier_info: vk.ImageDrmFormatModifierExplicitCreateInfoEXT = .{
        .drm_format_modifier = source.modifier,
        .drm_format_modifier_plane_count = source.plane_count,
        .p_plane_layouts = &plane_layouts,
    };
    var plane_view_formats = if (manual_parameters != null)
        vulkan_format.planeViewFormats(source_format)
    else
        null;
    var format_list: vk.ImageFormatListCreateInfo = .{ .p_next = &modifier_info };
    if (plane_view_formats) |*formats| {
        format_list.view_format_count = formats.len;
        format_list.p_view_formats = formats;
    }
    const external_info: vk.ExternalMemoryImageCreateInfo = .{
        .p_next = if (plane_view_formats != null) &format_list else &modifier_info,
        .handle_types = .{ .dma_buf_bit_ext = true },
    };
    const image = self.device_wrapper.createImage(self.device, &.{
        .p_next = &external_info,
        .flags = .{ .mutable_format_bit = plane_view_formats != null },
        .image_type = .@"2d",
        .format = source_format,
        .extent = extent(size),
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .drm_format_modifier_ext,
        .usage = .{ .sampled_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImage(self.device, image, null);
    const requirements = self.device_wrapper.getImageMemoryRequirements(self.device, image);
    var fd_properties: vk.MemoryFdPropertiesKHR = .{ .memory_type_bits = 0 };
    self.device_wrapper.getMemoryFdPropertiesKHR(
        self.device,
        .{ .dma_buf_bit_ext = true },
        duplicate_fd,
        &fd_properties,
    ) catch return error.VulkanFailure;
    const memory_type = self.deviceMemoryType(
        requirements.memory_type_bits & fd_properties.memory_type_bits,
    ) orelse return error.VulkanFailure;
    const dedicated: vk.MemoryDedicatedAllocateInfo = .{ .image = image };
    const import_info: vk.ImportMemoryFdInfoKHR = .{
        .p_next = &dedicated,
        .handle_type = .{ .dma_buf_bit_ext = true },
        .fd = duplicate_fd,
    };
    const memory = self.device_wrapper.allocateMemory(self.device, &.{
        .p_next = &import_info,
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    }, null) catch return error.VulkanFailure;
    fd_owned = false;
    errdefer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindImageMemory(self.device, image, memory, 0) catch
        return error.VulkanFailure;
    const conversion = if (video_graphics) |graphics| graphics.conversion else null;
    const conversion_info: vk.SamplerYcbcrConversionInfo = .{
        .conversion = conversion orelse .null_handle,
    };
    const primary_range: vk.ImageSubresourceRange = if (manual_parameters != null) .{
        .aspect_mask = .{ .plane_0_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    } else colorSubresourceRange();
    const view = self.device_wrapper.createImageView(self.device, &.{
        .p_next = if (conversion != null) &conversion_info else null,
        .image = image,
        .view_type = .@"2d",
        .format = if (manual_parameters != null) plane_view_formats.?[0] else source_format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = if (format_info.isPackedRgb() and source.force_opaque) .one else .identity,
        },
        .subresource_range = primary_range,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImageView(self.device, view, null);
    const secondary_view: ?vk.ImageView = if (manual_parameters != null)
        self.device_wrapper.createImageView(self.device, &.{
            .image = image,
            .view_type = .@"2d",
            .format = plane_view_formats.?[1],
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .plane_1_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null) catch return error.VulkanFailure
    else
        null;
    errdefer if (secondary_view) |secondary| {
        self.device_wrapper.destroyImageView(self.device, secondary, null);
    };
    const descriptor_set_layout = if (video_graphics) |graphics|
        graphics.descriptor_set_layout
    else
        self.descriptor_set_layout;
    var descriptor_set: vk.DescriptorSet = undefined;
    self.device_wrapper.allocateDescriptorSets(self.device, &.{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&descriptor_set_layout),
    }, @ptrCast(&descriptor_set)) catch return error.VulkanFailure;
    errdefer self.device_wrapper.freeDescriptorSets(
        self.device,
        self.descriptor_pool,
        &.{descriptor_set},
    ) catch {};
    const sampler = if (video_graphics) |graphics| graphics.sampler else self.sampler;
    const image_infos = [_]vk.DescriptorImageInfo{
        .{
            .sampler = sampler,
            .image_view = view,
            .image_layout = .shader_read_only_optimal,
        },
        .{
            .sampler = sampler,
            .image_view = secondary_view orelse view,
            .image_layout = .shader_read_only_optimal,
        },
    };
    const descriptor_writes = [_]vk.WriteDescriptorSet{
        .{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&image_infos[0]),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        .{
            .dst_set = descriptor_set,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&image_infos[1]),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    };
    if (video_graphics == null) {
        self.updateImageDescriptor(descriptor_set, self.sampler, view);
    } else {
        self.device_wrapper.updateDescriptorSets(
            self.device,
            descriptor_writes[0..if (manual_parameters != null) 2 else 1],
            null,
        );
    }
    const texture: Texture = .{
        .image = image,
        .memory = memory,
        .view = view,
        .secondary_view = secondary_view,
        .descriptor_set = descriptor_set,
        .pipeline = if (video_graphics) |graphics| graphics.pipeline else .null_handle,
        .pipeline_layout = if (video_graphics) |graphics|
            graphics.pipeline_layout
        else
            .null_handle,
        .video_representation = if (format_info.isPackedRgb()) null else representation,
        .manual_ycbcr = manual_parameters,
        .size = size,
        .initialized = true,
        .imported = true,
        .last_used = self.frame_number,
    };
    self.advanceResourceEpoch();
    return texture;
}

fn destroyTexture(self: *Self, texture: Texture) void {
    self.advanceResourceEpoch();
    self.device_wrapper.freeDescriptorSets(
        self.device,
        self.descriptor_pool,
        &.{texture.descriptor_set},
    ) catch {};
    if (texture.secondary_view) |view| {
        self.device_wrapper.destroyImageView(self.device, view, null);
    }
    self.device_wrapper.destroyImageView(self.device, texture.view, null);
    self.device_wrapper.destroyImage(self.device, texture.image, null);
    self.device_wrapper.freeMemory(self.device, texture.memory, null);
}

fn makeTextureRoom(self: *Self) !void {
    if (self.textures.count() < max_cached_textures) return;
    var oldest_id: ?u64 = null;
    var oldest_frame: u64 = std.math.maxInt(u64);
    var iterator = self.textures.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.last_used < oldest_frame and
            entry.value_ptr.last_used != self.frame_number)
        {
            oldest_id = entry.key_ptr.*;
            oldest_frame = entry.value_ptr.last_used;
        }
    }
    const id = oldest_id orelse return error.CacheFull;
    try self.drainAllPending();
    const removed = self.textures.fetchRemove(id).?;
    self.destroyTexture(removed.value);
}

fn reclaimStaleResources(self: *Self) Error!void {
    const oldest = self.frame_number -| stale_frame_count;
    var drained = false;
    while (true) {
        var stale: ?u64 = null;
        var iterator = self.textures.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_used < oldest) {
                stale = entry.key_ptr.*;
                break;
            }
        }
        const id = stale orelse break;
        if (!drained) {
            try self.drainAllPending();
            drained = true;
        }
        self.destroyTexture(self.textures.fetchRemove(id).?.value);
    }
    while (true) {
        var stale: ?u64 = null;
        var iterator = self.calibrations.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_used < oldest) {
                stale = entry.key_ptr.*;
                break;
            }
        }
        const identity = stale orelse break;
        if (!drained) {
            try self.drainAllPending();
            drained = true;
        }
        self.destroyCalibrationTexture(self.calibrations.fetchRemove(identity).?.value);
    }
    while (true) {
        var stale: ?TargetKey = null;
        var iterator = self.outputs.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.kind == .pixels and entry.value_ptr.last_used < oldest) {
                stale = entry.key_ptr.*;
                break;
            }
        }
        const key = stale orelse break;
        if (!drained) {
            try self.drainAllPending();
            drained = true;
        }
        self.destroyOutput(self.outputs.fetchRemove(key).?.value);
    }
}

fn destroyCachedResources(self: *Self) void {
    var output_iterator = self.outputs.valueIterator();
    while (output_iterator.next()) |output| self.destroyOutput(output.*);
    self.outputs.deinit(self.allocator);
    var texture_iterator = self.textures.valueIterator();
    while (texture_iterator.next()) |texture| self.destroyTexture(texture.*);
    self.textures.deinit(self.allocator);
    var calibration_iterator = self.calibrations.valueIterator();
    while (calibration_iterator.next()) |calibration| {
        self.destroyCalibrationTexture(calibration.*);
    }
    self.calibrations.deinit(self.allocator);
    var video_iterator = self.video_graphics.valueIterator();
    while (video_iterator.next()) |graphics| self.destroyVideoGraphics(graphics.*);
    self.video_graphics.deinit(self.allocator);
}

fn invalidatePreparedTextures(self: *Self, prepared_images: []const PreparedImage) void {
    for (prepared_images) |prepared| {
        const cache_id = prepared.cache_id orelse continue;
        if (self.textures.fetchRemove(cache_id)) |removed| {
            self.destroyTexture(removed.value);
        }
    }
    while (true) {
        var uninitialized_id: ?u64 = null;
        var iterator = self.textures.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.initialized) {
                uninitialized_id = entry.key_ptr.*;
                break;
            }
        }
        const cache_id = uninitialized_id orelse break;
        self.destroyTexture(self.textures.fetchRemove(cache_id).?.value);
    }
}

fn deviceMemoryType(self: *Self, memory_type_bits: u32) ?u32 {
    const properties = self.instance_wrapper.getPhysicalDeviceMemoryProperties(self.physical_device);
    var compatible: ?u32 = null;
    for (0..properties.memory_type_count) |index| {
        const index_u5: u5 = @intCast(index);
        if (memory_type_bits & (@as(u32, 1) << index_u5) == 0) continue;
        compatible = @intCast(index);
        if (properties.memory_types[index].property_flags.device_local_bit) return @intCast(index);
    }
    return compatible;
}

fn ensureWorkBuffer(self: *Self, submission: *Submission, required_size: usize) Error!void {
    if (submission.work_capacity >= required_size) return;
    std.debug.assert(!submission.fence_pending);

    const buffer = self.device_wrapper.createBuffer(self.device, &.{
        .size = required_size,
        .usage = .{ .transfer_src_bit = true, .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyBuffer(self.device, buffer, null);

    const requirements = self.device_wrapper.getBufferMemoryRequirements(self.device, buffer);
    const memory_type_index = self.hostMemoryType(requirements.memory_type_bits) orelse
        return error.VulkanFailure;
    const memory = self.device_wrapper.allocateMemory(self.device, &.{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type_index,
    }, null) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        else => return error.VulkanFailure,
    };
    errdefer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindBufferMemory(self.device, buffer, memory, 0) catch
        return error.VulkanFailure;
    const mapped_opaque = self.device_wrapper.mapMemory(
        self.device,
        memory,
        0,
        required_size,
        .{},
    ) catch return error.VulkanFailure;
    const mapped: [*]u8 = @ptrCast(mapped_opaque orelse return error.VulkanFailure);
    errdefer self.device_wrapper.unmapMemory(self.device, memory);

    self.destroyWorkBuffer(submission);
    submission.work_buffer = buffer;
    submission.work_memory = memory;
    submission.work_mapped = mapped;
    submission.work_capacity = required_size;
    self.advanceResourceEpoch();
}

fn destroyWorkBuffer(self: *Self, submission: *Submission) void {
    std.debug.assert(!submission.fence_pending);
    if (submission.work_mapped != null) {
        self.device_wrapper.unmapMemory(self.device, submission.work_memory);
    }
    if (submission.work_buffer != .null_handle) {
        self.device_wrapper.destroyBuffer(self.device, submission.work_buffer, null);
    }
    if (submission.work_memory != .null_handle) {
        self.device_wrapper.freeMemory(self.device, submission.work_memory, null);
    }
    submission.work_buffer = .null_handle;
    submission.work_memory = .null_handle;
    submission.work_mapped = null;
    submission.work_capacity = 0;
}

fn ensureInstanceBuffer(self: *Self, submission: *Submission, required_size: usize) Error!void {
    if (submission.instance_capacity >= required_size) return;
    std.debug.assert(!submission.fence_pending);

    const buffer = self.device_wrapper.createBuffer(self.device, &.{
        .size = required_size,
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyBuffer(self.device, buffer, null);

    const requirements = self.device_wrapper.getBufferMemoryRequirements(self.device, buffer);
    const memory_type_index = self.hostMemoryType(requirements.memory_type_bits) orelse
        return error.VulkanFailure;
    const memory = self.device_wrapper.allocateMemory(self.device, &.{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type_index,
    }, null) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        else => return error.VulkanFailure,
    };
    errdefer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindBufferMemory(self.device, buffer, memory, 0) catch
        return error.VulkanFailure;
    const mapped_opaque = self.device_wrapper.mapMemory(
        self.device,
        memory,
        0,
        required_size,
        .{},
    ) catch return error.VulkanFailure;
    const mapped: [*]u8 = @ptrCast(mapped_opaque orelse return error.VulkanFailure);
    errdefer self.device_wrapper.unmapMemory(self.device, memory);

    self.destroyInstanceBuffer(submission);
    submission.instance_buffer = buffer;
    submission.instance_memory = memory;
    submission.instance_mapped = mapped;
    submission.instance_capacity = required_size;
    self.advanceResourceEpoch();
}

fn destroyInstanceBuffer(self: *Self, submission: *Submission) void {
    std.debug.assert(!submission.fence_pending);
    if (submission.instance_mapped != null) {
        self.device_wrapper.unmapMemory(self.device, submission.instance_memory);
    }
    if (submission.instance_buffer != .null_handle) {
        self.device_wrapper.destroyBuffer(self.device, submission.instance_buffer, null);
    }
    if (submission.instance_memory != .null_handle) {
        self.device_wrapper.freeMemory(self.device, submission.instance_memory, null);
    }
    submission.instance_buffer = .null_handle;
    submission.instance_memory = .null_handle;
    submission.instance_mapped = null;
    submission.instance_capacity = 0;
}

fn hostMemoryType(self: *Self, memory_type_bits: u32) ?u32 {
    const properties = self.instance_wrapper.getPhysicalDeviceMemoryProperties(self.physical_device);
    var coherent: ?u32 = null;
    for (0..properties.memory_type_count) |index| {
        const index_u5: u5 = @intCast(index);
        if (memory_type_bits & (@as(u32, 1) << index_u5) == 0) continue;
        const flags = properties.memory_types[index].property_flags;
        if (!flags.host_visible_bit or !flags.host_coherent_bit) continue;
        if (coherent == null) coherent = @intCast(index);
        if (flags.host_cached_bit) return @intCast(index);
    }
    return coherent;
}

fn advanceResourceEpoch(self: *Self) void {
    self.resource_epoch +%= 1;
    if (self.resource_epoch == 0) self.resource_epoch = 1;
}

fn commandsAffectRect(
    commands: []const render.Command,
    rect: render.Rect,
    frame_size: render.Size,
) bool {
    for (commands) |command| {
        const visible = command_geometry.visibleRect(command, frame_size) orelse continue;
        if (visible.intersection(rect) != null) return true;
    }
    return false;
}

fn imageCanReplace(image: render.Image) bool {
    return image.is_opaque and
        image.alpha_multiplier == std.math.maxInt(u32) and
        image.rounded_clip == null;
}

fn validateCrossfadeSource(source: ?render.SourceRect, size: render.Size) Error!render.SourceRect {
    const rectangle: render.SourceRect = source orelse .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(size.width),
        .height = @floatFromInt(size.height),
    };
    if (!std.math.isFinite(rectangle.x) or !std.math.isFinite(rectangle.y) or
        !std.math.isFinite(rectangle.width) or !std.math.isFinite(rectangle.height) or
        rectangle.width <= 0 or rectangle.height <= 0 or rectangle.x < 0 or rectangle.y < 0 or
        rectangle.x + rectangle.width > @as(f64, @floatFromInt(size.width)) or
        rectangle.y + rectangle.height > @as(f64, @floatFromInt(size.height)))
        return error.InvalidTarget;
    return rectangle;
}

fn compileDrawRuns(
    self: *Self,
    frame: render.Frame,
    prepared_images: []const PreparedImage,
    output_color_description: render.ColorDescription,
) Error!void {
    var prepared_index: usize = 0;
    var captures: std.ArrayList(CompiledBackdropCapture) = .empty;
    defer captures.deinit(self.allocator);
    var base_capture: ?CompiledBackdropCapture = null;
    var pending_backdrop: ?PendingBackdropComposite = null;
    for (frame.commands, 0..) |command, command_index| switch (command) {
        .crossfade => |fade| {
            const old_target = switch (fade.old) {
                .offscreen => |target| target,
                .pixels => return error.InvalidTarget,
            };
            const new_target = switch (fade.new) {
                .offscreen => |target| target,
                .pixels => return error.InvalidTarget,
            };
            const old_output = self.outputs.getPtr(.{ .offscreen = old_target.id }) orelse
                return error.InvalidTarget;
            const new_output = self.outputs.getPtr(.{ .offscreen = new_target.id }) orelse
                return error.InvalidTarget;
            if (!std.meta.eql(old_output.size, old_target.size) or
                !std.meta.eql(new_output.size, new_target.size) or
                !old_output.linear_initialized or !new_output.linear_initialized or
                fade.destination.width == 0 or fade.destination.height == 0)
                return error.InvalidTarget;
            const destination = fade.destination;
            var clipped = destination.clipTo(frame.size) orelse continue;
            if (fade.clip) |clip| clipped = clipped.intersection(clip) orelse continue;
            if (fade.rounded_clip) |rounded_clip| clipped = clipped.intersection(rounded_clip.rect) orelse continue;
            const old_source = try validateCrossfadeSource(fade.old_source, old_target.size);
            const new_source = try validateCrossfadeSource(fade.new_source, new_target.size);
            const rounded = fade.rounded_clip orelse render.RoundedClip{
                .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .radius = 0,
            };
            const radius = @min(rounded.radius, @min(rounded.rect.width, rounded.rect.height) / 2);
            const first_run = self.draw_runs.items.len;
            try self.emitDamaged(frame, clipped, .crossfade, self.crossfade_pipeline, .null_handle, old_output.linear.descriptor_set, old_target.size, .{}, null, null, .{
                .destination = rectFloats(destination),
                .source = .{ @floatCast(old_source.x), @floatCast(old_source.y), @floatCast(old_source.width), @floatCast(old_source.height) },
                .clip = undefined,
                .color = .{ @floatCast(new_source.x), @floatCast(new_source.y), @floatCast(new_source.width), @floatCast(new_source.height) },
                .rounded = rectFloats(rounded.rect),
                .parameters = .{ @floatFromInt(radius), 0, 0, @as(f32, @floatFromInt(fade.factor)) / @as(f32, @floatFromInt(std.math.maxInt(u32))) },
            });
            for (self.draw_runs.items[first_run..]) |*run| {
                std.debug.assert(run.pipeline == .crossfade and run.secondary_descriptor_set == null);
                run.secondary_descriptor_set = new_output.linear.descriptor_set;
            }
        },
        .backdrop_capture => |capture| {
            std.debug.assert(pending_backdrop == null);
            const compiled = try self.compileBackdropCapture(
                frame,
                capture,
                command_index,
                base_capture,
            );
            try captures.append(self.allocator, compiled);
            if (capture.base) {
                if (base_capture != null) return error.InvalidTarget;
                base_capture = compiled;
            }
        },
        .clear => |color| {
            const rect: render.Rect = .{
                .x = 0,
                .y = 0,
                .width = frame.size.width,
                .height = frame.size.height,
            };
            try self.emitDamaged(frame, rect, .replace, .null_handle, .null_handle, null, .{ .width = 1, .height = 1 }, .{}, null, null, .{
                .destination = rectFloats(rect),
                .source = .{ 0, 0, 1, 1 },
                .clip = undefined,
                .color = color_math.linearColor(color, output_color_description),
                .rounded = .{ 0, 0, 0, 0 },
                .parameters = .{ 0, 0, 0, 0 },
            });
        },
        .solid_rect => |solid| {
            var clipped = solid.rect.clipTo(frame.size) orelse continue;
            if (solid.clip) |clip| clipped = clipped.intersection(clip) orelse continue;
            const pipeline: PipelineKind = if (solid.color.alpha == std.math.maxInt(u8))
                .replace
            else
                .blend;
            try self.emitDamaged(frame, clipped, pipeline, .null_handle, .null_handle, null, .{ .width = 1, .height = 1 }, .{}, null, null, .{
                .destination = rectFloats(clipped),
                .source = .{ 0, 0, 1, 1 },
                .clip = undefined,
                .color = color_math.linearColor(solid.color, output_color_description),
                .rounded = .{ 0, 0, 0, 0 },
                .parameters = .{ 0, 0, 0, 0 },
            });
        },
        .image => |image| {
            const backdrop = pending_backdrop;
            pending_backdrop = null;
            const prepared = prepared_images[prepared_index];
            prepared_index += 1;
            const destination: render.Rect = .{
                .x = image.x,
                .y = image.y,
                .width = image.size.width,
                .height = image.size.height,
            };
            var clipped = destination.clipTo(frame.size) orelse continue;
            if (image.clip) |clip| clipped = clipped.intersection(clip) orelse continue;
            if (image.rounded_clip) |rounded_clip| {
                clipped = clipped.intersection(rounded_clip.rect) orelse continue;
            }
            const transformed_size = image.transform.applyToSize(image.buffer.size);
            const source = image.source orelse render.SourceRect{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(transformed_size.width),
                .height = @floatFromInt(transformed_size.height),
            };
            const rounded = image.rounded_clip orelse render.RoundedClip{
                .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .radius = 0,
            };
            const radius = @min(rounded.radius, @min(rounded.rect.width, rounded.rect.height) / 2);
            const dmabuf = image.buffer.dmabuf;
            const replace = imageCanReplace(image);
            const image_pipeline = if (backdrop != null)
                self.backdrop_image_pipeline
            else if (prepared.texture.pipeline != .null_handle)
                prepared.texture.pipeline
            else switch (image.samplingFilter()) {
                .nearest => if (image.buffer.color_description.transfer_function == .gamma22)
                    if (replace)
                        self.opaque_nearest_gamma22_image_pipeline
                    else
                        self.nearest_gamma22_image_pipeline
                else if (replace)
                    self.opaque_nearest_image_pipeline
                else
                    self.nearest_image_pipeline,
                .linear => if (replace) self.opaque_image_pipeline else self.image_pipeline,
                .reconstruction => if (replace)
                    self.opaque_reconstruction_image_pipeline
                else
                    self.reconstruction_image_pipeline,
                .area => if (replace) self.opaque_area_image_pipeline else self.area_image_pipeline,
            };
            try self.emitDamaged(
                frame,
                clipped,
                if (backdrop != null) .backdrop_image else .image,
                image_pipeline,
                prepared.texture.pipeline_layout,
                prepared.texture.descriptor_set,
                image.buffer.size,
                color_math.sourceTransform(
                    image.buffer.color_description,
                    output_color_description,
                ),
                if (backdrop != null) null else prepared.texture.manual_ycbcr,
                if (backdrop) |pending| pending.capture.op_index else null,
                .{
                    .destination = rectFloats(destination),
                    .source = .{
                        @floatCast(source.x),
                        @floatCast(source.y),
                        @floatCast(source.width),
                        @floatCast(source.height),
                    },
                    .clip = undefined,
                    .color = .{ 1, 1, 1, 1 },
                    .rounded = rectFloats(rounded.rect),
                    .parameters = .{
                        @floatFromInt(radius),
                        @floatFromInt(@intFromEnum(image.transform)),
                        @floatFromInt(@intFromBool(dmabuf != null and dmabuf.?.y_inverted)),
                        @as(f32, @floatFromInt(image.alpha_multiplier)) / @as(f32, @floatFromInt(std.math.maxInt(u32))),
                    },
                },
            );
        },
        .shadow => |shadow| {
            if (shadow.color.alpha == 0 or shadow.rect.width == 0 or shadow.rect.height == 0) {
                continue;
            }
            const spread: i64 = shadow.spread;
            const shape_x = @as(i64, shadow.rect.x) - spread;
            const shape_y = @as(i64, shadow.rect.y) - spread;
            const shape_width = @as(i64, shadow.rect.width) + 2 * spread;
            const shape_height = @as(i64, shadow.rect.height) + 2 * spread;
            if (shape_width <= 0 or shape_height <= 0) continue;

            const blur_extent: i64 = render.shadowBlurExtent(shadow.blur_radius);
            const left = @max(shape_x - blur_extent, 0);
            const top = @max(shape_y - blur_extent, 0);
            const right = @min(shape_x + shape_width + blur_extent, frame.size.width);
            const bottom = @min(shape_y + shape_height + blur_extent, frame.size.height);
            if (left >= right or top >= bottom) continue;
            var clipped: render.Rect = .{
                .x = @intCast(left),
                .y = @intCast(top),
                .width = @intCast(right - left),
                .height = @intCast(bottom - top),
            };
            if (shadow.clip) |clip| clipped = clipped.intersection(clip) orelse continue;

            const requested_radius = @max(@as(i64, shadow.corner_radius) + spread, 0);
            const radius = @min(requested_radius, @divTrunc(@min(shape_width, shape_height), 2));
            const cutout = shadow.cutout orelse render.RoundedClip{
                .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .radius = 0,
            };
            const cutout_radius = @min(
                cutout.radius,
                @min(cutout.rect.width, cutout.rect.height) / 2,
            );
            const instance: Instance = .{
                .destination = rectFloats(cutout.rect),
                .source = .{ 0, 0, 1, 1 },
                .clip = undefined,
                .color = color_math.linearColor(shadow.color, output_color_description),
                .rounded = .{
                    @floatFromInt(shape_x),
                    @floatFromInt(shape_y),
                    @floatFromInt(shape_width),
                    @floatFromInt(shape_height),
                },
                .parameters = .{
                    @floatFromInt(radius),
                    @floatFromInt(shadow.blur_radius),
                    @floatFromInt(cutout_radius),
                    @floatFromInt(@intFromBool(shadow.cutout != null)),
                },
            };
            var raster_rects: [4]?render.Rect = @splat(null);
            if (shadow.cutout) |_| {
                if (opaqueRoundedRectInterior(cutout.rect, cutout_radius)) |interior| {
                    raster_rects = rectDifferenceStrips(clipped, interior);
                } else {
                    raster_rects[0] = clipped;
                }
            } else {
                raster_rects[0] = clipped;
            }
            for (raster_rects) |raster_rect| {
                try self.emitDamaged(frame, raster_rect orelse continue, .shadow, .null_handle, .null_handle, null, .{ .width = 1, .height = 1 }, .{}, null, null, instance);
            }
        },
        .backdrop_blur => |blur| {
            if (blur.radius == 0 or blur.rect.width == 0 or blur.rect.height == 0) continue;
            var clipped = blur.rect.clipTo(frame.size) orelse continue;
            if (blur.clip) |clip| clipped = clipped.intersection(clip) orelse continue;
            const capture = compiledBackdropCapture(captures.items, blur.capture_id) orelse
                return error.InvalidTarget;
            const level = blur_geometry.configuredLevel(blur.radius, blur.downsample_level);
            const sample_radius = blur_geometry.footprint(blur.radius, blur.downsample_level);
            const sample_rect = blur_geometry.sampleRect(clipped, sample_radius, level, frame.size);
            if (capture.radius != blur.radius or
                capture.downsample_level != blur.downsample_level or
                !std.meta.eql(capture.finish, blur.finish) or
                capture.level != level or
                !rectContains(capture.sample_rect, sample_rect)) return error.InvalidTarget;
            self.markBackdropCaptureUsed(capture.op_index);
            _ = damageBounds(frame.damage, clipped) orelse continue;
            if (command_index + 1 < frame.commands.len) {
                const next_image = switch (frame.commands[command_index + 1]) {
                    .image => |image| image,
                    else => null,
                };
                if (next_image) |image| {
                    const prepared = prepared_images[prepared_index];
                    if (prepared.texture.pipeline == .null_handle and
                        prepared.texture.manual_ycbcr == null and
                        canFuseBackdropImage(blur, image))
                    {
                        pending_backdrop = .{ .capture = capture };
                        continue;
                    }
                }
            }
            const radius = @min(blur.corner_radius, @min(blur.rect.width, blur.rect.height) / 2);
            const blur_rect = rectFloats(blur.rect);
            const composite: Instance = .{
                .destination = blur_rect,
                .source = blur_rect,
                .clip = undefined,
                .color = .{ 1, 1, 1, 1 },
                .rounded = blur_rect,
                .parameters = .{ @floatFromInt(radius), 0, 0, 1 },
            };
            const composite_instance: u32 = @intCast(self.instances.items.len);
            var composite_count: u32 = 0;
            if (frame.damage) |damage| {
                for (damage) |damaged| {
                    const damaged_clip = damaged.clipTo(frame.size) orelse continue;
                    const composite_clip = clipped.intersection(damaged_clip) orelse continue;
                    var instance = composite;
                    instance.clip = rectFloats(composite_clip);
                    try self.instances.append(self.allocator, instance);
                    composite_count = std.math.add(u32, composite_count, 1) catch
                        return error.InvalidTarget;
                }
            } else {
                var instance = composite;
                instance.clip = rectFloats(clipped);
                try self.instances.append(self.allocator, instance);
                composite_count = 1;
            }
            std.debug.assert(composite_count > 0);
            try self.draw_runs.append(self.allocator, .{
                .pipeline = .blur_composite,
                .descriptor_set = null,
                .texture_size = frame.size,
                .first_instance = composite_instance,
                .instance_count = composite_count,
                .backdrop_op_index = capture.op_index,
            });
        },
    };
    std.debug.assert(pending_backdrop == null);
    std.debug.assert(prepared_index == prepared_images.len);
}

fn compiledBackdropCapture(
    captures: []const CompiledBackdropCapture,
    id: u32,
) ?CompiledBackdropCapture {
    var index = captures.len;
    while (index > 0) {
        index -= 1;
        if (captures[index].id == id) return captures[index];
    }
    return null;
}

fn markBackdropCaptureUsed(self: *Self, op_index: u32) void {
    var current: ?u32 = op_index;
    while (current) |index| {
        const op = &self.blur_ops.items[index];
        if (op.used) return;
        op.used = true;
        current = op.reuse_op_index;
    }
}

fn canFuseBackdropImage(blur: render.BackdropBlur, image: render.Image) bool {
    if (image.buffer.dmabuf != null or image.samplingFilter() != .nearest) return false;
    const destination: render.Rect = .{
        .x = image.x,
        .y = image.y,
        .width = image.size.width,
        .height = image.size.height,
    };
    if (!std.meta.eql(destination, blur.rect) or !std.meta.eql(image.clip, blur.clip)) {
        return false;
    }
    if (image.rounded_clip) |rounded| {
        return std.meta.eql(rounded.rect, destination) and rounded.radius == blur.corner_radius;
    }
    return blur.corner_radius == 0;
}

fn compileBackdropCapture(
    self: *Self,
    frame: render.Frame,
    capture: render.BackdropCapture,
    command_index: usize,
    base_capture: ?CompiledBackdropCapture,
) Error!CompiledBackdropCapture {
    if (capture.radius == 0 or capture.rect.width == 0 or capture.rect.height == 0) {
        return error.InvalidTarget;
    }
    const clipped = capture.rect.clipTo(frame.size) orelse return error.InvalidTarget;
    const level = blur_geometry.configuredLevel(capture.radius, capture.downsample_level);
    const sample_radius = blur_geometry.footprint(capture.radius, capture.downsample_level);
    const sample_rect = blur_geometry.sampleRect(clipped, sample_radius, level, frame.size);
    const own_cache_key = backdrop_cache_key.key(frame.commands[0 .. command_index + 1]);
    const geometry_key = backdrop_cache_key.geometryKey(capture);
    const reuse_op_index = if (!capture.base) reuse: {
        const base = base_capture orelse break :reuse null;
        if (base.radius != capture.radius or
            base.downsample_level != capture.downsample_level or
            !std.meta.eql(base.finish, capture.finish) or
            !rectContains(base.sample_rect, sample_rect) or
            commandsAffectRect(
                frame.commands[base.command_index + 1 .. command_index],
                sample_rect,
                frame.size,
            )) break :reuse null;
        break :reuse base.op_index;
    } else null;
    const cache_key = if (reuse_op_index != null) base_capture.?.key else own_cache_key;

    var level_rects: [blur_level_count]render.Rect = undefined;
    for (&level_rects, 0..) |*rect, index| {
        rect.* = blur_geometry.scaledRect(sample_rect, @intCast(index));
    }
    const kawase_offset = blur_geometry.sampleOffset(capture.radius, level);
    const source_expansion = blur_geometry.sourceExpansion(capture.radius, level);
    var upsample_rects: [blur_level_count]render.Rect = @splat(.{ .x = 0, .y = 0, .width = 0, .height = 0 });
    upsample_rects[0] = clipped;
    for (1..@as(usize, level) + 1) |index| {
        upsample_rects[index] = blur_geometry.expandWithin(
            blur_geometry.scaledRect(upsample_rects[index - 1], 1),
            source_expansion,
            level_rects[index],
        );
    }
    var downsample_instances: [blur_level_count]u32 = @splat(0);
    if (level == 0) {
        downsample_instances[0] = @intCast(self.instances.items.len);
        try self.instances.append(self.allocator, kawaseDownsampleInstance(
            level_rects[0],
            level_rects[0],
            kawase_offset,
        ));
    } else for (0..level) |index| {
        const destination_index = index + 1;
        downsample_instances[destination_index] = @intCast(self.instances.items.len);
        try self.instances.append(self.allocator, kawaseDownsampleInstance(
            level_rects[destination_index],
            level_rects[index],
            kawase_offset,
        ));
    }
    var upsample_instances: [blur_level_count]u32 = @splat(0);
    const upsample_passes: usize = @max(level, 1);
    for (0..upsample_passes) |index| {
        upsample_instances[index] = @intCast(self.instances.items.len);
        try self.instances.append(self.allocator, kawaseUpsampleInstance(
            upsample_rects[index],
            kawase_offset,
            level == 0,
            if (index == 0) capture.finish else null,
        ));
    }

    const op_index: u32 = @intCast(self.blur_ops.items.len);
    try self.blur_ops.append(self.allocator, .{
        .run_index = @intCast(self.draw_runs.items.len),
        .cache_key = cache_key,
        .geometry_key = geometry_key,
        .base_capture = capture.base,
        .reuse_op_index = reuse_op_index,
        .level = level,
        .downsample_instances = downsample_instances,
        .upsample_instances = upsample_instances,
        .sample_rect = sample_rect,
        .level_rects = level_rects,
        .upsample_rects = upsample_rects,
    });
    try self.draw_runs.append(self.allocator, .{
        .pipeline = .blur_composite,
        .descriptor_set = null,
        .texture_size = frame.size,
        .first_instance = @intCast(self.instances.items.len),
        .instance_count = 0,
        .backdrop_op_index = op_index,
    });
    return .{
        .id = capture.id,
        .command_index = command_index,
        .op_index = op_index,
        .radius = capture.radius,
        .downsample_level = capture.downsample_level,
        .finish = capture.finish,
        .key = cache_key,
        .level = level,
        .sample_rect = sample_rect,
    };
}

fn rectContains(outer: render.Rect, inner: render.Rect) bool {
    return @as(i64, inner.x) >= outer.x and
        @as(i64, inner.y) >= outer.y and
        @as(i64, inner.x) + inner.width <= @as(i64, outer.x) + outer.width and
        @as(i64, inner.y) + inner.height <= @as(i64, outer.y) + outer.height;
}

fn opaqueRoundedRectInterior(rect: render.Rect, radius: u32) ?render.Rect {
    std.debug.assert(radius <= @min(rect.width, rect.height) / 2);
    const inset = radius * 2;
    if (rect.width <= inset or rect.height <= inset) return null;
    return .{
        .x = @intCast(@as(i64, rect.x) + radius),
        .y = @intCast(@as(i64, rect.y) + radius),
        .width = rect.width - inset,
        .height = rect.height - inset,
    };
}

fn rectDifferenceStrips(outer: render.Rect, removed: render.Rect) [4]?render.Rect {
    var result: [4]?render.Rect = @splat(null);
    const interior = outer.intersection(removed) orelse {
        result[0] = outer;
        return result;
    };
    const outer_right = @as(i64, outer.x) + outer.width;
    const outer_bottom = @as(i64, outer.y) + outer.height;
    const interior_right = @as(i64, interior.x) + interior.width;
    const interior_bottom = @as(i64, interior.y) + interior.height;
    if (interior.y > outer.y) result[0] = .{
        .x = outer.x,
        .y = outer.y,
        .width = outer.width,
        .height = @intCast(@as(i64, interior.y) - outer.y),
    };
    if (interior_bottom < outer_bottom) result[1] = .{
        .x = outer.x,
        .y = @intCast(interior_bottom),
        .width = outer.width,
        .height = @intCast(outer_bottom - interior_bottom),
    };
    if (interior.x > outer.x) result[2] = .{
        .x = outer.x,
        .y = interior.y,
        .width = @intCast(@as(i64, interior.x) - outer.x),
        .height = interior.height,
    };
    if (interior_right < outer_right) result[3] = .{
        .x = @intCast(interior_right),
        .y = interior.y,
        .width = @intCast(outer_right - interior_right),
        .height = interior.height,
    };
    return result;
}

fn emitDamaged(
    self: *Self,
    frame: render.Frame,
    visible_rect: render.Rect,
    pipeline_kind: PipelineKind,
    pipeline_handle: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    descriptor_set: ?vk.DescriptorSet,
    texture_size: render.Size,
    color_transform: color_math.ColorTransform,
    manual_ycbcr: ?ManualYcbcr,
    backdrop_op_index: ?u32,
    instance: Instance,
) Error!void {
    if (frame.damage) |damage| {
        for (damage) |damaged| {
            const clipped_damage = damaged.clipTo(frame.size) orelse continue;
            const clipped = visible_rect.intersection(clipped_damage) orelse continue;
            try self.emitInstance(
                pipeline_kind,
                pipeline_handle,
                pipeline_layout,
                descriptor_set,
                texture_size,
                color_transform,
                manual_ycbcr,
                backdrop_op_index,
                instance,
                clipped,
            );
        }
    } else {
        try self.emitInstance(
            pipeline_kind,
            pipeline_handle,
            pipeline_layout,
            descriptor_set,
            texture_size,
            color_transform,
            manual_ycbcr,
            backdrop_op_index,
            instance,
            visible_rect,
        );
    }
}

fn damageBounds(damage: ?[]const render.Rect, visible: render.Rect) ?render.Rect {
    const rectangles = damage orelse return visible;
    var bounds: ?render.Rect = null;
    for (rectangles) |rectangle| {
        const clipped = visible.intersection(rectangle) orelse continue;
        bounds = if (bounds) |current| unionRect(current, clipped) else clipped;
    }
    return bounds;
}

fn unionRect(a: render.Rect, b: render.Rect) render.Rect {
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(@as(i64, a.x) + a.width, @as(i64, b.x) + b.width);
    const bottom = @max(@as(i64, a.y) + a.height, @as(i64, b.y) + b.height);
    return .{ .x = left, .y = top, .width = @intCast(right - left), .height = @intCast(bottom - top) };
}

test "Vulkan blur bounds only cover damaged visible pixels" {
    const visible: render.Rect = .{ .x = 10, .y = 10, .width = 100, .height = 80 };
    try std.testing.expectEqual(visible, damageBounds(null, visible).?);
    try std.testing.expectEqual(
        render.Rect{ .x = 12, .y = 15, .width = 88, .height = 55 },
        damageBounds(&.{
            .{ .x = 12, .y = 15, .width = 8, .height = 5 },
            .{ .x = 90, .y = 60, .width = 10, .height = 10 },
        }, visible).?,
    );
    try std.testing.expectEqual(null, damageBounds(&.{.{ .x = 0, .y = 0, .width = 5, .height = 5 }}, visible));
}

test "Vulkan shadow raster strips exclude only the opaque cutout interior" {
    try std.testing.expectEqual(
        render.Rect{ .x = 22, .y = 32, .width = 76, .height = 56 },
        opaqueRoundedRectInterior(.{ .x = 10, .y = 20, .width = 100, .height = 80 }, 12).?,
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 10, .y = 20, .width = 100, .height = 80 },
        opaqueRoundedRectInterior(.{ .x = 10, .y = 20, .width = 100, .height = 80 }, 0).?,
    );
    try std.testing.expectEqual(
        @as(?render.Rect, null),
        opaqueRoundedRectInterior(.{ .x = 10, .y = 20, .width = 24, .height = 24 }, 12),
    );

    try std.testing.expectEqualSlices(
        ?render.Rect,
        &.{
            .{ .x = 10, .y = 20, .width = 100, .height = 15 },
            .{ .x = 10, .y = 65, .width = 100, .height = 35 },
            .{ .x = 10, .y = 35, .width = 20, .height = 30 },
            .{ .x = 70, .y = 35, .width = 40, .height = 30 },
        },
        &rectDifferenceStrips(
            .{ .x = 10, .y = 20, .width = 100, .height = 80 },
            .{ .x = 30, .y = 35, .width = 40, .height = 30 },
        ),
    );
    try std.testing.expectEqualSlices(
        ?render.Rect,
        &.{ .{ .x = 10, .y = 20, .width = 100, .height = 80 }, null, null, null },
        &rectDifferenceStrips(
            .{ .x = 10, .y = 20, .width = 100, .height = 80 },
            .{ .x = -20, .y = -20, .width = 10, .height = 10 },
        ),
    );
}

fn emitInstance(
    self: *Self,
    pipeline_kind: PipelineKind,
    pipeline_handle: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    descriptor_set: ?vk.DescriptorSet,
    texture_size: render.Size,
    color_transform: color_math.ColorTransform,
    manual_ycbcr: ?ManualYcbcr,
    backdrop_op_index: ?u32,
    template: Instance,
    clip: render.Rect,
) Error!void {
    if (self.instances.items.len >= std.math.maxInt(u32)) return error.InvalidTarget;
    const instance_index: u32 = @intCast(self.instances.items.len);
    var instance = template;
    instance.clip = rectFloats(clip);
    try self.instances.append(self.allocator, instance);

    if (self.draw_runs.items.len > 0) {
        const last = &self.draw_runs.items[self.draw_runs.items.len - 1];
        if (last.pipeline == pipeline_kind and
            last.secondary_descriptor_set == null and
            last.pipeline_handle == pipeline_handle and
            last.pipeline_layout == pipeline_layout and
            last.descriptor_set == descriptor_set and
            last.backdrop_op_index == backdrop_op_index and
            std.meta.eql(last.texture_size, texture_size) and
            std.meta.eql(last.color_transform, color_transform) and
            std.meta.eql(last.manual_ycbcr, manual_ycbcr))
        {
            last.instance_count = std.math.add(u32, last.instance_count, 1) catch
                return error.InvalidTarget;
            return;
        }
    }
    try self.draw_runs.append(self.allocator, .{
        .pipeline = pipeline_kind,
        .pipeline_handle = pipeline_handle,
        .pipeline_layout = pipeline_layout,
        .descriptor_set = descriptor_set,
        .texture_size = texture_size,
        .first_instance = instance_index,
        .instance_count = 1,
        .color_transform = color_transform,
        .manual_ycbcr = manual_ycbcr,
        .backdrop_op_index = backdrop_op_index,
    });
}

fn pipelineForKind(self: *const Self, kind: PipelineKind) vk.Pipeline {
    return switch (kind) {
        .replace => self.replace_pipeline,
        .blend => self.blend_pipeline,
        .image => self.image_pipeline,
        .crossfade => self.crossfade_pipeline,
        .backdrop_image => self.backdrop_image_pipeline,
        .shadow => self.shadow_pipeline,
        .downsample => self.downsample_pipeline,
        .blur_downsample => self.blur_downsample_pipeline,
        .blur_upsample => self.blur_upsample_pipeline,
        .blur_composite => self.blur_composite_pipeline,
    };
}

fn gpuTimingCategory(kind: PipelineKind) GpuTimingCategory {
    return switch (kind) {
        .replace, .blend => .solid_composition,
        .image, .crossfade, .backdrop_image, .downsample => .image_composition,
        .shadow => .shadow,
        .blur_downsample => .blur_downsample,
        .blur_upsample => .blur_upsample,
        .blur_composite => .blur_composite,
    };
}

fn imageInstance(destination: render.Rect, source: render.Rect) Instance {
    return .{ .destination = rectFloats(destination), .source = rectFloats(source), .clip = rectFloats(destination), .color = .{ 1, 1, 1, 1 }, .rounded = .{ 0, 0, 0, 0 }, .parameters = .{ 0, 0, 0, 1 } };
}

fn kawaseDownsampleInstance(destination: render.Rect, source: render.Rect, offset: f32) Instance {
    return .{
        .destination = rectFloats(destination),
        .source = rectFloats(source),
        .clip = rectFloats(destination),
        .color = .{ 1, 1, 1, 1 },
        .rounded = .{ 0, 0, 0, 0 },
        .parameters = .{ offset, 0, 0, 1 },
    };
}

fn kawaseUpsampleInstance(
    destination: render.Rect,
    offset: f32,
    same_size: bool,
    finish: ?render.BackdropBlurFinish,
) Instance {
    const destination_floats = rectFloats(destination);
    const divisor: f32 = if (same_size) 1 else 2;
    const finish_parameters = finish orelse render.BackdropBlurFinish{};
    return .{
        .destination = destination_floats,
        .source = .{ destination_floats[0] / divisor, destination_floats[1] / divisor, destination_floats[2] / divisor, destination_floats[3] / divisor },
        .clip = destination_floats,
        .color = .{
            finish_parameters.brightness,
            @floatFromInt(@intFromBool(finish != null and !finish_parameters.isNeutral())),
            0,
            0,
        },
        .rounded = .{ 0, 0, 0, 0 },
        .parameters = .{
            offset,
            finish_parameters.contrast,
            finish_parameters.saturation,
            finish_parameters.noise,
        },
    };
}

fn buildGpuTimingPlan(draw_runs: []const DrawRun, blur_ops: []const BlurOp) GpuTimingPlan {
    var plan: GpuTimingPlan = .{};
    plan.append(.composition_overhead);
    for (draw_runs, 0..) |run, run_index| {
        if (blurOpAtSlice(blur_ops, run_index)) |blur_op| {
            if (!blur_op.used) continue;
            if (!blur_op.cache_hit) {
                plan.append(.blur_downsample);
                plan.append(.blur_upsample);
            }
        }
        plan.append(gpuTimingCategory(run.pipeline));
    }
    plan.append(.composition_overhead);
    return plan;
}

fn blurOpAtSlice(blur_ops: []const BlurOp, run_index: usize) ?BlurOp {
    for (blur_ops) |op| if (op.run_index == run_index) return op;
    return null;
}

fn blurOpAt(self: *const Self, run_index: usize) ?BlurOp {
    return blurOpAtSlice(self.blur_ops.items, run_index);
}

fn drawScratchPass(self: *Self, command_buffer: vk.CommandBuffer, framebuffer: vk.Framebuffer, size: render.Size, area: render.Rect, kind: PipelineKind, descriptor: vk.DescriptorSet, texture_size: render.Size, instance: u32) void {
    const pass_info: vk.RenderPassBeginInfo = .{ .render_pass = self.scratch_render_pass, .framebuffer = framebuffer, .render_area = rect2D(area) };
    self.device_wrapper.cmdBeginRenderPass(command_buffer, &pass_info, .@"inline");
    self.setViewportAndScissor(command_buffer, size);
    self.device_wrapper.cmdBindPipeline(command_buffer, .graphics, self.pipelineForKind(kind));
    self.device_wrapper.cmdBindDescriptorSets(command_buffer, .graphics, self.pipeline_layout, 0, &.{descriptor}, null);
    const push: FramePush = .{ .target_size = sizeFloats(size), .texture_size = sizeFloats(texture_size), .swap_red_blue = 0 };
    self.device_wrapper.cmdPushConstants(command_buffer, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(FramePush), &push);
    self.device_wrapper.cmdDraw(command_buffer, 4, 1, 0, instance);
    self.device_wrapper.cmdEndRenderPass(command_buffer);
}

fn setViewportAndScissor(self: *Self, command_buffer: vk.CommandBuffer, size: render.Size) void {
    self.device_wrapper.cmdSetViewport(command_buffer, 0, &.{.{ .x = 0, .y = 0, .width = @floatFromInt(size.width), .height = @floatFromInt(size.height), .min_depth = 0, .max_depth = 1 }});
    self.device_wrapper.cmdSetScissor(command_buffer, 0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = size.width, .height = size.height } }});
}

fn transitionScratchForWrite(self: *Self, command_buffer: vk.CommandBuffer, image: vk.Image, initialized: bool, new_layout: vk.ImageLayout, destination_access: vk.AccessFlags, destination_stage: vk.PipelineStageFlags) void {
    self.transitionImage(command_buffer, image, if (initialized) .shader_read_only_optimal else .undefined, new_layout, if (initialized) .{ .shader_read_bit = true } else .{}, destination_access, if (initialized) .{ .fragment_shader_bit = true } else .{ .top_of_pipe_bit = true }, destination_stage);
}

fn transitionScratchToRead(self: *Self, command_buffer: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, source_access: vk.AccessFlags, source_stage: vk.PipelineStageFlags) void {
    self.transitionImage(command_buffer, image, old_layout, .shader_read_only_optimal, source_access, .{ .shader_read_bit = true }, source_stage, .{ .fragment_shader_bit = true });
}

fn copyOutputDamage(
    self: *Self,
    work_buffer: vk.Buffer,
    command_buffer: vk.CommandBuffer,
    frame: render.Frame,
    target: render.PixelBuffer,
    image: vk.Image,
) void {
    if (frame.damage) |damage| {
        for (damage) |rect| {
            const clipped = rect.clipTo(frame.size) orelse continue;
            self.copyOutputRect(work_buffer, command_buffer, target, image, clipped);
        }
    } else {
        self.copyOutputRect(work_buffer, command_buffer, target, image, .{
            .x = 0,
            .y = 0,
            .width = frame.size.width,
            .height = frame.size.height,
        });
    }
}

fn copyOutputRect(
    self: *Self,
    work_buffer: vk.Buffer,
    command_buffer: vk.CommandBuffer,
    target: render.PixelBuffer,
    image: vk.Image,
    rect: render.Rect,
) void {
    std.debug.assert(rect.x >= 0 and rect.y >= 0);
    const pixel_offset = @as(u64, @intCast(rect.y)) * target.stride_pixels +
        @as(u32, @intCast(rect.x));
    const copy: vk.BufferImageCopy = .{
        .buffer_offset = pixel_offset * @sizeOf(u32),
        .buffer_row_length = target.stride_pixels,
        .buffer_image_height = target.size.height,
        .image_subresource = colorSubresourceLayers(),
        .image_offset = .{ .x = rect.x, .y = rect.y, .z = 0 },
        .image_extent = extent(.{ .width = rect.width, .height = rect.height }),
    };
    self.device_wrapper.cmdCopyImageToBuffer(
        command_buffer,
        image,
        .transfer_src_optimal,
        work_buffer,
        &.{copy},
    );
}

fn copyTextureRect(
    self: *Self,
    work_buffer: vk.Buffer,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
    buffer: render.PixelBuffer,
    base_offset: usize,
    rect: render.Rect,
) void {
    std.debug.assert(rect.x >= 0 and rect.y >= 0);
    const pixel_offset = @as(u64, @intCast(rect.y)) * buffer.stride_pixels +
        @as(u32, @intCast(rect.x));
    const upload: vk.BufferImageCopy = .{
        .buffer_offset = base_offset + pixel_offset * @sizeOf(u32),
        .buffer_row_length = buffer.stride_pixels,
        .buffer_image_height = buffer.size.height,
        .image_subresource = colorSubresourceLayers(),
        .image_offset = .{ .x = rect.x, .y = rect.y, .z = 0 },
        .image_extent = extent(.{ .width = rect.width, .height = rect.height }),
    };
    self.device_wrapper.cmdCopyBufferToImage(
        command_buffer,
        work_buffer,
        image,
        .transfer_dst_optimal,
        &.{upload},
    );
}

fn copySourceToMapped(
    mapped: [*]u8,
    base_offset: usize,
    buffer: render.PixelBuffer,
    damage: ?[]const render.Rect,
) Error!void {
    const dmabuf = buffer.dmabuf orelse {
        copyPixelsToMapped(mapped, base_offset, buffer, damage);
        return;
    };
    if (dmabuf.plane_count != 1) return error.InvalidTarget;
    const plane = dmabuf.planes[0];
    const mapping = std.posix.mmap(
        null,
        plane.required_bytes,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        plane.fd,
        0,
    ) catch return error.VulkanFailure;
    defer std.posix.munmap(mapping);
    if (!(dmabuf.begin_cpu_read)(dmabuf.context)) return error.VulkanFailure;
    defer _ = (dmabuf.end_cpu_read)(dmabuf.context);

    if (damage) |rectangles| {
        for (rectangles) |rect| copyDmabufRectToMapped(
            mapped,
            base_offset,
            buffer,
            dmabuf,
            mapping,
            rect,
        );
        return;
    }
    copyDmabufRectToMapped(mapped, base_offset, buffer, dmabuf, mapping, .{
        .x = 0,
        .y = 0,
        .width = buffer.size.width,
        .height = buffer.size.height,
    });
}

fn copyDmabufRectToMapped(
    mapped: [*]u8,
    base_offset: usize,
    buffer: render.PixelBuffer,
    dmabuf: render.DmabufSource,
    mapping: []align(std.heap.page_size_min) const u8,
    rect: render.Rect,
) void {
    std.debug.assert(rect.x >= 0 and rect.y >= 0);
    const x_bytes = @as(usize, @intCast(rect.x)) * @sizeOf(u32);
    const copy_bytes = @as(usize, rect.width) * @sizeOf(u32);
    const stride_bytes = @as(usize, buffer.stride_pixels) * @sizeOf(u32);
    const format = render.DmabufFormat.fromFourcc(dmabuf.format);
    for (0..rect.height) |row| {
        const row_offset = (@as(usize, @intCast(rect.y)) + row) * stride_bytes + x_bytes;
        @memcpy(
            mapped[base_offset + row_offset ..][0..copy_bytes],
            mapping[@as(usize, dmabuf.planes[0].offset) + row_offset ..][0..copy_bytes],
        );
        if ((format != null and format.?.redBlueSwapped()) or dmabuf.force_opaque) {
            const row_pixels: [*]u32 = @ptrCast(@alignCast(
                mapped + base_offset + row_offset,
            ));
            for (row_pixels[0..rect.width]) |*pixel| {
                if (format) |source_format| {
                    pixel.* = source_format.toArgb8888(pixel.*);
                }
                if (dmabuf.force_opaque) pixel.* |= 0xff00_0000;
            }
        }
    }
}

fn copyPixelsToMapped(
    mapped: [*]u8,
    base_offset: usize,
    buffer: render.PixelBuffer,
    damage: ?[]const render.Rect,
) void {
    const pixels = std.mem.sliceAsBytes(buffer.pixels);
    const row_bytes = @as(usize, buffer.size.width) * @sizeOf(u32);
    const stride_bytes = @as(usize, buffer.stride_pixels) * @sizeOf(u32);
    if (damage) |rectangles| {
        for (rectangles) |rect| {
            const x_bytes = @as(usize, @intCast(rect.x)) * @sizeOf(u32);
            const damaged_row_bytes = @as(usize, rect.width) * @sizeOf(u32);
            for (0..rect.height) |row| {
                const offset = (@as(usize, @intCast(rect.y)) + row) * stride_bytes + x_bytes;
                @memcpy(
                    mapped[base_offset + offset ..][0..damaged_row_bytes],
                    pixels[offset..][0..damaged_row_bytes],
                );
            }
        }
        return;
    }
    for (0..buffer.size.height) |row| {
        const offset = row * stride_bytes;
        @memcpy(mapped[base_offset + offset ..][0..row_bytes], pixels[offset..][0..row_bytes]);
    }
}

fn copyDamageToTarget(frame: render.Frame, target: render.PixelBuffer, mapped: [*]const u8) void {
    if (frame.damage) |damage| {
        for (damage) |rect| {
            const clipped = rect.clipTo(frame.size) orelse continue;
            copyMappedRect(target, mapped, clipped);
        }
    } else {
        copyMappedRect(target, mapped, .{
            .x = 0,
            .y = 0,
            .width = frame.size.width,
            .height = frame.size.height,
        });
    }
}

fn copyMappedRect(target: render.PixelBuffer, mapped: [*]const u8, rect: render.Rect) void {
    std.debug.assert(rect.x >= 0 and rect.y >= 0);
    const pixels = std.mem.sliceAsBytes(target.pixels);
    const row_bytes = @as(usize, rect.width) * @sizeOf(u32);
    const stride_bytes = @as(usize, target.stride_pixels) * @sizeOf(u32);
    const x_bytes = @as(usize, @intCast(rect.x)) * @sizeOf(u32);
    for (0..rect.height) |row| {
        const offset = (@as(usize, @intCast(rect.y)) + row) * stride_bytes + x_bytes;
        @memcpy(pixels[offset..][0..row_bytes], mapped[offset..][0..row_bytes]);
    }
}

fn transitionImage(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    source_access: vk.AccessFlags,
    destination_access: vk.AccessFlags,
    source_stage: vk.PipelineStageFlags,
    destination_stage: vk.PipelineStageFlags,
) void {
    const barrier: vk.ImageMemoryBarrier = .{
        .src_access_mask = source_access,
        .dst_access_mask = destination_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = colorSubresourceRange(),
    };
    self.device_wrapper.cmdPipelineBarrier(
        command_buffer,
        source_stage,
        destination_stage,
        .{},
        null,
        null,
        &.{barrier},
    );
}

fn transitionExternalToRender(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    output: Output,
) void {
    self.transitionExternal(
        command_buffer,
        output,
        if (output.initialized) .general else .undefined,
        .color_attachment_optimal,
        if (output.initialized) vk.QUEUE_FAMILY_FOREIGN_EXT else vk.QUEUE_FAMILY_IGNORED,
        self.queue_family_index,
        .{},
        .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
        if (output.initialized) .{ .all_commands_bit = true } else .{ .top_of_pipe_bit = true },
        .{ .color_attachment_output_bit = true },
    );
}

fn transitionRenderToExternal(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
) void {
    const output: Output = .{
        .image = image,
        .memory = .null_handle,
        .view = .null_handle,
        .descriptor_set = .null_handle,
        .framebuffer = .null_handle,
        .format = .undefined,
        .size = .{ .width = 0, .height = 0 },
        .last_used = 0,
        .linear = undefined,
        .submission = undefined,
    };
    self.transitionExternal(
        command_buffer,
        output,
        .color_attachment_optimal,
        .general,
        self.queue_family_index,
        vk.QUEUE_FAMILY_FOREIGN_EXT,
        .{ .color_attachment_write_bit = true },
        .{},
        .{ .color_attachment_output_bit = true },
        .{ .bottom_of_pipe_bit = true },
    );
}

fn transitionExternalSourceToSample(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
) void {
    const output: Output = .{
        .image = image,
        .memory = .null_handle,
        .view = .null_handle,
        .descriptor_set = .null_handle,
        .framebuffer = .null_handle,
        .format = .undefined,
        .size = .{ .width = 0, .height = 0 },
        .last_used = 0,
        .linear = undefined,
        .submission = undefined,
    };
    self.transitionExternal(
        command_buffer,
        output,
        .general,
        .shader_read_only_optimal,
        vk.QUEUE_FAMILY_FOREIGN_EXT,
        self.queue_family_index,
        .{},
        .{ .shader_read_bit = true },
        .{ .all_commands_bit = true },
        .{ .fragment_shader_bit = true },
    );
}

fn transitionSampleToExternal(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
) void {
    const output: Output = .{
        .image = image,
        .memory = .null_handle,
        .view = .null_handle,
        .descriptor_set = .null_handle,
        .framebuffer = .null_handle,
        .format = .undefined,
        .size = .{ .width = 0, .height = 0 },
        .last_used = 0,
        .linear = undefined,
        .submission = undefined,
    };
    self.transitionExternal(
        command_buffer,
        output,
        .shader_read_only_optimal,
        .general,
        self.queue_family_index,
        vk.QUEUE_FAMILY_FOREIGN_EXT,
        .{ .shader_read_bit = true },
        .{},
        .{ .fragment_shader_bit = true },
        .{ .bottom_of_pipe_bit = true },
    );
}

fn transitionExternal(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    output: Output,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    source_queue: u32,
    destination_queue: u32,
    source_access: vk.AccessFlags,
    destination_access: vk.AccessFlags,
    source_stage: vk.PipelineStageFlags,
    destination_stage: vk.PipelineStageFlags,
) void {
    const barrier: vk.ImageMemoryBarrier = .{
        .src_access_mask = source_access,
        .dst_access_mask = destination_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = source_queue,
        .dst_queue_family_index = destination_queue,
        .image = output.image,
        .subresource_range = colorSubresourceRange(),
    };
    self.device_wrapper.cmdPipelineBarrier(
        command_buffer,
        source_stage,
        destination_stage,
        .{},
        null,
        null,
        &.{barrier},
    );
}

fn rectFloats(rect: render.Rect) [4]f32 {
    return .{
        @floatFromInt(rect.x),
        @floatFromInt(rect.y),
        @floatFromInt(rect.width),
        @floatFromInt(rect.height),
    };
}

fn sizeFloats(size: render.Size) [2]f32 {
    return .{ @floatFromInt(size.width), @floatFromInt(size.height) };
}

fn rect2D(rect: render.Rect) vk.Rect2D {
    return .{
        .offset = .{ .x = rect.x, .y = rect.y },
        .extent = .{ .width = rect.width, .height = rect.height },
    };
}

fn extent(size: render.Size) vk.Extent3D {
    return .{ .width = size.width, .height = size.height, .depth = 1 };
}

fn colorSubresourceLayers() vk.ImageSubresourceLayers {
    return .{
        .aspect_mask = .{ .color_bit = true },
        .mip_level = 0,
        .base_array_layer = 0,
        .layer_count = 1,
    };
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

fn transferToHostBarrier(self: *Self, command_buffer: vk.CommandBuffer) void {
    const barrier: vk.MemoryBarrier = .{
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .host_read_bit = true },
    };
    self.device_wrapper.cmdPipelineBarrier(
        command_buffer,
        .{ .transfer_bit = true },
        .{ .host_bit = true },
        .{},
        &.{barrier},
        null,
        null,
    );
}

test "Vulkan disables blending only for rectangular opaque images" {
    var pixels = [_]u32{0xffffffff};
    var image: render.Image = .{
        .x = 0,
        .y = 0,
        .size = .{ .width = 1, .height = 1 },
        .buffer = .{
            .size = .{ .width = 1, .height = 1 },
            .stride_pixels = 1,
            .pixels = &pixels,
        },
    };
    try std.testing.expect(!imageCanReplace(image));

    image.is_opaque = true;
    try std.testing.expect(imageCanReplace(image));
    image.clip = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    try std.testing.expect(imageCanReplace(image));

    image.alpha_multiplier = 0x8000_0000;
    try std.testing.expect(!imageCanReplace(image));
    image.alpha_multiplier = std.math.maxInt(u32);
    image.rounded_clip = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .radius = 1,
    };
    try std.testing.expect(!imageCanReplace(image));
}

test "Vulkan disables blending for opaque solid rectangles" {
    var renderer: Self = undefined;
    renderer.allocator = std.testing.allocator;
    renderer.instances = .empty;
    defer renderer.instances.deinit(std.testing.allocator);
    renderer.draw_runs = .empty;
    defer renderer.draw_runs.deinit(std.testing.allocator);
    renderer.blur_ops = .empty;
    defer renderer.blur_ops.deinit(std.testing.allocator);

    const commands = [_]render.Command{
        .{ .solid_rect = .{
            .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .color = render.Color.rgba(1, 2, 3, 255),
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .color = render.Color.rgba(1, 2, 3, 128),
        } },
    };
    try renderer.compileDrawRuns(.{
        .size = .{ .width = 2, .height = 1 },
        .commands = &commands,
    }, &.{}, .{});

    try std.testing.expectEqual(@as(usize, 2), renderer.draw_runs.items.len);
    try std.testing.expectEqual(PipelineKind.replace, renderer.draw_runs.items[0].pipeline);
    try std.testing.expectEqual(PipelineKind.blend, renderer.draw_runs.items[1].pipeline);
}

test "Vulkan graphics path supports images, alpha blending, and backdrop blur" {
    try std.testing.expect(supports(&.{.{ .solid_rect = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .color = render.Color.rgba(1, 2, 3, 128),
    } }}));
    var pixels = [_]u32{0};
    try std.testing.expect(supports(&.{.{ .image = .{
        .x = 0,
        .y = 0,
        .size = .{ .width = 1, .height = 1 },
        .buffer = .{
            .size = .{ .width = 1, .height = 1 },
            .stride_pixels = 1,
            .pixels = &pixels,
        },
    } }}));
    try std.testing.expect(supports(&.{.{ .shadow = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .corner_radius = 0,
        .blur_radius = 1,
        .spread = 0,
        .color = render.Color.rgba(1, 2, 3, 128),
    } }}));
    try std.testing.expect(supports(&.{.{ .backdrop_blur = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .corner_radius = 0,
        .radius = 1,
    } }}));
}

test "Vulkan work reservation rejects overflow without changing the offset" {
    var work_size: usize = std.math.maxInt(usize) - 3;
    try std.testing.expectError(error.InvalidTarget, reserveWork(&work_size, 4));
    try std.testing.expectEqual(std.math.maxInt(usize) - 3, work_size);
}

test "backdrop blur finish is attached only to the final upsample" {
    const destination: render.Rect = .{ .x = 4, .y = 8, .width = 32, .height = 16 };
    const intermediate = kawaseUpsampleInstance(destination, 0.75, false, null);
    try std.testing.expectEqual(@as(f32, 0), intermediate.color[1]);
    try std.testing.expectEqualSlices(f32, &.{ 0.75, 1, 1, 0 }, &intermediate.parameters);

    const final = kawaseUpsampleInstance(destination, 0.75, false, .{
        .brightness = 0.95,
        .contrast = 0.92,
        .saturation = 1.08,
        .noise = 0.01,
    });
    try std.testing.expectEqualSlices(f32, &.{ 0.95, 1, 0, 0 }, &final.color);
    try std.testing.expectEqualSlices(f32, &.{ 0.75, 0.92, 1.08, 0.01 }, &final.parameters);
}

test "damage coverage combines disjoint rectangles without accepting holes" {
    const target: render.Rect = .{ .x = 2, .y = 3, .width = 6, .height = 4 };
    try std.testing.expect(try damageCoversRect(std.testing.allocator, &.{
        .{ .x = 2, .y = 3, .width = 3, .height = 4 },
        .{ .x = 5, .y = 3, .width = 3, .height = 4 },
    }, target));
    try std.testing.expect(!try damageCoversRect(std.testing.allocator, &.{
        .{ .x = 2, .y = 3, .width = 3, .height = 4 },
        .{ .x = 6, .y = 3, .width = 2, .height = 4 },
    }, target));
}

test "owner capture aliases base before owner shadow but not intersecting lower content" {
    var renderer: Self = undefined;
    renderer.allocator = std.testing.allocator;
    renderer.instances = .empty;
    defer renderer.instances.deinit(std.testing.allocator);
    renderer.draw_runs = .empty;
    defer renderer.draw_runs.deinit(std.testing.allocator);
    renderer.blur_ops = .empty;
    defer renderer.blur_ops.deinit(std.testing.allocator);

    var commands = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .backdrop_capture = .{
            .rect = .{ .x = 0, .y = 0, .width = 64, .height = 32 },
            .radius = 8,
            .base = true,
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
            .color = render.Color.rgba(255, 255, 255, 255),
        } },
        .{ .backdrop_capture = .{
            .rect = .{ .x = 48, .y = 8, .width = 8, .height = 8 },
            .radius = 8,
        } },
        .{ .shadow = .{
            .rect = .{ .x = 48, .y = 8, .width = 8, .height = 8 },
            .corner_radius = 2,
            .blur_radius = 8,
            .spread = 0,
            .color = render.Color.rgba(0, 0, 0, 128),
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 48, .y = 8, .width = 8, .height = 8 },
            .corner_radius = 0,
            .radius = 8,
        } },
    };
    var frame: render.Frame = .{
        .size = .{ .width = 64, .height = 32 },
        .commands = &commands,
    };
    try renderer.compileDrawRuns(frame, &.{}, .{});
    try std.testing.expectEqual(@as(usize, 2), renderer.blur_ops.items.len);
    try std.testing.expectEqual(@as(?u32, 0), renderer.blur_ops.items[1].reuse_op_index);
    try std.testing.expect(renderer.blur_ops.items[0].used);
    try std.testing.expect(renderer.blur_ops.items[1].used);

    renderer.instances.clearRetainingCapacity();
    renderer.draw_runs.clearRetainingCapacity();
    renderer.blur_ops.clearRetainingCapacity();
    const unrelated_damage = [_]render.Rect{.{ .x = 0, .y = 0, .width = 4, .height = 4 }};
    frame.damage = &unrelated_damage;
    try renderer.compileDrawRuns(frame, &.{}, .{});
    try std.testing.expectEqual(@as(usize, 2), renderer.blur_ops.items.len);
    try std.testing.expectEqual(@as(?u32, 0), renderer.blur_ops.items[1].reuse_op_index);
    try std.testing.expect(renderer.blur_ops.items[0].used);
    try std.testing.expect(renderer.blur_ops.items[1].used);

    renderer.instances.clearRetainingCapacity();
    renderer.draw_runs.clearRetainingCapacity();
    renderer.blur_ops.clearRetainingCapacity();
    frame.damage = null;
    commands[2].solid_rect.rect.x = 40;
    try renderer.compileDrawRuns(frame, &.{}, .{});
    try std.testing.expectEqual(@as(usize, 2), renderer.blur_ops.items.len);
    try std.testing.expectEqual(@as(?u32, null), renderer.blur_ops.items[1].reuse_op_index);
}

test "backdrop caches only reuse initialized stable keys" {
    var cache: BackdropCache = .{
        .size = .{ .width = 1, .height = 1 },
        .image = undefined,
        .framebuffer = .null_handle,
        .key = 42,
    };
    try std.testing.expect(!cache.matches(42));
    cache.initialized = true;
    try std.testing.expect(cache.matches(42));
    try std.testing.expect(!cache.matches(43));
    try std.testing.expect(!cache.matches(null));

    var output: Output = undefined;
    output.backdrop_cache = .empty;
    defer output.backdrop_cache.deinit(std.testing.allocator);
    try output.backdrop_cache.append(std.testing.allocator, cache);
    cache.key = 84;
    try output.backdrop_cache.append(std.testing.allocator, cache);
    try std.testing.expect(selectBackdropCache(
        &output,
        0,
        .{ .width = 1, .height = 1 },
        84,
    ));
    try std.testing.expectEqual(@as(?u64, 84), output.backdrop_cache.items[0].key);
    try std.testing.expectEqual(@as(?u64, 42), output.backdrop_cache.items[1].key);
}

test "recorded Vulkan frames match only identical command topology" {
    var renderer: Self = undefined;
    renderer.allocator = std.testing.allocator;
    renderer.resource_epoch = 7;
    renderer.draw_runs = .empty;
    defer renderer.draw_runs.deinit(std.testing.allocator);
    renderer.blur_ops = .empty;
    defer renderer.blur_ops.deinit(std.testing.allocator);
    try renderer.draw_runs.append(std.testing.allocator, .{
        .pipeline = .image,
        .descriptor_set = null,
        .texture_size = .{ .width = 2, .height = 1 },
        .first_instance = 0,
        .instance_count = 1,
    });

    var pixels = [_]u32{ 1, 2 };
    var damage = [_]render.Rect{.{ .x = 0, .y = 0, .width = 1, .height = 1 }};
    const prepared = [_]PreparedImage{.{
        .texture = .{
            .image = .null_handle,
            .memory = .null_handle,
            .view = .null_handle,
            .descriptor_set = .null_handle,
            .size = .{ .width = 2, .height = 1 },
            .initialized = true,
            .last_used = 1,
        },
        .buffer = .{
            .size = .{ .width = 2, .height = 1 },
            .stride_pixels = 2,
            .pixels = &pixels,
        },
        .upload_offset = 16,
        .upload_damage = &damage,
        .cache_id = 1,
        .desired_version = 2,
    }};
    const upload_completion = frameCompletion(&prepared);
    try std.testing.expectEqual(@as(u32, 1), upload_completion.cpu_uploads);
    try std.testing.expectEqual(@as(u32, 0), upload_completion.dmabuf_imports);
    var imported_prepared = prepared;
    imported_prepared[0].newly_imported = true;
    const import_completion = frameCompletion(&imported_prepared);
    try std.testing.expectEqual(@as(u32, 1), import_completion.cpu_uploads);
    try std.testing.expectEqual(@as(u32, 1), import_completion.dmabuf_imports);

    var recorded: RecordedFrame = .{};
    defer recorded.deinit(std.testing.allocator);
    var submission: Submission = undefined;
    submission.work_buffer = .null_handle;
    submission.instance_buffer = .null_handle;
    submission.timestamp_query_pool = .null_handle;
    const render_area: render.Rect = .{ .x = 0, .y = 0, .width = 2, .height = 1 };

    try renderer.rememberRecordedFrame(&submission, &recorded, true, 0, render_area, &prepared);
    try std.testing.expect(renderer.recordedFrameMatches(&submission, &recorded, true, 0, render_area, &prepared));
    try std.testing.expect(!renderer.recordedFrameMatches(&submission, &recorded, true, 1, render_area, &prepared));
    try std.testing.expect(!renderer.recordedFrameMatches(&submission, &recorded, true, 0, .{ .x = 1, .y = 0, .width = 1, .height = 1 }, &prepared));

    try renderer.blur_ops.append(std.testing.allocator, .{
        .run_index = 0,
        .sample_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    });
    try std.testing.expect(!renderer.recordedFrameMatches(&submission, &recorded, true, 0, render_area, &prepared));
    renderer.blur_ops.clearRetainingCapacity();

    damage[0].x = 1;
    try std.testing.expect(!renderer.recordedFrameMatches(&submission, &recorded, true, 0, render_area, &prepared));
    damage[0].x = 0;
    renderer.draw_runs.items[0].instance_count = 2;
    try std.testing.expect(!renderer.recordedFrameMatches(&submission, &recorded, true, 0, render_area, &prepared));
    renderer.draw_runs.items[0].instance_count = 1;
    renderer.advanceResourceEpoch();
    try std.testing.expect(!renderer.recordedFrameMatches(&submission, &recorded, true, 0, render_area, &prepared));
}

test "Vulkan renderer clears and clips solid rectangles" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var pixels = [_]u32{0} ** 12;
    const target: render.PixelBuffer = .{
        .size = .{ .width = 4, .height = 3 },
        .stride_pixels = 4,
        .pixels = &pixels,
    };
    const commands = [_]render.Command{
        .{ .clear = render.Color.rgba(1, 2, 3, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 1, .width = 3, .height = 2 },
            .clip = .{ .x = 2, .y = 0, .width = 1, .height = 3 },
            .color = render.Color.rgba(20, 30, 40, 255),
        } },
    };

    try renderer.renderFrame(
        .{ .size = target.size, .commands = &commands },
        .{ .pixels = target },
    );

    try std.testing.expectEqual(@as(u32, 0xff010203), pixels[5]);
    try std.testing.expectEqual(@as(u32, 0xff141e28), pixels[6]);
    try std.testing.expectEqual(@as(u32, 0xff010203), pixels[7]);
    try std.testing.expectEqual(@as(u32, 0xff141e28), pixels[10]);
}

test "Vulkan renderer completes asynchronous pixel readback" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var pixels = [_]u32{0} ** 16;
    const target: render.PixelBuffer = .{
        .size = .{ .width = 4, .height = 4 },
        .stride_pixels = 4,
        .pixels = &pixels,
    };
    const commands = [_]render.Command{.{
        .clear = render.Color.rgba(12, 34, 56, 255),
    }};
    const completion = try renderer.renderFrameReadback(
        .{ .size = target.size, .commands = &commands },
        target,
    );
    var destination_pixels = [_]u32{0} ** 16;
    const destination: render.PixelBuffer = .{
        .size = target.size,
        .stride_pixels = target.stride_pixels,
        .pixels = &destination_pixels,
    };
    if (completion.sync_file_fd) |fd| {
        defer _ = std.c.close(fd);
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&poll_fds, -1));
        try renderer.completeFrameReadback(target, destination);
        for (destination_pixels) |pixel| {
            try std.testing.expectEqual(@as(u32, 0xff0c2238), pixel);
        }
    } else {
        for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0xff0c2238), pixel);
    }
}

test "Vulkan pixel scanout completes before returning" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var pixels = [_]u32{0} ** 16;
    const target: render.PixelBuffer = .{
        .size = .{ .width = 4, .height = 4 },
        .stride_pixels = 4,
        .pixels = &pixels,
    };
    const completion = try renderer.renderFrameScanout(.{
        .size = target.size,
        .commands = &.{.{ .clear = render.Color.rgba(12, 34, 56, 255) }},
    }, .{ .pixels = target }, null);
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), completion.sync_file_fd);
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0xff0c2238), pixel);
}

test "Vulkan renderer applies a three-dimensional output calibration LUT" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var values: [33 * 33 * 33][4]f16 = undefined;
    for (0..33) |blue| for (0..33) |green| for (0..33) |red| {
        const scale: f32 = 1.0 / 32.0;
        values[(blue * 33 + green) * 33 + red] = .{
            @floatCast(@as(f32, @floatFromInt(blue)) * scale),
            @floatCast(@as(f32, @floatFromInt(red)) * scale),
            @floatCast(@as(f32, @floatFromInt(green)) * scale),
            1,
        };
    };
    var source = [_]u32{0xff800000};
    var pixel = [_]u32{0};
    const commands = [_]render.Command{.{ .image = .{
        .x = 0,
        .y = 0,
        .size = .{ .width = 1, .height = 1 },
        .buffer = .{
            .size = .{ .width = 1, .height = 1 },
            .stride_pixels = 1,
            .pixels = &source,
            .color_description = .{
                .transfer_function = .{ .power = 10000 },
                .min_luminance = 0,
            },
        },
        .is_opaque = true,
    } }};
    try renderer.renderFrame(.{
        .size = .{ .width = 1, .height = 1 },
        .commands = &commands,
        .output_calibration = .{
            .identity = 42,
            .edge_length = 33,
            .values = &values,
        },
    }, .{ .pixels = .{
        .size = .{ .width = 1, .height = 1 },
        .stride_pixels = 1,
        .pixels = &pixel,
    } });

    try expectArgbNear(0xff008000, pixel[0], 1);
}

test "reproducible scene: Vulkan applies ordered backdrop blurs on GPU" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var pixels = [_]u32{ 0xff000000, 0xff000000, 0xffffffff, 0xff000000, 0xff000000 };
    const target: render.PixelBuffer = .{ .size = .{ .width = 5, .height = 1 }, .stride_pixels = 5, .pixels = &pixels };
    const commands = [_]render.Command{
        .{ .backdrop_capture = .{
            .rect = .{ .x = 1, .y = 0, .width = 3, .height = 1 },
            .radius = 1,
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 1, .y = 0, .width = 3, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
            .clip = .{ .x = 2, .y = 0, .width = 1, .height = 1 },
        } },
        .{ .backdrop_capture = .{
            .rect = .{ .x = 1, .y = 0, .width = 3, .height = 1 },
            .radius = 1,
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 1, .y = 0, .width = 3, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
            .clip = .{ .x = 2, .y = 0, .width = 1, .height = 1 },
        } },
    };
    try renderer.renderFrame(.{ .size = target.size, .commands = &commands }, .{ .pixels = target });

    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[1]);
    const blurred = pixels[2] & 0xff;
    // The blur is composited in linear light and encoded only at output.
    try std.testing.expect(blurred >= 157 and blurred <= 159);
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[3]);
}

test "Vulkan backdrop blur keeps its capture across an interleaved owner" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var pixels = [_]u32{0xff000000} ** 3;
    const target: render.PixelBuffer = .{ .size = .{ .width = 3, .height = 1 }, .stride_pixels = 3, .pixels = &pixels };
    const commands = [_]render.Command{
        .{ .backdrop_capture = .{
            .id = 1,
            .rect = .{ .x = 0, .y = 0, .width = 3, .height = 1 },
            .radius = 1,
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .color = render.Color.rgba(255, 255, 255, 255),
        } },
        .{ .backdrop_capture = .{
            .id = 2,
            .rect = .{ .x = 0, .y = 0, .width = 3, .height = 1 },
            .radius = 1,
        } },
        .{ .backdrop_blur = .{
            .capture_id = 1,
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
        } },
    };
    try renderer.renderFrame(.{ .size = target.size, .commands = &commands }, .{ .pixels = target });

    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[1]);
}

test "Vulkan ignores an unused backdrop capture" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 2, .height = 1 };
    var pixels = [_]u32{0} ** 2;
    const commands = [_]render.Command{
        .{ .clear = render.Color.rgba(1, 2, 3, 255) },
        .{ .backdrop_capture = .{
            .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
            .radius = 1,
            .base = true,
        } },
    };
    try renderer.renderFrame(.{ .size = size, .commands = &commands }, .{ .pixels = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &pixels,
    } });

    for (pixels) |pixel| try expectArgbNear(0xff010203, pixel, 1);
}

test "reproducible scene: Vulkan fused backdrop image matches separate composites" {
    var fused_renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer fused_renderer.deinit();
    var separate_renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer separate_renderer.deinit();

    const size: render.Size = .{ .width = 9, .height = 5 };
    var owner_pixels = [_]u32{0x80000080} ** (size.width * size.height);
    var fused_pixels = [_]u32{0} ** (size.width * size.height);
    var separate_pixels = [_]u32{0} ** (size.width * size.height);
    const prefix = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 3, .y = 1, .width = 2, .height = 2 },
            .color = render.Color.rgba(255, 255, 255, 255),
        } },
        .{ .backdrop_capture = .{
            .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
            .radius = 8,
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
            .corner_radius = 2,
            .radius = 8,
        } },
    };
    const owner: render.Command = .{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{
            .size = size,
            .stride_pixels = size.width,
            .pixels = &owner_pixels,
        },
        .rounded_clip = .{
            .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
            .radius = 2,
        },
    } };
    const fused_commands = prefix ++ [_]render.Command{owner};
    const separate_commands = prefix ++ [_]render.Command{
        .{ .solid_rect = .{
            .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
            .color = render.Color.rgba(0, 0, 0, 0),
        } },
        owner,
    };
    try fused_renderer.renderFrame(
        .{ .size = size, .commands = &fused_commands },
        .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &fused_pixels } },
    );
    try separate_renderer.renderFrame(
        .{ .size = size, .commands = &separate_commands },
        .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &separate_pixels } },
    );
    for (fused_pixels, separate_pixels) |fused, separate| {
        try expectArgbNear(separate, fused, 1);
    }
}

test "Vulkan base backdrop cache survives partial background and owner changes" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var reference = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer reference.deinit();

    const size: render.Size = .{ .width = 32, .height = 16 };
    var cached_pixels = [_]u32{0} ** (size.width * size.height);
    var reference_pixels = [_]u32{0} ** (size.width * size.height);
    const cached_target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &cached_pixels,
    };
    const reference_target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &reference_pixels,
    };
    var commands = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 22, .y = 7, .width = 1, .height = 1 },
            .color = render.Color.rgba(255, 255, 255, 255),
        } },
        .{ .backdrop_capture = .{
            .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
            .radius = 2,
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 20, .y = 4, .width = 8, .height = 8 },
            .corner_radius = 0,
            .radius = 2,
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 20, .y = 4, .width = 8, .height = 8 },
            .color = render.Color.rgba(255, 0, 0, 64),
        } },
    };
    try renderer.renderFrame(
        .{ .size = size, .commands = &commands },
        .{ .pixels = cached_target },
    );
    const output = renderer.outputs.getPtr(targetKey(.{ .pixels = cached_target })).?;
    try std.testing.expectEqual(@as(usize, 1), output.backdrop_cache.items.len);
    const original_key = output.backdrop_cache.items[0].key.?;

    commands[1].solid_rect.color = render.Color.rgba(255, 0, 0, 255);
    try renderer.renderFrame(
        .{
            .size = size,
            .commands = &commands,
            .damage = &.{.{ .x = 22, .y = 7, .width = 1, .height = 1 }},
        },
        .{ .pixels = cached_target },
    );
    const changed_key = output.backdrop_cache.items[0].key.?;
    try std.testing.expect(original_key != changed_key);

    commands[4].solid_rect.color = render.Color.rgba(0, 0, 255, 64);
    const owner_damage = [_]render.Rect{.{ .x = 20, .y = 4, .width = 8, .height = 8 }};
    try renderer.renderFrame(
        .{ .size = size, .commands = &commands, .damage = &owner_damage },
        .{ .pixels = cached_target },
    );
    try reference.renderFrame(
        .{ .size = size, .commands = &commands },
        .{ .pixels = reference_target },
    );
    try std.testing.expectEqual(changed_key, output.backdrop_cache.items[0].key.?);
    try std.testing.expectEqualSlices(u32, &reference_pixels, &cached_pixels);
}

test "Vulkan capture cache miss preserves pixels outside a complete sample damage region" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 32, .height = 16 };
    var pixels = [_]u32{0} ** (size.width * size.height);
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &pixels,
    };
    var commands = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 10, .y = 7, .width = 1, .height = 1 },
            .color = render.Color.rgba(255, 255, 255, 255),
        } },
        .{ .backdrop_capture = .{
            .rect = .{ .x = 8, .y = 4, .width = 8, .height = 8 },
            .radius = 2,
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 8, .y = 4, .width = 8, .height = 8 },
            .corner_radius = 0,
            .radius = 2,
        } },
    };
    try renderer.renderFrame(.{ .size = size, .commands = &commands }, .{ .pixels = target });

    const untouched = 0xfeedbeef;
    pixels[31] = untouched;
    commands[1].solid_rect.color = render.Color.rgba(255, 0, 0, 255);
    try renderer.renderFrame(.{
        .size = size,
        .commands = &commands,
        .damage = &.{.{ .x = 3, .y = 0, .width = 18, .height = 16 }},
    }, .{ .pixels = target });

    try std.testing.expectEqual(@as(u32, untouched), pixels[31]);
}

test "Vulkan capture cache rekeys when lower damage misses its sample region" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 32, .height = 16 };
    var source_pixels = [_]u32{0xff000000} ** (size.width * size.height);
    var output_pixels = [_]u32{0} ** (size.width * size.height);
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &output_pixels,
    };
    var commands = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = size.width,
                .pixels = &source_pixels,
                .source_cache = .{ .id = 1, .version = 1 },
            },
        } },
        .{ .backdrop_capture = .{
            .rect = .{ .x = 8, .y = 4, .width = 8, .height = 8 },
            .radius = 2,
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 8, .y = 4, .width = 8, .height = 8 },
            .corner_radius = 0,
            .radius = 2,
        } },
    };
    try renderer.renderFrame(.{ .size = size, .commands = &commands }, .{ .pixels = target });

    const untouched = 0xfeedbeef;
    output_pixels[30] = untouched;
    source_pixels[31] = 0xffffffff;
    commands[1].image.buffer.source_cache.?.version = 2;
    try renderer.renderFrame(.{
        .size = size,
        .commands = &commands,
        .damage = &.{.{ .x = 31, .y = 0, .width = 1, .height = 1 }},
    }, .{ .pixels = target });

    try std.testing.expectEqual(@as(u32, untouched), output_pixels[30]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), output_pixels[31]);
}

test "reproducible scene: Vulkan partial backdrop blur matches a full redraw" {
    var partial_renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer partial_renderer.deinit();
    var full_renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer full_renderer.deinit();

    const size: render.Size = .{ .width = 32, .height = 16 };
    var partial_pixels = [_]u32{0} ** (size.width * size.height);
    var full_pixels = [_]u32{0} ** (size.width * size.height);
    const initial = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{ .rect = .{ .x = 8, .y = 7, .width = 1, .height = 1 }, .color = render.Color.rgba(255, 255, 255, 255) } },
        .{ .backdrop_capture = .{ .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height }, .radius = 8 } },
        .{ .backdrop_blur = .{ .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height }, .corner_radius = 0, .radius = 8 } },
    };
    try partial_renderer.renderFrame(.{ .size = size, .commands = &initial }, .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &partial_pixels } });
    try full_renderer.renderFrame(.{ .size = size, .commands = &initial }, .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &full_pixels } });

    const updated = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{ .rect = .{ .x = 10, .y = 7, .width = 1, .height = 1 }, .color = render.Color.rgba(255, 255, 255, 255) } },
        .{ .backdrop_capture = .{ .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height }, .radius = 8 } },
        .{ .backdrop_blur = .{ .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height }, .corner_radius = 0, .radius = 8 } },
    };
    try partial_renderer.renderFrame(.{
        .size = size,
        .commands = &updated,
        .damage = &.{.{ .x = 0, .y = 0, .width = 28, .height = size.height }},
    }, .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &partial_pixels } });
    try full_renderer.renderFrame(.{ .size = size, .commands = &updated }, .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &full_pixels } });

    try std.testing.expectEqualSlices(u32, &full_pixels, &partial_pixels);
}

test "reproducible scene: Vulkan preserves pixels outside frame damage" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const untouched = 0xfeedbeef;
    var pixels = [_]u32{untouched} ** 4;
    const size: render.Size = .{ .width = 4, .height = 1 };
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .clear = render.Color.rgba(1, 2, 3, 255) }},
        .damage = &.{.{ .x = 1, .y = 0, .width = 2, .height = 1 }},
    }, .{ .pixels = .{
        .size = size,
        .stride_pixels = 4,
        .pixels = &pixels,
    } });

    try std.testing.expectEqualSlices(
        u32,
        &.{ untouched, 0xff010203, 0xff010203, untouched },
        &pixels,
    );
}

test "Vulkan output color changes redraw retained pixels outside frame damage" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 2, .height = 1 };
    var pixels = [_]u32{0} ** 2;
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &pixels,
    };
    const commands = [_]render.Command{.{ .clear = render.Color.rgba(255, 0, 0, 255) }};
    try renderer.renderFrame(.{
        .size = size,
        .commands = &commands,
    }, .{ .pixels = target });
    try std.testing.expectEqualSlices(u32, &.{ 0xffff0000, 0xffff0000 }, &pixels);

    try renderer.renderFrame(.{
        .size = size,
        .commands = &commands,
        .damage = &.{.{ .x = 0, .y = 0, .width = 1, .height = 1 }},
        .output_color_description = .{
            .primaries = render.display_p3_chromaticities,
            .named_primaries = .display_p3,
        },
    }, .{ .pixels = target });

    try std.testing.expect(pixels[0] != 0xffff0000);
    try expectArgbNear(pixels[0], pixels[1], 1);
}

test "Vulkan renderer composites image commands" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var source_pixels = [_]u32{0xffabcdef};
    var target_pixels = [_]u32{0};
    const size: render.Size = .{ .width = 1, .height = 1 };
    try renderer.renderFrame(.{ .size = size, .commands = &.{.{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{ .size = size, .stride_pixels = 1, .pixels = &source_pixels },
    } }} }, .{ .pixels = .{
        .size = size,
        .stride_pixels = 1,
        .pixels = &target_pixels,
    } });

    try expectArgbNear(source_pixels[0], target_pixels[0], 1);
}

test "renderer conformance: reproducible scene: Vulkan SDR and HDR transfer round trips" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 4, .height = 1 };
    var source_pixels = [_]u32{ 0xff0a0a0a, 0xff404040, 0xff808080, 0xffe0e0e0 };
    var target_pixels = [_]u32{0} ** source_pixels.len;
    var commands = [_]render.Command{.{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{
            .size = size,
            .stride_pixels = size.width,
            .pixels = &source_pixels,
        },
        .is_opaque = true,
    } }};
    const descriptions = [_]render.ColorDescription{
        .{ .transfer_function = .gamma22 },
        .{ .transfer_function = .srgb },
        .{ .transfer_function = .bt1886 },
        .{ .transfer_function = .{ .power = 18000 } },
        .{
            .transfer_function = .st2084_pq,
            .max_luminance = 1000,
            .max_cll = 1000,
        },
        .{
            .transfer_function = .hlg,
            .max_luminance = 1000,
            .max_cll = 1000,
        },
    };
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &target_pixels,
    };
    for (descriptions) |description| {
        @memset(&target_pixels, 0);
        commands[0].image.buffer.color_description = description;
        try renderer.renderFrame(.{
            .size = size,
            .commands = &commands,
            .output_color_description = description,
        }, .{ .pixels = target });
        for (source_pixels, target_pixels) |expected, actual| {
            try expectArgbNear(expected, actual, 2);
        }
    }
}

test "renderer conformance: Vulkan vertex texture coordinates preserve buffer transforms" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const source_size: render.Size = .{ .width = 2, .height = 3 };
    var source = [_]u32{
        0xffff0000, 0xff00ff00,
        0xff0000ff, 0xffffff00,
        0xff00ffff, 0xffff00ff,
    };
    const Case = struct {
        transform: render.BufferTransform,
        expected: [6]u32,
    };
    const cases = [_]Case{
        .{ .transform = .normal, .expected = .{
            0xffff0000, 0xff00ff00,
            0xff0000ff, 0xffffff00,
            0xff00ffff, 0xffff00ff,
        } },
        .{ .transform = .rotate_90, .expected = .{
            0xff00ffff, 0xff0000ff, 0xffff0000,
            0xffff00ff, 0xffffff00, 0xff00ff00,
        } },
        .{ .transform = .rotate_180, .expected = .{
            0xffff00ff, 0xff00ffff,
            0xffffff00, 0xff0000ff,
            0xff00ff00, 0xffff0000,
        } },
        .{ .transform = .rotate_270, .expected = .{
            0xff00ff00, 0xffffff00, 0xffff00ff,
            0xffff0000, 0xff0000ff, 0xff00ffff,
        } },
        .{ .transform = .flipped, .expected = .{
            0xff00ff00, 0xffff0000,
            0xffffff00, 0xff0000ff,
            0xffff00ff, 0xff00ffff,
        } },
        .{ .transform = .flipped_90, .expected = .{
            0xffff00ff, 0xffffff00, 0xff00ff00,
            0xff00ffff, 0xff0000ff, 0xffff0000,
        } },
        .{ .transform = .flipped_180, .expected = .{
            0xff00ffff, 0xffff00ff,
            0xff0000ff, 0xffffff00,
            0xffff0000, 0xff00ff00,
        } },
        .{ .transform = .flipped_270, .expected = .{
            0xffff0000, 0xff0000ff, 0xff00ffff,
            0xff00ff00, 0xffffff00, 0xffff00ff,
        } },
    };

    for (cases) |case| {
        const target_size = case.transform.applyToSize(source_size);
        var target = [_]u32{0} ** source.len;
        try renderer.renderFrame(.{
            .size = target_size,
            .commands = &.{.{ .image = .{
                .x = 0,
                .y = 0,
                .size = target_size,
                .buffer = .{
                    .size = source_size,
                    .stride_pixels = source_size.width,
                    .pixels = &source,
                },
                .transform = case.transform,
                .is_opaque = true,
            } }},
        }, .{ .pixels = .{
            .size = target_size,
            .stride_pixels = target_size.width,
            .pixels = &target,
        } });
        for (case.expected, target) |expected, actual| {
            try expectArgbNear(expected, actual, 1);
        }
    }
}

test "renderer conformance: Vulkan reconstruction preserves constant fields and source crop edges" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var constant_source = [_]u32{0xff808080} ** 4;
    var constant_target = [_]u32{0} ** 9;
    try renderer.renderFrame(.{
        .size = .{ .width = 3, .height = 3 },
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 3, .height = 3 },
            .buffer = .{
                .size = .{ .width = 2, .height = 2 },
                .stride_pixels = 2,
                .pixels = &constant_source,
            },
        } }},
    }, .{ .pixels = .{
        .size = .{ .width = 3, .height = 3 },
        .stride_pixels = 3,
        .pixels = &constant_target,
    } });
    for (constant_target) |pixel| try expectArgbNear(0xff808080, pixel, 1);

    var cropped_source = [_]u32{ 0xffff0000, 0xffff0000, 0xff00ff00, 0xff00ff00 };
    var cropped_target = [_]u32{0} ** 4;
    try renderer.renderFrame(.{
        .size = .{ .width = 4, .height = 1 },
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 4, .height = 1 },
            .buffer = .{
                .size = .{ .width = 4, .height = 1 },
                .stride_pixels = 4,
                .pixels = &cropped_source,
            },
            .source = .{ .x = 0, .y = 0, .width = 2, .height = 1 },
        } }},
    }, .{ .pixels = .{
        .size = .{ .width = 4, .height = 1 },
        .stride_pixels = 4,
        .pixels = &cropped_target,
    } });
    for (cropped_target) |pixel| try expectArgbNear(0xffff0000, pixel, 1);

    var impulse_source = [_]u32{ 0xff000000, 0xffffffff, 0xff000000, 0xff000000 };
    var impulse_target = [_]u32{0} ** 8;
    try renderer.renderFrame(.{
        .size = .{ .width = 8, .height = 1 },
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 8, .height = 1 },
            .buffer = .{
                .size = .{ .width = 4, .height = 1 },
                .stride_pixels = 4,
                .pixels = &impulse_source,
            },
        } }},
    }, .{ .pixels = .{
        .size = .{ .width = 8, .height = 1 },
        .stride_pixels = 8,
        .pixels = &impulse_target,
    } });
    try expectArgbNear(0xffdddddd, impulse_target[2], 2);
    try expectArgbNear(0xffdddddd, impulse_target[3], 2);
}

test "renderer conformance: Vulkan reconstruction preserves premultiplied alpha" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var source = [_]u32{ 0x00000000, 0x80800000 };
    var target = [_]u32{0} ** 3;
    try renderer.renderFrame(.{
        .size = .{ .width = 3, .height = 1 },
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 3, .height = 1 },
            .buffer = .{
                .size = .{ .width = 2, .height = 1 },
                .stride_pixels = 2,
                .pixels = &source,
            },
        } }},
    }, .{ .pixels = .{
        .size = .{ .width = 3, .height = 1 },
        .stride_pixels = 3,
        .pixels = &target,
    } });
    for (target) |pixel| {
        const alpha: u8 = @truncate(pixel >> 24);
        try std.testing.expect(@as(u8, @truncate(pixel >> 16)) <= alpha);
        try std.testing.expect(@as(u8, @truncate(pixel >> 8)) <= alpha);
        try std.testing.expect(@as(u8, @truncate(pixel)) <= alpha);
    }
}

test "renderer conformance: Vulkan area minification integrates source texels" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var constant_source = [_]u32{0xff808080} ** 64;
    var constant_target = [_]u32{0} ** 9;
    try renderer.renderFrame(.{
        .size = .{ .width = 3, .height = 3 },
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 3, .height = 3 },
            .buffer = .{
                .size = .{ .width = 8, .height = 8 },
                .stride_pixels = 8,
                .pixels = &constant_source,
            },
        } }},
    }, .{ .pixels = .{
        .size = .{ .width = 3, .height = 3 },
        .stride_pixels = 3,
        .pixels = &constant_target,
    } });
    for (constant_target) |pixel| try expectArgbNear(0xff808080, pixel, 1);

    var integer_source = [_]u32{ 0xffffffff, 0xffffffff, 0xff000000, 0xff000000 };
    var integer_target = [_]u32{0};
    try renderer.renderFrame(.{
        .size = .{ .width = 1, .height = 1 },
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 1, .height = 1 },
            .buffer = .{
                .size = .{ .width = 4, .height = 1 },
                .stride_pixels = 4,
                .pixels = &integer_source,
            },
        } }},
    }, .{ .pixels = .{
        .size = .{ .width = 1, .height = 1 },
        .stride_pixels = 1,
        .pixels = &integer_target,
    } });
    try expectArgbNear(0xff808080, integer_target[0], 2);

    var fractional_source = [_]u32{ 0xffffffff, 0xff000000, 0xff000000 };
    var fractional_target = [_]u32{0};
    try renderer.renderFrame(.{
        .size = .{ .width = 1, .height = 1 },
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 1, .height = 1 },
            .buffer = .{
                .size = .{ .width = 3, .height = 1 },
                .stride_pixels = 3,
                .pixels = &fractional_source,
            },
        } }},
    }, .{ .pixels = .{
        .size = .{ .width = 1, .height = 1 },
        .stride_pixels = 1,
        .pixels = &fractional_target,
    } });
    try expectArgbNear(0xff555555, fractional_target[0], 2);

    var cropped_source = [_]u32{0xffff0000} ++ [_]u32{0xff00ff00} ** 8 ++ [_]u32{0xffff0000};
    var cropped_target = [_]u32{0} ** 2;
    try renderer.renderFrame(.{
        .size = .{ .width = 2, .height = 1 },
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 2, .height = 1 },
            .buffer = .{
                .size = .{ .width = 10, .height = 1 },
                .stride_pixels = 10,
                .pixels = &cropped_source,
            },
            .source = .{ .x = 1, .y = 0, .width = 8, .height = 1 },
        } }},
    }, .{ .pixels = .{
        .size = .{ .width = 2, .height = 1 },
        .stride_pixels = 2,
        .pixels = &cropped_target,
    } });
    for (cropped_target) |pixel| try expectArgbNear(0xff00ff00, pixel, 1);
}

test "renderer conformance: Vulkan area minification follows transforms and premultiplied alpha" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var transformed_source: [16]u32 = undefined;
    for (0..8) |y| {
        const color: u32 = if (y % 2 == 0) 0xffffffff else 0xff000000;
        transformed_source[y * 2] = color;
        transformed_source[y * 2 + 1] = color;
    }
    var transformed_target = [_]u32{0} ** 4;
    try renderer.renderFrame(.{
        .size = .{ .width = 2, .height = 2 },
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 2, .height = 2 },
            .buffer = .{
                .size = .{ .width = 2, .height = 8 },
                .stride_pixels = 2,
                .pixels = &transformed_source,
            },
            .transform = .rotate_90,
        } }},
    }, .{ .pixels = .{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = &transformed_target,
    } });
    for (transformed_target) |pixel| try expectArgbNear(0xff808080, pixel, 2);

    var alpha_source = [_]u32{ 0x00000000, 0x80800000, 0x00000000, 0x80800000 };
    var alpha_target = [_]u32{0};
    try renderer.renderFrame(.{
        .size = .{ .width = 1, .height = 1 },
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 1, .height = 1 },
            .buffer = .{
                .size = .{ .width = 4, .height = 1 },
                .stride_pixels = 4,
                .pixels = &alpha_source,
            },
        } }},
    }, .{ .pixels = .{
        .size = .{ .width = 1, .height = 1 },
        .stride_pixels = 1,
        .pixels = &alpha_target,
    } });
    try expectArgbNear(0x40400000, alpha_target[0], 1);
}

test "renderer conformance: reproducible scene: Vulkan HDR tone mapping reserves SDR highlight headroom" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const source_size: render.Size = .{ .width = 1, .height = 1 };
    var pq_reference_white = [_]u32{0xff949494};
    var sdr_reference_white = [_]u32{0xffffffff};
    var target_pixels = [_]u32{0} ** 2;
    const commands = [_]render.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = source_size,
            .buffer = .{
                .size = source_size,
                .stride_pixels = 1,
                .pixels = &pq_reference_white,
                .color_description = .{
                    .primaries = render.bt2020_chromaticities,
                    .named_primaries = .bt2020,
                    .transfer_function = .st2084_pq,
                    .min_luminance = 50,
                    .max_luminance = 10000,
                    .reference_luminance = 203,
                },
            },
        } },
        .{ .image = .{
            .x = 1,
            .y = 0,
            .size = source_size,
            .buffer = .{
                .size = source_size,
                .stride_pixels = 1,
                .pixels = &sdr_reference_white,
            },
        } },
    };
    try renderer.renderFrame(.{
        .size = .{ .width = 2, .height = 1 },
        .commands = &commands,
    }, .{ .pixels = .{
        .size = .{ .width = 2, .height = 1 },
        .stride_pixels = 2,
        .pixels = &target_pixels,
    } });

    const mapped_white: u8 = @truncate(target_pixels[0]);
    try std.testing.expect(mapped_white >= 225 and mapped_white <= 240);
    try expectArgbNear(
        0xff000000 | @as(u32, mapped_white) * 0x010101,
        target_pixels[0],
        1,
    );
    try std.testing.expectEqual(@as(u32, 0xffffffff), target_pixels[1]);
}

test "renderer conformance: reproducible scene: Vulkan HDR tone mapping preserves highlight hue" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 1, .height = 1 };
    // PQ code values representing approximately 1000, 500, and 250 nits.
    var source_pixels = [_]u32{0xffc0ad9a};
    var target_pixels = [_]u32{0};
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = 1,
                .pixels = &source_pixels,
                .color_description = .{
                    .primaries = render.bt2020_chromaticities,
                    .named_primaries = .bt2020,
                    .transfer_function = .st2084_pq,
                    .min_luminance = 50,
                    .max_luminance = 10000,
                    .reference_luminance = 203,
                },
            },
        } }},
        .output_color_description = .{
            .primaries = render.bt2020_chromaticities,
            .named_primaries = .bt2020,
        },
    }, .{ .pixels = .{
        .size = size,
        .stride_pixels = 1,
        .pixels = &target_pixels,
    } });

    const red: u8 = @truncate(target_pixels[0] >> 16);
    const green: u8 = @truncate(target_pixels[0] >> 8);
    const blue: u8 = @truncate(target_pixels[0]);
    try std.testing.expect(red >= 254);
    try std.testing.expect(green >= 175 and green <= 200);
    try std.testing.expect(blue >= 125 and blue <= 150);
}

test "renderer conformance: reproducible scene: Vulkan HDR tone mapping preserves highlight gradation" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 2, .height = 1 };
    // Neutral PQ code values representing approximately 400 and 1000 nits.
    var source_pixels = [_]u32{ 0xffa6a6a6, 0xffc0c0c0 };
    var target_pixels = [_]u32{0} ** 2;
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = 2,
                .pixels = &source_pixels,
                .color_description = .{
                    .primaries = render.bt2020_chromaticities,
                    .named_primaries = .bt2020,
                    .transfer_function = .st2084_pq,
                    .min_luminance = 50,
                    .max_luminance = 10000,
                    .reference_luminance = 203,
                },
            },
        } }},
    }, .{ .pixels = .{
        .size = size,
        .stride_pixels = 2,
        .pixels = &target_pixels,
    } });

    const lower: u8 = @truncate(target_pixels[0]);
    const upper: u8 = @truncate(target_pixels[1]);
    try expectArgbNear(0xff000000 | @as(u32, lower) * 0x010101, target_pixels[0], 1);
    try expectArgbNear(0xff000000 | @as(u32, upper) * 0x010101, target_pixels[1], 1);
    try std.testing.expect(lower + 3 < upper);
    try std.testing.expect(upper < 250);
}

test "renderer conformance: Vulkan compresses wide gamut colors without channel clipping" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 1, .height = 1 };
    var source_pixels = [_]u32{0xffff0000};
    var target_pixels = [_]u32{0};
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = 1,
                .pixels = &source_pixels,
                .color_description = .{
                    .primaries = render.display_p3_chromaticities,
                    .named_primaries = .display_p3,
                },
            },
        } }},
    }, .{ .pixels = .{
        .size = size,
        .stride_pixels = 1,
        .pixels = &target_pixels,
    } });

    const red: u8 = @truncate(target_pixels[0] >> 16);
    const green: u8 = @truncate(target_pixels[0] >> 8);
    const blue: u8 = @truncate(target_pixels[0]);
    try std.testing.expect(red >= 245);
    try std.testing.expect(green >= 25 and green <= 70);
    try std.testing.expect(blue >= 35 and blue <= 80);
}

test "renderer conformance: Vulkan preserves HDR hue above the output peak" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 1, .height = 1 };
    // A BT.2020 red near 4000 nits exceeds this P3 output's 1000-nit peak.
    var source_pixels = [_]u32{0xffe60000};
    var target_pixels = [_]u32{0};
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = 1,
                .pixels = &source_pixels,
                .color_description = .{
                    .primaries = render.bt2020_chromaticities,
                    .named_primaries = .bt2020,
                    .transfer_function = .st2084_pq,
                    .min_luminance = 50,
                    .max_luminance = 10000,
                    .reference_luminance = 203,
                },
            },
        } }},
        .output_color_description = .{
            .primaries = render.display_p3_chromaticities,
            .named_primaries = .display_p3,
            .transfer_function = .st2084_pq,
            .min_luminance = 50,
            .max_luminance = 1000,
            .reference_luminance = 203,
        },
    }, .{ .pixels = .{
        .size = size,
        .stride_pixels = 1,
        .pixels = &target_pixels,
    } });

    const red: u8 = @truncate(target_pixels[0] >> 16);
    const green: u8 = @truncate(target_pixels[0] >> 8);
    const blue: u8 = @truncate(target_pixels[0]);
    try std.testing.expect(red > 220);
    try std.testing.expect(@as(u16, red) > @as(u16, green) + 40);
    try std.testing.expect(@as(u16, red) > @as(u16, blue) + 40);
}

test "renderer conformance: Vulkan keeps source and output reference luminance distinct" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const source_size: render.Size = .{ .width = 1, .height = 1 };
    var source_pixels = [_]u32{0xffffffff};
    var target_pixels = [_]u32{0} ** 2;
    const commands = [_]render.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = source_size,
            .buffer = .{
                .size = source_size,
                .stride_pixels = 1,
                .pixels = &source_pixels,
                .color_description = .{
                    .max_luminance = 100,
                    .reference_luminance = 100,
                },
            },
        } },
        .{ .image = .{
            .x = 1,
            .y = 0,
            .size = source_size,
            .buffer = .{
                .size = source_size,
                .stride_pixels = 1,
                .pixels = &source_pixels,
                .color_description = .{
                    .max_luminance = 100,
                    .reference_luminance = 50,
                },
            },
        } },
    };
    try renderer.renderFrame(.{
        .size = .{ .width = 2, .height = 1 },
        .commands = &commands,
        .output_color_description = .{
            .max_luminance = 400,
            .reference_luminance = 200,
        },
    }, .{ .pixels = .{
        .size = .{ .width = 2, .height = 1 },
        .stride_pixels = 2,
        .pixels = &target_pixels,
    } });

    try expectArgbNear(0xffbababa, target_pixels[0], 2);
    try expectArgbNear(0xffffffff, target_pixels[1], 1);
}

test "Vulkan renderer preserves image orientation and source rectangles" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const source_size: render.Size = .{ .width = 2, .height = 2 };
    const source_pixels = [_]u32{
        0xffff0000, 0xff00ff00,
        0xff0000ff, 0xffffffff,
    };
    var target_pixels = [_]u32{0} ** 6;
    const commands = [_]render.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = source_size,
            .buffer = .{
                .size = source_size,
                .stride_pixels = 2,
                .pixels = @constCast(&source_pixels),
            },
        } },
        .{ .image = .{
            .x = 2,
            .y = 0,
            .size = .{ .width = 1, .height = 1 },
            .source = .{ .x = 1, .y = 1, .width = 1, .height = 1 },
            .buffer = .{
                .size = source_size,
                .stride_pixels = 2,
                .pixels = @constCast(&source_pixels),
            },
        } },
    };
    try renderer.renderFrame(.{
        .size = .{ .width = 3, .height = 2 },
        .commands = &commands,
    }, .{ .pixels = .{
        .size = .{ .width = 3, .height = 2 },
        .stride_pixels = 3,
        .pixels = &target_pixels,
    } });

    try std.testing.expectEqualSlices(
        u32,
        &.{ 0xffff0000, 0xff00ff00, 0xffffffff, 0xff0000ff, 0xffffffff, 0 },
        &target_pixels,
    );
}

test "Vulkan renderer keeps offscreen frames GPU-resident" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 64, .height = 64 };
    const offscreen = try renderer.createOffscreenTarget(size);
    defer renderer.releaseOutput(.{ .offscreen = offscreen.id });
    var command: render.Command = .{ .clear = render.Color.rgba(12, 34, 56, 255) };
    const frame: render.Frame = .{
        .size = size,
        .commands = @as(*const [1]render.Command, @ptrCast(&command)),
    };

    try renderer.renderFrame(frame, .{ .offscreen = offscreen });
    const output = renderer.outputs.getPtr(.{ .offscreen = offscreen.id }).?;
    try std.testing.expectEqual(OutputKind.offscreen, output.kind);
    try std.testing.expect(output.initialized);
    try std.testing.expect(output.recorded_frame.valid);

    command.clear = render.Color.rgba(78, 90, 123, 255);
    try renderer.renderFrame(frame, .{ .offscreen = offscreen });
    try std.testing.expect(output.recorded_frame.valid);
}

test "Vulkan renderer copies a retained composed frame without replaying commands" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 8, .height = 4 };
    const offscreen = try renderer.createOffscreenTarget(size);
    defer renderer.releaseOutput(.{ .offscreen = offscreen.id });
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .clear = render.Color.rgba(12, 34, 56, 255) }},
    }, .{ .offscreen = offscreen });

    var pixels = [_]u32{0} ** 32;
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &pixels,
    };
    const completion = (try renderer.copyComposedFrame(
        .{ .offscreen = offscreen },
        null,
        .{ .pixels = target },
        .{},
    )).?;
    if (completion.sync_file_fd) |fd| {
        _ = std.c.close(fd);
        try renderer.completeFrameReadback(target, target);
    }
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0xff0c2238), pixel);

    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{
            .{ .clear = render.Color.rgba(0, 0, 255, 255) },
            .{ .solid_rect = .{
                .rect = .{ .x = 4, .y = 0, .width = 4, .height = 4 },
                .color = render.Color.rgba(255, 0, 0, 255),
            } },
        },
    }, .{ .offscreen = offscreen });
    var cropped_pixels = [_]u32{0} ** 4;
    const cropped_target: render.PixelBuffer = .{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = &cropped_pixels,
    };
    const full_pattern = (try renderer.copyComposedFrame(
        .{ .offscreen = offscreen },
        null,
        .{ .pixels = target },
        .{},
    )).?;
    const cropped = (try renderer.copyComposedFrame(
        .{ .offscreen = offscreen },
        .{ .x = 6, .y = 2, .width = 2, .height = 2 },
        .{ .pixels = cropped_target },
        .{},
    )).?;
    if (full_pattern.sync_file_fd) |fd| {
        _ = std.c.close(fd);
        try renderer.completeFrameReadback(target, target);
    }
    if (cropped.sync_file_fd) |fd| {
        _ = std.c.close(fd);
        try renderer.completeFrameReadback(cropped_target, cropped_target);
    }
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[7]);
    for (cropped_pixels) |pixel| try std.testing.expectEqual(@as(u32, 0xffff0000), pixel);
    try std.testing.expectError(error.InvalidTarget, renderer.copyComposedFrame(
        .{ .offscreen = offscreen },
        .{ .x = 7, .y = 3, .width = 2, .height = 2 },
        .{ .pixels = cropped_target },
        .{},
    ));

    const monitor_description: render.ColorDescription = .{
        .primaries = render.bt2020_chromaticities,
        .named_primaries = .bt2020,
        .transfer_function = .{ .power = 24000 },
    };
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .clear = render.Color.rgba(64, 64, 64, 255) }},
        .output_color_description = monitor_description,
    }, .{ .offscreen = offscreen });
    const converted = (try renderer.copyComposedFrame(
        .{ .offscreen = offscreen },
        null,
        .{ .pixels = target },
        .{},
    )).?;
    if (converted.sync_file_fd) |fd| {
        _ = std.c.close(fd);
        try renderer.completeFrameReadback(target, target);
    }
    for (pixels) |pixel| {
        try std.testing.expectEqual(@as(u8, 255), @as(u8, @truncate(pixel >> 24)));
        try std.testing.expectApproxEqAbs(
            @as(f32, 64),
            @as(f32, @floatFromInt(@as(u8, @truncate(pixel >> 16)))),
            2,
        );
        try std.testing.expectApproxEqAbs(
            @as(f32, 64),
            @as(f32, @floatFromInt(@as(u8, @truncate(pixel >> 8)))),
            2,
        );
        try std.testing.expectApproxEqAbs(
            @as(f32, 64),
            @as(f32, @floatFromInt(@as(u8, @truncate(pixel)))),
            2,
        );
    }
}

test "Vulkan renderer imports and renders a cropped frame directly to a linear ARGB GBM dmabuf" {
    const fd = std.c.open("/dev/dri/renderD128", std.c.O{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    });
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);

    var renderer = Self.init(std.testing.allocator, .{ .major = 226, .minor = 128 }) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const access = renderer.dmabufAccess() orelse return error.SkipZigTest;
    const Gbm = @import("../backend/gbm.zig");
    var gbm = Gbm.init(fd) catch return error.SkipZigTest;
    defer gbm.deinit();

    const size: render.Size = .{ .width = 64, .height = 64 };
    var imported_buffer: ?Gbm.Buffer = null;
    const id = render.allocateRenderTargetId();
    for (access.target_formats) |target_format| {
        if (target_format.format != @intFromEnum(render.DmabufFormat.argb8888) or
            target_format.modifier != 0) continue;
        var buffer = gbm.createBuffer(
            size,
            target_format.format,
            &.{target_format.modifier},
        ) catch continue;
        renderer.importTarget(.{
            .id = id,
            .size = size,
            .fd = buffer.fd,
            .format = target_format.format,
            .modifier = buffer.modifier,
            .stride = buffer.stride,
            .offset = buffer.offset,
        }) catch {
            buffer.deinit();
            continue;
        };
        imported_buffer = buffer;
        break;
    }
    if (imported_buffer == null) return error.SkipZigTest;
    defer imported_buffer.?.deinit();
    defer renderer.releaseTarget(id);

    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .clear = render.Color.rgba(12, 34, 56, 255) }},
    }, .{ .dmabuf = .{ .id = id, .size = size } });

    const source_size: render.Size = .{ .width = 128, .height = 64 };
    const offscreen = try renderer.createOffscreenTarget(source_size);
    defer renderer.releaseOutput(.{ .offscreen = offscreen.id });
    try renderer.renderFrame(.{
        .size = source_size,
        .commands = &.{.{ .clear = render.Color.rgba(78, 90, 123, 255) }},
    }, .{ .offscreen = offscreen });
    const completion = (try renderer.copyComposedFrame(
        .{ .offscreen = offscreen },
        .{ .x = 32, .y = 0, .width = size.width, .height = size.height },
        .{ .dmabuf = .{ .id = id, .size = size } },
        .{},
    )).?;
    if (completion.sync_file_fd) |completion_fd| _ = std.c.close(completion_fd);
}

test "Vulkan renderer samples an ABGR GBM dmabuf without a CPU upload" {
    const fd = std.c.open("/dev/dri/renderD128", std.c.O{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    });
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);

    var renderer = Self.init(std.testing.allocator, .{ .major = 226, .minor = 128 }) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    if (std.mem.indexOfScalar(u64, renderer.dmabuf_rgba_source_modifiers, 0) == null) {
        return error.SkipZigTest;
    }
    const Gbm = @import("../backend/gbm.zig");
    var gbm = Gbm.init(fd) catch return error.SkipZigTest;
    defer gbm.deinit();

    const size: render.Size = .{ .width = 64, .height = 64 };
    const source_format: u32 = @intFromEnum(render.DmabufFormat.abgr8888);
    var source_buffer = gbm.createBuffer(size, source_format, &.{0}) catch
        return error.SkipZigTest;
    defer source_buffer.deinit();

    const NoopSync = struct {
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
    const cache_id = render.allocateSourceCacheId();
    var target_pixels = [_]u32{0} ** (64 * 64);
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = source_buffer.stride / @sizeOf(u32),
                .dmabuf = .{
                    .context = &source_buffer,
                    .format = source_format,
                    .modifier = source_buffer.modifier,
                    .planes = .{
                        .{
                            .fd = source_buffer.fd,
                            .stride = source_buffer.stride,
                            .offset = source_buffer.offset,
                            .required_bytes = @intCast(
                                source_buffer.offset + source_buffer.stride * size.height,
                            ),
                        },
                        .{},
                        .{},
                        .{},
                    },
                    .plane_count = 1,
                    .y_inverted = false,
                    .force_opaque = false,
                    .retain = NoopSync.retain,
                    .release = NoopSync.release,
                    .begin_cpu_read = NoopSync.begin,
                    .end_cpu_read = NoopSync.end,
                    .export_read_fence = NoopSync.exportFence,
                },
                .source_cache = .{ .id = cache_id, .version = 1 },
            },
        } }},
    }, .{ .pixels = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &target_pixels,
    } });

    try std.testing.expect(renderer.textures.get(cache_id).?.imported);
}

fn syncTestDmaBuf(fd: std.posix.fd_t, flags: u64) bool {
    while (true) {
        var state: sync.dma_buf_sync = .{ .flags = flags };
        const result = sync.ioctl(fd, sync.DMA_BUF_IOCTL_SYNC, &state);
        if (result >= 0) return true;
        switch (std.posix.errno(result)) {
            .INTR, .AGAIN => continue,
            else => return false,
        }
    }
}

const TestVideoPattern = enum {
    uniform_red,
    isolated_chroma,
};

fn fillTestVideoBuffer(
    mapping: []u8,
    format: render.DmabufFormat,
    size: render.Size,
    luma_stride: u32,
    chroma_offset: u32,
    chroma_stride: u32,
    pattern: TestVideoPattern,
    range: render.ColorRange,
) void {
    switch (format) {
        .nv12 => {
            const y_code: u8 = if (range == .limited) 63 else 54;
            const cb_code: u8 = if (range == .limited) 102 else 99;
            const cr_code: u8 = if (range == .limited) 240 else 255;
            for (0..size.height) |y| {
                @memset(mapping[y * luma_stride ..][0..size.width], y_code);
            }
            for (0..size.height / 2) |y| {
                const row = mapping[@as(usize, chroma_offset) + y * chroma_stride ..];
                for (0..size.width / 2) |x| {
                    row[x * 2] = if (pattern == .uniform_red) cb_code else 128;
                    row[x * 2 + 1] = if (pattern == .uniform_red) cr_code else 128;
                }
            }
            if (pattern == .isolated_chroma) {
                std.debug.assert(range == .limited);
                const row = mapping[@as(usize, chroma_offset) + 16 * chroma_stride ..];
                row[16 * 2] = 102;
                row[16 * 2 + 1] = 240;
            }
        },
        .p010 => {
            std.debug.assert(pattern == .uniform_red);
            const y_code: u16 = @as(u16, if (range == .limited) 252 else 217) << 6;
            const cb_code: u16 = @as(u16, if (range == .limited) 408 else 395) << 6;
            const cr_code: u16 = @as(u16, if (range == .limited) 960 else 1023) << 6;
            for (0..size.height) |y| {
                const row = mapping[y * luma_stride ..];
                for (0..size.width) |x| {
                    std.mem.writeInt(u16, row[x * 2 ..][0..2], y_code, .little);
                }
            }
            for (0..size.height / 2) |y| {
                const row = mapping[@as(usize, chroma_offset) + y * chroma_stride ..];
                for (0..size.width / 2) |x| {
                    std.mem.writeInt(u16, row[x * 4 ..][0..2], cb_code, .little);
                    std.mem.writeInt(u16, row[x * 4 + 2 ..][0..2], cr_code, .little);
                }
            }
        },
        .argb8888, .xrgb8888, .abgr8888, .xbgr8888, .xrgb2101010 => unreachable,
    }
}

fn expectVideoImport(
    format: render.DmabufFormat,
    chroma_location: render.ChromaLocation,
    pattern: TestVideoPattern,
    range: render.ColorRange,
) !void {
    const fd = std.c.open("/dev/dri/renderD128", std.c.O{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    });
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);

    var renderer = Self.init(std.testing.allocator, .{ .major = 226, .minor = 128 }) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const modifiers = switch (format) {
        .nv12 => renderer.dmabuf_nv12_source_modifiers,
        .p010 => renderer.dmabuf_p010_source_modifiers,
        .argb8888, .xrgb8888, .abgr8888, .xbgr8888, .xrgb2101010 => unreachable,
    };
    if (std.mem.indexOfScalar(u64, modifiers, 0) == null) return error.SkipZigTest;
    try std.testing.expect(render.DmabufFormatModifier.contains(
        renderer.dmabuf_source_formats,
        @intFromEnum(format),
        0,
    ));

    const Gbm = @import("../backend/gbm.zig");
    var gbm = Gbm.init(fd) catch return error.SkipZigTest;
    defer gbm.deinit();
    const size: render.Size = .{ .width = 64, .height = 64 };
    var storage = gbm.createBuffer(
        size,
        @intFromEnum(render.DmabufFormat.xrgb8888),
        &.{0},
    ) catch return error.SkipZigTest;
    defer storage.deinit();
    if (storage.modifier != 0) return error.SkipZigTest;

    const bytes_per_sample: u32 = if (format == .p010) 2 else 1;
    const luma_stride = size.width * bytes_per_sample;
    const chroma_stride = size.width * bytes_per_sample;
    const chroma_offset = luma_stride * size.height;
    const required_bytes: usize = chroma_offset + chroma_stride * (size.height / 2);
    var file_stat: sync.struct_stat = undefined;
    if (sync.fstat(storage.fd, &file_stat) != 0 or file_stat.st_size < required_bytes) {
        return error.SkipZigTest;
    }
    const mapping = std.posix.mmap(
        null,
        @intCast(file_stat.st_size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        storage.fd,
        0,
    ) catch return error.SkipZigTest;
    defer std.posix.munmap(mapping);
    if (!syncTestDmaBuf(storage.fd, sync.DMA_BUF_SYNC_WRITE)) return error.SkipZigTest;
    var write_pending = true;
    defer if (write_pending) {
        _ = syncTestDmaBuf(
            storage.fd,
            sync.DMA_BUF_SYNC_WRITE | sync.DMA_BUF_SYNC_END,
        );
    };
    fillTestVideoBuffer(
        mapping,
        format,
        size,
        luma_stride,
        chroma_offset,
        chroma_stride,
        pattern,
        range,
    );
    if (!syncTestDmaBuf(
        storage.fd,
        sync.DMA_BUF_SYNC_WRITE | sync.DMA_BUF_SYNC_END,
    )) return error.SkipZigTest;
    write_pending = false;

    const chroma_fd = std.c.dup(storage.fd);
    if (chroma_fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(chroma_fd);
    const NoopSync = struct {
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
    const cache_id = render.allocateSourceCacheId();
    var target_pixels = [_]u32{0} ** (64 * 64);
    const completion = try renderer.renderFrameWithCompletion(.{
        .size = size,
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = size.width,
                .dmabuf = .{
                    .context = &storage,
                    .format = @intFromEnum(format),
                    .modifier = 0,
                    .planes = .{
                        .{
                            .fd = storage.fd,
                            .stride = luma_stride,
                            .offset = 0,
                            .required_bytes = chroma_offset,
                        },
                        .{
                            .fd = chroma_fd,
                            .stride = chroma_stride,
                            .offset = chroma_offset,
                            .required_bytes = required_bytes,
                        },
                        .{},
                        .{},
                    },
                    .plane_count = 2,
                    .y_inverted = false,
                    .force_opaque = true,
                    .retain = NoopSync.retain,
                    .release = NoopSync.release,
                    .begin_cpu_read = NoopSync.begin,
                    .end_cpu_read = NoopSync.end,
                    .export_read_fence = NoopSync.exportFence,
                },
                .source_cache = .{ .id = cache_id, .version = 1 },
                .color_representation = .{
                    .coefficients = .bt709,
                    .range = range,
                    .chroma_location = chroma_location,
                },
            },
        } }},
    }, .{ .pixels = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &target_pixels,
    } }, .wait, null);

    try std.testing.expectEqual(@as(u32, 0), completion.cpu_uploads);
    try std.testing.expectEqual(@as(u32, 1), completion.dmabuf_imports);
    const expected_manual = switch (chroma_location) {
        .type_0, .type_1, .type_2, .type_3 => false,
        .type_4, .type_5 => true,
    };
    try std.testing.expectEqual(
        expected_manual,
        renderer.textures.get(cache_id).?.manual_ycbcr != null,
    );
    switch (pattern) {
        .uniform_red => try expectArgbNear(0xffff0000, target_pixels[32 * 64 + 32], 2),
        .isolated_chroma => switch (chroma_location) {
            .type_4 => {
                try expectArgbNear(0xffff0000, target_pixels[33 * 64 + 32], 2);
                try expectArgbNear(
                    target_pixels[33 * 64 + 31],
                    target_pixels[32 * 64 + 32],
                    2,
                );
            },
            .type_5 => try expectArgbNear(
                target_pixels[33 * 64 + 32],
                target_pixels[33 * 64 + 33],
                2,
            ),
            .type_0, .type_1, .type_2, .type_3 => unreachable,
        },
    }
}

test "renderer conformance: reproducible scene: Vulkan converts known NV12 pixels with an immutable sampler" {
    try expectVideoImport(.nv12, .type_0, .uniform_red, .limited);
}

test "renderer conformance: reproducible scene: Vulkan manually reconstructs known NV12 pixels" {
    try expectVideoImport(.nv12, .type_4, .uniform_red, .limited);
    try expectVideoImport(.nv12, .type_4, .uniform_red, .full);
}

test "renderer conformance: reproducible scene: Vulkan manually reconstructs known P010 pixels" {
    try expectVideoImport(.p010, .type_5, .uniform_red, .limited);
}

test "renderer conformance: reproducible scene: Vulkan reconstructs bottom-sited NV12 chroma" {
    try expectVideoImport(.nv12, .type_4, .isolated_chroma, .limited);
    try expectVideoImport(.nv12, .type_5, .isolated_chroma, .limited);
}

test "renderer conformance: Vulkan blends premultiplied alpha in linear light" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var pixel = [_]u32{0};
    const size: render.Size = .{ .width = 1, .height = 1 };
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{
            .{ .clear = render.Color.rgba(0, 0, 255, 255) },
            .{ .solid_rect = .{
                .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
                .color = render.Color.rgba(255, 0, 0, 128),
            } },
            .{ .solid_rect = .{
                .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
                .color = render.Color.rgba(0, 255, 0, 128),
            } },
        },
    }, .{ .pixels = .{ .size = size, .stride_pixels = 1, .pixels = &pixel } });

    try expectArgbNear(0xff88ba88, pixel[0], 1);
}

test "Vulkan renderer applies image alpha multiplier" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 1, .height = 1 };
    var source = [_]u32{0xffff0000};
    var target = [_]u32{0};
    const commands = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 255, 255) },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{ .size = size, .stride_pixels = 1, .pixels = &source },
            .alpha_multiplier = 0x8000_0000,
        } },
    };
    try renderer.renderFrame(.{ .size = size, .commands = &commands }, .{ .pixels = .{
        .size = size,
        .stride_pixels = 1,
        .pixels = &target,
    } });

    try expectArgbNear(0xffba00ba, target[0], 1);
}

fn expectArgbNear(expected: u32, actual: u32, tolerance: u8) !void {
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        const expected_channel: u8 = @truncate(expected >> shift);
        const actual_channel: u8 = @truncate(actual >> shift);
        const difference = if (expected_channel > actual_channel)
            expected_channel - actual_channel
        else
            actual_channel - expected_channel;
        try std.testing.expect(difference <= tolerance);
    }
}

test "Vulkan renderer uploads cached image content only for a new version" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 1, .height = 1 };
    var source_pixel = [_]u32{0xffff0000};
    var target_pixel = [_]u32{0};
    var command: render.Command = .{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{
            .size = size,
            .stride_pixels = 1,
            .pixels = &source_pixel,
            .source_cache = .{ .id = 42, .version = 1 },
        },
    } };
    const frame: render.Frame = .{
        .size = size,
        .commands = @as(*const [1]render.Command, @ptrCast(&command)),
    };
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = 1,
        .pixels = &target_pixel,
    };
    try renderer.renderFrame(frame, .{ .pixels = target });
    try std.testing.expectEqual(@as(u32, 0xffff0000), target_pixel[0]);

    source_pixel[0] = 0xff00ff00;
    try renderer.renderFrame(frame, .{ .pixels = target });
    try std.testing.expectEqual(@as(u32, 0xffff0000), target_pixel[0]);

    command.image.buffer.source_cache.?.version = 2;
    try renderer.renderFrame(frame, .{ .pixels = target });
    try std.testing.expectEqual(@as(u32, 0xff00ff00), target_pixel[0]);
}

test "Vulkan renderer uploads only source-damaged texture pixels" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 2, .height = 1 };
    var source_pixels = [_]u32{ 0xffff0000, 0xff0000ff };
    var target_pixels = [_]u32{0} ** 2;
    var command: render.Command = .{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{
            .size = size,
            .stride_pixels = 2,
            .pixels = &source_pixels,
            .source_cache = .{ .id = 43, .version = 1 },
        },
    } };
    const frame: render.Frame = .{
        .size = size,
        .commands = @as(*const [1]render.Command, @ptrCast(&command)),
    };
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = 2,
        .pixels = &target_pixels,
    };
    try renderer.renderFrame(frame, .{ .pixels = target });

    source_pixels = .{ 0xff00ff00, 0xffffffff };
    command.image.buffer.source_cache.?.version = 2;
    command.image.buffer.source_damage = &.{.{
        .x = 1,
        .y = 0,
        .width = 1,
        .height = 1,
    }};
    try renderer.renderFrame(frame, .{ .pixels = target });

    try std.testing.expectEqualSlices(
        u32,
        &.{ 0xffff0000, 0xffffffff },
        &target_pixels,
    );
}

test "reproducible scene: Vulkan preserves command order in a mixed GPU frame" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 2, .height = 1 };
    var source_pixels = [_]u32{0xffff0000} ** 2;
    const untouched = 0xfeedbeef;
    var target_pixels = [_]u32{untouched} ** 2;
    const commands = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{ .size = size, .stride_pixels = 2, .pixels = &source_pixels },
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .color = render.Color.rgba(0, 255, 0, 255),
        } },
    };
    try renderer.renderFrame(.{
        .size = size,
        .commands = &commands,
        .damage = &.{.{ .x = 1, .y = 0, .width = 1, .height = 1 }},
    }, .{ .pixels = .{
        .size = size,
        .stride_pixels = 2,
        .pixels = &target_pixels,
    } });

    try std.testing.expectEqualSlices(u32, &.{ untouched, 0xff00ff00 }, &target_pixels);
}

test "Vulkan crossfades retained linear offscreen targets" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const size: render.Size = .{ .width = 1, .height = 1 };
    const old = try renderer.createOffscreenTarget(size);
    defer renderer.releaseOutput(.{ .offscreen = old.id });
    const new = try renderer.createOffscreenTarget(size);
    defer renderer.releaseOutput(.{ .offscreen = new.id });
    try renderer.renderFrame(.{ .size = size, .commands = &.{
        .{ .clear = render.Color.rgba(0, 0, 0, 0) },
        .{ .solid_rect = .{ .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .color = render.Color.rgba(0, 0, 0, 128) } },
    } }, .{ .offscreen = old });
    try renderer.renderFrame(.{ .size = size, .commands = &.{
        .{ .clear = render.Color.rgba(0, 0, 0, 0) },
        .{ .solid_rect = .{ .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .color = render.Color.rgba(255, 255, 255, 128) } },
    } }, .{ .offscreen = new });

    const factors = [_]u32{ 0, std.math.maxInt(u32) / 2, std.math.maxInt(u32) };
    const expected = [_]u8{ 44, 143, 191 };
    for (factors, expected) |factor, wanted| {
        var pixel = [_]u32{0};
        try renderer.renderFrame(.{ .size = size, .commands = &.{
            .{ .clear = render.Color.rgba(64, 64, 64, 255) },
            .{ .crossfade = .{
                .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
                .old = .{ .offscreen = old },
                .new = .{ .offscreen = new },
                .factor = factor,
            } },
        } }, .{ .pixels = .{ .size = size, .stride_pixels = 1, .pixels = &pixel } });
        inline for (0..3) |component| {
            const actual: u8 = @truncate(pixel[0] >> @intCast(component * 8));
            try std.testing.expect(@abs(@as(i16, wanted) - actual) <= 3);
        }
    }

    // A retained image outside this frame's damage must not emit or mutate a draw run.
    var undamaged = [_]u32{0};
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .crossfade = .{
            .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .old = .{ .offscreen = old },
            .new = .{ .offscreen = new },
            .factor = std.math.maxInt(u32) / 2,
        } }},
        .damage = &.{.{ .x = 1, .y = 0, .width = 1, .height = 1 }},
    }, .{ .pixels = .{ .size = size, .stride_pixels = 1, .pixels = &undamaged } });

    var pixel = [_]u32{0};
    try std.testing.expectError(error.InvalidTarget, renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .crossfade = .{
            .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .old = .{ .offscreen = .{ .id = old.id + new.id + 1, .size = size } },
            .new = .{ .offscreen = new },
            .factor = 0,
        } }},
    }, .{ .pixels = .{ .size = size, .stride_pixels = 1, .pixels = &pixel } }));
}

test "Vulkan renderer reuses frame resources per target" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var small_pixels = [_]u32{0};
    const small: render.PixelBuffer = .{
        .size = .{ .width = 1, .height = 1 },
        .stride_pixels = 1,
        .pixels = &small_pixels,
    };
    try renderer.renderFrame(.{
        .size = small.size,
        .commands = &.{.{ .clear = render.Color.rgba(1, 2, 3, 255) }},
    }, .{ .pixels = small });
    const small_key = targetKey(.{ .pixels = small });
    const initial_buffer = renderer.outputs.getPtr(small_key).?.submission.work_buffer;
    try renderer.renderFrame(.{
        .size = small.size,
        .commands = &.{.{ .clear = render.Color.rgba(4, 5, 6, 255) }},
    }, .{ .pixels = small });
    try std.testing.expectEqual(
        initial_buffer,
        renderer.outputs.getPtr(small_key).?.submission.work_buffer,
    );
    try std.testing.expectEqual(@as(u32, 0xff040506), small_pixels[0]);

    var large_pixels = [_]u32{0} ** 4;
    const large: render.PixelBuffer = .{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = &large_pixels,
    };
    try renderer.renderFrame(.{
        .size = large.size,
        .commands = &.{.{ .clear = render.Color.rgba(7, 8, 9, 255) }},
    }, .{ .pixels = large });
    const large_key = targetKey(.{ .pixels = large });
    try std.testing.expectEqual(
        @as(usize, 4 * @sizeOf(u32)),
        renderer.outputs.getPtr(large_key).?.submission.work_capacity,
    );
    try std.testing.expectEqualSlices(u32, &([_]u32{0xff070809} ** 4), &large_pixels);

    try renderer.renderFrame(.{
        .size = small.size,
        .commands = &.{.{ .clear = render.Color.rgba(10, 11, 12, 255) }},
    }, .{ .pixels = small });
    try std.testing.expectEqual(
        @as(usize, @sizeOf(u32)),
        renderer.outputs.getPtr(small_key).?.submission.work_capacity,
    );
    try std.testing.expectEqual(@as(u32, 0xff0a0b0c), small_pixels[0]);
}

test "Vulkan renderer reports tagged GPU timestamps for cached frames" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const target = try renderer.createOffscreenTarget(.{ .width = 1, .height = 1 });
    defer renderer.releaseOutput(.{ .offscreen = target.id });
    if (renderer.outputs.getPtr(.{ .offscreen = target.id }).?.submission.timestamp_query_pool == .null_handle) {
        return error.SkipZigTest;
    }
    const frame: render.Frame = .{
        .size = target.size,
        .commands = &.{.{ .clear = render.Color.rgba(1, 2, 3, 255) }},
    };
    _ = try renderer.renderFrameScanout(frame, .{ .offscreen = target }, 17);
    try std.testing.expect(renderer.takeGpuTiming() == null);
    _ = try renderer.renderFrameScanout(frame, .{ .offscreen = target }, 18);
    const first_timing = renderer.takeGpuTiming().?;
    try std.testing.expectEqual(@as(u64, 17), first_timing.tag);
    try std.testing.expect(first_timing.pass_timings_available);
    try renderer.renderFrame(frame, .{ .offscreen = target });
    const cached_timing = renderer.takeGpuTiming().?;
    try std.testing.expectEqual(@as(u64, 18), cached_timing.tag);
    try std.testing.expect(cached_timing.pass_timings_available);
    try std.testing.expect(renderer.takeGpuTiming() == null);
}

test "Vulkan renderer keeps independent output submissions in flight" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const first = try renderer.createOffscreenTarget(.{ .width = 1, .height = 1 });
    defer renderer.releaseOutput(.{ .offscreen = first.id });
    const second = try renderer.createOffscreenTarget(.{ .width = 1, .height = 1 });
    defer renderer.releaseOutput(.{ .offscreen = second.id });
    const frame: render.Frame = .{
        .size = first.size,
        .commands = &.{.{ .clear = render.Color.rgba(1, 2, 3, 255) }},
    };

    _ = try renderer.renderFrameScanout(frame, .{ .offscreen = first }, null);
    try std.testing.expect(renderer.outputs.getPtr(.{ .offscreen = first.id }).?.submission.fence_pending);

    _ = try renderer.renderFrameScanout(frame, .{ .offscreen = second }, null);
    try std.testing.expect(renderer.outputs.getPtr(.{ .offscreen = first.id }).?.submission.fence_pending);
    try std.testing.expect(renderer.outputs.getPtr(.{ .offscreen = second.id }).?.submission.fence_pending);
    try std.testing.expect(
        renderer.outputs.getPtr(.{ .offscreen = first.id }).?.submission.instance_buffer !=
            renderer.outputs.getPtr(.{ .offscreen = second.id }).?.submission.instance_buffer,
    );

    try renderer.drainAllPending();
    try std.testing.expect(!renderer.outputs.getPtr(.{ .offscreen = first.id }).?.submission.fence_pending);
    try std.testing.expect(!renderer.outputs.getPtr(.{ .offscreen = second.id }).?.submission.fence_pending);
}

test "GPU timing plan includes only executed backdrop blur passes" {
    const run: DrawRun = .{
        .pipeline = .blur_composite,
        .descriptor_set = null,
        .texture_size = .{ .width = 10, .height = 10 },
        .first_instance = 0,
        .instance_count = 1,
    };
    var blur: BlurOp = .{
        .run_index = 0,
        .used = true,
        .sample_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
    };

    const rendered = buildGpuTimingPlan(&.{run}, &.{blur});
    try std.testing.expectEqualSlices(GpuTimingCategory, &.{
        .composition_overhead,
        .blur_downsample,
        .blur_upsample,
        .blur_composite,
        .composition_overhead,
    }, rendered.segments[0..rendered.segment_count]);

    blur.cache_hit = true;
    const cached = buildGpuTimingPlan(&.{run}, &.{blur});
    try std.testing.expectEqualSlices(GpuTimingCategory, &.{
        .composition_overhead,
        .blur_composite,
        .composition_overhead,
    }, cached.segments[0..cached.segment_count]);

    blur.used = false;
    const unused = buildGpuTimingPlan(&.{run}, &.{blur});
    try std.testing.expectEqualSlices(
        GpuTimingCategory,
        &.{.composition_overhead},
        unused.segments[0..unused.segment_count],
    );
}
