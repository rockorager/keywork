//! Zig host using the public, typed Keywork API.

const std = @import("std");
const builtin = @import("builtin");
const keywork = @import("keywork");

const increment_handler: keywork.HandlerId = 1;
const use_debug_allocator = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub fn main(_: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (use_debug_allocator) _ = debug_allocator.deinit();
    }
    const allocator = if (use_debug_allocator)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

    var loop = try keywork.Loop.init(allocator);
    defer loop.deinit();
    const context = try keywork.Context.init(allocator, &loop, .{});
    defer context.deinit();
    const surface = try context.createSurface(.{
        .backend = .wayland_shm,
        .title = "Keywork Zig example",
        .app_id = "dev.keywork.ZigExample",
        .width = 480,
        .height = 240,
    });

    var count: u32 = 0;
    var active_document = try submit(surface, count);

    while (true) {
        try loop.dispatch(-1);
        try context.flush();

        while (context.nextEvent()) |event| switch (event) {
            .handler => |handler| if (handler.document == active_document and handler.handler == increment_handler) {
                count += 1;
                active_document = try submit(surface, count);
            },
            .configured => {},
            .appearance_changed => |appearance| std.log.info("desktop color scheme: {s}", .{@tagName(appearance.color_scheme)}),
            .document_retired => |retired| {
                // Applications with per-document registries can clean them up here.
                if (retired.document == active_document) active_document = 0;
            },
            .closed => return,
        };
    }
}

fn submit(surface: *keywork.Surface, count: u32) !keywork.DocumentId {
    var count_buffer: [64]u8 = undefined;
    const count_text = try std.fmt.bufPrint(&count_buffer, "Count: {d}", .{count});

    const heading: keywork.Widget = .{ .text = .{
        .value = "Native Zig host",
        .color = keywork.colors.accent,
        .font_size = 22,
        .role = .title,
    } };
    const value = keywork.ui.text(count_text);
    const button_label: keywork.Widget = .{ .text = .{ .value = "Increment", .role = .label } };
    const button: keywork.Widget = .{ .filled_button = .{
        .key = "increment",
        .id = "increment",
        .handler = increment_handler,
        .child = &button_label,
    } };
    const children = [_]keywork.Widget{ heading, value, button };
    const column: keywork.Widget = .{ .column = .{
        .children = &children,
        .gap = 12,
    } };
    const root: keywork.Widget = .{ .padding = .{
        .insets = keywork.EdgeInsets.all(24),
        .child = &column,
    } };

    // submit copies the borrowed tree and all strings before returning.
    return surface.submit(root);
}
