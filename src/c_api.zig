//! Stable C ABI adapter. Policy and rendering behavior live in `keywork`.

const std = @import("std");
const keywork = @import("keywork");

const allocator = std.heap.c_allocator;

const KeyworkContext = opaque {};
const KeyworkSurface = opaque {};

const CSurfaceOptions = extern struct {
    struct_size: usize,
    backend: c_int,
    title: ?[*:0]const u8,
    app_id: ?[*:0]const u8,
    width: u32,
    height: u32,
    layer_shell: c_int,
    layer_namespace: ?[*:0]const u8,
    layer: c_int,
    layer_anchors: u32,
    layer_exclusive_zone: i32,
    layer_margin_top: i32,
    layer_margin_right: i32,
    layer_margin_bottom: i32,
    layer_margin_left: i32,
    layer_keyboard_interactivity: c_int,
};

const CEvent = extern struct {
    struct_size: usize,
    kind: c_int,
    surface_id: u64,
    document_id: u64,
    handler_id: u64,
    payload_kind: c_int,
    payload_ptr: ?[*]const u8,
    payload_len: usize,
    payload_bool: c_int,
    width: f32,
    height: f32,
};

const CThemeColors = extern struct {
    struct_size: usize,
    color_scheme: c_int,
    primary: u32,
    on_primary: u32,
    primary_container: u32,
    on_primary_container: u32,
    surface: u32,
    on_surface: u32,
    on_surface_variant: u32,
    surface_container_low: u32,
    surface_container: u32,
    surface_container_high: u32,
    error_color: u32,
    on_error: u32,
    error_container: u32,
    on_error_container: u32,
    outline: u32,
    outline_variant: u32,
};

const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    unsupported = 3,
    invalid_document = 4,
    system_error = 5,
    internal_error = 6,
};

pub export fn keywork_abi_version() callconv(.c) u32 {
    return 3;
}

pub export fn keywork_widget_version() callconv(.c) u32 {
    return keywork.widget_wire_version;
}

pub export fn keywork_context_create(out_context: ?*?*KeyworkContext) callconv(.c) c_int {
    const out = out_context orelse return status(.invalid_argument);
    out.* = null;
    const context = keywork.Context.init(allocator, .{}) catch |err| return statusFromError(err);
    out.* = contextHandle(context);
    return status(.ok);
}

pub export fn keywork_context_destroy(context_handle: ?*KeyworkContext) callconv(.c) void {
    const context = contextFromHandle(context_handle orelse return);
    context.deinit();
}

pub export fn keywork_context_event_fd(context_handle: ?*KeyworkContext) callconv(.c) c_int {
    const context = contextFromHandle(context_handle orelse return -1);
    return context.eventFd();
}

pub export fn keywork_context_dispatch(context_handle: ?*KeyworkContext) callconv(.c) c_int {
    const context = contextFromHandle(context_handle orelse return status(.invalid_argument));
    context.dispatch() catch |err| return statusFromError(err);
    return status(.ok);
}

pub export fn keywork_context_next_event(context_handle: ?*KeyworkContext, out_event: ?*CEvent) callconv(.c) c_int {
    const context = contextFromHandle(context_handle orelse return -status(.invalid_argument));
    const out = out_event orelse return -status(.invalid_argument);
    if (out.struct_size < @sizeOf(CEvent)) return -status(.invalid_argument);
    const event = context.nextEvent() orelse return 0;
    out.* = .{
        .struct_size = @sizeOf(CEvent),
        .kind = 0,
        .surface_id = 0,
        .document_id = 0,
        .handler_id = 0,
        .payload_kind = 0,
        .payload_ptr = null,
        .payload_len = 0,
        .payload_bool = 0,
        .width = 0,
        .height = 0,
    };
    switch (event) {
        .handler => |value| {
            out.kind = 1;
            out.surface_id = value.surface;
            out.document_id = value.document;
            out.handler_id = value.handler;
            switch (value.payload) {
                .none => {},
                .boolean => |payload| {
                    out.payload_kind = 1;
                    out.payload_bool = if (payload) 1 else 0;
                },
                .text => |payload| {
                    out.payload_kind = 2;
                    out.payload_ptr = payload.ptr;
                    out.payload_len = payload.len;
                },
            }
        },
        .configured => |value| {
            out.kind = 2;
            out.surface_id = value.surface;
            out.width = value.width;
            out.height = value.height;
        },
        .closed => |value| {
            out.kind = 3;
            out.surface_id = value.surface;
        },
        .appearance_changed => {
            out.kind = 4;
        },
        .document_retired => |value| {
            out.kind = 5;
            out.surface_id = value.surface;
            out.document_id = value.document;
        },
    }
    return 1;
}

