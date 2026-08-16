//! Serialization of the retained widget tree's semantic state.

const std = @import("std");
const keywork = @import("keywork-ui");

pub fn write(
    json: *std.json.Stringify,
    root: *const keywork.Element,
    action_owner_id: u64,
    action_revision: u64,
) !void {
    var action_index: usize = 0;
    try writeElement(json, root, action_owner_id, action_revision, &action_index);
}

fn writeElement(
    json: *std.json.Stringify,
    element: *const keywork.Element,
    action_owner_id: u64,
    action_revision: u64,
    action_index: *usize,
) !void {
    try json.beginObject();
    try json.objectField("kind");
    try json.write(@tagName(element.kind));
    if (element.key) |key| {
        try json.objectField("key");
        switch (key) {
            .string => |value| try json.write(value),
            .integer => |value| try json.write(value),
        }
    }
    switch (element.widget) {
        .text => |text| {
            try json.objectField("text");
            try json.write(text.value);
            try json.objectField("role");
            try json.write(@tagName(text.role));
        },
        .clickable => |clickable| {
            try writeId(json, clickable.id);
            if (clickable.intent) |intent| try writeIntent(json, "intent", intent);
        },
        .anchored => |anchored| try writeId(json, anchored.id),
        .focus => |focus| {
            try writeId(json, focus.node.id);
            try writeFocused(json, element.focused);
        },
        .focus_scope => |scope| {
            try writeId(json, scope.id);
            if (scope.modal) {
                try json.objectField("modal");
                try json.write(true);
            }
        },
        .scroll => |scroll| try writeId(json, scroll.id),
        .list => |list| {
            try writeId(json, list.id);
            try json.objectField("itemCount");
            try json.write(list.item_count);
            if (list.selected) |selected| {
                try json.objectField("selected");
                try json.write(selected);
            }
        },
        .text_input => |input| {
            try writeId(json, input.id);
            try json.objectField("focusId");
            try json.write(input.focus_node.id);
            try writeFocused(json, element.focused);
            try json.objectField("obscured");
            try json.write(input.obscured);
            if (!input.obscured) {
                const state = keywork.textInputState(@constCast(element));
                try json.objectField("value");
                try json.write(state.text.items);
            }
            if (input.placeholder.len > 0) {
                try json.objectField("placeholder");
                try json.write(input.placeholder);
            }
        },
        .actions => |actions| {
            try json.objectField("actions");
            try json.beginArray();
            for (actions.bindings) |action| {
                try json.beginObject();
                try json.objectField("handle");
                var handle_buffer: [96]u8 = undefined;
                const handle = try std.fmt.bufPrint(
                    &handle_buffer,
                    "{d}:{d}:{d}",
                    .{ action_owner_id, action_revision, action_index.* },
                );
                try json.write(handle);
                try json.objectField("id");
                try json.write(action.id);
                if (action.input_schema_json) |schema| {
                    try json.objectField("inputSchemaJson");
                    try json.write(schema);
                }
                try json.endObject();
                action_index.* += 1;
            }
            try json.endArray();
        },
        .shortcuts => |shortcuts| {
            try json.objectField("shortcuts");
            try json.beginArray();
            for (shortcuts.bindings) |shortcut| {
                try json.beginObject();
                try json.objectField("key");
                try json.write(@tagName(shortcut.key));
                try writeIntent(json, "intent", shortcut.intent);
                try json.endObject();
            }
            try json.endArray();
        },
        else => {},
    }
    try json.objectField("children");
    try json.beginArray();
    for (element.children) |*child| {
        try writeElement(json, child, action_owner_id, action_revision, action_index);
    }
    try json.endArray();
    try json.endObject();
}

fn writeId(json: *std.json.Stringify, id: []const u8) !void {
    try json.objectField("id");
    try json.write(id);
}

fn writeFocused(json: *std.json.Stringify, focused: bool) !void {
    if (!focused) return;
    try json.objectField("focused");
    try json.write(true);
}

fn writeIntent(json: *std.json.Stringify, field: []const u8, intent: keywork.Intent) !void {
    try json.objectField(field);
    try json.beginObject();
    try json.objectField("actionId");
    try json.write(intent.action_id);
    if (intent.target_json) |target| {
        try json.objectField("targetJson");
        try json.write(target);
    }
    try json.endObject();
}

test "semantic snapshots expose text without visual styling" {
    const text: keywork.Element = .{
        .kind = .text,
        .widget = .{ .text = .{ .value = "Hello", .role = .title } },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try write(&json, &text, 3, 7);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"text\",\"text\":\"Hello\",\"role\":\"title\",\"children\":[]}",
        output.written(),
    );
}

test "semantic snapshots redact obscured input values" {
    var state: keywork.TextInputState = .{};
    defer state.text.deinit(std.testing.allocator);
    try state.text.appendSlice(std.testing.allocator, "secret");
    var input: keywork.Element = .{
        .kind = .text_input,
        .widget = .{ .text_input = .{
            .id = "password",
            .focus_node = .named("password"),
            .value = "ignored",
            .placeholder = "Password",
            .obscured = true,
        } },
        .state = &state,
        .focused = true,
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try write(&json, &input, 3, 7);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"obscured\":true") != null);
}
