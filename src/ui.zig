//! Language-neutral declarative UI model used by the public Zig API.
//!
//! Widgets are borrowed descriptions. `Surface.submit` copies the complete
//! tree, so callers may build it from stack values or short-lived arenas.

const core = @import("core.zig");

pub const Widget = core.Widget;
pub const HandlerId = core.HandlerId;
pub const DocumentId = core.DocumentId;
pub const ResourceId = core.ResourceId;
pub const TextRole = core.TextRole;
pub const CrossAlignment = Widget.CrossAxisAlignment;
pub const MainAlignment = Widget.MainAxisAlignment;
pub const Alignment = Widget.Alignment;
pub const FlexFit = Widget.FlexFit;
pub const Activation = Widget.ClickActivation;
pub const ScrollAxes = Widget.ScrollAxes;
pub const ShortcutKey = core.ShortcutKey;
pub const TextStyle = core.TextStyle;
pub const Color = core.Color;
pub const EdgeInsets = core.EdgeInsets;

pub fn text(value: []const u8) Widget {
    return .{ .text = .{ .value = value } };
}

pub fn row(children: []const Widget) Widget {
    return .{ .row = .{ .children = children } };
}

pub fn column(children: []const Widget) Widget {
    return .{ .column = .{ .children = children } };
}

pub fn button(id: []const u8, handler: ?HandlerId, child: *const Widget) Widget {
    return .{ .button = .{ .id = id, .handler = handler, .child = child } };
}
