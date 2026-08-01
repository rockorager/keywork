//! Text clipboard ownership and selection offers over `wl_data_device`.

const Clipboard = @This();

const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("wayring-protocols");
const Client = @import("Client.zig");

const linux = std.os.linux;
const log = std.log.scoped(.keywork_wayring_clipboard);

const text_mimes = [_][]const u8{
    "text/plain;charset=utf-8",
    "UTF8_STRING",
    "text/plain",
    "TEXT",
    "STRING",
};

const read_timeout_ms: i32 = 2000;
const write_timeout_ms: i32 = 2000;
const max_selection_bytes: usize = 16 * 1024 * 1024;

const OfferState = struct {
    handle: wayring.ObjectHandle,
    mimes: std.ArrayList([]u8) = .empty,

    fn deinit(self: *OfferState, allocator: std.mem.Allocator) void {
        for (self.mimes.items) |mime| allocator.free(mime);
        self.mimes.deinit(allocator);
        self.* = undefined;
    }

    fn firstTextMime(self: *const OfferState) ?[]const u8 {
        for (text_mimes) |wanted| {
            for (self.mimes.items) |mime| {
                if (std.mem.eql(u8, mime, wanted)) return mime;
            }
        }
        return null;
    }
};

const SourceState = struct {
    handle: wayring.ObjectHandle,
    text: []u8,

    fn deinit(self: *SourceState, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

allocator: std.mem.Allocator,
client: ?*Client,
connection: *wayring.Connection,
manager: wayring.ObjectHandle,
device: wayring.ObjectHandle,
pending: ?OfferState = null,
selection: ?OfferState = null,
drag: ?OfferState = null,
source: ?SourceState = null,
retired_sources: std.ArrayList(SourceState) = .empty,
owns_selection: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    client: *Client,
    manager: wayring.ObjectHandle,
    seat: wayring.ObjectHandle,
) !Clipboard {
    var self = try initConnection(allocator, client.connectionPtr(), manager, seat);
    self.client = client;
    return self;
}

fn initConnection(
    allocator: std.mem.Allocator,
    connection: *wayring.Connection,
    manager: wayring.ObjectHandle,
    seat: wayring.ObjectHandle,
) !Clipboard {
    return .{
        .allocator = allocator,
        .client = null,
        .connection = connection,
        .manager = manager,
        .device = try protocol.wl_data_device_manager_types.requests.get_data_device(
            connection,
            manager,
            seat,
        ),
    };
}

/// Protocol objects are connection-owned during transport shutdown. Local
/// copies can be released once the client has stopped dispatching messages.
pub fn deinit(self: *Clipboard) void {
    self.deinitOffer(&self.pending);
    self.deinitOffer(&self.selection);
    self.deinitOffer(&self.drag);
    if (self.source) |*source| source.deinit(self.allocator);
    for (self.retired_sources.items) |*source| source.deinit(self.allocator);
    self.retired_sources.deinit(self.allocator);
    self.* = undefined;
}

pub fn ownsObject(self: *const Clipboard, id: u32) bool {
    return id == self.device.id or
        offerHasId(self.pending, id) or
        offerHasId(self.selection, id) or
        offerHasId(self.drag, id) or
        self.findSource(id) != null;
}

pub fn handleMessage(self: *Clipboard, message: *wayring.Message) !void {
    if (message.object_id == self.device.id) {
        try self.handleDevice(try protocol.wl_data_device_types.decodeEvent(
            self.connection,
            self.device,
            message,
        ));
        return;
    }
    if (self.findSource(message.object_id)) |source| {
        try self.handleSource(message, source, try protocol.wl_data_source_types.decodeEvent(
            self.connection,
            source,
            message,
        ));
        return;
    }
    if (self.findOffer(message.object_id)) |offer| {
        switch (try protocol.wl_data_offer_types.decodeEvent(
            self.connection,
            offer.handle,
            message,
        )) {
            .offer => |event| {
                const mime = try self.allocator.dupe(u8, event.mime_type);
                errdefer self.allocator.free(mime);
                try offer.mimes.append(self.allocator, mime);
            },
            .source_actions, .action => {},
        }
        return;
    }
    return error.UnknownClipboardObject;
}

/// Returns the current text selection. The transfer is bounded because this
/// synchronous platform contract runs on the event-loop thread.
pub fn read(self: *Clipboard, allocator: std.mem.Allocator) !?[]u8 {
    if (self.owns_selection) {
        const source = self.source orelse return null;
        return try allocator.dupe(u8, source.text);
    }
    const selection = if (self.selection) |*offer| offer else return null;
    const mime = selection.firstTextMime() orelse return null;
    const client = self.client orelse return error.ClipboardNotConnected;
    if (!client.canSubmitOutputImmediately()) return error.ClipboardBusy;

    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS)
        return error.PipeFailed;
    const read_fd = fds[0];
    const write_fd = fds[1];
    defer _ = linux.close(read_fd);
    protocol.wl_data_offer_types.requests.receive(
        self.connection,
        selection.handle,
        mime,
        write_fd,
    ) catch |err| {
        _ = linux.close(write_fd);
        return err;
    };
    // queueObject owns write_fd now. Submit without recursively dispatching
    // the reactor so the source can fill the pipe while this call polls it.
    try client.submitOutput();
    return try readAllFd(allocator, read_fd);
}

