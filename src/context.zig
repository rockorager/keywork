//! Public context/surface lifecycle and host event-loop boundary.

const std = @import("std");
const appearance = @import("appearance.zig");
const core = @import("core.zig");
const DesktopSettings = @import("desktop_settings.zig");
const document_mod = @import("document.zig");
const event_loop = @import("event_loop.zig");
const icon_render = @import("icon_render.zig");
const icon_theme = @import("icon_theme.zig");
const image_render = @import("image_render.zig");
const resources = @import("resources.zig");
const Runtime = @import("runtime.zig").Runtime;
const ui = @import("ui.zig");
const wayland_shm = @import("wayland_shm.zig");
const wayland_vulkan = @import("wayland_vulkan.zig");

const log = std.log.scoped(.keywork_context);

pub const SurfaceId = u64;
pub const DocumentId = ui.DocumentId;
pub const ColorScheme = appearance.ColorScheme;

pub const ContextOptions = struct {
    /// Observe toolkit-relevant settings through the XDG Desktop Portal.
    /// Failure to connect is non-fatal and leaves values at their defaults.
    desktop_settings: bool = true,
};

pub const Backend = enum {
    auto,
    headless,
    wayland_shm,
    vulkan,
};

pub const LayerShellOptions = struct {
    namespace: []const u8 = "keywork",
    layer: Layer = .top,
    anchors: AnchorSet = .{},
    exclusive_zone: i32 = 0,
    margin: Margin = .{},
    keyboard_interactivity: KeyboardInteractivity = .none,

    pub const Layer = enum {
        background,
        bottom,
        top,
        overlay,
    };

    pub const AnchorSet = packed struct {
        top: bool = false,
        bottom: bool = false,
        left: bool = false,
        right: bool = false,
    };

    pub const Margin = struct {
        top: i32 = 0,
        right: i32 = 0,
        bottom: i32 = 0,
        left: i32 = 0,
    };

    pub const KeyboardInteractivity = enum {
        none,
        exclusive,
        on_demand,
    };
};

pub const SurfaceOptions = struct {
    backend: Backend = .auto,
    title: []const u8 = "Keywork",
    app_id: []const u8 = "dev.keywork.Keywork",
    width: u32 = 640,
    height: u32 = 480,
    layer_shell: ?LayerShellOptions = null,
};

pub const Event = union(enum) {
    handler: Handler,
    configured: Configured,
    closed: Closed,
    appearance_changed: AppearanceChanged,
    document_retired: EventDocumentRetired,

    pub const Handler = struct {
        surface: SurfaceId,
        document: DocumentId,
        handler: ui.HandlerId,
        payload: EventHandlerPayload = .none,
    };

    pub const HandlerPayload = EventHandlerPayload;

    pub const Configured = struct {
        surface: SurfaceId,
        width: f32,
        height: f32,
    };

    pub const Closed = struct {
        surface: SurfaceId,
    };

    pub const AppearanceChanged = struct {
        color_scheme: ColorScheme,
    };

    pub const DocumentRetired = EventDocumentRetired;
};

pub const HandlerPayload = Event.HandlerPayload;
pub const DocumentRetired = Event.DocumentRetired;

const EventDocumentRetired = struct {
    surface: SurfaceId,
    document: DocumentId,
};

const EventHandlerPayload = union(enum) { none, boolean: bool, text: []const u8 };

