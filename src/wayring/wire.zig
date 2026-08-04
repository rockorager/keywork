//! Wayland wire descriptors, incremental framing, argument decoding, and
//! transactional output batches.

const std = @import("std");
const builtin = @import("builtin");

const native_endian = builtin.cpu.arch.endian();
const header_size = 8;
pub const max_message_size = std.math.maxInt(u16);

pub const Interface = struct {
    name: []const u8,
    version: u32,
};

pub const Nullability = enum { required, nullable };

pub const ObjectType = struct {
    interface: ?*const Interface = null,
    nullability: Nullability = .required,
};

pub const ArgumentKind = union(enum) {
    int,
    uint,
    fixed,
    string: Nullability,
    object: ObjectType,
    new_id: ?*const Interface,
    array,
    fd,
};

pub const ArgumentDescriptor = struct {
    name: []const u8,
    kind: ArgumentKind,
};

pub const MessageDescriptor = struct {
    name: []const u8,
    since: u32 = 1,
    destructor: bool = false,
    arguments: []const ArgumentDescriptor,
};

pub const GenericNewId = struct {
    interface: []const u8,
    version: u32,
    id: u32,
};

pub const NewId = union(enum) {
    typed: u32,
    generic: GenericNewId,
};

pub const Value = union(enum) {
    int: i32,
    uint: u32,
    fixed: i32,
    string: ?[]const u8,
    object: ?u32,
    new_id: NewId,
    array: []const u8,
    fd: ?std.posix.fd_t,
};

pub const FrameHeader = struct {
    object_id: u32,
    opcode: u16,
    size: u16,
};

pub const DecodedMessage = struct {
    allocator: std.mem.Allocator,
    descriptor: *const MessageDescriptor,
    body: []u8,
    values: []Value,

    /// The descriptor must outlive the decoded message. Strings, arrays, and
    /// generic new-id interface names borrow the message's owned body.
    pub fn deinit(self: *DecodedMessage) void {
        for (self.values) |value| switch (value) {
            .fd => |fd| if (fd) |owned| closeFd(owned),
            else => {},
        };
        self.allocator.free(self.values);
        self.allocator.free(self.body);
        self.* = undefined;
    }

    /// Transfers one decoded descriptor to the caller.
    pub fn takeFd(self: *DecodedMessage, index: usize) !std.posix.fd_t {
        if (index >= self.values.len) return error.InvalidArgumentIndex;
        if (self.values[index] != .fd) return error.ArgumentIsNotFileDescriptor;
        const owned = self.values[index].fd orelse return error.FileDescriptorAlreadyTaken;
        self.values[index].fd = null;
        return owned;
    }
};

