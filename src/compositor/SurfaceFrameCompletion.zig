//! Resource-free completion for a sampled compositor surface frame.

const SurfaceFrameCompletion = @This();

const presentation = @import("presentation.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");
const OutputLayout = @import("output_layout.zig");

pub const CallbackOnlyResult = enum {
    none,
    remaining,
    drained,
};

context: *anyopaque,
complete: *const fn (*anyopaque, SurfaceRegistry.Id, u32) void,
has_callback_only: ?*const fn (*anyopaque, SurfaceRegistry.Id) bool = null,
complete_callback_only: ?*const fn (*anyopaque, SurfaceRegistry.Id, u32) CallbackOnlyResult = null,
sampled: ?*const fn (*anyopaque, SurfaceRegistry.Id, OutputLayout.Id) bool = null,
presented: ?*const fn (*anyopaque, SurfaceRegistry.Id, OutputLayout.Id, presentation.Info) bool = null,
discarded: ?*const fn (*anyopaque, SurfaceRegistry.Id, OutputLayout.Id) bool = null,