/// Opaque, heap-stable context owned by Keywork. The handle may be copied,
/// but the context it identifies is single-thread-affine.
pub const Context = opaque {
    pub fn init(allocator: std.mem.Allocator, options: ContextOptions) !*Context {
        const self = try allocator.create(ContextImpl);
        errdefer allocator.destroy(self);
        var loop = try event_loop.EventLoop.init(allocator);
        const icon_cache = icon_theme.Cache.init(allocator) catch |err| {
            loop.deinit();
            return err;
        };
        self.* = .{
            .allocator = allocator,
            .loop = loop,
            .resources = resources.Store.init(allocator),
            .icon_cache = icon_cache,
        };
        errdefer self.deinitFields();
        if (options.desktop_settings) {
            self.desktop_settings = DesktopSettings.create(allocator, &self.loop, self, desktopColorSchemeChanged) catch |err| blk: {
                log.warn("desktop settings unavailable: {s}", .{@errorName(err)});
                break :blk null;
            };
        }
        return contextHandle(self);
    }

    pub fn deinit(self: *Context) void {
        contextImpl(self).deinit();
    }

    pub fn eventFd(self: *const Context) i32 {
        return contextConstImpl(self).eventFd();
    }

    pub fn createSurface(self: *Context, options: SurfaceOptions) !*Surface {
        return surfaceHandle(try contextImpl(self).createSurface(options));
    }

    pub fn destroySurface(self: *Context, surface: *Surface) void {
        contextImpl(self).destroySurface(surfaceImpl(surface));
    }

    pub fn dispatch(self: *Context) !void {
        try contextImpl(self).dispatch();
    }

    pub fn nextEvent(self: *Context) ?Event {
        return contextImpl(self).nextEvent();
    }

    pub fn colorScheme(self: *const Context) ColorScheme {
        return contextConstImpl(self).color_scheme;
    }

    pub fn createImageRgba8(self: *Context, width: u32, height: u32, stride_bytes: usize, pixels: []const u8) !ui.ResourceId {
        return contextImpl(self).resources.createRgba8(width, height, stride_bytes, pixels);
    }

    pub fn createAlphaMaskA8(self: *Context, width: u32, height: u32, stride_bytes: usize, pixels: []const u8) !ui.ResourceId {
        return contextImpl(self).resources.createA8(width, height, stride_bytes, pixels);
    }

    pub fn releaseResource(self: *Context, id: ui.ResourceId) void {
        contextImpl(self).resources.releaseHost(id);
    }

    pub fn setIconTheme(self: *Context, theme_name: []const u8) !void {
        try contextImpl(self).setIconTheme(theme_name);
    }
};

/// Opaque surface owned by its context.
pub const Surface = opaque {
    pub fn surfaceId(self: *const Surface) SurfaceId {
        return surfaceConstImpl(self).id;
    }

    pub fn submit(self: *Surface, root: ui.Widget) !DocumentId {
        return surfaceImpl(self).submit(root);
    }

    /// Low-level binding entry point. Official language bindings should
    /// expose typed builders and keep this encoding detail private.
    pub fn submitEncoded(self: *Surface, bytes: []const u8) !DocumentId {
        return surfaceImpl(self).submitEncoded(bytes);
    }

    pub fn invalidate(self: *Surface) !void {
        try surfaceImpl(self).invalidate();
    }
};