/// Ordered byte and file-descriptor input. A successful `receive` transfers
/// ownership of every supplied descriptor. Callers retain ownership on error.
pub const Input = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    byte_offset: usize = 0,
    fds: std.ArrayList(std.posix.fd_t) = .empty,
    fd_offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Input {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Input) void {
        self.closeUnclaimedFds();
        self.bytes.deinit(self.allocator);
        self.fds.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn receive(
        self: *Input,
        bytes: []const u8,
        fds: []const std.posix.fd_t,
    ) !void {
        try self.bytes.ensureUnusedCapacity(self.allocator, bytes.len);
        try self.fds.ensureUnusedCapacity(self.allocator, fds.len);
        self.bytes.appendSliceAssumeCapacity(bytes);
        self.fds.appendSliceAssumeCapacity(fds);
    }

    /// Returns the next complete frame's header without consuming it. The
    /// caller uses the object ID and opcode to select a message descriptor,
    /// then calls `decodeNext` exactly once.
    pub fn peekFrame(self: *Input) !?FrameHeader {
        const available = self.bytes.items[self.byte_offset..];
        if (available.len < header_size) return null;

        const object_id = readU32(available[0..4]);
        const word = readU32(available[4..8]);
        const opcode: u16 = @truncate(word);
        const size: u16 = @truncate(word >> 16);
        if (size < header_size or size % 4 != 0) {
            self.discardAfterFatal();
            return error.InvalidMessageSize;
        }
        if (available.len < size) return null;
        return .{
            .object_id = object_id,
            .opcode = opcode,
            .size = size,
        };
    }

    /// Decodes and consumes the next frame using the descriptor selected by
    /// the caller's object table. Need-more-data and allocation failures leave
    /// it pending for retry. Malformed input discards the connection-level
    /// input and closes all accepted, unclaimed descriptors.
    pub fn decodeNext(
        self: *Input,
        descriptor: *const MessageDescriptor,
    ) !DecodedMessage {
        const header = (try self.peekFrame()) orelse return error.NeedMoreBytes;
        const required_fds = countFds(descriptor.arguments);
        if (self.fds.items.len - self.fd_offset < required_fds) {
            return error.NeedMoreFileDescriptors;
        }

        const available = self.bytes.items[self.byte_offset..];
        const body = try self.allocator.dupe(u8, available[header_size..header.size]);
        errdefer self.allocator.free(body);
        const values = try self.allocator.alloc(Value, descriptor.arguments.len);
        errdefer self.allocator.free(values);

        var cursor: usize = 0;
        var next_fd = self.fd_offset;
        for (descriptor.arguments, values) |argument, *value| {
            value.* = decodeValue(
                body,
                &cursor,
                argument.kind,
                self.fds.items[self.fd_offset..],
                &next_fd,
                self.fd_offset,
            ) catch |err| {
                self.discardAfterFatal();
                return err;
            };
        }
        if (cursor != body.len) {
            self.discardAfterFatal();
            return error.TrailingMessageData;
        }

        self.fd_offset += required_fds;
        self.compactFds();
        self.byte_offset += header.size;
        self.compactBytes();
        return .{
            .allocator = self.allocator,
            .descriptor = descriptor,
            .body = body,
            .values = values,
        };
    }

    fn discardAfterFatal(self: *Input) void {
        self.closeUnclaimedFds();
        self.bytes.clearRetainingCapacity();
        self.byte_offset = 0;
        self.fds.clearRetainingCapacity();
        self.fd_offset = 0;
    }

    fn closeUnclaimedFds(self: *Input) void {
        for (self.fds.items[self.fd_offset..]) |fd| closeFd(fd);
    }

    fn compactBytes(self: *Input) void {
        if (self.byte_offset == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.byte_offset = 0;
            return;
        }
        if (self.byte_offset < 4096 or self.byte_offset < self.bytes.items.len / 2) return;
        const remaining = self.bytes.items[self.byte_offset..];
        std.mem.copyForwards(u8, self.bytes.items[0..remaining.len], remaining);
        self.bytes.shrinkRetainingCapacity(remaining.len);
        self.byte_offset = 0;
    }

    fn compactFds(self: *Input) void {
        if (self.fd_offset == self.fds.items.len) {
            self.fds.clearRetainingCapacity();
            self.fd_offset = 0;
            return;
        }
        if (self.fd_offset < 32 or self.fd_offset < self.fds.items.len / 2) return;
        const remaining = self.fds.items[self.fd_offset..];
        std.mem.copyForwards(std.posix.fd_t, self.fds.items[0..remaining.len], remaining);
        self.fds.shrinkRetainingCapacity(remaining.len);
        self.fd_offset = 0;
    }
};

pub const BatchToken = struct {
    value: u64,
};

pub const SendBatch = struct {
    token: BatchToken,
    bytes: []const u8,
    fds: []const std.posix.fd_t,
};

const QueuedBatch = struct {
    bytes: []u8,
    byte_offset: usize = 0,
    fds: []std.posix.fd_t,
};

