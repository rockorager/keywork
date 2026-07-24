//! Shared DRM device, connector outputs, and session ownership.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DrmOutput = @import("drm.zig");
const Gbm = @import("gbm.zig");
const Session = @import("session.zig");
const render = @import("../render/types.zig");

const c = @cImport({
    @cInclude("libudev.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/sysmacros.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});
const wl = wayland.server.wl;
const log = std.log.scoped(.drm);

allocator: std.mem.Allocator,
io: std.Io,
session: *Session,
session_listener: Session.Listener,
event_loop: *wl.EventLoop,
event_source: ?*wl.EventSource,
udev: ?*c.struct_udev,
udev_monitor: ?*c.struct_udev_monitor,
hotplug_source: ?*wl.EventSource,
device_path: ?[:0]u8,
device: ?Session.Device,
device_number: ?c.dev_t,
gbm_device: ?Gbm,
atomic: bool,
active_outputs: std.ArrayList(*DrmOutput),
retired_outputs: std.ArrayList(*DrmOutput),
leases: std.ArrayList(LeaseTracking),
listener: ?Listener,
initialized: bool,
failed: bool,

pub const Listener = struct {
    context: *anyopaque,
    added: *const fn (*anyopaque, *DrmOutput) void,
    removing: *const fn (*anyopaque, *DrmOutput) void,
    failed: *const fn (*anyopaque) void,
    activated: *const fn (*anyopaque) void = ignoreEvent,
    deactivating: *const fn (*anyopaque) void = ignoreEvent,
    changed: *const fn (*anyopaque, *DrmOutput) void = ignoreOutputEvent,
    lease_revoked: *const fn (*anyopaque, u32) void = ignoreLeaseRevoked,
};

pub const Lease = struct {
    fd: std.posix.fd_t,
    lessee_id: u32,
};

const LeaseTracking = struct {
    lessee_id: u32,
    connector_ids: []u32,
};

fn ignoreEvent(_: *anyopaque) void {}
fn ignoreOutputEvent(_: *anyopaque, _: *DrmOutput) void {}
fn ignoreLeaseRevoked(_: *anyopaque, _: u32) void {}

pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, event_loop: *wl.EventLoop, session: *Session, device_path: ?[]const u8) !void {
    const path = if (device_path) |value| try allocator.dupeSentinel(u8, value, 0) else null;
    self.* = .{
        .allocator = allocator,
        .io = io,
        .session = session,
        .session_listener = .{ .context = self, .activated = handleSessionActivated, .deactivated = handleSessionDeactivated, .failed = handleSessionFailed },
        .event_loop = event_loop,
        .event_source = null,
        .udev = null,
        .udev_monitor = null,
        .hotplug_source = null,
        .device_path = path,
        .device = null,
        .device_number = null,
        .gbm_device = null,
        .atomic = false,
        .active_outputs = .empty,
        .retired_outputs = .empty,
        .leases = .empty,
        .listener = null,
        .initialized = false,
        .failed = false,
    };
    errdefer if (self.device_path) |value| allocator.free(value);
    errdefer {
        self.destroyList(&self.active_outputs);
        self.destroyList(&self.retired_outputs);
        self.active_outputs.deinit(allocator);
        self.retired_outputs.deinit(allocator);
    }
    try session.addListener(&self.session_listener);
    errdefer session.removeListener(&self.session_listener);
    if (!session.isActive()) return error.SessionInactive;
    if (self.failed or self.device == null) return error.DrmInitializationFailed;
    errdefer self.deactivate();
    try self.initHotplugMonitor();
    self.initialized = true;
}

pub fn deinit(self: *Self) void {
    self.listener = null;
    self.initialized = false;
    self.session.removeListener(&self.session_listener);
    self.deinitHotplugMonitor();
    // Normally the protocol owner revokes first. This fallback prevents a
    // still-active lessor from retaining leases during partial initialization.
    while (self.leases.items.len > 0) self.revokeLease(self.leases.items[0].lessee_id);
    self.deactivate();
    self.leases.deinit(self.allocator);
    self.destroyList(&self.active_outputs);
    self.active_outputs.deinit(self.allocator);
    self.retired_outputs.deinit(self.allocator);
    if (self.device_path) |value| self.allocator.free(value);
    self.* = undefined;
}

pub fn outputs(self: *Self) []const *DrmOutput {
    return self.active_outputs.items;
}

pub fn deviceId(self: *const Self) ?render.DrmDeviceId {
    const number = self.device_number orelse return null;
    return .{
        .major = @intCast(c.major(number)),
        .minor = @intCast(c.minor(number)),
    };
}

/// Opens a non-master descriptor for this DRM device. The caller owns and must
/// close the returned descriptor.
pub fn openNonMasterFd(self: *Self) !std.posix.fd_t {
    if (self.failed or self.device == null or !self.session.isActive()) return error.SessionInactive;
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, self.device_path.?, .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    }, 0);
    errdefer _ = std.c.close(fd);
    if (c.drmIsMaster(fd) == 1 and c.drmDropMaster(fd) != 0) return error.DropMasterFailed;
    return fd;
}

