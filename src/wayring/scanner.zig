//! Wayland XML to Wayring descriptor generator.

const std = @import("std");
const xml = @import("xml");

const Allocator = std.mem.Allocator;

const Attr = struct { name: []const u8, value: []const u8 };
const Node = struct {
    name: []const u8,
    attrs: std.ArrayList(Attr) = .empty,
    children: std.ArrayList(*Node) = .empty,
};

pub const Arg = struct {
    name: []const u8,
    kind: []const u8,
    nullable: bool,
    interface_name: ?[]const u8,
    enum_name: ?[]const u8,
};
pub const Message = struct {
    name: []const u8,
    since: u32,
    destructor: bool,
    args: []const Arg,
};
pub const Entry = struct { name: []const u8, value: u32, since: u32 };
pub const Enum = struct { name: []const u8, bitfield: bool, since: u32, entries: []const Entry };
pub const Interface = struct {
    name: []const u8,
    version: u32,
    requests: []const Message,
    events: []const Message,
    enums: []const Enum,
};
pub const ProtocolSet = struct { interfaces: []const Interface };

fn attr(node: *const Node, name: []const u8) ?[]const u8 {
    for (node.attrs.items) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
    return null;
}

fn parseDocument(gpa: Allocator, arena: Allocator, bytes: []const u8) !*Node {
    var parser = xml.Parser.init(bytes);
    var stack: std.ArrayList(*Node) = .empty;
    defer stack.deinit(gpa);
    var root: ?*Node = null;
    while (parser.next()) |event| switch (event) {
        .open_tag => |name| {
            const node = try arena.create(Node);
            node.* = .{ .name = try arena.dupe(u8, name) };
            if (stack.items.len > 0) try stack.items[stack.items.len - 1].children.append(arena, node) else {
                if (root != null) return error.MultipleRoots;
                root = node;
            }
            try stack.append(gpa, node);
        },
        .attribute => |a| {
            if (stack.items.len == 0) return error.AttributeOutsideElement;
            const node = stack.items[stack.items.len - 1];
            const name = try arena.dupe(u8, a.name);
            if (attr(node, name) != null) return error.DuplicateAttribute;
            try node.attrs.append(arena, .{ .name = name, .value = try a.dupeValue(arena) });
        },
        .close_tag => |name| {
            if (stack.items.len == 0) return error.MalformedNesting;
            const node = stack.pop().?;
            if (!std.mem.eql(u8, node.name, name)) return error.MalformedNesting;
        },
        // Semantic parsing below accepts children only in their legal parents;
        // text belongs to description/copyright elements and is intentionally ignored.
        .character_data => {},
        .comment, .processing_instruction => {},
    };
    if (stack.items.len != 0 or std.mem.trim(u8, parser.document, " \t\r\n").len != 0) return error.MalformedXml;
    return root orelse error.MissingProtocol;
}

fn required(node: *const Node, name: []const u8) ![]const u8 {
    return attr(node, name) orelse error.MissingAttribute;
}
fn uintAttr(node: *const Node, name: []const u8, default: ?u32) !u32 {
    const text = attr(node, name) orelse return default orelse error.MissingAttribute;
    const value = std.fmt.parseInt(u32, text, 10) catch return error.InvalidInteger;
    if (value == 0) return error.InvalidVersion;
    return value;
}
fn boolAttr(node: *const Node, name: []const u8, default: bool) !bool {
    const text = attr(node, name) orelse return default;
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return error.InvalidBoolean;
}

fn parseValue(text: []const u8) !u32 {
    if (std.mem.indexOf(u8, text, "<<")) |at| {
        if (std.mem.indexOfPos(u8, text, at + 2, "<<") != null) return error.InvalidEnumValue;
        const lhs = std.mem.trim(u8, text[0..at], " \t");
        const rhs = std.mem.trim(u8, text[at + 2 ..], " \t");
        const base = std.fmt.parseInt(u32, lhs, 0) catch return error.InvalidEnumValue;
        const shift = std.fmt.parseInt(u5, rhs, 0) catch return error.InvalidEnumValue;
        return std.math.shl(u32, base, shift);
    }
    return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \t"), 0) catch error.InvalidEnumValue;
}