/// Ordered output queue. Enqueue duplicates borrowed descriptors before the
/// message becomes visible, making ownership transfer transactional.
pub const Output = struct {
    allocator: std.mem.Allocator,
    batches: std.ArrayList(QueuedBatch) = .empty,
    next_token: u64 = 1,
    in_flight: ?BatchToken = null,

    pub fn init(allocator: std.mem.Allocator) Output {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Output) void {
        for (self.batches.items) |batch| self.freeBatch(batch);
        self.batches.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn enqueue(
        self: *Output,
        object_id: u32,
        opcode: u16,
        descriptor: *const MessageDescriptor,
        values: []const Value,
    ) !void {
        if (values.len != descriptor.arguments.len) return error.ArgumentCountMismatch;

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        try writer.writer.writeAll(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });

        var borrowed_fds: std.ArrayList(std.posix.fd_t) = .empty;
        defer borrowed_fds.deinit(self.allocator);
        for (descriptor.arguments, values) |argument, value| {
            try encodeValue(&writer, &borrowed_fds, argument.kind, value, self.allocator);
        }
        const encoded = writer.written();
        if (encoded.len > max_message_size) return error.MessageTooLarge;
        writeU32(encoded[0..4], object_id);
        writeU32(encoded[4..8], (@as(u32, @intCast(encoded.len)) << 16) | opcode);

        const owned_fds = try self.allocator.alloc(std.posix.fd_t, borrowed_fds.items.len);
        var duplicated: usize = 0;
        errdefer {
            for (owned_fds[0..duplicated]) |fd| closeFd(fd);
            self.allocator.free(owned_fds);
        }
        for (borrowed_fds.items, owned_fds) |fd, *owned| {
            owned.* = try duplicateFd(fd);
            duplicated += 1;
        }

        const bytes = try writer.toOwnedSlice();
        errdefer self.allocator.free(bytes);
        try self.batches.append(self.allocator, .{
            .bytes = bytes,
            .fds = owned_fds,
        });
    }

    /// Begins one send attempt. The returned view remains valid only until
    /// `completeSend` or `deinit`; only one attempt may be in flight.
    pub fn beginSend(self: *Output) !?SendBatch {
        if (self.in_flight != null) return error.SendAlreadyInFlight;
        if (self.batches.items.len == 0) return null;
        if (self.next_token == 0) return error.BatchTokenExhausted;
        const batch = self.batches.items[0];
        const token: BatchToken = .{ .value = self.next_token };
        self.next_token +%= 1;
        self.in_flight = token;
        return .{
            .token = token,
            .bytes = batch.bytes[batch.byte_offset..],
            .fds = batch.fds,
        };
    }

    /// Records a successful send attempt. Any positive byte count consumes
    /// the complete FD payload, even when message bytes remain.
    pub fn completeSend(self: *Output, token: BatchToken, bytes_written: usize) !void {
        if (self.batches.items.len == 0) return error.NoPendingBatch;
        const in_flight = self.in_flight orelse return error.NoSendInFlight;
        if (in_flight.value != token.value) return error.StaleBatchToken;
        const batch = &self.batches.items[0];
        const remaining = batch.bytes.len - batch.byte_offset;
        if (bytes_written > remaining) return error.InvalidWriteCount;
        self.in_flight = null;
        if (bytes_written == 0) return;

        for (batch.fds) |fd| closeFd(fd);
        if (batch.fds.len > 0) self.allocator.free(batch.fds);
        batch.fds = &.{};
        batch.byte_offset += bytes_written;
        if (batch.byte_offset != batch.bytes.len) return;

        const finished = self.batches.orderedRemove(0);
        self.freeBatch(finished);
    }

    fn freeBatch(self: *Output, batch: QueuedBatch) void {
        for (batch.fds) |fd| closeFd(fd);
        if (batch.fds.len > 0) self.allocator.free(batch.fds);
        self.allocator.free(batch.bytes);
    }
};

fn decodeValue(
    body: []const u8,
    cursor: *usize,
    kind: ArgumentKind,
    available_fds: []const std.posix.fd_t,
    next_fd: *usize,
    fd_base: usize,
) !Value {
    return switch (kind) {
        .int => .{ .int = @bitCast(try decodeU32(body, cursor)) },
        .uint => .{ .uint = try decodeU32(body, cursor) },
        .fixed => .{ .fixed = @bitCast(try decodeU32(body, cursor)) },
        .string => |nullability| .{ .string = try decodeString(body, cursor, nullability) },
        .object => |object_type| .{ .object = try decodeObject(body, cursor, object_type.nullability) },
        .new_id => |interface| .{ .new_id = if (interface != null)
            .{ .typed = try decodeRequiredId(body, cursor) }
        else
            .{ .generic = .{
                .interface = (try decodeString(body, cursor, .required)).?,
                .version = try decodeU32(body, cursor),
                .id = try decodeRequiredId(body, cursor),
            } } },
        .array => .{ .array = try decodeArray(body, cursor) },
        .fd => blk: {
            const relative = next_fd.* - fd_base;
            const fd = available_fds[relative];
            next_fd.* += 1;
            break :blk .{ .fd = fd };
        },
    };
}

fn encodeValue(
    writer: *std.Io.Writer.Allocating,
    fds: *std.ArrayList(std.posix.fd_t),
    kind: ArgumentKind,
    value: Value,
    allocator: std.mem.Allocator,
) !void {
    switch (kind) {
        .int => if (value == .int) try encodeU32(writer, @bitCast(value.int)) else return error.ArgumentTypeMismatch,
        .uint => if (value == .uint) try encodeU32(writer, value.uint) else return error.ArgumentTypeMismatch,
        .fixed => if (value == .fixed) try encodeU32(writer, @bitCast(value.fixed)) else return error.ArgumentTypeMismatch,
        .string => |nullability| if (value == .string)
            try encodeString(writer, value.string, nullability)
        else
            return error.ArgumentTypeMismatch,
        .object => |object_type| if (value == .object)
            try encodeObject(writer, value.object, object_type.nullability)
        else
            return error.ArgumentTypeMismatch,
        .new_id => |interface| if (value == .new_id) switch (value.new_id) {
            .typed => |id| {
                if (interface == null) return error.ArgumentTypeMismatch;
                try encodeRequiredId(writer, id);
            },
            .generic => |new_id| {
                if (interface != null) return error.ArgumentTypeMismatch;
                try encodeString(writer, new_id.interface, .required);
                try encodeU32(writer, new_id.version);
                try encodeRequiredId(writer, new_id.id);
            },
        } else return error.ArgumentTypeMismatch,
        .array => if (value == .array) try encodeArray(writer, value.array) else return error.ArgumentTypeMismatch,
        .fd => if (value == .fd) {
            const fd = value.fd orelse return error.MissingFileDescriptor;
            try fds.append(allocator, fd);
        } else return error.ArgumentTypeMismatch,
    }
}

