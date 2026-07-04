//! Public Zig module for libkeywork.

pub const event_loop = @import("event_loop.zig");
pub const desktop_settings = @import("desktop_settings.zig");
pub const wayland_shm = @import("wayland_shm.zig");
pub const wayland_vulkan = @import("wayland_vulkan.zig");

pub const wl_display = opaque {};
pub const wl_surface = opaque {};

const core = @import("core.zig");
const app_runner = @import("app_runner.zig");

pub const Color = core.Color;
pub const colors = core.colors;
pub const widgets = core.widgets;
pub const Size = core.Size;
pub const Point = core.Point;
pub const Rect = core.Rect;
pub const EdgeInsets = core.EdgeInsets;
pub const Constraints = core.Constraints;
pub const Widget = core.Widget;
pub const AppContext = core.AppContext;
pub const AppHost = core.AppHost;
pub const Element = core.Element;
pub const RenderObjectNode = core.RenderObjectNode;
pub const RenderNode = core.RenderNode;
pub const PaintCommand = core.PaintCommand;
pub const DisplayList = core.DisplayList;
pub const RenderBackend = core.RenderBackend;
pub const TextMeasurer = core.TextMeasurer;
pub const LogBackend = core.LogBackend;
pub const KeyInput = core.KeyInput;
pub const CursorShape = core.CursorShape;
pub const ClickHit = core.ClickHit;
pub const buildRenderTree = core.buildRenderTree;
pub const buildRenderTreeMeasured = core.buildRenderTreeMeasured;
pub const buildRenderTreeFromElement = core.buildRenderTreeFromElement;
pub const buildElementTree = core.buildElementTree;
pub const updateElementTree = core.updateElementTree;
pub const destroyElementTree = core.destroyElementTree;
pub const buildRenderObjectTree = core.buildRenderObjectTree;
pub const updateRenderObjectTree = core.updateRenderObjectTree;
pub const destroyRenderObjectTree = core.destroyRenderObjectTree;
pub const destroyRenderTree = core.destroyRenderTree;
pub const paint = core.paint;
pub const hitTestButton = core.hitTestButton;
pub const hitTestClick = core.hitTestClick;
pub const hitTestTextInput = core.hitTestTextInput;
pub const hitTestCursorShape = core.hitTestCursorShape;

pub const Runtime = @import("runtime.zig").Runtime;
pub const BackendKind = app_runner.BackendKind;
pub const RunOptions = app_runner.Options;
pub const run = app_runner.run;
