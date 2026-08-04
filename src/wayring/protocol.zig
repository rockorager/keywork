//! Owned model and parser for Wayland protocol XML schemas.

const std = @import("std");

pub const ArgumentType = enum { int, uint, fixed, string, object, new_id, array, fd };

pub const Argument = struct {
    name: []const u8,
    type: ArgumentType,
    interface: ?[]const u8 = null,
    enum_name: ?[]const u8 = null,
    allow_null: bool = false,
};

pub const Message = struct {
    name: []const u8,
    since: u32 = 1,
    deprecated_since: ?u32 = null,
    destructor: bool = false,
    arguments: []const Argument,
};

pub const EnumEntry = struct {
    name: []const u8,
    value: i64,
    since: u32 = 1,
    deprecated_since: ?u32 = null,
};

pub const Enum = struct {
    name: []const u8,
    since: u32 = 1,
    bitfield: bool = false,
    entries: []const EnumEntry,
};

pub const Interface = struct {
    name: []const u8,
    version: u32,
    requests: []const Message,
    events: []const Message,
    enums: []const Enum,
};

pub const Protocol = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    interfaces: []const Interface,

    pub fn deinit(self: *Protocol) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParseError = error{
    InvalidXml,
    UnexpectedEndOfInput,
    MismatchedCloseTag,
    MultipleRoots,
    MissingRequiredAttribute,
    DuplicateAttribute,
    InvalidNumber,
    InvalidBoolean,
    InvalidArgumentType,
    InvalidMessageType,
    InvalidNesting,
    UnknownEntity,
} || std.mem.Allocator.Error;

const Attribute = struct { name: []const u8, value: []const u8 };
const Node = struct { name: []const u8, attributes: []const Attribute, children: []const Node };

/// Parses one complete XML document. All returned slices remain valid until
/// `Protocol.deinit`; the input may be released immediately after return.
pub fn parse(allocator: std.mem.Allocator, xml: []const u8) ParseError!Protocol {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parser: Parser = .{ .input = xml, .allocator = arena.allocator() };
    parser.skipMisc() catch |err| return err;
    if (parser.index == xml.len) return error.UnexpectedEndOfInput;
    const root = try parser.element();
    try parser.skipMisc();
    if (parser.index != xml.len) return error.MultipleRoots;
    if (!std.mem.eql(u8, root.name, "protocol")) return error.InvalidNesting;
    const name = try required(&root, "name");

    var interfaces: std.ArrayList(Interface) = .empty;
    for (root.children) |child| {
        if (isIgnored(child.name)) continue;
        if (!std.mem.eql(u8, child.name, "interface")) return error.InvalidNesting;
        try interfaces.append(arena.allocator(), try parseInterface(arena.allocator(), &child));
    }
    return .{ .arena = arena, .name = name, .interfaces = try interfaces.toOwnedSlice(arena.allocator()) };
}

fn parseInterface(allocator: std.mem.Allocator, node: *const Node) ParseError!Interface {
    var requests: std.ArrayList(Message) = .empty;
    var events: std.ArrayList(Message) = .empty;
    var enums: std.ArrayList(Enum) = .empty;
    for (node.children) |*child| {
        if (isIgnored(child.name)) continue;
        if (std.mem.eql(u8, child.name, "request")) {
            try requests.append(allocator, try parseMessage(allocator, child));
        } else if (std.mem.eql(u8, child.name, "event")) {
            try events.append(allocator, try parseMessage(allocator, child));
        } else if (std.mem.eql(u8, child.name, "enum")) {
            try enums.append(allocator, try parseEnum(allocator, child));
        } else return error.InvalidNesting;
    }
    return .{
        .name = try required(node, "name"),
        .version = try number(u32, try required(node, "version")),
        .requests = try requests.toOwnedSlice(allocator),
        .events = try events.toOwnedSlice(allocator),
        .enums = try enums.toOwnedSlice(allocator),
    };
}

fn parseMessage(allocator: std.mem.Allocator, node: *const Node) ParseError!Message {
    var arguments: std.ArrayList(Argument) = .empty;
    for (node.children) |*child| {
        if (isIgnored(child.name)) continue;
        if (!std.mem.eql(u8, child.name, "arg")) return error.InvalidNesting;
        try arguments.append(allocator, try parseArgument(child));
    }
    const message_type = optional(node, "type");
    if (message_type) |kind| if (!std.mem.eql(u8, kind, "destructor")) return error.InvalidMessageType;
    return .{
        .name = try required(node, "name"),
        .since = try optionalNumber(u32, node, "since", 1),
        .deprecated_since = try nullableNumber(u32, node, "deprecated-since"),
        .destructor = message_type != null,
        .arguments = try arguments.toOwnedSlice(allocator),
    };
}

