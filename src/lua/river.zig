//! Lua declarations and transaction callbacks for River window-manager apps.

const std = @import("std");
const river_policy = @import("../app/river_policy.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");
const xkb = @import("xkb_c");

const pop = lua_value.pop;

pub fn pushModule(lua_state: *c.lua_State) void {
    c.lua_createtable(lua_state, 0, 2);
    const module = c.lua_gettop(lua_state);
    lua_value.setClosureField(lua_state, module, "app", luaRiverApp, 0);
    lua_value.setClosureField(lua_state, module, "window_manager", luaWindowManager, 0);
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
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING) return error.InvalidRiverBinding;
        try validateBindingHandler(lua_state, -1);
        const id = try lua_value.dupeStringFromStack(lua_state, allocator, -2);
        errdefer allocator.free(id);
        const parsed = try parseBinding(allocator, id);
        try bindings.append(allocator, .{
            .id = id,
            .keysym = parsed.keysym,
            .modifiers = parsed.modifiers,
            .layout = if (c.lua_type(lua_state, -1) == c.LUA_TTABLE)
                try optionalIntegerField(u32, lua_state, c.lua_gettop(lua_state), "layout")
            else
                null,
        });
    }
    return bindings.toOwnedSlice(allocator);
}

pub fn parsePointerBindings(
    lua_state: *c.lua_State,
    root_ref: c_int,
    allocator: std.mem.Allocator,
) ![]river_policy.PointerBinding {
    const stack_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, stack_top);
    const manager = try pushManager(lua_state, root_ref);
    c.lua_getfield(lua_state, manager, "pointer_bindings");
    if (c.lua_isnil(lua_state, -1)) return allocator.alloc(river_policy.PointerBinding, 0);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverPointerBindings;
    const declarations = c.lua_gettop(lua_state);
    const count: usize = @intCast(c.lua_objlen(lua_state, declarations));

    var bindings: std.ArrayList(river_policy.PointerBinding) = .empty;
    errdefer {
        for (bindings.items) |binding| allocator.free(binding.id);
        bindings.deinit(allocator);
    }
    for (0..count) |index| {
        c.lua_rawgeti(lua_state, declarations, @intCast(index + 1));
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverPointerBinding;
        const declaration = c.lua_gettop(lua_state);
        try validatePointerBindingHandler(lua_state, declaration);
        const id = try lua_value.dupeStringField(lua_state, allocator, declaration, "id");
        errdefer allocator.free(id);
        for (bindings.items) |binding| {
            if (std.mem.eql(u8, binding.id, id)) return error.DuplicateRiverPointerBinding;
        }
        try bindings.append(allocator, .{
            .id = id,
            .button = try integerField(u32, lua_state, declaration, "button"),
            .modifiers = try modifiersField(lua_state, declaration),
        });
    }
    return bindings.toOwnedSlice(allocator);
}

fn validateBindingHandler(lua_state: *c.lua_State, index: c_int) !void {
    if (c.lua_type(lua_state, index) == c.LUA_TFUNCTION) return;
    if (c.lua_type(lua_state, index) != c.LUA_TTABLE) return error.InvalidRiverBinding;
    const table = lua_value.absoluteIndex(lua_state, index);
    var handler_count: usize = 0;
    for ([_][*:0]const u8{ "pressed", "released", "stop_repeat" }) |name| {
        c.lua_getfield(lua_state, table, name);
        defer pop(lua_state, 1);
        if (c.lua_isnil(lua_state, -1)) continue;
        if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.InvalidRiverBindingHandler;
        handler_count += 1;
    }
    if (handler_count == 0) return error.InvalidRiverBindingHandler;
}

fn validatePointerBindingHandler(lua_state: *c.lua_State, index: c_int) !void {
    const table = lua_value.absoluteIndex(lua_state, index);
    var handler_count: usize = 0;
    for ([_][*:0]const u8{ "pressed", "released" }) |name| {
        c.lua_getfield(lua_state, table, name);
        defer pop(lua_state, 1);
        if (c.lua_isnil(lua_state, -1)) continue;
        if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.InvalidRiverBindingHandler;
        handler_count += 1;
    }
    if (handler_count == 0) return error.InvalidRiverBindingHandler;
}