pub export fn keywork_context_get_color_scheme(context_handle: ?*const KeyworkContext, out_color_scheme: ?*c_int) callconv(.c) c_int {
    const context = contextFromConstHandle(context_handle orelse return status(.invalid_argument));
    const out = out_color_scheme orelse return status(.invalid_argument);
    out.* = @intFromEnum(context.colorScheme());
    return status(.ok);
}

pub export fn keywork_context_get_theme_colors(context_handle: ?*const KeyworkContext, out_colors: ?*CThemeColors) callconv(.c) c_int {
    const context = contextFromConstHandle(context_handle orelse return status(.invalid_argument));
    const out = out_colors orelse return status(.invalid_argument);
    if (out.struct_size < @sizeOf(CThemeColors)) return status(.invalid_argument);

    const color_scheme = context.colorScheme();
    const colors = keywork.Theme.fromColorScheme(color_scheme.name()).color_scheme;
    out.* = .{
        .struct_size = @sizeOf(CThemeColors),
        .color_scheme = @intFromEnum(color_scheme),
        .primary = colorInt(colors.primary),
        .on_primary = colorInt(colors.on_primary),
        .primary_container = colorInt(colors.primary_container),
        .on_primary_container = colorInt(colors.on_primary_container),
        .surface = colorInt(colors.surface),
        .on_surface = colorInt(colors.on_surface),
        .on_surface_variant = colorInt(colors.on_surface_variant),
        .surface_container_low = colorInt(colors.surface_container_low),
        .surface_container = colorInt(colors.surface_container),
        .surface_container_high = colorInt(colors.surface_container_high),
        .error_color = colorInt(colors.error_color),
        .on_error = colorInt(colors.on_error),
        .error_container = colorInt(colors.error_container),
        .on_error_container = colorInt(colors.on_error_container),
        .outline = colorInt(colors.outline),
        .outline_variant = colorInt(colors.outline_variant),
    };
    return status(.ok);
}

pub export fn keywork_context_set_icon_theme(context_handle: ?*KeyworkContext, theme_name: ?[*:0]const u8) callconv(.c) c_int {
    const context = contextFromHandle(context_handle orelse return status(.invalid_argument));
    const name = theme_name orelse return status(.invalid_argument);
    context.setIconTheme(std.mem.span(name)) catch |err| return statusFromError(err);
    return status(.ok);
}

pub export fn keywork_context_create_image_rgba8(context_handle: ?*KeyworkContext, width: u32, height: u32, stride_bytes: usize, pixels_ptr: ?[*]const u8, pixels_len: usize, out_resource_id: ?*u64) callconv(.c) c_int {
    const context = contextFromHandle(context_handle orelse return status(.invalid_argument));
    const out = out_resource_id orelse return status(.invalid_argument);
    out.* = 0;
    const pixels = pixels_ptr orelse return status(.invalid_argument);
    out.* = context.createImageRgba8(width, height, stride_bytes, pixels[0..pixels_len]) catch |err| return statusFromError(err);
    return status(.ok);
}