const ContextImpl = struct {
    allocator: std.mem.Allocator,
    loop: event_loop.EventLoop,
    resources: resources.Store,
    icon_cache: icon_theme.Cache,
    desktop_settings: ?*DesktopSettings = null,
    color_scheme: ColorScheme = .no_preference,
    surfaces: std.ArrayList(*SurfaceImpl) = .empty,
    events: std.ArrayList(Event) = .empty,
    event_payload_scratch: ?[]u8 = null,
    next_surface_id: SurfaceId = 1,
    next_document_id: DocumentId = 1,
    dispatching: bool = false,
    pending_error: ?anyerror = null,

    fn deinit(self: *ContextImpl) void {
        std.debug.assert(!self.dispatching);
        self.deinitFields();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn deinitFields(self: *ContextImpl) void {
        if (self.desktop_settings) |settings| settings.destroy();
        self.desktop_settings = null;
        while (self.surfaces.pop()) |surface| surface.deinitInternal();
        self.surfaces.deinit(self.allocator);
        self.deinitQueuedEvents();
        self.events.deinit(self.allocator);
        if (self.event_payload_scratch) |scratch| self.allocator.free(scratch);
        self.event_payload_scratch = null;
        self.icon_cache.deinit();
        self.resources.deinit();
        self.loop.deinit();
    }

    /// Stable aggregate descriptor. The host watches it for readability and
    /// calls `dispatch` when ready; Keywork owns every descriptor inside it.
    fn eventFd(self: *const ContextImpl) i32 {
        return self.loop.epoll_fd;
    }

    fn createSurface(self: *ContextImpl, options: SurfaceOptions) !*SurfaceImpl {
        std.debug.assert(!self.dispatching);
        const id = self.next_surface_id;
        self.next_surface_id = std.math.add(SurfaceId, id, 1) catch return error.SurfaceIdExhausted;
        const surface = try SurfaceImpl.init(self, id, options);
        errdefer surface.deinitInternal();
        try self.surfaces.append(self.allocator, surface);
        return surface;
    }

    fn destroySurface(self: *ContextImpl, surface: *SurfaceImpl) void {
        std.debug.assert(!self.dispatching);
        std.debug.assert(surface.context == self);
        for (self.surfaces.items, 0..) |item, index| {
            if (item != surface) continue;
            _ = self.surfaces.swapRemove(index);
            self.removeEventsForSurface(surface.id);
            surface.deinitInternal();
            return;
        }
        unreachable;
    }

    /// Non-blocking dispatch. This never invokes host-language code; all
    /// externally meaningful input is appended to the semantic event queue.
    fn dispatch(self: *ContextImpl) !void {
        if (self.dispatching) return error.ReentrantDispatch;
        self.dispatching = true;
        defer self.dispatching = false;
        for (self.surfaces.items) |surface| surface.beginDispatch();
        errdefer {
            for (self.surfaces.items) |surface| surface.cancelDispatch();
            self.loop.refreshWayland() catch {};
        }

        try self.loop.dispatch(0);
        if (self.desktop_settings) |settings| try settings.dispatchPending();
        for (self.surfaces.items) |surface| {
            try surface.afterDispatch();
        }
        try self.loop.refreshWayland();
        if (self.pending_error) |err| {
            self.pending_error = null;
            return err;
        }
    }

    fn nextEvent(self: *ContextImpl) ?Event {
        if (self.event_payload_scratch) |scratch| self.allocator.free(scratch);
        self.event_payload_scratch = null;
        if (self.events.items.len == 0) return null;
        var event = self.events.orderedRemove(0);
        if (event == .handler and event.handler.payload == .text) {
            const owned = @constCast(event.handler.payload.text);
            self.event_payload_scratch = owned;
            event.handler.payload.text = owned;
        }
        return event;
    }

    fn pushEvent(self: *ContextImpl, event: Event) void {
        self.events.append(self.allocator, event) catch {
            self.deinitEvent(event);
            self.pending_error = error.OutOfMemory;
        };
    }

    fn removeEventsForSurface(self: *ContextImpl, id: SurfaceId) void {
        var index: usize = 0;
        while (index < self.events.items.len) {
            const event_surface = switch (self.events.items[index]) {
                .handler => |event| event.surface,
                .configured => |event| event.surface,
                .closed => |event| event.surface,
                .document_retired => |event| event.surface,
                .appearance_changed => {
                    index += 1;
                    continue;
                },
            };
            if (event_surface == id) {
                self.deinitEvent(self.events.orderedRemove(index));
            } else {
                index += 1;
            }
        }
    }

    fn removeHandlerEventsForDocument(self: *ContextImpl, surface_id: SurfaceId, document_id: DocumentId) void {
        var index: usize = 0;
        while (index < self.events.items.len) {
            const remove = switch (self.events.items[index]) {
                .handler => |event| event.surface == surface_id and event.document == document_id,
                else => false,
            };
            if (remove) self.deinitEvent(self.events.orderedRemove(index)) else index += 1;
        }
    }

    fn deinitQueuedEvents(self: *ContextImpl) void {
        for (self.events.items) |event| self.deinitEvent(event);
        self.events.clearRetainingCapacity();
    }

    fn deinitEvent(self: *ContextImpl, event: Event) void {
        switch (event) {
            .handler => |handler| switch (handler.payload) {
                .text => |text| self.allocator.free(text),
                else => {},
            },
            else => {},
        }
    }

    fn setIconTheme(self: *ContextImpl, theme_name: []const u8) !void {
        try self.icon_cache.setTheme(theme_name);
        for (self.surfaces.items) |surface| try surface.invalidate();
    }

    fn applyColorScheme(self: *ContextImpl, color_scheme: ColorScheme) void {
        if (self.color_scheme == color_scheme) return;
        self.color_scheme = color_scheme;
        for (self.surfaces.items) |surface| {
            surface.runtime.?.setColorScheme(color_scheme) catch |err| {
                if (self.pending_error == null) self.pending_error = err;
            };
        }
        self.pushEvent(.{ .appearance_changed = .{ .color_scheme = color_scheme } });
    }
};

fn desktopColorSchemeChanged(context: *anyopaque, color_scheme: ColorScheme) void {
    const self: *ContextImpl = @ptrCast(@alignCast(context));
    self.applyColorScheme(color_scheme);
}

const SurfaceImpl = struct {
    context: *ContextImpl,
    id: SurfaceId,
    backend: BackendState,
    runtime: ?Runtime = null,
    document: ?document_mod.Document = null,
    document_id: ?DocumentId = null,
    repaint_queued: bool = false,
    repaint_ready: bool = false,
    configured_reported: bool = false,
    closed_reported: bool = false,

    const BackendState = union(Backend) {
        auto: void,
        headless: HeadlessBackend,
        wayland_shm: *wayland_shm.Backend,
        vulkan: *wayland_vulkan.Backend,
    };

    fn init(context: *ContextImpl, id: SurfaceId, options: SurfaceOptions) !*SurfaceImpl {
        if (options.height == 0) return error.InvalidSurfaceSize;
        if (options.width == 0 and (options.backend == .headless or options.layer_shell == null)) {
            return error.InvalidSurfaceSize;
        }
        if (options.width == 0) {
            const anchors = options.layer_shell.?.anchors;
            if (!anchors.left or !anchors.right) return error.InvalidSurfaceSize;
        }
        if (options.backend == .headless and options.layer_shell != null) return error.UnsupportedLayerShell;
        if (options.width > std.math.maxInt(u31) or options.height > std.math.maxInt(u31)) return error.InvalidSurfaceSize;

        const self = try context.allocator.create(SurfaceImpl);
        errdefer context.allocator.destroy(self);
        self.* = .{
            .context = context,
            .id = id,
            .backend = undefined,
        };

        switch (options.backend) {
            .auto => self.backend = createWaylandBackend(context, options, .vulkan) catch |err| blk: {
                if (!canFallbackFromVulkan(err)) return err;
                log.warn("Vulkan backend unavailable, falling back to Wayland SHM: {s}", .{@errorName(err)});
                const fallback = try createWaylandBackend(context, options, .wayland_shm);
                log.info("selected Wayland SHM backend", .{});
                break :blk fallback;
            },
            .headless => self.backend = .{ .headless = .{} },
            .wayland_shm, .vulkan => self.backend = try createWaylandBackend(context, options, options.backend),
        }
        if (options.backend == .auto and self.backend == .vulkan) log.info("selected Vulkan backend", .{});
        errdefer self.destroyBackend();

        const render_backend = switch (self.backend) {
            .auto => unreachable,
            .headless => |*backend| backend.renderBackend(),
            .wayland_shm => |backend| backend.renderBackend(),
            .vulkan => |backend| backend.renderBackend(),
        };
        self.runtime = try Runtime.init(
            context.allocator,
            render_backend,
            .{ .max_width = @floatFromInt(@max(options.width, 1)), .max_height = @floatFromInt(options.height) },
            .{ .ptr = self, .emit_fn = emitHandler },
            context.color_scheme,
        );
        errdefer {
            self.runtime.?.deinit();
            self.runtime = null;
        }
        self.runtime.?.setRepaintScheduler(self, scheduleRepaint);

        switch (self.backend) {
            .auto => unreachable,
            .headless => {},
            .wayland_shm => |backend| try self.attachWaylandBackend(wayland_shm.Backend, backend),
            .vulkan => |backend| try self.attachWaylandBackend(wayland_vulkan.Backend, backend),
        }
        return self;
    }

    fn createWaylandBackend(context: *ContextImpl, options: SurfaceOptions, backend: Backend) !BackendState {
        std.debug.assert(backend == .wayland_shm or backend == .vulkan);
        const title = try context.allocator.dupeZ(u8, options.title);
        defer context.allocator.free(title);
        const app_id = try context.allocator.dupeZ(u8, options.app_id);
        defer context.allocator.free(app_id);
        var namespace: ?[:0]u8 = null;
        defer if (namespace) |value| context.allocator.free(value);
        const layer_shell: ?core.LayerShellOptions = if (options.layer_shell) |layer| blk: {
            namespace = try context.allocator.dupeZ(u8, layer.namespace);
            break :blk .{
                .namespace = namespace.?,
                .layer = @enumFromInt(@intFromEnum(layer.layer)),
                .anchors = @bitCast(layer.anchors),
                .exclusive_zone = layer.exclusive_zone,
                .margin = .{
                    .top = layer.margin.top,
                    .right = layer.margin.right,
                    .bottom = layer.margin.bottom,
                    .left = layer.margin.left,
                },
                .keyboard_interactivity = @enumFromInt(@intFromEnum(layer.keyboard_interactivity)),
            };
        } else null;
        return switch (backend) {
            .wayland_shm => .{ .wayland_shm = try wayland_shm.Backend.create(context.allocator, .{
                .title = title,
                .app_id = app_id,
                .width = @intCast(options.width),
                .height = @intCast(options.height),
                .layer_shell = layer_shell,
            }) },
            .vulkan => .{ .vulkan = try wayland_vulkan.Backend.create(context.allocator, .{
                .title = title,
                .app_id = app_id,
                .width = @intCast(options.width),
                .height = @intCast(options.height),
                .layer_shell = layer_shell,
            }) },
            else => unreachable,
        };
    }

    fn attachWaylandBackend(self: *SurfaceImpl, comptime BackendType: type, backend: *BackendType) !void {
        const runtime = &self.runtime.?;
        backend.setPointerButtonHandler(runtime, Runtime.waylandPointerButton);
        backend.setPointerMoveHandler(runtime, Runtime.waylandPointerMove);
        backend.setCursorShapeHandler(runtime, Runtime.waylandCursorShape);
        backend.setRepaintHandler(self, configured);
        backend.setFrameHandler(runtime, Runtime.waylandFrameDone);
        backend.setKeyHandler(runtime, Runtime.waylandKeyInput);
        backend.setScrollHandler(runtime, Runtime.waylandScroll);
        try self.context.loop.setWayland(.{
            .fd = backend.eventLoopFd(),
            .ctx = backend,
            .prepare = BackendType.eventLoopPrepare,
            .finish = BackendType.eventLoopFinish,
        });
        errdefer self.context.loop.removeWayland(backend.eventLoopFd());
        try backend.installEventTimers(&self.context.loop);
    }

    fn submit(self: *SurfaceImpl, root: ui.Widget) !DocumentId {
        var next = try document_mod.Document.init(self.context.allocator, &self.context.resources, root);
        errdefer next.deinit();
        return self.installDocument(next);
    }

    fn submitEncoded(self: *SurfaceImpl, bytes: []const u8) !DocumentId {
        var next = try document_mod.Document.decode(self.context.allocator, &self.context.resources, bytes);
        errdefer next.deinit();
        return self.installDocument(next);
    }

    fn invalidate(self: *SurfaceImpl) !void {
        try self.runtime.?.invalidate();
    }

    fn installDocument(self: *SurfaceImpl, next: document_mod.Document) !DocumentId {
        const new_id = self.context.next_document_id;
        const following_id = std.math.add(DocumentId, new_id, 1) catch return error.DocumentIdExhausted;
        const previous = self.document;
        const previous_id = self.document_id;
        self.document = next;
        self.document_id = new_id;
        self.runtime.?.setDocument(next.root, new_id, self.renderFactory()) catch |err| {
            self.document = previous;
            self.document_id = previous_id;
            return err;
        };
        self.context.next_document_id = following_id;
        if (previous) |old_value| {
            const old_id = previous_id.?;
            self.context.removeHandlerEventsForDocument(self.id, old_id);
            self.context.pushEvent(.{ .document_retired = .{ .surface = self.id, .document = old_id } });
            var old = old_value;
            old.deinit();
        }
        return new_id;
    }

    fn renderFactory(self: *SurfaceImpl) core.RenderFactory {
        return .{ .ptr = self, .vtable = &.{ .image = renderImage, .icon = renderIcon } };
    }

    fn renderImage(ptr: *anyopaque, allocator: std.mem.Allocator, widget: core.Widget.Image) !core.RenderObject {
        const self: *SurfaceImpl = @ptrCast(@alignCast(ptr));
        return image_render.image(allocator, &self.context.resources, widget);
    }

    fn renderIcon(ptr: *anyopaque, allocator: std.mem.Allocator, widget: core.Widget.Icon) !core.RenderObject {
        const self: *SurfaceImpl = @ptrCast(@alignCast(ptr));
        const file = try self.context.icon_cache.lookup(widget.name, widget.size) orelse return icon_render.missing(allocator, widget.size);
        return icon_render.icon(allocator, file, widget.size, widget.color, self.context.icon_cache.generation);
    }

    fn emitHandler(ptr: *anyopaque, ref: core.HandlerRef, payload: core.EventPayload) anyerror!void {
        const self: *SurfaceImpl = @ptrCast(@alignCast(ptr));
        if (self.document_id != ref.document) return;
        const public_payload: HandlerPayload = switch (payload) {
            .none => .none,
            .bool => |value| .{ .boolean = value },
            .text => |text| .{ .text = try self.context.allocator.dupe(u8, text) },
        };
        self.context.pushEvent(.{ .handler = .{
            .surface = self.id,
            .document = ref.document,
            .handler = ref.handler,
            .payload = public_payload,
        } });
    }

    fn scheduleRepaint(ptr: *anyopaque) !void {
        const self: *SurfaceImpl = @ptrCast(@alignCast(ptr));
        if (self.repaint_queued) return;
        self.repaint_queued = true;
        self.context.loop.wake() catch |err| {
            self.repaint_queued = false;
            return err;
        };
    }

    fn configured(ptr: *anyopaque, size: core.Size) void {
        const self: *SurfaceImpl = @ptrCast(@alignCast(ptr));
        Runtime.waylandConfigure(&self.runtime.?, size);
        self.context.pushEvent(.{ .configured = .{
            .surface = self.id,
            .width = size.width,
            .height = size.height,
        } });
        self.configured_reported = true;
    }

    /// Freeze repaint work that existed before native dispatch. Invalidations
    /// raised by input during this dispatch remain queued for the next turn,
    /// allowing the host to handle semantic events and coalesce its document
    /// update into that repaint.
    fn beginDispatch(self: *SurfaceImpl) void {
        std.debug.assert(!self.repaint_ready);
        self.repaint_ready = self.repaint_queued;
        self.repaint_queued = false;
    }

    fn cancelDispatch(self: *SurfaceImpl) void {
        self.repaint_queued = self.repaint_queued or self.repaint_ready;
        self.repaint_ready = false;
    }

    fn afterDispatch(self: *SurfaceImpl) !void {
        switch (self.backend) {
            .auto => unreachable,
            .headless => {},
            .wayland_shm => |backend| try self.afterWaylandDispatch(backend),
            .vulkan => |backend| try self.afterWaylandDispatch(backend),
        }
        if (self.repaint_ready) {
            self.repaint_ready = false;
            if (!self.closed_reported) {
                self.runtime.?.repaint() catch |err| {
                    self.repaint_queued = true;
                    return err;
                };
            }
        }
    }

    fn afterWaylandDispatch(self: *SurfaceImpl, backend: anytype) !void {
        if (backend.isConfigured() and !self.configured_reported) {
            const size = backend.size();
            self.context.pushEvent(.{ .configured = .{
                .surface = self.id,
                .width = size.width,
                .height = size.height,
            } });
            self.configured_reported = true;
        }
        if (backend.isClosed() and !self.closed_reported) {
            self.context.pushEvent(.{ .closed = .{ .surface = self.id } });
            self.closed_reported = true;
        }
    }

    fn deinitInternal(self: *SurfaceImpl) void {
        if (self.runtime) |*runtime| runtime.deinit();
        self.runtime = null;
        if (self.document) |*document| document.deinit();
        self.document = null;
        self.destroyBackend();
        self.context.allocator.destroy(self);
    }

    fn destroyBackend(self: *SurfaceImpl) void {
        switch (self.backend) {
            .auto => unreachable,
            .headless => {},
            .wayland_shm => |backend| {
                self.context.loop.removeWayland(backend.eventLoopFd());
                backend.removeEventTimers(&self.context.loop);
                backend.destroy();
            },
            .vulkan => |backend| {
                self.context.loop.removeWayland(backend.eventLoopFd());
                backend.removeEventTimers(&self.context.loop);
                backend.destroy();
            },
        }
    }
};

fn canFallbackFromVulkan(err: anyerror) bool {
    return switch (err) {
        error.VulkanLoaderUnavailable,
        error.VulkanLoaderSymbolMissing,
        error.NoSuitableVulkanDevice,
        error.NoSurfaceFormats,
        error.UnsupportedSwapchainUsage,
        error.InitializationFailed,
        error.ExtensionNotPresent,
        error.FeatureNotPresent,
        error.FormatNotSupported,
        error.IncompatibleDriver,
        error.OutOfDeviceMemory,
        => true,
        else => false,
    };
}

fn contextHandle(value: *ContextImpl) *Context {
    return @ptrCast(value);
}

fn contextImpl(value: *Context) *ContextImpl {
    return @ptrCast(@alignCast(value));
}

fn contextConstImpl(value: *const Context) *const ContextImpl {
    return @ptrCast(@alignCast(value));
}

fn surfaceHandle(value: *SurfaceImpl) *Surface {
    return @ptrCast(value);
}

fn surfaceImpl(value: *Surface) *SurfaceImpl {
    return @ptrCast(@alignCast(value));
}

fn surfaceConstImpl(value: *const Surface) *const SurfaceImpl {
    return @ptrCast(@alignCast(value));
}

const HeadlessBackend = struct {
    fn renderBackend(self: *HeadlessBackend) core.RenderBackend {
        return .{ .ptr = self, .vtable = &.{
            .present = present,
            .measure_text = measureText,
            .scale = scale,
        } };
    }

    fn present(_: *anyopaque, _: core.RenderBackend.Frame) !bool {
        return false;
    }

    fn measureText(_: *anyopaque, value: []const u8, style: core.ResolvedTextStyle) !core.Size {
        return .{
            .width = @as(f32, @floatFromInt(value.len)) * style.font_size * 0.5,
            .height = style.font_size,
        };
    }

    fn scale(_: *anyopaque) f32 {
        return 1;
    }
};

test "headless click emits handler event tagged with submitted document" {
    const context = try Context.init(std.testing.allocator, .{ .desktop_settings = false });
    defer context.deinit();
    const surface = try context.createSurface(.{ .backend = .headless, .width = 100, .height = 30 });
    const label = ui.text("click");
    const document_id = try surface.submit(.{ .clickable = .{
        .id = "button",
        .handler = 42,
        .child = &label,
    } });
    try context.dispatch();

    const impl = surfaceImpl(surface);
    try impl.runtime.?.pointerButton(.{ .x = 1, .y = 1 }, .pressed);
    try impl.runtime.?.pointerButton(.{ .x = 1, .y = 1 }, .released);
    const event = context.nextEvent() orelse return error.MissingHandlerEvent;
    try std.testing.expectEqual(@as(ui.HandlerId, 42), event.handler.handler);
    try std.testing.expectEqual(document_id, event.handler.document);
    try std.testing.expectEqual(impl.id, event.handler.surface);
    try std.testing.expectEqual(Event.HandlerPayload.none, event.handler.payload);
}

test "headless semantic button activates on press and from keyboard focus" {
    const context = try Context.init(std.testing.allocator, .{ .desktop_settings = false });
    defer context.deinit();
    const surface = try context.createSurface(.{ .backend = .headless, .width = 100, .height = 40 });
    const label = ui.text("Action");
    const document_id = try surface.submit(ui.button("action", 43, &label));
    try context.dispatch();

    const impl = surfaceImpl(surface);
    try impl.runtime.?.pointerButton(.{ .x = 1, .y = 1 }, .pressed);
    const pressed_event = context.nextEvent() orelse return error.MissingHandlerEvent;
    try std.testing.expectEqual(@as(ui.HandlerId, 43), pressed_event.handler.handler);
    try std.testing.expectEqual(document_id, pressed_event.handler.document);
    try std.testing.expectEqualStrings("action", impl.runtime.?.focused_id.?);

    try impl.runtime.?.keyInput(.enter);
    const keyboard_event = context.nextEvent() orelse return error.MissingHandlerEvent;
    try std.testing.expectEqual(@as(ui.HandlerId, 43), keyboard_event.handler.handler);
    try std.testing.expectEqual(document_id, keyboard_event.handler.document);
}

test "replacement emits document_retired and drops stale queued handler event" {
    const context = try Context.init(std.testing.allocator, .{ .desktop_settings = false });
    defer context.deinit();
    const surface = try context.createSurface(.{ .backend = .headless, .width = 100, .height = 30 });
    const first_label = ui.text("first");
    const first_id = try surface.submit(.{ .clickable = .{ .id = "first", .handler = 1, .child = &first_label } });
    try context.dispatch();

    const impl = surfaceImpl(surface);
    try impl.runtime.?.pointerButton(.{ .x = 1, .y = 1 }, .pressed);
    try impl.runtime.?.pointerButton(.{ .x = 1, .y = 1 }, .released);

    const second_label = ui.text("second");
    const second_id = try surface.submit(.{ .clickable = .{ .id = "second", .handler = 2, .child = &second_label } });
    const event = context.nextEvent() orelse return error.MissingRetiredEvent;
    try std.testing.expectEqual(first_id, event.document_retired.document);
    try std.testing.expectEqual(impl.id, event.document_retired.surface);
    try std.testing.expectEqual(second_id, impl.document_id.?);
    try std.testing.expectEqual(@as(?Event, null), context.nextEvent());
}

test "text payload remains valid until next nextEvent call" {
    const context = try Context.init(std.testing.allocator, .{ .desktop_settings = false });
    defer context.deinit();
    const surface = try context.createSurface(.{ .backend = .headless, .width = 100, .height = 30 });
    const impl = surfaceImpl(surface);
    const document_id = try surface.submit(ui.text("root"));

    try SurfaceImpl.emitHandler(impl, .{ .document = document_id, .handler = 7 }, .{ .text = "hello" });
    const event = context.nextEvent() orelse return error.MissingTextEvent;
    try std.testing.expectEqualStrings("hello", event.handler.payload.text);
    try std.testing.expectEqual(@as(?Event, null), context.nextEvent());
}

test "surface options default to automatic backend selection" {
    const options: SurfaceOptions = .{};
    try std.testing.expectEqual(Backend.auto, options.backend);
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(Backend).@"enum".fields.len);
    try std.testing.expect(canFallbackFromVulkan(error.IncompatibleDriver));
    try std.testing.expect(!canFallbackFromVulkan(error.OutOfMemory));
    try std.testing.expect(!canFallbackFromVulkan(error.NoWlCompositor));
}