pub fn write(self: *Clipboard, text: []const u8, serial: u32) !void {
    if (self.source != null) try self.retired_sources.ensureUnusedCapacity(self.allocator, 1);
    const owned = try self.allocator.dupe(u8, text);
    var owned_cleanup = true;
    errdefer if (owned_cleanup) self.allocator.free(owned);
    const source = try protocol.wl_data_device_manager_types.requests.create_data_source(
        self.connection,
        self.manager,
    );
    var source_cleanup = true;
    errdefer if (source_cleanup) protocol.wl_data_source_types.requests.destroy(self.connection, source) catch {};
    for (text_mimes) |mime| try protocol.wl_data_source_types.requests.offer(
        self.connection,
        source,
        mime,
    );
    try protocol.wl_data_device_types.requests.set_selection(
        self.connection,
        self.device,
        source,
        serial,
    );

    if (self.source) |old_source| self.retired_sources.appendAssumeCapacity(old_source);
    self.source = .{ .handle = source, .text = owned };
    self.owns_selection = true;
    owned_cleanup = false;
    source_cleanup = false;
    if (self.client) |client| try client.flush();
}

fn handleDevice(self: *Clipboard, event: protocol.wl_data_device_types.Event) !void {
    switch (event) {
        .data_offer => |data_offer| {
            try self.destroyOffer(&self.pending);
            const device_object = try self.connection.objectForHandle(
                self.device,
                &protocol.wl_data_device,
            );
            self.pending = .{ .handle = .{
                .id = data_offer.id,
                .generation = try self.connection.registerObject(
                    data_offer.id,
                    &protocol.wl_data_offer,
                    @min(device_object.version, protocol.wl_data_offer.version),
                ),
            } };
            try self.connection.resumeParsing();
        },
        .selection => |selection| {
            try self.destroyOffer(&self.selection);
            self.selection = try self.takePending(selection.id);
        },
        .enter => |enter| {
            try self.destroyOffer(&self.drag);
            self.drag = try self.takePending(enter.id);
        },
        .leave, .drop => try self.destroyOffer(&self.drag),
        .motion => {},
    }
}

fn handleSource(
    self: *Clipboard,
    message: *wayring.Message,
    source: wayring.ObjectHandle,
    event: protocol.wl_data_source_types.Event,
) !void {
    switch (event) {
        .send => |send| {
            const fd = try message.takeFd(send.fd);
            defer _ = linux.close(fd);
            const text = self.sourceText(source.id) orelse return;
            writeAllFd(fd, text) catch |err| {
                log.warn("clipboard send failed: {}", .{err});
            };
        },
        .cancelled => {
            try protocol.wl_data_source_types.requests.destroy(self.connection, source);
            if (self.source != null and self.source.?.handle.id == source.id) {
                self.source.?.deinit(self.allocator);
                self.source = null;
                self.owns_selection = false;
            } else {
                for (self.retired_sources.items, 0..) |retired, index| {
                    if (retired.handle.id != source.id) continue;
                    var removed = self.retired_sources.orderedRemove(index);
                    removed.deinit(self.allocator);
                    break;
                }
            }
        },
        .target, .dnd_drop_performed, .dnd_finished, .action => {},
    }
}

fn takePending(self: *Clipboard, id: ?u32) !?OfferState {
    const object_id = id orelse return null;
    const pending = self.pending orelse return error.UnknownDataOffer;
    if (pending.handle.id != object_id) return error.UnknownDataOffer;
    self.pending = null;
    return pending;
}

fn findOffer(self: *Clipboard, id: u32) ?*OfferState {
    if (self.pending) |*offer| if (offer.handle.id == id) return offer;
    if (self.selection) |*offer| if (offer.handle.id == id) return offer;
    if (self.drag) |*offer| if (offer.handle.id == id) return offer;
    return null;
}

fn findSource(self: *const Clipboard, id: u32) ?wayring.ObjectHandle {
    if (self.source) |source| if (source.handle.id == id) return source.handle;
    for (self.retired_sources.items) |source| {
        if (source.handle.id == id) return source.handle;
    }
    return null;
}

fn sourceText(self: *const Clipboard, id: u32) ?[]const u8 {
    if (self.source) |source| if (source.handle.id == id) return source.text;
    for (self.retired_sources.items) |source| {
        if (source.handle.id == id) return source.text;
    }
    return null;
}

fn destroyOffer(self: *Clipboard, slot: *?OfferState) !void {
    const offer = if (slot.*) |*value| value else return;
    defer {
        offer.deinit(self.allocator);
        slot.* = null;
    }
    try protocol.wl_data_offer_types.requests.destroy(self.connection, offer.handle);
}

fn deinitOffer(self: *Clipboard, slot: *?OfferState) void {
    const offer = if (slot.*) |*value| value else return;
    offer.deinit(self.allocator);
    slot.* = null;
}