/// Creates and tracks a DRM lease. The caller owns the returned descriptor;
/// the lessee ID remains tracked until passed to `revokeLease` or revoked by
/// the kernel.
pub fn createLease(self: *Self, outputs_to_lease: []const *DrmOutput) !Lease {
    if (self.failed or self.device == null or !self.session.isActive()) return error.SessionInactive;
    if (outputs_to_lease.len == 0) return error.EmptyLease;

    var objects: std.ArrayList(u32) = .empty;
    defer objects.deinit(self.allocator);
    const connector_ids = try self.allocator.alloc(u32, outputs_to_lease.len);
    errdefer self.allocator.free(connector_ids);
    for (outputs_to_lease, 0..) |output, index| {
        if (self.findOutput(output.connector_id) != output) return error.UnknownOutput;
        if (self.outputLeased(output)) return error.OutputAlreadyLeased;
        for (connector_ids[0..index]) |id| if (id == output.connector_id) return error.DuplicateOutput;
        const plane_id = output.primary_plane_id orelse return error.OutputNotLeaseable;
        connector_ids[index] = output.connector_id;
        for ([_]u32{ output.connector_id, output.crtc_id, plane_id }) |object_id| {
            if (object_id == 0) return error.OutputNotLeaseable;
            if (!containsId(objects.items, object_id)) try objects.append(self.allocator, object_id);
        }
    }
    try self.leases.ensureUnusedCapacity(self.allocator, 1);
    var lessee_id: u32 = 0;
    const lease_fd = c.drmModeCreateLease(
        self.device.?.fd,
        objects.items.ptr,
        @intCast(objects.items.len),
        @bitCast(std.c.O{ .CLOEXEC = true }),
        &lessee_id,
    );
    if (lease_fd < 0) return error.CreateLeaseFailed;
    self.leases.appendAssumeCapacity(.{ .lessee_id = lessee_id, .connector_ids = connector_ids });
    return .{ .fd = lease_fd, .lessee_id = lessee_id };
}

pub fn revokeLease(self: *Self, lessee_id: u32) void {
    for (self.leases.items, 0..) |lease, index| if (lease.lessee_id == lessee_id) {
        // The session deactivation callback runs after Session has cleared its
        // active flag, but before this device fd is closed.
        if (self.device != null and c.drmModeRevokeLease(self.device.?.fd, lessee_id) != 0) {
            if (self.session.isActive()) {
                log.err("failed to revoke DRM lease {d}", .{lessee_id});
            } else {
                log.debug("DRM lease {d} outlived session master access", .{lessee_id});
            }
        }
        self.allocator.free(lease.connector_ids);
        _ = self.leases.orderedRemove(index);
        return;
    };
}

pub fn outputLeased(self: *const Self, output: *const DrmOutput) bool {
    for (self.leases.items) |lease| for (lease.connector_ids) |connector_id| {
        if (connector_id == output.connector_id) return true;
    };
    return false;
}

fn containsId(ids: []const u32, sought: u32) bool {
    for (ids) |id| if (id == sought) return true;
    return false;
}

pub fn setOutputEnabled(self: *Self, output: *DrmOutput, enabled: bool) !void {
    if (self.failed or self.device == null or !self.session.isActive()) {
        return error.SessionInactive;
    }
    if (self.findOutput(output.connector_id) != output) return error.UnknownOutput;
    if (!enabled) try self.waitOutputIdle(output);
    try output.setEnabled(self.device.?.fd, enabled);
}

