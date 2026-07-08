//! Keywork runtime binary: embeds LuaJIT and runs a Lua application.

const std = @import("std");
const Vm = @import("vm.zig");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next(); // program name
    const script = args.next() orelse {
        std.log.err("usage: keywork <app.lua>", .{});
        std.process.exit(1);
    };

    var vm = try Vm.init();
    defer vm.deinit();
    vm.runFile(script) catch |err| {
        std.log.err("{s}", .{vm.lastError()});
        return err;
    };
}

test {
    _ = @import("vm.zig");
}
