//! Typed commands understood by the built-in compositor policy.

pub const Direction = enum {
    left,
    down,
    up,
    right,
};

pub const WindowTarget = enum {
    focused,
};

pub const Command = union(enum) {
    focus_next,
    focus_previous,
    focus_direction: Direction,
    move_focused_next,
    move_focused_previous,
    move_focused_direction: Direction,
    close: WindowTarget,
    toggle_fullscreen: WindowTarget,
    toggle_floating: WindowTarget,
    layout_tiled,
    switch_workspace: u8,
    move_to_workspace: u8,

    pub fn repeats(self: Command) bool {
        return switch (self) {
            .focus_next,
            .focus_previous,
            .focus_direction,
            .move_focused_next,
            .move_focused_previous,
            .move_focused_direction,
            => true,
            .close,
            .toggle_fullscreen,
            .toggle_floating,
            .layout_tiled,
            .switch_workspace,
            .move_to_workspace,
            => false,
        };
    }
};

test "only directional commands repeat" {
    const testing = @import("std").testing;

    try testing.expect(Command.repeats(.focus_next));
    try testing.expect(Command.repeats(.{ .focus_direction = .left }));
    try testing.expect(Command.repeats(.move_focused_previous));
    try testing.expect(Command.repeats(.{ .move_focused_direction = .down }));
    try testing.expect(!Command.repeats(.{ .close = .focused }));
    try testing.expect(!Command.repeats(.{ .toggle_fullscreen = .focused }));
    try testing.expect(!Command.repeats(.{ .switch_workspace = 1 }));
    try testing.expect(!Command.repeats(.{ .move_to_workspace = 1 }));
}
