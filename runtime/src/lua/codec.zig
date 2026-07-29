//! Small comptime Lua table codec for app-side option structs.

const std = @import("std");
const keywork = @import("../ui.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

pub fn decode(comptime T: type, lua_state: *c.lua_State, index: c_int, allocator: std.mem.Allocator) !T {
    const table = absoluteIndex(lua_state, index);
    if (c.lua_type(lua_state, table) != c.LUA_TTABLE) return error.ExpectedLuaTable;

    var result: T = .{};
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.is_comptime) continue;
        c.lua_getfield(lua_state, table, field.name);
        if (!c.lua_isnil(lua_state, -1)) {
            @field(result, field.name) = decodeValue(field.type, lua_state, -1, allocator) catch |err| {
                pop(lua_state, 1);
                return err;
            };
        }
        pop(lua_state, 1);
    }
    return result;
}

pub fn push(comptime T: type, lua_state: *c.lua_State, value: T) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (T == keywork.Color) {
                c.lua_pushnumber(lua_state, @floatFromInt(@as(u32, @bitCast(value))));
                return;
            }
            c.lua_createtable(lua_state, 0, info.fields.len);
            inline for (info.fields) |field| {
                if (field.is_comptime) continue;
                try push(field.type, lua_state, @field(value, field.name));
                c.lua_setfield(lua_state, -2, field.name);
            }
        },
        .optional => |info| {
            if (value) |child| {
                try push(info.child, lua_state, child);
            } else {
                c.lua_pushnil(lua_state);
            }
        },
        .@"enum" => c.lua_pushstring(lua_state, @tagName(value)),
        .bool => c.lua_pushboolean(lua_state, if (value) 1 else 0),
        .int, .comptime_int => c.lua_pushnumber(lua_state, @floatFromInt(value)),
        .float, .comptime_float => c.lua_pushnumber(lua_state, @floatCast(value)),
        .pointer => |info| {
            if (info.size != .slice or info.child != u8) @compileError("unsupported Lua pointer field: " ++ @typeName(T));
            c.lua_pushlstring(lua_state, value.ptr, value.len);
        },
        else => @compileError("unsupported Lua value type: " ++ @typeName(T)),
    }
}

fn decodeValue(comptime T: type, lua_state: *c.lua_State, index: c_int, allocator: std.mem.Allocator) !T {
    switch (@typeInfo(T)) {
        .optional => |info| {
            if (c.lua_isnil(lua_state, index)) return null;
            return try decodeValue(info.child, lua_state, index, allocator);
        },
        .@"struct" => {
            if (T == keywork.Color) return try decodeColor(lua_state, index);
            if (T == keywork.EdgeInsets) return try decodeInsets(lua_state, index, allocator);
            if (T == keywork.BoxShadow) return try decodeBoxShadow(lua_state, index, allocator);
            return try decode(T, lua_state, index, allocator);
        },
        .@"enum" => |info| {
            const value = try stringFromStack(lua_state, index);
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, value, field.name)) return @field(T, field.name);
            }
            return error.UnknownLuaEnumValue;
        },
        .bool => {
            if (!c.lua_isboolean(lua_state, index)) return error.ExpectedLuaBoolean;
            return c.lua_toboolean(lua_state, index) != 0;
        },
        .int => {
            if (c.lua_isnumber(lua_state, index) == 0) return error.ExpectedLuaNumber;
            return @intFromFloat(c.lua_tonumber(lua_state, index));
        },
        .float => {
            if (c.lua_isnumber(lua_state, index) == 0) return error.ExpectedLuaNumber;
            return @floatCast(c.lua_tonumber(lua_state, index));
        },
        .pointer => |info| {
            if (info.size != .slice or info.child != u8) @compileError("unsupported Lua pointer field: " ++ @typeName(T));
            return try stringFromStack(lua_state, index);
        },
        else => @compileError("unsupported Lua value type: " ++ @typeName(T)),
    }
}

fn decodeBoxShadow(lua_state: *c.lua_State, index: c_int, allocator: std.mem.Allocator) !keywork.BoxShadow {
    const table = absoluteIndex(lua_state, index);
    if (c.lua_type(lua_state, table) != c.LUA_TTABLE) return error.ExpectedLuaTable;
    const length: usize = @intCast(c.lua_objlen(lua_state, table));
    if (length > keywork.BoxShadow.max_layers) return error.TooManyShadowLayers;
    var result: keywork.BoxShadow = .{};
    for (1..length + 1) |i| {
        c.lua_rawgeti(lua_state, table, @intCast(i));
        const layer = decode(keywork.ShadowLayer, lua_state, -1, allocator) catch |err| {
            pop(lua_state, 1);
            return err;
        };
        pop(lua_state, 1);
        try result.append(layer);
    }
    return result;
}

pub fn decodeColor(lua_state: *c.lua_State, index: c_int) !keywork.Color {
    if (c.lua_isnumber(lua_state, index) == 0) return error.ExpectedLuaNumber;
    const value = c.lua_tonumber(lua_state, index);
    if (value < 0 or value > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.InvalidLuaColor;
    return @bitCast(@as(u32, @intFromFloat(value)));
}

fn decodeInsets(lua_state: *c.lua_State, index: c_int, allocator: std.mem.Allocator) !keywork.EdgeInsets {
    if (c.lua_isnumber(lua_state, index) != 0) return keywork.EdgeInsets.all(@floatCast(c.lua_tonumber(lua_state, index)));
    if (c.lua_type(lua_state, index) != c.LUA_TTABLE) return error.ExpectedLuaTable;

    const Options = struct {
        all: f32 = 0,
        x: ?f32 = null,
        y: ?f32 = null,
        left: ?f32 = null,
        top: ?f32 = null,
        right: ?f32 = null,
        bottom: ?f32 = null,
    };
    const options = try decode(Options, lua_state, index, allocator);
    const x = options.x orelse options.all;
    const y = options.y orelse options.all;
    return .{
        .left = options.left orelse x,
        .top = options.top orelse y,
        .right = options.right orelse x,
        .bottom = options.bottom orelse y,
    };
}

test "box shadow decoding owns bounded normalized layers" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);
    try std.testing.expectEqual(@as(c_int, 0), c.luaL_loadstring(lua_state,
        \\return {
        \\  { color = 0x26000000, offset_x = 2, offset_y = 3, blur = 12, spread = -4 },
        \\  { color = 0x0d000000, blur = -1 },
        \\}
    ));
    try std.testing.expectEqual(@as(c_int, 0), c.lua_pcall(lua_state, 0, 1, 0));
    const shadow = try decodeBoxShadow(lua_state, -1, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), shadow.count);
    try std.testing.expectEqual(@as(f32, 12), shadow.layers[0].blur);
    try std.testing.expectEqual(@as(f32, -4), shadow.layers[0].spread);
    try std.testing.expectEqual(@as(f32, 0), shadow.layers[1].blur);
}

test "box shadow decoding rejects excess layers" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);
    try std.testing.expectEqual(@as(c_int, 0), c.luaL_loadstring(lua_state, "return {{},{},{},{},{},{},{}}"));
    try std.testing.expectEqual(@as(c_int, 0), c.lua_pcall(lua_state, 0, 1, 0));
    try std.testing.expectError(error.TooManyShadowLayers, decodeBoxShadow(lua_state, -1, std.testing.allocator));
}

const stringFromStack = lua_value.stringFromStack;
const absoluteIndex = lua_value.absoluteIndex;
const pop = lua_value.pop;
