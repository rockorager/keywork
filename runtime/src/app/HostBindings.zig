//! Optional lifecycle bridge from the native runner to an embedding host.

const HostBindings = @This();

const event_loop = @import("keywork-loop");
const platform_mod = @import("platform.zig");
const runtime_mod = @import("keywork-ui-runtime");

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    bind_invalidator: *const fn (ptr: *anyopaque, invalidator: runtime_mod.Invalidator) void = ignoreInvalidator,
    unbind_invalidator: *const fn (ptr: *anyopaque) void = ignore,
    bind_platform: *const fn (ptr: *anyopaque, platform: platform_mod.Platform) void = ignorePlatform,
    unbind_platform: *const fn (ptr: *anyopaque) void = ignore,
    bind_event_loop: *const fn (ptr: *anyopaque, loop: *event_loop.EventLoop) anyerror!void = ignoreEventLoop,
    unbind_event_loop: *const fn (ptr: *anyopaque) void = ignore,
    should_run_headless: *const fn (ptr: *anyopaque) bool = neverRunHeadless,
};

pub fn bindInvalidator(self: HostBindings, invalidator: runtime_mod.Invalidator) void {
    self.vtable.bind_invalidator(self.ptr, invalidator);
}

pub fn unbindInvalidator(self: HostBindings) void {
    self.vtable.unbind_invalidator(self.ptr);
}

pub fn bindPlatform(self: HostBindings, platform: platform_mod.Platform) void {
    self.vtable.bind_platform(self.ptr, platform);
}

pub fn unbindPlatform(self: HostBindings) void {
    self.vtable.unbind_platform(self.ptr);
}

pub fn bindEventLoop(self: HostBindings, loop: *event_loop.EventLoop) !void {
    try self.vtable.bind_event_loop(self.ptr, loop);
}

pub fn unbindEventLoop(self: HostBindings) void {
    self.vtable.unbind_event_loop(self.ptr);
}

pub fn shouldRunHeadless(self: HostBindings) bool {
    return self.vtable.should_run_headless(self.ptr);
}

fn ignore(_: *anyopaque) void {}

fn ignoreInvalidator(_: *anyopaque, _: runtime_mod.Invalidator) void {}

fn ignorePlatform(_: *anyopaque, _: platform_mod.Platform) void {}

fn ignoreEventLoop(_: *anyopaque, _: *event_loop.EventLoop) anyerror!void {}

fn neverRunHeadless(_: *anyopaque) bool {
    return false;
}