pub fn validate(
    lua_state: *c.lua_State,
    root_ref: c_int,
    allocator: std.mem.Allocator,
) !void {
    const bindings = try parseBindings(lua_state, root_ref, allocator);
    defer river_policy.freeBindings(allocator, bindings);
    const pointer_bindings = try parsePointerBindings(lua_state, root_ref, allocator);
    defer river_policy.freePointerBindings(allocator, pointer_bindings);

    const stack_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, stack_top);
    const manager = try pushManager(lua_state, root_ref);
    inline for (.{ "manage", "render" }) |name| {
        c.lua_getfield(lua_state, manager, name);
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.RiverTransactionCallbackMissing;
    }
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

pub fn invokeBinding(
    lua_state: *c.lua_State,
    root_ref: c_int,
    id: []const u8,
    event: river_policy.BindingEvent,
    seat: u32,
) !void {
    const stack_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, stack_top);
    const manager = try pushManager(lua_state, root_ref);
    c.lua_getfield(lua_state, manager, "bindings");
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverBindings;
    c.lua_pushlstring(lua_state, id.ptr, id.len);
    _ = c.lua_gettable(lua_state, -2);
    if (c.lua_type(lua_state, -1) == c.LUA_TFUNCTION) {
        if (event != .pressed) return;
    } else if (c.lua_type(lua_state, -1) == c.LUA_TTABLE) {
        c.lua_getfield(lua_state, -1, @tagName(event));
        if (c.lua_isnil(lua_state, -1)) return;
        if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.InvalidRiverBindingHandler;
    } else return error.UnknownRiverBinding;
    c.lua_pushinteger(lua_state, seat);
    c.lua_pushstring(lua_state, @tagName(event));
    if (c.lua_pcall(lua_state, 2, 0, 0) != 0)
        return lua_value.failLuaCall(lua_state, "river binding callback failed");
}

pub fn invokePointerBinding(
    lua_state: *c.lua_State,
    root_ref: c_int,
    id: []const u8,
    event: river_policy.BindingEvent,
    seat: u32,
) !void {
    const stack_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, stack_top);
    const manager = try pushManager(lua_state, root_ref);
    c.lua_getfield(lua_state, manager, "pointer_bindings");
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverPointerBindings;
    const declarations = c.lua_gettop(lua_state);
    const count: usize = @intCast(c.lua_objlen(lua_state, declarations));
    for (0..count) |index| {
        c.lua_rawgeti(lua_state, declarations, @intCast(index + 1));
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverPointerBinding;
        const declaration = c.lua_gettop(lua_state);
        c.lua_getfield(lua_state, declaration, "id");
        const declaration_id = lua_value.stringFromStack(lua_state, -1) catch return error.InvalidRiverPointerBinding;
        pop(lua_state, 1);
        if (!std.mem.eql(u8, id, declaration_id)) continue;
        c.lua_getfield(lua_state, declaration, @tagName(event));
        if (c.lua_isnil(lua_state, -1)) return;
        if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.InvalidRiverBindingHandler;
        c.lua_pushinteger(lua_state, seat);
        c.lua_pushstring(lua_state, @tagName(event));
        if (c.lua_pcall(lua_state, 2, 0, 0) != 0)
            return lua_value.failLuaCall(lua_state, "river pointer binding callback failed");
        return;
    }
    return error.UnknownRiverPointerBinding;
}

pub fn manage(
    lua_state: *c.lua_State,
    root_ref: c_int,
    allocator: std.mem.Allocator,
    context: river_policy.Context,
) ![]river_policy.ManageCommand {
    return invokeTransaction(river_policy.ManageCommand, lua_state, root_ref, allocator, context, "manage", parseManageCommand);
}

pub fn render(
    lua_state: *c.lua_State,
    root_ref: c_int,
    allocator: std.mem.Allocator,
    context: river_policy.Context,
) ![]river_policy.RenderCommand {
    return invokeTransaction(river_policy.RenderCommand, lua_state, root_ref, allocator, context, "render", parseRenderCommand);
}

