//! Keywork's toolkit core: declarative widgets, layout, rendering, input,
//! and Wayland surface management. The keywork runtime embeds this module
//! and owns the process event loop; Lua applications sit on top of the
//! runtime.

const core = @import("core.zig");
const context = @import("context.zig");

pub const ui = @import("ui.zig");

pub const Context = context.Context;
pub const ContextOptions = context.ContextOptions;
pub const Surface = context.Surface;
pub const SurfaceId = context.SurfaceId;
pub const SurfaceOptions = context.SurfaceOptions;
pub const Backend = context.Backend;
pub const LayerShellOptions = context.LayerShellOptions;
pub const Event = context.Event;
pub const ColorScheme = context.ColorScheme;

pub const Color = core.Color;
pub const Theme = core.Theme;
pub const ThemeColorScheme = core.ColorScheme;
pub const Widget = core.Widget;
pub const HandlerId = core.HandlerId;
pub const DocumentId = core.DocumentId;
pub const ResourceId = core.ResourceId;
pub const colors = core.colors;
pub const EdgeInsets = core.EdgeInsets;

test {
    _ = @import("appearance.zig");
    _ = @import("context.zig");
    _ = @import("core.zig");
    _ = @import("dbus_adapter.zig");
    _ = @import("desktop_settings.zig");
    _ = @import("document.zig");
    _ = @import("event_loop.zig");
    _ = @import("icon_render.zig");
    _ = @import("icon_theme.zig");
    _ = @import("image_render.zig");
    _ = @import("resources.zig");
    _ = @import("runtime.zig");
    _ = @import("text_renderer.zig");
    _ = @import("wayland_shm.zig");
}