fn decodeU32(body: []const u8, cursor: *usize) !u32 {
    const bytes = try take(body, cursor, 4);
    return readU32(@ptrCast(bytes.ptr));
}

fn decodeRequiredId(body: []const u8, cursor: *usize) !u32 {
    const id = try decodeU32(body, cursor);
    if (id == 0) return error.NullNewId;
    return id;
}

fn decodeObject(body: []const u8, cursor: *usize, nullability: Nullability) !?u32 {
    const id = try decodeU32(body, cursor);
    if (id == 0) {
        if (nullability == .required) return error.NullObject;
        return null;
    }
    return id;
}

fn decodeString(body: []const u8, cursor: *usize, nullability: Nullability) !?[]const u8 {
    const length: usize = @intCast(try decodeU32(body, cursor));
    if (length == 0) {
        if (nullability == .required) return error.NullString;
        return null;
    }
    const padded = try paddedLength(length);
    const bytes = try take(body, cursor, padded);
    const string = bytes[0..length];
    if (string[string.len - 1] != 0) return error.UnterminatedString;
    if (std.mem.indexOfScalar(u8, string[0 .. string.len - 1], 0) != null) return error.InteriorNull;
    return string[0 .. string.len - 1];
}

fn decodeArray(body: []const u8, cursor: *usize) ![]const u8 {
    const length: usize = @intCast(try decodeU32(body, cursor));
    const padded = try paddedLength(length);
    const bytes = try take(body, cursor, padded);
    return bytes[0..length];
}

fn encodeU32(writer: *std.Io.Writer.Allocating, value: u32) !void {
    var bytes: [4]u8 = undefined;
    writeU32(&bytes, value);
    try writer.writer.writeAll(&bytes);
}

fn encodeRequiredId(writer: *std.Io.Writer.Allocating, id: u32) !void {
    if (id == 0) return error.NullNewId;
    try encodeU32(writer, id);
}

fn encodeObject(writer: *std.Io.Writer.Allocating, id: ?u32, nullability: Nullability) !void {
    if (id == null and nullability == .required) return error.NullObject;
    try encodeU32(writer, id orelse 0);
}

fn encodeString(
    writer: *std.Io.Writer.Allocating,
    string: ?[]const u8,
    nullability: Nullability,
) !void {
    const value = string orelse {
        if (nullability == .required) return error.NullString;
        return encodeU32(writer, 0);
    };
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InteriorNull;
    const length = std.math.add(usize, value.len, 1) catch return error.MessageTooLarge;
    if (length > std.math.maxInt(u32)) return error.MessageTooLarge;
    try encodeU32(writer, @intCast(length));
    try writer.writer.writeAll(value);
    try writer.writer.writeByte(0);
    try writePadding(writer, length);
}

fn encodeArray(writer: *std.Io.Writer.Allocating, array: []const u8) !void {
    if (array.len > std.math.maxInt(u32)) return error.MessageTooLarge;
    try encodeU32(writer, @intCast(array.len));
    try writer.writer.writeAll(array);
    try writePadding(writer, array.len);
}

fn writePadding(writer: *std.Io.Writer.Allocating, length: usize) !void {
    const padded = try paddedLength(length);
    const padding = padded - length;
    try writer.writer.splatByteAll(0, padding);
}

fn paddedLength(length: usize) !usize {
    const with_padding = std.math.add(usize, length, 3) catch return error.MessageTooLarge;
    return with_padding & ~@as(usize, 3);
}

fn take(bytes: []const u8, cursor: *usize, length: usize) ![]const u8 {
    const end = std.math.add(usize, cursor.*, length) catch return error.TruncatedArgument;
    if (end > bytes.len) return error.TruncatedArgument;
    defer cursor.* = end;
    return bytes[cursor.*..end];
}

