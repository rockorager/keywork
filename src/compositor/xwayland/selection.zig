//! X11 and Wayland selection interoperability.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DataDevice = @import("../wayland/data_device.zig");
const PrimarySelection = @import("../wayland/primary_selection.zig");
const SelectionSource = @import("../wayland/selection_source.zig").Source;
const c = @import("xcb.zig").c;

const wl = wayland.server.wl;
const log = std.log.scoped(.xwayland_selection);

const max_direct_transfer_size = 64 * 1024;
const invalid_fd: std.posix.fd_t = -1;

allocator: std.mem.Allocator,
event_loop: *wl.EventLoop,
connection: *c.xcb_connection_t,
screen: *c.xcb_screen_t,
atoms: Atoms,
wayland_selection: WaylandSelection,
window: c.xcb_window_t,
owner: c.xcb_window_t,
targets_request: ?TargetsRequest,
source: SelectionSource,
mime_types: std.ArrayList([:0]u8),
target_atoms: std.ArrayList(c.xcb_atom_t),
outgoing_transfers: std.ArrayList(*OutgoingTransfer),
incoming_transfers: std.ArrayList(*IncomingTransfer),

const TargetsRequest = struct {
    requestor: c.xcb_window_t,
    owner: c.xcb_window_t,
    timestamp: c.xcb_timestamp_t,

    fn matches(
        request: TargetsRequest,
        event: *const c.xcb_selection_notify_event_t,
        owner: c.xcb_window_t,
        selection: c.xcb_atom_t,
        target: c.xcb_atom_t,
    ) bool {
        return request.owner == owner and
            request.requestor == event.requestor and
            request.timestamp == event.time and
            event.selection == selection and
            event.target == target;
    }
};

pub const Atoms = struct {
    selection: c.xcb_atom_t,
    targets: c.xcb_atom_t,
    selection_data: c.xcb_atom_t,
    incr: c.xcb_atom_t,
    utf8_string: c.xcb_atom_t,
    text: c.xcb_atom_t,
};

pub const WaylandSelection = union(enum) {
    clipboard: *DataDevice,
    primary: *PrimarySelection,
    drag: *DataDevice,

    fn addListener(self: WaylandSelection, listener: DataDevice.SelectionListener) !void {
        switch (self) {
            .clipboard => |selection| try selection.addSelectionListener(listener),
            .primary => |selection| try selection.addSelectionListener(.{
                .context = listener.context,
                .changed = listener.changed,
                .offered = listener.offered,
            }),
            .drag => |selection| try selection.addDragSelectionListener(listener),
        }
    }

    fn removeListener(self: WaylandSelection, context: *anyopaque) void {
        switch (self) {
            .clipboard => |selection| selection.removeSelectionListener(context),
            .primary => |selection| selection.removeSelectionListener(context),
            .drag => |selection| selection.removeDragSelectionListener(context),
        }
    }

    fn hasSelection(self: WaylandSelection) bool {
        return switch (self) {
            .clipboard => |selection| selection.hasSelection(),
            .primary => |selection| selection.hasSelection(),
            .drag => |selection| selection.dragSourceInfo() != null,
        };
    }

    fn mimeTypes(self: WaylandSelection) []const [:0]const u8 {
        return switch (self) {
            .clipboard => |selection| selection.selectionMimeTypes(),
            .primary => |selection| selection.selectionMimeTypes(),
            .drag => |selection| if (selection.dragSourceInfo()) |source| source.mime_types else &.{},
        };
    }

    fn send(self: WaylandSelection, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
        switch (self) {
            .clipboard => |selection| selection.sendSelection(mime_type, fd),
            .primary => |selection| selection.sendSelection(mime_type, fd),
            .drag => |selection| selection.sendDragSelection(mime_type, fd),
        }
    }

    fn isExternal(self: WaylandSelection, source: *const SelectionSource) bool {
        return switch (self) {
            .clipboard => |selection| selection.externalSelectionIs(source),
            .primary => |selection| selection.externalSelectionIs(source),
            .drag => false,
        };
    }

    fn setExternal(self: WaylandSelection, source: ?*const SelectionSource) void {
        switch (self) {
            .clipboard => |selection| selection.setExternalSelection(source),
            .primary => |selection| selection.setExternalSelection(source),
            .drag => {},
        }
    }

    fn externalDestroyed(self: WaylandSelection, source: *const SelectionSource) void {
        switch (self) {
            .clipboard => |selection| selection.externalSourceDestroyed(source),
            .primary => |selection| selection.externalSourceDestroyed(source),
            .drag => {},
        }
    }

    fn supportsExternal(self: WaylandSelection) bool {
        return switch (self) {
            .clipboard, .primary => true,
            .drag => false,
        };
    }
};

