//! JSON encode/decode for the keywork.json Lua module.
//!
//! Bridges std.json to Lua tables rather than binding a C JSON library:
//! the bridging is the real work either way, and std.json adds no
//! dependency. Conventions, chosen to match lua-cjson where Lua leaves
//! JSON underdetermined:
//!
//! - JSON null maps to the `json.null` sentinel (tables cannot hold nil).
//! - Decoded arrays carry a shared marker metatable, so empty arrays
//!   survive an encode round trip.
//! - An empty table without the marker encodes as {} (object). Use
//!   `json.array(t)` to force array encoding (and to produce []).
//! - decode returns nil, err for malformed input (expected runtime data);
//!   encode raises for unencodable values (programmer misuse).

const std = @import("std");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

/// Encoding this many nested tables means a cycle in practice.
const max_encode_depth = 128;

const array_metatable_key: [*:0]const u8 = "keywork.json.array";

/// The identity of json.null: a lightuserdata pointing at this byte.
var null_sentinel: u8 = 0;

/// Pushes the module table. `allocator` must outlive the Lua state.
pub fn pushModule(lua_state: *c.lua_State, allocator: *const std.mem.Allocator) void {
    c.lua_createtable(lua_state, 0, 4);
    const module = c.lua_gettop(lua_state);

    c.lua_pushlightuserdata(lua_state, @constCast(allocator));
    c.lua_pushcclosure(lua_state, luaEncode, 1);
    c.lua_setfield(lua_state, module, "encode");

    c.lua_pushlightuserdata(lua_state, @constCast(allocator));
    c.lua_pushcclosure(lua_state, luaDecode, 1);
    c.lua_setfield(lua_state, module, "decode");

    c.lua_pushcclosure(lua_state, luaArray, 0);
    c.lua_setfield(lua_state, module, "array");

    c.lua_pushlightuserdata(lua_state, &null_sentinel);
    c.lua_setfield(lua_state, module, "null");
}

fn allocatorFromUpvalue(lua_state: *c.lua_State) std.mem.Allocator {
    const ptr = c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?;
    return @as(*const std.mem.Allocator, @ptrCast(@alignCast(ptr))).*;
}

fn isNullSentinel(lua_state: *c.lua_State, index: c_int) bool {
    if (c.lua_type(lua_state, index) != c.LUA_TLIGHTUSERDATA) return false;
    return c.lua_touserdata(lua_state, index) == @as(*anyopaque, &null_sentinel);
}

fn pushArrayMetatable(lua_state: *c.lua_State) void {
    _ = c.luaL_newmetatable(lua_state, array_metatable_key);
}

fn hasArrayMark(lua_state: *c.lua_State, index: c_int) bool {
    if (c.lua_getmetatable(lua_state, index) == 0) return false;
    pushArrayMetatable(lua_state);
    const marked = c.lua_rawequal(lua_state, -1, -2) != 0;
    c.lua_settop(lua_state, -3);
    return marked;
}

// --- encode ---------------------------------------------------------------

const EncodeError = error{
    Unencodable,
    NonFiniteNumber,
    TooDeep,
    NonStringKey,
    StackOverflow,
    OutOfMemory,
    WriteFailed,
};

fn encodeErrorMessage(err: EncodeError) [*:0]const u8 {
    return switch (err) {
        error.Unencodable => "cannot encode this value type",
        error.NonFiniteNumber => "cannot encode nan or infinity",
        error.TooDeep => "table nesting too deep (reference cycle?)",
        error.NonStringKey => "table is not a sequence and has non-string keys",
        error.StackOverflow => "value too deeply nested",
        error.OutOfMemory => "out of memory",
        error.WriteFailed => "out of memory",
    };
}

