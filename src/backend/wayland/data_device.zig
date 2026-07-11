//! Wayland clipboard support over wl_data_device, text-only: tracks the
//! seat's selection offers and owns outgoing text sources. Drag-and-drop
//! offers are acknowledged only far enough to release their resources.

const std = @import("std");
const wayland = @import("wayland");

const linux = std.os.linux;
const wl = wayland.client.wl;

const log = std.log.scoped(.keywork_wayland_clipboard);

/// Mime types accepted and offered for text selections, in preference
/// order. The X11 aliases keep Xwayland clients interoperable.
const text_mimes = [_][:0]const u8{
    "text/plain;charset=utf-8",
    "UTF8_STRING",
    "text/plain",
    "TEXT",
    "STRING",
};

/// Reads longer than this abort rather than stall the event loop on a
/// misbehaving selection owner.
const read_timeout_ms: i32 = 2000;
const write_timeout_ms: i32 = 2000;
/// Cap incoming selections; a text clipboard has no business being
/// larger, and the owner controls how much it sends.
const max_selection_bytes: usize = 16 * 1024 * 1024;

/// One remote selection or drag offer with its announced mime types.
const OfferState = struct {
    clipboard: *Clipboard,
    offer: *wl.DataOffer,
    mimes: std.ArrayList([]u8) = .empty,

    fn destroy(self: *OfferState) void {
        const allocator = self.clipboard.allocator;
        for (self.mimes.items) |mime| allocator.free(mime);
        self.mimes.deinit(allocator);
        self.offer.destroy();
        allocator.destroy(self);
    }

    fn firstTextMime(self: *const OfferState) ?[]const u8 {
        for (&text_mimes) |wanted| {
            for (self.mimes.items) |mime| {
                if (std.mem.eql(u8, mime, wanted)) return mime;
            }
        }
        return null;
    }
};

pub const Clipboard = struct {
    allocator: std.mem.Allocator,
    display: *wl.Display,
    manager: *wl.DataDeviceManager,
    device: *wl.DataDevice,
    /// Offer announced via data_offer but not yet classified by a
    /// selection or drag enter event.
    pending: ?*OfferState = null,
    /// The seat's current selection, valid while keyboard focus stays in
    /// this client.
    selection: ?*OfferState = null,
    /// Drag offer currently over one of our surfaces; unused beyond
    /// releasing it on leave/drop.
    drag: ?*OfferState = null,
    /// Our outgoing selection source and the text it serves.
    source: ?*wl.DataSource = null,
    source_text: ?[]u8 = null,
    /// True from set_selection until the compositor cancels our source.
    /// While set, reads return source_text directly — receiving from our
    /// own offer would deadlock the single-threaded event loop.
    owns_selection: bool = false,

    /// Creates the clipboard when the compositor advertises
    /// wl_data_device_manager and a seat exists; otherwise (or on
    /// failure) returns null so backends degrade to no clipboard.
    pub fn init(
        allocator: std.mem.Allocator,
        display: *wl.Display,
        manager: ?*wl.DataDeviceManager,
        seat: ?*wl.Seat,
    ) ?*Clipboard {
        const data_device_manager = manager orelse return null;
        const wl_seat = seat orelse return null;
        return create(allocator, display, data_device_manager, wl_seat) catch |err| {
            log.warn("clipboard unavailable: {}", .{err});
            return null;
        };
    }

    pub fn create(
        allocator: std.mem.Allocator,
        display: *wl.Display,
        manager: *wl.DataDeviceManager,
        seat: *wl.Seat,
    ) !*Clipboard {
        const device = try manager.getDataDevice(seat);
        errdefer device.release();
        const self = try allocator.create(Clipboard);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .manager = manager,
            .device = device,
        };
        device.setListener(*Clipboard, deviceListener, self);
        return self;
    }

    pub fn destroy(self: *Clipboard) void {
        if (self.source) |source| source.destroy();
        if (self.source_text) |text| self.allocator.free(text);
        if (self.pending) |state| state.destroy();
        if (self.selection) |state| state.destroy();
        if (self.drag) |state| state.destroy();
        self.device.release();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Current selection as text, or null when the clipboard is empty or
    /// offers no text mime. The caller owns the returned slice. Blocks up
    /// to the read timeout while the selection owner streams data.
    pub fn read(self: *Clipboard, allocator: std.mem.Allocator) !?[]u8 {
        if (self.owns_selection) {
            const text = self.source_text orelse return null;
            return try allocator.dupe(u8, text);
        }
        // Sync selection state: a set_selection by another client may not
        // have been dispatched yet this turn.
        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        const state = self.selection orelse return null;
        const mime = state.firstTextMime() orelse return null;
        const mime_z = try allocator.dupeZ(u8, mime);
        defer allocator.free(mime_z);

        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
        const read_fd = fds[0];
        state.offer.receive(mime_z, fds[1]);
        _ = linux.close(fds[1]);
        defer _ = linux.close(read_fd);
        if (self.display.flush() != .SUCCESS) return error.FlushFailed;

        return try readAllFd(allocator, read_fd);
    }

    /// Claims the selection with `text`. `serial` must be a recent input
    /// serial; compositors reject stale claims.
    pub fn write(self: *Clipboard, text: []const u8, serial: u32) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        const source = try self.manager.createDataSource();

        if (self.source) |old| old.destroy();
        if (self.source_text) |old| self.allocator.free(old);
        self.source = source;
        self.source_text = owned;
        source.setListener(*Clipboard, sourceListener, self);
        for (&text_mimes) |mime| source.offer(mime);
        self.device.setSelection(source, serial);
        self.owns_selection = true;
        if (self.display.flush() != .SUCCESS) return error.FlushFailed;
    }

    /// Matches and detaches the pending offer for a device event. A
    /// mismatch means the compositor referenced an offer we never saw
    /// announced; nothing sane can be done with it.
    fn takePending(self: *Clipboard, offer: *wl.DataOffer) ?*OfferState {
        const state = self.pending orelse return null;
        if (state.offer != offer) return null;
        self.pending = null;
        return state;
    }
};