const IncomingTransfer = struct {
    selection: *Self,
    window: c.xcb_window_t,
    target: c.xcb_atom_t,
    fd: std.posix.fd_t,
    event_source: ?*wl.EventSource = null,
    data: []u8 = &.{},
    offset: usize = 0,
    incremental: bool = false,
    final_chunk: bool = false,

    fn destroy(self: *IncomingTransfer) void {
        const selection = self.selection;
        if (self.event_source) |source| source.remove();
        closeFd(&self.fd);
        selection.allocator.free(self.data);
        _ = c.xcb_destroy_window(selection.connection, self.window);
        _ = c.xcb_flush(selection.connection);
        for (selection.incoming_transfers.items, 0..) |transfer, index| {
            if (transfer != self) continue;
            _ = selection.incoming_transfers.swapRemove(index);
            break;
        }
        selection.allocator.destroy(self);
    }

    fn write(self: *IncomingTransfer) void {
        while (self.offset < self.data.len) {
            const remaining = self.data[self.offset..];
            const result = std.c.write(self.fd, remaining.ptr, remaining.len);
            if (result > 0) {
                self.offset += @intCast(result);
                continue;
            }
            if (result < 0) switch (std.posix.errno(result)) {
                .INTR => continue,
                .AGAIN => {
                    if (self.event_source == null) {
                        self.event_source = self.selection.event_loop.addFd(
                            *IncomingTransfer,
                            self.fd,
                            .{ .writable = true, .hangup = true, .@"error" = true },
                            writable,
                            self,
                        ) catch {
                            self.destroy();
                            return;
                        };
                    }
                    return;
                },
                else => {},
            };
            self.destroy();
            return;
        }
        if (!self.incremental) {
            self.destroy();
            return;
        }
        if (self.event_source) |source| {
            self.event_source = null;
            source.remove();
        }
        self.selection.allocator.free(self.data);
        self.data = &.{};
        self.offset = 0;
        _ = c.xcb_delete_property(
            self.selection.connection,
            self.window,
            self.selection.atoms.selection_data,
        );
        _ = c.xcb_flush(self.selection.connection);
        if (self.final_chunk) self.destroy();
    }

    fn writable(_: std.posix.fd_t, mask: wl.EventMask, self: *IncomingTransfer) c_int {
        if (mask.hangup or mask.@"error") {
            self.destroy();
            return 0;
        }
        if (mask.writable) self.write();
        return 0;
    }
};

