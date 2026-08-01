//! Sans-I/O Wayland wire framing, validation, object metadata, and send queues.
//!
//! `Connection` owns every byte and file descriptor passed to it. A successful
//! `feed` transfers ownership of all supplied descriptors, including when a
//! complete message has not arrived yet. Messages and outbound batches are
//! pulled explicitly; no user code runs while parsing input.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const native_endian = builtin.cpu.arch.endian();

pub const max_fds_per_batch: usize = 28;
pub const default_max_frame_size: usize = 1024 * 1024;

pub const Role = enum { client, server };
pub const ArgumentKind = enum { int, uint, fixed, string, object, new_id, array, fd };

pub const ArgumentSpec = struct {
    kind: ArgumentKind,
    nullable: bool = false,
    /// Wayland strings are normally protocol text and therefore UTF-8. Set
    /// false only for a protocol contract which explicitly carries bytes.
    validate_utf8: bool = true,
};

pub const MessageDescriptor = struct {
    name: []const u8,
    opcode: u16,
    since: u32 = 1,
    args: []const ArgumentSpec = &.{},

    pub fn fdCount(self: *const MessageDescriptor) usize {
        var count: usize = 0;
        for (self.args) |arg| if (arg.kind == .fd) {
            count += 1;
        };
        return count;
    }
};

pub const Interface = struct {
    name: []const u8,
    version: u32,
    requests: []const MessageDescriptor = &.{},
    events: []const MessageDescriptor = &.{},

    pub fn incoming(self: *const Interface, role: Role, opcode: u16) ?*const MessageDescriptor {
        return find(if (role == .client) self.events else self.requests, opcode);
    }

    pub fn outgoing(self: *const Interface, role: Role, opcode: u16) ?*const MessageDescriptor {
        return find(if (role == .client) self.requests else self.events, opcode);
    }

    fn find(table: []const MessageDescriptor, opcode: u16) ?*const MessageDescriptor {
        for (table) |*message| if (message.opcode == opcode) return message;
        return null;
    }
};

pub const Object = struct { interface: *const Interface, version: u32, generation: u64 };

pub const Value = union(ArgumentKind) {
    int: i32,
    uint: u32,
    fixed: i32,
    string: ?[]const u8,
    object: ?u32,
    new_id: u32,
    array: ?[]const u8,
    fd: usize,
};

pub const OutValue = union(ArgumentKind) {
    int: i32,
    uint: u32,
    fixed: i32,
    string: ?[]const u8,
    object: ?u32,
    new_id: u32,
    array: ?[]const u8,
    /// Ownership transfers to the connection only when `queue` succeeds.
    fd: i32,
};

