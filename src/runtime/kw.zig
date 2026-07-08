//! The `kw` Lua module: surface creation and widget-tree submission.
//!
//! Loaded with `require("kw")` via package.preload. Every closure carries
//! the owning Runtime as a light-userdata upvalue.

const std = @import("std");
const keywork = @import("keywork");
const c = @import("lua_c");
const Runtime = @import("runtime.zig");
const widget_tree = @import("widget_tree.zig");

const surface_metatable = "keywork.surface";

pub fn register(runtime: *Runtime) void {
    const L = runtime.vm.state;
    createSurfaceMetatable(runtime);
    c.lua_getfield(L, c.LUA_GLOBALSINDEX, "package");
    c.lua_getfield(L, -1, "preload");
    c.lua_pushlightuserdata(L, runtime);
    c.lua_pushcclosure(L, openKw, 1);
    c.lua_setfield(L, -2, "kw");
    c.lua_settop(L, -3);
}

fn createSurfaceMetatable(runtime: *Runtime) void {
    const L = runtime.vm.state;
    const created = c.luaL_newmetatable(L, surface_metatable);
    std.debug.assert(created == 1);
    c.lua_createtable(L, 0, 1);
    c.lua_pushlightuserdata(L, runtime);
    c.lua_pushcclosure(L, surfaceSubmit, 1);
    c.lua_setfield(L, -2, "submit");
    c.lua_setfield(L, -2, "__index");
    c.lua_settop(L, -2);
}

fn openKw(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    c.lua_createtable(L, 0, 1);
    c.lua_pushvalue(L, c.lua_upvalueindex(1));
    c.lua_pushcclosure(L, kwSurface, 1);
    c.lua_setfield(L, -2, "surface");
    return 1;
}

fn runtimeUpvalue(L: *c.lua_State) *Runtime {
    return @ptrCast(@alignCast(c.lua_touserdata(L, c.lua_upvalueindex(1))));
}

/// kw.surface(options?) -> surface userdata
fn kwSurface(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const runtime = runtimeUpvalue(L);

    var options: keywork.SurfaceOptions = .{};
    const has_options = c.lua_type(L, 1) == c.LUA_TTABLE;
    if (c.lua_type(L, 1) != c.LUA_TNONE and c.lua_type(L, 1) != c.LUA_TNIL and !has_options) {
        _ = c.luaL_error(L, "kw.surface expects an options table");
        unreachable;
    }

    // String option values stay on the stack while createSurface copies
    // them; the base top is restored afterwards.
    const base = c.lua_gettop(L);
    if (has_options) {
        if (surfaceStringOption(L, "title")) |title| options.title = title;
        if (surfaceStringOption(L, "app_id")) |app_id| options.app_id = app_id;
        if (surfaceDimensionOption(L, "width")) |width| options.width = width;
        if (surfaceDimensionOption(L, "height")) |height| options.height = height;
        if (surfaceStringOption(L, "backend")) |name| {
            options.backend = std.meta.stringToEnum(keywork.Backend, name) orelse {
                _ = c.luaL_error(L, "invalid surface backend");
                unreachable;
            };
        }
    }

    const surface_state = runtime.createSurface(options) catch {
        _ = c.luaL_error(L, "surface creation failed");
        unreachable;
    };
    c.lua_settop(L, base);

    const slot: **Runtime.SurfaceState = @ptrCast(@alignCast(
        c.lua_newuserdata(L, @sizeOf(*Runtime.SurfaceState)),
    ));
    slot.* = surface_state;
    c.luaL_getmetatable(L, surface_metatable);
    _ = c.lua_setmetatable(L, -2);
    return 1;
}

/// Reads a string field from the options table at index 1 and leaves the
/// value on the stack so it stays alive for the borrowing callee.
fn surfaceStringOption(L: *c.lua_State, comptime field: [:0]const u8) ?[]const u8 {
    c.lua_getfield(L, 1, field.ptr);
    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => {
            c.lua_settop(L, -2);
            return null;
        },
        c.LUA_TSTRING => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, -1, &len);
            return ptr[0..len];
        },
        else => {
            _ = c.luaL_error(L, "surface option '" ++ field ++ "' must be a string");
            unreachable;
        },
    }
}

fn surfaceDimensionOption(L: *c.lua_State, comptime field: [:0]const u8) ?u32 {
    c.lua_getfield(L, 1, field.ptr);
    defer c.lua_settop(L, -2);
    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return null,
        c.LUA_TNUMBER => {
            const value = c.lua_tonumber(L, -1);
            if (value < 1 or value > 16384) {
                _ = c.luaL_error(L, "surface option '" ++ field ++ "' out of range");
                unreachable;
            }
            return @intFromFloat(value);
        },
        else => {
            _ = c.luaL_error(L, "surface option '" ++ field ++ "' must be a number");
            unreachable;
        },
    }
}

/// surface:submit(widget_table) -> document id
fn surfaceSubmit(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const runtime = runtimeUpvalue(L);
    const slot: **Runtime.SurfaceState = @ptrCast(@alignCast(
        c.luaL_checkudata(L, 1, surface_metatable),
    ));
    const surface_state = slot.*;
    c.luaL_checktype(L, 2, c.LUA_TTABLE);
    if (surface_state.closed) {
        _ = c.luaL_error(L, "surface is closed");
        unreachable;
    }

    var diagnostic: [:0]const u8 = "submit failed";
    const document = submitTree(runtime, surface_state, L, &diagnostic) catch {
        // All Zig-side cleanup finished inside submitTree; the longjmp
        // below crosses no live defers.
        c.lua_pushstring(L, diagnostic.ptr);
        _ = c.lua_error(L);
        unreachable;
    };
    c.lua_pushinteger(L, @intCast(document));
    return 1;
}

fn submitTree(
    runtime: *Runtime,
    surface_state: *Runtime.SurfaceState,
    L: *c.lua_State,
    diagnostic: *[:0]const u8,
) !keywork.DocumentId {
    c.lua_settop(L, 2);
    var arena_state: std.heap.ArenaAllocator = .init(runtime.allocator);
    defer arena_state.deinit();

    var builder: widget_tree.Builder = .{
        .state = L,
        .arena = arena_state.allocator(),
        .ref_allocator = runtime.allocator,
    };
    errdefer builder.cancel();

    const root = builder.build() catch |err| {
        diagnostic.* = builder.diagnostic;
        return err;
    };
    const document = surface_state.surface.submit(root) catch |err| {
        diagnostic.* = "document submission failed";
        return err;
    };
    const refs = try builder.takeRefs();
    try runtime.recordDocument(document, refs);
    return document;
}