pub fn setOutputPowered(self: *Self, output: *DrmOutput, powered: bool) !void {
    if (self.failed or self.device == null or !self.session.isActive()) {
        return error.SessionInactive;
    }
    if (self.findOutput(output.connector_id) != output) return error.UnknownOutput;
    if (!powered) try self.waitOutputIdle(output);
    try output.setPowered(self.device.?.fd, powered);
}

pub fn setOutputMode(self: *Self, output: *DrmOutput, mode_index: usize) !void {
    if (self.failed or self.device == null or !self.session.isActive()) {
        return error.SessionInactive;
    }
    if (self.findOutput(output.connector_id) != output) return error.UnknownOutput;
    try self.waitOutputIdle(output);
    try output.setMode(self.device.?.fd, mode_index);
}

fn waitOutputIdle(self: *Self, output: *DrmOutput) !void {
    const fd = self.device.?.fd;
    var attempts: u8 = 0;
    while (output.pending != null or output.direct_pending != null) : (attempts += 1) {
        if (attempts == 4) return error.PageFlipTimeout;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, 1000) == 0) return error.PageFlipTimeout;
        if (poll_fds[0].revents &
            (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0)
        {
            return error.DeviceDisconnected;
        }
        try DrmOutput.dispatchEvents(fd);
        self.collectRetiredOutputs();
    }
}

/// Copies the listener and retains its context until clearListener or deinit.
pub fn setListener(self: *Self, listener: Listener) void {
    std.debug.assert(self.listener == null);
    self.listener = listener;
}

pub fn clearListener(self: *Self) void {
    self.listener = null;
}

pub fn releaseClientBuffers(self: *Self) void {
    for (self.active_outputs.items) |output| output.releaseClientBuffers();
    for (self.retired_outputs.items) |output| output.releaseClientBuffers();
}

fn newOutput(self: *Self, fd: std.posix.fd_t, selection: DrmOutput.Selection) !*DrmOutput {
    const output = try self.allocator.create(DrmOutput);
    errdefer self.allocator.destroy(output);
    output.init(self.allocator, self.io, .{
        .context = self,
        .fd = accessFd,
        .gbm = accessGbm,
        .atomic = accessAtomic,
        .active = accessActive,
        .fail = accessFail,
    });
    errdefer output.deinit();
    try output.activate(fd, selection, self.device_path.?);
    return output;
}

fn activate(self: *Self) !void {
    std.debug.assert(self.device == null);
    if (self.device_path) |path| {
        log.info("opening DRM device {s}", .{path});
    } else {
        log.info("discovering DRM device", .{});
    }
    const device = if (self.device_path) |path| try self.openDevice(path) else try self.discoverDevice();
    self.device = device;
    errdefer self.deactivate();
    self.device_number = try deviceNumber(device.fd);
    if (c.drmSetClientCap(device.fd, c.DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) != 0) {
        log.warn("universal DRM planes unavailable; using implicit scanout modifiers", .{});
    }
    self.atomic = c.drmSetClientCap(device.fd, c.DRM_CLIENT_CAP_ATOMIC, 1) == 0;
    if (self.atomic) {
        log.info("atomic DRM frame commits enabled", .{});
    } else {
        log.warn("atomic DRM unavailable; using legacy frame commits", .{});
    }
    self.gbm_device = Gbm.init(device.fd) catch |err| blk: {
        log.warn("GBM unavailable, using CPU scanout buffers: {t}", .{err});
        break :blk null;
    };
    log.info("opened DRM device {s}", .{self.device_path.?});
    if (self.initialized) try self.refreshLeases();
    const selections = try DrmOutput.selectOutputs(
        self.allocator,
        device.fd,
        self.active_outputs.items,
    );
    defer DrmOutput.deinitSelections(self.allocator, selections);
    log.info("found {d} usable connected DRM output(s)", .{selections.len});
    if (!self.initialized and selections.len == 0) return error.NoConnectedOutput;

    // Existing connector objects remain stable across a VT switch.
    for (selections) |selection| {
        const existing = self.findOutput(selection.connector_id);
        if (existing) |output| {
            try output.activate(device.fd, selection, self.device_path.?);
        } else {
            const output = try self.newOutput(device.fd, selection);
            self.active_outputs.append(self.allocator, output) catch |err| {
                output.deactivate(device.fd);
                output.deinit();
                self.allocator.destroy(output);
                return err;
            };
            if (self.initialized) if (self.listener) |listener| listener.added(listener.context, output);
        }
    }
    var index = self.active_outputs.items.len;
    while (index > 0) {
        index -= 1;
        const output = self.active_outputs.items[index];
        if (self.outputLeased(output)) continue;
        var found = false;
        for (selections) |selection| if (selection.connector_id == output.connector_id) {
            found = true;
            break;
        };
        if (!found) try self.removeAt(index, device.fd);
    }
    self.event_source = try self.event_loop.addFd(*Self, device.fd, .{ .readable = true }, handleDrmEvent, self);
    if (self.initialized) if (self.listener) |listener| listener.activated(listener.context);
}

