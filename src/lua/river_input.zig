//! Lua snapshot and command boundary for River input applications.

const std = @import("std");
const policy = @import("../app/river_input_policy.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const pop = lua_value.pop;

pub fn validate(lua_state: *c.lua_State, root_ref: c_int) !void {
    const stack_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, stack_top);
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, root_ref);
    c.lua_getfield(lua_state, -1, "update");
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.RiverInputUpdateMissing;
}

pub fn update(
    lua_state: *c.lua_State,
    root_ref: c_int,
    allocator: std.mem.Allocator,
    context: policy.Context,
) ![]policy.Command {
    const stack_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, stack_top);
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, root_ref);
    c.lua_getfield(lua_state, -1, "update");
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.RiverInputUpdateMissing;
    pushContext(lua_state, context);
    if (c.lua_pcall(lua_state, 1, 1, 0) != 0)
        return lua_value.failLuaCall(lua_state, "river input callback failed");
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverInputCommands;
    const result = c.lua_gettop(lua_state);
    const count: usize = @intCast(c.lua_objlen(lua_state, result));
    const commands = try allocator.alloc(policy.Command, count);
    for (commands, 0..) |*command, index| {
        c.lua_rawgeti(lua_state, result, @intCast(index + 1));
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverInputCommand;
        command.* = try parseCommand(lua_state, c.lua_gettop(lua_state), allocator);
    }
    return commands;
}

