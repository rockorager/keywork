//! Lua declarations and policy callbacks for River window-manager apps.

const std = @import("std");
const river_policy = @import("../app/river_policy.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");
const xkb = @import("xkb_c");

const pop = lua_value.pop;

pub const Host = struct {
    control: ?river_policy.Control = null,

    fn requestAction(self: *Host, action: river_policy.Action) !void {
        const control = self.control orelse return error.RiverWindowManagerNotRunning;
        try control.requestAction(action);
    }
};

pub fn pushModule(lua_state: *c.lua_State, host: *Host) void {
    c.lua_createtable(lua_state, 0, 5);
    const module = c.lua_gettop(lua_state);
    lua_value.setClosureField(lua_state, module, "app", luaRiverApp, 0);
    lua_value.setClosureField(lua_state, module, "window_manager", luaWindowManager, 0);
    inline for (.{
        .{ "close_focused", luaCloseFocused },
        .{ "focus_next", luaFocusNext },
        .{ "exit_session", luaExitSession },
    }) |entry| {
        c.lua_pushlightuserdata(lua_state, host);
        lua_value.setClosureField(lua_state, module, entry[0], entry[1], 1);
    }
}

fn luaRiverApp(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
    lua_value.setStringField(lua_state, 1, "type", "app");
    lua_value.setStringField(lua_state, 1, "kind", "river-window-manager");
    c.lua_pushvalue(lua_state, 1);
    return 1;
}

fn luaWindowManager(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
    lua_value.setStringField(lua_state, 1, "type", "river-window-manager");
    c.lua_pushvalue(lua_state, 1);
    return 1;
}

fn luaCloseFocused(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return requestAction(lua_state_optional.?, .close_focused);
}

fn luaFocusNext(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return requestAction(lua_state_optional.?, .focus_next);
}

fn luaExitSession(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return requestAction(lua_state_optional.?, .exit_session);
}

fn requestAction(lua_state: *c.lua_State, action: river_policy.Action) c_int {
    const host = lua_value.upvaluePointer(*Host, lua_state, 1);
    host.requestAction(action) catch |err| return lua_value.pushNilError(lua_state, err);
    c.lua_pushboolean(lua_state, 1);
    return 1;
}

pub fn parseBindings(
    lua_state: *c.lua_State,
    root_ref: c_int,
    allocator: std.mem.Allocator,
) ![]river_policy.Binding {
    const stack_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, stack_top);
    const manager = try pushManager(lua_state, root_ref);
    c.lua_getfield(lua_state, manager, "bindings");
    if (c.lua_isnil(lua_state, -1)) return allocator.alloc(river_policy.Binding, 0);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverBindings;
    const bindings_table = c.lua_gettop(lua_state);

    var bindings: std.ArrayList(river_policy.Binding) = .empty;
    errdefer {
        for (bindings.items) |binding| allocator.free(binding.id);
        bindings.deinit(allocator);
    }
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, bindings_table) != 0) {
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TFUNCTION)
            return error.InvalidRiverBinding;
        const id = try lua_value.dupeStringFromStack(lua_state, allocator, -2);
        errdefer allocator.free(id);
        const parsed = try parseBinding(allocator, id);
        try bindings.append(allocator, .{
            .id = id,
            .keysym = parsed.keysym,
            .modifiers = parsed.modifiers,
        });
    }
    return bindings.toOwnedSlice(allocator);
}

pub fn validate(
    lua_state: *c.lua_State,
    root_ref: c_int,
    allocator: std.mem.Allocator,
) !void {
    const bindings = try parseBindings(lua_state, root_ref, allocator);
    defer river_policy.freeBindings(allocator, bindings);

    const stack_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, stack_top);
    const manager = try pushManager(lua_state, root_ref);
    c.lua_getfield(lua_state, manager, "layout");
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.RiverLayoutMissing;
}

const ParsedBinding = struct {
    keysym: u32,
    modifiers: u32,
};

fn parseBinding(allocator: std.mem.Allocator, value: []const u8) !ParsedBinding {
    var parts = std.mem.splitScalar(u8, value, '+');
    var key_name: ?[]const u8 = null;
    var modifiers: u32 = 0;
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidRiverBinding;
        if (parts.peek() == null) {
            key_name = part;
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            modifiers |= 1;
        } else if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            modifiers |= 4;
        } else if (std.ascii.eqlIgnoreCase(part, "alt") or std.ascii.eqlIgnoreCase(part, "mod1")) {
            modifiers |= 8;
        } else if (std.ascii.eqlIgnoreCase(part, "mod3")) {
            modifiers |= 32;
        } else if (std.ascii.eqlIgnoreCase(part, "super") or std.ascii.eqlIgnoreCase(part, "mod4")) {
            modifiers |= 64;
        } else if (std.ascii.eqlIgnoreCase(part, "mod5")) {
            modifiers |= 128;
        } else return error.InvalidRiverModifier;
    }
    const key = key_name orelse return error.InvalidRiverBinding;
    const key_z = try allocator.dupeZ(u8, key);
    defer allocator.free(key_z);
    const keysym = xkb.xkb_keysym_from_name(key_z.ptr, xkb.XKB_KEYSYM_CASE_INSENSITIVE);
    if (keysym == xkb.XKB_KEY_NoSymbol) return error.InvalidRiverKeysym;
    return .{ .keysym = keysym, .modifiers = modifiers };
}