fn deactivate(self: *Self) void {
    if (self.device != null) if (self.listener) |listener| listener.deactivating(listener.context);
    for (self.active_outputs.items) |output| output.notifyDeactivated();
    if (self.event_source) |source| {
        source.remove();
        self.event_source = null;
    }
    const device = self.device orelse return;
    for (self.active_outputs.items) |output| output.deactivate(device.fd);
    // No callback can arrive after the event source is removed. Release any
    // scanout retained for a retired output before destroying its state.
    for (self.retired_outputs.items) |output| output.releaseClientBuffers();
    if (self.gbm_device) |*gbm_device| gbm_device.deinit();
    self.gbm_device = null;
    self.session.closeDevice(device) catch |err| log.err("failed to close DRM device: {t}", .{err});
    self.device = null;
    self.device_number = null;
    self.atomic = false;
    self.destroyList(&self.retired_outputs);
}

fn removeAt(self: *Self, index: usize, fd: std.posix.fd_t) !void {
    try self.retired_outputs.ensureUnusedCapacity(self.allocator, 1);
    const output = self.active_outputs.items[index];
    if (self.listener) |listener| listener.removing(listener.context, output);
    output.retire();
    output.disconnect(fd);
    _ = self.active_outputs.orderedRemove(index);
    if (output.retirementComplete()) {
        self.destroyOutput(output);
    } else {
        self.retired_outputs.appendAssumeCapacity(output);
    }
}

fn reconcile(self: *Self) !void {
    const device = self.device.?;
    // A revoked lessee returns its connector to the lessor's resource list.
    // Update tracking first so a simultaneous unplug is not hidden.
    try self.refreshLeases();
    const selections = try DrmOutput.selectOutputs(
        self.allocator,
        device.fd,
        self.active_outputs.items,
    );
    defer DrmOutput.deinitSelections(self.allocator, selections);
    // Kernel leases survive connector disconnects. Track every output here;
    // the removal listener revokes any lease before the output is retired.
    const topology_changed = connectorTopologyChanged(self.active_outputs.items, selections);
    for (selections) |selection| {
        const output = self.findOutput(selection.connector_id) orelse continue;
        if (!std.meta.eql(output.size, selection.modes[selection.mode_index].size()) or
            output.crtc_id != selection.crtc_id)
        {
            return error.OutputChanged;
        }
    }
    for (selections) |selection| {
        const output = self.findOutput(selection.connector_id) orelse continue;
        if (output.refreshIdentity(device.fd)) {
            if (self.listener) |listener| listener.changed(listener.context, output);
        }
    }
    if (!topology_changed) return;
    log.info(
        "reconciling DRM hotplug: {d} active output(s), {d} usable connected output(s)",
        .{ self.active_outputs.items.len, selections.len },
    );
    for (selections) |selection| if (self.findOutput(selection.connector_id) == null) {
        const output = try self.newOutput(device.fd, selection);
        self.active_outputs.append(self.allocator, output) catch |err| {
            output.deactivate(device.fd);
            output.deinit();
            self.allocator.destroy(output);
            return err;
        };
        if (self.listener) |listener| listener.added(listener.context, output);
    };
    var index = self.active_outputs.items.len;
    while (index > 0) {
        index -= 1;
        const output = self.active_outputs.items[index];
        var found = false;
        for (selections) |selection| if (selection.connector_id == output.connector_id) {
            found = true;
            break;
        };
        if (!found) try self.removeAt(index, device.fd);
    }
}

fn connectorTopologyChanged(
    tracked_outputs: []const *DrmOutput,
    selections: []const DrmOutput.Selection,
) bool {
    if (tracked_outputs.len != selections.len) return true;
    for (tracked_outputs) |output| {
        for (selections) |selection| {
            if (selection.connector_id == output.connector_id) break;
        } else return true;
    }
    return false;
}