fn parseCommand(lua_state: *c.lua_State, table: c_int, allocator: std.mem.Allocator) !policy.Command {
    const operation = try operationName(lua_state, table);
    if (std.mem.eql(u8, operation, "create_seat")) return .{ .create_seat = .{
        .name = try stringField(lua_state, table, "name", allocator),
    } };
    if (std.mem.eql(u8, operation, "destroy_seat")) return .{ .destroy_seat = .{
        .name = try stringField(lua_state, table, "name", allocator),
    } };
    if (std.mem.eql(u8, operation, "assign_to_seat")) return .{ .assign_to_seat = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .name = try stringField(lua_state, table, "name", allocator),
    } };
    if (std.mem.eql(u8, operation, "set_repeat_info")) return .{ .set_repeat_info = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .rate = try integerField(i32, lua_state, table, "rate"),
        .delay = try integerField(i32, lua_state, table, "delay"),
    } };
    if (std.mem.eql(u8, operation, "set_scroll_factor")) return .{ .set_scroll_factor = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .factor = try numberField(lua_state, table, "factor"),
    } };
    if (std.mem.eql(u8, operation, "map_to_output")) return .{ .map_to_output = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .output = try optionalIntegerField(u32, lua_state, table, "output"),
    } };
    if (std.mem.eql(u8, operation, "map_to_rectangle")) return .{ .map_to_rectangle = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .x = try integerField(i32, lua_state, table, "x"),
        .y = try integerField(i32, lua_state, table, "y"),
        .width = try integerField(i32, lua_state, table, "width"),
        .height = try integerField(i32, lua_state, table, "height"),
    } };
    if (std.mem.eql(u8, operation, "create_keymap")) return .{ .create_keymap = .{
        .id = try stringField(lua_state, table, "id", allocator),
        .text = try stringField(lua_state, table, "text", allocator),
        .format = try optionalEnumField(policy.KeymapFormat, lua_state, table, "format") orelse .text_v1,
    } };
    if (std.mem.eql(u8, operation, "destroy_keymap")) return .{ .destroy_keymap = .{
        .id = try stringField(lua_state, table, "id", allocator),
    } };
    if (std.mem.eql(u8, operation, "set_keymap")) return .{ .set_keymap = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .id = try stringField(lua_state, table, "keymap", allocator),
    } };
    if (std.mem.eql(u8, operation, "set_layout_by_index")) return .{ .set_layout_by_index = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .index = try integerField(i32, lua_state, table, "index"),
    } };
    if (std.mem.eql(u8, operation, "set_layout_by_name")) return .{ .set_layout_by_name = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .name = try stringField(lua_state, table, "name", allocator),
    } };
    if (std.mem.eql(u8, operation, "set_capslock")) return .{ .set_capslock = try deviceBool(lua_state, table) };
    if (std.mem.eql(u8, operation, "set_numlock")) return .{ .set_numlock = try deviceBool(lua_state, table) };
    if (std.mem.eql(u8, operation, "create_accel_config")) return .{ .create_accel_config = .{
        .id = try stringField(lua_state, table, "id", allocator),
        .profile = try enumField(policy.AccelProfile, lua_state, table, "profile"),
    } };
    if (std.mem.eql(u8, operation, "destroy_accel_config")) return .{ .destroy_accel_config = .{
        .id = try stringField(lua_state, table, "id", allocator),
    } };
    if (std.mem.eql(u8, operation, "set_accel_points")) return .{ .set_accel_points = .{
        .id = try stringField(lua_state, table, "config", allocator),
        .type = try enumField(policy.AccelType, lua_state, table, "type"),
        .step = try numberField(lua_state, table, "step"),
        .points = try numberArray(lua_state, table, "points", allocator),
    } };
    if (std.mem.eql(u8, operation, "apply_accel_config")) return .{ .apply_accel_config = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .id = try stringField(lua_state, table, "config", allocator),
    } };
    if (std.mem.eql(u8, operation, "set_send_events")) return .{ .set_send_events = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .mode = try sendEventsMode(lua_state, table),
    } };
    if (std.mem.eql(u8, operation, "set_tap")) return .{ .set_tap = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .state = try enumField(policy.BinaryState, lua_state, table, "state"),
    } };
    if (std.mem.eql(u8, operation, "set_tap_button_map")) return .{ .set_tap_button_map = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .map = try enumField(policy.TapButtonMap, lua_state, table, "map"),
    } };
    if (std.mem.eql(u8, operation, "set_drag")) return .{ .set_drag = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .state = try enumField(policy.BinaryState, lua_state, table, "state"),
    } };
    if (std.mem.eql(u8, operation, "set_drag_lock")) return .{ .set_drag_lock = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .state = try enumField(policy.DragLockState, lua_state, table, "state"),
    } };
    if (std.mem.eql(u8, operation, "set_three_finger_drag")) return .{ .set_three_finger_drag = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .state = try enumField(policy.ThreeFingerDragState, lua_state, table, "state"),
    } };
    if (std.mem.eql(u8, operation, "set_calibration_matrix")) return .{ .set_calibration_matrix = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .matrix = try matrixField(lua_state, table),
    } };
    if (std.mem.eql(u8, operation, "set_accel_profile")) return .{ .set_accel_profile = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .profile = try enumField(policy.AccelProfile, lua_state, table, "profile"),
    } };
    if (std.mem.eql(u8, operation, "set_accel_speed")) return .{ .set_accel_speed = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .speed = try numberField(lua_state, table, "speed"),
    } };
    if (std.mem.eql(u8, operation, "set_natural_scroll")) return .{ .set_natural_scroll = try deviceBool(lua_state, table) };
    if (std.mem.eql(u8, operation, "set_left_handed")) return .{ .set_left_handed = try deviceBool(lua_state, table) };
    if (std.mem.eql(u8, operation, "set_click_method")) return .{ .set_click_method = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .method = try enumField(policy.ClickMethod, lua_state, table, "method"),
    } };
    if (std.mem.eql(u8, operation, "set_clickfinger_button_map")) return .{ .set_clickfinger_button_map = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .map = try enumField(policy.TapButtonMap, lua_state, table, "map"),
    } };
    if (std.mem.eql(u8, operation, "set_middle_emulation")) return .{ .set_middle_emulation = try deviceBool(lua_state, table) };
    if (std.mem.eql(u8, operation, "set_scroll_method")) return .{ .set_scroll_method = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .method = try enumField(policy.ScrollMethod, lua_state, table, "method"),
    } };
    if (std.mem.eql(u8, operation, "set_scroll_button")) return .{ .set_scroll_button = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .button = try integerField(u32, lua_state, table, "button"),
    } };
    if (std.mem.eql(u8, operation, "set_scroll_button_lock")) return .{ .set_scroll_button_lock = try deviceBool(lua_state, table) };
    if (std.mem.eql(u8, operation, "set_dwt")) return .{ .set_dwt = try deviceBool(lua_state, table) };
    if (std.mem.eql(u8, operation, "set_dwtp")) return .{ .set_dwtp = try deviceBool(lua_state, table) };
    if (std.mem.eql(u8, operation, "set_rotation")) return .{ .set_rotation = .{
        .device = try integerField(u32, lua_state, table, "device"),
        .angle = try integerField(u32, lua_state, table, "angle"),
    } };
    return error.UnknownRiverInputCommand;
}

