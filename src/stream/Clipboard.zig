//! Bidirectional text clipboard bridge over ext-data-control-v1.

const Clipboard = @This();

const std = @import("std");
const wayland = @import("wayland");

const linux = std.os.linux;
const wl = wayland.client.wl;
const ext = wayland.client.ext;
const log = std.log.scoped(.stream_clipboard);

pub const maximum_text_bytes: usize = 1024 * 1024;
pub const poll_fd_count = 5;

const output_header_size = 8;
const output_clipboard = 1;
const protocol_version = 2;
const maximum_outgoing_transfers = poll_fd_count - 1;
const text_mimes = [_][:0]const u8{
    "text/plain;charset=utf-8",
    "UTF8_STRING",
    "text/plain",
};

const Offer = struct {
    clipboard: *Clipboard,
    proxy: *ext.DataControlOfferV1,
    mimes: std.ArrayList([:0]u8) = .empty,

    fn destroy(self: *Offer) void {
        const allocator = self.clipboard.allocator;
        for (self.mimes.items) |mime| allocator.free(mime);
        self.mimes.deinit(allocator);
        self.proxy.destroy();
        allocator.destroy(self);
    }

    fn textMime(self: *const Offer) ?[:0]const u8 {
        for (&text_mimes) |wanted| {
            for (self.mimes.items) |mime| {
                if (std.mem.eql(u8, mime, wanted)) return mime;
            }
        }
        return null;
    }
};

const Transfer = struct {
    fd: std.posix.fd_t,
    data: std.ArrayList(u8) = .empty,
};

const OutgoingTransfer = struct {
    fd: std.posix.fd_t,
    text: []u8,
    written: usize = 0,
};

allocator: std.mem.Allocator,
io: std.Io,
seat: ?*wl.Seat = null,
manager: ?*ext.DataControlManagerV1 = null,
device: ?*ext.DataControlDeviceV1 = null,
pending: ?*Offer = null,
selection: ?*Offer = null,
source: ?*ext.DataControlSourceV1 = null,
source_text: ?[]u8 = null,
transfer: ?Transfer = null,
outgoing: [maximum_outgoing_transfers]?OutgoingTransfer = @splat(null),

pub fn init(allocator: std.mem.Allocator, io: std.Io) Clipboard {
    return .{ .allocator = allocator, .io = io };
}

pub fn bindGlobal(
    self: *Clipboard,
    registry: *wl.Registry,
    name: u32,
    interface: []const u8,
    version: u32,
) !void {
    if (std.mem.eql(u8, interface, std.mem.span(wl.Seat.interface.name))) {
        if (self.seat == null) {
            self.seat = try registry.bind(name, wl.Seat, @min(version, wl.Seat.generated_version));
        }
    } else if (std.mem.eql(
        u8,
        interface,
        std.mem.span(ext.DataControlManagerV1.interface.name),
    )) {
        if (self.manager == null) {
            self.manager = try registry.bind(name, ext.DataControlManagerV1, 1);
        }
    }
}

pub fn start(self: *Clipboard) !void {
    const manager = self.manager orelse return error.MissingDataControlManager;
    const seat = self.seat orelse return error.MissingClipboardSeat;
    const device = try manager.getDataDevice(seat);
    self.device = device;
    device.setListener(*Clipboard, deviceListener, self);
}

pub fn deinit(self: *Clipboard) void {
    self.abortTransfer();
    for (0..self.outgoing.len) |index| self.finishOutgoing(index);
    if (self.source) |source| source.destroy();
    if (self.source_text) |text| self.allocator.free(text);
    if (self.pending) |offer| offer.destroy();
    if (self.selection) |offer| offer.destroy();
    if (self.device) |device| device.destroy();
    if (self.manager) |manager| manager.destroy();
    if (self.seat) |seat| {
        if (seat.getVersion() >= wl.Seat.release_since_version) {
            seat.release();
        } else {
            seat.destroy();
        }
    }
    self.* = undefined;
}

pub fn setText(self: *Clipboard, text: []const u8) !void {
    if (text.len > maximum_text_bytes) return error.ClipboardTooLarge;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidClipboardText;
    const manager = self.manager orelse return error.ClipboardUnavailable;
    const device = self.device orelse return error.ClipboardUnavailable;
    const owned = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(owned);
    const source = try manager.createDataSource();
    errdefer source.destroy();
    source.setListener(*Clipboard, sourceListener, self);
    for (&text_mimes) |mime| source.offer(mime);

    if (self.source_text) |old| self.allocator.free(old);
    self.source = source;
    self.source_text = owned;
    device.setSelection(source);
    try self.publish(text);
}

