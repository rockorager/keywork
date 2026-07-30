//! Lua full-userdata binding for the native shared pixel canvas.

const std = @import("std");
const keywork = @import("keywork-ui");
const native_runtime = @import("keywork-runtime");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const userdata_type = "keywork.pixel_buffer";

pub const Host = struct {
    ptr: *anyopaque,
    allocator_fn: *const fn (*anyopaque) std.mem.Allocator,
    invalidate_fn: *const fn (*anyopaque) anyerror!void,

    fn allocator(self: Host) std.mem.Allocator {
        return self.allocator_fn(self.ptr);
    }

    fn invalidate(self: Host) !void {
        try self.invalidate_fn(self.ptr);
    }
};

const Userdata = struct {
    buffer: ?*native_runtime.SharedPixelBuffer,
    host: Host,
};

pub fn install(lua_state: *c.lua_State, keywork_table: c_int, host: *Host) void {
    ensureMetatable(lua_state);
    lua_value.pop(lua_state, 1);
    c.lua_getfield(lua_state, keywork_table, "pixel_buffer");
    std.debug.assert(c.lua_type(lua_state, -1) == c.LUA_TTABLE);
    c.lua_pushlightuserdata(lua_state, host);
    lua_value.setClosureField(lua_state, -2, "new", luaNew, 1);
    lua_value.pop(lua_state, 1);
}

pub fn parseWidget(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int) !keywork.Widget {
    c.lua_getfield(lua_state, table, "buffer");
    defer lua_value.pop(lua_state, 1);
    const resource = userdata(lua_state, -1);
    const buffer = resource.buffer orelse return error.PixelBufferClosed;

    const width = optionalNumberField(lua_state, table, "width");
    const height = optionalNumberField(lua_state, table, "height");
    if ((width == null) != (height == null)) return error.IncompleteLogicalSize;
    const logical_size: ?keywork.Size = if (width) |resolved_width| .{
        .width = @floatCast(resolved_width),
        .height = @floatCast(height.?),
    } else null;
    if (logical_size) |size| {
        if (!std.math.isFinite(size.width) or size.width <= 0 or
            !std.math.isFinite(size.height) or size.height <= 0)
        {
            return error.InvalidLogicalSize;
        }
    }
    return buffer.widget(allocator, logical_size);
}

fn luaNew(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const host = lua_value.upvaluePointer(*Host, lua_state, 1);
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
    const width = integerField(lua_state, 1, "width");
    const height = integerField(lua_state, 1, "height");
    if (width <= 0 or height <= 0 or width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) {
        return c.luaL_error(lua_state, "pixel buffer dimensions must be positive 32-bit integers");
    }
    const format = formatField(lua_state, 1) catch {
        return c.luaL_error(lua_state, "invalid pixel buffer format");
    };
    const buffer = native_runtime.SharedPixelBuffer.create(
        host.allocator(),
        @intCast(width),
        @intCast(height),
        format,
    ) catch |err| return lua_value.pushNilError(lua_state, err);

    const resource: *Userdata = @ptrCast(@alignCast(c.lua_newuserdata(lua_state, @sizeOf(Userdata)).?));
    resource.* = .{ .buffer = buffer, .host = host.* };
    ensureMetatable(lua_state);
    _ = c.lua_setmetatable(lua_state, -2);
    return 1;
}

fn luaBeginWrite(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const buffer = liveBuffer(lua_state, 1);
    const write = buffer.beginWrite() catch |err| return lua_value.pushNilError(lua_state, err);
    c.lua_pushlightuserdata(lua_state, write.pointer);
    c.lua_pushinteger(lua_state, @intCast(write.byte_len));
    c.lua_pushinteger(lua_state, @intCast(write.stride));
    return 3;
}