fn invokeTransaction(
    comptime Command: type,
    lua_state: *c.lua_State,
    root_ref: c_int,
    allocator: std.mem.Allocator,
    context: river_policy.Context,
    comptime callback_name: [*:0]const u8,
    comptime parseCommand: fn (*c.lua_State, c_int, std.mem.Allocator) anyerror!Command,
) ![]Command {
    const stack_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, stack_top);
    const manager = try pushManager(lua_state, root_ref);
    c.lua_getfield(lua_state, manager, callback_name);
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.RiverTransactionCallbackMissing;
    pushContext(lua_state, context);
    if (c.lua_pcall(lua_state, 1, 1, 0) != 0)
        return lua_value.failLuaCall(lua_state, "river transaction callback failed");
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverCommands;
    const result = c.lua_gettop(lua_state);
    const count: usize = @intCast(c.lua_objlen(lua_state, result));
    const commands = try allocator.alloc(Command, count);
    errdefer allocator.free(commands);
    for (commands, 0..) |*command, index| {
        c.lua_rawgeti(lua_state, result, @intCast(index + 1));
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverCommand;
        command.* = try parseCommand(lua_state, c.lua_gettop(lua_state), allocator);
    }
    return commands;
}

fn parseManageCommand(
    lua_state: *c.lua_State,
    table: c_int,
    allocator: std.mem.Allocator,
) !river_policy.ManageCommand {
    const op = try operationName(lua_state, table);
    if (std.mem.eql(u8, op, "close")) return .{ .close = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "propose_dimensions")) return .{ .propose_dimensions = .{
        .window = try integerField(u32, lua_state, table, "window"),
        .width = try integerField(i32, lua_state, table, "width"),
        .height = try integerField(i32, lua_state, table, "height"),
    } };
    if (std.mem.eql(u8, op, "use_csd")) return .{ .use_csd = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "use_ssd")) return .{ .use_ssd = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "set_tiled")) return .{ .set_tiled = .{
        .window = try integerField(u32, lua_state, table, "window"),
        .edges = try edgesField(lua_state, table),
    } };
    if (std.mem.eql(u8, op, "inform_resize_start")) return .{ .inform_resize_start = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "inform_resize_end")) return .{ .inform_resize_end = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "set_capabilities")) return .{ .set_capabilities = .{
        .window = try integerField(u32, lua_state, table, "window"),
        .capabilities = .{
            .window_menu = try optionalBoolField(lua_state, table, "window_menu", false),
            .maximize = try optionalBoolField(lua_state, table, "maximize", false),
            .fullscreen = try optionalBoolField(lua_state, table, "fullscreen", false),
            .minimize = try optionalBoolField(lua_state, table, "minimize", false),
        },
    } };
    if (std.mem.eql(u8, op, "inform_maximized")) return .{ .inform_maximized = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "inform_unmaximized")) return .{ .inform_unmaximized = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "inform_fullscreen")) return .{ .inform_fullscreen = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "inform_not_fullscreen")) return .{ .inform_not_fullscreen = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "fullscreen")) return .{ .fullscreen = .{
        .window = try integerField(u32, lua_state, table, "window"),
        .output = try integerField(u32, lua_state, table, "output"),
    } };
    if (std.mem.eql(u8, op, "exit_fullscreen")) return .{ .exit_fullscreen = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "set_dimension_bounds")) return .{ .set_dimension_bounds = .{
        .window = try integerField(u32, lua_state, table, "window"),
        .max_width = try integerField(i32, lua_state, table, "max_width"),
        .max_height = try integerField(i32, lua_state, table, "max_height"),
    } };
    if (std.mem.eql(u8, op, "focus_window")) return .{ .focus_window = .{
        .seat = try integerField(u32, lua_state, table, "seat"),
        .window = try integerField(u32, lua_state, table, "window"),
    } };
    if (std.mem.eql(u8, op, "clear_focus")) return .{ .clear_focus = .{ .seat = try integerField(u32, lua_state, table, "seat") } };
    if (std.mem.eql(u8, op, "op_start_pointer")) return .{ .op_start_pointer = .{ .seat = try integerField(u32, lua_state, table, "seat") } };
    if (std.mem.eql(u8, op, "op_end")) return .{ .op_end = .{ .seat = try integerField(u32, lua_state, table, "seat") } };
    if (std.mem.eql(u8, op, "pointer_warp")) return .{ .pointer_warp = .{
        .seat = try integerField(u32, lua_state, table, "seat"),
        .x = try integerField(i32, lua_state, table, "x"),
        .y = try integerField(i32, lua_state, table, "y"),
    } };
    if (std.mem.eql(u8, op, "set_xcursor_theme")) return .{ .set_xcursor_theme = .{
        .seat = try integerField(u32, lua_state, table, "seat"),
        .name = try dupeZStringField(lua_state, allocator, table, "name"),
        .size = try integerField(u32, lua_state, table, "size"),
    } };
    if (std.mem.eql(u8, op, "ensure_next_key_eaten")) return .{ .ensure_next_key_eaten = .{
        .seat = try integerField(u32, lua_state, table, "seat"),
    } };
    if (std.mem.eql(u8, op, "cancel_ensure_next_key_eaten")) return .{ .cancel_ensure_next_key_eaten = .{
        .seat = try integerField(u32, lua_state, table, "seat"),
    } };
    if (std.mem.eql(u8, op, "modifiers_watch")) return .{ .modifiers_watch = .{
        .seat = try integerField(u32, lua_state, table, "seat"),
        .modifiers = try modifiersField(lua_state, table),
    } };
    if (std.mem.eql(u8, op, "exit_session")) return .exit_session;
    return error.UnknownRiverManageCommand;
}