fn parseArgument(node: *const Node) ParseError!Argument {
    if (hasSemanticChildren(node)) return error.InvalidNesting;
    return .{
        .name = try required(node, "name"),
        .type = std.meta.stringToEnum(ArgumentType, try required(node, "type")) orelse return error.InvalidArgumentType,
        .interface = optional(node, "interface"),
        .enum_name = optional(node, "enum"),
        .allow_null = try optionalBool(node, "allow-null", false),
    };
}

fn parseEnum(allocator: std.mem.Allocator, node: *const Node) ParseError!Enum {
    var entries: std.ArrayList(EnumEntry) = .empty;
    for (node.children) |*child| {
        if (isIgnored(child.name)) continue;
        if (!std.mem.eql(u8, child.name, "entry") or hasSemanticChildren(child)) return error.InvalidNesting;
        try entries.append(allocator, .{
            .name = try required(child, "name"),
            .value = try number(i64, try required(child, "value")),
            .since = try optionalNumber(u32, child, "since", 1),
            .deprecated_since = try nullableNumber(u32, child, "deprecated-since"),
        });
    }
    return .{
        .name = try required(node, "name"),
        .since = try optionalNumber(u32, node, "since", 1),
        .bitfield = try optionalBool(node, "bitfield", false),
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn isIgnored(name: []const u8) bool {
    return std.mem.eql(u8, name, "description") or std.mem.eql(u8, name, "copyright");
}

fn hasSemanticChildren(node: *const Node) bool {
    for (node.children) |child| if (!isIgnored(child.name)) return true;
    return false;
}

fn required(node: *const Node, name: []const u8) ParseError![]const u8 {
    return optional(node, name) orelse error.MissingRequiredAttribute;
}

fn optional(node: *const Node, name: []const u8) ?[]const u8 {
    for (node.attributes) |attribute| if (std.mem.eql(u8, attribute.name, name)) return attribute.value;
    return null;
}

fn number(comptime T: type, value: []const u8) ParseError!T {
    return std.fmt.parseInt(T, value, 0) catch error.InvalidNumber;
}

fn optionalNumber(comptime T: type, node: *const Node, name: []const u8, default: T) ParseError!T {
    return if (optional(node, name)) |value| try number(T, value) else default;
}

fn nullableNumber(comptime T: type, node: *const Node, name: []const u8) ParseError!?T {
    return if (optional(node, name)) |value| try number(T, value) else null;
}

fn optionalBool(node: *const Node, name: []const u8, default: bool) ParseError!bool {
    const value = optional(node, name) orelse return default;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}

const Parser = struct {
    input: []const u8,
    index: usize = 0,
    allocator: std.mem.Allocator,

    fn skipMisc(self: *Parser) ParseError!void {
        while (true) {
            self.skipWhitespace();
            if (self.starts("<!--")) try self.skipComment() else if (self.starts("<?")) try self.skipProcessingInstruction() else return;
        }
    }

    fn element(self: *Parser) ParseError!Node {
        if (!self.consume("<") or self.starts("/") or self.starts("!") or self.starts("?")) return error.InvalidXml;
        const element_name = try self.name();
        var attributes: std.ArrayList(Attribute) = .empty;
        var children: std.ArrayList(Node) = .empty;
        while (true) {
            self.skipWhitespace();
            if (self.consume("/>")) return .{ .name = element_name, .attributes = try attributes.toOwnedSlice(self.allocator), .children = &.{} };
            if (self.consume(">")) break;
            const attr_name = try self.name();
            for (attributes.items) |attribute| if (std.mem.eql(u8, attribute.name, attr_name)) return error.DuplicateAttribute;
            self.skipWhitespace();
            if (!self.consume("=")) return error.InvalidXml;
            self.skipWhitespace();
            try attributes.append(self.allocator, .{ .name = attr_name, .value = try self.attributeValue() });
        }
        while (true) {
            self.skipWhitespace();
            if (self.consume("</")) {
                const close_name = try self.name();
                self.skipWhitespace();
                if (!self.consume(">")) return error.InvalidXml;
                if (!std.mem.eql(u8, element_name, close_name)) return error.MismatchedCloseTag;
                break;
            }
            if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
            if (self.starts("<!--")) {
                try self.skipComment();
                continue;
            }
            if (self.starts("<")) try children.append(self.allocator, try self.element()) else try self.skipText();
        }
        return .{ .name = element_name, .attributes = try attributes.toOwnedSlice(self.allocator), .children = try children.toOwnedSlice(self.allocator) };
    }

    fn name(self: *Parser) ParseError![]const u8 {
        const start = self.index;
        while (self.index < self.input.len and isNameChar(self.input[self.index])) self.index += 1;
        if (start == self.index) return error.InvalidXml;
        return try self.allocator.dupe(u8, self.input[start..self.index]);
    }

    fn attributeValue(self: *Parser) ParseError![]const u8 {
        if (self.index >= self.input.len or (self.input[self.index] != '\'' and self.input[self.index] != '"')) return error.InvalidXml;
        const quote = self.input[self.index];
        self.index += 1;
        var result: std.ArrayList(u8) = .empty;
        while (self.index < self.input.len and self.input[self.index] != quote) {
            if (self.input[self.index] == '&') {
                self.index += 1;
                const end = std.mem.indexOfScalarPos(u8, self.input, self.index, ';') orelse return error.InvalidXml;
                const entity = self.input[self.index..end];
                const decoded: u8 = if (std.mem.eql(u8, entity, "amp")) '&' else if (std.mem.eql(u8, entity, "lt")) '<' else if (std.mem.eql(u8, entity, "gt")) '>' else if (std.mem.eql(u8, entity, "quot")) '"' else if (std.mem.eql(u8, entity, "apos")) '\'' else return error.UnknownEntity;
                try result.append(self.allocator, decoded);
                self.index = end + 1;
            } else {
                try result.append(self.allocator, self.input[self.index]);
                self.index += 1;
            }
        }
        if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
        self.index += 1;
        return try result.toOwnedSlice(self.allocator);
    }

    fn skipText(self: *Parser) ParseError!void {
        while (self.index < self.input.len and self.input[self.index] != '<') self.index += 1;
        if (self.index == self.input.len) return error.UnexpectedEndOfInput;
    }
    fn skipComment(self: *Parser) ParseError!void {
        if (!self.consume("<!--")) return error.InvalidXml;
        const end = std.mem.indexOfPos(u8, self.input, self.index, "-->") orelse return error.UnexpectedEndOfInput;
        self.index = end + 3;
    }
    fn skipProcessingInstruction(self: *Parser) ParseError!void {
        if (!self.consume("<?")) return error.InvalidXml;
        const end = std.mem.indexOfPos(u8, self.input, self.index, "?>") orelse return error.UnexpectedEndOfInput;
        self.index = end + 2;
    }
    fn skipWhitespace(self: *Parser) void {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) self.index += 1;
    }
    fn starts(self: *Parser, text: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.index..], text);
    }
    fn consume(self: *Parser, text: []const u8) bool {
        if (!self.starts(text)) return false;
        self.index += text.len;
        return true;
    }
};