fn deviceListener(_: *wl.DataDevice, event: wl.DataDevice.Event, self: *Clipboard) void {
    switch (event) {
        .data_offer => |data_offer| {
            // A pending offer still unclassified here means the compositor
            // never resolved it; the new announcement replaces it.
            if (self.pending) |state| state.destroy();
            self.pending = null;
            const state = self.allocator.create(OfferState) catch {
                data_offer.id.destroy();
                return;
            };
            state.* = .{ .clipboard = self, .offer = data_offer.id };
            data_offer.id.setListener(*OfferState, offerListener, state);
            self.pending = state;
        },
        .selection => |selection| {
            if (self.selection) |state| state.destroy();
            self.selection = null;
            const offer = selection.id orelse return;
            const state = self.takePending(offer) orelse return;
            self.selection = state;
        },
        .enter => |enter| {
            if (self.drag) |state| state.destroy();
            self.drag = null;
            const offer = enter.id orelse return;
            self.drag = self.takePending(offer);
        },
        .leave => {
            if (self.drag) |state| state.destroy();
            self.drag = null;
        },
        .drop => {
            // Drag-and-drop is not supported; releasing the offer tells
            // the source the drop went nowhere.
            if (self.drag) |state| state.destroy();
            self.drag = null;
        },
        .motion => {},
    }
}

fn sourceListener(source: *wl.DataSource, event: wl.DataSource.Event, self: *Clipboard) void {
    switch (event) {
        .send => |send| {
            defer _ = linux.close(send.fd);
            if (source != self.source) return;
            const text = self.source_text orelse return;
            writeAllFd(send.fd, text) catch |err| {
                log.warn("clipboard send failed: {}", .{err});
            };
        },
        .cancelled => {
            source.destroy();
            if (source != self.source) return;
            self.source = null;
            self.owns_selection = false;
            if (self.source_text) |text| self.allocator.free(text);
            self.source_text = null;
        },
        .target, .dnd_drop_performed, .dnd_finished, .action => {},
    }
}

fn offerListener(_: *wl.DataOffer, event: wl.DataOffer.Event, state: *OfferState) void {
    switch (event) {
        .offer => |offer| {
            const allocator = state.clipboard.allocator;
            const mime = allocator.dupe(u8, std.mem.span(offer.mime_type)) catch return;
            state.mimes.append(allocator, mime) catch allocator.free(mime);
        },
        .source_actions, .action => {},
    }
}

fn readAllFd(allocator: std.mem.Allocator, fd: i32) !?[]u8 {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    while (true) {
        var poll_fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&poll_fds, 1, read_timeout_ms);
        if (linux.errno(ready) != .SUCCESS) {
            if (linux.errno(ready) == .INTR) continue;
            return error.ReadFailed;
        }
        if (ready == 0) return error.ReadTimeout;

        try data.ensureUnusedCapacity(allocator, 4096);
        const dest = data.unusedCapacitySlice();
        const count = linux.read(fd, dest.ptr, dest.len);
        switch (linux.errno(count)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (count == 0) break;
        data.items.len += count;
        if (data.items.len > max_selection_bytes) return error.SelectionTooLarge;
    }
    return try data.toOwnedSlice(allocator);
}

fn writeAllFd(fd: i32, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        var poll_fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
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
