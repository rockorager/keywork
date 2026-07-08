//! The runtime layer: owns the embedded LuaJIT VM and the toolkit
//! context, and drains toolkit events into Lua handler calls at loop
//! iteration boundaries. Lua never runs during Wayland dispatch, layout,
//! or paint.

const Runtime = @This();

const std = @import("std");
const keywork = @import("keywork");
const c = @import("lua_c");
const kw = @import("kw.zig");
const Vm = @import("vm.zig");

const log = std.log.scoped(.keywork_runtime);

allocator: std.mem.Allocator,
loop: *keywork.Loop,
vm: Vm,
context: *keywork.Context,
surfaces: std.ArrayList(*SurfaceState) = .empty,
/// Handler registry refs owned by each installed document, released when
/// the toolkit retires the document.
documents: std.AutoHashMapUnmanaged(keywork.DocumentId, []c_int) = .empty,

pub const SurfaceState = struct {
    surface: *keywork.Surface,
    id: keywork.SurfaceId,
    closed: bool = false,
};

pub fn create(allocator: std.mem.Allocator, loop: *keywork.Loop) !*Runtime {
    const self = try allocator.create(Runtime);
    errdefer allocator.destroy(self);
    var vm = try Vm.init();
    errdefer vm.deinit();
    const context = try keywork.Context.init(allocator, loop, .{});
    errdefer context.deinit();
    self.* = .{
        .allocator = allocator,
        .loop = loop,
        .vm = vm,
        .context = context,
    };
    kw.register(self);
    return self;
}

pub fn destroy(self: *Runtime) void {
    var it = self.documents.valueIterator();
    while (it.next()) |refs| self.allocator.free(refs.*);
    self.documents.deinit(self.allocator);
    for (self.surfaces.items) |state| self.allocator.destroy(state);
    self.surfaces.deinit(self.allocator);
    self.context.deinit();
    // Closing the VM releases every pinned handler ref with it.
    self.vm.deinit();
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

/// Runs the process loop until every surface the application created has
/// closed. Returns immediately if the application created none.
pub fn run(self: *Runtime) !void {
    while (self.hasOpenSurfaces()) {
        try self.loop.dispatch(-1);
        try self.pump();
    }
}

/// One loop-iteration boundary: flush the toolkit, then hand queued
/// events to Lua. Handlers may submit new documents, so flush and drain
/// repeat until quiescent.
pub fn pump(self: *Runtime) !void {
    while (true) {
        try self.context.flush();
        if (self.drainEvents() == 0) break;
    }
}

pub fn createSurface(self: *Runtime, options: keywork.SurfaceOptions) !*SurfaceState {
    const state = try self.allocator.create(SurfaceState);
    errdefer self.allocator.destroy(state);
    const surface = try self.context.createSurface(options);
    state.* = .{ .surface = surface, .id = surface.surfaceId() };
    self.surfaces.append(self.allocator, state) catch |err| {
        self.context.destroySurface(surface);
        return err;
    };
    return state;
}

/// Takes ownership of the document's handler refs; they are released when
/// the toolkit retires the document.
pub fn recordDocument(self: *Runtime, document: keywork.DocumentId, refs: []c_int) !void {
    errdefer {
        self.releaseRefs(refs);
        self.allocator.free(refs);
    }
    try self.documents.putNoClobber(self.allocator, document, refs);
}

fn hasOpenSurfaces(self: *const Runtime) bool {
    for (self.surfaces.items) |state| {
        if (!state.closed) return true;
    }
    return false;
}

fn drainEvents(self: *Runtime) usize {
    var count: usize = 0;
    while (self.context.nextEvent()) |event| {
        count += 1;
        switch (event) {
            .handler => |handler| self.callHandler(handler),
            .closed => |closed| self.markClosed(closed.surface),
            .document_retired => |retired| self.releaseDocument(retired.document),
            .configured => {},
            .appearance_changed => {},
        }
    }
    return count;
}

fn callHandler(self: *Runtime, event: keywork.Event.Handler) void {
    const L = self.vm.state;
    const base = c.lua_gettop(L);
    defer c.lua_settop(L, base);

    // Events are processed in order, so a handler ref is always released
    // strictly after the last event that references its document.
    c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, @intCast(event.handler));
    std.debug.assert(c.lua_type(L, -1) == c.LUA_TFUNCTION);

    var nargs: c_int = 0;
    switch (event.payload) {
        .none => {},
        .boolean => |value| {
            c.lua_pushboolean(L, @intFromBool(value));
            nargs = 1;
        },
        .text => |text| {
            c.lua_pushlstring(L, text.ptr, text.len);
            nargs = 1;
        },
    }
    if (c.lua_pcall(L, nargs, 0, 0) != 0) {
        log.err("handler error: {s}", .{self.vm.lastError()});
    }
}

