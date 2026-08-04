//! CLI: `wayring-scanner PROTOCOL.xml [PROTOCOL.xml ...] > bindings.zig`.

const std = @import("std");
const wayring = @import("wayring");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buffer);
        stderr.interface.print("wayring-scanner: {t}\n", .{err}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    var arguments = try init.minimal.args.iterateAllocator(init.gpa);
    defer arguments.deinit();
    _ = arguments.next();
    var models: std.ArrayList(wayring.protocol.Protocol) = .empty;
    defer {
        for (models.items) |*model| model.deinit();
        models.deinit(init.gpa);
    }
    while (arguments.next()) |path| {
        const xml = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(16 * 1024 * 1024)) catch return error.InputReadFailed;
        defer init.gpa.free(xml);
        models.append(init.gpa, wayring.protocol.parse(init.gpa, xml) catch return error.ProtocolParseFailed) catch return error.OutOfMemory;
    }
    if (models.items.len == 0) return error.MissingInput;
    const pointers = try init.gpa.alloc(*const wayring.protocol.Protocol, models.items.len);
    defer init.gpa.free(pointers);
    for (models.items, pointers) |*model, *pointer| pointer.* = model;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    defer stdout.interface.flush() catch {};
    wayring.generator.generate(init.gpa, pointers, &stdout.interface) catch return error.GenerationFailed;
}