fn pushContext(lua_state: *c.lua_State, context: policy.Context) void {
    c.lua_createtable(lua_state, 0, 8);
    const table = c.lua_gettop(lua_state);
    lua_value.setIntegerField(lua_state, table, "input_management_version", context.input_management_version);
    lua_value.setIntegerField(lua_state, table, "libinput_config_version", context.libinput_config_version);
    lua_value.setIntegerField(lua_state, table, "xkb_config_version", context.xkb_config_version);

    c.lua_createtable(lua_state, @intCast(context.devices.len), 0);
    for (context.devices, 1..) |device, index| {
        c.lua_createtable(lua_state, 0, 5);
        lua_value.setIntegerField(lua_state, -1, "id", device.id);
        if (device.type) |value| lua_value.setStringField(lua_state, -1, "type", @tagName(value));
        if (device.name) |value| lua_value.setStringField(lua_state, -1, "name", value);
        if (device.libinput) |value| {
            pushLibinputState(lua_state, value);
            c.lua_setfield(lua_state, -2, "libinput");
        }
        if (device.keyboard) |value| {
            c.lua_createtable(lua_state, 0, 4);
            setOptionalValueField(lua_state, -1, "layout_index", value.layout_index);
            if (value.layout_name) |name| lua_value.setStringField(lua_state, -1, "layout_name", name);
            setOptionalValueField(lua_state, -1, "capslock", value.capslock);
            setOptionalValueField(lua_state, -1, "numlock", value.numlock);
            c.lua_setfield(lua_state, -2, "keyboard");
        }
        c.lua_rawseti(lua_state, -2, @intCast(index));
    }
    c.lua_setfield(lua_state, table, "devices");

    c.lua_createtable(lua_state, @intCast(context.outputs.len), 0);
    for (context.outputs, 1..) |output, index| {
        c.lua_createtable(lua_state, 0, 3);
        lua_value.setIntegerField(lua_state, -1, "id", output.id);
        lua_value.setIntegerField(lua_state, -1, "registry_name", output.registry_name);
        if (output.name) |name| lua_value.setStringField(lua_state, -1, "name", name);
        c.lua_rawseti(lua_state, -2, @intCast(index));
    }
    c.lua_setfield(lua_state, table, "outputs");

    c.lua_createtable(lua_state, @intCast(context.keymaps.len), 0);
    for (context.keymaps, 1..) |keymap, index| {
        c.lua_createtable(lua_state, 0, 3);
        lua_value.setStringField(lua_state, -1, "id", keymap.id);
        lua_value.setStringField(lua_state, -1, "state", @tagName(keymap.state));
        if (keymap.error_message) |message| lua_value.setStringField(lua_state, -1, "error", message);
        c.lua_rawseti(lua_state, -2, @intCast(index));
    }
    c.lua_setfield(lua_state, table, "keymaps");

    c.lua_createtable(lua_state, @intCast(context.accel_configs.len), 0);
    for (context.accel_configs, 1..) |config, index| {
        c.lua_createtable(lua_state, 0, 2);
        lua_value.setStringField(lua_state, -1, "id", config.id);
        lua_value.setStringField(lua_state, -1, "profile", @tagName(config.profile));
        c.lua_rawseti(lua_state, -2, @intCast(index));
    }
    c.lua_setfield(lua_state, table, "accel_configs");

    c.lua_createtable(lua_state, @intCast(context.events.len), 0);
    for (context.events, 1..) |event, index| {
        pushEvent(lua_state, event);
        c.lua_rawseti(lua_state, -2, @intCast(index));
    }
    c.lua_setfield(lua_state, table, "events");
}

