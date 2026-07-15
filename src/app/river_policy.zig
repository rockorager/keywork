//! Policy boundary between the River protocol runtime and application hosts.

const std = @import("std");

pub const Output = struct {
    id: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Window = struct {
    id: u32,
    title: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    identifier: ?[]const u8 = null,
};

pub const Context = struct {
    outputs: []const Output,
    windows: []const Window,
    focused_window: ?u32,
};

pub const Placement = struct {
    window_id: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool = true,
};

pub const Binding = struct {
    id: []const u8,
    keysym: u32,
    modifiers: u32,
};

pub const Action = enum {
    close_focused,
    focus_next,
    exit_session,
};

pub const Control = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request_action: *const fn (ptr: *anyopaque, action: Action) anyerror!void,
    };

    pub fn requestAction(self: Control, action: Action) !void {
        try self.vtable.request_action(self.ptr, action);
    }
};

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        refresh: *const fn (ptr: *anyopaque) anyerror!void,
        bindings: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]Binding,
        layout: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, context: Context) anyerror![]Placement,
        invoke_binding: *const fn (ptr: *anyopaque, id: []const u8) anyerror!void,
        set_control: *const fn (ptr: *anyopaque, control: ?Control) void,
        bind_invalidator: *const fn (
            ptr: *anyopaque,
            invalidator_ptr: *anyopaque,
            invalidate: *const fn (ptr: *anyopaque) anyerror!void,
        ) anyerror!void,
        unbind_invalidator: *const fn (ptr: *anyopaque) void,
    };

    pub fn refresh(self: Host) !void {
        try self.vtable.refresh(self.ptr);
    }

    pub fn bindings(self: Host, allocator: std.mem.Allocator) ![]Binding {
        return self.vtable.bindings(self.ptr, allocator);
    }

    pub fn layout(self: Host, allocator: std.mem.Allocator, context: Context) ![]Placement {
        return self.vtable.layout(self.ptr, allocator, context);
    }

    pub fn invokeBinding(self: Host, id: []const u8) !void {
        try self.vtable.invoke_binding(self.ptr, id);
    }

    pub fn setControl(self: Host, control: ?Control) void {
        self.vtable.set_control(self.ptr, control);
    }

    pub fn bindInvalidator(
        self: Host,
        invalidator_ptr: *anyopaque,
        invalidate: *const fn (ptr: *anyopaque) anyerror!void,
    ) !void {
        try self.vtable.bind_invalidator(self.ptr, invalidator_ptr, invalidate);
    }

    pub fn unbindInvalidator(self: Host) void {
        self.vtable.unbind_invalidator(self.ptr);
    }
};

pub fn freeBindings(allocator: std.mem.Allocator, bindings: []Binding) void {
    for (bindings) |binding| allocator.free(binding.id);
    allocator.free(bindings);
}
