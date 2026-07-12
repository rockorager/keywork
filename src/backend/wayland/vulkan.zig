//! Experimental Wayland/Vulkan render backend.

const std = @import("std");
const keywork = @import("../../ui.zig");
const SharedBackend = @import("backend.zig").Backend;
const VulkanRenderer = @import("vulkan/renderer.zig").Renderer;
const window = @import("window.zig");

const RendererAdapter = struct {
    pub const BackendResources = void;
    pub const WindowResources = VulkanRenderer;
    pub const default_title = "Keywork Vulkan";
    pub const connection_options: window.GlobalNeeds = .{ .outputs = true };

    pub fn initBackend(_: std.mem.Allocator, _: *window.Connection) !BackendResources {}
    pub fn deinitBackend(_: *BackendResources) void {}

    pub fn beforeWindowRendererInit(backend: anytype, protocol: *window.Surface) void {
        protocol.surface.commit();
        _ = backend.connection.display.flush();
    }

    pub fn initWindow(backend: anytype, protocol: *window.Surface) !WindowResources {
        return VulkanRenderer.init(backend.allocator, backend.connection.display, protocol.surface);
    }

    pub fn deinitWindow(_: anytype, renderer: *WindowResources) void {
        renderer.deinit();
    }

    pub fn present(win: anytype, frame: keywork.RenderBackend.Frame) !bool {
        const protocol = &win.protocol;
        const logical_width = try window.frameLogicalWidth(frame, protocol.width);
        const logical_height = try window.frameLogicalHeight(frame, protocol.height);
        const width = try window.scaledFrameDimension(logical_width, protocol.scale);
        const height = try window.scaledFrameDimension(logical_height, protocol.scale);
        protocol.configureBuffer(logical_width, logical_height);
        // Mesa's Wayland WSI commits inside vkQueuePresentKHR.
        try protocol.armFrameCallback();
        const pending = try win.renderer.present(frame.display_list, protocol.scale, width, height);
        if (!pending) return false;
        _ = win.backend.connection.display.flush();
        return true;
    }

    pub fn measureText(win: anytype, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
        return win.renderer.measureText(win.protocol.scale, value, style);
    }

    pub fn textMetrics(win: anytype, font_size: f32) !keywork.TextMetrics {
        return win.renderer.textMetrics(win.protocol.scale, font_size);
    }
};

pub const Backend = SharedBackend(RendererAdapter);