pub const Message = struct {
    allocator: std.mem.Allocator,
    object_id: u32,
    descriptor: *const MessageDescriptor,
    payload: []u8,
    values: []Value,
    fds: []i32,

    pub fn takeFd(self: *Message, argument_index: usize) !i32 {
        if (argument_index >= self.values.len or self.values[argument_index] != .fd)
            return error.NotFdArgument;
        const index = self.values[argument_index].fd;
        const fd = self.fds[index];
        if (fd < 0) return error.FdAlreadyTaken;
        self.fds[index] = -1;
        return fd;
    }

    pub fn deinit(self: *Message) void {
        closeAll(self.fds);
        self.allocator.free(self.fds);
        self.allocator.free(self.values);
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

const OutFrame = struct { bytes: []u8, offset: usize = 0, fds: []i32 };

pub const OutboundBatch = struct {
    token: u64,
    bytes: []const u8,
    /// These descriptors accompany the first byte only. A positive send result
    /// retires all of them, exactly matching SCM_RIGHTS/sendmsg semantics.
    fds: []const i32,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    role: Role,
    max_frame_size: usize,
    objects: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    next_generation: u64 = 1,
    input: std.ArrayList(u8) = .empty,
    input_fds: std.ArrayList(i32) = .empty,
    messages: std.ArrayList(Message) = .empty,
    outbound: std.ArrayList(OutFrame) = .empty,
    batch_live: bool = false,
    batch_token: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, role: Role, max_frame_size: usize) Connection {
        return .{ .allocator = allocator, .role = role, .max_frame_size = max_frame_size };
    }

    pub fn deinit(self: *Connection) void {
        for (self.messages.items) |*message| message.deinit();
        self.messages.deinit(self.allocator);
        closeAll(self.input_fds.items);
        self.input_fds.deinit(self.allocator);
        self.input.deinit(self.allocator);
        for (self.outbound.items) |frame| {
            closeAll(frame.fds);
            self.allocator.free(frame.fds);
            self.allocator.free(frame.bytes);
        }
        self.outbound.deinit(self.allocator);
        self.objects.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn registerObject(self: *Connection, id: u32, interface: *const Interface, version: u32) !u64 {
        if (id == 0 or version == 0 or version > interface.version) return error.InvalidObject;
        if (self.objects.contains(id)) return error.ObjectExists;
        const generation = self.next_generation;
        self.next_generation += 1;
        try self.objects.put(self.allocator, id, .{ .interface = interface, .version = version, .generation = generation });
        return generation;
    }

    pub fn removeObject(self: *Connection, id: u32, generation: ?u64) !void {
        const registered = self.objects.get(id) orelse return error.UnknownObject;
        if (generation) |expected| if (expected != registered.generation) return error.StaleObject;
        _ = self.objects.remove(id);
    }

    pub fn object(self: *const Connection, id: u32) ?Object {
        return self.objects.get(id);
    }

    /// The connection consumes every descriptor in `fds` on every return path.
    /// Protocol errors are connection-fatal, but already accepted descriptors
    /// remain owned here so callers never need to distinguish parse failures
    /// from allocation failures to clean them up correctly.
    pub fn feed(self: *Connection, bytes: []const u8, fds: []const i32) !void {
        self.input.ensureUnusedCapacity(self.allocator, bytes.len) catch |err| {
            closeAll(fds);
            return err;
        };
        self.input_fds.ensureUnusedCapacity(self.allocator, fds.len) catch |err| {
            closeAll(fds);
            return err;
        };
        self.input.appendSliceAssumeCapacity(bytes);
        self.input_fds.appendSliceAssumeCapacity(fds);
        try self.parseAvailable();
    }

    pub fn popMessage(self: *Connection) ?Message {
        if (self.messages.items.len == 0) return null;
        return self.messages.orderedRemove(0);
    }

    fn parseAvailable(self: *Connection) !void {
        while (self.input.items.len >= 8) {
            const object_id = readU32(self.input.items[0..4]);
            const word = readU32(self.input.items[4..8]);
            const size: usize = word >> 16;
            const opcode: u16 = @truncate(word);
            if (size < 8) return error.InvalidFrameSize;
            if (size & 3 != 0) return error.UnalignedFrame;
            if (size > self.max_frame_size or size > std.math.maxInt(u16)) return error.FrameTooLarge;
            const registered = self.objects.get(object_id) orelse return error.UnknownObject;
            const descriptor = registered.interface.incoming(self.role, opcode) orelse return error.UnknownOpcode;
            if (descriptor.since > registered.version) return error.UnsupportedVersion;
            if (self.input.items.len < size) return;
            const fd_count = descriptor.fdCount();
            // Validate bytes before waiting for FDs, but consume neither. This
            // lets a later feed supply descriptors without desynchronization.
            try validatePayload(descriptor, self.input.items[8..size]);
            if (self.input_fds.items.len < fd_count) return;

            const payload = try self.allocator.dupe(u8, self.input.items[8..size]);
            errdefer self.allocator.free(payload);
            const values = try decodePayload(self.allocator, descriptor, payload);
            errdefer self.allocator.free(values);
            const owned_fds = try self.allocator.alloc(i32, fd_count);
            errdefer self.allocator.free(owned_fds);
            @memcpy(owned_fds, self.input_fds.items[0..fd_count]);
            try self.messages.append(self.allocator, .{
                .allocator = self.allocator,
                .object_id = object_id,
                .descriptor = descriptor,
                .payload = payload,
                .values = values,
                .fds = owned_fds,
            });
            consumeFront(u8, &self.input, size);
            consumeFront(i32, &self.input_fds, fd_count);
        }
    }

    pub fn queue(self: *Connection, object_id: u32, opcode: u16, values: []const OutValue) !void {
        if (self.batch_live) return error.BatchLive;
        const registered = self.objects.get(object_id) orelse return error.UnknownObject;
        const descriptor = registered.interface.outgoing(self.role, opcode) orelse return error.UnknownOpcode;
        if (descriptor.since > registered.version) return error.UnsupportedVersion;
        if (values.len != descriptor.args.len) return error.SignatureMismatch;
        if (descriptor.fdCount() > max_fds_per_batch) return error.TooManyFds;

        try validateEncodedSize(descriptor, values, self.max_frame_size);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        var fds: std.ArrayList(i32) = .empty;
        defer fds.deinit(self.allocator);
        for (descriptor.args, values) |spec, value| try encodeValue(self.allocator, &body, &fds, spec, value);
        const size = body.items.len + 8;
        if (size > self.max_frame_size or size > std.math.maxInt(u16)) return error.FrameTooLarge;
        const bytes = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(bytes);
        writeU32(bytes[0..4], object_id);
        writeU32(bytes[4..8], (@as(u32, @intCast(size)) << 16) | opcode);
        @memcpy(bytes[8..], body.items);
        const owned_fds = try self.allocator.dupe(i32, fds.items);
        errdefer self.allocator.free(owned_fds);
        try self.outbound.append(self.allocator, .{ .bytes = bytes, .fds = owned_fds });
    }

    pub fn nextBatch(self: *Connection) ?OutboundBatch {
        if (self.batch_live or self.outbound.items.len == 0) return null;
        self.batch_token +%= 1;
        if (self.batch_token == 0) self.batch_token = 1;
        self.batch_live = true;
        const frame = &self.outbound.items[0];
        return .{ .token = self.batch_token, .bytes = frame.bytes[frame.offset..], .fds = frame.fds };
    }

    /// `written == null` is sendmsg failure: nothing changes. Zero is also no
    /// progress. Any positive count transfers all batch FDs and advances only
    /// that many bytes. The token rejects stale or duplicate acknowledgements.
    pub fn acknowledge(self: *Connection, token: u64, written: ?usize) !void {
        if (!self.batch_live or token != self.batch_token) return error.InvalidBatch;
        const frame = &self.outbound.items[0];
        if (written) |count| if (count > frame.bytes.len - frame.offset) return error.InvalidWriteCount;
        self.batch_live = false;
        const count = written orelse return;
        if (count == 0) return;
        closeAll(frame.fds);
        self.allocator.free(frame.fds);
        frame.fds = &.{};
        frame.offset += count;
        if (frame.offset == frame.bytes.len) {
            self.allocator.free(frame.bytes);
            _ = self.outbound.orderedRemove(0);
        }
    }
};

fn validatePayload(descriptor: *const MessageDescriptor, payload: []const u8) !void {
    var offset: usize = 0;
    for (descriptor.args) |spec| switch (spec.kind) {
        .int, .uint, .fixed, .object, .new_id => {
            if (offset + 4 > payload.len) return error.TruncatedArgument;
            const value = readU32(payload[offset..][0..4]);
            if ((spec.kind == .object and !spec.nullable and value == 0) or (spec.kind == .new_id and value == 0)) return error.NullNotAllowed;
            offset += 4;
        },
        .fd => {},
        .string, .array => {
            if (offset + 4 > payload.len) return error.TruncatedArgument;
            const length: usize = readU32(payload[offset..][0..4]);
            offset += 4;
            if (length > payload.len - offset) return error.TruncatedArgument;
            const padded = std.mem.alignForward(usize, length, 4);
            if (padded > payload.len - offset) return error.TruncatedArgument;
            for (payload[offset + length .. offset + padded]) |byte| if (byte != 0) return error.NonzeroPadding;
            if (spec.kind == .string) {
                if (length == 0) {
                    if (!spec.nullable) return error.NullNotAllowed;
                } else {
                    if (payload[offset + length - 1] != 0) return error.UnterminatedString;
                    if (spec.validate_utf8 and !std.unicode.utf8ValidateSlice(payload[offset .. offset + length - 1])) return error.InvalidUtf8;
                }
            }
            offset += padded;
        },
    };
    if (offset != payload.len) return error.TrailingData;
}

fn decodePayload(allocator: std.mem.Allocator, descriptor: *const MessageDescriptor, payload: []u8) ![]Value {
    const values = try allocator.alloc(Value, descriptor.args.len);
    var offset: usize = 0;
    var fd_index: usize = 0;
    for (descriptor.args, values) |spec, *value| switch (spec.kind) {
        .int => {
            value.* = .{ .int = @bitCast(readU32(payload[offset..][0..4])) };
            offset += 4;
        },
        .uint => {
            value.* = .{ .uint = readU32(payload[offset..][0..4]) };
            offset += 4;
        },
        .fixed => {
            value.* = .{ .fixed = @bitCast(readU32(payload[offset..][0..4])) };
            offset += 4;
        },
        .object => {
            const v = readU32(payload[offset..][0..4]);
            value.* = .{ .object = if (v == 0) null else v };
            offset += 4;
        },
        .new_id => {
            value.* = .{ .new_id = readU32(payload[offset..][0..4]) };
            offset += 4;
        },
        .fd => {
            value.* = .{ .fd = fd_index };
            fd_index += 1;
        },
        .string, .array => {
            const length: usize = readU32(payload[offset..][0..4]);
            offset += 4;
            if (spec.kind == .string) {
                value.* = .{ .string = if (length == 0) null else payload[offset .. offset + length - 1] };
            } else {
                value.* = .{ .array = if (length == 0 and spec.nullable) null else payload[offset .. offset + length] };
            }
            offset += std.mem.alignForward(usize, length, 4);
        },
    };
    return values;
}

fn encodeValue(allocator: std.mem.Allocator, body: *std.ArrayList(u8), fds: *std.ArrayList(i32), spec: ArgumentSpec, value: OutValue) !void {
    if (@as(ArgumentKind, value) != spec.kind) return error.SignatureMismatch;
    switch (value) {
        .int => |v| try appendU32(allocator, body, @bitCast(v)),
        .uint => |v| try appendU32(allocator, body, v),
        .fixed => |v| try appendU32(allocator, body, @bitCast(v)),
        .object => |v| {
            if (v == null and !spec.nullable) return error.NullNotAllowed;
            try appendU32(allocator, body, v orelse 0);
        },
        .new_id => |v| {
            if (v == 0) return error.NullNotAllowed;
            try appendU32(allocator, body, v);
        },
        .fd => |v| try fds.append(allocator, v),
        .string => |v| {
            if (v == null) {
                if (!spec.nullable) return error.NullNotAllowed;
                try appendU32(allocator, body, 0);
                return;
            }
            const text = v.?;
            if (spec.validate_utf8 and !std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
            if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
            try appendU32(allocator, body, @intCast(text.len + 1));
            try body.appendSlice(allocator, text);
            try body.append(allocator, 0);
            try pad(allocator, body);
        },
        .array => |v| {
            if (v == null) {
                if (!spec.nullable) return error.NullNotAllowed;
                try appendU32(allocator, body, 0);
                return;
            }
            try appendU32(allocator, body, @intCast(v.?.len));
            try body.appendSlice(allocator, v.?);
            try pad(allocator, body);
        },
    }
}

fn validateEncodedSize(descriptor: *const MessageDescriptor, values: []const OutValue, max_frame_size: usize) !void {
    var size: usize = 8;
    for (descriptor.args, values) |spec, value| {
        if (@as(ArgumentKind, value) != spec.kind) return error.SignatureMismatch;
        const argument_size: usize = switch (value) {
            .int, .uint, .fixed, .object, .new_id => 4,
            .fd => 0,
            .string => |text| blk: {
                if (text == null) {
                    if (!spec.nullable) return error.NullNotAllowed;
                    break :blk 4;
                }
                if (text.?.len >= std.math.maxInt(u32)) return error.FrameTooLarge;
                break :blk 4 + std.mem.alignForward(usize, text.?.len + 1, 4);
            },
            .array => |bytes| blk: {
                if (bytes == null) {
                    if (!spec.nullable) return error.NullNotAllowed;
                    break :blk 4;
                }
                if (bytes.?.len > std.math.maxInt(u32)) return error.FrameTooLarge;
                break :blk 4 + std.mem.alignForward(usize, bytes.?.len, 4);
            },
        };
        size = std.math.add(usize, size, argument_size) catch return error.FrameTooLarge;
        if (size > max_frame_size or size > std.math.maxInt(u16)) return error.FrameTooLarge;
    }
}

fn pad(allocator: std.mem.Allocator, list: *std.ArrayList(u8)) !void {
    while (list.items.len & 3 != 0) try list.append(allocator, 0);
}
fn appendU32(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: u32) !void {
    var b: [4]u8 = undefined;
    writeU32(&b, value);
    try list.appendSlice(allocator, &b);
}
fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, native_endian);
}
fn writeU32(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, native_endian);
}
fn consumeFront(comptime T: type, list: *std.ArrayList(T), count: usize) void {
    std.mem.copyForwards(T, list.items[0 .. list.items.len - count], list.items[count..]);
    list.items.len -= count;
}
fn closeAll(fds: []const i32) void {
    for (fds) |fd| {
        if (fd >= 0) _ = linux.close(fd);
    }
}