pub fn populatePollFds(self: *const Clipboard, poll_fds: []std.posix.pollfd) void {
    std.debug.assert(poll_fds.len == poll_fd_count);
    poll_fds[0] = .{
        .fd = if (self.transfer) |transfer| transfer.fd else -1,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };
    for (self.outgoing, poll_fds[1..]) |transfer, *poll_fd| {
        poll_fd.* = .{
            .fd = if (transfer) |value| value.fd else -1,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        };
    }
}

pub fn handleTransfers(self: *Clipboard, poll_fds: []const std.posix.pollfd) void {
    std.debug.assert(poll_fds.len == poll_fd_count);
    self.handleIncoming(poll_fds[0].revents) catch |err| {
        log.warn("clipboard receive failed: {t}", .{err});
    };
    for (poll_fds[1..], 0..) |poll_fd, index| {
        self.handleOutgoing(index, poll_fd.revents) catch |err| {
            log.warn("clipboard send failed: {t}", .{err});
        };
    }
}

fn handleIncoming(self: *Clipboard, revents: i16) !void {
    if (self.transfer == null or revents == 0) return;
    if (revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
        self.abortTransfer();
        return error.ClipboardTransferFailed;
    }
    if (revents & (std.posix.POLL.IN | std.posix.POLL.HUP) == 0) return;

    while (true) {
        var buffer: [4096]u8 = undefined;
        const count = std.posix.read(self.transfer.?.fd, &buffer) catch |err| switch (err) {
            error.WouldBlock => break,
            else => {
                self.abortTransfer();
                return err;
            },
        };
        if (count == 0) {
            try self.finishTransfer();
            return;
        }
        if (self.transfer.?.data.items.len + count > maximum_text_bytes) {
            self.abortTransfer();
            return error.ClipboardTooLarge;
        }
        try self.transfer.?.data.appendSlice(self.allocator, buffer[0..count]);
    }
}

fn takePending(self: *Clipboard, proxy: *ext.DataControlOfferV1) ?*Offer {
    const offer = self.pending orelse return null;
    if (offer.proxy != proxy) return null;
    self.pending = null;
    return offer;
}

fn replaceSelection(self: *Clipboard, proxy: ?*ext.DataControlOfferV1) void {
    self.abortTransfer();
    if (self.selection) |offer| offer.destroy();
    self.selection = null;
    const selected = proxy orelse {
        self.publish("") catch |err| log.warn("clipboard clear publish failed: {t}", .{err});
        return;
    };
    const offer = self.takePending(selected) orelse return;
    self.selection = offer;
    // Selection listeners run before the old source's cancelled event. If
    // our source still exists, this is either our own selection echo or a
    // replacement whose transfer must wait until cancellation identifies it.
    if (self.source != null) return;
    self.beginTransfer(offer) catch |err| {
        log.warn("clipboard receive failed: {t}", .{err});
    };
}

fn beginTransfer(self: *Clipboard, offer: *Offer) !void {
    const mime = offer.textMime() orelse {
        try self.publish("");
        return;
    };
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
        return error.PipeFailed;
    }
    errdefer _ = linux.close(fds[0]);
    errdefer _ = linux.close(fds[1]);
    try setNonblocking(fds[0]);
    offer.proxy.receive(mime.ptr, fds[1]);
    _ = linux.close(fds[1]);
    self.transfer = .{ .fd = fds[0] };
}

fn abortTransfer(self: *Clipboard) void {
    if (self.transfer) |*transfer| {
        _ = linux.close(transfer.fd);
        transfer.data.deinit(self.allocator);
    }
    self.transfer = null;
}

fn queueOutgoing(self: *Clipboard, fd: std.posix.fd_t, text: []const u8) !void {
    errdefer _ = linux.close(fd);
    try setNonblocking(fd);
    const owned = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(owned);
    for (&self.outgoing) |*slot| {
        if (slot.* != null) continue;
        slot.* = .{ .fd = fd, .text = owned };
        return;
    }
    return error.TooManyClipboardTransfers;
}

