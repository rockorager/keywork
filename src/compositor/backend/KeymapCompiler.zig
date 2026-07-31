//! Compiles XKB keymaps and owns their sealed, file-backed serialization.

const KeymapCompiler = @This();

const std = @import("std");

pub const xkb = @cImport({
    @cInclude("stdlib.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-names.h");
});

allocator: std.mem.Allocator,
io: std.Io,
context: *xkb.struct_xkb_context,

pub const Format = enum(u32) {
    text_v1 = 1,
    text_v2 = 2,
};

pub const Keymap = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    native: *xkb.struct_xkb_keymap,
    file: std.Io.File,
    size: u32,
    references: usize = 1,

    /// Adds an owned reference to this keymap.
    pub fn ref(self: *Keymap) *Keymap {
        self.references = std.math.add(usize, self.references, 1) catch unreachable;
        return self;
    }

    /// Releases an owned reference, destroying the keymap after the final release.
    pub fn unref(self: *Keymap) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        self.file.close(self.io);
        xkb.xkb_keymap_unref(self.native);
        self.allocator.destroy(self);
    }
};

pub fn init(self: *KeymapCompiler, allocator: std.mem.Allocator, io: std.Io) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed,
    };
}

pub fn deinit(self: *KeymapCompiler) void {
    xkb.xkb_context_unref(self.context);
    self.* = undefined;
}

/// Compiles the default XKB rules and returns one owned reference.
pub fn defaultKeymap(self: *KeymapCompiler) !*Keymap {
    // Keep the runtime contract compatible with Debian 13's libxkbcommon.
    // We serialize the result explicitly below, so the newer format-selecting
    // convenience API provides no benefit here.
    const native = xkb.xkb_keymap_new_from_names(
        self.context,
        null,
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.XkbKeymapFailed;
    return self.wrap(native);
}

/// Compiles `text` and returns one owned reference, or null for empty or rejected input.
pub fn compile(self: *KeymapCompiler, format: Format, text: []const u8) !?*Keymap {
    if (text.len == 0) return null;
    const native = xkb.xkb_keymap_new_from_buffer(
        self.context,
        text.ptr,
        text.len,
        @as(xkb.enum_xkb_keymap_format, @intFromEnum(format)),
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return null;
    return try self.wrap(native);
}

fn wrap(self: *KeymapCompiler, native: *xkb.struct_xkb_keymap) !*Keymap {
    errdefer xkb.xkb_keymap_unref(native);
    const text_pointer = xkb.xkb_keymap_get_as_string(
        native,
        xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
    ) orelse return error.SerializeKeymapFailed;
    defer xkb.free(text_pointer);
    const text = std.mem.span(text_pointer);
    const size = std.math.add(usize, text.len, 1) catch return error.KeymapTooLarge;
    if (size > std.math.maxInt(u32)) return error.KeymapTooLarge;

    const fd = try std.posix.memfd_create(
        "keywork-keymap",
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    errdefer file.close(self.io);
    try file.setLength(self.io, size);
    try file.writeStreamingAll(self.io, text.ptr[0..size]);
    const seals = std.os.linux.F.SEAL_SHRINK |
        std.os.linux.F.SEAL_GROW |
        std.os.linux.F.SEAL_WRITE |
        std.os.linux.F.SEAL_SEAL;
    if (std.c.fcntl(fd, std.os.linux.F.ADD_SEALS, @as(c_int, seals)) < 0) {
        return error.SealKeymapFailed;
    }
    const keymap = try self.allocator.create(Keymap);
    keymap.* = .{
        .allocator = self.allocator,
        .io = self.io,
        .native = native,
        .file = file,
        .size = @intCast(size),
    };
    return keymap;
}

test "compiler works without native input" {
    var compiler: KeymapCompiler = undefined;
    try compiler.init(std.testing.allocator, std.testing.io);
    defer compiler.deinit();

    const default = try compiler.defaultKeymap();
    defer default.unref();
    const text_pointer = xkb.xkb_keymap_get_as_string(
        default.native,
        xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
    ) orelse return error.SerializeKeymapFailed;
    defer xkb.free(text_pointer);
    const compiled = (try compiler.compile(.text_v1, std.mem.span(text_pointer))).?;
    compiled.unref();
}