const OutgoingTransfer = struct {
    selection: *Self,
    request: c.xcb_selection_request_event_t,
    property: c.xcb_atom_t,
    fd: std.posix.fd_t,
    event_source: ?*wl.EventSource,
    data: std.ArrayList(u8) = .empty,
    incremental: bool = false,
    source_eof: bool = false,
    requestor_ready: bool = false,
    terminator_sent: bool = false,

    fn destroy(self: *OutgoingTransfer) void {
        const selection = self.selection;
        log.debug("destroyed outgoing X11 selection transfer to window {d}", .{self.request.requestor});
        if (self.event_source) |source| source.remove();
        closeFd(&self.fd);
        self.data.deinit(selection.allocator);
        for (selection.outgoing_transfers.items, 0..) |transfer, index| {
            if (transfer != self) continue;
            _ = selection.outgoing_transfers.swapRemove(index);
            break;
        }
        selection.allocator.destroy(self);
    }

    fn fail(self: *OutgoingTransfer) void {
        if (!self.incremental) self.selection.sendNotify(self.request, c.XCB_ATOM_NONE);
        self.destroy();
    }

    fn finishDirect(self: *OutgoingTransfer) void {
        _ = c.xcb_change_property(
            self.selection.connection,
            c.XCB_PROP_MODE_REPLACE,
            self.request.requestor,
            self.property,
            self.request.target,
            8,
            @intCast(self.data.items.len),
            if (self.data.items.len == 0) null else self.data.items.ptr,
        );
        self.selection.sendNotify(self.request, self.property);
        self.destroy();
    }

    fn pauseRead(self: *OutgoingTransfer) bool {
        const source = self.event_source orelse return true;
        self.event_source = null;
        source.remove();
        return true;
    }

    fn resumeRead(self: *OutgoingTransfer) bool {
        if (self.source_eof) return true;
        if (self.event_source != null) return true;
        self.event_source = self.selection.event_loop.addFd(
            *OutgoingTransfer,
            self.fd,
            .{ .readable = true, .hangup = true, .@"error" = true },
            readable,
            self,
        ) catch {
            self.fail();
            return false;
        };
        return true;
    }

    fn stopRead(self: *OutgoingTransfer) void {
        if (self.event_source) |source| {
            self.event_source = null;
            source.remove();
        }
        closeFd(&self.fd);
    }

    fn beginIncremental(self: *OutgoingTransfer) void {
        self.incremental = true;
        log.debug("started outgoing INCR transfer to window {d}", .{self.request.requestor});
        const event_mask: u32 = c.XCB_EVENT_MASK_PROPERTY_CHANGE;
        _ = c.xcb_change_window_attributes(
            self.selection.connection,
            self.request.requestor,
            c.XCB_CW_EVENT_MASK,
            &event_mask,
        );
        const size_hint: u32 = max_direct_transfer_size;
        _ = c.xcb_change_property(
            self.selection.connection,
            c.XCB_PROP_MODE_REPLACE,
            self.request.requestor,
            self.property,
            self.selection.atoms.incr,
            32,
            1,
            &size_hint,
        );
        self.selection.sendNotify(self.request, self.property);
        _ = self.pauseRead();
    }

    fn sendChunk(self: *OutgoingTransfer) void {
        std.debug.assert(self.incremental and self.requestor_ready and self.data.items.len > 0);
        log.debug("sent outgoing INCR chunk of {d} bytes to window {d}", .{
            self.data.items.len,
            self.request.requestor,
        });
        _ = c.xcb_change_property(
            self.selection.connection,
            c.XCB_PROP_MODE_REPLACE,
            self.request.requestor,
            self.property,
            self.request.target,
            8,
            @intCast(self.data.items.len),
            self.data.items.ptr,
        );
        self.data.clearRetainingCapacity();
        self.requestor_ready = false;
        _ = c.xcb_flush(self.selection.connection);
        if (!self.source_eof) _ = self.resumeRead();
    }

    fn sendTerminator(self: *OutgoingTransfer) void {
        std.debug.assert(self.incremental and self.requestor_ready and self.source_eof);
        log.debug("sent outgoing INCR terminator to window {d}", .{self.request.requestor});
        _ = c.xcb_change_property(
            self.selection.connection,
            c.XCB_PROP_MODE_REPLACE,
            self.request.requestor,
            self.property,
            self.request.target,
            8,
            0,
            null,
        );
        self.terminator_sent = true;
        self.requestor_ready = false;
        _ = c.xcb_flush(self.selection.connection);
    }

    fn propertyDeleted(self: *OutgoingTransfer) void {
        std.debug.assert(self.incremental);
        log.debug("received outgoing INCR property deletion from window {d}", .{self.request.requestor});
        if (self.terminator_sent) {
            self.destroy();
            return;
        }
        self.requestor_ready = true;
        if (self.data.items.len > 0) {
            self.sendChunk();
        } else if (self.source_eof) {
            self.sendTerminator();
        } else {
            _ = self.resumeRead();
        }
    }

    fn readable(_: std.posix.fd_t, mask: wl.EventMask, self: *OutgoingTransfer) c_int {
        if (!(mask.readable or mask.hangup or mask.@"error")) return 0;
        if (self.data.items.len >= max_direct_transfer_size) {
            _ = self.pauseRead();
            return 0;
        }
        var buffer: [4096]u8 = undefined;
        while (true) {
            const available = max_direct_transfer_size - self.data.items.len;
            const result = std.c.read(self.fd, &buffer, @min(buffer.len, available));
            if (result > 0) {
                const count: usize = @intCast(result);
                self.data.appendSlice(self.selection.allocator, buffer[0..count]) catch {
                    self.fail();
                    return 0;
                };
                if (self.data.items.len >= max_direct_transfer_size) {
                    if (!self.incremental) {
                        self.beginIncremental();
                    } else if (self.requestor_ready) {
                        self.sendChunk();
                    } else {
                        _ = self.pauseRead();
                    }
                    return 0;
                }
                continue;
            }
            if (result == 0) {
                self.source_eof = true;
                log.debug("reached outgoing INCR source EOF for window {d}", .{self.request.requestor});
                self.stopRead();
                if (!self.incremental) {
                    self.finishDirect();
                } else if (self.requestor_ready) {
                    if (self.data.items.len > 0) {
                        self.sendChunk();
                    } else {
                        self.sendTerminator();
                    }
                }
                return 0;
            }
            switch (std.posix.errno(result)) {
                .INTR => continue,
                .AGAIN => {
                    if (mask.hangup or mask.@"error") self.fail();
                    return 0;
                },
                else => {
                    self.fail();
                    return 0;
                },
            }
        }
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    event_loop: *wl.EventLoop,
    connection: *c.xcb_connection_t,
    screen: *c.xcb_screen_t,
    atoms: Atoms,
    wayland_selection: WaylandSelection,
) !void {
    self.* = .{
        .allocator = allocator,
        .event_loop = event_loop,
        .connection = connection,
        .screen = screen,
        .atoms = atoms,
        .wayland_selection = wayland_selection,
        .window = c.xcb_generate_id(connection),
        .owner = c.XCB_WINDOW_NONE,
        .targets_request = null,
        .source = .{
            .context = self,
            .mime_types = sourceMimeTypes,
            .send = sourceSend,
            .cancel = sourceCancelled,
        },
        .mime_types = .empty,
        .target_atoms = .empty,
        .outgoing_transfers = .empty,
        .incoming_transfers = .empty,
    };
    if (self.window == c.XCB_WINDOW_NONE) return error.XidAllocationFailed;
    errdefer self.mime_types.deinit(allocator);
    errdefer self.target_atoms.deinit(allocator);
    errdefer self.outgoing_transfers.deinit(allocator);
    errdefer self.incoming_transfers.deinit(allocator);
    const event_mask: u32 = c.XCB_EVENT_MASK_PROPERTY_CHANGE;
    try checkRequest(connection, c.xcb_create_window_checked(
        connection,
        c.XCB_COPY_FROM_PARENT,
        self.window,
        screen.root,
        0,
        0,
        10,
        10,
        0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.root_visual,
        c.XCB_CW_EVENT_MASK,
        &event_mask,
    ));
    errdefer _ = c.xcb_destroy_window(connection, self.window);
    try checkRequest(connection, c.xcb_xfixes_select_selection_input_checked(
        connection,
        self.window,
        atoms.selection,
        c.XCB_XFIXES_SELECTION_EVENT_MASK_SET_SELECTION_OWNER |
            c.XCB_XFIXES_SELECTION_EVENT_MASK_SELECTION_WINDOW_DESTROY |
            c.XCB_XFIXES_SELECTION_EVENT_MASK_SELECTION_CLIENT_CLOSE,
    ));
    try wayland_selection.addListener(.{
        .context = self,
        .changed = waylandSelectionChanged,
        .offered = waylandMimeOffered,
    });
    errdefer wayland_selection.removeListener(self);
    self.updateOwner();
    self.discoverCurrentOwner();
}

pub fn deinit(self: *Self) void {
    self.wayland_selection.removeListener(self);
    self.clearExternalSource();
    self.cancelTargetsRequest();
    while (self.outgoing_transfers.items.len > 0) {
        self.outgoing_transfers.items[self.outgoing_transfers.items.len - 1].destroy();
    }
    while (self.incoming_transfers.items.len > 0) {
        self.incoming_transfers.items[self.incoming_transfers.items.len - 1].destroy();
    }
    self.releaseOwnership();
    _ = c.xcb_destroy_window(self.connection, self.window);
    _ = c.xcb_flush(self.connection);
    self.clearMimeTypes();
    self.mime_types.deinit(self.allocator);
    self.target_atoms.deinit(self.allocator);
    self.outgoing_transfers.deinit(self.allocator);
    self.incoming_transfers.deinit(self.allocator);
    self.* = undefined;
}

pub fn handlesSelection(self: *const Self, atom: c.xcb_atom_t) bool {
    return self.atoms.selection == atom;
}

pub fn ownerWindow(self: *const Self) c.xcb_window_t {
    return self.window;
}

pub fn targetAtomForMime(self: *Self, mime_type: [:0]const u8) ?c.xcb_atom_t {
    return self.mimeAtom(mime_type);
}

pub fn mimeForTargetAtom(self: *Self, atom: c.xcb_atom_t) ?[:0]u8 {
    return self.targetMime(atom);
}

pub fn reclaimWaylandSelection(self: *Self) void {
    if (self.wayland_selection.hasSelection()) self.updateOwner();
}

pub fn receiveExternalData(
    self: *Self,
    target: c.xcb_atom_t,
    timestamp: c.xcb_timestamp_t,
    fd: std.posix.fd_t,
) void {
    const duplicate = std.c.fcntl(
        fd,
        std.posix.F.DUPFD_CLOEXEC,
        @as(c_int, 0),
    );
    if (duplicate < 0) return;
    self.startIncomingTransferForTarget(target, timestamp, duplicate) catch {};
}

pub fn ownsWindow(self: *const Self, window: c.xcb_window_t) bool {
    if (self.window == window) return true;
    for (self.incoming_transfers.items) |transfer| {
        if (transfer.window == window) return true;
    }
    return false;
}

pub fn handleRequest(self: *Self, request: *const c.xcb_selection_request_event_t) void {
    if (request.owner != self.window or request.selection != self.atoms.selection) return;
    if (!self.wayland_selection.hasSelection()) {
        self.sendNotify(request.*, c.XCB_ATOM_NONE);
        return;
    }
    const property = if (request.property == c.XCB_ATOM_NONE) request.target else request.property;
    if (request.target == self.atoms.targets) {
        self.sendTargets(request.*, property);
    } else {
        self.sendData(request.*, property);
    }
}

pub fn handleRequestorDestroyed(self: *Self, window: c.xcb_window_t) void {
    var index: usize = 0;
    while (index < self.outgoing_transfers.items.len) {
        const transfer = self.outgoing_transfers.items[index];
        if (transfer.request.requestor == window) {
            log.debug("cancelled outgoing selection transfer for destroyed window {d}", .{window});
            transfer.destroy();
        } else {
            index += 1;
        }
    }
}

pub fn handleXfixesNotify(self: *Self, event: *const c.xcb_xfixes_selection_notify_event_t) void {
    if (event.selection != self.atoms.selection or event.window != self.window) return;
    self.cancelTargetsRequest();
    self.owner = event.owner;
    if (event.owner == self.window) {
        self.clearExternalSource();
        return;
    }
    self.clearExternalSource();
    if (event.owner == c.XCB_WINDOW_NONE) {
        while (self.incoming_transfers.items.len > 0) {
            self.incoming_transfers.items[self.incoming_transfers.items.len - 1].destroy();
        }
        return;
    }
    if (!self.wayland_selection.supportsExternal()) return;
    self.requestTargets(event.timestamp);
}

pub fn handleNotify(self: *Self, event: *const c.xcb_selection_notify_event_t) void {
    if (self.targets_request) |request| {
        if (request.matches(event, self.owner, self.atoms.selection, self.atoms.targets)) {
            self.targets_request = null;
            defer {
                _ = c.xcb_destroy_window(self.connection, request.requestor);
                _ = c.xcb_flush(self.connection);
            }
            self.receiveTargets(request.requestor, event);
            return;
        }
    }
    if (event.selection != self.atoms.selection) return;
    if (event.target == self.atoms.targets) {
        return;
    }
    for (self.incoming_transfers.items) |transfer| {
        if (transfer.window != event.requestor or transfer.target != event.target) continue;
        if (transfer.event_source != null) return;
        self.receiveData(transfer, event);
        return;
    }
}

pub fn handlePropertyNotify(self: *Self, event: *const c.xcb_property_notify_event_t) bool {
    if (event.state == c.XCB_PROPERTY_DELETE) {
        for (self.outgoing_transfers.items) |transfer| {
            if (!transfer.incremental or
                transfer.request.requestor != event.window or
                transfer.property != event.atom) continue;
            transfer.propertyDeleted();
            return true;
        }
    } else if (event.state == c.XCB_PROPERTY_NEW_VALUE) {
        for (self.incoming_transfers.items) |transfer| {
            if (!transfer.incremental or
                transfer.window != event.window or
                event.atom != self.atoms.selection_data or
                transfer.data.len != 0) continue;
            self.receiveIncrementalChunk(transfer);
            return true;
        }
    }
    return self.ownsWindow(event.window);
}

fn waylandSelectionChanged(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.wayland_selection.isExternal(&self.source)) return;
    self.updateOwner();
}