fn countFds(arguments: []const ArgumentDescriptor) usize {
    var count: usize = 0;
    for (arguments) |argument| if (argument.kind == .fd) {
        count += 1;
    };
    return count;
}

fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, native_endian);
}

fn writeU32(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, native_endian);
}

fn duplicateFd(fd: std.posix.fd_t) !std.posix.fd_t {
    const duplicate = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (duplicate < 0) return error.DuplicateFileDescriptor;
    return duplicate;
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

const test_interface: Interface = .{ .name = "wl_test", .version = 3 };
const test_arguments = [_]ArgumentDescriptor{
    .{ .name = "signed", .kind = .int },
    .{ .name = "unsigned", .kind = .uint },
    .{ .name = "fixed", .kind = .fixed },
    .{ .name = "label", .kind = .{ .string = .required } },
    .{ .name = "optional", .kind = .{ .object = .{ .interface = &test_interface, .nullability = .nullable } } },
    .{ .name = "child", .kind = .{ .new_id = &test_interface } },
    .{ .name = "generic", .kind = .{ .new_id = null } },
    .{ .name = "bytes", .kind = .array },
    .{ .name = "descriptor", .kind = .fd },
};
const test_message: MessageDescriptor = .{
    .name = "everything",
    .arguments = &test_arguments,
};

test "framer buffers fragmented and consecutive messages" {
    const allocator = std.testing.allocator;
    var input = Input.init(allocator);
    defer input.deinit();

    const bytes = [_]u8{
        5, 0, 0, 0, 1, 0, 12, 0, 9, 0, 0, 0,
        6, 0, 0, 0, 2, 0, 8,  0,
    };
    try input.receive(bytes[0..6], &.{});
    try std.testing.expect((try input.peekFrame()) == null);
    try input.receive(bytes[6..], &.{});

    const first = (try input.peekFrame()).?;
    try std.testing.expectEqual(@as(u32, 5), first.object_id);
    try std.testing.expectEqual(@as(u16, 1), first.opcode);
    const uint_arguments = [_]ArgumentDescriptor{.{ .name = "value", .kind = .uint }};
    const uint_message: MessageDescriptor = .{ .name = "value", .arguments = &uint_arguments };
    var first_message = try input.decodeNext(&uint_message);
    defer first_message.deinit();
    try std.testing.expectEqual(@as(u32, 9), first_message.values[0].uint);

    const second = (try input.peekFrame()).?;
    try std.testing.expectEqual(@as(u32, 6), second.object_id);
    try std.testing.expectEqual(@as(u16, 2), second.opcode);
    const empty_message: MessageDescriptor = .{ .name = "empty", .arguments = &.{} };
    var second_message = try input.decodeNext(&empty_message);
    defer second_message.deinit();
    try std.testing.expect((try input.peekFrame()) == null);
}

test "encoder and decoder preserve every wire argument and FD order" {
    const allocator = std.testing.allocator;
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer closeFd(pipe_fds[0]);
    defer closeFd(pipe_fds[1]);

    const values = [_]Value{
        .{ .int = -42 },
        .{ .uint = 42 },
        .{ .fixed = -384 },
        .{ .string = "hello" },
        .{ .object = null },
        .{ .new_id = .{ .typed = 7 } },
        .{ .new_id = .{ .generic = .{ .interface = "wl_other", .version = 2, .id = 8 } } },
        .{ .array = &.{ 1, 2, 3 } },
        .{ .fd = pipe_fds[0] },
    };

    var output = Output.init(allocator);
    defer output.deinit();
    try output.enqueue(4, 3, &test_message, &values);
    const batch = (try output.beginSend()).?;
    try std.testing.expectEqual(@as(usize, 1), batch.fds.len);
    try std.testing.expect(batch.fds[0] != pipe_fds[0]);
    const received_duplicate = std.c.fcntl(batch.fds[0], std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (received_duplicate < 0) return error.Unexpected;

    var input = Input.init(allocator);
    defer input.deinit();
    try input.receive(batch.bytes[0..5], &.{received_duplicate});
    try std.testing.expect((try input.peekFrame()) == null);
    try input.receive(batch.bytes[5..], &.{});
    const frame = (try input.peekFrame()).?;
    try std.testing.expectEqual(@as(u32, 4), frame.object_id);
    try std.testing.expectEqual(@as(u16, 3), frame.opcode);

    var decoded = try input.decodeNext(&test_message);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(i32, -42), decoded.values[0].int);
    try std.testing.expectEqual(@as(u32, 42), decoded.values[1].uint);
    try std.testing.expectEqual(@as(i32, -384), decoded.values[2].fixed);
    try std.testing.expectEqualStrings("hello", decoded.values[3].string.?);
    try std.testing.expect(decoded.values[4].object == null);
    try std.testing.expectEqual(@as(u32, 7), decoded.values[5].new_id.typed);
    try std.testing.expectEqualStrings("wl_other", decoded.values[6].new_id.generic.interface);
    try std.testing.expectEqual(@as(u32, 2), decoded.values[6].new_id.generic.version);
    try std.testing.expectEqual(@as(u32, 8), decoded.values[6].new_id.generic.id);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, decoded.values[7].array);

    const received_fd = try decoded.takeFd(8);
    defer closeFd(received_fd);
    try std.testing.expect(received_fd != pipe_fds[0]);

    // The test simulates a successful send after Input has taken ownership of
    // the duplicates. Positive progress must clear ancillary data immediately.
    try output.completeSend(batch.token, 4);
    const remainder = (try output.beginSend()).?;
    try std.testing.expectEqual(@as(usize, 0), remainder.fds.len);
    try output.completeSend(remainder.token, remainder.bytes.len);
    try std.testing.expect((try output.beginSend()) == null);
}