const all_args = [_]ArgumentSpec{
    .{ .kind = .int },                      .{ .kind = .uint },   .{ .kind = .fixed }, .{ .kind = .string, .nullable = true },
    .{ .kind = .object, .nullable = true }, .{ .kind = .new_id }, .{ .kind = .array }, .{ .kind = .fd },
};
const requests = [_]MessageDescriptor{
    .{ .name = "all", .opcode = 0, .args = &all_args },
    .{ .name = "new", .opcode = 1, .since = 2, .args = &.{.{ .kind = .new_id }} },
    .{ .name = "text", .opcode = 2, .args = &.{.{ .kind = .string }} },
    .{ .name = "bytes", .opcode = 3, .args = &.{.{ .kind = .array }} },
    .{ .name = "descriptor", .opcode = 4, .args = &.{.{ .kind = .fd }} },
};
const events = [_]MessageDescriptor{
    .{ .name = "done", .opcode = 0, .args = &.{.{ .kind = .uint }} },
    .{ .name = "descriptor", .opcode = 1, .args = &.{.{ .kind = .fd }} },
};
const test_interface: Interface = .{ .name = "test", .version = 2, .requests = &requests, .events = &events };

fn testFrame(allocator: std.mem.Allocator, object_id: u32, descriptor: *const MessageDescriptor, values: []const OutValue) ![]u8 {
    var c = Connection.init(allocator, .client, 4096);
    defer c.deinit();
    _ = try c.registerObject(object_id, &test_interface, 2);
    // Requests are outgoing for clients.
    try c.queue(object_id, descriptor.opcode, values);
    const batch = c.nextBatch().?;
    return allocator.dupe(u8, batch.bytes);
}