fn waylandMimeOffered(_: *anyopaque, _: [*:0]const u8) void {}

fn sourceMimeTypes(context: *anyopaque) []const [:0]const u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    return @ptrCast(self.mime_types.items);
}

fn sourceSend(context: *anyopaque, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const duplicate = std.c.fcntl(
        fd,
        std.posix.F.DUPFD_CLOEXEC,
        @as(c_int, 0),
    );
    if (duplicate < 0) return;
    self.startIncomingTransfer(std.mem.span(mime_type), duplicate) catch {};
}

fn sourceCancelled(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.clearMimeTypes();
}

fn discoverCurrentOwner(self: *Self) void {
    const reply = c.xcb_get_selection_owner_reply(
        self.connection,
        c.xcb_get_selection_owner(self.connection, self.atoms.selection),
        null,
    ) orelse return;
    defer std.c.free(reply);
    self.owner = reply.*.owner;
    if (self.wayland_selection.supportsExternal() and
        self.owner != c.XCB_WINDOW_NONE and self.owner != self.window)
    {
        self.requestTargets(c.XCB_CURRENT_TIME);
    }
}

fn requestTargets(self: *Self, timestamp: c.xcb_timestamp_t) void {
    std.debug.assert(self.targets_request == null);
    const requestor = c.xcb_generate_id(self.connection);
    if (requestor == c.XCB_WINDOW_NONE) {
        log.err("failed to allocate an X11 TARGETS requestor ID", .{});
        return;
    }
    checkRequest(self.connection, c.xcb_create_window_checked(
        self.connection,
        c.XCB_COPY_FROM_PARENT,
        requestor,
        self.window,
        0,
        0,
        1,
        1,
        0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        self.screen.root_visual,
        0,
        null,
    )) catch {
        log.err("failed to create an X11 TARGETS requestor window", .{});
        return;
    };
    self.targets_request = .{
        .requestor = requestor,
        .owner = self.owner,
        .timestamp = timestamp,
    };
    _ = c.xcb_delete_property(self.connection, requestor, self.atoms.selection_data);
    _ = c.xcb_convert_selection(
        self.connection,
        requestor,
        self.atoms.selection,
        self.atoms.targets,
        self.atoms.selection_data,
        timestamp,
    );
    if (c.xcb_flush(self.connection) <= 0) {
        log.err("failed to request X11 selection targets", .{});
        self.cancelTargetsRequest();
    }
}