pub export fn keywork_context_create_alpha_mask_a8(context_handle: ?*KeyworkContext, width: u32, height: u32, stride_bytes: usize, pixels_ptr: ?[*]const u8, pixels_len: usize, out_resource_id: ?*u64) callconv(.c) c_int {
    const context = contextFromHandle(context_handle orelse return status(.invalid_argument));
    const out = out_resource_id orelse return status(.invalid_argument);
    out.* = 0;
    const pixels = pixels_ptr orelse return status(.invalid_argument);
    out.* = context.createAlphaMaskA8(width, height, stride_bytes, pixels[0..pixels_len]) catch |err| return statusFromError(err);
    return status(.ok);
}

pub export fn keywork_context_release_resource(context_handle: ?*KeyworkContext, resource_id: u64) callconv(.c) void {
    const context = contextFromHandle(context_handle orelse return);
    context.releaseResource(resource_id);
}

pub export fn keywork_surface_create(
    context_handle: ?*KeyworkContext,
    options_ptr: ?*const CSurfaceOptions,
    out_surface: ?*?*KeyworkSurface,
) callconv(.c) c_int {
    const context = contextFromHandle(context_handle orelse return status(.invalid_argument));
    const options = options_ptr orelse return status(.invalid_argument);
    const out = out_surface orelse return status(.invalid_argument);
    out.* = null;
    if (options.struct_size < @sizeOf(CSurfaceOptions)) return status(.invalid_argument);

    const backend: keywork.Backend = switch (options.backend) {
        0 => .auto,
        1 => .wayland_shm,
        2 => .vulkan,
        3 => .headless,
        else => return status(.unsupported),
    };
    const layer_shell: ?keywork.LayerShellOptions = if (options.layer_shell != 0) .{
        .namespace = cString(options.layer_namespace, "keywork"),
        .layer = std.enums.fromInt(keywork.LayerShellOptions.Layer, options.layer) orelse return status(.invalid_argument),
        .anchors = .{
            .top = options.layer_anchors & (1 << 0) != 0,
            .bottom = options.layer_anchors & (1 << 1) != 0,
            .left = options.layer_anchors & (1 << 2) != 0,
            .right = options.layer_anchors & (1 << 3) != 0,
        },
        .exclusive_zone = options.layer_exclusive_zone,
        .margin = .{
            .top = options.layer_margin_top,
            .right = options.layer_margin_right,
            .bottom = options.layer_margin_bottom,
            .left = options.layer_margin_left,
        },
        .keyboard_interactivity = std.enums.fromInt(
            keywork.LayerShellOptions.KeyboardInteractivity,
            options.layer_keyboard_interactivity,
        ) orelse return status(.invalid_argument),
    } else null;

    const surface = context.createSurface(.{
        .backend = backend,
        .title = cString(options.title, "Keywork"),
        .app_id = cString(options.app_id, "dev.keywork.Keywork"),
        .width = options.width,
        .height = options.height,
        .layer_shell = layer_shell,
    }) catch |err| return statusFromError(err);
    out.* = surfaceHandle(surface);
    return status(.ok);
}

test "C backend enum mapping defaults zero-initialized options to auto" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(CBackend.auto));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(CBackend.wayland_shm));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(CBackend.vulkan));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(CBackend.headless));
}

const CBackend = enum(c_int) {
    auto = 0,
    wayland_shm = 1,
    vulkan = 2,
    headless = 3,
};

pub export fn keywork_surface_destroy(
    context_handle: ?*KeyworkContext,
    surface_handle: ?*KeyworkSurface,
) callconv(.c) void {
    const context = contextFromHandle(context_handle orelse return);
    const surface = surfaceFromHandle(surface_handle orelse return);
    context.destroySurface(surface);
}

pub export fn keywork_surface_id(surface_handle: ?*const KeyworkSurface) callconv(.c) u64 {
    const surface = surfaceFromConstHandle(surface_handle orelse return 0);
    return surface.surfaceId();
}