test "headers split at every boundary and coalesced frames" {
    var bytes: [12]u8 = undefined;
    writeU32(bytes[0..4], 3);
    writeU32(bytes[4..8], (12 << 16) | 0);
    writeU32(bytes[8..12], 77);
    var both: [24]u8 = undefined;
    @memcpy(both[0..12], &bytes);
    @memcpy(both[12..], &bytes);
    for (0..12) |split| {
        var c = Connection.init(std.testing.allocator, .client, 4096);
        defer c.deinit();
        _ = try c.registerObject(3, &test_interface, 1);
        try c.feed(bytes[0..split], &.{});
        try c.feed(bytes[split..], &.{});
        var m = c.popMessage().?;
        defer m.deinit();
        try std.testing.expectEqual(@as(u32, 77), m.values[0].uint);
    }
    var c = Connection.init(std.testing.allocator, .client, 4096);
    defer c.deinit();
    _ = try c.registerObject(3, &test_interface, 1);
    try c.feed(&both, &.{});
    var a = c.popMessage().?;
    defer a.deinit();
    var b = c.popMessage().?;
    defer b.deinit();
}

test "all argument shapes, ownership, padding, and FD waiting" {
    const vals = [_]OutValue{ .{ .int = -2 }, .{ .uint = 9 }, .{ .fixed = 384 }, .{ .string = "hé" }, .{ .object = null }, .{ .new_id = 8 }, .{ .array = "abc" }, .{ .fd = -1 } };
    const frame = try testFrame(std.testing.allocator, 4, &requests[0], &vals);
    defer std.testing.allocator.free(frame);
    var c = Connection.init(std.testing.allocator, .server, 4096);
    defer c.deinit();
    _ = try c.registerObject(4, &test_interface, 2);
    try c.feed(frame, &.{});
    try std.testing.expect(c.popMessage() == null);
    try c.feed(&.{}, &.{-1});
    var m = c.popMessage().?;
    defer m.deinit();
    try std.testing.expectEqual(@as(i32, -2), m.values[0].int);
    try std.testing.expectEqualStrings("hé", m.values[3].string.?);
    try std.testing.expect(m.values[4].object == null);
    try std.testing.expectEqualStrings("abc", m.values[6].array.?);
}