test "decoder waits for ordered FDs without consuming the frame" {
    const arguments = [_]ArgumentDescriptor{.{ .name = "fd", .kind = .fd }};
    const descriptor: MessageDescriptor = .{ .name = "with_fd", .arguments = &arguments };

    var input = Input.init(std.testing.allocator);
    defer input.deinit();
    try input.receive(&.{ 1, 0, 0, 0, 0, 0, 8, 0 }, &.{});
    try std.testing.expectError(error.NeedMoreFileDescriptors, input.decodeNext(&descriptor));
    try std.testing.expectEqual(@as(u32, 1), (try input.peekFrame()).?.object_id);
}

test "malformed frame closes accepted unclaimed FDs" {
    const allocator = std.testing.allocator;
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer closeFd(pipe_fds[1]);

    var input = Input.init(allocator);
    defer input.deinit();
    const malformed = [_]u8{ 1, 0, 0, 0, 0, 0, 7, 0 };
    try input.receive(&malformed, &.{pipe_fds[0]});
    try std.testing.expectError(error.InvalidMessageSize, input.peekFrame());
    try std.testing.expect(std.c.fcntl(pipe_fds[0], std.c.F.GETFD) < 0);
}

test "decoder rejects malformed strings and trailing data" {
    const allocator = std.testing.allocator;
    const arguments = [_]ArgumentDescriptor{.{ .name = "text", .kind = .{ .string = .required } }};
    const descriptor: MessageDescriptor = .{ .name = "text", .arguments = &arguments };

    var input = Input.init(allocator);
    defer input.deinit();
    try input.receive(&.{
        1, 0, 0, 0, 0,   0,   16,  0,
        4, 0, 0, 0, 'b', 'a', 'd', '!',
    }, &.{});
    try std.testing.expectError(error.UnterminatedString, input.decodeNext(&descriptor));

    try input.receive(&.{
        1, 0, 0, 0, 0,   0, 20, 0,
        2, 0, 0, 0, 'x', 0, 0,  0,
        1, 0, 0, 0,
    }, &.{});
    try std.testing.expectError(error.TrailingMessageData, input.decodeNext(&descriptor));
}

test "output validation is transactional" {
    const allocator = std.testing.allocator;
    const arguments = [_]ArgumentDescriptor{.{ .name = "text", .kind = .{ .string = .required } }};
    const descriptor: MessageDescriptor = .{ .name = "text", .arguments = &arguments };
    const values = [_]Value{.{ .string = "bad\x00text" }};

    var output = Output.init(allocator);
    defer output.deinit();
    try std.testing.expectError(error.InteriorNull, output.enqueue(1, 0, &descriptor, &values));
    try std.testing.expect((try output.beginSend()) == null);
}

test "output matches the Wayland header and string wire format" {
    const allocator = std.testing.allocator;
    const arguments = [_]ArgumentDescriptor{.{ .name = "text", .kind = .{ .string = .required } }};
    const descriptor: MessageDescriptor = .{ .name = "text", .arguments = &arguments };
    const values = [_]Value{.{ .string = "hi" }};

    var output = Output.init(allocator);
    defer output.deinit();
    try output.enqueue(9, 2, &descriptor, &values);
    const batch = (try output.beginSend()).?;
    try std.testing.expectEqualSlices(u8, &.{
        9,   0,   0,  0,
        2,   0,   16, 0,
        3,   0,   0,  0,
        'h', 'i', 0,  0,
    }, batch.bytes);
}

