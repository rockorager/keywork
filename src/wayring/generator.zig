//! Deterministic typed server binding generation from owned protocol models.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const Error = error{
    DuplicateInterface,
    DuplicateMessage,
    DuplicateEnum,
    DuplicateArgument,
    DuplicateEnumEntry,
    DeclarationCollision,
    InvalidVersion,
    InvalidSince,
    InvalidDeprecatedSince,
    InvalidAllowNull,
    InvalidInterfaceAttribute,
    InvalidEnumAttribute,
    UnknownInterface,
    UnknownEnum,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Generates one Zig source file for all supplied protocols. Protocol order is
/// retained, making output reproducible. String, array, and generic-new-id
/// request fields borrow the `DecodedMessage` body and remain valid until it
/// is deinitialized. Request file descriptors are transferred to the caller.
pub fn generate(allocator: std.mem.Allocator, protocols: []const *const protocol.Protocol, writer: *std.Io.Writer) Error!void {
    try validate(allocator, protocols);
    try writer.writeAll("const wayring = @import(\"wayring\");\nconst wire = wayring.wire;\n\n");
    for (protocols) |model| {
        for (model.interfaces) |*interface| try emitInterface(writer, interface);
    }
}

pub fn validate(allocator: std.mem.Allocator, protocols: []const *const protocol.Protocol) Error!void {
    var interfaces: std.StringHashMapUnmanaged(*const protocol.Interface) = .empty;
    defer interfaces.deinit(allocator);
    for (protocols) |model| {
        for (model.interfaces) |*interface| {
            if (std.mem.eql(u8, interface.name, "wayring") or std.mem.eql(u8, interface.name, "wire")) return error.DeclarationCollision;
            if (try interfaces.fetchPut(allocator, interface.name, interface) != null) return error.DuplicateInterface;
        }
    }
    for (protocols) |model| {
        for (model.interfaces) |*interface| {
            if (interface.version == 0) return error.InvalidVersion;
            var names: std.StringHashMapUnmanaged(void) = .empty;
            defer names.deinit(allocator);
            for (interface.requests) |*message| {
                if (try names.fetchPut(allocator, message.name, {}) != null) return error.DuplicateMessage;
                try validateMessage(allocator, &interfaces, interface, message);
            }
            names.clearRetainingCapacity();
            for (interface.events) |*message| {
                if (try names.fetchPut(allocator, message.name, {}) != null) return error.DuplicateMessage;
                try validateMessage(allocator, &interfaces, interface, message);
            }
            var declaration_arena = std.heap.ArenaAllocator.init(allocator);
            defer declaration_arena.deinit();
            const declaration_allocator = declaration_arena.allocator();
            var declarations: std.StringHashMapUnmanaged(void) = .empty;
            defer declarations.deinit(allocator);
            for ([_][]const u8{ "interface", "Request", "decodeRequest", "request_messages", "event_messages" }) |name| try reserveDeclaration(allocator, &declarations, name);
            for (interface.requests, 0..) |message, i| {
                const descriptor = try std.fmt.allocPrint(declaration_allocator, "request_{d}_arguments", .{i});
                try reserveDeclaration(allocator, &declarations, descriptor);
                const metadata = try std.fmt.allocPrint(declaration_allocator, "request:{s}:deprecated_since", .{message.name});
                try reserveDeclaration(allocator, &declarations, metadata);
            }
            for (interface.events, 0..) |message, i| {
                const descriptor = try std.fmt.allocPrint(declaration_allocator, "event_{d}_arguments", .{i});
                try reserveDeclaration(allocator, &declarations, descriptor);
                const sender = try std.fmt.allocPrint(declaration_allocator, "send:{s}", .{message.name});
                try reserveDeclaration(allocator, &declarations, sender);
            }
            var enums: std.StringHashMapUnmanaged(void) = .empty;
            defer enums.deinit(allocator);
            for (interface.enums) |*enum_model| {
                if (try enums.fetchPut(allocator, enum_model.name, {}) != null) return error.DuplicateEnum;
                try reserveDeclaration(allocator, &declarations, enum_model.name);
                if (enum_model.since == 0 or enum_model.since > interface.version) return error.InvalidSince;
                var entries: std.StringHashMapUnmanaged(void) = .empty;
                defer entries.deinit(allocator);
                try entries.put(allocator, "bitfield", {});
                for (enum_model.entries) |entry| {
                    if (try entries.fetchPut(allocator, entry.name, {}) != null) {
                        if (std.mem.eql(u8, entry.name, "bitfield")) return error.DeclarationCollision;
                        return error.DuplicateEnumEntry;
                    }
                    if (entry.since == 0 or entry.since > interface.version) return error.InvalidSince;
                    if (entry.deprecated_since) |value| {
                        if (value > interface.version or value < entry.since) return error.InvalidDeprecatedSince;
                    }
                }
            }
        }
    }
}