fn parseRenderCommand(
    lua_state: *c.lua_State,
    table: c_int,
    _: std.mem.Allocator,
) !river_policy.RenderCommand {
    const op = try operationName(lua_state, table);
    if (std.mem.eql(u8, op, "hide")) return .{ .hide = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "show")) return .{ .show = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "set_borders")) return .{ .set_borders = .{
        .window = try integerField(u32, lua_state, table, "window"),
        .edges = try edgesField(lua_state, table),
        .width = try integerField(i32, lua_state, table, "width"),
        .color = try colorField(lua_state, table),
    } };
    if (std.mem.eql(u8, op, "set_position")) return .{ .set_position = .{
        .window = try integerField(u32, lua_state, table, "window"),
        .x = try integerField(i32, lua_state, table, "x"),
        .y = try integerField(i32, lua_state, table, "y"),
    } };
    if (std.mem.eql(u8, op, "place_top")) return .{ .place_top = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "place_bottom")) return .{ .place_bottom = .{ .window = try integerField(u32, lua_state, table, "window") } };
    if (std.mem.eql(u8, op, "place_above")) return .{ .place_above = .{
        .window = try integerField(u32, lua_state, table, "window"),
        .other = try integerField(u32, lua_state, table, "other"),
    } };
    if (std.mem.eql(u8, op, "place_below")) return .{ .place_below = .{
        .window = try integerField(u32, lua_state, table, "window"),
        .other = try integerField(u32, lua_state, table, "other"),
    } };
    if (std.mem.eql(u8, op, "set_clip_box")) return .{ .set_clip_box = .{
        .window = try integerField(u32, lua_state, table, "window"),
        .x = try integerField(i32, lua_state, table, "x"),
        .y = try integerField(i32, lua_state, table, "y"),
        .width = try integerField(i32, lua_state, table, "width"),
        .height = try integerField(i32, lua_state, table, "height"),
    } };
    if (std.mem.eql(u8, op, "set_content_clip_box")) return .{ .set_content_clip_box = .{
        .window = try integerField(u32, lua_state, table, "window"),
        .x = try integerField(i32, lua_state, table, "x"),
        .y = try integerField(i32, lua_state, table, "y"),
        .width = try integerField(i32, lua_state, table, "width"),
        .height = try integerField(i32, lua_state, table, "height"),
    } };
    if (std.mem.eql(u8, op, "set_presentation_mode")) return .{ .set_presentation_mode = .{
        .output = try integerField(u32, lua_state, table, "output"),
        .mode = try presentationModeField(lua_state, table, "mode"),
    } };
    return error.UnknownRiverRenderCommand;
}

fn operationName(lua_state: *c.lua_State, table: c_int) ![]const u8 {
    c.lua_rawgeti(lua_state, table, 1);
    defer pop(lua_state, 1);
    return lua_value.stringFromStack(lua_state, -1) catch error.InvalidRiverCommand;
}

fn edgesField(lua_state: *c.lua_State, table: c_int) !river_policy.Edges {
    c.lua_getfield(lua_state, table, "edges");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverEdges;
    const edges = c.lua_gettop(lua_state);
    return .{
        .top = try optionalBoolField(lua_state, edges, "top", false),
        .bottom = try optionalBoolField(lua_state, edges, "bottom", false),
        .left = try optionalBoolField(lua_state, edges, "left", false),
        .right = try optionalBoolField(lua_state, edges, "right", false),
    };
}