fn luaCommit(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const resource = userdata(lua_state, 1);
    const buffer = resource.buffer orelse return c.luaL_error(lua_state, "pixel buffer is closed");

    var damage: keywork.DamageRegion = .{};
    if (c.lua_type(lua_state, 2) == c.LUA_TNONE or c.lua_type(lua_state, 2) == c.LUA_TNIL) {
        damage.add(buffer.fullRect());
    } else {
        c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
        c.lua_getfield(lua_state, 2, "damage");
        defer lua_value.pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) == c.LUA_TNIL) {
            damage.add(buffer.fullRect());
        } else {
            c.luaL_checktype(lua_state, -1, c.LUA_TTABLE);
            const count: usize = @intCast(c.lua_objlen(lua_state, -1));
            for (0..count) |index| {
                c.lua_rawgeti(lua_state, -1, @intCast(index + 1));
                c.luaL_checktype(lua_state, -1, c.LUA_TTABLE);
                damage.add(.{
                    .x = @floatCast(numberField(lua_state, -1, "x")),
                    .y = @floatCast(numberField(lua_state, -1, "y")),
                    .width = @floatCast(numberField(lua_state, -1, "width")),
                    .height = @floatCast(numberField(lua_state, -1, "height")),
                });
                lua_value.pop(lua_state, 1);
            }
        }
    }

    const revision = buffer.commit(damage.slice()) catch |err| return lua_value.pushNilError(lua_state, err);
    resource.host.invalidate() catch |err| return lua_value.pushNilError(lua_state, err);
    c.lua_pushinteger(lua_state, @intCast(revision));
    return 1;
}

fn luaGc(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const resource = userdata(lua_state_optional.?, 1);
    if (resource.buffer) |buffer| {
        resource.buffer = null;
        // A producer abandoned between begin_write and commit has no reader;
        // make final collection safe without publishing the partial pixels.
        buffer.cancelWrite();
        buffer.release();
    }
    return 0;
}

fn ensureMetatable(lua_state: *c.lua_State) void {
    if (c.luaL_newmetatable(lua_state, userdata_type) != 0) {
        c.lua_pushcclosure(lua_state, luaGc, 0);
        c.lua_setfield(lua_state, -2, "__gc");
        c.lua_createtable(lua_state, 0, 2);
        lua_value.setClosureField(lua_state, -1, "begin_write", luaBeginWrite, 0);
        lua_value.setClosureField(lua_state, -1, "commit", luaCommit, 0);
        c.lua_setfield(lua_state, -2, "__index");
    }
}

fn userdata(lua_state: *c.lua_State, index: c_int) *Userdata {
    return @ptrCast(@alignCast(c.luaL_checkudata(lua_state, index, userdata_type).?));
}

fn liveBuffer(lua_state: *c.lua_State, index: c_int) *native_runtime.SharedPixelBuffer {
    return userdata(lua_state, index).buffer orelse {
        _ = c.luaL_error(lua_state, "pixel buffer is closed");
        unreachable;
    };
}

fn integerField(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) c.lua_Integer {
    c.lua_getfield(lua_state, table, name);
    defer lua_value.pop(lua_state, 1);
    return c.luaL_checkinteger(lua_state, -1);
}

fn numberField(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) c.lua_Number {
    c.lua_getfield(lua_state, table, name);
    defer lua_value.pop(lua_state, 1);
    return c.luaL_checknumber(lua_state, -1);
}

fn optionalNumberField(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) ?c.lua_Number {
    c.lua_getfield(lua_state, table, name);
    defer lua_value.pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) == c.LUA_TNIL) return null;
    return c.luaL_checknumber(lua_state, -1);
}

fn formatField(lua_state: *c.lua_State, table: c_int) !keywork.PixelFormat {
    c.lua_getfield(lua_state, table, "format");
    defer lua_value.pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) == c.LUA_TNIL) return .argb8888_premultiplied;
    const value = lua_value.checkString(lua_state, -1);
    if (std.mem.eql(u8, value, "argb8888_premultiplied")) return .argb8888_premultiplied;
    if (std.mem.eql(u8, value, "argb8888_straight")) return .argb8888_straight;
    if (std.mem.eql(u8, value, "xrgb8888")) return .xrgb8888;
    return error.InvalidPixelFormat;
}