fn pushLibinputState(lua_state: *c.lua_State, state: policy.LibinputState) void {
    c.lua_createtable(lua_state, 0, 20);
    setStateField(lua_state, -1, "send_events", state.send_events);
    setStateField(lua_state, -1, "tap", state.tap);
    setStateField(lua_state, -1, "tap_button_map", state.tap_button_map);
    setStateField(lua_state, -1, "drag", state.drag);
    setStateField(lua_state, -1, "drag_lock", state.drag_lock);
    setStateField(lua_state, -1, "three_finger_drag", state.three_finger_drag);
    setStateField(lua_state, -1, "calibration_matrix", state.calibration_matrix);
    setStateField(lua_state, -1, "accel_profile", state.accel_profile);
    setStateField(lua_state, -1, "accel_speed", state.accel_speed);
    setStateField(lua_state, -1, "natural_scroll", state.natural_scroll);
    setStateField(lua_state, -1, "left_handed", state.left_handed);
    setStateField(lua_state, -1, "click_method", state.click_method);
    setStateField(lua_state, -1, "clickfinger_button_map", state.clickfinger_button_map);
    setStateField(lua_state, -1, "middle_emulation", state.middle_emulation);
    setStateField(lua_state, -1, "scroll_method", state.scroll_method);
    setStateField(lua_state, -1, "scroll_button", state.scroll_button);
    setStateField(lua_state, -1, "scroll_button_lock", state.scroll_button_lock);
    setStateField(lua_state, -1, "dwt", state.dwt);
    setStateField(lua_state, -1, "dwtp", state.dwtp);
    setStateField(lua_state, -1, "rotation", state.rotation);
}

fn setStateField(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8, state: anytype) void {
    const absolute_table = lua_value.absoluteIndex(lua_state, table);
    c.lua_createtable(lua_state, 0, 3);
    if (@hasField(@TypeOf(state), "support")) setOptionalValueField(lua_state, -1, "support", state.support);
    setOptionalValueField(lua_state, -1, "default", state.default);
    setOptionalValueField(lua_state, -1, "current", state.current);
    c.lua_setfield(lua_state, absolute_table, name);
}

fn setOptionalValueField(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8, value: anytype) void {
    const absolute_table = lua_value.absoluteIndex(lua_state, table);
    if (value) |inner| {
        pushValue(lua_state, inner);
        c.lua_setfield(lua_state, absolute_table, name);
    }
}

fn pushValue(lua_state: *c.lua_State, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .bool => c.lua_pushboolean(lua_state, if (value) 1 else 0),
        .int, .comptime_int => c.lua_pushinteger(lua_state, @intCast(value)),
        .float, .comptime_float => c.lua_pushnumber(lua_state, @floatCast(value)),
        .@"enum" => c.lua_pushstring(lua_state, @tagName(value)),
        .array => {
            c.lua_createtable(lua_state, @intCast(value.len), 0);
            for (value, 1..) |item, index| {
                pushValue(lua_state, item);
                c.lua_rawseti(lua_state, -2, @intCast(index));
            }
        },
        else => @compileError("unsupported River input Lua value"),
    }
}

fn pushEvent(lua_state: *c.lua_State, event: policy.Event) void {
    c.lua_createtable(lua_state, 0, 5);
    const table = c.lua_gettop(lua_state);
    lua_value.setStringField(lua_state, table, "type", @tagName(event));
    switch (event) {
        .device_added, .device_removed, .state_changed => |device| lua_value.setIntegerField(lua_state, table, "device", device),
        .output_added, .output_removed => |output| lua_value.setIntegerField(lua_state, table, "output", output),
        .keymap_ready => |id| lua_value.setStringField(lua_state, table, "keymap", id),
        .keymap_failed => |value| {
            lua_value.setStringField(lua_state, table, "keymap", value.id);
            lua_value.setStringField(lua_state, table, "error", value.error_message);
        },
        .libinput_result => |value| {
            switch (value.target) {
                .device => |device| lua_value.setIntegerField(lua_state, table, "device", device),
                .accel_config => |config| lua_value.setStringField(lua_state, table, "accel_config", config),
            }
            lua_value.setStringField(lua_state, table, "operation", @tagName(value.operation));
            lua_value.setStringField(lua_state, table, "status", @tagName(value.status));
        },
    }
}

fn operationName(lua_state: *c.lua_State, table: c_int) ![]const u8 {
    c.lua_rawgeti(lua_state, table, 1);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TSTRING) return error.InvalidRiverInputCommand;
    return lua_value.stringFromStack(lua_state, -1);
}