fn markClosed(self: *Runtime, id: keywork.SurfaceId) void {
    for (self.surfaces.items) |state| {
        if (state.id == id) {
            state.closed = true;
            return;
        }
    }
}

fn releaseDocument(self: *Runtime, document: keywork.DocumentId) void {
    const entry = self.documents.fetchRemove(document) orelse return;
    self.releaseRefs(entry.value);
    self.allocator.free(entry.value);
}

fn releaseRefs(self: *Runtime, refs: []const c_int) void {
    for (refs) |ref| c.luaL_unref(self.vm.state, c.LUA_REGISTRYINDEX, ref);
}

test "lua app creates a surface and submits a document" {
    var loop = try keywork.Loop.init(std.testing.allocator);
    defer loop.deinit();
    const runtime = try Runtime.create(std.testing.allocator, &loop);
    defer runtime.destroy();

    try runtime.vm.runString(
        \\local kw = require("kw")
        \\surface = kw.surface({ backend = "headless", width = 200, height = 100 })
        \\document = surface:submit({
        \\  type = "column",
        \\  gap = 8,
        \\  { type = "text", value = "hello" },
        \\  {
        \\    type = "filled_button",
        \\    id = "go",
        \\    on_activate = function() end,
        \\    child = { type = "text", value = "Go" },
        \\  },
        \\})
    );

    c.lua_getfield(runtime.vm.state, c.LUA_GLOBALSINDEX, "document");
    try std.testing.expect(c.lua_tonumber(runtime.vm.state, -1) >= 1);
    c.lua_settop(runtime.vm.state, 0);
    try std.testing.expectEqual(@as(usize, 1), runtime.surfaces.items.len);
    try std.testing.expectEqual(@as(u32, 1), runtime.documents.size);
}

test "resubmission releases the retired document's handler refs" {
    var loop = try keywork.Loop.init(std.testing.allocator);
    defer loop.deinit();
    const runtime = try Runtime.create(std.testing.allocator, &loop);
    defer runtime.destroy();

    try runtime.vm.runString(
        \\local kw = require("kw")
        \\local surface = kw.surface({ backend = "headless", width = 200, height = 100 })
        \\local function view()
        \\  return {
        \\    type = "filled_button",
        \\    id = "go",
        \\    on_activate = function() end,
        \\    child = { type = "text", value = "Go" },
        \\  }
        \\end
        \\surface:submit(view())
        \\surface:submit(view())
    );

    try runtime.pump();
    try std.testing.expectEqual(@as(u32, 1), runtime.documents.size);
}

test "submitting an invalid widget raises a lua error" {
    var loop = try keywork.Loop.init(std.testing.allocator);
    defer loop.deinit();
    const runtime = try Runtime.create(std.testing.allocator, &loop);
    defer runtime.destroy();

    try std.testing.expectError(error.LuaRuntime, runtime.vm.runString(
        \\local kw = require("kw")
        \\local surface = kw.surface({ backend = "headless" })
        \\surface:submit({ type = "nonsense" })
    ));
    try std.testing.expect(std.mem.endsWith(u8, runtime.vm.lastError(), "unknown widget type"));
}
