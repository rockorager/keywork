//! Walks plain Lua widget tables into typed `ui.Widget` trees.
//!
//! The application describes UI as nested tables: a `type` field selects
//! the widget kind, the array part holds row/column children, and handler
//! slots hold Lua functions. Each handler function is pinned in the Lua
//! registry with `luaL_ref`; the ref doubles as the widget's opaque
//! HandlerId, scoped to the submitted document. Strings are copied into
//! the build arena so the resulting tree never borrows Lua memory.

const std = @import("std");
const keywork = @import("keywork");
const c = @import("lua_c");

const Widget = keywork.Widget;

pub const Error = error{ OutOfMemory, InvalidWidget };

const Kind = enum {
    text,
    row,
    column,
    filled_button,
    gesture_detector,
    padding,
    center,
    spacer,
    sized_box,
    flexible,
};

pub const Builder = struct {
    state: *c.lua_State,
    /// Owns every widget node, slice, and string in the built tree.
    arena: std.mem.Allocator,
    ref_allocator: std.mem.Allocator,
    /// Registry refs pinned for handler functions during this build.
    refs: std.ArrayList(c_int) = .empty,
    /// Static description of the failure when build returns InvalidWidget.
    diagnostic: [:0]const u8 = "invalid widget table",

    /// Builds the widget table at the top of the Lua stack. The table
    /// stays on the stack; the stack is restored on failure.
    pub fn build(self: *Builder) Error!Widget {
        const top = c.lua_gettop(self.state);
        errdefer c.lua_settop(self.state, top);
        return self.buildWidget();
    }

    /// Releases every ref pinned so far. Call when the build or the
    /// subsequent submission fails.
    pub fn cancel(self: *Builder) void {
        for (self.refs.items) |ref| c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, ref);
        self.refs.deinit(self.ref_allocator);
    }

    /// Transfers ownership of the pinned refs to the caller.
    pub fn takeRefs(self: *Builder) std.mem.Allocator.Error![]c_int {
        return self.refs.toOwnedSlice(self.ref_allocator);
    }

    fn buildWidget(self: *Builder) Error!Widget {
        const L = self.state;
        if (c.lua_checkstack(L, 8) == 0) return self.fail("widget tree too deep");
        if (c.lua_type(L, -1) != c.LUA_TTABLE) return self.fail("widget must be a table");

        c.lua_getfield(L, -1, "type");
        if (c.lua_type(L, -1) != c.LUA_TSTRING) {
            c.lua_settop(L, -2);
            return self.fail("widget table requires a 'type' string");
        }
        var len: usize = 0;
        const type_name = c.lua_tolstring(L, -1, &len)[0..len];
        const kind = std.meta.stringToEnum(Kind, type_name) orelse {
            c.lua_settop(L, -2);
            return self.fail("unknown widget type");
        };
        c.lua_settop(L, -2);

        return switch (kind) {
            .text => .{ .text = .{
                .key = try self.stringField("key"),
                .value = try self.requireStringField("value"),
                .font_size = try self.numberField("font_size"),
                .role = try self.enumField(@FieldType(Widget.Text, "role"), "role", .body),
            } },
            .row => .{ .row = try self.buildChildren() },
            .column => .{ .column = try self.buildChildren() },
            .filled_button => .{ .filled_button = .{
                .key = try self.stringField("key"),
                .id = try self.requireStringField("id"),
                .handler = try self.handlerField("on_activate"),
                .child = try self.childField(),
                .activation = try self.enumField(Widget.ClickActivation, "activation", .press),
            } },
            .gesture_detector => .{ .gesture_detector = .{
                .key = try self.stringField("key"),
                .id = try self.requireStringField("id"),
                .handler = (try self.handlerField("on_activate")) orelse
                    return self.fail("gesture_detector requires 'on_activate'"),
                .child = try self.childField(),
                .activation = try self.enumField(Widget.ClickActivation, "activation", .release),
            } },
            .padding => .{ .padding = .{
                .key = try self.stringField("key"),
                .insets = try self.insetsField(),
                .child = try self.childField(),
            } },
            .center => .{ .center = .{
                .key = try self.stringField("key"),
                .child = try self.childField(),
            } },
            .spacer => .{ .spacer = .{
                .key = try self.stringField("key"),
                .flex = (try self.numberField("flex")) orelse 1,
            } },
            .sized_box => .{ .sized_box = .{
                .key = try self.stringField("key"),
                .child = try self.childField(),
                .width = try self.numberField("width"),
                .height = try self.numberField("height"),
                .min_width = (try self.numberField("min_width")) orelse 0,
                .min_height = (try self.numberField("min_height")) orelse 0,
                .max_width = try self.numberField("max_width"),
                .max_height = try self.numberField("max_height"),
            } },
            .flexible => .{ .flexible = .{
                .key = try self.stringField("key"),
                .child = try self.childField(),
                .flex = (try self.numberField("flex")) orelse 1,
                .fit = try self.enumField(Widget.FlexFit, "fit", .tight),
            } },
        };
    }

    fn buildChildren(self: *Builder) Error!Widget.Children {
        return .{
            .key = try self.stringField("key"),
            .children = try self.childrenSlice(),
            .gap = (try self.numberField("gap")) orelse 0,
            .cross_align = try self.enumField(Widget.CrossAxisAlignment, "cross_align", .start),
            .main_align = try self.enumField(Widget.MainAxisAlignment, "main_align", .start),
        };
    }

    /// Children come from the array part of the widget table.
    fn childrenSlice(self: *Builder) Error![]Widget {
        const L = self.state;
        const count = c.lua_objlen(L, -1);
        const children = try self.arena.alloc(Widget, count);
        for (children, 0..) |*slot, index| {
            c.lua_rawgeti(L, -1, @intCast(index + 1));
            slot.* = try self.buildWidget();
            c.lua_settop(L, -2);
        }
        return children;
    }

    fn childField(self: *Builder) Error!*Widget {
        const L = self.state;
        c.lua_getfield(L, -1, "child");
        if (c.lua_type(L, -1) != c.LUA_TTABLE) {
            c.lua_settop(L, -2);
            return self.fail("widget requires a 'child' table");
        }
        const child = try self.buildWidget();
        c.lua_settop(L, -2);
        return Widget.alloc(self.arena, child);
    }

    fn insetsField(self: *Builder) Error!keywork.EdgeInsets {
        const L = self.state;
        c.lua_getfield(L, -1, "insets");
        defer c.lua_settop(L, -2);
        switch (c.lua_type(L, -1)) {
            c.LUA_TNIL => return .{},
            c.LUA_TNUMBER => return .all(@floatCast(c.lua_tonumber(L, -1))),
            c.LUA_TTABLE => return .{
                .left = (try self.numberField("left")) orelse 0,
                .top = (try self.numberField("top")) orelse 0,
                .right = (try self.numberField("right")) orelse 0,
                .bottom = (try self.numberField("bottom")) orelse 0,
            },
            else => return self.fail("'insets' must be a number or a table"),
        }
    }

    /// Pins a handler function from the given field in the Lua registry
    /// and returns the ref as the widget's handler identity.
    fn handlerField(self: *Builder, comptime field: [:0]const u8) Error!?keywork.HandlerId {
        const L = self.state;
        c.lua_getfield(L, -1, field.ptr);
        switch (c.lua_type(L, -1)) {
            c.LUA_TNIL => {
                c.lua_settop(L, -2);
                return null;
            },
            c.LUA_TFUNCTION => {
                const ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
                std.debug.assert(ref > 0);
                self.refs.append(self.ref_allocator, ref) catch {
                    c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);
                    return error.OutOfMemory;
                };
                return @intCast(ref);
            },
            else => {
                c.lua_settop(L, -2);
                return self.fail("'" ++ field ++ "' must be a function");
            },
        }
    }

    fn stringField(self: *Builder, comptime field: [:0]const u8) Error!?[]const u8 {
        const L = self.state;
        c.lua_getfield(L, -1, field.ptr);
        defer c.lua_settop(L, -2);
        switch (c.lua_type(L, -1)) {
            c.LUA_TNIL => return null,
            c.LUA_TSTRING => {
                var len: usize = 0;
                const ptr = c.lua_tolstring(L, -1, &len);
                return try self.arena.dupe(u8, ptr[0..len]);
            },
            else => return self.fail("'" ++ field ++ "' must be a string"),
        }
    }

    fn requireStringField(self: *Builder, comptime field: [:0]const u8) Error![]const u8 {
        return (try self.stringField(field)) orelse
            self.fail("widget requires a '" ++ field ++ "' string");
    }

    fn numberField(self: *Builder, comptime field: [:0]const u8) Error!?f32 {
        const L = self.state;
        c.lua_getfield(L, -1, field.ptr);
        defer c.lua_settop(L, -2);
        switch (c.lua_type(L, -1)) {
            c.LUA_TNIL => return null,
            c.LUA_TNUMBER => return @floatCast(c.lua_tonumber(L, -1)),
            else => return self.fail("'" ++ field ++ "' must be a number"),
        }
    }

    fn enumField(self: *Builder, comptime E: type, comptime field: [:0]const u8, default: E) Error!E {
        const L = self.state;
        c.lua_getfield(L, -1, field.ptr);
        defer c.lua_settop(L, -2);
        switch (c.lua_type(L, -1)) {
            c.LUA_TNIL => return default,
            c.LUA_TSTRING => {
                var len: usize = 0;
                const ptr = c.lua_tolstring(L, -1, &len);
                return std.meta.stringToEnum(E, ptr[0..len]) orelse
                    self.fail("invalid value for '" ++ field ++ "'");
            },
            else => return self.fail("'" ++ field ++ "' must be a string"),
        }
    }

    fn fail(self: *Builder, comptime message: [:0]const u8) error{InvalidWidget} {
        self.diagnostic = message;
        return error.InvalidWidget;
    }
};