fn deviceBool(lua_state: *c.lua_State, table: c_int) !policy.DeviceBool {
    return .{
        .device = try integerField(u32, lua_state, table, "device"),
        .enabled = try booleanField(lua_state, table, "enabled"),
    };
}

fn integerField(comptime T: type, lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) !T {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TNUMBER) return error.InvalidRiverInputCommand;
    const number = c.lua_tonumber(lua_state, -1);
    if (!std.math.isFinite(number) or @floor(number) != number) return error.InvalidRiverInputCommand;
    const minimum: f64 = @floatFromInt(std.math.minInt(T));
    const maximum: f64 = @floatFromInt(std.math.maxInt(T));
    if (number < minimum or number > maximum) return error.InvalidRiverInputCommand;
    return @intFromFloat(number);
}

fn optionalIntegerField(comptime T: type, lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) !?T {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    if (c.lua_type(lua_state, -1) != c.LUA_TNUMBER) return error.InvalidRiverInputCommand;
    const number = c.lua_tonumber(lua_state, -1);
    if (!std.math.isFinite(number) or @floor(number) != number) return error.InvalidRiverInputCommand;
    const minimum: f64 = @floatFromInt(std.math.minInt(T));
    const maximum: f64 = @floatFromInt(std.math.maxInt(T));
    if (number < minimum or number > maximum) return error.InvalidRiverInputCommand;
    return @intFromFloat(number);
}

fn numberField(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) !f64 {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TNUMBER) return error.InvalidRiverInputCommand;
    return c.lua_tonumber(lua_state, -1);
}

fn booleanField(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) !bool {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TBOOLEAN) return error.InvalidRiverInputCommand;
    return c.lua_toboolean(lua_state, -1) != 0;
}

fn stringField(
    lua_state: *c.lua_State,
    table: c_int,
    name: [*:0]const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TSTRING) return error.InvalidRiverInputCommand;
    return allocator.dupe(u8, try lua_value.stringFromStack(lua_state, -1));
}

fn enumField(comptime T: type, lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) !T {
    return (try optionalEnumField(T, lua_state, table, name)) orelse error.InvalidRiverInputCommand;
}

fn optionalEnumField(comptime T: type, lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) !?T {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    if (c.lua_type(lua_state, -1) != c.LUA_TSTRING) return error.InvalidRiverInputCommand;
    const value = try lua_value.stringFromStack(lua_state, -1);
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidRiverInputCommand;
}

fn sendEventsMode(lua_state: *c.lua_State, table: c_int) !u32 {
    c.lua_getfield(lua_state, table, "mode");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TSTRING) return error.InvalidRiverInputCommand;
    const value = try lua_value.stringFromStack(lua_state, -1);
    if (std.mem.eql(u8, value, "enabled")) return 0;
    if (std.mem.eql(u8, value, "disabled")) return 1;
    if (std.mem.eql(u8, value, "disabled_on_external_mouse")) return 2;
    return error.InvalidRiverInputCommand;
}

fn matrixField(lua_state: *c.lua_State, table: c_int) ![6]f32 {
    c.lua_getfield(lua_state, table, "matrix");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE or c.lua_objlen(lua_state, -1) != 6)
        return error.InvalidRiverInputCommand;
    var matrix: [6]f32 = undefined;
    for (&matrix, 1..) |*entry, index| {
        c.lua_rawgeti(lua_state, -1, @intCast(index));
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) != c.LUA_TNUMBER) return error.InvalidRiverInputCommand;
        entry.* = @floatCast(c.lua_tonumber(lua_state, -1));
    }
    return matrix;
}

fn numberArray(
    lua_state: *c.lua_State,
    table: c_int,
    name: [*:0]const u8,
    allocator: std.mem.Allocator,
) ![]const f64 {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidRiverInputCommand;
    const count: usize = @intCast(c.lua_objlen(lua_state, -1));
    const values = try allocator.alloc(f64, count);
    for (values, 1..) |*entry, index| {
        c.lua_rawgeti(lua_state, -1, @intCast(index));
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) != c.LUA_TNUMBER) return error.InvalidRiverInputCommand;
        entry.* = c.lua_tonumber(lua_state, -1);
    }
    return values;
}