fn modifiersField(lua_state: *c.lua_State, table: c_int) !u32 {
    c.lua_getfield(lua_state, table, "modifiers");
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return 0;
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverModifiers;
    const modifiers = c.lua_gettop(lua_state);
    var mask: u32 = 0;
    if (try optionalBoolField(lua_state, modifiers, "shift", false)) mask |= 1;
    if (try optionalBoolField(lua_state, modifiers, "ctrl", false) or
        try optionalBoolField(lua_state, modifiers, "control", false)) mask |= 4;
    if (try optionalBoolField(lua_state, modifiers, "alt", false) or
        try optionalBoolField(lua_state, modifiers, "mod1", false)) mask |= 8;
    if (try optionalBoolField(lua_state, modifiers, "mod3", false)) mask |= 32;
    if (try optionalBoolField(lua_state, modifiers, "super", false) or
        try optionalBoolField(lua_state, modifiers, "mod4", false)) mask |= 64;
    if (try optionalBoolField(lua_state, modifiers, "mod5", false)) mask |= 128;
    return mask;
}

fn colorField(lua_state: *c.lua_State, table: c_int) !river_policy.Color {
    c.lua_getfield(lua_state, table, "color");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverColor;
    const color = c.lua_gettop(lua_state);
    return .{
        .r = try integerField(u32, lua_state, color, "r"),
        .g = try integerField(u32, lua_state, color, "g"),
        .b = try integerField(u32, lua_state, color, "b"),
        .a = try integerField(u32, lua_state, color, "a"),
    };
}

fn presentationModeField(
    lua_state: *c.lua_State,
    table: c_int,
    name: [*:0]const u8,
) !river_policy.PresentationMode {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    const value = lua_value.stringFromStack(lua_state, -1) catch return error.InvalidRiverPresentationMode;
    if (std.mem.eql(u8, value, "vsync")) return .vsync;
    if (std.mem.eql(u8, value, "async")) return .async;
    return error.InvalidRiverPresentationMode;
}

fn pushManager(lua_state: *c.lua_State, root_ref: c_int) !c_int {
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, root_ref);
    c.lua_getfield(lua_state, -1, "manager");
    c.lua_remove(lua_state, -2);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverManager;
    return c.lua_gettop(lua_state);
}

fn pushContext(lua_state: *c.lua_State, context: river_policy.Context) void {
    c.lua_createtable(lua_state, 0, 7);
    const table = c.lua_gettop(lua_state);
    lua_value.setBooleanField(lua_state, table, "session_locked", context.session_locked);
    lua_value.setIntegerField(lua_state, table, "window_management_version", context.window_management_version);
    lua_value.setIntegerField(lua_state, table, "xkb_bindings_version", context.xkb_bindings_version);

    c.lua_createtable(lua_state, @intCast(context.outputs.len), 0);
    for (context.outputs, 1..) |output, index| {
        c.lua_createtable(lua_state, 0, 6);
        lua_value.setIntegerField(lua_state, -1, "id", output.id);
        setOptionalInteger(lua_state, -1, "wl_output", output.wl_output);
        lua_value.setIntegerField(lua_state, -1, "x", output.x);
        lua_value.setIntegerField(lua_state, -1, "y", output.y);
        lua_value.setIntegerField(lua_state, -1, "width", output.width);
        lua_value.setIntegerField(lua_state, -1, "height", output.height);
        c.lua_rawseti(lua_state, -2, @intCast(index));
    }
    c.lua_setfield(lua_state, table, "outputs");

    c.lua_createtable(lua_state, @intCast(context.windows.len), 0);
    for (context.windows, 1..) |window, index| {
        c.lua_createtable(lua_state, 0, 11);
        lua_value.setIntegerField(lua_state, -1, "id", window.id);
        setOptionalString(lua_state, -1, "title", window.title);
        setOptionalString(lua_state, -1, "app_id", window.app_id);
        setOptionalString(lua_state, -1, "identifier", window.identifier);
        setOptionalInteger(lua_state, -1, "parent", window.parent);
        setOptionalInteger(lua_state, -1, "unreliable_pid", window.unreliable_pid);
        setOptionalDimensions(lua_state, -1, "dimensions", window.dimensions);
        setOptionalDimensionsHint(lua_state, -1, window.dimensions_hint);
        setOptionalEnum(lua_state, -1, "decoration_hint", window.decoration_hint);
        setOptionalEnum(lua_state, -1, "presentation_hint", window.presentation_hint);
        c.lua_rawseti(lua_state, -2, @intCast(index));
    }
    c.lua_setfield(lua_state, table, "windows");

    c.lua_createtable(lua_state, @intCast(context.seats.len), 0);
    for (context.seats, 1..) |seat, index| {
        c.lua_createtable(lua_state, 0, 4);
        lua_value.setIntegerField(lua_state, -1, "id", seat.id);
        setOptionalInteger(lua_state, -1, "wl_seat", seat.wl_seat);
        setOptionalInteger(lua_state, -1, "modifiers", seat.modifiers);
        const seat_table = c.lua_gettop(lua_state);
        if (seat.pointer_position) |point| {
            c.lua_createtable(lua_state, 0, 2);
            lua_value.setIntegerField(lua_state, -1, "x", point.x);
            lua_value.setIntegerField(lua_state, -1, "y", point.y);
        } else c.lua_pushnil(lua_state);
        c.lua_setfield(lua_state, seat_table, "pointer_position");
        c.lua_rawseti(lua_state, -2, @intCast(index));
    }
    c.lua_setfield(lua_state, table, "seats");

    c.lua_createtable(lua_state, @intCast(context.events.len), 0);
    for (context.events, 1..) |event, index| {
        pushEvent(lua_state, event);
        c.lua_rawseti(lua_state, -2, @intCast(index));
    }
    c.lua_setfield(lua_state, table, "events");
}

