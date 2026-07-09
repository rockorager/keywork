//! Wayland backend-specific options.

pub const LayerShellOptions = struct {
    namespace: [:0]const u8 = "keywork",
    layer: Layer = .top,
    anchors: AnchorSet = .{},
    exclusive_zone: i32 = 0,
    margin: Margin = .{},
    keyboard_interactivity: KeyboardInteractivity = .none,
    output: Output = .compositor_default,

    pub const Layer = enum {
        background,
        bottom,
        top,
        overlay,
    };

    pub const AnchorSet = packed struct {
        top: bool = false,
        bottom: bool = false,
        left: bool = false,
        right: bool = false,
    };

    pub const Margin = struct {
        top: i32 = 0,
        right: i32 = 0,
        bottom: i32 = 0,
        left: i32 = 0,
    };

    pub const KeyboardInteractivity = enum {
        none,
        exclusive,
        on_demand,
    };

    pub const Output = enum {
        compositor_default,
        all,
    };
};

/// Snapshot of one output's identity and geometry for window placement
/// and app-side output iteration.
pub const OutputInfo = struct {
    name: []const u8,
    /// Logical size: pixel mode divided by the integer scale. Zero until
    /// the compositor reports a mode.
    width: f32,
    height: f32,
    scale: f32,
};
