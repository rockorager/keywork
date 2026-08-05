//! Resource-free completion for a sampled compositor surface frame.

const SurfaceFrameCompletion = @This();

const SurfaceRegistry = @import("SurfaceRegistry.zig");

context: *anyopaque,
complete: *const fn (*anyopaque, SurfaceRegistry.Id, u32) void,