test "malformed framing metadata and objects" {
    var h: [8]u8 = undefined;
    writeU32(h[0..4], 1);
    writeU32(h[4..8], 7 << 16);
    {
        var c = Connection.init(std.testing.allocator, .server, 16);
        defer c.deinit();
        _ = try c.registerObject(1, &test_interface, 1);
        try std.testing.expectError(error.InvalidFrameSize, c.feed(&h, &.{}));
    }
    writeU32(h[4..8], 10 << 16);
    {
        var c = Connection.init(std.testing.allocator, .server, 16);
        defer c.deinit();
        _ = try c.registerObject(1, &test_interface, 1);
        try std.testing.expectError(error.UnalignedFrame, c.feed(&h, &.{}));
    }
    writeU32(h[0..4], 99);
    writeU32(h[4..8], 8 << 16);
    {
        var c = Connection.init(std.testing.allocator, .server, 16);
        defer c.deinit();
        try std.testing.expectError(error.UnknownObject, c.feed(&h, &.{}));
    }
    writeU32(h[0..4], 1);
    writeU32(h[4..8], (8 << 16) | 99);
    {
        var c = Connection.init(std.testing.allocator, .server, 16);
        defer c.deinit();
        _ = try c.registerObject(1, &test_interface, 1);
        try std.testing.expectError(error.UnknownOpcode, c.feed(&h, &.{}));
    }
    writeU32(h[4..8], (8 << 16) | 1);
    {
        var c = Connection.init(std.testing.allocator, .server, 16);
        defer c.deinit();
        _ = try c.registerObject(1, &test_interface, 1);
        try std.testing.expectError(error.UnsupportedVersion, c.feed(&h, &.{}));
    }
}