const Vm = @import("vm.zig");

test "walker builds a typed widget tree from lua tables" {
    var vm = try Vm.init();
    defer vm.deinit();
    try vm.runString(
        \\widget = {
        \\  type = "padding",
        \\  insets = 24,
        \\  child = {
        \\    type = "column",
        \\    gap = 12,
        \\    { type = "text", value = "hello", role = "title" },
        \\    {
        \\      type = "filled_button",
        \\      id = "go",
        \\      on_activate = function() end,
        \\      child = { type = "text", value = "Go" },
        \\    },
        \\  },
        \\}
    );
    c.lua_getfield(vm.state, c.LUA_GLOBALSINDEX, "widget");

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var builder: Builder = .{
        .state = vm.state,
        .arena = arena_state.allocator(),
        .ref_allocator = std.testing.allocator,
    };
    defer builder.cancel();

    const widget = try builder.build();
    try std.testing.expectEqual(@as(f32, 24), widget.padding.insets.left);
    const children = widget.padding.child.column;
    try std.testing.expectEqual(@as(f32, 12), children.gap);
    try std.testing.expectEqual(@as(usize, 2), children.children.len);
    try std.testing.expectEqualStrings("hello", children.children[0].text.value);
    try std.testing.expectEqual(.title, children.children[0].text.role);
    const button = children.children[1].filled_button;
    try std.testing.expectEqualStrings("go", button.id);
    try std.testing.expectEqualStrings("Go", button.child.text.value);

    // The pinned handler resolves back to the Lua function.
    try std.testing.expectEqual(@as(usize, 1), builder.refs.items.len);
    c.lua_rawgeti(vm.state, c.LUA_REGISTRYINDEX, @intCast(button.handler.?));
    try std.testing.expectEqual(c.LUA_TFUNCTION, c.lua_type(vm.state, -1));
    c.lua_settop(vm.state, 0);
}

test "walker rejects malformed widgets with a diagnostic" {
    var vm = try Vm.init();
    defer vm.deinit();
    try vm.runString("widget = { type = 'text' }");
    c.lua_getfield(vm.state, c.LUA_GLOBALSINDEX, "widget");

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var builder: Builder = .{
        .state = vm.state,
        .arena = arena_state.allocator(),
        .ref_allocator = std.testing.allocator,
    };
    defer builder.cancel();

    try std.testing.expectError(error.InvalidWidget, builder.build());
    try std.testing.expectEqualStrings("widget requires a 'value' string", builder.diagnostic);
    c.lua_settop(vm.state, 0);
}