test "failed receive leaves file descriptors with the caller" {
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer closeFd(pipe_fds[0]);
    defer closeFd(pipe_fds[1]);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var input = Input.init(failing.allocator());
    defer input.deinit();
    try std.testing.expectError(error.OutOfMemory, input.receive(&.{1}, &.{pipe_fds[0]}));
    try std.testing.expect(std.c.fcntl(pipe_fds[0], std.c.F.GETFD) >= 0);
}

test "multiple FDs retain order within and across messages" {
    const two_fd_arguments = [_]ArgumentDescriptor{
        .{ .name = "first", .kind = .fd },
        .{ .name = "second", .kind = .fd },
    };
    const two_fds: MessageDescriptor = .{ .name = "two", .arguments = &two_fd_arguments };
    const one_fd_arguments = [_]ArgumentDescriptor{.{ .name = "third", .kind = .fd }};
    const one_fd: MessageDescriptor = .{ .name = "one", .arguments = &one_fd_arguments };

    var pipes: [3][2]std.posix.fd_t = undefined;
    for (&pipes) |*pipe_fds| {
        if (std.c.pipe(pipe_fds) != 0) return error.Unexpected;
    }
    defer for (pipes) |pipe_fds| closeFd(pipe_fds[1]);

    var input = Input.init(std.testing.allocator);
    defer input.deinit();
    try input.receive(&.{
        1, 0, 0, 0, 0, 0, 8, 0,
        1, 0, 0, 0, 1, 0, 8, 0,
    }, &.{ pipes[0][0], pipes[1][0], pipes[2][0] });

    var first = try input.decodeNext(&two_fds);
    defer first.deinit();
    const first_fd = try first.takeFd(0);
    defer closeFd(first_fd);
    const second_fd = try first.takeFd(1);
    defer closeFd(second_fd);
    try std.testing.expectEqual(pipes[0][0], first_fd);
    try std.testing.expectEqual(pipes[1][0], second_fd);

    var second = try input.decodeNext(&one_fd);
    defer second.deinit();
    const third_fd = try second.takeFd(0);
    defer closeFd(third_fd);
    try std.testing.expectEqual(pipes[2][0], third_fd);
}

test "decode allocation failure leaves bytes and FDs pending" {
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer closeFd(pipe_fds[1]);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var input = Input.init(failing.allocator());
    defer input.deinit();
    try input.receive(&.{ 1, 0, 0, 0, 0, 0, 8, 0 }, &.{pipe_fds[0]});

    const arguments = [_]ArgumentDescriptor{.{ .name = "fd", .kind = .fd }};
    const descriptor: MessageDescriptor = .{ .name = "fd", .arguments = &arguments };
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, input.decodeNext(&descriptor));
    try std.testing.expectEqual(@as(u32, 1), (try input.peekFrame()).?.object_id);
    try std.testing.expect(std.c.fcntl(pipe_fds[0], std.c.F.GETFD) >= 0);

    failing.fail_index = std.math.maxInt(usize);
    var decoded = try input.decodeNext(&descriptor);
    defer decoded.deinit();
    try std.testing.expectEqual(pipe_fds[0], try decoded.takeFd(0));
    closeFd(pipe_fds[0]);
}

test "malformed arguments close every unclaimed FD" {
    var pipes: [2][2]std.posix.fd_t = undefined;
    for (&pipes) |*pipe_fds| {
        if (std.c.pipe(pipe_fds) != 0) return error.Unexpected;
    }
    defer for (pipes) |pipe_fds| closeFd(pipe_fds[1]);

    const arguments = [_]ArgumentDescriptor{
        .{ .name = "fd", .kind = .fd },
        .{ .name = "text", .kind = .{ .string = .required } },
    };
    const descriptor: MessageDescriptor = .{ .name = "bad", .arguments = &arguments };
    var input = Input.init(std.testing.allocator);
    defer input.deinit();
    try input.receive(&.{
        1, 0, 0, 0, 0,   0,   16,  0,
        4, 0, 0, 0, 'b', 'a', 'd', '!',
    }, &.{ pipes[0][0], pipes[1][0] });
    try std.testing.expectError(error.UnterminatedString, input.decodeNext(&descriptor));
    try std.testing.expect(std.c.fcntl(pipes[0][0], std.c.F.GETFD) < 0);
    try std.testing.expect(std.c.fcntl(pipes[1][0], std.c.F.GETFD) < 0);
}