fn refreshLeases(self: *Self) !void {
    const device = self.device orelse return error.SessionInactive;
    const kernel_lessees = c.drmModeListLessees(device.fd) orelse return error.ListLesseesFailed;
    defer c.drmFree(kernel_lessees);
    const ids_ptr: [*]const u32 = @ptrFromInt(@intFromPtr(kernel_lessees) + @sizeOf(c.drmModeLesseeListRes));
    const ids = ids_ptr[0..kernel_lessees.*.count];
    var index = self.leases.items.len;
    while (index > 0) {
        index -= 1;
        const lease = self.leases.items[index];
        if (containsId(ids, lease.lessee_id)) continue;
        self.allocator.free(lease.connector_ids);
        _ = self.leases.orderedRemove(index);
        if (self.listener) |listener| listener.lease_revoked(listener.context, lease.lessee_id);
    }
}

fn findOutput(self: *Self, connector_id: u32) ?*DrmOutput {
    for (self.active_outputs.items) |output| if (output.connector_id == connector_id) return output;
    return null;
}

fn collectRetiredOutputs(self: *Self) void {
    var index = self.retired_outputs.items.len;
    while (index > 0) {
        index -= 1;
        const output = self.retired_outputs.items[index];
        if (!output.retirementComplete()) continue;
        _ = self.retired_outputs.orderedRemove(index);
        self.destroyOutput(output);
    }
}

fn destroyOutput(self: *Self, output: *DrmOutput) void {
    output.deinit();
    self.allocator.destroy(output);
}

fn destroyList(self: *Self, list: *std.ArrayList(*DrmOutput)) void {
    for (list.items) |output| self.destroyOutput(output);
    list.clearRetainingCapacity();
}

fn openDevice(self: *Self, path: [:0]const u8) !Session.Device {
    const device = try self.session.openDevice(path);
    errdefer self.session.closeDevice(device) catch {};
    if (c.drmIsKMS(device.fd) != 1) return error.NotKmsDevice;
    return device;
}

fn discoverDevice(self: *Self) !Session.Device {
    const udev = c.udev_new() orelse return error.UdevContextFailed;
    defer _ = c.udev_unref(udev);
    const enumerate = c.udev_enumerate_new(udev) orelse return error.UdevEnumerateFailed;
    defer _ = c.udev_enumerate_unref(enumerate);
    if (c.udev_enumerate_add_match_subsystem(enumerate, "drm") != 0 or c.udev_enumerate_scan_devices(enumerate) != 0) return error.UdevEnumerateFailed;
    var entry = c.udev_enumerate_get_list_entry(enumerate);
    while (entry) |current| : (entry = c.udev_list_entry_get_next(current)) {
        const syspath = c.udev_list_entry_get_name(current) orelse continue;
        const udev_device = c.udev_device_new_from_syspath(udev, syspath) orelse continue;
        defer _ = c.udev_device_unref(udev_device);
        const path = std.mem.span(c.udev_device_get_devnode(udev_device) orelse continue);
        if (!DrmOutput.isPrimaryNode(path)) continue;
        const device = self.openDevice(path) catch continue;
        self.device_path = self.allocator.dupeSentinel(u8, path, 0) catch |err| {
            self.session.closeDevice(device) catch {};
            return err;
        };
        return device;
    }
    return error.NoDrmDevice;
}

fn initHotplugMonitor(self: *Self) !void {
    const udev = c.udev_new() orelse return error.UdevContextFailed;
    self.udev = udev;
    errdefer {
        _ = c.udev_unref(udev);
        self.udev = null;
    }
    const monitor = c.udev_monitor_new_from_netlink(udev, "udev") orelse return error.UdevMonitorFailed;
    self.udev_monitor = monitor;
    errdefer {
        _ = c.udev_monitor_unref(monitor);
        self.udev_monitor = null;
    }
    if (c.udev_monitor_filter_add_match_subsystem_devtype(monitor, "drm", null) != 0 or c.udev_monitor_enable_receiving(monitor) != 0) return error.UdevMonitorFailed;
    const fd = c.udev_monitor_get_fd(monitor);
    if (fd < 0) return error.UdevMonitorFailed;
    self.hotplug_source = try self.event_loop.addFd(*Self, fd, .{ .readable = true }, handleHotplugEvent, self);
    errdefer {
        self.hotplug_source.?.remove();
        self.hotplug_source = null;
    }
}