fn handleOutgoing(self: *Clipboard, index: usize, revents: i16) !void {
    if (self.outgoing[index] == null or revents == 0) return;
    if (revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
        self.finishOutgoing(index);
        return;
    }
    if (revents & std.posix.POLL.OUT == 0) return;
    const transfer = &self.outgoing[index].?;
    while (transfer.written < transfer.text.len) {
        const result = linux.write(
            transfer.fd,
            transfer.text.ptr + transfer.written,
            transfer.text.len - transfer.written,
        );
        switch (linux.errno(result)) {
            .SUCCESS => transfer.written += result,
            .INTR => continue,
            .AGAIN => return,
            .PIPE => {
                self.finishOutgoing(index);
                return;
            },
            else => {
                self.finishOutgoing(index);
                return error.ClipboardWriteFailed;
            },
        }
    }
    self.finishOutgoing(index);
}

fn finishOutgoing(self: *Clipboard, index: usize) void {
    if (self.outgoing[index]) |transfer| {
        _ = linux.close(transfer.fd);
        self.allocator.free(transfer.text);
    }
    self.outgoing[index] = null;
}

fn setNonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL);
    if (flags < 0) return error.SetNonblockingFailed;
    var status: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
    status.NONBLOCK = true;
    if (std.c.fcntl(
        fd,
        std.posix.F.SETFL,
        @as(c_int, @intCast(@as(u32, @bitCast(status)))),
    ) < 0) return error.SetNonblockingFailed;
}

fn finishTransfer(self: *Clipboard) !void {
    const transfer = &self.transfer.?;
    if (!std.unicode.utf8ValidateSlice(transfer.data.items)) {
        self.abortTransfer();
        return error.InvalidClipboardText;
    }
    try self.publish(transfer.data.items);
    self.abortTransfer();
}

fn publish(self: *Clipboard, text: []const u8) !void {
    var header: [output_header_size]u8 = @splat(0);
    header[0] = protocol_version;
    header[1] = output_clipboard;
    std.mem.writeInt(u32, header[4..8], @intCast(text.len), .little);
    const output = std.Io.File.stdout();
    try output.writeStreamingAll(self.io, &header);
    try output.writeStreamingAll(self.io, text);
}

fn deviceListener(
    device: *ext.DataControlDeviceV1,
    event: ext.DataControlDeviceV1.Event,
    self: *Clipboard,
) void {
    switch (event) {
        .data_offer => |data_offer| {
            if (self.pending) |offer| offer.destroy();
            self.pending = null;
            const offer = self.allocator.create(Offer) catch {
                data_offer.id.destroy();
                return;
            };
            offer.* = .{ .clipboard = self, .proxy = data_offer.id };
            data_offer.id.setListener(*Offer, offerListener, offer);
            self.pending = offer;
        },
        .selection => |selection| self.replaceSelection(selection.id),
        .primary_selection => {
            if (self.pending) |offer| offer.destroy();
            self.pending = null;
        },
        .finished => {
            self.abortTransfer();
            device.destroy();
            if (self.device == device) self.device = null;
        },
    }
}

fn offerListener(
    _: *ext.DataControlOfferV1,
    event: ext.DataControlOfferV1.Event,
    offer: *Offer,
) void {
    switch (event) {
        .offer => |offered| {
            const mime = offer.clipboard.allocator.dupeZ(
                u8,
                std.mem.span(offered.mime_type),
            ) catch return;
            offer.mimes.append(offer.clipboard.allocator, mime) catch
                offer.clipboard.allocator.free(mime);
        },
    }
}

fn sourceListener(
    source: *ext.DataControlSourceV1,
    event: ext.DataControlSourceV1.Event,
    self: *Clipboard,
) void {
    switch (event) {
        .send => |send| {
            if (source != self.source) {
                _ = linux.close(send.fd);
                return;
            }
            const text = self.source_text orelse {
                _ = linux.close(send.fd);
                return;
            };
            self.queueOutgoing(send.fd, text) catch |err| {
                log.warn("clipboard source write failed: {t}", .{err});
            };
        },
        .cancelled => {
            source.destroy();
            if (source != self.source) return;
            self.source = null;
            if (self.source_text) |text| self.allocator.free(text);
            self.source_text = null;
            if (self.selection) |offer| {
                if (self.transfer == null) self.beginTransfer(offer) catch |err| {
                    log.warn("clipboard replacement receive failed: {t}", .{err});
                };
            }
        },
    }
}
