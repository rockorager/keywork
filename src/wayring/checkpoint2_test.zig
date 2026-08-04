const std = @import("std");
const generated = @import("generated");
const wayring = @import("wayring");

const Fixture = generated.@"test-object";

test "generated checkpoint API and transactional request FD extraction" {
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer _ = std.c.close(pipe_fds[1]);

    const values = try std.testing.allocator.dupe(wayring.wire.Value, &.{
        .{ .string = null },
        .{ .object = null },
        .{ .new_id = .{ .generic = .{ .interface = "other", .version = 2, .id = 4 } } },
        .{ .new_id = .{ .typed = 5 } },
        .{ .uint = 1 },
        .{ .array = "bytes" },
        .{ .fd = pipe_fds[0] },
        .{ .int = 9 },
    });
    var message: wayring.wire.DecodedMessage = .{
        .allocator = std.testing.allocator,
        .descriptor = &Fixture.request_messages[0],
        .body = try std.testing.allocator.alloc(u8, 0),
        .values = values,
    };
    defer message.deinit();

    try std.testing.expectError(error.InvalidRequestValue, Fixture.decodeRequest(0, &message));
    try std.testing.expectEqual(pipe_fds[0], message.values[6].fd.?);

    message.values[7] = .{ .uint = 9 };
    const request: Fixture.Request = try Fixture.decodeRequest(0, &message);
    const owned_fd = request.destroy.descriptor;
    defer _ = std.c.close(owned_fd);
    try std.testing.expect(message.values[6].fd == null);

    var output = wayring.wire.Output.init(std.testing.allocator);
    defer output.deinit();
    try Fixture.@"send:done"(&output, 3, 7, 8, "done", "data", pipe_fds[1]);
    try std.testing.expect((try output.beginSend()) != null);
}