test "malformed strings and arrays are rejected" {
    const text_values = [_]OutValue{.{ .string = "a" }};
    const valid_text = try testFrame(std.testing.allocator, 4, &requests[2], &text_values);
    defer std.testing.allocator.free(valid_text);
    {
        const frame = try std.testing.allocator.dupe(u8, valid_text);
        defer std.testing.allocator.free(frame);
        frame[13] = 'x';
        var c = Connection.init(std.testing.allocator, .server, 4096);
        defer c.deinit();
        _ = try c.registerObject(4, &test_interface, 2);
        try std.testing.expectError(error.UnterminatedString, c.feed(frame, &.{}));
    }
    {
        const frame = try std.testing.allocator.dupe(u8, valid_text);
        defer std.testing.allocator.free(frame);
        frame[12] = 0xff;
        var c = Connection.init(std.testing.allocator, .server, 4096);
        defer c.deinit();
        _ = try c.registerObject(4, &test_interface, 2);
        try std.testing.expectError(error.InvalidUtf8, c.feed(frame, &.{}));
    }
    {
        const frame = try std.testing.allocator.dupe(u8, valid_text);
        defer std.testing.allocator.free(frame);
        frame[15] = 1;
        var c = Connection.init(std.testing.allocator, .server, 4096);
        defer c.deinit();
        _ = try c.registerObject(4, &test_interface, 2);
        try std.testing.expectError(error.NonzeroPadding, c.feed(frame, &.{}));
    }

    const array_values = [_]OutValue{.{ .array = "a" }};
    const valid_array = try testFrame(std.testing.allocator, 4, &requests[3], &array_values);
    defer std.testing.allocator.free(valid_array);
    const frame = try std.testing.allocator.dupe(u8, valid_array);
    defer std.testing.allocator.free(frame);
    writeU32(frame[8..12], 5);
    var c = Connection.init(std.testing.allocator, .server, 4096);
    defer c.deinit();
    _ = try c.registerObject(4, &test_interface, 2);
    try std.testing.expectError(error.TruncatedArgument, c.feed(frame, &.{}));
}