fn deinitHotplugMonitor(self: *Self) void {
    if (self.hotplug_source) |source| {
        source.remove();
        self.hotplug_source = null;
    }
    if (self.udev_monitor) |monitor| {
        _ = c.udev_monitor_unref(monitor);
        self.udev_monitor = null;
    }
    if (self.udev) |udev| {
        _ = c.udev_unref(udev);
        self.udev = null;
    }
}

fn fail(self: *Self, err: anyerror) void {
    if (self.failed) return;
    self.failed = true;
    log.err("DRM device failed: {t}", .{err});
    self.deinitHotplugMonitor();
    self.deactivate();
    if (self.initialized) if (self.listener) |listener| listener.failed(listener.context);
}

fn handleSessionActivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.failed) return;
    self.activate() catch |err| return self.fail(err);
    if (self.initialized) for (self.active_outputs.items) |output| output.notifyReady();
}

fn handleSessionDeactivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.deactivate();
}

fn handleSessionFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.fail(error.SessionFailed);
}

fn handleDrmEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") self.fail(error.DeviceDisconnected) else if (mask.readable) if (self.device) |device| {
        DrmOutput.dispatchEvents(device.fd) catch |err| self.fail(err);
        self.collectRetiredOutputs();
    };
    return 0;
}

fn handleHotplugEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") {
        self.fail(error.UdevMonitorFailed);
        return 0;
    }
    if (!mask.readable) return 0;
    const device = c.udev_monitor_receive_device(self.udev_monitor.?) orelse return 0;
    defer _ = c.udev_device_unref(device);
    self.handleDeviceEvent(device) catch |err| self.fail(err);
    return 0;
}

fn handleDeviceEvent(self: *Self, device: *c.struct_udev_device) !void {
    const sysname = std.mem.span(c.udev_device_get_sysname(device) orelse return);
    if (!DrmOutput.isPrimaryNode(sysname)) return;
    const action = std.mem.span(c.udev_device_get_action(device) orelse return);
    const devnode = std.mem.span(c.udev_device_get_devnode(device) orelse return);
    const event_seat = if (c.udev_device_get_property_value(device, "ID_SEAT")) |value|
        std.mem.span(value)
    else
        "seat0";
    if (!std.mem.eql(u8, event_seat, self.session.name())) return;
    if (self.device_number == null or
        c.udev_device_get_devnum(device) != self.device_number.?) return;

    log.info(
        "DRM device event action={s} sysname={s} devnode={s} seat={s}",
        .{ action, sysname, devnode, event_seat },
    );
    if (std.mem.eql(u8, action, "change")) {
        if (self.device != null and self.session.isActive()) try self.reconcile();
    } else if (std.mem.eql(u8, action, "remove")) {
        return error.DeviceDisconnected;
    }
}

fn deviceNumber(fd: std.posix.fd_t) !c.dev_t {
    var status: c.struct_stat = undefined;
    if (c.fstat(fd, &status) != 0) return error.StatDeviceFailed;
    return status.st_rdev;
}

fn accessFd(context: *anyopaque) ?std.posix.fd_t {
    const self: *Self = @ptrCast(@alignCast(context));
    return if (self.device) |device| device.fd else null;
}

fn accessGbm(context: *anyopaque) ?*Gbm {
    const self: *Self = @ptrCast(@alignCast(context));
    return if (self.gbm_device) |*device| device else null;
}

fn accessAtomic(context: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.atomic;
}

fn accessActive(context: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return !self.failed and self.session.isActive() and self.device != null;
}

fn accessFail(context: *anyopaque, err: anyerror) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.fail(err);
}

test "connector topology requires every tracked output" {
    var first: DrmOutput = undefined;
    first.connector_id = 10;
    var second: DrmOutput = undefined;
    second.connector_id = 20;
    const tracked_outputs = [_]*DrmOutput{ &first, &second };

    var unchanged: [2]DrmOutput.Selection = undefined;
    unchanged[0].connector_id = 20;
    unchanged[1].connector_id = 10;
    try std.testing.expect(!connectorTopologyChanged(&tracked_outputs, &unchanged));

    var replacement: [2]DrmOutput.Selection = undefined;
    replacement[0].connector_id = 10;
    replacement[1].connector_id = 30;
    try std.testing.expect(connectorTopologyChanged(&tracked_outputs, &replacement));
    try std.testing.expect(connectorTopologyChanged(&tracked_outputs, replacement[0..1]));
}
