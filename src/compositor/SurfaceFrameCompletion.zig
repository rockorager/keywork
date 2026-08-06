//! Resource-free completion for a sampled compositor surface frame.

const SurfaceFrameCompletion = @This();

const SurfaceRegistry = @import("SurfaceRegistry.zig");

pub const CallbackOnlyResult = enum {
    none,
    remaining,
    drained,
};

context: *anyopaque,
complete: *const fn (*anyopaque, SurfaceRegistry.Id, u32) void,
has_callback_only: ?*const fn (*anyopaque, SurfaceRegistry.Id) bool = null,
complete_callback_only: ?*const fn (*anyopaque, SurfaceRegistry.Id, u32) CallbackOnlyResult = null,