fn luaEncode(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checkany(lua_state, 1);
    const allocator = allocatorFromUpvalue(lua_state);

    var out: std.Io.Writer.Allocating = .init(allocator);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    encodeValue(lua_state, 1, &jw, 0) catch |err| {
        // luaL_error longjmps past Zig defers, so release explicitly first.
        out.deinit();
        return c.luaL_error(lua_state, encodeErrorMessage(err));
    };

    const text = out.written();
    c.lua_pushlstring(lua_state, text.ptr, text.len);
    out.deinit();
    return 1;
}

fn encodeValue(lua_state: *c.lua_State, index: c_int, jw: *std.json.Stringify, depth: usize) EncodeError!void {
    switch (c.lua_type(lua_state, index)) {
        c.LUA_TNIL => try jw.write(null),
        c.LUA_TBOOLEAN => try jw.write(c.lua_toboolean(lua_state, index) != 0),
        c.LUA_TNUMBER => try encodeNumber(jw, c.lua_tonumber(lua_state, index)),
        c.LUA_TSTRING => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(lua_state, index, &len).?;
            try jw.write(ptr[0..len]);
        },
        c.LUA_TLIGHTUSERDATA => {
            if (!isNullSentinel(lua_state, index)) return error.Unencodable;
            try jw.write(null);
        },
        c.LUA_TTABLE => try encodeTable(lua_state, index, jw, depth),
        else => return error.Unencodable,
    }
}

/// Integral doubles inside the f64-precise range encode without a
/// fractional part, so counters and ids round-trip as JSON integers.
fn encodeNumber(jw: *std.json.Stringify, number: f64) EncodeError!void {
    if (!std.math.isFinite(number)) return error.NonFiniteNumber;
    const max_precise_int = @as(f64, @floatFromInt(@as(i64, 1) << 53));
    if (@floor(number) == number and @abs(number) <= max_precise_int) {
        try jw.write(@as(i64, @intFromFloat(number)));
    } else {
        try jw.write(number);
    }
}

fn encodeTable(lua_state: *c.lua_State, index: c_int, jw: *std.json.Stringify, depth: usize) EncodeError!void {
    if (depth >= max_encode_depth) return error.TooDeep;
    if (c.lua_checkstack(lua_state, 8) == 0) return error.StackOverflow;
    const table = absoluteIndex(lua_state, index);

    if (hasArrayMark(lua_state, table)) return encodeArray(lua_state, table, jw, depth);

    // One classification pass: a table whose keys are exactly the integers
    // 1..n is a sequence; anything else must have only string keys.
    var count: usize = 0;
    var integer_keys: usize = 0;
    var max_key: usize = 0;
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, table) != 0) {
        c.lua_settop(lua_state, -2); // classification only needs the key
        count += 1;
        if (integerKey(lua_state, -1)) |key| {
            integer_keys += 1;
            max_key = @max(max_key, key);
        }
    }
    if (count == 0) {
        try jw.beginObject();
        try jw.endObject();
        return;
    }
    if (integer_keys == count and max_key == count) return encodeArray(lua_state, table, jw, depth);

    try jw.beginObject();
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, table) != 0) {
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING) {
            c.lua_settop(lua_state, -3);
            return error.NonStringKey;
        }
        var key_len: usize = 0;
        const key_ptr = c.lua_tolstring(lua_state, -2, &key_len).?;
        try jw.objectField(key_ptr[0..key_len]);
        errdefer c.lua_settop(lua_state, -3);
        try encodeValue(lua_state, -1, jw, depth + 1);
        c.lua_settop(lua_state, -2);
    }
    try jw.endObject();
}

/// Emits 1..#t as a JSON array. For marked arrays holes encode as null;
/// unmarked tables only reach this with a fully validated sequence.
fn encodeArray(lua_state: *c.lua_State, table: c_int, jw: *std.json.Stringify, depth: usize) EncodeError!void {
    const length: usize = @intCast(c.lua_objlen(lua_state, table));
    try jw.beginArray();
    var i: usize = 1;
    while (i <= length) : (i += 1) {
        c.lua_rawgeti(lua_state, table, @intCast(i));
        errdefer c.lua_settop(lua_state, -2);
        try encodeValue(lua_state, -1, jw, depth + 1);
        c.lua_settop(lua_state, -2);
    }
    try jw.endArray();
}