test "appearance changes update runtimes and survive surface destruction" {
    const context = try Context.init(std.testing.allocator, .{ .desktop_settings = false });
    defer context.deinit();
    const surface = try context.createSurface(.{ .backend = .headless, .width = 100, .height = 30 });
    const impl = contextImpl(context);

    impl.applyColorScheme(.dark);
    try std.testing.expectEqual(ColorScheme.dark, context.colorScheme());
    try std.testing.expectEqual(ColorScheme.dark, surfaceImpl(surface).runtime.?.color_scheme);

    context.destroySurface(surface);
    const event = context.nextEvent() orelse return error.MissingAppearanceEvent;
    try std.testing.expectEqual(ColorScheme.dark, event.appearance_changed.color_scheme);
}

test "repaint raised during dispatch remains queued for the host's next turn" {
    const context = try Context.init(std.testing.allocator, .{ .desktop_settings = false });
    defer context.deinit();
    const surface = try context.createSurface(.{ .backend = .headless, .width = 100, .height = 30 });
    const impl = surfaceImpl(surface);

    impl.repaint_queued = true;
    impl.beginDispatch();
    try std.testing.expect(impl.repaint_ready);
    try std.testing.expect(!impl.repaint_queued);

    try SurfaceImpl.scheduleRepaint(impl);
    try impl.afterDispatch();
    try std.testing.expect(!impl.repaint_ready);
    try std.testing.expect(impl.repaint_queued);
}
