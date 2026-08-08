//! Canonical generated-server publication profile and security diagnostics.
//!
//! The manifest records stable interface order, versions, publication gates,
//! and visibility. Protocol adapters still own resources and publication;
//! startup validates their composed registry against this source of truth.

const std = @import("std");
const wayring = @import("wayring");

const Server = wayring.server.Server;
const Client = wayring.server.Client;

pub const Gate = enum {
    sidecar,
    presenting_headless,
};

pub const Entry = struct {
    interface: []const u8,
    version: u32,
    visibility: Server.GlobalVisibility = .public,
    gate: Gate,
};

pub const entries = [_]Entry{
    .{ .interface = "wl_compositor", .version = 6, .gate = .sidecar },
    .{ .interface = "wl_shm", .version = 1, .gate = .sidecar },
    .{ .interface = "wl_subcompositor", .version = 1, .gate = .sidecar },
    .{ .interface = "wl_seat", .version = 11, .gate = .sidecar },
    .{ .interface = "wl_output", .version = 4, .gate = .presenting_headless },
    .{ .interface = "zxdg_output_manager_v1", .version = 3, .gate = .presenting_headless },
    .{ .interface = "wp_presentation", .version = 2, .gate = .presenting_headless },
    .{ .interface = "xdg_wm_base", .version = 7, .gate = .presenting_headless },
    .{ .interface = "wp_viewporter", .version = 1, .gate = .presenting_headless },
    .{ .interface = "wp_fractional_scale_manager_v1", .version = 1, .gate = .presenting_headless },
    .{ .interface = "wp_content_type_manager_v1", .version = 1, .gate = .presenting_headless },
    .{ .interface = "wl_fixes", .version = 1, .gate = .presenting_headless },
    .{ .interface = "wp_cursor_shape_manager_v1", .version = 2, .gate = .presenting_headless },
    .{ .interface = "zxdg_decoration_manager_v1", .version = 2, .gate = .presenting_headless },
    .{ .interface = "xdg_activation_v1", .version = 1, .gate = .presenting_headless },
    .{ .interface = "wl_data_device_manager", .version = 4, .gate = .presenting_headless },
    .{ .interface = "zwp_primary_selection_device_manager_v1", .version = 1, .gate = .presenting_headless },
    .{ .interface = "zwp_text_input_manager_v3", .version = 2, .gate = .presenting_headless },
    .{ .interface = "ext_data_control_manager_v1", .version = 1, .visibility = .restricted, .gate = .presenting_headless },
    .{ .interface = "zwp_input_method_manager_v2", .version = 1, .visibility = .restricted, .gate = .presenting_headless },
    .{ .interface = "zwp_virtual_keyboard_manager_v1", .version = 1, .visibility = .restricted, .gate = .presenting_headless },
    .{ .interface = "zwlr_layer_shell_v1", .version = 5, .gate = .presenting_headless },
    .{ .interface = "ext_session_lock_manager_v1", .version = 1, .visibility = .restricted, .gate = .presenting_headless },
    .{ .interface = "ext_idle_notifier_v1", .version = 2, .gate = .presenting_headless },
    .{ .interface = "ext_workspace_manager_v1", .version = 1, .visibility = .restricted, .gate = .presenting_headless },
    .{ .interface = "wp_security_context_manager_v1", .version = 1, .visibility = .restricted, .gate = .presenting_headless },
    .{ .interface = "zwp_linux_dmabuf_v1", .version = 6, .gate = .presenting_headless },
    .{ .interface = "zwlr_output_manager_v1", .version = 4, .visibility = .restricted, .gate = .presenting_headless },
    .{ .interface = "zwlr_screencopy_manager_v1", .version = 3, .visibility = .restricted, .gate = .presenting_headless },
    .{ .interface = "zwlr_virtual_pointer_manager_v1", .version = 2, .visibility = .restricted, .gate = .presenting_headless },
};

pub const PeerClass = enum { direct, security_context, unknown };

pub const Diagnostic = union(enum) {
    missing: struct { index: usize, expected: Entry },
    unexpected: struct { index: usize, actual: Actual },
    mismatch: struct { index: usize, expected: Entry, actual: Actual },

    pub fn format(self: Diagnostic, writer: *std.Io.Writer) !void {
        switch (self) {
            .missing => |value| try writer.print(
                "profile[{d}] missing expected {s}@{d} visibility={t}",
                .{ value.index, value.expected.interface, value.expected.version, value.expected.visibility },
            ),
            .unexpected => |value| try writer.print(
                "profile[{d}] unexpected {s}@{d} visibility={t}",
                .{ value.index, value.actual.interface, value.actual.version, value.actual.visibility },
            ),
            .mismatch => |value| try writer.print(
                "profile[{d}] expected {s}@{d} visibility={t}; actual {s}@{d} visibility={t}",
                .{ value.index, value.expected.interface, value.expected.version, value.expected.visibility, value.actual.interface, value.actual.version, value.actual.visibility },
            ),
        }
    }
};

pub const Actual = struct {
    interface: []const u8,
    version: u32,
    visibility: Server.GlobalVisibility,
};

pub fn visible(entry: Entry, peer: PeerClass) bool {
    return switch (entry.visibility) {
        .public => true,
        .restricted => peer == .direct,
        .private => false,
    };
}