fn reserveDeclaration(allocator: std.mem.Allocator, declarations: *std.StringHashMapUnmanaged(void), name: []const u8) Error!void {
    if (try declarations.fetchPut(allocator, name, {}) != null) return error.DeclarationCollision;
}

fn validateMessage(allocator: std.mem.Allocator, interfaces: *const std.StringHashMapUnmanaged(*const protocol.Interface), owner: *const protocol.Interface, message: *const protocol.Message) Error!void {
    if (message.since == 0 or message.since > owner.version) return error.InvalidSince;
    if (message.deprecated_since) |value| {
        if (value > owner.version or value < message.since) return error.InvalidDeprecatedSince;
    }
    var arguments: std.StringHashMapUnmanaged(void) = .empty;
    defer arguments.deinit(allocator);
    for (message.arguments) |argument| {
        if (try arguments.fetchPut(allocator, argument.name, {}) != null) return error.DuplicateArgument;
        if (argument.allow_null and argument.type != .string and argument.type != .object) return error.InvalidAllowNull;
        if (argument.interface != null and argument.type != .object and argument.type != .new_id) return error.InvalidInterfaceAttribute;
        if (argument.interface) |name| {
            if (!interfaces.contains(name)) return error.UnknownInterface;
        }
        if (argument.enum_name) |reference| {
            if (argument.type != .int and argument.type != .uint) return error.InvalidEnumAttribute;
            var enum_owner = owner;
            var enum_name = reference;
            if (std.mem.indexOfScalar(u8, reference, '.')) |dot| {
                enum_owner = interfaces.get(reference[0..dot]) orelse return error.UnknownInterface;
                enum_name = reference[dot + 1 ..];
            }
            var found = false;
            for (enum_owner.enums) |candidate| if (std.mem.eql(u8, candidate.name, enum_name)) {
                found = true;
                break;
            };
            if (!found) return error.UnknownEnum;
        }
    }
}

fn emitInterface(w: *std.Io.Writer, interface: *const protocol.Interface) !void {
    try w.writeAll("pub const ");
    try ident(w, interface.name);
    try w.writeAll(" = struct {\n");
    try w.print("    pub const interface: wire.Interface = .{{ .name = \"{f}\", .version = {d} }};\n", .{ std.zig.fmtString(interface.name), interface.version });
    for (interface.enums) |enum_model| {
        try w.writeAll("    pub const ");
        try ident(w, enum_model.name);
        try w.writeAll(" = struct {\n");
        try w.print("        pub const bitfield = {};\n", .{enum_model.bitfield});
        for (enum_model.entries) |entry| {
            try w.writeAll("        pub const ");
            try ident(w, entry.name);
            try w.print(": i64 = {d};\n", .{entry.value});
        }
        try w.writeAll("    };\n");
    }
    for (interface.requests) |message| {
        try w.writeAll("    pub const @\"request:");
        try w.print("{f}", .{std.zig.fmtString(message.name)});
        try w.writeAll(":deprecated_since\": ?u32 = ");
        if (message.deprecated_since) |value| try w.print("{d}", .{value}) else try w.writeAll("null");
        try w.writeAll(";\n");
    }
    try emitDescriptors(w, "request", interface.requests);
    try emitDescriptors(w, "event", interface.events);
    try w.writeAll("    pub const Request = union(enum) {\n");
    for (interface.requests) |message| {
        try w.writeAll("        ");
        try ident(w, message.name);
        try w.writeAll(": struct {\n");
        for (message.arguments) |arg| {
            try w.writeAll("            ");
            try ident(w, arg.name);
            try w.writeAll(": ");
            try typeName(w, arg);
            try w.writeAll(",\n");
        }
        try w.writeAll("        },\n");
    }
    try w.writeAll("    };\n\n    /// Borrowed request slices remain valid only while `message` is alive.\n    pub fn decodeRequest(opcode: u16, message: *wire.DecodedMessage) !Request {\n        if (opcode >= request_messages.len or message.descriptor != &request_messages[opcode] or message.values.len != request_messages[opcode].arguments.len) return error.InvalidRequestDescriptor;\n        return switch (opcode) {\n");
    for (interface.requests, 0..) |message, opcode| {
        try w.print("            {d} => blk: {{\n", .{opcode});
        for (message.arguments, 0..) |arg, index| try emitPreflight(w, arg, index);
        try w.writeAll("                break :blk .{ .");
        try ident(w, message.name);
        try w.writeAll(" = .{\n");
        for (message.arguments, 0..) |arg, index| {
            try w.writeAll("                .");
            try ident(w, arg.name);
            try w.writeAll(" = ");
            try decodeExpr(w, arg, index);
            try w.writeAll(",\n");
        }
        try w.writeAll("            } };\n            },\n");
    }
    try w.writeAll("            else => error.UnknownRequestOpcode,\n        };\n    }\n");
    for (interface.events, 0..) |message, opcode| try emitSender(w, message, opcode);
    try w.writeAll("};\n\n");
    try w.writeAll("test { _ = ");
    try ident(w, interface.name);
    try w.writeAll(".interface; _ = ");
    try ident(w, interface.name);
    try w.writeAll(".request_messages; _ = ");
    try ident(w, interface.name);
    try w.writeAll(".event_messages; }\n\n");
}

