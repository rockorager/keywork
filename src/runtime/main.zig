//! Keywork runtime binary: embeds LuaJIT and runs a Lua application.

const std = @import("std");
const keywork = @import("keywork");
const Runtime = @import("runtime.zig");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next(); // program name
    const script = args.next() orelse {
        std.log.err("usage: keywork <app.lua>", .{});
        std.process.exit(1);
    };

    var loop = try keywork.Loop.init(init.gpa);
    defer loop.deinit();
    const runtime = try Runtime.create(init.gpa, &loop);
    defer runtime.destroy();

    runtime.vm.runFile(script) catch |err| {
        std.log.err("{s}", .{runtime.vm.lastError()});
        return err;
    };
    try runtime.run();
}

test {
    _ = @import("vm.zig");
    _ = @import("widget_tree.zig");
    _ = @import("runtime.zig");
    _ = @import("kw.zig");
}