pub fn invokeBinding(lua_state: *c.lua_State, root_ref: c_int, id: []const u8) !void {
    const stack_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, stack_top);
    const manager = try pushManager(lua_state, root_ref);
    c.lua_getfield(lua_state, manager, "bindings");
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverBindings;
    c.lua_pushlstring(lua_state, id.ptr, id.len);
    _ = c.lua_gettable(lua_state, -2);
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.UnknownRiverBinding;
    if (c.lua_pcall(lua_state, 0, 0, 0) != 0)
        return lua_value.failLuaCall(lua_state, "river binding callback failed");
}

pub fn buildLayout(
    lua_state: *c.lua_State,
    root_ref: c_int,
    allocator: std.mem.Allocator,
    context: river_policy.Context,
) ![]river_policy.Placement {
    const stack_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, stack_top);
    const manager = try pushManager(lua_state, root_ref);
    c.lua_getfield(lua_state, manager, "layout");
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.RiverLayoutMissing;
    pushContext(lua_state, context);
    if (c.lua_pcall(lua_state, 1, 1, 0) != 0)
        return lua_value.failLuaCall(lua_state, "river layout callback failed");
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverLayout;
    const result = c.lua_gettop(lua_state);
    const count: usize = @intCast(c.lua_objlen(lua_state, result));
    const placements = try allocator.alloc(river_policy.Placement, count);
    errdefer allocator.free(placements);
    for (placements, 0..) |*placement, index| {
        c.lua_rawgeti(lua_state, result, @intCast(index + 1));
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverPlacement;
        const table = c.lua_gettop(lua_state);
        placement.* = .{
            .window_id = try integerField(u32, lua_state, table, "window"),
            .x = try integerField(i32, lua_state, table, "x"),
            .y = try integerField(i32, lua_state, table, "y"),
            .width = try positiveDimension(lua_state, table, "width"),
            .height = try positiveDimension(lua_state, table, "height"),
            .visible = try optionalBoolField(lua_state, table, "visible", true),
        };
    }
    return placements;
}

fn pushManager(lua_state: *c.lua_State, root_ref: c_int) !c_int {
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, root_ref);
    c.lua_getfield(lua_state, -1, "manager");
    c.lua_remove(lua_state, -2);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverManager;
    return c.lua_gettop(lua_state);
}

fn pushContext(lua_state: *c.lua_State, context: river_policy.Context) void {
    c.lua_createtable(lua_state, 0, 3);
    const table = c.lua_gettop(lua_state);

    c.lua_createtable(lua_state, @intCast(context.outputs.len), 0);
    for (context.outputs, 1..) |output, index| {
        c.lua_createtable(lua_state, 0, 5);
        lua_value.setIntegerField(lua_state, -1, "id", output.id);
        lua_value.setIntegerField(lua_state, -1, "x", output.x);
        lua_value.setIntegerField(lua_state, -1, "y", output.y);
        lua_value.setIntegerField(lua_state, -1, "width", output.width);
        lua_value.setIntegerField(lua_state, -1, "height", output.height);
        c.lua_rawseti(lua_state, -2, @intCast(index));
    }
    c.lua_setfield(lua_state, table, "outputs");

    c.lua_createtable(lua_state, @intCast(context.windows.len), 0);
    for (context.windows, 1..) |window, index| {
        c.lua_createtable(lua_state, 0, 4);
        lua_value.setIntegerField(lua_state, -1, "id", window.id);
        setOptionalString(lua_state, -1, "title", window.title);
        setOptionalString(lua_state, -1, "app_id", window.app_id);
        setOptionalString(lua_state, -1, "identifier", window.identifier);
        c.lua_rawseti(lua_state, -2, @intCast(index));
    }
    c.lua_setfield(lua_state, table, "windows");

    if (context.focused_window) |id| {
        lua_value.setIntegerField(lua_state, table, "focused_window", id);
    } else {
        c.lua_pushnil(lua_state);
        c.lua_setfield(lua_state, table, "focused_window");
    }
}

fn setOptionalString(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8, value: ?[]const u8) void {
    const absolute_table = lua_value.absoluteIndex(lua_state, table);
    if (value) |string| {
        lua_value.setStringField(lua_state, absolute_table, name, string);
    } else {
        c.lua_pushnil(lua_state);
        c.lua_setfield(lua_state, absolute_table, name);
    }
}

fn integerField(comptime T: type, lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) !T {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TNUMBER) return error.InvalidRiverPlacement;
    const number = c.lua_tonumber(lua_state, -1);
    if (!std.math.isFinite(number) or @floor(number) != number) return error.InvalidRiverPlacement;
    const min: f64 = @floatFromInt(std.math.minInt(T));
    const max: f64 = @floatFromInt(std.math.maxInt(T));
    if (number < min or number > max) return error.InvalidRiverPlacement;
    return @intFromFloat(number);
}

fn positiveDimension(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) !i32 {
    const value = try integerField(i32, lua_state, table, name);
    if (value <= 0) return error.InvalidRiverPlacement;
    return value;
}

fn optionalBoolField(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8, default: bool) !bool {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    return switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => default,
        c.LUA_TBOOLEAN => c.lua_toboolean(lua_state, -1) != 0,
        else => error.InvalidRiverPlacement,
    };
}

test "parseBinding accepts common modifier names" {
    const binding = try parseBinding(std.testing.allocator, "Super+Shift+Return");
    try std.testing.expectEqual(@as(u32, xkb.XKB_KEY_Return), binding.keysym);
    try std.testing.expectEqual(@as(u32, 65), binding.modifiers);
}

test "parseBinding rejects unknown modifiers" {
    try std.testing.expectError(error.InvalidRiverModifier, parseBinding(std.testing.allocator, "Hyper+q"));
}