pub export fn keywork_surface_submit(
    surface_handle: ?*KeyworkSurface,
    bytes_ptr: ?[*]const u8,
    bytes_len: usize,
    out_document_id: ?*u64,
) callconv(.c) c_int {
    const surface = surfaceFromHandle(surface_handle orelse return status(.invalid_argument));
    const out = out_document_id orelse return status(.invalid_argument);
    out.* = 0;
    if (bytes_len > 0 and bytes_ptr == null) return status(.invalid_argument);
    const bytes = if (bytes_ptr) |ptr| ptr[0..bytes_len] else &.{};
    out.* = surface.submitEncoded(bytes) catch |err| return statusFromError(err);
    return status(.ok);
}

pub export fn keywork_surface_invalidate(surface_handle: ?*KeyworkSurface) callconv(.c) c_int {
    const surface = surfaceFromHandle(surface_handle orelse return status(.invalid_argument));
    surface.invalidate() catch |err| return statusFromError(err);
    return status(.ok);
}

fn cString(value: ?[*:0]const u8, default: []const u8) []const u8 {
    return if (value) |pointer| std.mem.span(pointer) else default;
}

fn colorInt(color: keywork.Color) u32 {
    return @bitCast(color);
}

fn status(value: Status) c_int {
    return @intFromEnum(value);
}

fn statusFromError(err: anyerror) c_int {
    return status(switch (err) {
        error.OutOfMemory,
        error.OutOfHostMemory,
        error.OutOfDeviceMemory,
        => .out_of_memory,
        error.InvalidSurfaceSize,
        error.InvalidResource,
        error.InvalidIconTheme,
        error.ReentrantDispatch,
        => .invalid_argument,
        error.UnsupportedDocumentVersion,
        error.ResourceUnavailable,
        error.UnsupportedLayerShell,
        error.UnsupportedLayerShellAllOutputs,
        error.VulkanLoaderUnavailable,
        error.VulkanLoaderSymbolMissing,
        error.NoSuitableVulkanDevice,
        error.NoSurfaceFormats,
        error.UnsupportedSwapchainUsage,
        error.ExtensionNotPresent,
        error.FeatureNotPresent,
        error.FormatNotSupported,
        error.IncompatibleDriver,
        => .unsupported,
        error.TruncatedDocument,
        error.InvalidDocumentMagic,
        error.InvalidDocumentHeader,
        error.InvalidDocumentSize,
        error.InvalidRootNode,
        error.InvalidNodeIndex,
        error.DocumentTooDeep,
        error.CyclicDocument,
        error.DuplicateNodeReference,
        error.DuplicateSiblingKey,
        error.UnreachableNode,
        error.InvalidNodeField,
        error.InvalidChildCount,
        error.InvalidChildIndex,
        error.InvalidString,
        error.UnknownNodeTag,
        => .invalid_document,
        error.NoWlCompositor,
        error.NoWlShm,
        error.NoXdgWmBase,
        error.NoLayerShell,
        error.NoWlOutput,
        error.RoundtripFailed,
        error.DispatchFailed,
        error.ReadEventsFailed,
        error.FlushFailed,
        => .system_error,
        else => .internal_error,
    });
}

fn contextHandle(context: *keywork.Context) *KeyworkContext {
    return @ptrCast(context);
}

fn contextFromHandle(handle: *KeyworkContext) *keywork.Context {
    return @ptrCast(@alignCast(handle));
}

fn contextFromConstHandle(handle: *const KeyworkContext) *const keywork.Context {
    return @ptrCast(@alignCast(handle));
}

fn surfaceHandle(surface: *keywork.Surface) *KeyworkSurface {
    return @ptrCast(surface);
}

fn surfaceFromHandle(handle: *KeyworkSurface) *keywork.Surface {
    return @ptrCast(@alignCast(handle));
}

fn surfaceFromConstHandle(handle: *const KeyworkSurface) *const keywork.Surface {
    return @ptrCast(@alignCast(handle));
}

test "C context lifecycle" {
    var handle: ?*KeyworkContext = null;
    try std.testing.expectEqual(status(.ok), keywork_context_create(&handle));
    try std.testing.expect(keywork_context_event_fd(handle) >= 0);
    keywork_context_destroy(handle);
}