pub fn expectedCount(gate: Gate, peer: PeerClass) usize {
    var count: usize = 0;
    for (entries) |entry| if (enabled(entry, gate) and visible(entry, peer)) {
        count += 1;
    };
    return count;
}

pub fn expectedAt(gate: Gate, peer: PeerClass, visible_index: usize) ?Entry {
    var index: usize = 0;
    for (entries) |entry| {
        if (!enabled(entry, gate) or !visible(entry, peer)) continue;
        if (index == visible_index) return entry;
        index += 1;
    }
    return null;
}

pub fn validate(server: *const Server, gate: Gate) ?Diagnostic {
    var iterator = server.iterator();
    var index: usize = 0;
    while (iterator.next()) |global| : (index += 1) {
        const actual: Actual = .{
            .interface = global.interface().name,
            .version = global.version(),
            .visibility = global.visibility(),
        };
        const expected = expectedAt(gate, .direct, index) orelse
            return .{ .unexpected = .{ .index = index, .actual = actual } };
        if (!std.mem.eql(u8, expected.interface, actual.interface) or
            expected.version != actual.version or expected.visibility != actual.visibility)
            return .{ .mismatch = .{ .index = index, .expected = expected, .actual = actual } };
    }
    if (expectedAt(gate, .direct, index)) |expected|
        return .{ .missing = .{ .index = index, .expected = expected } };
    return null;
}

pub fn securityVisible(
    authorized_uid: std.os.linux.uid_t,
    client: *const Client,
    global: *const Server.Global,
) bool {
    return switch (global.visibility()) {
        .public => true,
        .restricted => client.securityIdentity().isTrustedDirectUid(authorized_uid),
        .private => false,
    };
}

fn enabled(entry: Entry, gate: Gate) bool {
    return entry.gate == .sidecar or gate == .presenting_headless;
}

test "manifest pins exact direct and security-context profiles" {
    try std.testing.expectEqual(@as(usize, 4), expectedCount(.sidecar, .direct));
    try std.testing.expectEqual(@as(usize, 4), expectedCount(.sidecar, .security_context));
    try std.testing.expectEqual(@as(usize, 30), expectedCount(.presenting_headless, .direct));
    try std.testing.expectEqual(@as(usize, 21), expectedCount(.presenting_headless, .security_context));
    try std.testing.expectEqual(@as(usize, 21), expectedCount(.presenting_headless, .unknown));
    try std.testing.expectEqualStrings("wp_security_context_manager_v1", expectedAt(.presenting_headless, .direct, 25).?.interface);
    try std.testing.expectEqualStrings("zwp_linux_dmabuf_v1", expectedAt(.presenting_headless, .security_context, 20).?.interface);
    try std.testing.expect(expectedAt(.presenting_headless, .security_context, 21) == null);
}

test "security visibility requires trusted direct UID and keeps public open" {
    const TestProtocol = struct {
        pub const interface: wayring.wire.Interface = .{ .name = "wl_test", .version = 1 };
    };
    const Context = struct {
        fn bind(_: *Client, _: u32, _: u32, _: *@This()) !void {}
    };
    var server: Server = .init(std.testing.allocator);
    defer server.deinit();
    var context: Context = .{};
    const public = try server.addGlobal(TestProtocol, 1, Context, &context, Context.bind);
    const restricted = try server.addGlobalWithOptions(TestProtocol, 1, Context, &context, Context.bind, .{ .visibility = .restricted });
    const private = try server.addGlobalWithOptions(TestProtocol, 1, Context, &context, Context.bind, .{ .visibility = .private });

    const credentials: Client.Credentials = .{ .pid = 1, .uid = 42, .gid = 2 };
    var direct: Client = .init(std.testing.allocator, .{ .credentials = credentials, .transport_provenance = .direct });
    defer direct.deinit();
    var foreign: Client = .init(std.testing.allocator, .{ .credentials = .{ .pid = 2, .uid = 41, .gid = 2 }, .transport_provenance = .direct });
    defer foreign.deinit();
    var derived: Client = .init(std.testing.allocator, .{ .credentials = credentials, .transport_provenance = .security_context });
    defer derived.deinit();
    var unknown: Client = .init(std.testing.allocator, .{ .credentials = credentials });
    defer unknown.deinit();
    var missing: Client = .init(std.testing.allocator, .{ .transport_provenance = .direct });
    defer missing.deinit();

    inline for (.{ &direct, &foreign, &derived, &unknown, &missing }) |client|
        try std.testing.expect(securityVisible(42, client, public));
    try std.testing.expect(securityVisible(42, &direct, restricted));
    inline for (.{ &foreign, &derived, &unknown, &missing }) |client|
        try std.testing.expect(!securityVisible(42, client, restricted));
    inline for (.{ &direct, &foreign, &derived, &unknown, &missing }) |client|
        try std.testing.expect(!securityVisible(42, client, private));
}

test "diagnostics are deterministic and include order version and visibility" {
    const expected = entries[14];
    const diagnostic: Diagnostic = .{ .mismatch = .{
        .index = 14,
        .expected = expected,
        .actual = .{ .interface = expected.interface, .version = 2, .visibility = .public },
    } };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try diagnostic.format(&writer);
    try std.testing.expectEqualStrings(
        "profile[14] expected ext_data_control_manager_v1@1 visibility=restricted; actual ext_data_control_manager_v1@2 visibility=public",
        writer.buffered(),
    );
}