/// The key at `index` as a positive sequence index, if it is one.
fn integerKey(lua_state: *c.lua_State, index: c_int) ?usize {
    if (c.lua_type(lua_state, index) != c.LUA_TNUMBER) return null;
    const number = c.lua_tonumber(lua_state, index);
    if (@floor(number) != number or number < 1 or number > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
    return @intFromFloat(number);
}

// --- decode ---------------------------------------------------------------

fn luaDecode(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    var len: usize = 0;
    const ptr = c.luaL_checklstring(lua_state, 1, &len).?;
    const allocator = allocatorFromUpvalue(lua_state);

    // Malformed input is expected runtime data, so decode reports nil, err.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, ptr[0..len], .{}) catch |err| {
        return lua_value.pushNilError(lua_state, err);
    };
    defer parsed.deinit();

    pushJsonValue(lua_state, parsed.value) catch {
        c.lua_pushnil(lua_state);
        c.lua_pushliteral(lua_state, "DocumentTooDeep");
        return 2;
    };
    return 1;
}

fn pushJsonValue(lua_state: *c.lua_State, value: std.json.Value) error{StackOverflow}!void {
    if (c.lua_checkstack(lua_state, 8) == 0) return error.StackOverflow;
    switch (value) {
        .null => c.lua_pushlightuserdata(lua_state, &null_sentinel),
        .bool => |v| c.lua_pushboolean(lua_state, if (v) 1 else 0),
        .integer => |v| c.lua_pushnumber(lua_state, @floatFromInt(v)),
        .float => |v| c.lua_pushnumber(lua_state, v),
        .number_string => |v| c.lua_pushnumber(lua_state, std.fmt.parseFloat(f64, v) catch std.math.nan(f64)),
        .string => |v| c.lua_pushlstring(lua_state, v.ptr, v.len),
        .array => |items| {
            c.lua_createtable(lua_state, @intCast(items.items.len), 0);
            for (items.items, 1..) |item, i| {
                try pushJsonValue(lua_state, item);
                c.lua_rawseti(lua_state, -2, @intCast(i));
            }
            pushArrayMetatable(lua_state);
            _ = c.lua_setmetatable(lua_state, -2);
        },
        .object => |map| {
            c.lua_createtable(lua_state, 0, @intCast(map.count()));
            var it = map.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                c.lua_pushlstring(lua_state, key.ptr, key.len);
                try pushJsonValue(lua_state, entry.value_ptr.*);
                c.lua_rawset(lua_state, -3);
            }
        },
    }
}

// --- json.array -----------------------------------------------------------

/// json.array(t?) marks `t` (or a fresh table) as a JSON array, so encode
/// emits [] even when it is empty or would otherwise classify as an object.
fn luaArray(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    if (c.lua_gettop(lua_state) == 0 or c.lua_type(lua_state, 1) == c.LUA_TNIL) {
        c.lua_settop(lua_state, 0);
        c.lua_createtable(lua_state, 0, 0);
    } else {
        c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
        c.lua_settop(lua_state, 1);
    }
    pushArrayMetatable(lua_state);
    _ = c.lua_setmetatable(lua_state, -2);
    return 1;
}

fn absoluteIndex(lua_state: *c.lua_State, index: c_int) c_int {
    if (index > 0 or index <= c.LUA_REGISTRYINDEX) return index;
    return c.lua_gettop(lua_state) + index + 1;
}

// --- tests ------------------------------------------------------------------

var test_allocator: std.mem.Allocator = undefined;

