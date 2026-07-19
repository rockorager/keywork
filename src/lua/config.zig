//! Lua keywork.app root configuration parsing.

const std = @import("std");
const app_options = @import("../app/options.zig");
const wayland_options = @import("../backend/wayland/options.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const pop = lua_value.pop;

pub const Config = struct {
    app_id: ?[:0]u8 = null,
    title: ?[:0]u8 = null,
    backend: ?app_options.BackendKind = null,
    width: ?f32 = null,
    height: ?f32 = null,
    /// Preferred toplevel decoration policy; null means the runner's
    /// default (server-side).
    decorations: ?wayland_options.Decorations = null,
    layer_shell: ?wayland_options.LayerShellOptions = null,
    /// Ask the compositor to blur content behind the full window surface.
    background_blur: bool = false,
    /// Request ext-session-lock and make every declared window a lock
    /// surface. Each window must name an output.
    session_lock: bool = false,
    /// The script declares its window set via a `windows` function, so
    /// it needs a windowing backend even without app-level layer_shell.
    has_windows: bool = false,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.app_id) |value| allocator.free(value);
        if (self.title) |value| allocator.free(value);
        self.* = .{};
    }
};

pub fn parseRoot(lua_state: *c.lua_State, allocator: std.mem.Allocator, table_index: c_int) !Config {
    var config: Config = .{};
    const root_type = (try checkStringField(lua_state, table_index, "type")) orelse
        return invalidAppRoot("script must return keywork.app(...) as its root", .{});
    if (!std.mem.eql(u8, root_type, "app")) return invalidAppRoot("script root must be an app, got '{s}'", .{root_type});

    if (try checkStringField(lua_state, table_index, "backend")) |name| {
        config.backend = backendFromName(name) orelse
            return invalidAppRoot("unknown backend '{s}' (expected cpu, vulkan, or log)", .{name});
    }
    if (try checkNumberField(lua_state, table_index, "width")) |value| config.width = @floatCast(value);
    if (try checkNumberField(lua_state, table_index, "height")) |value| config.height = @floatCast(value);
    config.background_blur = try checkBoolField(lua_state, table_index, "background_blur");
    config.session_lock = try checkBoolField(lua_state, table_index, "session_lock");
    if (try checkStringField(lua_state, table_index, "decorations")) |name| {
        config.decorations = if (std.mem.eql(u8, name, "server"))
            .server
        else if (std.mem.eql(u8, name, "client"))
            .client
        else
            return invalidAppRoot("unknown decorations '{s}' (expected server or client)", .{name});
    }

    c.lua_getfield(lua_state, table_index, "layer_shell");
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TTABLE => config.layer_shell = try parseLayerShellTable(lua_state, c.lua_gettop(lua_state)),
        else => return invalidAppRoot("app option 'layer_shell' must be a table", .{}),
    }
    pop(lua_state, 1);

    c.lua_getfield(lua_state, table_index, "child");
    const child_is_widget = c.lua_type(lua_state, -1) == c.LUA_TTABLE and isWidgetTable(lua_state, c.lua_gettop(lua_state));
    pop(lua_state, 1);
    c.lua_getfield(lua_state, table_index, "windows");
    config.has_windows = c.lua_type(lua_state, -1) == c.LUA_TFUNCTION;
    pop(lua_state, 1);
    if (!child_is_widget and !config.has_windows) return invalidAppRoot("keywork.app requires a widget child or a windows function", .{});

    const app_id = try checkStringField(lua_state, table_index, "app_id");
    const title = try checkStringField(lua_state, table_index, "title");
    if (app_id) |value| config.app_id = allocator.dupeZ(u8, value) catch return error.OutOfMemory;
    if (title) |value| {
        config.title = allocator.dupeZ(u8, value) catch {
            config.deinit(allocator);
            return error.OutOfMemory;
        };
    }
    return config;
}