fn pushEvent(lua_state: *c.lua_State, event: river_policy.Event) void {
    c.lua_createtable(lua_state, 0, 5);
    const table = c.lua_gettop(lua_state);
    lua_value.setStringField(lua_state, table, "type", @tagName(event));
    switch (event) {
        .session_locked, .session_unlocked => {},
        .window_added, .window_closed, .maximize_requested, .unmaximize_requested, .exit_fullscreen_requested, .minimize_requested => |window| lua_value.setIntegerField(lua_state, table, "window", window),
        .output_added, .output_removed => |output| lua_value.setIntegerField(lua_state, table, "output", output),
        .seat_added, .seat_removed, .pointer_leave, .op_release, .ate_unbound_key => |seat| lua_value.setIntegerField(lua_state, table, "seat", seat),
        .pointer_move_requested, .pointer_enter, .window_interaction => |value| {
            lua_value.setIntegerField(lua_state, table, "window", value.window);
            lua_value.setIntegerField(lua_state, table, "seat", value.seat);
        },
        .pointer_resize_requested => |value| {
            lua_value.setIntegerField(lua_state, table, "window", value.window);
            lua_value.setIntegerField(lua_state, table, "seat", value.seat);
            pushEdges(lua_state, edgesFromMask(value.edges));
            c.lua_setfield(lua_state, table, "edges");
        },
        .show_window_menu_requested => |value| {
            lua_value.setIntegerField(lua_state, table, "window", value.window);
            lua_value.setIntegerField(lua_state, table, "x", value.x);
            lua_value.setIntegerField(lua_state, table, "y", value.y);
        },
        .fullscreen_requested => |value| {
            lua_value.setIntegerField(lua_state, table, "window", value.window);
            setOptionalInteger(lua_state, table, "output", value.output);
        },
        .op_delta => |value| {
            lua_value.setIntegerField(lua_state, table, "seat", value.seat);
            lua_value.setIntegerField(lua_state, table, "dx", value.dx);
            lua_value.setIntegerField(lua_state, table, "dy", value.dy);
        },
        .modifiers_update => |value| {
            lua_value.setIntegerField(lua_state, table, "seat", value.seat);
            lua_value.setIntegerField(lua_state, table, "old", value.old);
            lua_value.setIntegerField(lua_state, table, "new", value.new);
        },
    }
}