fn cancelTargetsRequest(self: *Self) void {
    const request = self.targets_request orelse return;
    self.targets_request = null;
    _ = c.xcb_destroy_window(self.connection, request.requestor);
    _ = c.xcb_flush(self.connection);
}

fn receiveTargets(
    self: *Self,
    requestor: c.xcb_window_t,
    event: *const c.xcb_selection_notify_event_t,
) void {
    if (self.owner == self.window or self.owner == c.XCB_WINDOW_NONE) return;
    if (event.property != self.atoms.selection_data) return;
    const reply = c.xcb_get_property_reply(
        self.connection,
        c.xcb_get_property(
            self.connection,
            1,
            requestor,
            self.atoms.selection_data,
            c.XCB_ATOM_ATOM,
            0,
            4096,
        ),
        null,
    ) orelse return;
    defer std.c.free(reply);
    if (reply.*.type != c.XCB_ATOM_ATOM or reply.*.format != 32 or reply.*.bytes_after != 0) {
        return;
    }

    self.clearExternalSource();
    const count: usize = @intCast(reply.*.value_len);
    const data = c.xcb_get_property_value(reply) orelse return;
    const atoms: [*]const c.xcb_atom_t = @ptrCast(@alignCast(data));
    for (atoms[0..count]) |target| {
        const mime_type = self.targetMime(target) orelse continue;
        var duplicate = false;
        for (self.mime_types.items) |existing| {
            if (std.mem.eql(u8, existing, mime_type)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            self.allocator.free(mime_type);
            continue;
        }
        self.mime_types.append(self.allocator, mime_type) catch {
            self.allocator.free(mime_type);
            self.clearMimeTypes();
            return;
        };
        self.target_atoms.append(self.allocator, target) catch {
            self.allocator.free(self.mime_types.pop().?);
            self.clearMimeTypes();
            return;
        };
    }
    if (self.mime_types.items.len > 0) self.wayland_selection.setExternal(&self.source);
}

fn targetMime(self: *Self, atom: c.xcb_atom_t) ?[:0]u8 {
    if (atom == self.atoms.targets) return null;
    if (atom == self.atoms.utf8_string) {
        return self.allocator.dupeZ(u8, "text/plain;charset=utf-8") catch null;
    }
    if (atom == self.atoms.text) {
        return self.allocator.dupeZ(u8, "text/plain") catch null;
    }
    const reply = c.xcb_get_atom_name_reply(
        self.connection,
        c.xcb_get_atom_name(self.connection, atom),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    const length: usize = @intCast(c.xcb_get_atom_name_name_length(reply));
    const name = c.xcb_get_atom_name_name(reply) orelse return null;
    const bytes = @as([*]const u8, @ptrCast(name))[0..length];
    if (std.mem.indexOfScalar(u8, bytes, '/') == null or !std.unicode.utf8ValidateSlice(bytes)) {
        return null;
    }
    return self.allocator.dupeZ(u8, bytes) catch null;
}

fn clearExternalSource(self: *Self) void {
    if (self.wayland_selection.isExternal(&self.source)) {
        self.wayland_selection.externalDestroyed(&self.source);
    }
    self.clearMimeTypes();
}

fn clearMimeTypes(self: *Self) void {
    for (self.mime_types.items) |mime_type| self.allocator.free(mime_type);
    self.mime_types.clearRetainingCapacity();
    self.target_atoms.clearRetainingCapacity();
}

fn startIncomingTransfer(self: *Self, mime_type: []const u8, fd: std.posix.fd_t) !void {
    const target = for (self.mime_types.items, self.target_atoms.items) |offered, atom| {
        if (std.mem.eql(u8, offered, mime_type)) break atom;
    } else {
        _ = std.c.close(fd);
        return error.UnsupportedMimeType;
    };
    try self.startIncomingTransferForTarget(target, c.XCB_CURRENT_TIME, fd);
}

fn startIncomingTransferForTarget(
    self: *Self,
    target: c.xcb_atom_t,
    timestamp: c.xcb_timestamp_t,
    fd: std.posix.fd_t,
) !void {
    errdefer _ = std.c.close(fd);
    try setNonblocking(fd);

    const transfer = try self.allocator.create(IncomingTransfer);
    errdefer self.allocator.destroy(transfer);
    const window = c.xcb_generate_id(self.connection);
    if (window == c.XCB_WINDOW_NONE) return error.XidAllocationFailed;
    const event_mask: u32 = c.XCB_EVENT_MASK_PROPERTY_CHANGE;
    try checkRequest(self.connection, c.xcb_create_window_checked(
        self.connection,
        c.XCB_COPY_FROM_PARENT,
        window,
        self.screen.root,
        0,
        0,
        10,
        10,
        0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        self.screen.root_visual,
        c.XCB_CW_EVENT_MASK,
        &event_mask,
    ));
    errdefer _ = c.xcb_destroy_window(self.connection, window);
    transfer.* = .{
        .selection = self,
        .window = window,
        .target = target,
        .fd = fd,
    };
    try self.incoming_transfers.append(self.allocator, transfer);
    _ = c.xcb_convert_selection(
        self.connection,
        window,
        self.atoms.selection,
        target,
        self.atoms.selection_data,
        timestamp,
    );
    if (c.xcb_flush(self.connection) <= 0) {
        transfer.destroy();
        return;
    }
}

fn receiveData(
    self: *Self,
    transfer: *IncomingTransfer,
    event: *const c.xcb_selection_notify_event_t,
) void {
    if (event.property == c.XCB_ATOM_NONE) {
        transfer.destroy();
        return;
    }
    const reply = c.xcb_get_property_reply(
        self.connection,
        c.xcb_get_property(
            self.connection,
            1,
            transfer.window,
            self.atoms.selection_data,
            c.XCB_GET_PROPERTY_TYPE_ANY,
            0,
            max_direct_transfer_size / 4 + 1,
        ),
        null,
    ) orelse {
        transfer.destroy();
        return;
    };
    defer std.c.free(reply);
    if (reply.*.type == self.atoms.incr) {
        transfer.incremental = true;
        _ = c.xcb_flush(self.connection);
        return;
    }
    const length: usize = @intCast(c.xcb_get_property_value_length(reply));
    if (reply.*.type == c.XCB_ATOM_NONE or reply.*.format != 8 or
        reply.*.bytes_after != 0 or length > max_direct_transfer_size)
    {
        transfer.destroy();
        return;
    }
    const value = c.xcb_get_property_value(reply);
    transfer.data = self.allocator.alloc(u8, length) catch {
        transfer.destroy();
        return;
    };
    if (length > 0) @memcpy(transfer.data, @as([*]const u8, @ptrCast(value))[0..length]);
    transfer.write();
}

fn receiveIncrementalChunk(self: *Self, transfer: *IncomingTransfer) void {
    const reply = c.xcb_get_property_reply(
        self.connection,
        c.xcb_get_property(
            self.connection,
            0,
            transfer.window,
            self.atoms.selection_data,
            c.XCB_GET_PROPERTY_TYPE_ANY,
            0,
            max_direct_transfer_size / 4 + 1,
        ),
        null,
    ) orelse {
        transfer.destroy();
        return;
    };
    defer std.c.free(reply);
    const length: usize = @intCast(c.xcb_get_property_value_length(reply));
    if (reply.*.type == c.XCB_ATOM_NONE or reply.*.format != 8 or
        reply.*.bytes_after != 0 or length > max_direct_transfer_size)
    {
        transfer.destroy();
        return;
    }
    transfer.final_chunk = length == 0;
    const value = c.xcb_get_property_value(reply);
    transfer.data = self.allocator.alloc(u8, length) catch {
        transfer.destroy();
        return;
    };
    if (length > 0) @memcpy(transfer.data, @as([*]const u8, @ptrCast(value))[0..length]);
    transfer.write();
}

fn updateOwner(self: *Self) void {
    self.cancelTargetsRequest();
    if (!self.wayland_selection.hasSelection()) {
        self.releaseOwnership();
        _ = c.xcb_flush(self.connection);
        return;
    }
    self.owner = self.window;
    _ = c.xcb_set_selection_owner(
        self.connection,
        self.window,
        self.atoms.selection,
        c.XCB_CURRENT_TIME,
    );
    if (c.xcb_flush(self.connection) <= 0) {
        log.err("failed to update X11 selection ownership", .{});
    }
}

fn releaseOwnership(self: *Self) void {
    const reply = c.xcb_get_selection_owner_reply(
        self.connection,
        c.xcb_get_selection_owner(self.connection, self.atoms.selection),
        null,
    ) orelse return;
    defer std.c.free(reply);
    if (reply.*.owner != self.window) return;
    _ = c.xcb_set_selection_owner(
        self.connection,
        c.XCB_WINDOW_NONE,
        self.atoms.selection,
        c.XCB_CURRENT_TIME,
    );
}

fn sendTargets(self: *Self, request: c.xcb_selection_request_event_t, property: c.xcb_atom_t) void {
    var targets: std.ArrayList(c.xcb_atom_t) = .empty;
    defer targets.deinit(self.allocator);
    targets.append(self.allocator, self.atoms.targets) catch return self.sendNotify(request, c.XCB_ATOM_NONE);
    for (self.wayland_selection.mimeTypes()) |mime_type| {
        const atom = self.mimeAtom(mime_type) orelse continue;
        if (std.mem.indexOfScalar(c.xcb_atom_t, targets.items, atom) != null) continue;
        targets.append(self.allocator, atom) catch return self.sendNotify(request, c.XCB_ATOM_NONE);
    }
    _ = c.xcb_change_property(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        request.requestor,
        property,
        c.XCB_ATOM_ATOM,
        32,
        @intCast(targets.items.len),
        targets.items.ptr,
    );
    self.sendNotify(request, property);
}

fn sendData(self: *Self, request: c.xcb_selection_request_event_t, property: c.xcb_atom_t) void {
    const mime_type = self.mimeForTarget(request.target) orelse {
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    };
    var transfer_index: usize = 0;
    while (transfer_index < self.outgoing_transfers.items.len) {
        const transfer = self.outgoing_transfers.items[transfer_index];
        if (transfer.request.requestor == request.requestor) {
            transfer.fail();
        } else {
            transfer_index += 1;
        }
    }

    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe2(&fds, .{ .CLOEXEC = true }) < 0) {
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    }
    var read_fd = fds[0];
    var write_fd = fds[1];
    defer closeFd(&read_fd);
    defer closeFd(&write_fd);
    setNonblocking(read_fd) catch {
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    };
    const transfer = self.allocator.create(OutgoingTransfer) catch {
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    };
    var transfer_registered = false;
    defer if (!transfer_registered) self.allocator.destroy(transfer);
    transfer.* = .{
        .selection = self,
        .request = request,
        .property = property,
        .fd = read_fd,
        .event_source = undefined,
    };
    const event_source = self.event_loop.addFd(
        *OutgoingTransfer,
        read_fd,
        .{ .readable = true, .hangup = true, .@"error" = true },
        OutgoingTransfer.readable,
        transfer,
    ) catch {
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    };
    transfer.event_source = event_source;
    self.outgoing_transfers.append(self.allocator, transfer) catch {
        event_source.remove();
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    };
    transfer_registered = true;
    read_fd = invalid_fd;
    self.wayland_selection.send(mime_type.ptr, write_fd);
    closeFd(&write_fd);
}

fn sendNotify(self: *Self, request: c.xcb_selection_request_event_t, property: c.xcb_atom_t) void {
    var event = std.mem.zeroes(c.xcb_selection_notify_event_t);
    event.response_type = c.XCB_SELECTION_NOTIFY;
    event.time = request.time;
    event.requestor = request.requestor;
    event.selection = request.selection;
    event.target = request.target;
    event.property = property;
    _ = c.xcb_send_event(
        self.connection,
        0,
        request.requestor,
        c.XCB_EVENT_MASK_NO_EVENT,
        @ptrCast(&event),
    );
    _ = c.xcb_flush(self.connection);
}

fn mimeAtom(self: *Self, mime_type: [:0]const u8) ?c.xcb_atom_t {
    if (std.mem.eql(u8, mime_type, "text/plain;charset=utf-8")) return self.atoms.utf8_string;
    if (std.mem.eql(u8, mime_type, "text/plain")) return self.atoms.text;
    if (mime_type.len > std.math.maxInt(u16)) return null;
    const reply = c.xcb_intern_atom_reply(
        self.connection,
        c.xcb_intern_atom(self.connection, 0, @intCast(mime_type.len), mime_type.ptr),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    return reply.*.atom;
}

fn mimeForTarget(self: *Self, target: c.xcb_atom_t) ?[:0]const u8 {
    for (self.wayland_selection.mimeTypes()) |mime_type| {
        if (self.mimeAtom(mime_type)) |atom| {
            if (atom == target) return mime_type;
        }
    }
    return null;
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

fn closeFd(fd: *std.posix.fd_t) void {
    if (fd.* < 0) return;
    _ = std.c.close(fd.*);
    fd.* = invalid_fd;
}

fn checkRequest(connection: *c.xcb_connection_t, cookie: c.xcb_void_cookie_t) !void {
    const x_error = c.xcb_request_check(connection, cookie) orelse return;
    defer std.c.free(x_error);
    return error.X11RequestFailed;
}

test "TARGETS replies match their requestor generation" {
    const request: TargetsRequest = .{
        .requestor = 10,
        .owner = 20,
        .timestamp = 30,
    };
    var event = std.mem.zeroes(c.xcb_selection_notify_event_t);
    event.requestor = request.requestor;
    event.selection = 40;
    event.target = 50;
    event.time = request.timestamp;

    try std.testing.expect(request.matches(&event, request.owner, 40, 50));

    event.requestor = 11;
    try std.testing.expect(!request.matches(&event, request.owner, 40, 50));

    event.requestor = request.requestor;
    try std.testing.expect(!request.matches(&event, 21, 40, 50));
}