pub fn parseLayerShellTable(lua_state: *c.lua_State, table_index: c_int) !wayland_options.LayerShellOptions {
    var options: wayland_options.LayerShellOptions = .{};

    if (try checkStringField(lua_state, table_index, "layer")) |name| {
        options.layer = if (std.mem.eql(u8, name, "background"))
            .background
        else if (std.mem.eql(u8, name, "bottom"))
            .bottom
        else if (std.mem.eql(u8, name, "top"))
            .top
        else if (std.mem.eql(u8, name, "overlay"))
            .overlay
        else
            return invalidAppRoot("unknown layer '{s}' (expected background, bottom, top, or overlay)", .{name});
    }

    c.lua_getfield(lua_state, table_index, "anchor");
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TTABLE => {
            const anchor_table = c.lua_gettop(lua_state);
            const count: usize = @intCast(c.lua_objlen(lua_state, anchor_table));
            var index: usize = 1;
            while (index <= count) : (index += 1) {
                c.lua_rawgeti(lua_state, anchor_table, @intCast(index));
                if (c.lua_type(lua_state, -1) != c.LUA_TSTRING) return invalidAppRoot("anchor entries must be strings", .{});
                var len: usize = 0;
                const ptr = c.lua_tolstring(lua_state, -1, &len).?;
                const name = ptr[0..len];
                if (std.mem.eql(u8, name, "top")) {
                    options.anchors.top = true;
                } else if (std.mem.eql(u8, name, "bottom")) {
                    options.anchors.bottom = true;
                } else if (std.mem.eql(u8, name, "left")) {
                    options.anchors.left = true;
                } else if (std.mem.eql(u8, name, "right")) {
                    options.anchors.right = true;
                } else return invalidAppRoot("unknown anchor '{s}' (expected top, bottom, left, or right)", .{name});
                pop(lua_state, 1);
            }
        },
        else => return invalidAppRoot("layer_shell.anchor must be an array of strings", .{}),
    }
    pop(lua_state, 1);

    if (try checkI32Field(lua_state, table_index, "exclusive_zone")) |value| options.exclusive_zone = value;

    c.lua_getfield(lua_state, table_index, "margin");
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TTABLE => {
            const margin_table = c.lua_gettop(lua_state);
            if (try checkI32Field(lua_state, margin_table, "top")) |value| options.margin.top = value;
            if (try checkI32Field(lua_state, margin_table, "right")) |value| options.margin.right = value;
            if (try checkI32Field(lua_state, margin_table, "bottom")) |value| options.margin.bottom = value;
            if (try checkI32Field(lua_state, margin_table, "left")) |value| options.margin.left = value;
        },
        else => return invalidAppRoot("layer_shell.margin must be a table", .{}),
    }
    pop(lua_state, 1);

    if (try checkStringField(lua_state, table_index, "keyboard")) |name| {
        options.keyboard_interactivity = if (std.mem.eql(u8, name, "none"))
            .none
        else if (std.mem.eql(u8, name, "exclusive"))
            .exclusive
        else if (std.mem.eql(u8, name, "on-demand") or std.mem.eql(u8, name, "on_demand"))
            .on_demand
        else
            return invalidAppRoot("unknown keyboard interactivity '{s}' (expected none, exclusive, or on-demand)", .{name});
    }

    if (try checkStringField(lua_state, table_index, "pointer")) |name| {
        options.pointer_interactivity = if (std.mem.eql(u8, name, "auto"))
            .auto
        else if (std.mem.eql(u8, name, "none"))
            .none
        else
            return invalidAppRoot("unknown pointer interactivity '{s}' (expected auto or none)", .{name});
    }

    return options;
}

fn checkStringField(lua_state: *c.lua_State, table_index: c_int, name: [:0]const u8) !?[]const u8 {
    c.lua_getfield(lua_state, table_index, name.ptr);
    defer pop(lua_state, 1);
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => return null,
        c.LUA_TSTRING => {},
        else => return invalidAppRoot("app option '{s}' must be a string", .{name}),
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(lua_state, -1, &len).?;
    return ptr[0..len];
}

fn checkNumberField(lua_state: *c.lua_State, table_index: c_int, name: [:0]const u8) !?f64 {
    c.lua_getfield(lua_state, table_index, name.ptr);
    defer pop(lua_state, 1);
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => return null,
        c.LUA_TNUMBER => return c.lua_tonumber(lua_state, -1),
        else => return invalidAppRoot("app option '{s}' must be a number", .{name}),
    }
}

fn checkI32Field(lua_state: *c.lua_State, table_index: c_int, name: [:0]const u8) !?i32 {
    const value = (try checkNumberField(lua_state, table_index, name)) orelse return null;
    const min: f64 = @floatFromInt(std.math.minInt(i32));
    const max: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(value) or value < min or value > max) return invalidAppRoot("app option '{s}' is out of range", .{name});
    return @intFromFloat(value);
}

fn checkBoolField(lua_state: *c.lua_State, table_index: c_int, name: [:0]const u8) !bool {
    c.lua_getfield(lua_state, table_index, name.ptr);
    defer pop(lua_state, 1);
    return switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => false,
        c.LUA_TBOOLEAN => c.lua_toboolean(lua_state, -1) != 0,
        else => invalidAppRoot("app option '{s}' must be a boolean", .{name}),
    };
}

fn backendFromName(name: []const u8) ?app_options.BackendKind {
    if (std.mem.eql(u8, name, "cpu")) return .wayland_shm;
    if (std.mem.eql(u8, name, "vulkan")) return .vulkan;
    if (std.mem.eql(u8, name, "log")) return .log;
    return null;
}

fn isWidgetTable(lua_state: *c.lua_State, table: c_int) bool {
    c.lua_getfield(lua_state, table, "type");
    defer pop(lua_state, 1);
    return !c.lua_isnil(lua_state, -1);
}

fn invalidAppRoot(comptime format: []const u8, args: anytype) error{InvalidAppRoot} {
    std.log.scoped(.keywork_luajit).warn(format, args);
    return error.InvalidAppRoot;
}