test "send attempts reject overlap and stale completion tokens" {
    const descriptor: MessageDescriptor = .{ .name = "empty", .arguments = &.{} };
    var output = Output.init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(1, 0, &descriptor, &.{});
    try output.enqueue(1, 1, &descriptor, &.{});

    const first = (try output.beginSend()).?;
    try std.testing.expectError(error.SendAlreadyInFlight, output.beginSend());
    try output.completeSend(first.token, 0);
    const first_retry = (try output.beginSend()).?;
    try std.testing.expect(first.token.value != first_retry.token.value);
    try std.testing.expectError(
        error.InvalidWriteCount,
        output.completeSend(first_retry.token, first_retry.bytes.len + 1),
    );
    try output.completeSend(first_retry.token, 1);
    const first_remainder = (try output.beginSend()).?;
    try std.testing.expect(first_retry.token.value != first_remainder.token.value);
    try std.testing.expectError(error.StaleBatchToken, output.completeSend(first_retry.token, 1));
    try output.completeSend(first_remainder.token, first_remainder.bytes.len);

    const second = (try output.beginSend()).?;
    try std.testing.expectError(error.StaleBatchToken, output.completeSend(first.token, 1));
    try output.completeSend(second.token, second.bytes.len);
    try std.testing.expect((try output.beginSend()) == null);
}

test "generic new-id has the specified expanded wire representation" {
    const arguments = [_]ArgumentDescriptor{.{ .name = "id", .kind = .{ .new_id = null } }};
    const descriptor: MessageDescriptor = .{ .name = "bind", .arguments = &arguments };
    const values = [_]Value{.{
        .new_id = .{ .generic = .{ .interface = "wl_test", .version = 3, .id = 7 } },
    }};

    var output = Output.init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(2, 0, &descriptor, &values);
    const batch = (try output.beginSend()).?;
    try std.testing.expectEqualSlices(u8, &.{
        2,   0,   0,   0, 0,   0,   28,  0,
        8,   0,   0,   0, 'w', 'l', '_', 't',
        'e', 's', 't', 0, 3,   0,   0,   0,
        7,   0,   0,   0,
    }, batch.bytes);
}

test "positive send progress releases every duplicated FD once" {
    const arguments = [_]ArgumentDescriptor{
        .{ .name = "first", .kind = .fd },
        .{ .name = "second", .kind = .fd },
    };
    const descriptor: MessageDescriptor = .{ .name = "fds", .arguments = &arguments };
    var pipes: [2][2]std.posix.fd_t = undefined;
    for (&pipes) |*pipe_fds| {
        if (std.c.pipe(pipe_fds) != 0) return error.Unexpected;
    }
    defer for (pipes) |pipe_fds| {
        closeFd(pipe_fds[0]);
        closeFd(pipe_fds[1]);
    };

    var output = Output.init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(1, 0, &descriptor, &.{
        .{ .fd = pipes[0][0] },
        .{ .fd = pipes[1][0] },
    });
    const first = (try output.beginSend()).?;
    try std.testing.expectEqual(@as(usize, 2), first.fds.len);
    const duplicates = [2]std.posix.fd_t{ first.fds[0], first.fds[1] };
    try output.completeSend(first.token, 1);
    try std.testing.expect(std.c.fcntl(duplicates[0], std.c.F.GETFD) < 0);
    try std.testing.expect(std.c.fcntl(duplicates[1], std.c.F.GETFD) < 0);

    const remainder = (try output.beginSend()).?;
    try std.testing.expectEqual(@as(usize, 0), remainder.fds.len);
    // Teardown owns the remaining bytes but has no descriptors left to close.
}

test "FD duplication failure rolls back earlier duplicates" {
    const arguments = [_]ArgumentDescriptor{
        .{ .name = "valid", .kind = .fd },
        .{ .name = "invalid", .kind = .fd },
    };
    const descriptor: MessageDescriptor = .{ .name = "fds", .arguments = &arguments };
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer closeFd(pipe_fds[0]);
    defer closeFd(pipe_fds[1]);

    const before = try countOpenFds();
    var output = Output.init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.DuplicateFileDescriptor, output.enqueue(
        1,
        0,
        &descriptor,
        &.{ .{ .fd = pipe_fds[0] }, .{ .fd = -1 } },
    ));
    try std.testing.expect((try output.beginSend()) == null);
    try std.testing.expectEqual(before, try countOpenFds());
    try std.testing.expect(std.c.fcntl(pipe_fds[0], std.c.F.GETFD) >= 0);
}

fn countOpenFds() !usize {
    var directory = try std.Io.Dir.openDirAbsolute(std.testing.io, "/proc/self/fd", .{ .iterate = true });
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}