fn testState() !*c.lua_State {
    test_allocator = std.testing.allocator;
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    c.luaL_openlibs(lua_state);
    pushModule(lua_state, &test_allocator);
    c.lua_setglobal(lua_state, "json");
    return lua_state;
}

fn runScript(lua_state: *c.lua_State, script: [*:0]const u8) !void {
    if (c.luaL_loadstring(lua_state, script) != 0) return error.LoadFailed;
    if (c.lua_pcall(lua_state, 0, 0, 0) != 0) {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(lua_state, -1, &len);
        if (message_ptr) |message| std.debug.print("script failed: {s}\n", .{message[0..len]});
        return error.ScriptFailed;
    }
}

test "json encodes scalars, sequences, and objects" {
    const lua_state = try testState();
    defer c.lua_close(lua_state);
    try runScript(lua_state,
        \\assert(json.encode(true) == "true")
        \\assert(json.encode("hi\n") == "\"hi\\n\"")
        \\assert(json.encode(42) == "42")
        \\assert(json.encode(1.5) == "1.5")
        \\assert(json.encode(nil) == "null")
        \\assert(json.encode(json.null) == "null")
        \\assert(json.encode({1, 2, 3}) == "[1,2,3]")
        \\assert(json.encode({a = 1}) == "{\"a\":1}")
        \\assert(json.encode({{}, {x = true}}) == "[{},{\"x\":true}]")
    );
}

test "json empty tables encode as objects unless marked as arrays" {
    const lua_state = try testState();
    defer c.lua_close(lua_state);
    try runScript(lua_state,
        \\assert(json.encode({}) == "{}")
        \\assert(json.encode(json.array()) == "[]")
        \\assert(json.encode(json.array({"a"})) == "[\"a\"]")
        \\assert(json.encode({list = json.array()}) == "{\"list\":[]}")
    );
}

test "json decode maps null, arrays, and objects to Lua" {
    const lua_state = try testState();
    defer c.lua_close(lua_state);
    try runScript(lua_state,
        \\local value = json.decode('{"n":null,"list":[1,"two",false],"nested":{"k":-2.5}}')
        \\assert(value.n == json.null)
        \\assert(#value.list == 3 and value.list[2] == "two" and value.list[3] == false)
        \\assert(value.nested.k == -2.5)
        \\-- decoded arrays keep their identity through a re-encode
        \\assert(json.encode(json.decode("[]")) == "[]")
        \\assert(json.encode(json.decode('{"a":[]}')) == "{\"a\":[]}")
    );
}

test "json decode reports malformed input as nil, err" {
    const lua_state = try testState();
    defer c.lua_close(lua_state);
    try runScript(lua_state,
        \\local value, err = json.decode("{broken")
        \\assert(value == nil and type(err) == "string")
        \\local value2, err2 = json.decode("")
        \\assert(value2 == nil and type(err2) == "string")
    );
}

test "json encode raises on unencodable values" {
    const lua_state = try testState();
    defer c.lua_close(lua_state);
    try runScript(lua_state,
        \\local function fails(value, fragment)
        \\  local ok, err = pcall(json.encode, value)
        \\  assert(not ok, "expected failure")
        \\  assert(err:find(fragment, 1, true), err)
        \\end
        \\fails(print, "value type")
        \\fails(0 / 0, "nan or infinity")
        \\fails(math.huge, "nan or infinity")
        \\fails({[1] = "a", x = "b"}, "non-string keys")
        \\fails({[1] = "a", [3] = "c"}, "non-string keys")
        \\local cycle = {}
        \\cycle.self = cycle
        \\fails(cycle, "too deep")
    );
}

test "json roundtrips numbers as integers when precise" {
    const lua_state = try testState();
    defer c.lua_close(lua_state);
    try runScript(lua_state,
        \\assert(json.encode(json.decode("9007199254740992")) == "9007199254740992")
        \\assert(json.encode(-0.25) == "-0.25")
        \\assert(json.decode("3") == 3)
    );
}