test "incoming descriptors follow the message FIFO across feeds" {
    var first_pipe: [2]i32 = undefined;
    var second_pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&first_pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    var first_owned = true;
    defer if (first_owned) {
        _ = linux.close(first_pipe[0]);
    };
    defer _ = linux.close(first_pipe[1]);
    if (linux.errno(linux.pipe2(&second_pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    var second_owned = true;
    defer if (second_owned) {
        _ = linux.close(second_pipe[0]);
    };
    defer _ = linux.close(second_pipe[1]);

    var frames: [16]u8 = undefined;
    writeU32(frames[0..4], 3);
    writeU32(frames[4..8], (8 << 16) | 1);
    @memcpy(frames[8..], frames[0..8]);

    var c = Connection.init(std.testing.allocator, .client, 4096);
    defer c.deinit();
    _ = try c.registerObject(3, &test_interface, 1);
    first_owned = false;
    try c.feed(&frames, &.{first_pipe[0]});
    var first = c.popMessage().?;
    defer first.deinit();
    try std.testing.expect(c.popMessage() == null);
    second_owned = false;
    try c.feed(&.{}, &.{second_pipe[0]});
    var second = c.popMessage().?;
    defer second.deinit();
    const first_fd = try first.takeFd(0);
    defer _ = linux.close(first_fd);
    const second_fd = try second.takeFd(0);
    defer _ = linux.close(second_fd);
    try std.testing.expectEqual(first_pipe[0], first_fd);
    try std.testing.expectEqual(second_pipe[0], second_fd);
}

test "objects generations and outbound retry and suffix" {
    var c = Connection.init(std.testing.allocator, .client, 4096);
    defer c.deinit();
    const generation = try c.registerObject(2, &test_interface, 1);
    try std.testing.expectError(error.ObjectExists, c.registerObject(2, &test_interface, 1));
    try c.removeObject(2, generation);
    const replacement = try c.registerObject(2, &test_interface, 2);
    try std.testing.expectError(error.StaleObject, c.removeObject(2, generation));
    try std.testing.expect(replacement != generation);
    const vals = [_]OutValue{ .{ .int = 1 }, .{ .uint = 2 }, .{ .fixed = 3 }, .{ .string = null }, .{ .object = null }, .{ .new_id = 5 }, .{ .array = "x" }, .{ .fd = -1 } };
    try c.queue(2, 0, &vals);
    const first = c.nextBatch().?;
    const original_len = first.bytes.len;
    try std.testing.expectEqual(@as(u32, 2), readU32(first.bytes[0..4]));
    try std.testing.expectEqual(@as(u16, 0), @as(u16, @truncate(readU32(first.bytes[4..8]))));
    try c.acknowledge(first.token, null);
    const retry = c.nextBatch().?;
    try std.testing.expectEqual(original_len, retry.bytes.len);
    try std.testing.expectEqual(@as(usize, 1), retry.fds.len);
    try c.acknowledge(retry.token, 4);
    const suffix = c.nextBatch().?;
    try std.testing.expectEqual(original_len - 4, suffix.bytes.len);
    try std.testing.expectEqual(@as(usize, 0), suffix.fds.len);
    try c.acknowledge(suffix.token, suffix.bytes.len);
    try std.testing.expect(c.nextBatch() == null);
}

test "outbound FD cap and positive-send ownership" {
    const TooMany = struct {
        const args = [_]ArgumentSpec{.{ .kind = .fd }} ** (max_fds_per_batch + 1);
        const request = [_]MessageDescriptor{.{ .name = "many", .opcode = 0, .args = &args }};
        const interface: Interface = .{ .name = "many", .version = 1, .requests = &request };
    };
    var too_many = Connection.init(std.testing.allocator, .client, 4096);
    defer too_many.deinit();
    _ = try too_many.registerObject(1, &TooMany.interface, 1);
    const values: [max_fds_per_batch + 1]OutValue = @splat(.{ .fd = -1 });
    try std.testing.expectError(error.TooManyFds, too_many.queue(1, 0, &values));

    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    defer _ = linux.close(pipe[1]);
    var read_owned = true;
    defer if (read_owned) {
        _ = linux.close(pipe[0]);
    };

    var c = Connection.init(std.testing.allocator, .client, 4096);
    defer c.deinit();
    _ = try c.registerObject(2, &test_interface, 2);
    try c.queue(2, 4, &.{.{ .fd = pipe[0] }});
    read_owned = false;
    const first = c.nextBatch().?;
    try c.acknowledge(first.token, null);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(pipe[0], linux.F.GETFD, 0)));
    const retry = c.nextBatch().?;
    try c.acknowledge(retry.token, 1);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(pipe[0], linux.F.GETFD, 0)));
}