fn offerHasId(offer: ?OfferState, id: u32) bool {
    return offer != null and offer.?.handle.id == id;
}

fn readAllFd(allocator: std.mem.Allocator, fd: i32) ![]u8 {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    while (true) {
        var poll_fds = [_]linux.pollfd{.{
            .fd = fd,
            .events = linux.POLL.IN,
            .revents = 0,
        }};
        const ready = linux.poll(&poll_fds, 1, read_timeout_ms);
        if (linux.errno(ready) != .SUCCESS) {
            if (linux.errno(ready) == .INTR) continue;
            return error.ReadFailed;
        }
        if (ready == 0) return error.ReadTimeout;

        try data.ensureUnusedCapacity(allocator, 4096);
        const destination = data.unusedCapacitySlice();
        const count = linux.read(fd, destination.ptr, destination.len);
        switch (linux.errno(count)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (count == 0) break;
        data.items.len += count;
        if (data.items.len > max_selection_bytes) return error.SelectionTooLarge;
    }
    return data.toOwnedSlice(allocator);
}

fn writeAllFd(fd: i32, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        var poll_fds = [_]linux.pollfd{.{
            .fd = fd,
            .events = linux.POLL.OUT,
            .revents = 0,
        }};
        const ready = linux.poll(&poll_fds, 1, write_timeout_ms);
        if (linux.errno(ready) != .SUCCESS) {
            if (linux.errno(ready) == .INTR) continue;
            return error.WriteFailed;
        }
        if (ready == 0) return error.WriteTimeout;

        const count = linux.write(fd, data.ptr + written, data.len - written);
        switch (linux.errno(count)) {
            .SUCCESS => written += count,
            .INTR => continue,
            .PIPE => return error.ReceiverClosed,
            else => return error.WriteFailed,
        }
    }
}

fn transfer(sender: *wayring.Connection, receiver: *wayring.Connection) !void {
    const batch = sender.nextBatch() orelse return error.MissingBatch;
    var duplicated: [wayring.max_fds_per_batch]i32 = undefined;
    var count: usize = 0;
    errdefer {
        for (duplicated[0..count]) |fd| _ = linux.close(fd);
    }
    for (batch.fds) |fd| {
        const result = linux.dup(fd);
        if (linux.errno(result) != .SUCCESS) return error.DuplicateFdFailed;
        duplicated[count] = @intCast(result);
        count += 1;
    }
    try receiver.feed(batch.bytes, duplicated[0..count]);
    count = 0;
    try sender.acknowledge(batch.token, batch.bytes.len);
}

test "selection offers and outgoing source sends use typed FD ownership" {
    const allocator = std.testing.allocator;
    var client_connection = wayring.Connection.init(allocator, .client, 4096);
    defer client_connection.deinit();
    var server_connection = wayring.Connection.init(allocator, .server, 4096);
    defer server_connection.deinit();

    const manager: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try client_connection.registerObject(
            2,
            &protocol.wl_data_device_manager,
            4,
        ),
    };
    const seat: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try client_connection.registerObject(3, &protocol.wl_seat, 8),
    };
    var clipboard = try Clipboard.initConnection(allocator, &client_connection, manager, seat);
    defer clipboard.deinit();
    _ = try server_connection.registerObject(
        clipboard.device.id,
        &protocol.wl_data_device,
        4,
    );

    const offer_id: u32 = 0xff000000;
    _ = try server_connection.registerObject(offer_id, &protocol.wl_data_offer, 4);
    try server_connection.queue(clipboard.device.id, 0, &.{.{ .new_id = offer_id }});
    try server_connection.queue(offer_id, 0, &.{.{ .string = "text/plain" }});
    try server_connection.queue(clipboard.device.id, 5, &.{.{ .object = offer_id }});
    try transfer(&server_connection, &client_connection);
    while (client_connection.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        try clipboard.handleMessage(&message);
    }
    try std.testing.expectEqualStrings("text/plain", clipboard.selection.?.firstTextMime().?);

    try clipboard.write("from keywork", 42);
    const source = clipboard.source.?.handle;
    _ = try server_connection.registerObject(source.id, &protocol.wl_data_source, 4);
    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS)
        return error.PipeFailed;
    defer _ = linux.close(pipe[0]);
    var write_owned = true;
    defer if (write_owned) {
        _ = linux.close(pipe[1]);
    };
    try server_connection.queue(source.id, 1, &.{
        .{ .string = "text/plain" },
        .{ .fd = pipe[1] },
    });
    write_owned = false;
    try transfer(&server_connection, &client_connection);
    var send_message = client_connection.popMessage().?;
    defer send_message.deinit();
    try clipboard.handleMessage(&send_message);
    var output: [32]u8 = undefined;
    const length = linux.read(pipe[0], &output, output.len);
    if (linux.errno(length) != .SUCCESS) return error.ReadFailed;
    try std.testing.expectEqualStrings("from keywork", output[0..length]);
}

test {
    std.testing.refAllDecls(Clipboard);
}
