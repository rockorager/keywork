//! Text log render backend.

const std = @import("std");
const ui = @import("../ui.zig");

pub const LogBackend = struct {
    writer: *std.Io.Writer,

    pub fn backend(self: *LogBackend) ui.RenderBackend {
        return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
    }

    fn present(ptr: *anyopaque, frame: ui.RenderBackend.Frame) !bool {
        const self: *LogBackend = @ptrCast(@alignCast(ptr));
        try self.writer.print("frame {d}x{d} scale {d} commands {d}\n", .{
            frame.size.width,
            frame.size.height,
            frame.scale,
            frame.display_list.len,
        });
        for (frame.display_list) |command| {
            switch (command) {
                .fill_rect => |fill| try self.writer.print(
                    "fill_rect x={d} y={d} w={d} h={d} color=#{x:0>8}\n",
                    .{ fill.rect.x, fill.rect.y, fill.rect.width, fill.rect.height, @as(u32, @bitCast(fill.color)) },
                ),
                .text => |run| try self.writer.print(
                    "text x={d} y={d} value=\"{s}\" color=#{x:0>8} size={d}\n",
                    .{ run.origin.x, run.origin.y, run.value, @as(u32, @bitCast(run.style.color)), run.style.font_size },
                ),
                .alpha_image => |image| try self.writer.print(
                    "alpha_image x={d} y={d} w={d} h={d} pixels={d}x{d} color=#{x:0>8}\n",
                    .{ image.rect.x, image.rect.y, image.rect.width, image.rect.height, image.width, image.height, @as(u32, @bitCast(image.color)) },
                ),
                .color_image => |image| try self.writer.print(
                    "color_image x={d} y={d} w={d} h={d} pixels={d}x{d}\n",
                    .{ image.rect.x, image.rect.y, image.rect.width, image.rect.height, image.width, image.height },
                ),
                .set_clip => |clip| if (clip) |rect| {
                    try self.writer.print(
                        "set_clip x={d} y={d} w={d} h={d}\n",
                        .{ rect.x, rect.y, rect.width, rect.height },
                    );
                } else {
                    try self.writer.print("set_clip none\n", .{});
                },
            }
        }
        return false;
    }

    fn measureText(_: *anyopaque, value: []const u8, style: ui.ResolvedTextStyle) !ui.Size {
        const measurer: ui.TextMeasurer = .fixed;
        return measurer.measureText(value, style);
    }

    fn scale(_: *anyopaque) f32 {
        return 1;
    }
};
