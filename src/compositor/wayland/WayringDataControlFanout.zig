//! Atomic transaction fanout for the EXT and WLR data-control adapters.

const WayringDataControlFanout = @This();

const DataDevice = @import("../DataDevice.zig");
const WayringDataControl = @import("WayringDataControl.zig");
const WayringZwlrDataControl = @import("WayringZwlrDataControl.zig");

ext: *WayringDataControl,
wlr: *WayringZwlrDataControl,

pub fn finalize(context: *anyopaque) error{OutOfMemory}!void {
    const self: *WayringDataControlFanout = @ptrCast(@alignCast(context));
    try WayringDataControl.transactionFinalize(self.ext);
    WayringZwlrDataControl.transactionFinalize(self.wlr) catch |err| {
        // EXT is already prepared. Cancel both halves here rather than relying
        // solely on the canonical transaction's subsequent abort callback.
        self.abortAdapters();
        return err;
    };
}

pub fn commit(context: *anyopaque) void {
    const self: *WayringDataControlFanout = @ptrCast(@alignCast(context));
    WayringDataControl.transactionCommit(self.ext);
    WayringZwlrDataControl.transactionCommit(self.wlr);
}

pub fn abort(context: *anyopaque) void {
    const self: *WayringDataControlFanout = @ptrCast(@alignCast(context));
    self.abortAdapters();
}

fn abortAdapters(self: *WayringDataControlFanout) void {
    WayringDataControl.transactionAbort(self.ext);
    WayringZwlrDataControl.transactionAbort(self.wlr);
}

pub fn rolledBack(context: *anyopaque, id: DataDevice.ControlOfferId) void {
    const self: *WayringDataControlFanout = @ptrCast(@alignCast(context));
    WayringDataControl.offerRolledBack(self.ext, id);
    WayringZwlrDataControl.offerRolledBack(self.wlr, id);
}

pub fn mimeOffered(context: *anyopaque, id: DataDevice.ControlOfferId, mime: []const u8) void {
    const self: *WayringDataControlFanout = @ptrCast(@alignCast(context));
    WayringDataControl.offerMimeOffered(self.ext, id, mime);
    WayringZwlrDataControl.offerMimeOffered(self.wlr, id, mime);
}