fn pushEdges(lua_state: *c.lua_State, edges: river_policy.Edges) void {
    c.lua_createtable(lua_state, 0, 4);
    lua_value.setBooleanField(lua_state, -1, "top", edges.top);
    lua_value.setBooleanField(lua_state, -1, "bottom", edges.bottom);
    lua_value.setBooleanField(lua_state, -1, "left", edges.left);
    lua_value.setBooleanField(lua_state, -1, "right", edges.right);
}

fn edgesFromMask(mask: u32) river_policy.Edges {
    return .{
        .top = mask & 1 != 0,
        .bottom = mask & 2 != 0,
        .left = mask & 4 != 0,
        .right = mask & 8 != 0,
    };
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

fn setOptionalInteger(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8, value: anytype) void {
    const absolute_table = lua_value.absoluteIndex(lua_state, table);
    if (value) |number| {
        lua_value.setIntegerField(lua_state, absolute_table, name, number);
    } else {
        c.lua_pushnil(lua_state);
        c.lua_setfield(lua_state, absolute_table, name);
    }
}

fn setOptionalDimensions(
    lua_state: *c.lua_State,
    table: c_int,
    name: [*:0]const u8,
    value: ?river_policy.Dimensions,
) void {
    const absolute_table = lua_value.absoluteIndex(lua_state, table);
    if (value) |dimensions| {
        c.lua_createtable(lua_state, 0, 2);
        lua_value.setIntegerField(lua_state, -1, "width", dimensions.width);
        lua_value.setIntegerField(lua_state, -1, "height", dimensions.height);
    } else c.lua_pushnil(lua_state);
    c.lua_setfield(lua_state, absolute_table, name);
}

fn setOptionalDimensionsHint(lua_state: *c.lua_State, table: c_int, value: ?river_policy.DimensionsHint) void {
    const absolute_table = lua_value.absoluteIndex(lua_state, table);
    if (value) |hint| {
        c.lua_createtable(lua_state, 0, 4);
        lua_value.setIntegerField(lua_state, -1, "min_width", hint.min_width);
        lua_value.setIntegerField(lua_state, -1, "min_height", hint.min_height);
        lua_value.setIntegerField(lua_state, -1, "max_width", hint.max_width);
        lua_value.setIntegerField(lua_state, -1, "max_height", hint.max_height);
    } else c.lua_pushnil(lua_state);
    c.lua_setfield(lua_state, absolute_table, "dimensions_hint");
}

fn setOptionalEnum(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8, value: anytype) void {
    const absolute_table = lua_value.absoluteIndex(lua_state, table);
    if (value) |enum_value| {
        lua_value.setStringField(lua_state, absolute_table, name, @tagName(enum_value));
    } else {
        c.lua_pushnil(lua_state);
        c.lua_setfield(lua_state, absolute_table, name);
    }
}

fn integerField(comptime T: type, lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) !T {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TNUMBER) return error.InvalidRiverCommand;
    const number = c.lua_tonumber(lua_state, -1);
    if (!std.math.isFinite(number) or @floor(number) != number) return error.InvalidRiverCommand;
    const min: f64 = @floatFromInt(std.math.minInt(T));
    const max: f64 = @floatFromInt(std.math.maxInt(T));
    if (number < min or number > max) return error.InvalidRiverCommand;
    return @intFromFloat(number);
}

fn optionalIntegerField(
    comptime T: type,
    lua_state: *c.lua_State,
    table: c_int,
    name: [*:0]const u8,
) !?T {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    if (c.lua_type(lua_state, -1) != c.LUA_TNUMBER) return error.InvalidRiverCommand;
    const number = c.lua_tonumber(lua_state, -1);
    if (!std.math.isFinite(number) or @floor(number) != number) return error.InvalidRiverCommand;
    const min: f64 = @floatFromInt(std.math.minInt(T));
    const max: f64 = @floatFromInt(std.math.maxInt(T));
    if (number < min or number > max) return error.InvalidRiverCommand;
    return @intFromFloat(number);
}

fn dupeZStringField(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    table: c_int,
    name: [*:0]const u8,
) ![:0]const u8 {
    const value = try lua_value.stringField(lua_state, table, name);
    return allocator.dupeZ(u8, value);
}

fn optionalBoolField(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8, default: bool) !bool {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    return switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => default,
        c.LUA_TBOOLEAN => c.lua_toboolean(lua_state, -1) != 0,
        else => error.InvalidRiverCommand,
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
