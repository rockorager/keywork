//! Parsing for Lua Storybook catalogs.

const std = @import("std");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const absoluteIndex = lua_value.absoluteIndex;
const pop = lua_value.pop;
const stringFromStack = lua_value.stringFromStack;

pub const ColorScheme = enum {
    light,
    dark,

    pub fn name(self: ColorScheme) []const u8 {
        return @tagName(self);
    }
};

pub const Story = struct {
    id: []u8,
    group: ?[]u8 = null,
    name: []u8,
    index: usize,
    width: f32 = 640,
    height: f32 = 480,
    scale: f32 = 1,
    color_scheme: ColorScheme = .light,

    pub fn deinit(self: *Story, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.group) |group| allocator.free(group);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    title: ?[]u8 = null,
    stories: []Story,

    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        for (self.stories) |*story| story.deinit(allocator);
        allocator.free(self.stories);
        self.* = undefined;
    }

    pub fn find(self: *const Catalog, id: []const u8) ?*const Story {
        for (self.stories) |*story| {
            if (std.mem.eql(u8, story.id, id)) return story;
        }
        return null;
    }
};

pub fn parseRoot(lua_state: *c.lua_State, allocator: std.mem.Allocator, table_index: c_int) !Catalog {
    const table = absoluteIndex(lua_state, table_index);
    if (c.lua_type(lua_state, table) != c.LUA_TTABLE) return error.InvalidStorybookRoot;
    const root_type = (try optionalStringField(lua_state, table, "type")) orelse return error.InvalidStorybookRoot;
    if (!std.mem.eql(u8, root_type, "storybook")) return error.InvalidStorybookRoot;

    const title_value = try optionalStringField(lua_state, table, "title");
    const title = if (title_value) |value| try allocator.dupe(u8, value) else null;
    errdefer if (title) |value| allocator.free(value);

    c.lua_getfield(lua_state, table, "stories");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.StoriesListMissing;
    const stories_table = c.lua_gettop(lua_state);
    const count: usize = @intCast(c.lua_objlen(lua_state, stories_table));

    var stories: std.ArrayList(Story) = .empty;
    errdefer {
        for (stories.items) |*story| story.deinit(allocator);
        stories.deinit(allocator);
    }
    for (1..count + 1) |index| {
        c.lua_rawgeti(lua_state, stories_table, @intCast(index));
        defer pop(lua_state, 1);
        const story = try parseStory(lua_state, allocator, c.lua_gettop(lua_state), index);
        errdefer {
            var owned = story;
            owned.deinit(allocator);
        }
        for (stories.items) |existing| {
            if (std.mem.eql(u8, existing.id, story.id)) return error.DuplicateStoryId;
        }
        try stories.append(allocator, story);
    }

    return .{
        .title = title,
        .stories = try stories.toOwnedSlice(allocator),
    };
}

fn parseStory(lua_state: *c.lua_State, allocator: std.mem.Allocator, table_index: c_int, index: usize) !Story {
    const table = absoluteIndex(lua_state, table_index);
    if (c.lua_type(lua_state, table) != c.LUA_TTABLE) return error.InvalidStory;
    const story_type = (try optionalStringField(lua_state, table, "type")) orelse return error.InvalidStory;
    if (!std.mem.eql(u8, story_type, "story")) return error.InvalidStory;

    const id_value = (try optionalStringField(lua_state, table, "id")) orelse return error.StoryIdMissing;
    if (!validId(id_value)) return error.InvalidStoryId;
    const name_value = (try optionalStringField(lua_state, table, "name")) orelse return error.StoryNameMissing;
    if (name_value.len == 0) return error.StoryNameMissing;
    const group_value = try optionalStringField(lua_state, table, "group");

    const id = try allocator.dupe(u8, id_value);
    errdefer allocator.free(id);
    const group = if (group_value) |value| try allocator.dupe(u8, value) else null;
    errdefer if (group) |value| allocator.free(value);
    const name = try allocator.dupe(u8, name_value);
    errdefer allocator.free(name);

    var story: Story = .{ .id = id, .group = group, .name = name, .index = index };
    c.lua_getfield(lua_state, table, "viewport");
    defer pop(lua_state, 1);
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TTABLE => {
            const viewport = c.lua_gettop(lua_state);
            if (try optionalNumberField(lua_state, viewport, "width")) |value| story.width = try positiveFinite(value);
            if (try optionalNumberField(lua_state, viewport, "height")) |value| story.height = try positiveFinite(value);
            if (try optionalNumberField(lua_state, viewport, "scale")) |value| story.scale = try positiveFinite(value);
        },
        else => return error.InvalidStoryViewport,
    }

    if (try optionalStringField(lua_state, table, "color_scheme")) |scheme| {
        story.color_scheme = if (std.mem.eql(u8, scheme, "light"))
            .light
        else if (std.mem.eql(u8, scheme, "dark"))
            .dark
        else
            return error.InvalidStoryColorScheme;
    }

    c.lua_getfield(lua_state, table, "render");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.StoryRenderMissing;
    return story;
}

fn optionalStringField(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) !?[]const u8 {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    return switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => null,
        c.LUA_TSTRING => try stringFromStack(lua_state, -1),
        else => error.InvalidStoryField,
    };
}

fn optionalNumberField(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8) !?f64 {
    c.lua_getfield(lua_state, table, name);
    defer pop(lua_state, 1);
    return switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => null,
        c.LUA_TNUMBER => c.lua_tonumber(lua_state, -1),
        else => error.InvalidStoryField,
    };
}

fn positiveFinite(value: f64) !f32 {
    if (!std.math.isFinite(value) or value <= 0 or value > std.math.floatMax(f32)) return error.InvalidStoryViewport;
    return @floatCast(value);
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id[0] == '/' or id[id.len - 1] == '/') return false;
    var segments = std.mem.splitScalar(u8, id, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
        }
    }
    return true;
}

test "story ids are safe relative paths" {
    try std.testing.expect(validId("button/default"));
    try std.testing.expect(validId("input/error-state_2"));
    try std.testing.expect(!validId("../escape"));
    try std.testing.expect(!validId("button//default"));
    try std.testing.expect(!validId("button/default state"));
}
