//! Public Zig module for libkeywork.

pub const event_loop = @import("event_loop.zig");
pub const desktop_settings = @import("desktop_settings.zig");
pub const icon_theme = @import("icon_theme.zig");
pub const svg_icon = @import("svg_icon.zig");
pub const wayland_shm = @import("wayland_shm.zig");
pub const wayland_vulkan = @import("wayland_vulkan.zig");

pub const wl_display = opaque {};
pub const wl_surface = opaque {};

const core = @import("core.zig");
const app_runner = @import("app_runner.zig");

pub const Color = core.Color;
pub const colors = core.colors;
pub const Theme = core.Theme;
pub const Brightness = core.Brightness;
pub const ColorScheme = core.ColorScheme;
pub const TextStyle = core.TextStyle;
pub const ResolvedTextStyle = core.ResolvedTextStyle;
pub const TextRole = core.TextRole;
pub const TextTheme = core.TextTheme;
pub const ButtonTheme = core.ButtonTheme;
pub const InputTheme = core.InputTheme;
pub const InteractionState = core.InteractionState;
pub const FocusNode = core.FocusNode;
pub const widgets = core.widgets;
pub const Size = core.Size;
pub const Point = core.Point;
pub const Rect = core.Rect;
pub const EdgeInsets = core.EdgeInsets;
pub const Constraints = core.Constraints;
pub const Widget = core.Widget;
pub const BuildScope = core.BuildScope;
pub const AppContext = core.AppContext;
pub const AppHost = core.AppHost;
pub const Element = core.Element;
pub const RenderNode = core.RenderNode;
pub const PaintCommand = core.PaintCommand;
pub const DisplayList = core.DisplayList;
pub const RenderBackend = core.RenderBackend;
pub const TextMeasurer = core.TextMeasurer;
pub const LogBackend = core.LogBackend;
pub const KeyInput = core.KeyInput;
pub const ShortcutKey = core.ShortcutKey;
pub const Intent = core.Intent;
pub const CursorShape = core.CursorShape;
pub const PointerButtonState = core.PointerButtonState;
pub const LayerShellOptions = core.LayerShellOptions;
pub const ClickHit = core.ClickHit;
pub const FocusTarget = core.FocusTarget;
pub const buildRenderTreeFromElement = core.buildRenderTreeFromElement;
pub const buildElementTree = core.buildElementTree;
pub const buildElementTreeScoped = core.buildElementTreeScoped;
pub const updateElementTree = core.updateElementTree;
pub const updateElementTreeScoped = core.updateElementTreeScoped;
pub const destroyElementTree = core.destroyElementTree;
pub const paint = core.paint;
pub const paintScaled = core.paintScaled;
pub const collectDamage = core.collectDamage;
pub const hitTestButton = core.hitTestButton;
pub const hitTestClick = core.hitTestClick;
pub const hitTestTextInput = core.hitTestTextInput;
pub const hitTestCursorShape = core.hitTestCursorShape;
pub const shortcutKeyForInput = core.shortcutKeyForInput;
pub const findShortcutAction = core.findShortcutAction;
pub const findFocusedShortcutAction = core.findFocusedShortcutAction;
pub const collectFocusTargets = core.collectFocusTargets;
pub const findFocusTarget = core.findFocusTarget;

pub const Runtime = @import("runtime.zig").Runtime;
pub const BackendKind = app_runner.BackendKind;
pub const EventSourceInstaller = app_runner.EventSourceInstaller;
pub const RunOptions = app_runner.Options;
pub const run = app_runner.run;

test {
    _ = @import("core.zig");
    _ = @import("desktop_settings.zig");
    _ = @import("event_loop.zig");
    _ = @import("icon_theme.zig");
    _ = @import("runtime.zig");
    _ = @import("text_renderer.zig");
    _ = @import("wayland_shm.zig");
    _ = @import("wayland_vulkan.zig");
}