fn parseMessage(arena: Allocator, node: *const Node, interface_version: u32) !Message {
    const since = try uintAttr(node, "since", 1);
    if (since > interface_version) return error.MessageVersionTooNew;
    const type_name = attr(node, "type");
    const destructor = if (type_name) |t| if (std.mem.eql(u8, t, "destructor")) true else return error.InvalidMessageType else false;
    var args: std.ArrayList(Arg) = .empty;
    for (node.children.items) |child| {
        if (std.mem.eql(u8, child.name, "description")) continue;
        if (!std.mem.eql(u8, child.name, "arg")) return error.MalformedNesting;
        const kind = try required(child, "type");
        const valid = std.mem.eql(u8, kind, "int") or std.mem.eql(u8, kind, "uint") or std.mem.eql(u8, kind, "fixed") or
            std.mem.eql(u8, kind, "string") or std.mem.eql(u8, kind, "object") or std.mem.eql(u8, kind, "new_id") or
            std.mem.eql(u8, kind, "array") or std.mem.eql(u8, kind, "fd");
        if (!valid) return error.InvalidArgumentType;
        const nullable = try boolAttr(child, "allow-null", false);
        if (nullable and !(std.mem.eql(u8, kind, "string") or std.mem.eql(u8, kind, "object") or std.mem.eql(u8, kind, "array"))) return error.InvalidNullability;
        const interface_name = attr(child, "interface");
        if (interface_name != null and !(std.mem.eql(u8, kind, "object") or std.mem.eql(u8, kind, "new_id"))) return error.InvalidInterfaceAttribute;
        const enum_name = attr(child, "enum");
        if (enum_name != null and !(std.mem.eql(u8, kind, "int") or std.mem.eql(u8, kind, "uint"))) return error.InvalidEnumAttribute;
        try args.append(arena, .{
            .name = try required(child, "name"),
            .kind = kind,
            .nullable = nullable,
            .interface_name = interface_name,
            .enum_name = enum_name,
        });
    }
    return .{ .name = try required(node, "name"), .since = since, .destructor = destructor, .args = args.items };
}

fn parseInterface(arena: Allocator, node: *const Node) !Interface {
    const version = try uintAttr(node, "version", null);
    var requests: std.ArrayList(Message) = .empty;
    var events: std.ArrayList(Message) = .empty;
    var enums: std.ArrayList(Enum) = .empty;
    for (node.children.items) |child| {
        if (std.mem.eql(u8, child.name, "description")) continue;
        if (std.mem.eql(u8, child.name, "request")) {
            if (requests.items.len > std.math.maxInt(u16)) return error.TooManyMessages;
            try requests.append(arena, try parseMessage(arena, child, version));
        } else if (std.mem.eql(u8, child.name, "event")) {
            if (events.items.len > std.math.maxInt(u16)) return error.TooManyMessages;
            try events.append(arena, try parseMessage(arena, child, version));
        } else if (std.mem.eql(u8, child.name, "enum")) {
            const since = try uintAttr(child, "since", 1);
            if (since > version) return error.MessageVersionTooNew;
            var entries: std.ArrayList(Entry) = .empty;
            for (child.children.items) |entry| {
                if (std.mem.eql(u8, entry.name, "description")) continue;
                if (!std.mem.eql(u8, entry.name, "entry")) return error.MalformedNesting;
                const entry_since = try uintAttr(entry, "since", 1);
                if (entry_since > version) return error.MessageVersionTooNew;
                try entries.append(arena, .{ .name = try required(entry, "name"), .value = try parseValue(try required(entry, "value")), .since = entry_since });
            }
            try enums.append(arena, .{ .name = try required(child, "name"), .bitfield = try boolAttr(child, "bitfield", false), .since = since, .entries = entries.items });
        } else return error.MalformedNesting;
    }
    return .{ .name = try required(node, "name"), .version = version, .requests = requests.items, .events = events.items, .enums = enums.items };
}

pub fn parse(gpa: Allocator, arena: Allocator, documents: []const []const u8) !ProtocolSet {
    var interfaces: std.ArrayList(Interface) = .empty;
    for (documents) |bytes| {
        const root = try parseDocument(gpa, arena, bytes);
        if (!std.mem.eql(u8, root.name, "protocol")) return error.MissingProtocol;
        _ = try required(root, "name");
        for (root.children.items) |child| {
            if (std.mem.eql(u8, child.name, "description") or std.mem.eql(u8, child.name, "copyright")) continue;
            if (!std.mem.eql(u8, child.name, "interface")) return error.MalformedNesting;
            const interface = try parseInterface(arena, child);
            for (interfaces.items) |existing| if (std.mem.eql(u8, existing.name, interface.name)) return error.DuplicateInterface;
            try interfaces.append(arena, interface);
        }
    }
    return .{ .interfaces = interfaces.items };
}

fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| switch (c) {
        '"', '\\' => try writer.print("\\{c}", .{c}),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (c < 0x20) try writer.print("\\x{x:0>2}", .{c}) else try writer.writeByte(c),
    };
    try writer.writeByte('"');
}
fn ident(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeAll("@\"");
    for (text) |c| if (c == '"' or c == '\\') try writer.print("\\{c}", .{c}) else try writer.writeByte(c);
    try writer.writeByte('"');
}
fn compositeIdent(writer: *std.Io.Writer, text: []const u8, suffix: []const u8) !void {
    try writer.writeAll("@\"");
    for (text) |c| if (c == '"' or c == '\\') try writer.print("\\{c}", .{c}) else try writer.writeByte(c);
    try writer.writeAll(suffix);
    try writer.writeByte('"');
}

pub fn generate(set: ProtocolSet, writer: *std.Io.Writer) !void {
    try writer.writeAll("//! Generated by Wayring scanner.\n\nconst wayring = @import(\"wayring\");\n\n");
    for (set.interfaces) |interface| {
        try writer.writeAll("pub const ");
        try compositeIdent(writer, interface.name, "_types");
        try writer.writeAll(" = struct {\n");
        for (interface.enums) |e| {
            try writer.writeAll("    pub const ");
            try ident(writer, e.name);
            if (e.bitfield) {
                try writer.writeAll(" = struct {\n");
                for (e.entries) |entry| {
                    try writer.writeAll("        pub const ");
                    try ident(writer, entry.name);
                    try writer.print(": u32 = {d};\n", .{entry.value});
                }
                try writer.writeAll("    };\n");
            } else {
                try writer.writeAll(" = enum(u32) {\n");
                for (e.entries) |entry| {
                    try writer.writeAll("        ");
                    try ident(writer, entry.name);
                    try writer.print(" = {d},\n", .{entry.value});
                }
                try writer.writeAll("        _,\n");
                try writer.writeAll("    };\n");
            }
        }
        try writer.writeAll("};\n");
        for ([_]struct { label: []const u8, messages: []const Message }{ .{ .label = "requests", .messages = interface.requests }, .{ .label = "events", .messages = interface.events } }) |group| {
            for (group.messages, 0..) |message, opcode| {
                try writer.writeAll("const ");
                var suffix: [64]u8 = undefined;
                const suffix_text = try std.fmt.bufPrint(&suffix, "_{s}_{d}_args", .{ group.label, opcode });
                try compositeIdent(writer, interface.name, suffix_text);
                try writer.writeAll(" = [_]wayring.ArgumentSpec{\n");
                for (message.args) |arg_value| {
                    if (std.mem.eql(u8, arg_value.kind, "new_id") and arg_value.interface_name == null) {
                        try writer.writeAll("    .{ .kind = .string, .name = \"interface\" },\n    .{ .kind = .uint, .name = \"version\" },\n");
                    }
                    try writer.writeAll("    .{ .kind = .");
                    try writer.writeAll(arg_value.kind);
                    if (arg_value.nullable) try writer.writeAll(", .nullable = true");
                    try writer.writeAll(", .name = ");
                    try writeString(writer, arg_value.name);
                    if (arg_value.interface_name) |v| {
                        try writer.writeAll(", .interface_name = ");
                        try writeString(writer, v);
                    }
                    if (arg_value.enum_name) |v| {
                        try writer.writeAll(", .enum_name = ");
                        try writeString(writer, v);
                    }
                    try writer.writeAll(" },\n");
                }
                try writer.writeAll("};\n");
            }
            try writer.writeAll("const ");
            var group_suffix: [32]u8 = undefined;
            const group_suffix_text = try std.fmt.bufPrint(&group_suffix, "_{s}", .{group.label});
            try compositeIdent(writer, interface.name, group_suffix_text);
            try writer.writeAll(" = [_]wayring.MessageDescriptor{\n");
            for (group.messages, 0..) |message, opcode| {
                try writer.writeAll("    .{ .name = ");
                try writeString(writer, message.name);
                try writer.print(", .opcode = {d}", .{opcode});
                if (message.since != 1) try writer.print(", .since = {d}", .{message.since});
                if (message.destructor) try writer.writeAll(", .destructor = true");
                try writer.writeAll(", .args = &");
                var suffix: [64]u8 = undefined;
                const suffix_text = try std.fmt.bufPrint(&suffix, "_{s}_{d}_args", .{ group.label, opcode });
                try compositeIdent(writer, interface.name, suffix_text);
                try writer.writeAll(" },\n");
            }
            try writer.writeAll("};\n");
        }
        try writer.writeAll("pub const ");
        try ident(writer, interface.name);
        try writer.writeAll(": wayring.Interface = .{ .name = ");
        try writeString(writer, interface.name);
        try writer.print(", .version = {d}, .requests = &", .{interface.version});
        try compositeIdent(writer, interface.name, "_requests");
        try writer.writeAll(", .events = &");
        try compositeIdent(writer, interface.name, "_events");
        try writer.writeAll(" };\n\n");
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(gpa);
    var output: ?[]const u8 = null;
    var args = init.minimal.args.iterate();
    _ = args.next(); // executable name
    while (args.next()) |arg_value| {
        if (std.mem.eql(u8, arg_value, "-i")) try inputs.append(gpa, args.next() orelse return error.MissingInputPath) else if (std.mem.eql(u8, arg_value, "-o")) {
            if (output != null) return error.DuplicateOutput;
            output = args.next() orelse return error.MissingOutputPath;
        } else return error.UnknownArgument;
    }
    if (inputs.items.len == 0) return error.MissingInput;
    const output_path = output orelse return error.MissingOutput;
    var documents: std.ArrayList([]const u8) = .empty;
    defer {
        for (documents.items) |d| gpa.free(d);
        documents.deinit(gpa);
    }
    for (inputs.items) |path| {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        try documents.append(gpa, try reader.interface.allocRemaining(gpa, .unlimited));
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const set = try parse(gpa, arena_state.allocator(), documents.items);
    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    defer writer.interface.flush() catch {};
    try generate(set, &writer.interface);
}

const fixture =
    \\<protocol name="sample"><interface name="wl_sample" version="3">
    \\<request name="destroy" type="destructor" since="2"><arg name="i" type="int"/><arg name="u" type="uint" enum="mode"/><arg name="f" type="fixed"/><arg name="s" type="string" allow-null="true"/><arg name="o" type="object" interface="wl_other" allow-null="true"/><arg name="a" type="array" allow-null="true"/><arg name="fd" type="fd"/><arg name="typed" type="new_id" interface="wl_other"/><arg name="dynamic" type="new_id"/></request>
    \\<event name="done"><arg name="value" type="uint"/></event>
    \\<enum name="mode"><entry name="one" value="1"/><entry name="shift" value="1 &lt;&lt; 4" since="2"/></enum>
    \\<enum name="flags" bitfield="true"><entry name="high" value="0x20"/></enum>
    \\</interface></protocol>
;

test "parse and generate complete descriptor fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const set = try parse(std.testing.allocator, arena.allocator(), &.{fixture});
    const interface = set.interfaces[0];
    try std.testing.expectEqual(@as(usize, 9), interface.requests[0].args.len);
    try std.testing.expect(interface.requests[0].destructor);
    try std.testing.expectEqual(@as(u32, 16), interface.enums[0].entries[1].value);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try generate(set, &out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, ".destructor = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".interface_name = \"wl_other\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".kind = .string, .name = \"interface\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@\"shift\" = 16") != null);
}

test "semantic errors are rejected" {
    const cases = [_][]const u8{
        "<protocol name=\"x\"><interface name=\"a\"/></protocol>",
        "<protocol name=\"x\"><interface name=\"a\" version=\"1\"><request/></interface></protocol>",
        "<protocol name=\"x\"><interface name=\"a\" version=\"1\"><event name=\"e\" since=\"2\"/></interface></protocol>",
        "<protocol name=\"x\"><interface name=\"a\" version=\"1\"><request name=\"r\"><arg name=\"x\" type=\"bad\"/></request></interface></protocol>",
    };
    for (cases) |bad| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        if (parse(std.testing.allocator, arena.allocator(), &.{bad})) |_| return error.ExpectedParseError else |_| {}
    }
}

test "duplicate interfaces and malformed nesting are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const duplicate = "<protocol name=\"x\"><interface name=\"a\" version=\"1\"/></protocol>";
    try std.testing.expectError(error.DuplicateInterface, parse(std.testing.allocator, arena.allocator(), &.{ duplicate, duplicate }));
    try std.testing.expectError(error.MalformedNesting, parse(std.testing.allocator, arena.allocator(), &.{"<protocol name=\"x\"><interface name=\"a\" version=\"1\"></protocol></interface>"}));
}