fn emitDescriptors(w: *std.Io.Writer, prefix: []const u8, messages: []const protocol.Message) !void {
    for (messages, 0..) |message, i| {
        try w.print("    pub const {s}_{d}_arguments = [_]wire.ArgumentDescriptor{{\n", .{ prefix, i });
        for (message.arguments) |arg| {
            try w.print("        .{{ .name = \"{f}\", .kind = ", .{std.zig.fmtString(arg.name)});
            try kind(w, arg);
            try w.writeAll(" },\n");
        }
        try w.writeAll("    };\n");
    }
    try w.print("    pub const {s}_messages = [_]wire.MessageDescriptor{{\n", .{prefix});
    for (messages, 0..) |message, i| try w.print("        .{{ .name = \"{f}\", .since = {d}, .destructor = {}, .arguments = &{s}_{d}_arguments }},\n", .{ std.zig.fmtString(message.name), message.since, message.destructor, prefix, i });
    try w.writeAll("    };\n");
}

fn kind(w: *std.Io.Writer, arg: protocol.Argument) !void {
    switch (arg.type) {
        .int => try w.writeAll(".int"),
        .uint => try w.writeAll(".uint"),
        .fixed => try w.writeAll(".fixed"),
        .string => try w.print(".{{ .string = .{s} }}", .{if (arg.allow_null) "nullable" else "required"}),
        .object => {
            try w.writeAll(".{ .object = .{ .interface = ");
            if (arg.interface) |name| {
                try w.writeAll("&");
                try ident(w, name);
                try w.writeAll(".interface");
            } else try w.writeAll("null");
            try w.print(", .nullability = .{s} }} }}", .{if (arg.allow_null) "nullable" else "required"});
        },
        .new_id => {
            try w.writeAll(".{ .new_id = ");
            if (arg.interface) |name| {
                try w.writeAll("&");
                try ident(w, name);
                try w.writeAll(".interface");
            } else try w.writeAll("null");
            try w.writeAll(" }");
        },
        .array => try w.writeAll(".array"),
        .fd => try w.writeAll(".fd"),
    }
}

fn typeName(w: *std.Io.Writer, arg: protocol.Argument) !void {
    switch (arg.type) {
        .int, .fixed => try w.writeAll("i32"),
        .uint => try w.writeAll("u32"),
        .string => try w.writeAll(if (arg.allow_null) "?[]const u8" else "[]const u8"),
        .array => try w.writeAll("[]const u8"),
        .object => try w.writeAll(if (arg.allow_null) "?u32" else "u32"),
        .new_id => try w.writeAll(if (arg.interface == null) "wire.GenericNewId" else "u32"),
        .fd => try w.writeAll("wire.FileDescriptor"),
    }
}

fn decodeExpr(w: *std.Io.Writer, arg: protocol.Argument, i: usize) !void {
    if (arg.type == .fd) {
        try w.print("try message.takeFd({d})", .{i});
        return;
    }
    try w.print("switch (message.values[{d}]) {{ .{s} => |value| ", .{ i, @tagName(arg.type) });
    if (arg.type == .new_id) try w.writeAll(if (arg.interface == null) "switch (value) { .generic => |id| id, else => return error.InvalidRequestValue }," else "switch (value) { .typed => |id| id, else => return error.InvalidRequestValue },") else if (arg.type == .object and !arg.allow_null) try w.writeAll("value orelse return error.InvalidRequestValue,") else if (arg.type == .string and !arg.allow_null) try w.writeAll("value orelse return error.InvalidRequestValue,") else try w.writeAll("value,");
    try w.writeAll(" else => return error.InvalidRequestValue }");
}

fn emitPreflight(w: *std.Io.Writer, arg: protocol.Argument, i: usize) !void {
    const inspect_value = arg.type == .fd or arg.type == .new_id or ((arg.type == .string or arg.type == .object) and !arg.allow_null);
    try w.print("                switch (message.values[{d}]) {{ .{s} => ", .{ i, @tagName(arg.type) });
    if (inspect_value) try w.writeAll("|value| ");
    try w.writeAll("{ ");
    switch (arg.type) {
        .fd => try w.writeAll("if (value == null) return error.FileDescriptorAlreadyTaken;"),
        .string, .object => if (!arg.allow_null) try w.writeAll("if (value == null) return error.InvalidRequestValue;"),
        .new_id => if (arg.interface == null)
            try w.writeAll("switch (value) { .generic => {}, else => return error.InvalidRequestValue }")
        else
            try w.writeAll("switch (value) { .typed => {}, else => return error.InvalidRequestValue }"),
        else => {},
    }
    try w.writeAll(" }, else => return error.InvalidRequestValue }\n");
}