fn isNameChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '-' or char == ':' or char == '.';
}

test "parse representative Wayland schema" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!-- ordinary protocol schema -->
        \\<protocol name="demo&amp;test">
        \\  <interface name="wl_demo" version="4">
        \\    <request name="destroy" type="destructor" since="2" deprecated-since="4"/>
        \\    <request name="make"><arg name="id" type="new_id"/><arg name="typed" type="new_id" interface="wl_child"/></request>
        \\    <event name="ready"><arg name="object" type="object" interface="wl_child" allow-null="true"/><arg name="fd" type="fd"/><arg name="state" type="uint" enum="wl_child.state"/></event>
        \\    <enum name="flags" since="2" bitfield="true"><entry name="one" value="0x1" since="2" deprecated-since="3"/></enum>
        \\  </interface><interface name="wl_child" version="1"/>
        \\</protocol>
    ;
    var protocol = try parse(std.testing.allocator, xml);
    defer protocol.deinit();
    try std.testing.expectEqualStrings("demo&test", protocol.name);
    try std.testing.expectEqual(@as(usize, 2), protocol.interfaces.len);
    const interface = protocol.interfaces[0];
    try std.testing.expect(interface.requests[0].destructor);
    try std.testing.expectEqual(@as(?u32, 4), interface.requests[0].deprecated_since);
    try std.testing.expect(interface.events[0].arguments[0].allow_null);
    try std.testing.expectEqual(ArgumentType.fd, interface.events[0].arguments[1].type);
    try std.testing.expectEqualStrings("wl_child.state", interface.events[0].arguments[2].enum_name.?);
    try std.testing.expect(interface.enums[0].bitfield);
    try std.testing.expectEqual(@as(i64, 1), interface.enums[0].entries[0].value);
}

test "reject malformed and invalid schemas without leaks" {
    const cases = .{
        .{ "<protocol/>", error.MissingRequiredAttribute },
        .{ "<protocol name='x'><interface name='i' version='no'/></protocol>", error.InvalidNumber },
        .{ "<protocol name='x'><interface name='i' version='1'><event name='e'><arg name='a' type='wat'/></event></interface></protocol>", error.InvalidArgumentType },
        .{ "<protocol name='x'><interface name='i' version='1'><enum name='e' bitfield='maybe'/></interface></protocol>", error.InvalidBoolean },
        .{ "<protocol name='x'></interface>", error.MismatchedCloseTag },
        .{ "<protocol name='x'/><protocol name='y'/>", error.MultipleRoots },
        .{ "<protocol name='&bogus;'/>", error.UnknownEntity },
    };
    inline for (cases) |case| try std.testing.expectError(case[1], parse(std.testing.allocator, case[0]));
}
