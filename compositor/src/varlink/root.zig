//! Generic Varlink wire framing, encoding, and synchronous client.

const std = @import("std");

pub const service_interface_name = "org.varlink.service";
pub const service_interface_description =
    \\interface org.varlink.service
    \\method GetInfo () -> (vendor: string, product: string, version: string, url: string, interfaces: []string)
    \\method GetInterfaceDescription (interface: string) -> (description: string)
    \\error InterfaceNotFound (interface: string)
    \\error MethodNotFound (method: string)
    \\error MethodNotImplemented (method: string)
    \\error InvalidParameter (parameter: string)
    \\error PermissionDenied ()
    \\error ExpectedMore ()
;

pub const Call = struct {
    method: []const u8,
    parameters: ?std.json.Value = null,
    oneway: bool = false,
    more: bool = false,
    upgrade: bool = false,
};

pub const Reply = struct {
    parameters: ?std.json.Value = null,
    @"error": ?[]const u8 = null,
    continues: bool = false,
};

pub const Client = struct {
    const maximum_message_size = 1024 * 1024;

    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,

    pub fn connect(allocator: std.mem.Allocator, io: std.Io, address: []const u8) !Client {
        const prefix = "unix:";
        if (!std.mem.startsWith(u8, address, prefix)) return error.UnsupportedAddress;
        const path = address[prefix.len..];
        if (!std.fs.path.isAbsolute(path)) return error.InvalidAddress;
        const unix_address = try std.Io.net.UnixAddress.init(path);
        return .{ .allocator = allocator, .io = io, .stream = try unix_address.connect(io) };
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
        self.* = undefined;
    }

    pub fn call(self: *Client, method: []const u8, parameters: anytype) !std.json.Parsed(Reply) {
        var request: std.ArrayList(u8) = .empty;
        defer request.deinit(self.allocator);
        try encode(self.allocator, &request, .{ .method = method, .parameters = parameters }, maximum_message_size);

        var write_buffer: [4096]u8 = undefined;
        var stream_writer = self.stream.writer(self.io, &write_buffer);
        try stream_writer.interface.writeAll(request.items);
        try stream_writer.interface.flush();

        const read_buffer = try self.allocator.alloc(u8, maximum_message_size + 1);
        defer self.allocator.free(read_buffer);
        var stream_reader = self.stream.reader(self.io, read_buffer);
        const message = try stream_reader.interface.takeSentinel(0);
        if (message.len == 0) return error.InvalidFrame;
        return std.json.parseFromSlice(Reply, self.allocator, message, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
    }

    pub fn notify(self: *Client, method: []const u8, parameters: anytype) !void {
        var request: std.ArrayList(u8) = .empty;
        defer request.deinit(self.allocator);
        try encode(self.allocator, &request, .{
            .method = method,
            .parameters = parameters,
            .oneway = true,
        }, maximum_message_size);

        var write_buffer: [4096]u8 = undefined;
        var stream_writer = self.stream.writer(self.io, &write_buffer);
        try stream_writer.interface.writeAll(request.items);
        try stream_writer.interface.flush();
    }
};

pub const FrameIterator = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) FrameIterator {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *FrameIterator) !?[]const u8 {
        const relative_end = std.mem.indexOfScalar(u8, self.bytes[self.offset..], 0) orelse return null;
        const end = self.offset + relative_end;
        if (end == self.offset) return error.InvalidFrame;
        const frame = self.bytes[self.offset..end];
        self.offset = end + 1;
        return frame;
    }

    pub fn consumed(self: FrameIterator) usize {
        return self.offset;
    }
};

pub fn encode(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: anytype,
    maximum_output_size: usize,
) !void {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &writer.writer);
    try writer.writer.writeByte(0);
    if (writer.written().len > maximum_output_size -| output.items.len) return error.OutputTooLarge;
    try output.appendSlice(allocator, writer.written());
}

test "frame iterator handles coalesced and incomplete frames" {
    var iterator: FrameIterator = .init("one\x00two\x00partial");
    try std.testing.expectEqualStrings("one", (try iterator.next()).?);
    try std.testing.expectEqualStrings("two", (try iterator.next()).?);
    try std.testing.expect((try iterator.next()) == null);
    try std.testing.expectEqual(@as(usize, 8), iterator.consumed());

    var invalid: FrameIterator = .init("\x00");
    try std.testing.expectError(error.InvalidFrame, invalid.next());
}

test "encoding appends JSON and NUL within caller bound" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &output, .{ .answer = @as(u8, 42) }, 14);
    try std.testing.expectEqualStrings("{\"answer\":42}\x00", output.items);
    try std.testing.expectError(
        error.OutputTooLarge,
        encode(std.testing.allocator, &output, .{ .ok = true }, output.items.len + 1),
    );
}

test "oneway calls encode without requiring a reply" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &output, .{
        .method = "example.Quit",
        .parameters = struct {}{},
        .oneway = true,
    }, 1024);
    try std.testing.expectEqualStrings(
        "{\"method\":\"example.Quit\",\"parameters\":{},\"oneway\":true}\x00",
        output.items,
    );
}