fn emitSender(w: *std.Io.Writer, message: protocol.Message, opcode: usize) !void {
    try w.writeAll("    pub fn @\"send:");
    try w.print("{f}", .{std.zig.fmtString(message.name)});
    try w.writeAll("\"");
    const output_suffix = internalNameSuffix(message, "__wayring_output");
    const object_suffix = internalNameSuffixWithReserved(message, "__wayring_object_id", "__wayring_output", output_suffix);
    const values_suffix = internalNameSuffix(message, "__wayring_values");
    try w.writeAll("(");
    try writeInternalName(w, "__wayring_output", output_suffix);
    try w.writeAll(": *wire.Output, ");
    try writeInternalName(w, "__wayring_object_id", object_suffix);
    try w.writeAll(": u32");
    for (message.arguments) |arg| {
        try w.writeAll(", ");
        try ident(w, arg.name);
        try w.writeAll(": ");
        try typeName(w, arg);
    }
    try w.writeAll(") !void {\n        const ");
    try writeInternalName(w, "__wayring_values", values_suffix);
    try w.writeAll(" = [_]wire.Value{\n");
    for (message.arguments) |arg| {
        try w.writeAll("            .{ .");
        try w.writeAll(@tagName(arg.type));
        try w.writeAll(" = ");
        if (arg.type == .new_id) {
            if (arg.interface == null) try w.writeAll(".{ .generic = ") else try w.writeAll(".{ .typed = ");
            try ident(w, arg.name);
            try w.writeAll(" }");
        } else {
            try ident(w, arg.name);
        }
        try w.writeAll(" },\n");
    }
    try w.writeAll("        };\n        try ");
    try writeInternalName(w, "__wayring_output", output_suffix);
    try w.writeAll(".enqueue(");
    try writeInternalName(w, "__wayring_object_id", object_suffix);
    try w.print(", {d}, &event_messages[{d}], &", .{ opcode, opcode });
    try writeInternalName(w, "__wayring_values", values_suffix);
    try w.writeAll(");\n    }\n");
}

fn internalNameSuffix(message: protocol.Message, base: []const u8) usize {
    var suffix: usize = 0;
    while (hasArgumentName(message, base, suffix)) suffix += 1;
    return suffix;
}

fn internalNameSuffixWithReserved(message: protocol.Message, base: []const u8, reserved_base: []const u8, reserved_suffix: usize) usize {
    var suffix: usize = 0;
    while (hasArgumentName(message, base, suffix) or (std.mem.eql(u8, base, reserved_base) and suffix == reserved_suffix)) suffix += 1;
    return suffix;
}

fn hasArgumentName(message: protocol.Message, base: []const u8, suffix: usize) bool {
    for (message.arguments) |arg| {
        if (arg.name.len == base.len + suffix and std.mem.startsWith(u8, arg.name, base)) {
            var matches = true;
            for (arg.name[base.len..]) |byte| matches = matches and byte == '_';
            if (matches) return true;
        }
    }
    return false;
}

fn writeInternalName(w: *std.Io.Writer, base: []const u8, suffix: usize) !void {
    try w.writeAll(base);
    try w.splatByteAll('_', suffix);
}

fn ident(w: *std.Io.Writer, name: []const u8) !void {
    try w.print("@\"{f}\"", .{std.zig.fmtString(name)});
}

test "validation and escaped identifiers" {
    var model = try protocol.parse(std.testing.allocator, "<protocol name='p'><interface name='struct' version='1'><request name='error'><arg name='type' type='uint'/></request></interface></protocol>");
    defer model.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generate(std.testing.allocator, &.{&model}, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "pub const @\"struct\"") != null);
    var repeated: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer repeated.deinit();
    try generate(std.testing.allocator, &.{&model}, &repeated.writer);
    try std.testing.expectEqualStrings(output.written(), repeated.written());
    var bad = try protocol.parse(std.testing.allocator, "<protocol name='p'><interface name='i' version='1'><event name='e' since='2'/></interface></protocol>");
    defer bad.deinit();
    try std.testing.expectError(error.InvalidSince, validate(std.testing.allocator, &.{&bad}));
    var reference = try protocol.parse(std.testing.allocator, "<protocol name='p'><interface name='i' version='1'><event name='e'><arg name='x' type='uint' enum='missing'/></event></interface></protocol>");
    defer reference.deinit();
    try std.testing.expectError(error.UnknownEnum, validate(std.testing.allocator, &.{&reference}));
}
