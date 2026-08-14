//! Widgets, retained element/render trees, layout, painting, and hit testing.

const std = @import("std");
const types = @import("types.zig");
const display = @import("display.zig");
const animation = @import("animation.zig");
const damage_region = @import("damage_region.zig");

pub const Color = types.Color;
pub const ShadowLayer = types.ShadowLayer;
pub const BoxShadow = types.BoxShadow;
pub const colors = types.colors;
pub const scale = types.scale;
pub const TextStyle = types.TextStyle;
pub const ResolvedTextStyle = types.ResolvedTextStyle;
pub const TextRole = types.TextRole;
pub const Theme = types.Theme;
pub const InteractionState = types.InteractionState;
pub const ShortcutKey = types.ShortcutKey;
pub const Intent = types.Intent;
pub const FocusNode = types.FocusNode;
pub const Size = types.Size;
pub const Point = types.Point;
pub const Rect = types.Rect;
pub const DamageRegion = damage_region.DamageRegion;
pub const EdgeInsets = types.EdgeInsets;
pub const Constraints = types.Constraints;
pub const KeyInput = types.KeyInput;
pub const CursorShape = types.CursorShape;
pub const PointerButtonEvent = types.PointerButtonEvent;
pub const PointerButton = types.PointerButton;
pub const PointerButtons = types.PointerButtons;
pub const TapEvent = types.TapEvent;
pub const ScrollEvent = types.ScrollEvent;
pub const DisplayList = display.DisplayList;
pub const RasterCache = display.RasterCache;
pub const RenderBackend = display.RenderBackend;
pub const TextMeasurer = display.TextMeasurer;

pub const LayoutError = anyerror;

pub const Widget = union(enum) {
    keyed: Keyed,
    text: Text,
    box: Box,
    clickable: Clickable,
    anchored: Anchored,
    focus: Focus,
    focus_scope: FocusScope,
    scroll: Scroll,
    list: List,
    text_input: TextInput,
    separator: Separator,
    spinner: Spinner,
    row: Children,
    column: Children,
    spacer: Spacer,
    flexible: Flexible,
    sized: Sized,
    padding: Padding,
    center: Child,
    actions: Actions,
    shortcuts: Shortcuts,
    theme: ThemeWidget,
    default_text_style: DefaultTextStyle,
    component: Component,
    stateful: Stateful,
    element: CustomElement,
    render_object: RenderObject,

    pub fn alloc(allocator: std.mem.Allocator, widget: Widget) !*Widget {
        const result = try allocator.create(Widget);
        result.* = widget;
        return result;
    }

    pub fn allocSlice(allocator: std.mem.Allocator, items: []const Widget) ![]Widget {
        return allocator.dupe(Widget, items);
    }

    pub const Key = union(enum) {
        string: []const u8,
        integer: u64,
    };

    pub const Keyed = struct {
        key: Key,
        child: *const Widget,
    };

    pub const Text = struct {
        value: []const u8,
        color: ?Color = null,
        font_size: ?f32 = null,
        line_height: ?f32 = null,
        role: TextRole = .body,
        max_lines: ?u32 = null,
        overflow: TextOverflow = .ellipsis,
        line_break: LineBreakStrategy = .greedy,
    };

    pub const TextOverflow = enum {
        ellipsis,
        clip,
    };

    pub const LineBreakStrategy = enum {
        greedy,
        knuth_plass,
    };

    pub const Box = struct {
        child: *const Widget,
        background: Color = colors.transparent,
        border: ?Color = null,
        border_width: f32 = 1,
        radius: f32 = 0,
        shadow: ?BoxShadow = null,
        min_width: f32 = 0,
        min_height: f32 = 0,
        horizontal_align: Alignment = .start,
        vertical_align: Alignment = .start,
    };

    pub const Clickable = struct {
        id: []const u8,
        child: *const Widget,
        on_click: ?TapCallback = null,
        intent: ?Intent = null,
        on_tap_down: ?TapCallback = null,
        on_tap_up: ?TapCallback = null,
        on_tap_cancel: ?TapCallback = null,
        on_scroll: ?ScrollEventCallback = null,
        /// Fires with true when the pointer enters this widget and false
        /// when it leaves. Driven only by real pointer motion, so content
        /// scrolling beneath a stationary pointer does not re-fire it.
        on_hover_change: ?FocusChangeCallback = null,
        buttons: PointerButtons = .{},
        /// Release waits for pointer-up over the same target so a press can
        /// be aborted by dragging off; press is an explicit opt-in for
        /// controls that must activate immediately on pointer-down.
        activation: ClickActivation = .release,
        hover_style: ?ClickableStyle = null,
        pressed_style: ?ClickableStyle = null,
        focused_border: ?Color = null,
        focused_border_width: f32 = 2,
        cursor: CursorShape = .default,
    };

    pub const ClickableStyle = struct {
        background: ?Color = null,
        base_background: ?Color = null,
    };

    pub const ClickActivation = enum {
        release,
        press,
    };

    /// Declares that a popup surface may hang off this widget's laid-out
    /// rect. The inline child renders normally; when `popup` is non-null
    /// the host is expected to realize it as a separate surface anchored
    /// to this widget. Popup existence is state-driven: builds that omit
    /// `popup` dismiss it.
    pub const Anchored = struct {
        id: []const u8,
        child: *const Widget,
        popup: ?Popup = null,
    };

    pub const Popup = struct {
        builder: PopupBuilder,
        placement: PopupPlacement = .{},
        /// Explicit size overrides; content is measured when null.
        width: ?f32 = null,
        height: ?f32 = null,
        /// Fired when the host dismisses the popup (for example Escape or a
        /// compositor grab break), so app state can drop the declaration.
        on_close: ?Callback = null,

        pub fn clone(self: Popup, allocator: std.mem.Allocator) !Popup {
            const builder = try self.builder.clone(allocator);
            errdefer builder.destroy(allocator);
            const on_close = if (self.on_close) |callback| try callback.clone(allocator) else null;
            return .{
                .builder = builder,
                .placement = self.placement,
                .width = self.width,
                .height = self.height,
                .on_close = on_close,
            };
        }

        pub fn destroy(self: Popup, allocator: std.mem.Allocator) void {
            if (self.on_close) |callback| callback.destroy(allocator);
            self.builder.destroy(allocator);
        }
    };

    pub const PopupPlacement = struct {
        /// Edge of the anchor rect the popup attaches to.
        edge: Edge = .bottom,
        /// How the popup lines up along that edge.
        alignment: Alignment = .start,
        /// Gap in logical pixels between the anchor edge and the popup.
        gap: f32 = 0,

        pub const Edge = enum {
            top,
            bottom,
            left,
            right,
        };
    };

    /// Builds popup content on demand so each realization of the popup
    /// (initial surface creation and subsequent rebuilds) gets a fresh
    /// widget tree instead of sharing one retained subtree.
    pub const PopupBuilder = struct {
        ptr: *const anyopaque,
        build_fn: *const fn (ptr: *const anyopaque, scope: *BuildScope, context: BuildContext) anyerror!Widget,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) anyerror!*const anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) void = null,

        pub fn build(self: PopupBuilder, scope: *BuildScope, context: BuildContext) !Widget {
            return self.build_fn(self.ptr, scope, context);
        }

        pub fn clone(self: PopupBuilder, allocator: std.mem.Allocator) !PopupBuilder {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .build_fn = self.build_fn,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: PopupBuilder, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    pub const Focus = struct {
        node: FocusNode,
        child: *const Widget,
        autofocus: bool = false,
        skip_traversal: bool = false,
        can_request_focus: bool = true,
        on_focus_change: ?FocusChangeCallback = null,
    };

    pub const FocusScope = struct {
        id: []const u8,
        child: *const Widget,
        modal: bool = false,
    };

    pub const ActionBinding = struct {
        id: []const u8,
        callback: Callback,
        invoke: ?ActionCallback = null,
        input_schema_json: ?[]const u8 = null,
    };

    pub const ShortcutBinding = struct {
        key: ShortcutKey,
        intent: Intent,
    };

    pub const Actions = struct {
        bindings: []const ActionBinding,
        child: *const Widget,
    };

    pub const Shortcuts = struct {
        bindings: []const ShortcutBinding,
        child: *const Widget,
    };

    /// A scrollable viewport: the child is laid out unbounded along the
    /// scrollable axes, clipped to the viewport, and offset by the
    /// element-owned scroll position. Scrollbars are painted for axes with
    /// overflowing content.
    pub const Scroll = struct {
        id: []const u8,
        child: *const Widget,
        axes: ScrollAxes = .vertical,
        scrollbar_track_color: ?Color = null,
        scrollbar_color: ?Color = null,
    };

    /// A virtualized vertical list: only the items visible in the viewport
    /// (plus a small buffer) are built as elements. A supplied item extent is
    /// the fixed-height fast path; otherwise child heights are measured and
    /// estimated lazily. Item state does not survive scrolling out of the
    /// built window.
    pub const List = struct {
        id: []const u8,
        item_count: usize,
        /// Fixed item height fast path. Null measures children lazily and
        /// caches their individual extents, like Flutter's ListView.builder.
        item_extent: ?f32,
        build_item: ItemBuilder,
        /// Controlled selection: when set and changed since the last
        /// layout, the list scrolls the minimum distance to bring the
        /// item fully into view. Selection state itself lives in the app.
        selected: ?usize = null,
        /// Follow appended items while the viewport is already at the end.
        /// Scrolling away from the end suspends following until the user
        /// returns there.
        follow_end: bool = false,
        scrollbar_track_color: ?Color = null,
        scrollbar_color: ?Color = null,
    };

    pub const ItemBuilder = struct {
        ptr: *const anyopaque,
        build_fn: *const fn (ptr: *const anyopaque, scope: *BuildScope, index: usize) anyerror!Widget,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) anyerror!*const anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) void = null,

        pub fn build(self: ItemBuilder, scope: *BuildScope, index: usize) !Widget {
            return self.build_fn(self.ptr, scope, index);
        }

        pub fn clone(self: ItemBuilder, allocator: std.mem.Allocator) !ItemBuilder {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .build_fn = self.build_fn,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: ItemBuilder, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    pub const ScrollAxes = enum {
        vertical,
        horizontal,
        both,

        pub fn horizontalUnbounded(self: ScrollAxes) bool {
            return self != .vertical;
        }

        pub fn verticalUnbounded(self: ScrollAxes) bool {
            return self != .horizontal;
        }
    };

    pub const TextInput = struct {
        id: []const u8,
        focus_node: FocusNode,
        /// Initial text only: after the element is created, its editing
        /// state owns the text.
        value: []const u8,
        placeholder: []const u8,
        on_change: ?TextChangeCallback = null,
        on_submit: ?TextChangeCallback = null,
        obscured: bool = false,
        clear_on_submit: bool = false,
        foreground: Color = colors.ink,
        background: Color = colors.transparent,
        border: Color = colors.transparent,
        focused_border: Color = colors.transparent,
        placeholder_foreground: Color = colors.neutral10,
        padding_x: f32 = 0,
        padding_y: f32 = 0,
        radius: f32 = 0,
        font_size: f32 = 16,
        line_height: f32 = 20,
        autofocus: bool = false,
        style: Style = .{},

        pub const Style = struct {
            foreground: ?Color = null,
            background: ?Color = null,
            border: ?Color = null,
            focused_border: ?Color = null,
            placeholder_foreground: ?Color = null,
            padding_x: ?f32 = null,
            padding_y: ?f32 = null,
            radius: ?f32 = null,
            font_size: ?f32 = null,
            line_height: ?f32 = null,
        };
    };

    pub const Separator = struct {
        color: ?Color = null,
        thickness: f32 = 1,
        margin: f32 = 0,
        axis: Axis = .horizontal,

        pub const Axis = enum { horizontal, vertical };
    };

    /// Indeterminate activity indicator: a ring of dots whose highlight
    /// sweeps once per period. Its presence keeps per-frame demand
    /// registered, so it only belongs in trees doing visible work.
    pub const Spinner = struct {
        size: f32 = scale.space(4),
        color: ?Color = null,
        period_ms: u32 = 800,
    };

    pub const Children = struct {
        children: []const Widget,
        gap: f32 = 0,
        cross_align: CrossAxisAlignment = .start,
        main_align: MainAxisAlignment = .start,
    };

    pub const CrossAxisAlignment = enum {
        start,
        center,
        end,
        stretch,
        /// Rows only: align children that expose a first-line text baseline.
        /// Layout-neutral wrappers propagate their child's baseline; children
        /// without one fall back to center alignment.
        baseline,
        /// Rows only: text children center as usual, while other children
        /// (icons) center on the first text child's cap-height midline,
        /// matching how macOS aligns symbol icons next to text. Falls back
        /// to center when the row has no text child.
        cap_center,
    };

    pub const MainAxisAlignment = enum {
        start,
        center,
        end,
        space_between,
        space_around,
        space_evenly,
    };

    /// A flex child of a row or column: after non-flex children take
    /// their intrinsic size, the remaining main-axis space is divided
    /// between flexible children in proportion to their flex factors.
    pub const Flexible = struct {
        child: *const Widget,
        flex: f32 = 1,
        /// tight forces the child to fill its share (Flutter's Expanded);
        /// loose lets it be smaller.
        fit: FlexFit = .tight,
    };

    pub const FlexFit = enum { tight, loose };

    pub const Alignment = enum {
        start,
        center,
        end,
    };

    pub const Sized = struct {
        child: *const Widget,
        width: ?f32 = null,
        height: ?f32 = null,
        min_width: f32 = 0,
        min_height: f32 = 0,
        max_width: ?f32 = null,
        max_height: ?f32 = null,
    };

    pub const Spacer = struct {
        flex: f32 = 1,
    };

    pub const Padding = struct {
        insets: EdgeInsets,
        child: *const Widget,
    };

    pub const Child = struct {
        child: *const Widget,
    };

    pub const ThemeWidget = struct {
        theme: Theme,
        child: *const Widget,
    };

    pub const DefaultTextStyle = struct {
        style: TextStyle,
        child: *const Widget,
    };

    pub const Callback = struct {
        ptr: *anyopaque,
        call_fn: *const fn (ptr: *anyopaque) anyerror!void,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) anyerror!*anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void = null,

        pub fn call(self: Callback) !void {
            try self.call_fn(self.ptr);
        }

        pub fn clone(self: Callback, allocator: std.mem.Allocator) !Callback {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .call_fn = self.call_fn,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: Callback, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    /// An action callback optionally receives the JSON target carried by an
    /// intent. It is separate from `Callback`, whose zero-argument contract
    /// is also used by lifecycle APIs.
    pub const ActionCallback = struct {
        ptr: *anyopaque,
        call_fn: *const fn (ptr: *anyopaque, target_json: ?[]const u8) anyerror!void,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) anyerror!*anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void = null,

        pub fn call(self: ActionCallback, target_json: ?[]const u8) !void {
            try self.call_fn(self.ptr, target_json);
        }

        pub fn clone(self: ActionCallback, allocator: std.mem.Allocator) !ActionCallback {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .call_fn = self.call_fn,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: ActionCallback, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    pub const ActionInvocation = struct {
        binding: ActionBinding,
        target_json: ?[]const u8,

        pub fn call(self: ActionInvocation) !void {
            if (self.binding.invoke) |invoke| {
                try invoke.call(self.target_json);
            } else {
                try self.binding.callback.call();
            }
        }
    };

    pub const FocusChangeCallback = struct {
        ptr: *anyopaque,
        call_fn: *const fn (ptr: *anyopaque, focused: bool) anyerror!void,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) anyerror!*anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void = null,

        pub fn call(self: FocusChangeCallback, focused: bool) !void {
            try self.call_fn(self.ptr, focused);
        }

        pub fn clone(self: FocusChangeCallback, allocator: std.mem.Allocator) !FocusChangeCallback {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .call_fn = self.call_fn,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: FocusChangeCallback, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    pub const TapCallback = struct {
        ptr: *anyopaque,
        call_fn: *const fn (ptr: *anyopaque, event: TapEvent) anyerror!void,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) anyerror!*anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void = null,

        pub fn call(self: TapCallback, event: TapEvent) !void {
            try self.call_fn(self.ptr, event);
        }
        pub fn clone(self: TapCallback, allocator: std.mem.Allocator) !TapCallback {
            const clone_fn = self.clone_fn orelse return self;
            return .{ .ptr = try clone_fn(allocator, self.ptr), .call_fn = self.call_fn, .clone_fn = self.clone_fn, .destroy_fn = self.destroy_fn };
        }
        pub fn destroy(self: TapCallback, allocator: std.mem.Allocator) void {
            if (self.destroy_fn) |destroy_fn| destroy_fn(allocator, self.ptr);
        }
    };

    pub const ScrollEventCallback = struct {
        ptr: *anyopaque,
        call_fn: *const fn (ptr: *anyopaque, event: ScrollEvent) anyerror!void,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) anyerror!*anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void = null,

        pub fn call(self: ScrollEventCallback, event: ScrollEvent) !void {
            try self.call_fn(self.ptr, event);
        }
        pub fn clone(self: ScrollEventCallback, allocator: std.mem.Allocator) !ScrollEventCallback {
            const clone_fn = self.clone_fn orelse return self;
            return .{ .ptr = try clone_fn(allocator, self.ptr), .call_fn = self.call_fn, .clone_fn = self.clone_fn, .destroy_fn = self.destroy_fn };
        }
        pub fn destroy(self: ScrollEventCallback, allocator: std.mem.Allocator) void {
            if (self.destroy_fn) |destroy_fn| destroy_fn(allocator, self.ptr);
        }
    };

    pub const TextChangeCallback = struct {
        ptr: *anyopaque,
        call_fn: *const fn (ptr: *anyopaque, text: []const u8) anyerror!void,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) anyerror!*anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void = null,

        pub fn call(self: TextChangeCallback, text: []const u8) !void {
            try self.call_fn(self.ptr, text);
        }

        pub fn clone(self: TextChangeCallback, allocator: std.mem.Allocator) !TextChangeCallback {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .call_fn = self.call_fn,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: TextChangeCallback, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    pub const BuildContext = struct {
        constraints: Constraints,
        theme: Theme = .default,
        default_text_style: TextStyle = .{},
        interaction: InteractionState = .{},
        app_context: AppContext = .{},
    };

    pub const Component = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            build: *const fn (ptr: *const anyopaque, scope: *BuildScope, context: BuildContext) anyerror!Widget,
        };

        pub fn build(self: Component, scope: *BuildScope, context: BuildContext) !Widget {
            return self.vtable.build(self.ptr, scope, context);
        }
    };

    pub const Stateful = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) anyerror!*const anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) void = null,
        /// Identity token: two stateful widgets with different tokens are
        /// never update-compatible, so swapping widget types at the same
        /// tree position disposes the old state and creates fresh state
        /// instead of silently reusing it.
        type_token: ?*const anyopaque = null,

        pub const VTable = struct {
            create_state: *const fn (ptr: *const anyopaque, allocator: std.mem.Allocator) anyerror!*anyopaque,
            update: *const fn (ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator, context: BuildContext) anyerror!void,
            build: *const fn (ptr: *const anyopaque, state: *anyopaque, scope: *BuildScope, context: BuildContext) anyerror!Widget,
            destroy_state: *const fn (ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator) void,
            rebuild_token: ?*const fn (state: *anyopaque, force: bool) ?u64 = null,
            finish_rebuild: ?*const fn (state: *anyopaque, token: u64) void = null,
        };

        pub fn createState(self: Stateful, allocator: std.mem.Allocator) !*anyopaque {
            return self.vtable.create_state(self.ptr, allocator);
        }

        pub fn update(self: Stateful, state: *anyopaque, allocator: std.mem.Allocator, context: BuildContext) !void {
            try self.vtable.update(self.ptr, state, allocator, context);
        }

        pub fn build(self: Stateful, state: *anyopaque, scope: *BuildScope, context: BuildContext) !Widget {
            return self.vtable.build(self.ptr, state, scope, context);
        }

        pub fn destroyState(self: Stateful, state: *anyopaque, allocator: std.mem.Allocator) void {
            self.vtable.destroy_state(self.ptr, state, allocator);
        }

        pub fn rebuildToken(self: Stateful, state: *anyopaque, force: bool) ?u64 {
            const rebuild_token = self.vtable.rebuild_token orelse return null;
            return rebuild_token(state, force);
        }

        pub fn finishRebuild(self: Stateful, state: *anyopaque, token: ?u64) void {
            const value = token orelse return;
            const finish_rebuild = self.vtable.finish_rebuild orelse return;
            finish_rebuild(state, value);
        }

        pub fn clone(self: Stateful, allocator: std.mem.Allocator) !Stateful {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .vtable = self.vtable,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
                .type_token = self.type_token,
            };
        }

        pub fn destroy(self: Stateful, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    pub const CustomElement = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) anyerror!*const anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) void = null,

        pub const VTable = struct {
            build: *const fn (ptr: *const anyopaque, allocator: std.mem.Allocator, scope: *BuildScope, context: BuildContext) anyerror!Element,
        };

        pub fn build(self: CustomElement, allocator: std.mem.Allocator, scope: *BuildScope, context: BuildContext) !Element {
            return self.vtable.build(self.ptr, allocator, scope, context);
        }

        pub fn clone(self: CustomElement, allocator: std.mem.Allocator) !CustomElement {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .vtable = self.vtable,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: CustomElement, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    pub const RenderObject = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) anyerror!*const anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) void = null,

        pub const LayoutContext = struct {
            constraints: Constraints,
            measurer: TextMeasurer,
        };

        pub const PaintContext = struct {
            allocator: std.mem.Allocator,
            rect: Rect,
            scale: f32,
            display_list: *DisplayList,
            raster_cache: *RasterCache,
        };

        pub const VTable = struct {
            layout: *const fn (ptr: *const anyopaque, context: LayoutContext) anyerror!Size,
            /// Paint commands must stay within `context.rect`; partial frame
            /// generation uses that rect as the render object's paint bound.
            paint: *const fn (ptr: *const anyopaque, context: PaintContext) anyerror!void,
            /// Reports the pixels changed between two retained instances.
            /// Implementations append widget-local rectangles translated into
            /// `rect`; omitting this callback conservatively damages `rect`.
            damage: ?*const fn (old_ptr: *const anyopaque, new_ptr: *const anyopaque, rect: Rect, result: *DamageRegion) void = null,
            hit_test: ?*const fn (ptr: *const anyopaque, rect: Rect, point: Point) ?[]const u8 = null,
        };

        pub fn layout(self: RenderObject, context: LayoutContext) !Size {
            return self.vtable.layout(self.ptr, context);
        }

        pub fn paint(self: RenderObject, context: PaintContext) !void {
            try self.vtable.paint(self.ptr, context);
        }

        pub fn hitTest(self: RenderObject, rect: Rect, point: Point) ?[]const u8 {
            const hit_test = self.vtable.hit_test orelse return null;
            return hit_test(self.ptr, rect, point);
        }

        pub fn clone(self: RenderObject, allocator: std.mem.Allocator) !RenderObject {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .vtable = self.vtable,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: RenderObject, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };
};

pub const BuildScope = struct {
    allocator: std.mem.Allocator,
    theme: Theme = .default,
    default_text_style: TextStyle = .{},
    interaction: InteractionState = .{},
    actions: ?*const ActionScope = null,
    app_context: AppContext = .{},
    /// The runtime that owns this build. Stateful widgets retain this
    /// callback so a local state change dirties only its own runtime.
    state_invalidator: ?Widget.Callback = null,
    /// Render scale of the runtime driving this build, so scale-dependent
    /// asset choices (e.g. icon rasterization) match the target window.
    render_scale: f32 = 1,
};

pub const ActionScope = struct {
    bindings: []const Widget.ActionBinding,
    parent: ?*const ActionScope = null,
};

pub const widgets = struct {
    pub fn text(value: []const u8) Widget {
        return .{ .text = .{ .value = value } };
    }

    pub fn clickable(allocator: std.mem.Allocator, id: []const u8, child: Widget, on_click: ?Widget.TapCallback) !Widget {
        return .{ .clickable = .{ .id = id, .child = try Widget.alloc(allocator, child), .on_click = on_click } };
    }

    pub fn focus(allocator: std.mem.Allocator, node: FocusNode, child: Widget) !Widget {
        return focusWithOptions(allocator, node, child, .{});
    }

    pub const FocusOptions = struct {
        autofocus: bool = false,
        skip_traversal: bool = false,
        can_request_focus: bool = true,
        on_focus_change: ?Widget.FocusChangeCallback = null,
    };

    pub fn focusWithOptions(allocator: std.mem.Allocator, node: FocusNode, child: Widget, options: FocusOptions) !Widget {
        return .{ .focus = .{
            .node = node,
            .child = try Widget.alloc(allocator, child),
            .autofocus = options.autofocus,
            .skip_traversal = options.skip_traversal,
            .can_request_focus = options.can_request_focus,
            .on_focus_change = options.on_focus_change,
        } };
    }

    pub fn focusScope(allocator: std.mem.Allocator, id: []const u8, child: Widget) !Widget {
        return focusScopeWithOptions(allocator, id, child, .{});
    }

    pub const FocusScopeOptions = struct {
        modal: bool = false,
    };

    pub fn focusScopeWithOptions(allocator: std.mem.Allocator, id: []const u8, child: Widget, options: FocusScopeOptions) !Widget {
        return .{ .focus_scope = .{ .id = id, .child = try Widget.alloc(allocator, child), .modal = options.modal } };
    }

    pub fn scroll(allocator: std.mem.Allocator, id: []const u8, child: Widget) !Widget {
        return .{ .scroll = .{ .id = id, .child = try Widget.alloc(allocator, child) } };
    }

    pub fn list(id: []const u8, item_count: usize, item_extent: ?f32, build_item: Widget.ItemBuilder) Widget {
        return .{ .list = .{ .id = id, .item_count = item_count, .item_extent = item_extent, .build_item = build_item } };
    }

    pub fn theme(allocator: std.mem.Allocator, theme_value: Theme, child: Widget) !Widget {
        return .{ .theme = .{ .theme = theme_value, .child = try Widget.alloc(allocator, child) } };
    }

    pub fn defaultTextStyle(allocator: std.mem.Allocator, style: TextStyle, child: Widget) !Widget {
        return .{ .default_text_style = .{ .style = style, .child = try Widget.alloc(allocator, child) } };
    }

    pub fn textInput(id: []const u8, value: []const u8, placeholder: []const u8) Widget {
        return .{ .text_input = .{ .id = id, .focus_node = .named(id), .value = value, .placeholder = placeholder } };
    }

    pub fn textInputWithFocusNode(id: []const u8, focus_node: FocusNode, value: []const u8, placeholder: []const u8) Widget {
        return .{ .text_input = .{ .id = id, .focus_node = focus_node, .value = value, .placeholder = placeholder } };
    }

    pub const LinearOptions = struct {
        gap: f32 = 0,
        cross_align: Widget.CrossAxisAlignment = .start,
        main_align: Widget.MainAxisAlignment = .start,
    };

    pub fn expandedFlex(allocator: std.mem.Allocator, child: Widget, flex: f32) !Widget {
        return .{ .flexible = .{ .child = try Widget.alloc(allocator, child), .flex = flex, .fit = .tight } };
    }

    pub fn flexible(allocator: std.mem.Allocator, child: Widget, flex: f32) !Widget {
        return .{ .flexible = .{ .child = try Widget.alloc(allocator, child), .flex = flex, .fit = .loose } };
    }

    pub fn rowWithOptions(allocator: std.mem.Allocator, children: []const Widget, options: LinearOptions) !Widget {
        return .{ .row = .{
            .children = try Widget.allocSlice(allocator, children),
            .gap = options.gap,
            .cross_align = options.cross_align,
            .main_align = options.main_align,
        } };
    }

    pub fn row(allocator: std.mem.Allocator, children: []const Widget, gap: f32) !Widget {
        return .{ .row = .{ .children = try Widget.allocSlice(allocator, children), .gap = gap } };
    }

    pub fn column(allocator: std.mem.Allocator, children: []const Widget, gap: f32) !Widget {
        return .{ .column = .{ .children = try Widget.allocSlice(allocator, children), .gap = gap } };
    }

    pub fn spacer(flex: f32) Widget {
        return .{ .spacer = .{ .flex = @max(0, flex) } };
    }

    pub fn spinner(options: Widget.Spinner) Widget {
        return .{ .spinner = options };
    }

    pub fn sized(allocator: std.mem.Allocator, child: Widget, width: ?f32, height: ?f32) !Widget {
        return .{ .sized = .{ .child = try Widget.alloc(allocator, child), .width = width, .height = height } };
    }

    pub fn padding(allocator: std.mem.Allocator, insets: EdgeInsets, child: Widget) !Widget {
        return .{ .padding = .{ .insets = insets, .child = try Widget.alloc(allocator, child) } };
    }

    pub fn actions(allocator: std.mem.Allocator, bindings: []const Widget.ActionBinding, child: Widget) !Widget {
        return .{ .actions = .{ .bindings = try allocator.dupe(Widget.ActionBinding, bindings), .child = try Widget.alloc(allocator, child) } };
    }

    pub fn shortcuts(allocator: std.mem.Allocator, bindings: []const Widget.ShortcutBinding, child: Widget) !Widget {
        return .{ .shortcuts = .{ .bindings = try allocator.dupe(Widget.ShortcutBinding, bindings), .child = try Widget.alloc(allocator, child) } };
    }
};

pub const Element = struct {
    kind: Kind,
    widget: Widget,
    key: ?Widget.Key = null,
    state: ?*anyopaque = null,
    focused: bool = false,
    render_node: ?*RenderNode = null,
    children: []Element = &.{},

    pub const Kind = enum {
        keyed,
        text,
        box,
        clickable,
        anchored,
        focus,
        focus_scope,
        scroll,
        list,
        text_input,
        separator,
        spinner,
        row,
        column,
        spacer,
        flexible,
        sized,
        padding,
        center,
        actions,
        shortcuts,
        theme,
        default_text_style,
        component,
        stateful,
        element,
        render_object,
    };
};

const ActionTapAdapter = struct {
    invocation: Widget.ActionInvocation,
    owned_target_json: ?[]const u8,
};

fn callActionAsTap(ptr: *anyopaque, _: TapEvent) !void {
    const adapter: *ActionTapAdapter = @ptrCast(@alignCast(ptr));
    try adapter.invocation.call();
}

fn cloneActionAdapter(allocator: std.mem.Allocator, ptr: *anyopaque) !*anyopaque {
    const original: *ActionTapAdapter = @ptrCast(@alignCast(ptr));
    const copy = try allocator.create(ActionTapAdapter);
    errdefer allocator.destroy(copy);
    copy.* = original.*;
    copy.owned_target_json = if (original.owned_target_json) |target| try allocator.dupe(u8, target) else null;
    copy.invocation.target_json = copy.owned_target_json;
    return copy;
}

fn destroyActionAdapter(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const stored: *ActionTapAdapter = @ptrCast(@alignCast(ptr));
    if (stored.owned_target_json) |target| allocator.free(target);
    allocator.destroy(stored);
}

fn resolveClickableIntent(allocator: std.mem.Allocator, actions: ?*const ActionScope, clickable: *Widget.Clickable) !void {
    if (clickable.on_click != null) return;
    const intent = clickable.intent orelse return;
    const action = findActionForIntent(actions, intent) orelse return;
    const stored = try allocator.create(ActionTapAdapter);
    errdefer allocator.destroy(stored);
    const target_json = if (intent.target_json) |target| try allocator.dupe(u8, target) else null;
    stored.* = .{
        .invocation = .{ .binding = action.binding, .target_json = target_json },
        .owned_target_json = target_json,
    };
    clickable.on_click = .{
        .ptr = stored,
        .call_fn = callActionAsTap,
        .clone_fn = cloneActionAdapter,
        .destroy_fn = destroyActionAdapter,
    };
}

fn defaultResolvedTextStyle() ResolvedTextStyle {
    return .{ .color = colors.ink, .font_size = scale.fontSize(3) };
}

fn roleTextStyle(theme: Theme, role: TextRole) TextStyle {
    return switch (role) {
        .body => theme.text_theme.body,
        .label => theme.text_theme.label,
        .title => theme.text_theme.title,
    };
}

fn mergeTextStyle(base: TextStyle, overlay: TextStyle) TextStyle {
    return .{
        .color = overlay.color orelse base.color,
        .font_size = overlay.font_size orelse base.font_size,
        .line_height = overlay.line_height orelse if (overlay.font_size != null) null else base.line_height,
    };
}

fn resolveTextStyle(theme: Theme, inherited_style: TextStyle, text_widget: Widget.Text) ResolvedTextStyle {
    const role_style = roleTextStyle(theme, text_widget.role);
    const line_height = text_widget.line_height orelse
        if (text_widget.font_size != null)
            null
        else
            inherited_style.line_height orelse if (inherited_style.font_size != null) null else role_style.line_height;
    return .{
        .color = text_widget.color orelse inherited_style.color orelse role_style.color orelse theme.color_scheme.foreground,
        .font_size = text_widget.font_size orelse inherited_style.font_size orelse role_style.font_size orelse scale.fontSize(3),
        .line_height = line_height,
    };
}

pub const RenderNode = struct {
    kind: Kind,
    rect: Rect,
    text: ?[]const u8 = null,
    text_buffer: std.ArrayList(u8) = .empty,
    text_buffered: bool = false,
    text_style: ResolvedTextStyle = defaultResolvedTextStyle(),
    clickable_id: ?[]const u8 = null,
    click_callback: ?Widget.TapCallback = null,
    tap_down_callback: ?Widget.TapCallback = null,
    tap_up_callback: ?Widget.TapCallback = null,
    tap_cancel_callback: ?Widget.TapCallback = null,
    scroll_event_callback: ?Widget.ScrollEventCallback = null,
    hover_change_callback: ?Widget.FocusChangeCallback = null,
    click_buttons: PointerButtons = .{},
    click_activation: Widget.ClickActivation = .release,
    click_cursor: CursorShape = .default,
    text_input_id: ?[]const u8 = null,
    focus_id: ?[]const u8 = null,
    focus_scope_id: ?[]const u8 = null,
    modal_focus_scope: bool = false,
    scroll_id: ?[]const u8 = null,
    scroll_content: Size = .{ .width = 0, .height = 0 },
    scroll_offset: Point = .{ .x = 0, .y = 0 },
    scrollbar_track_color: Color = colors.transparent,
    scrollbar_color: Color = colors.scrollbar_light,
    autofocus: bool = false,
    skip_traversal: bool = false,
    can_request_focus: bool = true,
    focus_change_callback: ?Widget.FocusChangeCallback = null,
    render_object: ?Widget.RenderObject = null,
    foreground: Color = colors.ink,
    background: Color = colors.transparent,
    box_border: ?Color = null,
    box_border_width: f32 = 1,
    box_radius: f32 = 0,
    box_shadow: ?BoxShadow = null,
    separator_axis: Widget.Separator.Axis = .horizontal,
    separator_margin: f32 = 0,
    /// Scrollbar opacity for viewport nodes, copied from the scroll
    /// state at layout and written directly by animation ticks between
    /// layouts. Zero hides the scrollbar from painting and pointer hits.
    scrollbar_alpha: f32 = 1,
    /// Sweep phase of a spinner node in 0..1.
    spinner_progress: f32 = 0,
    placeholder: ?[]const u8 = null,
    border: Color = colors.ink,
    focused_border: Color = colors.accent,
    placeholder_foreground: Color = colors.neutral10,
    padding_x: f32 = 0,
    padding_y: f32 = 0,
    focused: bool = false,
    caret_x: ?f32 = null,
    /// Constraints this node was last laid out with; cached so clean
    /// subtrees can be skipped when re-laid out with identical inputs.
    constraints: Constraints = .{ .max_width = 0, .max_height = 0 },
    needs_layout: bool = true,
    /// Whether this node's painted payload changed since its last layout.
    /// Kept separate from layout dirtiness so a semantically identical
    /// rebuild does not manufacture damage merely by re-running layout.
    needs_paint: bool = true,
    /// Conservative bounds of this subtree's paint. Layout stores this
    /// separately from `rect` because descendants and glyphs may overhang
    /// layout geometry. Viewports clip it to their rect.
    paint_bounds: ?Rect = null,
    /// Paint damage accumulated since the last collection. A bounded region
    /// preserves normal disjoint updates without per-node allocations.
    damage: DamageRegion = .{},
    /// Render-object damage can be computed while both old and new widget
    /// payloads are alive, before the old retained widget is destroyed.
    paint_damage_precomputed: bool = false,
    /// Child nodes are owned by the corresponding child elements; this
    /// slice only borrows them and is refreshed on every layout.
    children: []*RenderNode = &.{},

    pub const Kind = enum {
        keyed,
        text,
        box,
        clickable,
        anchored,
        focus,
        focus_scope,
        scroll,
        list,
        text_input,
        separator,
        spinner,
        row,
        column,
        spacer,
        flexible,
        sized,
        padding,
        center,
        actions,
        shortcuts,
        theme,
        default_text_style,
        component,
        stateful,
        element,
        render_object,

        pub fn isViewport(self: Kind) bool {
            return self == .scroll or self == .list;
        }
    };

    /// Returns retained paint bounds, deriving them for manually constructed
    /// nodes used by embedders and tests that have not passed through layout.
    pub fn paintBounds(self: *const RenderNode) ?Rect {
        return self.paint_bounds orelse self.derivePaintBounds();
    }

    pub fn derivePaintBounds(self: *const RenderNode) ?Rect {
        return self.derivePaintBoundsForChildren(self.children);
    }

    pub fn derivePaintBoundsForChildren(self: *const RenderNode, children: []const *RenderNode) ?Rect {
        var bounds = unionPaintBounds(null, self.deriveOwnPaintBounds());
        for (children) |child| bounds = unionPaintBounds(bounds, child.paintBounds());
        if (self.kind.isViewport()) {
            if (bounds) |value| {
                const clipped = value.intersect(self.rect);
                bounds = if (clipped.isEmpty()) null else clipped;
            }
        }
        return bounds;
    }

    /// Returns paint bounds that need native surface space. Text uses its
    /// layout rect here because its larger retained paint bounds are only a
    /// conservative allowance for damage and culling.
    pub fn framePaintBounds(self: *const RenderNode) ?Rect {
        var bounds = unionPaintBounds(null, switch (self.kind) {
            .text => if (self.text) |value| if (value.len == 0) null else self.rect else null,
            else => self.deriveOwnPaintBounds(),
        });
        for (self.children) |child| bounds = unionPaintBounds(bounds, child.framePaintBounds());
        if (self.kind.isViewport()) {
            if (bounds) |value| {
                const clipped = value.intersect(self.rect);
                bounds = if (clipped.isEmpty()) null else clipped;
            }
        }
        return bounds;
    }

    pub fn deriveOwnPaintBounds(self: *const RenderNode) ?Rect {
        return switch (self.kind) {
            .text => if (self.text) |value| blk: {
                if (value.len == 0) break :blk null;
                const overhang = @max(0, self.text_style.font_size);
                break :blk .{
                    .x = self.rect.x - overhang,
                    .y = self.rect.y - overhang,
                    .width = self.rect.width + overhang * 2,
                    .height = self.rect.height + overhang * 2,
                };
            } else null,
            .box => if (self.box_shadow) |shadow|
                if (shadow.isVisible()) shadow.paintBounds(self.rect) else if (self.background.a > 0 or self.box_border != null) self.rect else null
            else if (self.background.a > 0 or self.box_border != null) self.rect else null,
            .separator => if (self.background.a > 0) self.rect else null,
            .text_input, .spinner, .scroll, .list, .render_object => self.rect,
            else => null,
        };
    }

    fn unionPaintBounds(a: ?Rect, b: ?Rect) ?Rect {
        const left = if (a) |value| if (!value.isEmpty()) value else null else null;
        const right = if (b) |value| if (!value.isEmpty()) value else null else null;
        const left_bounds = left orelse return right;
        const right_bounds = right orelse return left;
        const x0 = @min(left_bounds.x, right_bounds.x);
        const y0 = @min(left_bounds.y, right_bounds.y);
        const x1 = @max(left_bounds.x + left_bounds.width, right_bounds.x + right_bounds.width);
        const y1 = @max(left_bounds.y + left_bounds.height, right_bounds.y + right_bounds.height);
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }
};

pub const AppContext = struct {
    window_width: f32 = 0,
    window_height: f32 = 0,
    color_scheme: []const u8 = "no-preference",
};

/// Editing state owned by a text_input element; the single source of truth
/// for the input's text after creation.
pub const TextInputState = struct {
    text: std.ArrayList(u8) = .empty,
};

pub fn textInputState(element: *Element) *TextInputState {
    std.debug.assert(element.kind == .text_input);
    return @ptrCast(@alignCast(element.state.?));
}

/// Scroll position owned by a scroll element; clamped to the content
/// extent during layout. The scrollbar thumb rests hidden and is revealed
/// by scroll activity, fading back out on the shared fade timeline.
pub const ScrollState = struct {
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    scrollbar_alpha: f32 = 0,
    scrollbar_fade: animation.Timeline = .{},
};

pub fn scrollState(element: *Element) *ScrollState {
    std.debug.assert(element.kind == .scroll);
    return @ptrCast(@alignCast(element.state.?));
}

/// State owned by a list element: the scroll offset plus the currently
/// built item window. range_stale marks a built window that no longer
/// matches the offset/viewport; the runtime schedules another dirty-state
/// pass to rebuild it.
pub const ListState = struct {
    const FollowAlignment = enum { top, bottom, end };

    pub const ScrollAnchor = struct {
        index: usize,
        offset_within_item: f32,
    };

    offset: f32 = 0,
    viewport_height: f32 = 0,
    first: usize = 0,
    built: usize = 0,
    range_stale: bool = false,
    /// The selection the list last followed; a differing widget value
    /// triggers the follow scroll, so free scrolling in between is left
    /// alone.
    last_selected: ?usize = null,
    content_extent: f32 = 0,
    follow_end_pending: bool = false,
    /// Variable-height lists retain measured extents by absolute item index.
    /// Values from an old width remain useful estimates after reflow, while
    /// measured marks values authoritative at measured_width.
    heights: std.ArrayList(f32) = .empty,
    measured: std.DynamicBitSetUnmanaged = .{},
    ever_measured: std.DynamicBitSetUnmanaged = .{},
    prefix: std.ArrayList(f32) = .empty,
    measured_width: ?f32 = null,
    estimated_item_extent: f32 = 16,
    follow_alignment: ?FollowAlignment = null,
    scrollbar_alpha: f32 = 0,
    scrollbar_fade: animation.Timeline = .{},

    pub fn deinit(self: *ListState, allocator: std.mem.Allocator) void {
        self.heights.deinit(allocator);
        self.measured.deinit(allocator);
        self.ever_measured.deinit(allocator);
        self.prefix.deinit(allocator);
    }

    /// Keeps variable-height geometry synchronized with the item count.
    /// Layout additionally supplies the authoritative child width; other
    /// tree walks pass null because flex layout may narrow their constraints.
    /// Fixed-height lists never allocate this cache.
    pub fn prepare(self: *ListState, allocator: std.mem.Allocator, list_widget: Widget.List, width: ?f32) !void {
        const at_end = self.content_extent == 0 or self.offset + self.viewport_height >= self.content_extent - 0.5;
        if (!list_widget.follow_end) {
            self.follow_end_pending = false;
            if (self.follow_alignment == .end) self.follow_alignment = null;
        } else if (at_end) {
            self.follow_end_pending = true;
        }

        if (list_widget.item_extent != null) {
            if (self.heights.capacity != 0 or self.prefix.capacity != 0 or self.measured.bit_length != 0 or self.ever_measured.bit_length != 0) {
                self.heights.deinit(allocator);
                self.measured.deinit(allocator);
                self.ever_measured.deinit(allocator);
                self.prefix.deinit(allocator);
                self.heights = .empty;
                self.measured = .{};
                self.ever_measured = .{};
                self.prefix = .empty;
            }
            self.measured_width = null;
            self.follow_alignment = null;
            return;
        }

        const old_count = self.heights.items.len;
        const count_changed = old_count != list_widget.item_count;
        const prefix_uninitialized = self.prefix.items.len != list_widget.item_count + 1;
        if (count_changed or prefix_uninitialized) {
            try self.heights.resize(allocator, list_widget.item_count);
            if (list_widget.item_count > old_count) {
                @memset(self.heights.items[old_count..], self.estimated_item_extent);
            }
            try self.measured.resize(allocator, list_widget.item_count, false);
            try self.ever_measured.resize(allocator, list_widget.item_count, false);
            try self.prefix.resize(allocator, list_widget.item_count + 1);
            self.rebuildPrefix();
        }

        if (width) |layout_width| {
            if (self.measured_width == null or self.measured_width.? != layout_width) {
                self.measured.unsetAll();
                self.measured_width = layout_width;
            }
        }
    }

    fn rebuildPrefix(self: *ListState) void {
        if (self.prefix.items.len == 0) return;
        self.prefix.items[0] = 0;
        for (self.heights.items, 0..) |height, index| {
            self.prefix.items[index + 1] = self.prefix.items[index] + height;
        }
    }

    pub fn itemStart(self: *const ListState, list_widget: Widget.List, index: usize) f32 {
        if (list_widget.item_extent) |extent| return extent * @as(f32, @floatFromInt(index));
        if (index < self.prefix.items.len) return self.prefix.items[index];
        return self.estimated_item_extent * @as(f32, @floatFromInt(index));
    }

    pub fn itemExtent(self: *const ListState, list_widget: Widget.List, index: usize) f32 {
        if (list_widget.item_extent) |extent| return extent;
        if (index < self.heights.items.len) return self.heights.items[index];
        return self.estimated_item_extent;
    }

    pub fn contentExtent(self: *const ListState, list_widget: Widget.List) f32 {
        if (list_widget.item_extent) |extent| return extent * @as(f32, @floatFromInt(list_widget.item_count));
        if (self.prefix.items.len > list_widget.item_count) return self.prefix.items[list_widget.item_count];
        return self.estimated_item_extent * @as(f32, @floatFromInt(list_widget.item_count));
    }

    pub fn captureScrollAnchor(self: *const ListState, list_widget: Widget.List) ?ScrollAnchor {
        if (list_widget.item_count == 0) return null;
        const index = self.itemAtOffset(self.offset);
        return .{
            .index = index,
            .offset_within_item = self.offset - self.itemStart(list_widget, index),
        };
    }

    pub fn restoreScrollAnchor(self: *ListState, list_widget: Widget.List, anchor: ScrollAnchor) void {
        if (anchor.index >= list_widget.item_count) return;
        const offset_within_item = std.math.clamp(anchor.offset_within_item, 0, self.itemExtent(list_widget, anchor.index));
        self.offset = self.itemStart(list_widget, anchor.index) + offset_within_item;
    }

    fn itemAtOffset(self: *const ListState, offset: f32) usize {
        std.debug.assert(self.heights.items.len > 0);
        var low: usize = 0;
        var high = self.heights.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.prefix.items[middle + 1] <= offset) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return @min(low, self.heights.items.len - 1);
    }

    /// Records one laid-out row. Prefix positions are rebuilt once after the
    /// whole retained window has been measured.
    pub fn recordMeasurement(self: *ListState, index: usize, height: f32) bool {
        if (index >= self.heights.items.len) return false;
        const measured_height = if (std.math.isFinite(height)) @max(0, height) else self.estimated_item_extent;
        const changed = @abs(self.heights.items[index] - measured_height) > 0.01;
        self.heights.items[index] = measured_height;
        self.measured.set(index);
        self.ever_measured.set(index);
        return changed;
    }

    /// Updates the rolling estimate and positions after a layout pass.
    pub fn finishMeasurements(self: *ListState, measurements_changed: bool) bool {
        if (!measurements_changed) return false;

        var total: f32 = 0;
        var count: usize = 0;
        for (self.heights.items, 0..) |height, index| {
            if (!self.measured.isSet(index)) continue;
            total += height;
            count += 1;
        }

        var changed = measurements_changed;
        if (count > 0) {
            const estimate = total / @as(f32, @floatFromInt(count));
            if (std.math.isFinite(estimate) and estimate > 0 and @abs(self.estimated_item_extent - estimate) > 0.01) {
                self.estimated_item_extent = estimate;
                changed = true;
            }
            for (self.heights.items, 0..) |*height, index| {
                if (self.ever_measured.isSet(index)) continue;
                if (@abs(height.* - self.estimated_item_extent) > 0.01) changed = true;
                height.* = self.estimated_item_extent;
            }
        }
        if (changed) self.rebuildPrefix();
        return changed;
    }
};

pub fn listState(element: *Element) *ListState {
    std.debug.assert(element.kind == .list);
    return @ptrCast(@alignCast(element.state.?));
}

/// Free-running sweep owned by a spinner element. The phase baseline is
/// captured on the first animation tick, so a spinner built in a tree
/// that never ticks (popup measurement, headless snapshots) stays inert.
pub const SpinnerState = struct {
    start_ns: ?u64 = null,
    progress: f32 = 0,
};

pub fn spinnerState(element: *Element) *SpinnerState {
    std.debug.assert(element.kind == .spinner);
    return @ptrCast(@alignCast(element.state.?));
}

/// Advances every animation in the tree to `now_ns`, writing new values
/// into the retained render nodes and accumulating damage directly:
/// animation ticks repaint without rebuilding or re-laying-out anything.
/// Returns true while any animation still demands another frame.
pub fn advanceAnimations(element: *Element, now_ns: u64) bool {
    var active = switch (element.kind) {
        .scroll => blk: {
            const state = scrollState(element);
            break :blk advanceScrollbarFade(&state.scrollbar_fade, &state.scrollbar_alpha, element.render_node, now_ns);
        },
        .list => blk: {
            const state = listState(element);
            break :blk advanceScrollbarFade(&state.scrollbar_fade, &state.scrollbar_alpha, element.render_node, now_ns);
        },
        .spinner => blk: {
            const state = spinnerState(element);
            const start = state.start_ns orelse now_ns;
            state.start_ns = start;
            const period_ns = @as(u64, element.widget.spinner.period_ms) * std.time.ns_per_ms;
            state.progress = animation.repeatingPhase(start, now_ns, period_ns);
            if (element.render_node) |node| {
                node.spinner_progress = state.progress;
                addRenderDamage(node, node.rect);
            }
            break :blk true;
        },
        else => false,
    };
    for (element.children) |*child| {
        if (advanceAnimations(child, now_ns)) active = true;
    }
    return active;
}

/// Whether any animation in the tree demands another frame. Queried after
/// rebuilds so animations created by this frame's build register demand
/// even though they were not advanced this frame.
pub fn anyAnimationsActive(element: *Element) bool {
    const active = switch (element.kind) {
        .scroll => scrollState(element).scrollbar_fade.active,
        .list => listState(element).scrollbar_fade.active,
        .spinner => true,
        else => false,
    };
    if (active) return true;
    for (element.children) |*child| {
        if (anyAnimationsActive(child)) return true;
    }
    return false;
}

/// Restarts the reveal-then-fade cycle in response to scroll activity.
pub fn revealScrollbar(element: *Element, now_ns: u64) void {
    switch (element.kind) {
        .scroll => {
            const state = scrollState(element);
            state.scrollbar_alpha = 1;
            state.scrollbar_fade.start(now_ns, animation.scrollbar_fade_total_ns);
        },
        .list => {
            const state = listState(element);
            state.scrollbar_alpha = 1;
            state.scrollbar_fade.start(now_ns, animation.scrollbar_fade_total_ns);
        },
        else => unreachable,
    }
}

fn advanceScrollbarFade(timeline: *animation.Timeline, alpha: *f32, render_node: ?*RenderNode, now_ns: u64) bool {
    if (!timeline.active) return false;
    alpha.* = animation.scrollbarFadeAlpha(timeline.advance(now_ns));
    const node = render_node orelse return timeline.active;
    node.scrollbar_alpha = alpha.*;
    // Damage only the edge strips the thumbs occupy, and only for axes
    // that overflow; the fade repaints without touching the content.
    const strip = scrollbar_thickness + scrollbar_margin * 2;
    if (node.scroll_content.height > node.rect.height) {
        addRenderDamage(node, .{
            .x = node.rect.x + node.rect.width - strip,
            .y = node.rect.y,
            .width = strip,
            .height = node.rect.height,
        });
    }
    if (node.scroll_content.width > node.rect.width) {
        addRenderDamage(node, .{
            .x = node.rect.x,
            .y = node.rect.y + node.rect.height - strip,
            .width = node.rect.width,
            .height = strip,
        });
    }
    return timeline.active;
}

const list_buffer_items = 2;

const ListRange = struct {
    first: usize,
    count: usize,
};

pub fn listVisibleRange(list_widget: Widget.List, state: *const ListState, offset: f32, viewport_height: f32) ListRange {
    if (list_widget.item_count == 0) return .{ .first = 0, .count = 0 };
    if (list_widget.item_extent) |item_extent| {
        if (item_extent <= 0) return .{ .first = 0, .count = 0 };
        const height = if (std.math.isFinite(viewport_height))
            viewport_height
        else
            item_extent * @as(f32, @floatFromInt(list_widget.item_count));
        const first_visible: usize = @intFromFloat(@max(0, @floor(offset / item_extent)));
        const first = @min(first_visible -| list_buffer_items, list_widget.item_count - 1);
        const visible: usize = @intFromFloat(@ceil(height / item_extent) + 1);
        const count = @min(visible + list_buffer_items * 2, list_widget.item_count - first);
        return .{ .first = first, .count = count };
    }

    const content_extent = state.contentExtent(list_widget);
    const height = if (std.math.isFinite(viewport_height)) @max(0, viewport_height) else content_extent;
    const clamped_offset = std.math.clamp(offset, 0, @max(0, content_extent));
    const first_visible = state.itemAtOffset(clamped_offset);
    const last_visible = state.itemAtOffset(@min(content_extent, clamped_offset + height));
    const first = first_visible -| list_buffer_items;
    const end = @min(list_widget.item_count, last_visible + 1 +| list_buffer_items);
    return .{ .first = first, .count = end - first };
}

pub fn listItemConstraints(list_widget: Widget.List, constraints: Constraints) Constraints {
    return .{
        .max_width = constraints.max_width,
        .max_height = list_widget.item_extent orelse std.math.inf(f32),
    };
}

fn buildListChildren(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    list_widget: Widget.List,
    range: ListRange,
    constraints: Constraints,
) ![]Element {
    const item_constraints = listItemConstraints(list_widget, constraints);
    const children = try allocator.alloc(Element, range.count);
    var initialized: usize = 0;
    errdefer {
        for (children[0..initialized]) |*child| destroyElementTree(allocator, child);
        allocator.free(children);
    }
    for (children, 0..) |*child, index| {
        const item = try list_widget.build_item.build(scope, range.first + index);
        child.* = try buildElementTreeScoped(allocator, scope, &item, item_constraints);
        initialized += 1;
    }
    return children;
}

/// How reconcileListWindow treats rows whose item index stayed inside the
/// window: .rebuild re-runs the item builder and reconciles the result into
/// the retained element (item data may have changed), .reuse keeps the
/// element untouched (pure scroll, nothing changed).
const RetainedRows = enum { rebuild, reuse };

/// Reconciles a list's built row window against a new visible range keyed
/// by absolute item index. Retained rows keep their element identity —
/// render nodes, text measurements, and row state survive — while rows
/// entering the window are built fresh and rows leaving it are destroyed.
/// Takes ownership of element.children and returns the new window; the
/// caller stores it back along with the range bookkeeping.
fn reconcileListWindow(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    list_widget: Widget.List,
    range: ListRange,
    constraints: Constraints,
    retained: RetainedRows,
) ![]Element {
    std.debug.assert(element.kind == .list);
    const item_constraints = listItemConstraints(list_widget, constraints);
    const old_first = listState(element).first;
    const old_children = element.children;
    element.children = &.{};

    const moved = try allocator.alloc(bool, old_children.len);
    defer allocator.free(moved);
    @memset(moved, false);

    const new_children = try allocator.alloc(Element, range.count);
    var initialized: usize = 0;
    errdefer {
        for (new_children[0..initialized]) |*child| destroyElementTree(allocator, child);
        allocator.free(new_children);
        for (old_children, 0..) |*old_child, index| {
            if (!moved[index]) destroyElementTree(allocator, old_child);
        }
        allocator.free(old_children);
    }

    for (new_children, 0..) |*slot, index| {
        const item_index = range.first + index;
        if (item_index >= old_first and item_index - old_first < old_children.len) {
            const old_index = item_index - old_first;
            slot.* = old_children[old_index];
            moved[old_index] = true;
            initialized += 1;
            if (retained == .rebuild) {
                const item = try list_widget.build_item.build(scope, item_index);
                try updateElementTreeScoped(allocator, scope, slot, &item, item_constraints);
            }
            continue;
        }
        const item = try list_widget.build_item.build(scope, item_index);
        slot.* = try buildElementTreeScoped(allocator, scope, &item, item_constraints);
        initialized += 1;
    }

    for (old_children, 0..) |*old_child, index| {
        if (!moved[index]) destroyElementTree(allocator, old_child);
    }
    allocator.free(old_children);
    return new_children;
}

/// Reports whether any list's built window drifted from its offset and
/// viewport, so the runtime can run another dirty-state pass.
pub fn anyListRangeStale(element: *const Element) bool {
    if (element.kind == .list) {
        const state: *const ListState = @ptrCast(@alignCast(element.state.?));
        if (state.range_stale) return true;
    }
    for (element.children) |*child| {
        if (anyListRangeStale(child)) return true;
    }
    return false;
}

pub fn scrollChildConstraints(constraints: Constraints, axes: Widget.ScrollAxes) Constraints {
    // Content is free along a scrollable axis; mins only carry across
    // the bounded axis so tight fits still reach the content.
    return .{
        .max_width = if (axes.horizontalUnbounded()) std.math.inf(f32) else constraints.max_width,
        .max_height = if (axes.verticalUnbounded()) std.math.inf(f32) else constraints.max_height,
        .min_width = if (axes.horizontalUnbounded()) 0 else constraints.min_width,
        .min_height = if (axes.verticalUnbounded()) 0 else constraints.min_height,
    };
}

pub const AppHost = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        build_widget: *const fn (ptr: *anyopaque, scope: *BuildScope, context: AppContext) anyerror!Widget,
    };

    pub fn buildWidget(self: AppHost, scope: *BuildScope, context: AppContext) !Widget {
        return self.vtable.build_widget(self.ptr, scope, context);
    }
};

pub fn buildRenderTreeFromElement(
    allocator: std.mem.Allocator,
    element: *Element,
    constraints: Constraints,
    backend: RenderBackend,
) !*RenderNode {
    return layoutElement(allocator, element, constraints, .{ .x = 0, .y = 0 }, .{ .backend = backend });
}

pub fn buildElementTree(allocator: std.mem.Allocator, widget: *const Widget, constraints: Constraints) anyerror!Element {
    var scope: BuildScope = .{ .allocator = allocator };
    return buildElementTreeScoped(allocator, &scope, widget, constraints);
}

pub fn buildElementTreeScoped(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    widget: *const Widget,
    constraints: Constraints,
) anyerror!Element {
    switch (widget.*) {
        .keyed => |keyed_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const element_key = try cloneKey(allocator, keyed_widget.key);
            errdefer destroyKey(allocator, element_key);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, keyed_widget.child, constraints);
            return .{ .kind = .keyed, .widget = element_widget, .key = element_key, .children = children };
        },
        .text => return .{ .kind = .text, .widget = try cloneWidgetForElementThemed(allocator, widget.*, scope.theme, scope.default_text_style) },
        .spacer => return .{ .kind = .spacer, .widget = try cloneWidgetForElement(allocator, widget.*) },
        .sized => |sized_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, sized_widget.child, constrainSized(constraints, sized_widget));
            return .{ .kind = .sized, .widget = element_widget, .children = children };
        },
        .text_input => {
            var element_widget = try cloneWidgetForElementThemed(allocator, widget.*, scope.theme, scope.default_text_style);
            errdefer destroyElementWidget(allocator, &element_widget);
            const state = try allocator.create(TextInputState);
            errdefer allocator.destroy(state);
            state.* = .{};
            try state.text.appendSlice(allocator, element_widget.text_input.value);
            return .{
                .kind = .text_input,
                .widget = element_widget,
                .state = state,
                .focused = scope.interaction.isFocused(element_widget.text_input.focus_node),
            };
        },
        .separator => return .{ .kind = .separator, .widget = try cloneWidgetForElementThemed(allocator, widget.*, scope.theme, scope.default_text_style) },
        .spinner => {
            const element_widget = try cloneWidgetForElementThemed(allocator, widget.*, scope.theme, scope.default_text_style);
            const state = try allocator.create(SpinnerState);
            state.* = .{};
            return .{ .kind = .spinner, .widget = element_widget, .state = state };
        },
        .render_object => return .{ .kind = .render_object, .widget = try cloneWidgetForElement(allocator, widget.*) },
        .box => |box_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, box_widget.child, constraints);
            return .{ .kind = .box, .widget = element_widget, .children = children };
        },
        .clickable => |clickable_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            try resolveClickableIntent(allocator, scope.actions, &element_widget.clickable);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildClickableChildElement(allocator, scope, clickable_widget, constraints);
            return .{ .kind = .clickable, .widget = element_widget, .children = children };
        },
        .anchored => |anchored_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, anchored_widget.child, constraints);
            return .{ .kind = .anchored, .widget = element_widget, .children = children };
        },
        .focus => |focus_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, focus_widget.child, constraints);
            return .{ .kind = .focus, .widget = element_widget, .focused = scope.interaction.isFocused(element_widget.focus.node), .children = children };
        },
        .scroll => |scroll_widget| {
            var element_widget = try cloneWidgetForElementThemed(allocator, widget.*, scope.theme, scope.default_text_style);
            errdefer destroyElementWidget(allocator, &element_widget);
            const state = try allocator.create(ScrollState);
            errdefer allocator.destroy(state);
            state.* = .{};
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, scroll_widget.child, scrollChildConstraints(constraints, scroll_widget.axes));
            return .{ .kind = .scroll, .widget = element_widget, .state = state, .children = children };
        },
        .list => {
            var element_widget = try cloneWidgetForElementThemed(allocator, widget.*, scope.theme, scope.default_text_style);
            errdefer destroyElementWidget(allocator, &element_widget);
            const state = try allocator.create(ListState);
            state.* = .{ .viewport_height = constraints.max_height };
            errdefer {
                state.deinit(allocator);
                allocator.destroy(state);
            }
            try state.prepare(allocator, element_widget.list, null);
            const range = listVisibleRange(element_widget.list, state, state.offset, constraints.max_height);
            state.first = range.first;
            state.built = range.count;
            const children = try buildListChildren(allocator, scope, element_widget.list, range, constraints);
            return .{ .kind = .list, .widget = element_widget, .state = state, .children = children };
        },
        .focus_scope => |focus_scope_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, focus_scope_widget.child, constraints);
            return .{ .kind = .focus_scope, .widget = element_widget, .children = children };
        },
        .padding => |padding_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, padding_widget.child, constraints.inset(padding_widget.insets));
            return .{ .kind = .padding, .widget = element_widget, .children = children };
        },
        .flexible => |flexible_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, flexible_widget.child, constraints);
            return .{ .kind = .flexible, .widget = element_widget, .children = children };
        },
        .center => |center_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, center_widget.child, constraints);
            return .{ .kind = .center, .widget = element_widget, .children = children };
        },
        .actions => |actions_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const previous_actions = scope.actions;
            const nested_actions: ActionScope = .{ .bindings = element_widget.actions.bindings, .parent = previous_actions };
            scope.actions = &nested_actions;
            defer scope.actions = previous_actions;
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, actions_widget.child, constraints);
            return .{ .kind = .actions, .widget = element_widget, .children = children };
        },
        .shortcuts => |shortcuts_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, shortcuts_widget.child, constraints);
            return .{ .kind = .shortcuts, .widget = element_widget, .children = children };
        },
        .theme => |theme_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const previous_theme = scope.theme;
            scope.theme = theme_widget.theme;
            defer scope.theme = previous_theme;
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, theme_widget.child, constraints);
            return .{ .kind = .theme, .widget = element_widget, .children = children };
        },
        .default_text_style => |default_text_style| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const previous_style = scope.default_text_style;
            scope.default_text_style = mergeTextStyle(previous_style, default_text_style.style);
            defer scope.default_text_style = previous_style;
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, default_text_style.child, constraints);
            return .{ .kind = .default_text_style, .widget = element_widget, .children = children };
        },
        .row => |row_widget| return buildLinearElementTree(allocator, scope, .row, widget.*, row_widget.children, constraints),
        .column => |column_widget| return buildLinearElementTree(allocator, scope, .column, widget.*, column_widget.children, constraints),
        .component => |component_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const built = try component_widget.build(scope, buildContext(scope, constraints));
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, &built, constraints);
            return .{ .kind = .component, .widget = element_widget, .children = children };
        },
        .stateful => |stateful_widget| {
            _ = stateful_widget;
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const retained_stateful = element_widget.stateful;
            const state = try retained_stateful.createState(allocator);
            errdefer retained_stateful.destroyState(state, allocator);
            const rebuild_token = retained_stateful.rebuildToken(state, true);
            const built = try retained_stateful.build(state, scope, buildContext(scope, constraints));
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTreeScoped(allocator, scope, &built, constraints);
            initialized = true;
            retained_stateful.finishRebuild(state, rebuild_token);
            return .{ .kind = .stateful, .widget = element_widget, .state = state, .children = children };
        },
        .element => |custom_element| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            errdefer allocator.free(children);
            children[0] = try custom_element.build(allocator, scope, buildContext(scope, constraints));
            return .{ .kind = .element, .widget = element_widget, .children = children };
        },
    }
}

fn buildContext(scope: *const BuildScope, constraints: Constraints) Widget.BuildContext {
    return .{
        .constraints = constraints,
        .theme = scope.theme,
        .default_text_style = scope.default_text_style,
        .interaction = scope.interaction,
        .app_context = scope.app_context,
    };
}

fn buildLinearElementTree(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    kind: Element.Kind,
    widget: Widget,
    child_widgets: []const Widget,
    constraints: Constraints,
) anyerror!Element {
    std.debug.assert(kind == .row or kind == .column);
    std.debug.assert(widgetKeysAreUnique(child_widgets));

    var element_widget = try cloneWidgetForElement(allocator, widget);
    errdefer destroyElementWidget(allocator, &element_widget);
    const children = try allocator.alloc(Element, child_widgets.len);
    var initialized: usize = 0;
    errdefer {
        for (children[0..initialized]) |*child| destroyElementTree(allocator, child);
        allocator.free(children);
    }

    for (child_widgets, 0..) |*child_widget, index| {
        children[index] = try buildElementTreeScoped(allocator, scope, child_widget, constraints);
        initialized += 1;
    }

    return .{ .kind = kind, .widget = element_widget, .children = children };
}

/// A popup declared by an anchored element in the current element tree,
/// paired with the anchor's laid-out rect in window coordinates.
pub const PopupRequest = struct {
    id: []const u8,
    anchor_rect: Rect,
    popup: *const Widget.Popup,
};

/// Collects popups declared by anchored elements, in tree order. The
/// borrowed ids and popup declarations stay valid until the element tree
/// is next updated or destroyed.
pub fn collectPopupRequests(
    allocator: std.mem.Allocator,
    element: *const Element,
    out: *std.ArrayList(PopupRequest),
) !void {
    if (element.kind == .anchored) {
        if (element.widget.anchored.popup) |*popup_decl| {
            if (element.render_node) |node| {
                try out.append(allocator, .{
                    .id = element.widget.anchored.id,
                    .anchor_rect = node.rect,
                    .popup = popup_decl,
                });
            }
        }
    }
    for (element.children) |*child| try collectPopupRequests(allocator, child, out);
}

pub fn destroyElementTree(allocator: std.mem.Allocator, element: *Element) void {
    if (element.render_node) |node| {
        node.text_buffer.deinit(allocator);
        allocator.free(node.children);
        allocator.destroy(node);
        element.render_node = null;
    }
    for (element.children) |*child| destroyElementTree(allocator, child);
    allocator.free(element.children);
    element.children = &.{};
    if (element.state) |state| {
        switch (element.kind) {
            .stateful => element.widget.stateful.destroyState(state, allocator),
            .text_input => {
                const input_state: *TextInputState = @ptrCast(@alignCast(state));
                std.crypto.secureZero(u8, input_state.text.items);
                input_state.text.deinit(allocator);
                allocator.destroy(input_state);
            },
            .scroll => allocator.destroy(@as(*ScrollState, @ptrCast(@alignCast(state)))),
            .list => {
                const list_state: *ListState = @ptrCast(@alignCast(state));
                list_state.deinit(allocator);
                allocator.destroy(list_state);
            },
            .spinner => allocator.destroy(@as(*SpinnerState, @ptrCast(@alignCast(state)))),
            else => unreachable,
        }
        element.state = null;
    }
    if (element.key) |key| {
        destroyKey(allocator, key);
        element.key = null;
    }
    destroyElementWidget(allocator, &element.widget);
}

pub fn updateElementTree(allocator: std.mem.Allocator, element: *Element, widget: *const Widget, constraints: Constraints) anyerror!void {
    var scope: BuildScope = .{ .allocator = allocator };
    try updateElementTreeScoped(allocator, &scope, element, widget, constraints);
}

pub fn updateElementTreeScoped(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    widget: *const Widget,
    constraints: Constraints,
) anyerror!void {
    if (!canUpdateElement(element, widget)) {
        var replacement = try buildElementTreeScoped(allocator, scope, widget, constraints);
        errdefer destroyElementTree(allocator, &replacement);
        destroyElementTree(allocator, element);
        element.* = replacement;
        return;
    }

    switch (widget.*) {
        .keyed => |keyed_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, keyed_widget.child, constraints);
        },
        .text => try replaceElementWidgetThemed(allocator, element, widget.*, scope.theme, scope.default_text_style),
        .spacer => try replaceElementWidget(allocator, element, widget.*),
        .sized => |sized_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, sized_widget.child, constrainSized(constraints, sized_widget));
        },
        .text_input => {
            const focused = scope.interaction.isFocused(widget.text_input.focus_node);
            if (element.focused != focused) markElementPaintDirty(element);
            try replaceElementWidgetThemed(allocator, element, widget.*, scope.theme, scope.default_text_style);
            element.focused = focused;
        },
        .separator => try replaceElementWidgetThemed(allocator, element, widget.*, scope.theme, scope.default_text_style),
        .spinner => try replaceElementWidgetThemed(allocator, element, widget.*, scope.theme, scope.default_text_style),
        .render_object => try replaceElementWidget(allocator, element, widget.*),
        .box => |box_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, box_widget.child, constraints);
        },
        .clickable => |clickable_widget| {
            // Match buildClickableChildElement: keep the hover style applied
            // when the tree is rebuilt while the pointer rests on the target.
            const styled_child = clickableStyledChild(clickable_widget, scope.interaction);
            try updateSingleChildElement(allocator, scope, element, widget.*, &styled_child, constraints);
            try resolveClickableIntent(allocator, scope.actions, &element.widget.clickable);
        },
        .anchored => |anchored_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, anchored_widget.child, constraints);
        },
        .focus => |focus_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, focus_widget.child, constraints);
            element.focused = scope.interaction.isFocused(element.widget.focus.node);
        },
        .scroll => |scroll_widget| {
            const themed_widget = try cloneWidgetForElementThemed(scope.allocator, widget.*, scope.theme, scope.default_text_style);
            try updateSingleChildElement(allocator, scope, element, themed_widget, scroll_widget.child, scrollChildConstraints(constraints, scroll_widget.axes));
        },
        .list => {
            var element_widget = try cloneWidgetForElementThemed(allocator, widget.*, scope.theme, scope.default_text_style);
            errdefer destroyElementWidget(allocator, &element_widget);
            const state = listState(element);
            try state.prepare(allocator, element_widget.list, null);
            const range = listVisibleRange(element_widget.list, state, state.offset, state.viewport_height);
            const children = try reconcileListWindow(allocator, scope, element, element_widget.list, range, constraints, .rebuild);
            element.children = children;
            state.first = range.first;
            state.built = range.count;
            state.range_stale = false;
            markElementWidgetDirtyIfChanged(element, element_widget);
            destroyElementWidget(allocator, &element.widget);
            element.widget = element_widget;
        },
        .focus_scope => |focus_scope_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, focus_scope_widget.child, constraints);
        },
        .padding => |padding_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, padding_widget.child, constraints.inset(padding_widget.insets));
        },
        .flexible => |flexible_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, flexible_widget.child, constraints);
        },
        .center => |center_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, center_widget.child, constraints);
        },
        .actions => |actions_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const previous_actions = scope.actions;
            const nested_actions: ActionScope = .{ .bindings = element_widget.actions.bindings, .parent = previous_actions };
            scope.actions = &nested_actions;
            defer scope.actions = previous_actions;
            try updateElementTreeScoped(allocator, scope, &element.children[0], actions_widget.child, constraints);
            destroyElementWidget(allocator, &element.widget);
            element.widget = element_widget;
        },
        .shortcuts => |shortcuts_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, shortcuts_widget.child, constraints);
        },
        .theme => |theme_widget| {
            const previous_theme = scope.theme;
            scope.theme = theme_widget.theme;
            defer scope.theme = previous_theme;
            try updateSingleChildElement(allocator, scope, element, widget.*, theme_widget.child, constraints);
        },
        .default_text_style => |default_text_style| {
            const previous_style = scope.default_text_style;
            scope.default_text_style = mergeTextStyle(previous_style, default_text_style.style);
            defer scope.default_text_style = previous_style;
            try updateSingleChildElement(allocator, scope, element, widget.*, default_text_style.child, constraints);
        },
        .row => |row_widget| try updateLinearElement(allocator, scope, element, widget.*, row_widget.children, constraints),
        .column => |column_widget| try updateLinearElement(allocator, scope, element, widget.*, column_widget.children, constraints),
        .component => |component_widget| {
            const built = try component_widget.build(scope, buildContext(scope, constraints));
            try updateSingleChildElement(allocator, scope, element, widget.*, &built, constraints);
        },
        .stateful => |stateful_widget| {
            const state = element.state orelse return error.MissingState;
            try stateful_widget.update(state, allocator, buildContext(scope, constraints));
            const rebuild_token = stateful_widget.rebuildToken(state, true);
            const built = try stateful_widget.build(state, scope, buildContext(scope, constraints));
            try updateSingleChildElement(allocator, scope, element, widget.*, &built, constraints);
            stateful_widget.finishRebuild(state, rebuild_token);
        },
        .element => |custom_element| {
            var replacement_child = try custom_element.build(allocator, scope, buildContext(scope, constraints));
            errdefer destroyElementTree(allocator, &replacement_child);
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            destroyElementTree(allocator, &element.children[0]);
            element.children[0] = replacement_child;
            destroyElementWidget(allocator, &element.widget);
            element.widget = element_widget;
        },
    }

    syncRenderNodeMetadata(element);
    for (element.children) |*child| {
        if (elementNeedsLayout(child)) {
            markElementLayoutDirty(element);
            break;
        }
    }
}

pub fn rebuildDirtyElementTreeScoped(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    constraints: Constraints,
) anyerror!bool {
    switch (element.widget) {
        .text,
        .spacer,
        .text_input,
        .separator,
        .spinner,
        .render_object,
        => return false,

        .keyed,
        .box,
        .sized,
        .clickable,
        .anchored,
        .focus,
        .focus_scope,
        .center,
        .flexible,
        .component,
        .element,
        .shortcuts,
        => return try rebuildDirtySingleChildElement(allocator, scope, element, constraints),

        .scroll => |scroll_widget| return try rebuildDirtySingleChildElement(allocator, scope, element, scrollChildConstraints(constraints, scroll_widget.axes)),
        .list => |list_widget| {
            const state = listState(element);
            try state.prepare(allocator, list_widget, null);
            const rebuilt_children = try rebuildDirtyChildren(allocator, scope, element.children, listItemConstraints(list_widget, constraints));
            if (!state.range_stale) {
                if (rebuilt_children) markElementLayoutDirty(element);
                return rebuilt_children;
            }
            const range = listVisibleRange(list_widget, state, state.offset, state.viewport_height);
            const children = try reconcileListWindow(allocator, scope, element, list_widget, range, constraints, .reuse);
            element.children = children;
            state.first = range.first;
            state.built = range.count;
            state.range_stale = false;
            markElementLayoutDirty(element);
            return true;
        },
        .padding => |padding_widget| return try rebuildDirtySingleChildElement(allocator, scope, element, constraints.inset(padding_widget.insets)),
        .theme => |theme_widget| {
            const previous_theme = scope.theme;
            scope.theme = theme_widget.theme;
            defer scope.theme = previous_theme;
            return try rebuildDirtySingleChildElement(allocator, scope, element, constraints);
        },
        .default_text_style => |default_text_style| {
            const previous_style = scope.default_text_style;
            scope.default_text_style = mergeTextStyle(previous_style, default_text_style.style);
            defer scope.default_text_style = previous_style;
            return try rebuildDirtySingleChildElement(allocator, scope, element, constraints);
        },
        .actions => |actions_widget| {
            const previous_actions = scope.actions;
            const nested_actions: ActionScope = .{ .bindings = actions_widget.bindings, .parent = previous_actions };
            scope.actions = &nested_actions;
            defer scope.actions = previous_actions;
            return try rebuildDirtySingleChildElement(allocator, scope, element, constraints);
        },
        .row, .column => {
            const rebuilt = try rebuildDirtyChildren(allocator, scope, element.children, constraints);
            if (rebuilt) markElementLayoutDirty(element);
            return rebuilt;
        },
        .stateful => |stateful_widget| {
            const state = element.state orelse return error.MissingState;
            if (stateful_widget.rebuildToken(state, false)) |rebuild_token| {
                const built = try stateful_widget.build(state, scope, buildContext(scope, constraints));
                try updateElementTreeScoped(allocator, scope, &element.children[0], &built, constraints);
                stateful_widget.finishRebuild(state, rebuild_token);
                markElementLayoutDirty(element);
                return true;
            }
            return try rebuildDirtySingleChildElement(allocator, scope, element, constraints);
        },
    }
}

/// Finds the text input element with the given focus id, marking the
/// layout path to it dirty so an edit relayouts exactly that input.
pub fn dirtyTextInputElement(element: *Element, focus_id: []const u8) ?*Element {
    if (element.kind == .text_input) {
        if (std.mem.eql(u8, element.widget.text_input.focus_node.id, focus_id)) {
            markElementLayoutDirty(element);
            markElementPaintDirty(element);
            return element;
        }
        return null;
    }
    for (element.children) |*child| {
        if (dirtyTextInputElement(child, focus_id)) |found| {
            markElementLayoutDirty(element);
            return found;
        }
    }
    return null;
}

/// Finds the scroll element with the given id, marking the layout path to
/// it dirty so a scroll relayouts exactly that viewport.
pub fn dirtyScrollElement(element: *Element, scroll_id: []const u8) ?*Element {
    const id: ?[]const u8 = switch (element.kind) {
        .scroll => element.widget.scroll.id,
        .list => element.widget.list.id,
        else => null,
    };
    if (id) |element_id| {
        if (std.mem.eql(u8, element_id, scroll_id)) {
            markElementLayoutDirty(element);
            return element;
        }
    }
    for (element.children) |*child| {
        if (dirtyScrollElement(child, scroll_id)) |found| {
            markElementLayoutDirty(element);
            return found;
        }
    }
    return null;
}

/// Re-expands interaction-styled elements whose id is in `ids`
/// using the scope's current interaction state, so hover/press changes can
/// restyle exactly the affected widgets instead of rebuilding the app.
/// Ancestors of refreshed elements are marked for relayout.
pub fn refreshInteractionElements(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    constraints: Constraints,
    ids: []const []const u8,
) anyerror!bool {
    switch (element.widget) {
        .text,
        .spacer,
        .text_input,
        .separator,
        .spinner,
        .render_object,
        => return false,

        .clickable => |clickable_widget| {
            var matched = false;
            for (ids) |id| {
                if (std.mem.eql(u8, clickable_widget.id, id)) matched = true;
            }
            if (matched and (clickable_widget.hover_style != null or clickable_widget.pressed_style != null)) {
                applyClickableStateStyle(&element.children[0], clickable_widget, scope.interaction);
                markElementLayoutDirty(&element.children[0]);
                markElementPaintDirty(&element.children[0]);
                markElementLayoutDirty(element);
                return true;
            }
            return try refreshInteractionSingleChild(allocator, scope, element, constraints, ids);
        },

        .keyed,
        .box,
        .sized,
        .anchored,
        .focus,
        .focus_scope,
        .center,
        .flexible,
        .component,
        .element,
        .shortcuts,
        .stateful,
        => return try refreshInteractionSingleChild(allocator, scope, element, constraints, ids),

        .scroll => |scroll_widget| return try refreshInteractionSingleChild(allocator, scope, element, scrollChildConstraints(constraints, scroll_widget.axes), ids),
        .list => |list_widget| {
            var refreshed = false;
            const item_constraints = listItemConstraints(list_widget, constraints);
            for (element.children) |*child| {
                if (try refreshInteractionElements(allocator, scope, child, item_constraints, ids)) refreshed = true;
            }
            if (refreshed) markElementLayoutDirty(element);
            return refreshed;
        },
        .padding => |padding_widget| return try refreshInteractionSingleChild(allocator, scope, element, constraints.inset(padding_widget.insets), ids),
        .theme => |theme_widget| {
            const previous_theme = scope.theme;
            scope.theme = theme_widget.theme;
            defer scope.theme = previous_theme;
            return try refreshInteractionSingleChild(allocator, scope, element, constraints, ids);
        },
        .default_text_style => |default_text_style| {
            const previous_style = scope.default_text_style;
            scope.default_text_style = mergeTextStyle(previous_style, default_text_style.style);
            defer scope.default_text_style = previous_style;
            return try refreshInteractionSingleChild(allocator, scope, element, constraints, ids);
        },
        .actions => |actions_widget| {
            const previous_actions = scope.actions;
            const nested_actions: ActionScope = .{ .bindings = actions_widget.bindings, .parent = previous_actions };
            scope.actions = &nested_actions;
            defer scope.actions = previous_actions;
            return try refreshInteractionSingleChild(allocator, scope, element, constraints, ids);
        },
        .row, .column => {
            var refreshed = false;
            for (element.children) |*child| {
                if (try refreshInteractionElements(allocator, scope, child, constraints, ids)) refreshed = true;
            }
            if (refreshed) markElementLayoutDirty(element);
            return refreshed;
        },
    }
}

fn refreshInteractionSingleChild(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    constraints: Constraints,
    ids: []const []const u8,
) !bool {
    std.debug.assert(element.children.len == 1);
    const refreshed = try refreshInteractionElements(allocator, scope, &element.children[0], constraints, ids);
    if (refreshed) markElementLayoutDirty(element);
    return refreshed;
}

fn rebuildDirtySingleChildElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    constraints: Constraints,
) !bool {
    std.debug.assert(element.children.len == 1);
    // A rebuilt descendant may change size, so every ancestor on the path
    // must re-run layout even though its own widget is unchanged.
    const rebuilt = try rebuildDirtyElementTreeScoped(allocator, scope, &element.children[0], constraints);
    if (rebuilt) markElementLayoutDirty(element);
    return rebuilt;
}

fn rebuildDirtyChildren(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    children: []Element,
    constraints: Constraints,
) !bool {
    var rebuilt = false;
    for (children) |*child| {
        if (try rebuildDirtyElementTreeScoped(allocator, scope, child, constraints)) rebuilt = true;
    }
    return rebuilt;
}

fn canUpdateElement(element: *const Element, widget: *const Widget) bool {
    if (element.kind != elementKindForWidget(widget.*)) return false;
    return switch (widget.*) {
        .keyed => |keyed_widget| if (element.key) |key| keysEqual(key, keyed_widget.key) else false,
        .stateful => |stateful_widget| statefulTypesEqual(element.widget.stateful, stateful_widget),
        else => true,
    };
}

fn statefulTypesEqual(a: Widget.Stateful, b: Widget.Stateful) bool {
    if (a.type_token != null or b.type_token != null) {
        return a.type_token != null and b.type_token != null and a.type_token.? == b.type_token.?;
    }
    return a.vtable == b.vtable;
}

fn elementKindForWidget(widget: Widget) Element.Kind {
    return switch (widget) {
        .keyed => .keyed,
        .text => .text,
        .box => .box,
        .clickable => .clickable,
        .anchored => .anchored,
        .focus => .focus,
        .focus_scope => .focus_scope,
        .scroll => .scroll,
        .list => .list,
        .text_input => .text_input,
        .separator => .separator,
        .spinner => .spinner,
        .row => .row,
        .column => .column,
        .spacer => .spacer,
        .flexible => .flexible,
        .sized => .sized,
        .padding => .padding,
        .center => .center,
        .actions => .actions,
        .shortcuts => .shortcuts,
        .theme => .theme,
        .default_text_style => .default_text_style,
        .component => .component,
        .stateful => .stateful,
        .element => .element,
        .render_object => .render_object,
    };
}

fn updateSingleChildElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    widget: Widget,
    child_widget: *const Widget,
    child_constraints: Constraints,
) anyerror!void {
    std.debug.assert(element.children.len == 1);
    var element_widget = try cloneWidgetForElement(allocator, widget);
    errdefer destroyElementWidget(allocator, &element_widget);
    try updateElementTreeScoped(allocator, scope, &element.children[0], child_widget, child_constraints);
    markElementWidgetDirtyIfChanged(element, element_widget);
    destroyElementWidget(allocator, &element.widget);
    element.widget = element_widget;
}

fn updateLinearElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    widget: Widget,
    child_widgets: []const Widget,
    constraints: Constraints,
) anyerror!void {
    std.debug.assert(widgetKeysAreUnique(child_widgets));

    var element_widget = try cloneWidgetForElement(allocator, widget);
    errdefer destroyElementWidget(allocator, &element_widget);

    if (childrenCanUpdateInPlace(element.children, child_widgets)) {
        for (child_widgets, 0..) |*child_widget, index| {
            try updateElementTreeScoped(allocator, scope, &element.children[index], child_widget, constraints);
        }
        markElementWidgetDirtyIfChanged(element, element_widget);
        destroyElementWidget(allocator, &element.widget);
        element.widget = element_widget;
        return;
    }

    // A changed child list or order changes linear layout even when all
    // reused children remain individually clean.
    markElementLayoutDirty(element);

    const old_children = element.children;
    const used = try allocator.alloc(bool, old_children.len);
    defer allocator.free(used);
    @memset(used, false);

    var old_top: usize = 0;
    var new_top: usize = 0;
    while (old_top < old_children.len and new_top < child_widgets.len and canUpdateElement(&old_children[old_top], &child_widgets[new_top])) {
        old_top += 1;
        new_top += 1;
    }

    var old_bottom = old_children.len;
    var new_bottom = child_widgets.len;
    while (old_bottom > old_top and new_bottom > new_top and canUpdateElement(&old_children[old_bottom - 1], &child_widgets[new_bottom - 1])) {
        old_bottom -= 1;
        new_bottom -= 1;
    }

    var keyed_children: KeyedChildMap = .empty;
    defer keyed_children.deinit(allocator);
    for (old_children[old_top..old_bottom], old_top..) |old_child, index| {
        if (old_child.key) |key| try keyed_children.put(allocator, key, index);
    }

    const new_children = try allocator.alloc(Element, child_widgets.len);
    for (new_children) |*child| {
        child.* = .{ .kind = .spacer, .widget = .{ .spacer = .{ .flex = 0 } } };
    }
    errdefer {
        for (old_children, 0..) |*old_child, index| {
            if (!used[index]) destroyElementTree(allocator, old_child);
        }
        allocator.free(old_children);
        // Reconciliation may already have updated moved children. Keep every
        // new slot valid and attach the partial result so an error never
        // leaves element.children pointing at the freed old slice.
        element.children = new_children;
        if (element.render_node) |node| {
            allocator.free(node.children);
            node.children = &.{};
            node.needs_layout = true;
        }
    }

    for (child_widgets[0..new_top], 0..) |*child_widget, index| {
        used[index] = true;
        new_children[index] = old_children[index];
        try updateElementTreeScoped(allocator, scope, &new_children[index], child_widget, constraints);
    }

    for (child_widgets[new_top..new_bottom], new_top..) |*child_widget, index| {
        if (widgetKey(child_widget.*)) |key| {
            if (keyed_children.get(key)) |old_index| {
                if (used[old_index] or !canUpdateElement(&old_children[old_index], child_widget)) {
                    new_children[index] = try buildElementTreeScoped(allocator, scope, child_widget, constraints);
                    continue;
                }
                used[old_index] = true;
                new_children[index] = old_children[old_index];
                try updateElementTreeScoped(allocator, scope, &new_children[index], child_widget, constraints);
                continue;
            }
        }

        new_children[index] = try buildElementTreeScoped(allocator, scope, child_widget, constraints);
    }

    const suffix_len = child_widgets.len - new_bottom;
    for (0..suffix_len) |offset| {
        const old_index = old_bottom + offset;
        const new_index = new_bottom + offset;
        used[old_index] = true;
        new_children[new_index] = old_children[old_index];
        try updateElementTreeScoped(allocator, scope, &new_children[new_index], &child_widgets[new_index], constraints);
    }

    for (old_children, 0..) |*old_child, index| {
        if (!used[index]) destroyElementTree(allocator, old_child);
    }
    allocator.free(old_children);
    destroyElementWidget(allocator, &element.widget);
    element.widget = element_widget;
    element.children = new_children;
}

fn childrenCanUpdateInPlace(children: []const Element, widgets_to_update: []const Widget) bool {
    if (children.len != widgets_to_update.len) return false;
    for (children, widgets_to_update) |*child, *widget| {
        if (!canUpdateElement(child, widget)) return false;
    }
    return true;
}

const KeyContext = struct {
    pub fn hash(_: @This(), key: Widget.Key) u64 {
        return switch (key) {
            .string => |value| std.hash.Wyhash.hash(0, value),
            .integer => |value| std.hash.Wyhash.hash(1, std.mem.asBytes(&value)),
        };
    }

    pub fn eql(_: @This(), a: Widget.Key, b: Widget.Key) bool {
        return keysEqual(a, b);
    }
};

const KeyedChildMap = std.HashMapUnmanaged(
    Widget.Key,
    usize,
    KeyContext,
    std.hash_map.default_max_load_percentage,
);

fn widgetKeysAreUnique(items: []const Widget) bool {
    for (items, 0..) |item, index| {
        const key = widgetKey(item) orelse continue;
        for (items[index + 1 ..]) |other| {
            const other_key = widgetKey(other) orelse continue;
            if (keysEqual(key, other_key)) return false;
        }
    }
    return true;
}

fn widgetKey(widget: Widget) ?Widget.Key {
    return switch (widget) {
        .keyed => |keyed_widget| keyed_widget.key,
        else => null,
    };
}

fn replaceElementWidget(allocator: std.mem.Allocator, element: *Element, widget: Widget) anyerror!void {
    var element_widget = try cloneWidgetForElement(allocator, widget);
    errdefer destroyElementWidget(allocator, &element_widget);
    markElementWidgetDirtyIfChanged(element, element_widget);
    destroyElementWidget(allocator, &element.widget);
    element.widget = element_widget;
}

fn replaceElementWidgetThemed(allocator: std.mem.Allocator, element: *Element, widget: Widget, theme: Theme, inherited_style: TextStyle) anyerror!void {
    var element_widget = try cloneWidgetForElementThemed(allocator, widget, theme, inherited_style);
    errdefer destroyElementWidget(allocator, &element_widget);
    markElementWidgetDirtyIfChanged(element, element_widget);
    destroyElementWidget(allocator, &element.widget);
    element.widget = element_widget;
}

fn markElementWidgetDirtyIfChanged(element: *Element, widget: Widget) void {
    if (!widgetLayoutEqual(element.widget, widget)) markElementLayoutDirty(element);
    if (!widgetPaintEqual(element.widget, widget)) {
        if (element.render_node) |node| {
            switch (element.widget) {
                .render_object => |old_object| switch (widget) {
                    .render_object => |new_object| if (old_object.vtable == new_object.vtable) {
                        if (new_object.vtable.damage) |damage| {
                            damage(old_object.ptr, new_object.ptr, node.rect, &node.damage);
                            node.paint_damage_precomputed = true;
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
        markElementPaintDirty(element);
    }
}

fn markElementPaintDirty(element: *Element) void {
    if (element.render_node) |node| {
        node.needs_layout = true;
        node.needs_paint = true;
    }
}

fn elementNeedsLayout(element: *const Element) bool {
    const node = element.render_node orelse return true;
    return node.needs_layout;
}

fn widgetLayoutEqual(a: Widget, b: Widget) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .text => |a_text| blk: {
            const b_text = b.text;
            break :blk std.mem.eql(u8, a_text.value, b_text.value) and
                a_text.font_size == b_text.font_size and
                a_text.line_height == b_text.line_height and
                a_text.max_lines == b_text.max_lines and
                a_text.overflow == b_text.overflow and
                a_text.line_break == b_text.line_break;
        },
        .box => |a_box| blk: {
            const b_box = b.box;
            break :blk a_box.min_width == b_box.min_width and
                a_box.min_height == b_box.min_height and
                a_box.horizontal_align == b_box.horizontal_align and
                a_box.vertical_align == b_box.vertical_align;
        },
        .scroll => |scroll| scroll.axes == b.scroll.axes,
        .list => |list| list.item_count == b.list.item_count and
            list.item_extent == b.list.item_extent and
            list.selected == b.list.selected and
            list.follow_end == b.list.follow_end,
        .text_input => |a_input| blk: {
            const b_input = b.text_input;
            break :blk std.mem.eql(u8, a_input.placeholder, b_input.placeholder) and
                a_input.obscured == b_input.obscured and
                a_input.padding_x == b_input.padding_x and
                a_input.padding_y == b_input.padding_y and
                a_input.font_size == b_input.font_size and
                a_input.line_height == b_input.line_height;
        },
        .separator => |separator| separator.thickness == b.separator.thickness and
            separator.margin == b.separator.margin and
            separator.axis == b.separator.axis,
        .spinner => |spinner| spinner.size == b.spinner.size,
        .row, .column => |children| children.gap == switch (b) {
            inline .row, .column => |other| other.gap,
            else => unreachable,
        } and children.cross_align == switch (b) {
            inline .row, .column => |other| other.cross_align,
            else => unreachable,
        } and children.main_align == switch (b) {
            inline .row, .column => |other| other.main_align,
            else => unreachable,
        },
        .spacer => |spacer| spacer.flex == b.spacer.flex,
        .flexible => |flexible| flexible.flex == b.flexible.flex and flexible.fit == b.flexible.fit,
        .sized => |sized| sized.width == b.sized.width and
            sized.height == b.sized.height and
            sized.min_width == b.sized.min_width and
            sized.min_height == b.sized.min_height and
            sized.max_width == b.sized.max_width and
            sized.max_height == b.sized.max_height,
        .padding => |padding| std.meta.eql(padding.insets, b.padding.insets),
        .render_object => false,
        else => true,
    };
}

fn widgetPaintEqual(a: Widget, b: Widget) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .text => |a_text| blk: {
            const b_text = b.text;
            break :blk std.mem.eql(u8, a_text.value, b_text.value) and
                std.meta.eql(a_text.color, b_text.color) and
                a_text.font_size == b_text.font_size and
                a_text.line_height == b_text.line_height and
                a_text.max_lines == b_text.max_lines and
                a_text.overflow == b_text.overflow and
                a_text.line_break == b_text.line_break;
        },
        .box => |a_box| blk: {
            const b_box = b.box;
            break :blk std.meta.eql(a_box.background, b_box.background) and
                std.meta.eql(a_box.border, b_box.border) and
                a_box.border_width == b_box.border_width and
                a_box.radius == b_box.radius and
                std.meta.eql(a_box.shadow, b_box.shadow);
        },
        .scroll => |scroll| std.meta.eql(scroll.scrollbar_track_color, b.scroll.scrollbar_track_color) and
            std.meta.eql(scroll.scrollbar_color, b.scroll.scrollbar_color),
        .list => |list| std.meta.eql(list.scrollbar_track_color, b.list.scrollbar_track_color) and
            std.meta.eql(list.scrollbar_color, b.list.scrollbar_color),
        .text_input => |a_input| blk: {
            const b_input = b.text_input;
            break :blk std.mem.eql(u8, a_input.placeholder, b_input.placeholder) and
                a_input.obscured == b_input.obscured and
                std.meta.eql(a_input.foreground, b_input.foreground) and
                std.meta.eql(a_input.background, b_input.background) and
                std.meta.eql(a_input.border, b_input.border) and
                std.meta.eql(a_input.focused_border, b_input.focused_border) and
                std.meta.eql(a_input.placeholder_foreground, b_input.placeholder_foreground) and
                a_input.padding_x == b_input.padding_x and
                a_input.padding_y == b_input.padding_y and
                a_input.radius == b_input.radius and
                a_input.font_size == b_input.font_size and
                a_input.line_height == b_input.line_height;
        },
        .separator => |separator| std.meta.eql(separator, b.separator),
        .spinner => |spinner| std.meta.eql(spinner, b.spinner),
        // Render objects own arbitrary paint behavior; only their
        // implementation can know whether two instances paint alike.
        .render_object => false,
        else => true,
    };
}

/// Refreshes payload fields borrowed from the retained widget even when
/// layout can stay cached. This prevents callback and id updates from forcing
/// geometry work while ensuring no render node points at a destroyed widget.
fn syncRenderNodeMetadata(element: *Element) void {
    const node = element.render_node orelse return;
    switch (element.widget) {
        .text => |text| if (!node.text_buffered) {
            node.text = text.value;
        },
        .clickable => |clickable| {
            node.clickable_id = clickable.id;
            node.click_callback = clickable.on_click;
            node.tap_down_callback = clickable.on_tap_down;
            node.tap_up_callback = clickable.on_tap_up;
            node.tap_cancel_callback = clickable.on_tap_cancel;
            node.scroll_event_callback = clickable.on_scroll;
            node.hover_change_callback = clickable.on_hover_change;
            node.click_buttons = clickable.buttons;
            node.click_activation = clickable.activation;
            node.click_cursor = clickable.cursor;
        },
        .focus => |focus| {
            node.focus_id = focus.node.id;
            node.focused = element.focused;
            node.autofocus = focus.autofocus;
            node.skip_traversal = focus.skip_traversal;
            node.can_request_focus = focus.can_request_focus;
            node.focus_change_callback = focus.on_focus_change;
        },
        .focus_scope => |focus_scope| {
            node.focus_scope_id = focus_scope.id;
            node.modal_focus_scope = focus_scope.modal;
        },
        .scroll => |scroll| node.scroll_id = scroll.id,
        .list => |list| node.scroll_id = list.id,
        .text_input => |input| {
            node.text_input_id = input.id;
            node.focus_id = input.focus_node.id;
            node.autofocus = input.autofocus;
            node.placeholder = input.placeholder;
        },
        else => {},
    }
}

fn cloneWidgetForElementThemed(allocator: std.mem.Allocator, widget: Widget, theme: Theme, inherited_style: TextStyle) !Widget {
    var result = try cloneWidgetForElement(allocator, widget);
    switch (result) {
        .text => |*text_widget| {
            const style = resolveTextStyle(theme, inherited_style, text_widget.*);
            text_widget.color = style.color;
            text_widget.font_size = style.font_size;
            text_widget.line_height = style.line_height;
        },
        .text_input => |*input_widget| {
            input_widget.foreground = input_widget.style.foreground orelse colors.ink;
            input_widget.background = input_widget.style.background orelse colors.transparent;
            input_widget.border = input_widget.style.border orelse colors.transparent;
            input_widget.focused_border = input_widget.style.focused_border orelse colors.transparent;
            input_widget.placeholder_foreground = input_widget.style.placeholder_foreground orelse colors.neutral10;
            input_widget.padding_x = input_widget.style.padding_x orelse 0;
            input_widget.padding_y = input_widget.style.padding_y orelse 0;
            input_widget.radius = input_widget.style.radius orelse 0;
            input_widget.font_size = input_widget.style.font_size orelse 16;
            input_widget.line_height = input_widget.style.line_height orelse 20;
        },
        .separator => |*separator| separator.color = separator.color orelse theme.separator_theme.color orelse theme.color_scheme.border,
        .spinner => |*spinner_widget| spinner_widget.color = spinner_widget.color orelse theme.color_scheme.foreground,
        .scroll => |*scroll_widget| {
            scroll_widget.scrollbar_track_color = scroll_widget.scrollbar_track_color orelse theme.scrollbar_theme.track orelse theme.color_scheme.surface_low;
            scroll_widget.scrollbar_color = scroll_widget.scrollbar_color orelse theme.scrollbar_theme.thumb orelse theme.color_scheme.muted;
        },
        .list => |*list_widget| {
            list_widget.scrollbar_track_color = list_widget.scrollbar_track_color orelse theme.scrollbar_theme.track orelse theme.color_scheme.surface_low;
            list_widget.scrollbar_color = list_widget.scrollbar_color orelse theme.scrollbar_theme.thumb orelse theme.color_scheme.muted;
        },
        else => {},
    }
    return result;
}

fn buildClickableChildElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    clickable_widget: Widget.Clickable,
    constraints: Constraints,
) !Element {
    const child = clickableStyledChild(clickable_widget, scope.interaction);
    return buildElementTreeScoped(allocator, scope, &child, constraints);
}

fn clickableStyledChild(clickable_widget: Widget.Clickable, interaction: InteractionState) Widget {
    var child = clickable_widget.child.*;
    if (clickableActiveBackground(clickable_widget, interaction)) |background| {
        switch (child) {
            .box => child.box.background = background,
            else => {},
        }
    }
    if (clickable_widget.focused_border) |border| {
        if (interaction.isFocused(.named(clickable_widget.id))) {
            switch (child) {
                .box => {
                    child.box.border = border;
                    child.box.border_width = clickable_widget.focused_border_width;
                },
                else => {},
            }
        }
    }
    return child;
}

fn applyClickableStateStyle(element: *Element, clickable_widget: Widget.Clickable, interaction: InteractionState) void {
    const value = clickableActiveBackground(clickable_widget, interaction) orelse
        clickableBaseBackground(clickable_widget) orelse return;
    switch (element.widget) {
        .box => element.widget.box.background = value,
        else => {},
    }
}

/// Background for the clickable's active interaction state; pressed wins
/// over hover. Null when neither state is active or styled.
fn clickableActiveBackground(clickable_widget: Widget.Clickable, interaction: InteractionState) ?Color {
    if (interaction.isPressed(clickable_widget.id)) {
        if (clickable_widget.pressed_style) |style| {
            if (style.background) |background| return background;
        }
    }
    if (interaction.isHovered(clickable_widget.id)) {
        if (clickable_widget.hover_style) |style| {
            if (style.background) |background| return background;
        }
    }
    return null;
}

/// The child's original background, captured into the state styles when
/// the widget was cloned for retention, so leaving hover/press restores it.
fn clickableBaseBackground(clickable_widget: Widget.Clickable) ?Color {
    if (clickable_widget.hover_style) |style| {
        if (style.base_background) |base| return base;
    }
    if (clickable_widget.pressed_style) |style| {
        if (style.base_background) |base| return base;
    }
    return null;
}

fn clickableStateStyle(style_value: ?Widget.ClickableStyle, child: *const Widget) ?Widget.ClickableStyle {
    var style = style_value orelse return null;
    if (style.background != null and style.base_background == null) {
        style.base_background = clickableChildBackground(child);
    }
    return style;
}

fn clickableChildBackground(child: *const Widget) ?Color {
    return switch (child.*) {
        .box => |box_widget| box_widget.background,
        else => null,
    };
}

fn cloneWidgetForElement(allocator: std.mem.Allocator, widget: Widget) !Widget {
    return switch (widget) {
        .keyed => |keyed_widget| .{ .keyed = .{
            .key = try cloneKey(allocator, keyed_widget.key),
            .child = keyed_widget.child,
        } },
        .text => |text_widget| .{ .text = .{
            .value = try allocator.dupe(u8, text_widget.value),
            .color = text_widget.color,
            .font_size = text_widget.font_size,
            .line_height = text_widget.line_height,
            .role = text_widget.role,
            .max_lines = text_widget.max_lines,
            .overflow = text_widget.overflow,
            .line_break = text_widget.line_break,
        } },
        .spacer => |spacer_widget| .{ .spacer = spacer_widget },
        .separator => |separator| .{ .separator = separator },
        .spinner => |spinner_widget| .{ .spinner = spinner_widget },
        .sized => |sized_widget| .{ .sized = sized_widget },
        .box => |box_widget| .{ .box = box_widget },
        .clickable => |clickable_widget| blk: {
            const id = try allocator.dupe(u8, clickable_widget.id);
            errdefer allocator.free(id);
            const intent = if (clickable_widget.intent) |intent_value| try cloneIntent(allocator, intent_value) else null;
            errdefer if (intent) |intent_value| destroyIntent(allocator, intent_value);
            const callback = if (clickable_widget.on_click) |on_click| try on_click.clone(allocator) else null;
            errdefer if (callback) |on_click| on_click.destroy(allocator);
            const tap_down = if (clickable_widget.on_tap_down) |on_tap_down| try on_tap_down.clone(allocator) else null;
            errdefer if (tap_down) |on_tap_down| on_tap_down.destroy(allocator);
            const tap_up = if (clickable_widget.on_tap_up) |on_tap_up| try on_tap_up.clone(allocator) else null;
            errdefer if (tap_up) |on_tap_up| on_tap_up.destroy(allocator);
            const tap_cancel = if (clickable_widget.on_tap_cancel) |on_tap_cancel| try on_tap_cancel.clone(allocator) else null;
            errdefer if (tap_cancel) |on_tap_cancel| on_tap_cancel.destroy(allocator);
            const scroll = if (clickable_widget.on_scroll) |on_scroll| try on_scroll.clone(allocator) else null;
            errdefer if (scroll) |on_scroll| on_scroll.destroy(allocator);
            const hover_change = if (clickable_widget.on_hover_change) |on_hover_change| try on_hover_change.clone(allocator) else null;
            errdefer if (hover_change) |on_hover_change| on_hover_change.destroy(allocator);
            break :blk .{ .clickable = .{
                .id = id,
                .child = clickable_widget.child,
                .on_click = callback,
                .intent = intent,
                .on_tap_down = tap_down,
                .on_tap_up = tap_up,
                .on_tap_cancel = tap_cancel,
                .on_scroll = scroll,
                .on_hover_change = hover_change,
                .buttons = clickable_widget.buttons,
                .activation = clickable_widget.activation,
                .hover_style = clickableStateStyle(clickable_widget.hover_style, clickable_widget.child),
                .pressed_style = clickableStateStyle(clickable_widget.pressed_style, clickable_widget.child),
                .focused_border = clickable_widget.focused_border,
                .focused_border_width = clickable_widget.focused_border_width,
                .cursor = clickable_widget.cursor,
            } };
        },
        .anchored => |anchored_widget| blk: {
            const id = try allocator.dupe(u8, anchored_widget.id);
            errdefer allocator.free(id);
            const popup = if (anchored_widget.popup) |popup_decl| try popup_decl.clone(allocator) else null;
            break :blk .{ .anchored = .{
                .id = id,
                .child = anchored_widget.child,
                .popup = popup,
            } };
        },
        .focus => |focus_widget| blk: {
            const focus_id = try allocator.dupe(u8, focus_widget.node.id);
            errdefer allocator.free(focus_id);
            const focus_change_callback = if (focus_widget.on_focus_change) |callback| try callback.clone(allocator) else null;
            errdefer if (focus_change_callback) |callback| callback.destroy(allocator);
            break :blk .{ .focus = .{
                .node = .named(focus_id),
                .child = focus_widget.child,
                .autofocus = focus_widget.autofocus,
                .skip_traversal = focus_widget.skip_traversal,
                .can_request_focus = focus_widget.can_request_focus,
                .on_focus_change = focus_change_callback,
            } };
        },
        .focus_scope => |focus_scope_widget| blk: {
            const id = try allocator.dupe(u8, focus_scope_widget.id);
            break :blk .{ .focus_scope = .{ .id = id, .child = focus_scope_widget.child, .modal = focus_scope_widget.modal } };
        },
        .scroll => |scroll_widget| blk: {
            const id = try allocator.dupe(u8, scroll_widget.id);
            break :blk .{ .scroll = .{
                .id = id,
                .child = scroll_widget.child,
                .axes = scroll_widget.axes,
                .scrollbar_track_color = scroll_widget.scrollbar_track_color,
                .scrollbar_color = scroll_widget.scrollbar_color,
            } };
        },
        .list => |list_widget| blk: {
            const id = try allocator.dupe(u8, list_widget.id);
            errdefer allocator.free(id);
            const builder = try list_widget.build_item.clone(allocator);
            break :blk .{ .list = .{
                .id = id,
                .item_count = list_widget.item_count,
                .item_extent = list_widget.item_extent,
                .build_item = builder,
                .selected = list_widget.selected,
                .follow_end = list_widget.follow_end,
                .scrollbar_track_color = list_widget.scrollbar_track_color,
                .scrollbar_color = list_widget.scrollbar_color,
            } };
        },
        .text_input => |input_widget| blk: {
            const id = try allocator.dupe(u8, input_widget.id);
            errdefer allocator.free(id);
            const focus_node_id = try allocator.dupe(u8, input_widget.focus_node.id);
            errdefer allocator.free(focus_node_id);
            const value = try allocator.dupe(u8, input_widget.value);
            errdefer allocator.free(value);
            const placeholder = try allocator.dupe(u8, input_widget.placeholder);
            errdefer allocator.free(placeholder);
            const on_change = if (input_widget.on_change) |callback| try callback.clone(allocator) else null;
            const on_submit = if (input_widget.on_submit) |callback| try callback.clone(allocator) else null;
            break :blk .{ .text_input = .{
                .id = id,
                .focus_node = .named(focus_node_id),
                .value = value,
                .placeholder = placeholder,
                .on_change = on_change,
                .on_submit = on_submit,
                .obscured = input_widget.obscured,
                .clear_on_submit = input_widget.clear_on_submit,
                .foreground = input_widget.foreground,
                .background = input_widget.background,
                .border = input_widget.border,
                .focused_border = input_widget.focused_border,
                .placeholder_foreground = input_widget.placeholder_foreground,
                .padding_x = input_widget.padding_x,
                .padding_y = input_widget.padding_y,
                .radius = input_widget.radius,
                .font_size = input_widget.font_size,
                .line_height = input_widget.line_height,
                .autofocus = input_widget.autofocus,
                .style = input_widget.style,
            } };
        },
        .row => |row_widget| .{ .row = .{ .children = &.{}, .gap = row_widget.gap, .cross_align = row_widget.cross_align, .main_align = row_widget.main_align } },
        .column => |column_widget| .{ .column = .{ .children = &.{}, .gap = column_widget.gap, .cross_align = column_widget.cross_align, .main_align = column_widget.main_align } },
        .padding => |padding_widget| .{ .padding = padding_widget },
        .center => |center_widget| .{ .center = center_widget },
        .flexible => |flexible_widget| .{ .flexible = flexible_widget },
        .actions => |actions_widget| .{ .actions = .{
            .bindings = try cloneActionBindings(allocator, actions_widget.bindings),
            .child = actions_widget.child,
        } },
        .shortcuts => |shortcuts_widget| .{ .shortcuts = .{
            .bindings = try cloneShortcutBindings(allocator, shortcuts_widget.bindings),
            .child = shortcuts_widget.child,
        } },
        .theme => |theme_widget| .{ .theme = theme_widget },
        .default_text_style => |default_text_style| .{ .default_text_style = default_text_style },
        .component => |component_widget| .{ .component = component_widget },
        .stateful => |stateful_widget| .{ .stateful = try stateful_widget.clone(allocator) },
        .element => |custom_element| .{ .element = try custom_element.clone(allocator) },
        .render_object => |render_object| .{ .render_object = try render_object.clone(allocator) },
    };
}

fn destroyElementWidget(allocator: std.mem.Allocator, widget: *Widget) void {
    switch (widget.*) {
        .keyed => |keyed_widget| destroyKey(allocator, keyed_widget.key),
        .text => |text_widget| allocator.free(text_widget.value),
        .spacer => {},
        .separator => {},
        .spinner => {},
        .sized => {},
        .clickable => |clickable_widget| {
            if (clickable_widget.on_click) |callback| callback.destroy(allocator);
            if (clickable_widget.on_tap_down) |callback| callback.destroy(allocator);
            if (clickable_widget.on_tap_up) |callback| callback.destroy(allocator);
            if (clickable_widget.on_tap_cancel) |callback| callback.destroy(allocator);
            if (clickable_widget.on_scroll) |callback| callback.destroy(allocator);
            if (clickable_widget.on_hover_change) |callback| callback.destroy(allocator);
            if (clickable_widget.intent) |intent| destroyIntent(allocator, intent);
            allocator.free(clickable_widget.id);
        },
        .anchored => |anchored_widget| {
            if (anchored_widget.popup) |popup_decl| popup_decl.destroy(allocator);
            allocator.free(anchored_widget.id);
        },
        .focus => |focus_widget| {
            if (focus_widget.on_focus_change) |callback| callback.destroy(allocator);
            allocator.free(focus_widget.node.id);
        },
        .focus_scope => |focus_scope_widget| allocator.free(focus_scope_widget.id),
        .scroll => |scroll_widget| allocator.free(scroll_widget.id),
        .list => |list_widget| {
            list_widget.build_item.destroy(allocator);
            allocator.free(list_widget.id);
        },
        .text_input => |input_widget| {
            if (input_widget.on_change) |callback| callback.destroy(allocator);
            if (input_widget.on_submit) |callback| callback.destroy(allocator);
            allocator.free(input_widget.id);
            allocator.free(input_widget.focus_node.id);
            if (input_widget.obscured) std.crypto.secureZero(u8, @constCast(input_widget.value));
            allocator.free(input_widget.value);
            allocator.free(input_widget.placeholder);
        },
        .stateful => |stateful_widget| stateful_widget.destroy(allocator),
        .render_object => |render_object| render_object.destroy(allocator),
        .element => |custom_element| custom_element.destroy(allocator),
        .actions => |actions_widget| destroyActionBindings(allocator, actions_widget.bindings),
        .shortcuts => |shortcuts_widget| destroyShortcutBindings(allocator, shortcuts_widget.bindings),
        .box, .row, .column, .padding, .center, .flexible, .theme, .default_text_style, .component => {},
    }
}

fn cloneActionBindings(allocator: std.mem.Allocator, bindings: []const Widget.ActionBinding) ![]Widget.ActionBinding {
    const result = try allocator.alloc(Widget.ActionBinding, bindings.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |binding| {
            allocator.free(binding.id);
            binding.callback.destroy(allocator);
            if (binding.invoke) |invoke| invoke.destroy(allocator);
            if (binding.input_schema_json) |schema| allocator.free(schema);
        }
        allocator.free(result);
    }
    for (bindings, 0..) |binding, index| {
        const id = try allocator.dupe(u8, binding.id);
        errdefer allocator.free(id);
        const callback = binding.callback.clone(allocator) catch |err| {
            return err;
        };
        errdefer callback.destroy(allocator);
        const invoke = if (binding.invoke) |invoke| try invoke.clone(allocator) else null;
        errdefer if (invoke) |action_callback| action_callback.destroy(allocator);
        const input_schema_json = if (binding.input_schema_json) |schema| try allocator.dupe(u8, schema) else null;
        result[index] = .{ .id = id, .callback = callback, .invoke = invoke, .input_schema_json = input_schema_json };
        initialized += 1;
    }
    return result;
}

fn destroyActionBindings(allocator: std.mem.Allocator, bindings: []const Widget.ActionBinding) void {
    for (bindings) |binding| {
        allocator.free(binding.id);
        binding.callback.destroy(allocator);
        if (binding.invoke) |invoke| invoke.destroy(allocator);
        if (binding.input_schema_json) |schema| allocator.free(schema);
    }
    allocator.free(bindings);
}

fn cloneShortcutBindings(allocator: std.mem.Allocator, bindings: []const Widget.ShortcutBinding) ![]Widget.ShortcutBinding {
    const result = try allocator.alloc(Widget.ShortcutBinding, bindings.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |binding| destroyIntent(allocator, binding.intent);
        allocator.free(result);
    }
    for (bindings, 0..) |binding, index| {
        result[index] = .{ .key = binding.key, .intent = try cloneIntent(allocator, binding.intent) };
        initialized += 1;
    }
    return result;
}

fn destroyShortcutBindings(allocator: std.mem.Allocator, bindings: []const Widget.ShortcutBinding) void {
    for (bindings) |binding| destroyIntent(allocator, binding.intent);
    allocator.free(bindings);
}

fn cloneIntent(allocator: std.mem.Allocator, intent: Intent) !Intent {
    const action_id = try allocator.dupe(u8, intent.action_id);
    errdefer allocator.free(action_id);
    return .{
        .action_id = action_id,
        .target_json = if (intent.target_json) |target| try allocator.dupe(u8, target) else null,
    };
}

fn destroyIntent(allocator: std.mem.Allocator, intent: Intent) void {
    allocator.free(intent.action_id);
    if (intent.target_json) |target| allocator.free(target);
}

fn cloneKey(allocator: std.mem.Allocator, key: Widget.Key) !Widget.Key {
    return switch (key) {
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .integer => |value| .{ .integer = value },
    };
}

fn destroyKey(allocator: std.mem.Allocator, key: Widget.Key) void {
    switch (key) {
        .string => |value| allocator.free(value),
        .integer => {},
    }
}

fn keysEqual(a: Widget.Key, b: Widget.Key) bool {
    return switch (a) {
        .string => |a_value| switch (b) {
            .string => |b_value| std.mem.eql(u8, a_value, b_value),
            .integer => false,
        },
        .integer => |a_value| switch (b) {
            .string => false,
            .integer => |b_value| a_value == b_value,
        },
    };
}

const paint_model = @import("paint.zig");

pub const paint = paint_model.paint;
pub const paintScaled = paint_model.paintScaled;
pub const paintDamagedScaled = paint_model.paintDamagedScaled;
pub const ScrollbarAxis = paint_model.ScrollbarAxis;
pub const ScrollbarThumbHit = paint_model.ScrollbarThumbHit;
pub const hitTestScrollbarThumb = paint_model.hitTestScrollbarThumb;
const roundedRectAlpha = paint_model.roundedRectAlpha;
const scrollbar_track_color = paint_model.scrollbar_track_color;
const scrollbar_color = paint_model.scrollbar_color;
const scrollbar_thickness = paint_model.scrollbar_thickness;
const scrollbar_margin = paint_model.scrollbar_margin;
const hit_testing_model = @import("hit_testing.zig");

pub const hitTestButton = hit_testing_model.hitTestButton;
pub const ClickHit = hit_testing_model.ClickHit;
pub const FocusTarget = hit_testing_model.FocusTarget;
pub const collectFocusTargets = hit_testing_model.collectFocusTargets;
pub const findFocusTarget = hit_testing_model.findFocusTarget;
pub const hitTestClick = hit_testing_model.hitTestClick;
pub const ScrollHit = hit_testing_model.ScrollHit;
pub const hitTestScrollCallback = hit_testing_model.hitTestScrollCallback;
pub const findClickHitById = hit_testing_model.findClickHitById;
pub const hitTestTextInput = hit_testing_model.hitTestTextInput;
pub const hitTestScroll = hit_testing_model.hitTestScroll;
pub const RevealAdjustment = hit_testing_model.RevealAdjustment;
pub const collectRevealAdjustments = hit_testing_model.collectRevealAdjustments;
pub const hitTestCursorShape = hit_testing_model.hitTestCursorShape;
const shortcuts_model = @import("shortcuts.zig");

pub const shortcutKeyForInput = shortcuts_model.shortcutKeyForInput;
pub const shortcutAllowedWhileEditing = shortcuts_model.shortcutAllowedWhileEditing;
pub const findShortcutAction = shortcuts_model.findShortcutAction;
pub const findFocusedShortcutAction = shortcuts_model.findFocusedShortcutAction;
const findActionForIntent = shortcuts_model.findActionForIntent;

const layout_model = @import("layout.zig");

const layoutElement = layout_model.layoutElement;
const markElementLayoutDirty = layout_model.markElementLayoutDirty;
const addRenderDamage = layout_model.addDamage;
const constrainSized = layout_model.constrainSized;
pub const collectDamage = layout_model.collectDamage;
pub const collectDamageRegion = layout_model.collectDamageRegion;
pub const translateNode = layout_model.translateNode;

var test_callback_state: u8 = 0;

fn testTapCallback() Widget.TapCallback {
    return .{ .ptr = &test_callback_state, .call_fn = testCallbackCall };
}

fn testCallbackCall(_: *anyopaque, _: TapEvent) !void {}

const TestListItems = struct {
    builds: ?*usize = null,

    fn builder(self: *const @This()) Widget.ItemBuilder {
        return .{ .ptr = self, .build_fn = build };
    }

    fn build(ptr: *const anyopaque, scope: *BuildScope, index: usize) !Widget {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        if (self.builds) |builds| builds.* += 1;
        const label = try std.fmt.allocPrint(scope.allocator, "item {d}", .{index});
        return .{ .text = .{ .value = label } };
    }
};

const VariableListItems = struct {
    heights: []const f32,

    fn builder(self: *const @This()) Widget.ItemBuilder {
        return .{ .ptr = self, .build_fn = build };
    }

    fn build(ptr: *const anyopaque, scope: *BuildScope, index: usize) !Widget {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        return widgets.sized(scope.allocator, widgets.text("row"), null, self.heights[index]);
    }
};

fn convergeTestList(
    allocator: std.mem.Allocator,
    build_allocator: std.mem.Allocator,
    element: *Element,
    constraints: Constraints,
) !*RenderNode {
    for (0..8) |_| {
        const root = try layoutElement(allocator, element, constraints, .{ .x = 0, .y = 0 }, .fixed);
        if (!anyListRangeStale(element)) return root;
        var scope: BuildScope = .{ .allocator = build_allocator };
        _ = try rebuildDirtyElementTreeScoped(allocator, &scope, element, constraints);
    }
    return error.ListDidNotStabilize;
}

const test_red: Color = Color.argb(0xff, 0xff, 0x00, 0x00);

test "raster cache reuses alpha image data across display lists" {
    const allocator = std.testing.allocator;

    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(allocator);
    var first_list: DisplayList = .{};
    defer first_list.deinit(allocator);
    var second_list: DisplayList = .{};
    defer second_list.deinit(allocator);

    {
        raster_cache.beginFrame();
        defer raster_cache.endFrame(allocator);
        const alpha = try raster_cache.insertAlpha(allocator, 42, 2, 2, try allocator.dupe(u8, &.{ 1, 2, 3, 4 }));
        try first_list.alphaImage(allocator, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, 2, 2, alpha, colors.white, 42);
    }
    const bytes_after_first = raster_cache.byte_usage;

    {
        raster_cache.beginFrame();
        defer raster_cache.endFrame(allocator);
        const alpha = raster_cache.cachedAlphaImage(42, 2, 2).?;
        try second_list.alphaImage(allocator, .{ .x = 2, .y = 2, .width = 2, .height = 2 }, 2, 2, alpha, colors.black, 42);
        const image = second_list.commands.items[0].alpha_image;
        try std.testing.expectEqual(@as(u32, 4), image.stride);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, image.alpha[0..2]);
        try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, image.alpha[image.stride..][0..2]);
        try std.testing.expectEqual(bytes_after_first, raster_cache.byte_usage);
        try std.testing.expectEqual(@as(u32, 1), raster_cache.alpha.count());
    }
}

test "rounded rect alpha covers fill and hollow border band" {
    const allocator = std.testing.allocator;
    const size = 16;

    const fill = try roundedRectAlpha(allocator, size, size, 4, null);
    defer allocator.free(fill);
    // Center is fully covered, the rounded-off corner is empty.
    try std.testing.expectEqual(@as(u8, 255), fill[8 * size + 8]);
    try std.testing.expectEqual(@as(u8, 0), fill[0]);

    const stroke = try roundedRectAlpha(allocator, size, size, 4, 2);
    defer allocator.free(stroke);
    // The band covers the edge but leaves the interior hollow.
    try std.testing.expectEqual(@as(u8, 255), stroke[1 * size + 8]);
    try std.testing.expectEqual(@as(u8, 0), stroke[8 * size + 8]);
    try std.testing.expectEqual(@as(u8, 0), stroke[0]);
}

test "scroll viewport clips content, clamps offset, and blocks hits outside" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();
    const build_allocator = build_arena.allocator();

    // Ten Fluent body rows at 20px: 200px of content in a 40px viewport.
    var rows: [10]Widget = undefined;
    for (&rows, 0..) |*row, index| {
        row.* = if (index == 9)
            try widgets.clickable(build_allocator, "last-row", widgets.text("row"), testTapCallback())
        else
            widgets.text("row");
    }
    const column = try widgets.column(build_allocator, &rows, 0);
    const scroll_widget = try widgets.scroll(build_allocator, "list", column);
    const constraints: Constraints = .{ .max_width = 100, .max_height = 40 };

    var scope: BuildScope = .{ .allocator = build_allocator };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &scroll_widget, constraints);
    defer destroyElementTree(retained_allocator, &element);
    const root = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(RenderNode.Kind, .scroll), root.kind);
    try std.testing.expectEqual(@as(f32, 40), root.rect.height);
    try std.testing.expectEqual(@as(f32, 0), root.children[0].rect.y);

    // The clickable in the last row sits below the viewport; the clip
    // blocks hits at its laid-out position.
    try std.testing.expectEqual(@as(?ClickHit, null), hitTestClick(root, .{ .x = 5, .y = 150 }, .left));
    try std.testing.expectEqualStrings("list", hitTestScroll(root, .{ .x = 5, .y = 20 }).?);

    // An absurd offset clamps to content minus viewport.
    scrollState(&element).offset_y = 1000;
    _ = dirtyScrollElement(&element, "list");
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(@as(f32, 160), scrollState(&element).offset_y);
    try std.testing.expectEqual(@as(f32, -160), root.children[0].rect.y);

    // Scrolled to the bottom, the last row is inside the viewport and
    // clickable again.
    try std.testing.expectEqualStrings("last-row", hitTestClick(root, .{ .x = 5, .y = 30 }, .left).?.id);

    // Paint clips the content to the viewport rect.
    var display_list: DisplayList = .{};
    defer display_list.deinit(retained_allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(retained_allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(retained_allocator);
    try paintScaled(retained_allocator, root, &display_list, &raster_cache, 1);
    var saw_viewport_clip = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .set_clip => |clip| if (clip) |rect| {
                if (std.meta.eql(rect, root.rect)) saw_viewport_clip = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_viewport_clip);
}

test "horizontal scroll clamps its axis and paints an overlay scrollbar thumb" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();
    const build_allocator = build_arena.allocator();

    // Ten 21px-wide cells: 210px of content in an 80px viewport.
    var cells: [10]Widget = undefined;
    for (&cells) |*cell| cell.* = widgets.text("row");
    const row = try widgets.row(build_allocator, &cells, 0);
    var scroll_widget = try widgets.scroll(build_allocator, "strip", row);
    scroll_widget.scroll.axes = .horizontal;
    const constraints: Constraints = .{ .max_width = 80, .max_height = 40 };

    var scope: BuildScope = .{ .allocator = build_allocator };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &scroll_widget, constraints);
    defer destroyElementTree(retained_allocator, &element);
    const root = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(f32, 80), root.rect.width);
    try std.testing.expectEqual(@as(f32, 210), root.children[0].rect.width);

    scrollState(&element).offset_x = 1000;
    revealScrollbar(&element, 0);
    _ = dirtyScrollElement(&element, "strip");
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(@as(f32, 130), scrollState(&element).offset_x);
    try std.testing.expectEqual(@as(f32, -130), root.children[0].rect.x);

    // The horizontal thumb shows along the bottom edge as a rounded pill
    // without painting Fluent's transparent overlay track.
    var display_list: DisplayList = .{};
    defer display_list.deinit(retained_allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(retained_allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(retained_allocator);
    try paintScaled(retained_allocator, root, &display_list, &raster_cache, 1);
    var saw_track = false;
    var saw_thumb = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .alpha_image => |image| {
                if (std.meta.eql(image.color, scrollbar_track_color) and image.rect.height == scrollbar_thickness) saw_track = true;
                if (std.meta.eql(image.color, scrollbar_color) and image.rect.height == scrollbar_thickness) saw_thumb = true;
            },
            else => {},
        }
    }
    try std.testing.expect(!saw_track);
    try std.testing.expect(saw_thumb);
}

test "virtualized list builds only the visible window and follows scroll" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    // 1000 items at 16px in a 48px viewport.
    const items: TestListItems = .{};
    const list_widget = widgets.list("big-list", 1000, 16, items.builder());
    const constraints: Constraints = .{ .max_width = 100, .max_height = 48 };

    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &list_widget, constraints);
    defer destroyElementTree(retained_allocator, &element);

    // Only the window is built, not 1000 elements.
    try std.testing.expect(element.children.len < 16);
    try std.testing.expectEqualStrings("item 0", element.children[0].widget.text.value);

    const root = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(@as(f32, 48), root.rect.height);
    try std.testing.expect(!anyListRangeStale(&element));

    // Jump halfway down: layout clamps, flags the stale window, and the
    // dirty pass rebuilds it around the new offset.
    listState(&element).offset = 8000;
    _ = dirtyScrollElement(&element, "big-list");
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expect(anyListRangeStale(&element));

    var rebuild_scope: BuildScope = .{ .allocator = build_arena.allocator() };
    try std.testing.expect(try rebuildDirtyElementTreeScoped(retained_allocator, &rebuild_scope, &element, constraints));
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expect(!anyListRangeStale(&element));

    const state = listState(&element);
    try std.testing.expectEqual(@as(usize, 498), state.first);
    var label_buffer: [16]u8 = undefined;
    const expected = try std.fmt.bufPrint(&label_buffer, "item {d}", .{state.first});
    try std.testing.expectEqualStrings(expected, element.children[0].widget.text.value);
    // The first built row sits just above the viewport.
    try std.testing.expect(root.children[0].rect.y <= 0);
}

test "list window reconciles rows across scroll and update" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    // 1000 items at 16px in a 48px viewport.
    var builds: usize = 0;
    const items: TestListItems = .{ .builds = &builds };
    const list_widget = widgets.list("reconcile-list", 1000, 16, items.builder());
    const constraints: Constraints = .{ .max_width = 100, .max_height = 48 };

    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &list_widget, constraints);
    defer destroyElementTree(retained_allocator, &element);
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);

    const window = element.children.len;
    try std.testing.expectEqual(window, builds);
    // Item 1's render node, tracked across the scroll below.
    const item_one_node = element.children[1].render_node.?;

    // Scroll three items down: the window shifts by one (buffer rows
    // absorb the rest), so exactly one row enters and one leaves.
    listState(&element).offset = 48;
    _ = dirtyScrollElement(&element, "reconcile-list");
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    var rebuild_scope: BuildScope = .{ .allocator = build_arena.allocator() };
    try std.testing.expect(try rebuildDirtyElementTreeScoped(retained_allocator, &rebuild_scope, &element, constraints));
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);

    // Only the entering row was built; retained rows kept their elements.
    try std.testing.expectEqual(@as(usize, 1), listState(&element).first);
    try std.testing.expectEqual(window + 1, builds);
    try std.testing.expectEqual(item_one_node, element.children[0].render_node.?);
    try std.testing.expectEqualStrings("item 1", element.children[0].widget.text.value);

    // A widget update re-runs the builder for every visible row but
    // reconciles into the retained elements instead of rebuilding them.
    const builds_before_update = builds;
    var updated_widget = widgets.list("reconcile-list", 1000, 16, items.builder());
    updated_widget.list.selected = 2;
    var update_scope: BuildScope = .{ .allocator = build_arena.allocator() };
    try updateElementTreeScoped(retained_allocator, &update_scope, &element, &updated_widget, constraints);

    try std.testing.expectEqual(builds_before_update + window, builds);
    try std.testing.expectEqual(item_one_node, element.children[0].render_node.?);
}

test "list follows controlled selection and leaves free scrolling alone" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    // 100 items at 16px in a 48px viewport (3 fully visible).
    const items: TestListItems = .{};
    var list_widget = widgets.list("select-list", 100, 16, items.builder());
    list_widget.list.selected = 10;
    list_widget.list.follow_end = true;
    const constraints: Constraints = .{ .max_width = 100, .max_height = 48 };

    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &list_widget, constraints);
    defer destroyElementTree(retained_allocator, &element);

    // The initial selection takes precedence over end following: item 10's
    // bottom lands at the viewport bottom.
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    const state = listState(&element);
    try std.testing.expectEqual(@as(f32, 11 * 16 - 48), state.offset);

    // Unchanged selection leaves free scrolling alone.
    state.offset = 40;
    markElementLayoutDirty(&element);
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(@as(f32, 40), state.offset);

    // Selection above the viewport snaps its top to the viewport top.
    element.widget.list.selected = 1;
    markElementLayoutDirty(&element);
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(@as(f32, 16), state.offset);

    // An already fully visible selection does not move the viewport.
    element.widget.list.selected = 2;
    markElementLayoutDirty(&element);
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(@as(f32, 16), state.offset);

    // Clearing the selection changes nothing until one appears again.
    element.widget.list.selected = null;
    markElementLayoutDirty(&element);
    _ = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(@as(f32, 16), state.offset);
}

test "variable-height list measures, stacks, scrolls, and invalidates on width change" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const heights = [_]f32{ 10, 20, 30, 40, 50, 60 };
    const items: VariableListItems = .{ .heights = &heights };
    const list_widget = widgets.list("variable-list", heights.len, null, items.builder());
    const constraints: Constraints = .{ .max_width = 100, .max_height = 45 };

    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &list_widget, constraints);
    defer destroyElementTree(retained_allocator, &element);

    var root = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);
    const state = listState(&element);
    try std.testing.expectEqual(@as(usize, 5), state.measured.count());
    for (root.children[1..], 1..) |child, index| {
        const previous = root.children[index - 1];
        try std.testing.expectApproxEqAbs(previous.rect.y + previous.rect.height, child.rect.y, 0.01);
    }

    // Scrolling into the final row builds and measures it without losing the
    // absolute item indices of the retained contiguous window.
    state.offset = 110;
    _ = dirtyScrollElement(&element, "variable-list");
    root = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);
    try std.testing.expectEqual(@as(usize, 2), state.first);
    try std.testing.expectEqual(@as(usize, heights.len), state.measured.count());
    try std.testing.expectApproxEqAbs(@as(f32, 210), state.contentExtent(element.widget.list), 0.01);
    for (root.children[1..], 1..) |child, index| {
        const previous = root.children[index - 1];
        try std.testing.expectApproxEqAbs(previous.rect.y + previous.rect.height, child.rect.y, 0.01);
    }

    // Non-layout tree walks synchronize count but cannot know the width a
    // flex child will actually receive, so they must retain measurements.
    try state.prepare(retained_allocator, element.widget.list, null);
    try std.testing.expectEqual(@as(usize, heights.len), state.measured.count());

    // Cached heights are width-specific; a reflow makes every row an
    // estimate again, while retaining prior heights as useful estimates.
    try state.prepare(retained_allocator, element.widget.list, 80);
    try std.testing.expectEqual(@as(usize, 0), state.measured.count());
    try std.testing.expectApproxEqAbs(@as(f32, 210), state.contentExtent(element.widget.list), 0.01);
}

test "variable-height list keeps the visible row anchored as estimates change" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    var heights: [1000]f32 = undefined;
    @memset(heights[0..], 10);
    @memset(heights[490..520], 80);
    const items: VariableListItems = .{ .heights = &heights };
    const list_widget = widgets.list("variable-anchor", heights.len, null, items.builder());
    const constraints: Constraints = .{ .max_width = 100, .max_height = 40 };

    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &list_widget, constraints);
    defer destroyElementTree(retained_allocator, &element);
    _ = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);

    const state = listState(&element);
    try std.testing.expectApproxEqAbs(@as(f32, 10), state.estimated_item_extent, 0.01);

    // Jump to row 500 under the initial estimate. Measuring the much taller
    // rows around it changes the global estimate, but row 500 must remain at
    // the same viewport position instead of jumping to another item.
    state.offset = 5000;
    _ = dirtyScrollElement(&element, "variable-anchor");
    const root = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);
    const anchor = state.captureScrollAnchor(element.widget.list).?;
    try std.testing.expectEqual(@as(usize, 500), anchor.index);
    try std.testing.expectApproxEqAbs(@as(f32, 0), anchor.offset_within_item, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), root.children[500 - state.first].rect.y, 0.01);
}

test "variable-height list follows appends then preserves free scrolling" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const heights = [_]f32{ 12, 24, 18, 36, 20, 28, 16, 40, 22, 30, 26, 44, 32 };
    const items: VariableListItems = .{ .heights = &heights };
    var list_widget = widgets.list("variable-follow", 12, null, items.builder());
    list_widget.list.selected = 11;
    const constraints: Constraints = .{ .max_width = 100, .max_height = 50 };

    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &list_widget, constraints);
    defer destroyElementTree(retained_allocator, &element);
    _ = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);

    const state = listState(&element);
    const selected_bottom = state.itemStart(element.widget.list, 11) + state.itemExtent(element.widget.list, 11);
    try std.testing.expectApproxEqAbs(selected_bottom, state.offset + constraints.max_height, 0.01);

    // Once estimates have converged, an unchanged selected value does not
    // snap a user who scrolls upward back to the selected row.
    state.offset = 20;
    _ = dirtyScrollElement(&element, "variable-follow");
    _ = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 20), state.offset, 0.01);

    // A newly appended selected row follows its bottom while its own height
    // and the preceding estimates converge.
    var appended_widget = widgets.list("variable-follow", heights.len, null, items.builder());
    appended_widget.list.selected = heights.len - 1;
    var update_scope: BuildScope = .{ .allocator = build_arena.allocator() };
    try updateElementTreeScoped(retained_allocator, &update_scope, &element, &appended_widget, constraints);
    _ = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);
    const appended_bottom = state.itemStart(element.widget.list, heights.len - 1) + state.itemExtent(element.widget.list, heights.len - 1);
    try std.testing.expectApproxEqAbs(appended_bottom, state.offset + constraints.max_height, 0.01);
}

test "variable-height list follows appends only while pinned to the end" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const heights = [_]f32{ 12, 24, 18, 36, 20, 28, 16, 40, 22, 30, 26, 44, 32, 20 };
    const items: VariableListItems = .{ .heights = &heights };
    var list_widget = widgets.list("follow-end", 11, null, items.builder());
    list_widget.list.follow_end = true;
    const constraints: Constraints = .{ .max_width = 100, .max_height = 50 };

    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &list_widget, constraints);
    defer destroyElementTree(retained_allocator, &element);
    _ = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);

    const state = listState(&element);
    try std.testing.expectApproxEqAbs(state.contentExtent(element.widget.list), state.offset + constraints.max_height, 0.01);

    // Appending while the user is reading history preserves their anchor.
    state.offset = 20;
    _ = dirtyScrollElement(&element, "follow-end");
    _ = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);
    var appended_widget = widgets.list("follow-end", 12, null, items.builder());
    appended_widget.list.follow_end = true;
    var update_scope: BuildScope = .{ .allocator = build_arena.allocator() };
    try updateElementTreeScoped(retained_allocator, &update_scope, &element, &appended_widget, constraints);
    _ = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 20), state.offset, 0.01);

    // Once the user returns to the end, the next append remains pinned.
    state.offset = state.contentExtent(element.widget.list) - constraints.max_height;
    _ = dirtyScrollElement(&element, "follow-end");
    _ = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);
    var pinned_widget = widgets.list("follow-end", heights.len, null, items.builder());
    pinned_widget.list.follow_end = true;
    var pinned_scope: BuildScope = .{ .allocator = build_arena.allocator() };
    try updateElementTreeScoped(retained_allocator, &pinned_scope, &element, &pinned_widget, constraints);
    _ = try convergeTestList(retained_allocator, build_arena.allocator(), &element, constraints);
    try std.testing.expectApproxEqAbs(state.contentExtent(element.widget.list), state.offset + constraints.max_height, 0.01);
}

test "variable-height cache resizes through empty lists" {
    var state: ListState = .{};
    defer state.deinit(std.testing.allocator);
    const items: TestListItems = .{};

    const growing = widgets.list("resize", 4, null, items.builder());
    try state.prepare(std.testing.allocator, growing.list, 100);
    try std.testing.expectEqual(@as(usize, 4), state.heights.items.len);
    try std.testing.expectEqual(@as(usize, 5), state.prefix.items.len);
    _ = state.recordMeasurement(3, 32);

    const shrinking = widgets.list("resize", 2, null, items.builder());
    try state.prepare(std.testing.allocator, shrinking.list, 100);
    try std.testing.expectEqual(@as(usize, 2), state.heights.items.len);
    try std.testing.expectEqual(@as(usize, 3), state.prefix.items.len);

    // Shrunk indices become new unknown rows if the count grows again.
    try state.prepare(std.testing.allocator, growing.list, 100);
    try std.testing.expect(!state.measured.isSet(3));
    try std.testing.expect(!state.ever_measured.isSet(3));

    const empty = widgets.list("resize", 0, null, items.builder());
    try state.prepare(std.testing.allocator, empty.list, 100);
    try std.testing.expectEqual(@as(usize, 0), state.heights.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.prefix.items.len);
    const range = listVisibleRange(empty.list, &state, 0, 100);
    try std.testing.expectEqual(@as(usize, 0), range.count);
}

test "variable-height cache retains prior row estimates across width changes" {
    var state: ListState = .{};
    defer state.deinit(std.testing.allocator);
    const items: TestListItems = .{};
    const list_widget = widgets.list("reflow", 4, null, items.builder());

    try state.prepare(std.testing.allocator, list_widget.list, 100);
    var changed = state.recordMeasurement(0, 10);
    changed = state.recordMeasurement(1, 20) or changed;
    _ = state.finishMeasurements(changed);

    try state.prepare(std.testing.allocator, list_widget.list, 80);
    try std.testing.expectEqual(@as(usize, 0), state.measured.count());
    try std.testing.expectEqual(@as(usize, 2), state.ever_measured.count());

    // The first row reflows, updating the global estimate for unknown rows.
    // Row 1 keeps its old width-specific height as a better per-row estimate
    // until it is measured at the new width.
    _ = state.finishMeasurements(state.recordMeasurement(0, 30));
    try std.testing.expectApproxEqAbs(@as(f32, 20), state.heights.items[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30), state.heights.items[2], 0.01);
}

test "tight flex reports an error under unbounded scroll constraints" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();
    const build_allocator = build_arena.allocator();

    const children = [_]Widget{ widgets.text("top"), widgets.spacer(1), widgets.text("bottom") };
    const column = try widgets.column(build_allocator, &children, 0);
    const scroll_widget = try widgets.scroll(build_allocator, "list", column);
    const constraints: Constraints = .{ .max_width = 100, .max_height = 40 };

    var scope: BuildScope = .{ .allocator = build_allocator };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &scroll_widget, constraints);
    defer destroyElementTree(retained_allocator, &element);
    try std.testing.expectError(
        error.UnboundedTightFlex,
        layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed),
    );
}

test "display list clip stack resolves nested intersections" {
    const allocator = std.testing.allocator;

    var display_list: DisplayList = .{};
    defer display_list.deinit(allocator);

    try display_list.pushClip(allocator, .{ .x = 10, .y = 10, .width = 100, .height = 50 });
    try display_list.pushClip(allocator, .{ .x = 0, .y = 0, .width = 40, .height = 200 });
    try display_list.popClip(allocator);
    try display_list.popClip(allocator);

    const commands = display_list.commands.items;
    try std.testing.expectEqual(@as(usize, 4), commands.len);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .width = 100, .height = 50 }, commands[0].set_clip.?);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .width = 30, .height = 50 }, commands[1].set_clip.?);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .width = 100, .height = 50 }, commands[2].set_clip.?);
    try std.testing.expectEqual(@as(?Rect, null), commands[3].set_clip);

    display_list.clearRetainingCapacity(allocator);
    try std.testing.expectEqual(@as(usize, 0), display_list.clip_stack.items.len);
}

test "text input paint clips its content" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const input = widgets.textInput("input", "overflowing value", "placeholder");
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &input, .{ .max_width = 60, .max_height = 40 });
    defer destroyElementTree(retained_allocator, &element);
    const root = try layoutElement(retained_allocator, &element, .{ .max_width = 60, .max_height = 40 }, .{ .x = 0, .y = 0 }, .fixed);

    var display_list: DisplayList = .{};
    defer display_list.deinit(retained_allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(retained_allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(retained_allocator);
    try paintScaled(retained_allocator, root, &display_list, &raster_cache, 1);

    var clip_active = false;
    var text_clipped = false;
    var last_clip: ?Rect = .{ .x = -1, .y = -1, .width = 0, .height = 0 };
    for (display_list.commands.items) |command| {
        switch (command) {
            .set_clip => |clip| {
                clip_active = clip != null;
                last_clip = clip;
            },
            .text => if (clip_active) {
                text_clipped = true;
            },
            else => {},
        }
    }
    try std.testing.expect(text_clipped);
    try std.testing.expectEqual(@as(?Rect, null), last_clip);
}

test "text input uses intrinsic width when unconstrained" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const input = widgets.textInput("input", "", "Name");
    const constraints: Constraints = .{ .max_width = std.math.inf(f32), .max_height = 40 };
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &input, constraints);
    defer destroyElementTree(retained_allocator, &element);
    const root = try layoutElement(retained_allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);

    // The low-level editable primitive contributes only its text metrics;
    // design-system fields compose padding around it in Lua.
    try std.testing.expectEqual(@as(f32, 32), root.rect.width);
    try std.testing.expectEqual(@as(f32, 20), root.rect.height);
}

test "layout, paint, and hit test a padded column" {
    const allocator = std.testing.allocator;

    const title: Widget = .{ .text = .{ .value = "Title" } };
    const label: Widget = .{ .text = .{ .value = "OK", .color = colors.white } };
    const button_padding: Widget = .{ .padding = .{ .insets = EdgeInsets.all(8), .child = &label } };
    const button_box: Widget = .{ .box = .{ .background = colors.accent, .child = &button_padding } };
    const button: Widget = .{ .clickable = .{ .id = "ok", .child = &button_box, .on_click = testTapCallback() } };
    const children = [_]Widget{ title, button };
    const column: Widget = .{ .column = .{ .children = &children, .gap = 4 } };
    const padded: Widget = .{ .padding = .{ .insets = EdgeInsets.all(10), .child = &column } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &padded, .{ .max_width = 200, .max_height = 120 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 200, .max_height = 120 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(RenderNode.Kind, .padding), root.kind);
    try std.testing.expectEqual(@as(f32, 55), root.rect.width);
    try std.testing.expectEqual(@as(f32, 80), root.rect.height);

    var display_list: DisplayList = .{};
    defer display_list.deinit(allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(allocator);
    try paint(allocator, root, &display_list, &raster_cache);

    try std.testing.expectEqual(@as(usize, 3), display_list.commands.items.len);
    try std.testing.expectEqualStrings("ok", hitTestButton(root, .{ .x = 25, .y = 45 }).?);
    try std.testing.expect(hitTestButton(root, .{ .x = 2, .y = 2 }) == null);
}

test "row spacer takes remaining main-axis space" {
    const allocator = std.testing.allocator;

    const children = [_]Widget{
        widgets.text("A"),
        widgets.spacer(1),
        widgets.text("B"),
    };
    const row = try widgets.row(allocator, &children, 0);
    defer allocator.free(row.row.children);

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &row, .{ .max_width = 100, .max_height = 20 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 20 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(RenderNode.Kind, .row), root.kind);
    try std.testing.expectEqual(@as(f32, 100), root.rect.width);
    try std.testing.expectEqual(@as(f32, 86), root.children[1].rect.width);
    try std.testing.expectEqual(@as(f32, 93), root.children[2].rect.x);
}

test "expanded children split the spare main axis by flex factor" {
    const allocator = std.testing.allocator;

    const first = try widgets.expandedFlex(allocator, widgets.text("B"), 1);
    defer allocator.destroy(first.flexible.child);
    const second = try widgets.expandedFlex(allocator, widgets.text("C"), 2);
    defer allocator.destroy(second.flexible.child);
    const children = [_]Widget{ widgets.text("A"), first, second };
    const row = try widgets.row(allocator, &children, 0);
    defer allocator.free(row.row.children);

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &row, .{ .max_width = 98, .max_height = 20 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 98, .max_height = 20 }, .{ .x = 0, .y = 0 }, .fixed);

    // Text A is 7px wide; the 91 spare pixels split by a 1:2 flex ratio.
    try std.testing.expectEqual(@as(f32, 98), root.rect.width);
    try std.testing.expectApproxEqAbs(@as(f32, 91.0 / 3.0), root.children[1].rect.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 182.0 / 3.0), root.children[2].rect.width, 0.001);
    try std.testing.expectEqual(@as(f32, 7), root.children[1].rect.x);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0 + 91.0 / 3.0), root.children[2].rect.x, 0.001);
    // Tight fit forces the wrapped child to fill the share too.
    try std.testing.expectApproxEqAbs(@as(f32, 91.0 / 3.0), root.children[1].children[0].rect.width, 0.001);
}

test "tight flexible box centers its child within the whole share" {
    const allocator = std.testing.allocator;

    const inner = widgets.text("B");
    const box: Widget = .{ .box = .{ .child = &inner, .vertical_align = .center } };
    const expanded = try widgets.expandedFlex(allocator, box, 1);
    defer allocator.destroy(expanded.flexible.child);
    const children = [_]Widget{ widgets.text("A"), expanded };
    const column = try widgets.column(allocator, &children, 0);
    defer allocator.free(column.column.children);

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &column, .{ .max_width = 100, .max_height = 48 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 48 }, .{ .x = 0, .y = 0 }, .fixed);

    // The 20px Fluent body line leaves a 28px expanded share.
    const flexible_node = root.children[1];
    const box_node = flexible_node.children[0];
    try std.testing.expectEqual(@as(f32, 28), flexible_node.rect.height);
    try std.testing.expectEqual(@as(f32, 28), box_node.rect.height);
    try std.testing.expectEqual(@as(f32, 20), box_node.rect.y);
    try std.testing.expectEqual(@as(f32, 24), box_node.children[0].rect.y);
}

test "stretch lays out children with tight cross constraints" {
    const allocator = std.testing.allocator;

    const inner = widgets.text("B");
    const box: Widget = .{ .box = .{ .child = &inner, .vertical_align = .center } };
    const children = [_]Widget{ widgets.text("A"), box };
    const row: Widget = .{ .row = .{ .children = &children, .gap = 0, .cross_align = .stretch } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &row, .{ .max_width = 100, .max_height = 40 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 40 }, .{ .x = 0, .y = 0 }, .fixed);

    // Stretch is a tight cross constraint, not a post-layout inflation:
    // children fill the row's whole 40px cross axis, and the box centers
    // its 20px child in the slack it knew about at alignment time.
    try std.testing.expectEqual(@as(f32, 40), root.rect.height);
    try std.testing.expectEqual(@as(f32, 40), root.children[0].rect.height);
    try std.testing.expectEqual(@as(f32, 40), root.children[1].rect.height);
    try std.testing.expectEqual(@as(f32, 10), root.children[1].children[0].rect.y);
}

test "sized passes parent min constraints through unspecified axes" {
    const allocator = std.testing.allocator;

    const inner = widgets.text("B");
    const box: Widget = .{ .box = .{ .child = &inner, .vertical_align = .center } };
    const sized_box = try widgets.sized(allocator, box, 50, null);
    defer allocator.destroy(sized_box.sized.child);
    const expanded = try widgets.expandedFlex(allocator, sized_box, 1);
    defer allocator.destroy(expanded.flexible.child);
    const children = [_]Widget{ widgets.text("A"), expanded };
    const column = try widgets.column(allocator, &children, 0);
    defer allocator.free(column.column.children);

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &column, .{ .max_width = 100, .max_height = 48 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 48 }, .{ .x = 0, .y = 0 }, .fixed);

    // The sized wrapper only pins its width; the expanded 28px height min
    // passes through it so the box still aligns against the whole share.
    const sized_node = root.children[1].children[0];
    const box_node = sized_node.children[0];
    try std.testing.expectEqual(@as(f32, 50), sized_node.rect.width);
    try std.testing.expectEqual(@as(f32, 28), sized_node.rect.height);
    try std.testing.expectEqual(@as(f32, 28), box_node.rect.height);
    try std.testing.expectEqual(@as(f32, 24), box_node.children[0].rect.y);
}

test "linear intrinsic children get an unbounded main axis" {
    const allocator = std.testing.allocator;

    const children = [_]Widget{widgets.text("ABCDEF")};
    const row = try widgets.row(allocator, &children, 0);
    defer allocator.free(row.row.children);

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &row, .{ .max_width = 10, .max_height = 20 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 10, .max_height = 20 }, .{ .x = 0, .y = 0 }, .fixed);

    // The 42px text keeps its intrinsic size and overflows the 10px row
    // instead of being clamped by the row's own max constraint.
    try std.testing.expectEqual(@as(f32, 42), root.children[0].rect.width);
    try std.testing.expectEqual(@as(f32, 10), root.rect.width);
}

test "loose flexible keeps its intrinsic size" {
    const allocator = std.testing.allocator;

    const loose = try widgets.flexible(allocator, widgets.text("B"), 1);
    defer allocator.destroy(loose.flexible.child);
    const children = [_]Widget{ widgets.text("A"), loose };
    const row = try widgets.row(allocator, &children, 0);
    defer allocator.free(row.row.children);

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &row, .{ .max_width = 100, .max_height = 20 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 20 }, .{ .x = 0, .y = 0 }, .fixed);

    // The loose child may use up to its 93px share but stays 7px wide.
    try std.testing.expectEqual(@as(f32, 7), root.children[1].rect.width);
    try std.testing.expectEqual(@as(f32, 7), root.children[1].rect.x);
    try std.testing.expectEqual(@as(f32, 100), root.rect.width);
}

test "main axis alignment distributes leftover space" {
    const allocator = std.testing.allocator;

    const children = [_]Widget{ widgets.text("A"), widgets.text("B") };

    inline for (.{
        .{ .main_align = Widget.MainAxisAlignment.space_between, .first = 0, .second = 93 },
        .{ .main_align = Widget.MainAxisAlignment.center, .first = 43, .second = 50 },
        .{ .main_align = Widget.MainAxisAlignment.end, .first = 86, .second = 93 },
        .{ .main_align = Widget.MainAxisAlignment.space_evenly, .first = 86.0 / 3.0, .second = 193.0 / 3.0 },
    }) |case| {
        const row = try widgets.rowWithOptions(allocator, &children, .{ .main_align = case.main_align });
        defer allocator.free(row.row.children);

        var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer built_arena.deinit();
        var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
        var built_element = try buildElementTreeScoped(allocator, &build_scope, &row, .{ .max_width = 100, .max_height = 20 });
        defer destroyElementTree(allocator, &built_element);
        const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 20 }, .{ .x = 0, .y = 0 }, .fixed);

        // A non-start alignment claims the full 100px main axis.
        try std.testing.expectEqual(@as(f32, 100), root.rect.width);
        try std.testing.expectApproxEqAbs(@as(f32, case.first), root.children[0].rect.x, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, case.second), root.children[1].rect.x, 0.001);
    }
}

test "row centers children on the cross axis" {
    const allocator = std.testing.allocator;

    const short = widgets.text("A");
    const tall = try widgets.sized(allocator, widgets.text("B"), null, 40);
    defer allocator.destroy(tall.sized.child);
    const children = [_]Widget{ short, tall };
    const row: Widget = .{ .row = .{ .children = &children, .gap = 0, .cross_align = .center } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &row, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(f32, 40), root.rect.height);
    try std.testing.expectEqual(@as(f32, 10), root.children[0].rect.y);
    try std.testing.expectEqual(@as(f32, 0), root.children[1].rect.y);
}

test "row baseline aligns mixed text sizes through an expanded wrapper" {
    const allocator = std.testing.allocator;

    const username: Widget = .{ .text = .{
        .value = "username",
        .font_size = 16,
        .line_height = 24,
    } };
    const timestamp: Widget = .{ .text = .{
        .value = "12:12 PM",
        .font_size = 12,
        .line_height = 14,
    } };
    const expanded_timestamp: Widget = .{ .flexible = .{ .child = &timestamp } };
    const children = [_]Widget{ username, expanded_timestamp };
    const row: Widget = .{ .row = .{
        .children = &children,
        .gap = 6,
        .cross_align = .baseline,
    } };

    var built_arena = std.heap.ArenaAllocator.init(allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &row, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    const username_node = root.children[0];
    const timestamp_node = root.children[1].children[0];
    const username_baseline = username_node.rect.y + 4 + 12.8;
    const timestamp_baseline = timestamp_node.rect.y + 1 + 9.6;
    try std.testing.expectApproxEqAbs(username_baseline, timestamp_baseline, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.2), timestamp_node.rect.y, 0.001);
    try std.testing.expectEqual(@as(f32, 24), root.rect.height);
}

test "text role resolves themed font size for layout and paint" {
    const allocator = std.testing.allocator;

    const label: Widget = .{ .text = .{ .value = "Hi", .role = .label } };
    const themed: Widget = .{ .theme = .{
        .theme = .{ .color_scheme = .light, .text_theme = .{ .label = .{ .color = colors.accent, .font_size = 22, .line_height = 30 } } },
        .child = &label,
    } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &themed, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    const text_node = root.children[0];
    try std.testing.expectEqual(@as(f32, 30), text_node.rect.height);
    try std.testing.expectEqual(@as(f32, 22), text_node.text_style.font_size);
    try std.testing.expectEqual(@as(?f32, 30), text_node.text_style.line_height);
    try std.testing.expectEqual(colors.accent, text_node.text_style.color);

    var display_list: DisplayList = .{};
    defer display_list.deinit(allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(allocator);
    try paint(allocator, root, &display_list, &raster_cache);

    try std.testing.expectEqual(@as(usize, 1), display_list.commands.items.len);
    try std.testing.expect(display_list.commands.items[0] == .text);
    try std.testing.expectEqual(@as(f32, 22), display_list.commands.items[0].text.style.font_size);
    try std.testing.expectEqual(@as(?f32, 30), display_list.commands.items[0].text.style.line_height);
    try std.testing.expectEqual(colors.accent, display_list.commands.items[0].text.style.color);
}

test "default Fluent label resolves 14px font and 20px line height" {
    const allocator = std.testing.allocator;
    const label: Widget = .{ .text = .{ .value = "Label", .role = .label } };

    var built_arena = std.heap.ArenaAllocator.init(allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &label, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(f32, 14), root.text_style.font_size);
    try std.testing.expectEqual(@as(?f32, 20), root.text_style.line_height);
    try std.testing.expectEqual(@as(f32, 20), root.rect.height);
}

test "wrapped text measures and paints with the same explicit line height" {
    const allocator = std.testing.allocator;
    const text_widget: Widget = .{ .text = .{
        .value = "abcd",
        .font_size = 10,
        .line_height = 20,
    } };

    var built_arena = std.heap.ArenaAllocator.init(allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &text_widget, .{ .max_width = 10, .max_height = 100 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 10, .max_height = 100 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqualStrings("ab\ncd", root.text.?);
    try std.testing.expectEqual(@as(f32, 40), root.rect.height);

    var display_list: DisplayList = .{};
    defer display_list.deinit(allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(allocator);
    try paint(allocator, root, &display_list, &raster_cache);

    try std.testing.expectEqual(@as(usize, 1), display_list.commands.items.len);
    try std.testing.expectEqualStrings("ab\ncd", display_list.commands.items[0].text.value);
    try std.testing.expectEqual(@as(?f32, 20), display_list.commands.items[0].text.style.line_height);
}

test "default text style overrides descendant text defaults" {
    const allocator = std.testing.allocator;

    const label = widgets.text("Inherited");
    const inherited = try widgets.defaultTextStyle(allocator, .{ .color = test_red, .font_size = 18 }, label);
    defer allocator.destroy(inherited.default_text_style.child);

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &inherited, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(RenderNode.Kind, .default_text_style), root.kind);
    try std.testing.expectEqual(test_red, root.children[0].text_style.color);
    try std.testing.expectEqual(@as(f32, 18), root.children[0].text_style.font_size);
    try std.testing.expectEqual(@as(?f32, null), root.children[0].text_style.line_height);
    try std.testing.expectEqual(@as(f32, 18), root.children[0].rect.height);
}

test "linear element clone preserves cross-axis alignment" {
    const allocator = std.testing.allocator;

    const child = widgets.text("A");
    const children = [_]Widget{child};
    const row: Widget = .{ .row = .{ .children = &children, .cross_align = .center } };
    const column: Widget = .{ .column = .{ .children = &children, .cross_align = .end } };

    var row_element = try buildElementTree(allocator, &row, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(allocator, &row_element);
    var column_element = try buildElementTree(allocator, &column, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(allocator, &column_element);

    try std.testing.expectEqual(Widget.CrossAxisAlignment.center, row_element.widget.row.cross_align);
    try std.testing.expectEqual(Widget.CrossAxisAlignment.end, column_element.widget.column.cross_align);
}

test "rounded box paints alpha images for fill and border" {
    const allocator = std.testing.allocator;

    const child = widgets.text("A");
    const box: Widget = .{ .box = .{ .child = &child, .background = colors.panel, .border = colors.accent, .border_width = 2, .radius = 5 } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &box, .{ .max_width = 100, .max_height = 40 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 40 }, .{ .x = 0, .y = 0 }, .fixed);

    var display_list: DisplayList = .{};
    defer display_list.deinit(allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(allocator);
    try paintScaled(allocator, root, &display_list, &raster_cache, 1.5);

    try std.testing.expectEqual(@as(usize, 3), display_list.commands.items.len);
    try std.testing.expect(display_list.commands.items[0] == .alpha_image);
    try std.testing.expect(display_list.commands.items[1] == .alpha_image);
    try std.testing.expect(display_list.commands.items[2] == .text);
}

test "box aligns child inside its minimum size" {
    const allocator = std.testing.allocator;

    const child = widgets.text("A");
    const box: Widget = .{ .box = .{
        .child = &child,
        .min_width = 40,
        .min_height = 40,
        .horizontal_align = .center,
        .vertical_align = .center,
    } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &box, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(f32, 40), root.rect.width);
    try std.testing.expectEqual(@as(f32, 40), root.rect.height);
    try std.testing.expectEqual(@as(f32, 16.5), root.children[0].rect.x);
    try std.testing.expectEqual(@as(f32, 10), root.children[0].rect.y);
}

test "separator fills its cross axis and reserves main-axis margins" {
    const allocator = std.testing.allocator;
    const widget: Widget = .{ .separator = .{ .thickness = 2, .margin = 3 } };
    var element = try buildElementTree(allocator, &widget, .{ .max_width = 80, .max_height = 20 });
    defer destroyElementTree(allocator, &element);
    const node = try layoutElement(allocator, &element, .{ .max_width = 80, .max_height = 20 }, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(@as(f32, 80), node.rect.width);
    try std.testing.expectEqual(@as(f32, 8), node.rect.height);
    try std.testing.expectEqual(Widget.Separator.Axis.horizontal, node.separator_axis);
}

test "theme selects light and dark defaults from color scheme" {
    try std.testing.expectEqual(Theme.light.color_scheme.primary, Theme.fromColorScheme("light").color_scheme.primary);
    try std.testing.expectEqual(Theme.dark.color_scheme.primary, Theme.fromColorScheme("dark").color_scheme.primary);
    try std.testing.expectEqual(Theme.light.color_scheme.primary, Theme.fromColorScheme("no-preference").color_scheme.primary);
}

test "editable text keeps mechanical defaults under an ambient theme" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const children = [_]Widget{
        widgets.text("plain"),
        widgets.textInput("input", "", "placeholder"),
    };
    const column = try widgets.column(build_arena.allocator(), &children, 4);
    const themed = try widgets.theme(build_arena.allocator(), Theme.dark, column);
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &themed, .{ .max_width = 200, .max_height = 120 });
    defer destroyElementTree(retained_allocator, &element);
    const root = try layoutElement(retained_allocator, &element, .{ .max_width = 200, .max_height = 120 }, .{ .x = 0, .y = 0 }, .fixed);

    const text_node = root.children[0].children[0];
    const input_node = root.children[0].children[1];
    try std.testing.expectEqual(Theme.dark.color_scheme.foreground, text_node.foreground);
    try std.testing.expectEqual(colors.transparent, input_node.background);
    try std.testing.expectEqual(colors.transparent, input_node.border);
    try std.testing.expectEqual(colors.neutral10, input_node.placeholder_foreground);
}

test "text input derives focus from ambient focus node" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const input = widgets.textInputWithFocusNode("input", .named("field-focus"), "", "placeholder");
    var scope: BuildScope = .{
        .allocator = build_arena.allocator(),
        .interaction = .{ .focused_id = "field-focus" },
    };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &input, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(retained_allocator, &element);
    const root = try layoutElement(retained_allocator, &element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expect(root.focused);
    try std.testing.expectEqualStrings("field-focus", root.focus_id.?);
    try std.testing.expectEqualStrings("field-focus", hitTestTextInput(root, .{ .x = 1, .y = 1 }).?);
}

test "focus targets are collected in render tree order" {
    const allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(allocator);
    defer build_arena.deinit();
    const build_allocator = build_arena.allocator();

    const input = widgets.textInput("input", "", "placeholder");
    const button = try widgets.clickable(build_allocator, "button", widgets.text("Button"), testTapCallback());
    const children = [_]Widget{ input, button };
    const column = try widgets.column(build_allocator, &children, 4);
    var scope: BuildScope = .{ .allocator = build_allocator };
    var element = try buildElementTreeScoped(allocator, &scope, &column, .{ .max_width = 200, .max_height = 120 });
    defer destroyElementTree(allocator, &element);
    const root = try layoutElement(allocator, &element, .{ .max_width = 200, .max_height = 120 }, .{ .x = 0, .y = 0 }, .fixed);

    const targets = try collectFocusTargets(allocator, root);
    defer allocator.free(targets);
    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqualStrings("input", targets[0].id);
    try std.testing.expectEqual(FocusTarget.Kind.text_input, targets[0].kind);
    try std.testing.expectEqualStrings("button", targets[1].id);
    try std.testing.expectEqual(FocusTarget.Kind.clickable, targets[1].kind);
    try std.testing.expectEqual(FocusTarget.Kind.clickable, findFocusTarget(root, "button").?.kind);
}

test "focus widget makes arbitrary subtree focusable" {
    const allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(allocator);
    defer build_arena.deinit();

    const label = widgets.text("Focusable text");
    const focus = try widgets.focus(build_arena.allocator(), .named("label-focus"), label);

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &focus, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    const targets = try collectFocusTargets(allocator, root);
    defer allocator.free(targets);
    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("label-focus", targets[0].id);
    try std.testing.expectEqual(FocusTarget.Kind.focus, targets[0].kind);
    try std.testing.expectEqual(FocusTarget.Kind.focus, findFocusTarget(root, "label-focus").?.kind);
}

test "center moves descendants" {
    const allocator = std.testing.allocator;

    const label: Widget = .{ .text = .{ .value = "Run" } };
    const button: Widget = .{ .clickable = .{ .id = "centered", .child = &label, .on_click = testTapCallback() } };
    const center: Widget = .{ .center = .{ .child = &button } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &center, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(allocator, &built_element);
    const root = try layoutElement(allocator, &built_element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(f32, 39.5), root.children[0].rect.x);
    try std.testing.expectEqual(@as(f32, 30), root.children[0].rect.y);
    try std.testing.expectEqualStrings("centered", hitTestButton(root, .{ .x = 40, .y = 35 }).?);
}

test "clickable carries opaque callback handles through hit testing" {
    const Counter = struct {
        value: usize = 0,

        fn increment(ptr: *anyopaque, _: TapEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.value += 1;
        }
    };

    var counter: Counter = .{};
    var updated_counter: Counter = .{};
    const label: Widget = .{ .text = .{ .value = "Count" } };
    const button: Widget = .{ .clickable = .{
        .id = "counter",
        .child = &label,
        .on_click = .{ .ptr = &counter, .call_fn = Counter.increment },
    } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(std.testing.allocator, &build_scope, &button, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &built_element);
    const root = try layoutElement(std.testing.allocator, &built_element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    const hit = hitTestClick(root, .{ .x = 2, .y = 2 }, .left).?;
    try std.testing.expectEqualStrings("counter", hit.id);
    try hit.callback.?.call(.{ .source = .keyboard });
    try std.testing.expectEqual(@as(usize, 1), counter.value);

    _ = collectDamage(root);
    const updated: Widget = .{ .clickable = .{
        .id = "updated-counter",
        .child = &label,
        .on_click = .{ .ptr = &updated_counter, .call_fn = Counter.increment },
    } };
    try updateElementTree(std.testing.allocator, &built_element, &updated, .{ .max_width = 100, .max_height = 80 });

    // Callback-only updates refresh borrowed render metadata without
    // invalidating otherwise cached layout.
    try std.testing.expect(!root.needs_layout);
    const updated_hit = hitTestClick(root, .{ .x = 2, .y = 2 }, .left).?;
    try std.testing.expectEqualStrings("updated-counter", updated_hit.id);
    try updated_hit.callback.?.call(.{ .source = .keyboard });
    try std.testing.expectEqual(@as(usize, 1), counter.value);
    try std.testing.expectEqual(@as(usize, 1), updated_counter.value);
}

test "clickable applies hover background style" {
    const allocator = std.testing.allocator;
    const label = widgets.text("chip");
    const box: Widget = .{ .box = .{
        .child = &label,
        .background = colors.transparent,
    } };
    const chip: Widget = .{ .clickable = .{
        .id = "chip",
        .child = &box,
        .hover_style = .{ .background = colors.blue9 },
    } };

    var built_arena = std.heap.ArenaAllocator.init(allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{
        .allocator = built_arena.allocator(),
        .interaction = .{ .hovered_id = "chip" },
    };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &chip, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(allocator, &built_element);

    try std.testing.expectEqual(colors.blue9, built_element.children[0].widget.box.background);
}

test "clickable hover refresh updates painted background" {
    const allocator = std.testing.allocator;
    const label = widgets.text("chip");
    const box: Widget = .{ .box = .{
        .child = &label,
        .background = colors.transparent,
    } };
    const chip: Widget = .{ .clickable = .{
        .id = "chip",
        .child = &box,
        .hover_style = .{ .background = colors.blue9 },
    } };
    const constraints: Constraints = .{ .max_width = 100, .max_height = 80 };

    var built_arena = std.heap.ArenaAllocator.init(allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &chip, constraints);
    defer destroyElementTree(allocator, &built_element);

    var root = try layoutElement(allocator, &built_element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(colors.transparent, root.children[0].background);

    build_scope.interaction = .{ .hovered_id = "chip" };
    try std.testing.expect(try refreshInteractionElements(allocator, &build_scope, &built_element, constraints, &.{"chip"}));
    root = try layoutElement(allocator, &built_element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(colors.blue9, root.children[0].background);
}

test "clickable keeps hover background through tree update" {
    const allocator = std.testing.allocator;
    const label = widgets.text("chip");
    const box: Widget = .{ .box = .{
        .child = &label,
        .background = colors.transparent,
    } };
    const chip: Widget = .{ .clickable = .{
        .id = "chip",
        .child = &box,
        .hover_style = .{ .background = colors.blue9 },
    } };
    const constraints: Constraints = .{ .max_width = 100, .max_height = 80 };

    var built_arena = std.heap.ArenaAllocator.init(allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{
        .allocator = built_arena.allocator(),
        .interaction = .{ .hovered_id = "chip" },
    };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &chip, constraints);
    defer destroyElementTree(allocator, &built_element);
    try std.testing.expectEqual(colors.blue9, built_element.children[0].widget.box.background);

    // A rebuild while the pointer rests on the target must not drop the
    // hover style (regression: status updates wiped hover highlights).
    try updateElementTreeScoped(allocator, &build_scope, &built_element, &chip, constraints);
    try std.testing.expectEqual(colors.blue9, built_element.children[0].widget.box.background);
}

test "clickable pressed style wins over hover and releases back to base" {
    const allocator = std.testing.allocator;
    const label = widgets.text("chip");
    const box: Widget = .{ .box = .{
        .child = &label,
        .background = colors.transparent,
    } };
    const chip: Widget = .{ .clickable = .{
        .id = "chip",
        .child = &box,
        .hover_style = .{ .background = colors.blue9 },
        .pressed_style = .{ .background = colors.red9 },
    } };
    const constraints: Constraints = .{ .max_width = 100, .max_height = 80 };

    var built_arena = std.heap.ArenaAllocator.init(allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &chip, constraints);
    defer destroyElementTree(allocator, &built_element);

    build_scope.interaction = .{ .hovered_id = "chip", .pressed_id = "chip" };
    try std.testing.expect(try refreshInteractionElements(allocator, &build_scope, &built_element, constraints, &.{"chip"}));
    var root = try layoutElement(allocator, &built_element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(colors.red9, root.children[0].background);

    build_scope.interaction = .{ .hovered_id = "chip" };
    try std.testing.expect(try refreshInteractionElements(allocator, &build_scope, &built_element, constraints, &.{"chip"}));
    root = try layoutElement(allocator, &built_element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(colors.blue9, root.children[0].background);

    build_scope.interaction = .{};
    try std.testing.expect(try refreshInteractionElements(allocator, &build_scope, &built_element, constraints, &.{"chip"}));
    root = try layoutElement(allocator, &built_element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(colors.transparent, root.children[0].background);
}

test "clickable focused border applies to box child" {
    const allocator = std.testing.allocator;
    const label = widgets.text("chip");
    const box: Widget = .{ .box = .{
        .child = &label,
        .background = colors.transparent,
    } };
    const chip: Widget = .{ .clickable = .{
        .id = "chip",
        .child = &box,
        .focused_border = colors.blue9,
    } };

    var built_arena = std.heap.ArenaAllocator.init(allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{
        .allocator = built_arena.allocator(),
        .interaction = .{ .focused_id = "chip" },
    };
    var built_element = try buildElementTreeScoped(allocator, &build_scope, &chip, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(allocator, &built_element);

    try std.testing.expectEqual(colors.blue9, built_element.children[0].widget.box.border.?);
}

test "anchored elements declare popups with laid-out anchor rects" {
    const popup_builder = struct {
        fn build(_: *const anyopaque, _: *BuildScope, _: Widget.BuildContext) anyerror!Widget {
            return .{ .text = .{ .value = "menu" } };
        }
    };
    const label: Widget = .{ .text = .{ .value = "Clock" } };
    const anchored: Widget = .{ .anchored = .{
        .id = "clock",
        .child = &label,
        .popup = .{
            .builder = .{ .ptr = undefined, .build_fn = popup_builder.build },
            .placement = .{ .edge = .top, .alignment = .center, .gap = 4 },
        },
    } };
    const padded: Widget = .{ .padding = .{ .insets = .{ .left = 10, .top = 5 }, .child = &anchored } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(std.testing.allocator, &build_scope, &padded, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &built_element);
    _ = try layoutElement(std.testing.allocator, &built_element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    var requests: std.ArrayList(PopupRequest) = .empty;
    defer requests.deinit(std.testing.allocator);
    try collectPopupRequests(std.testing.allocator, &built_element, &requests);

    try std.testing.expectEqual(@as(usize, 1), requests.items.len);
    const request = requests.items[0];
    try std.testing.expectEqualStrings("clock", request.id);
    try std.testing.expectEqual(@as(f32, 10), request.anchor_rect.x);
    try std.testing.expectEqual(@as(f32, 5), request.anchor_rect.y);
    try std.testing.expectEqual(Widget.PopupPlacement.Edge.top, request.popup.placement.edge);
    try std.testing.expectEqual(Widget.Alignment.center, request.popup.placement.alignment);
    try std.testing.expectEqual(@as(f32, 4), request.popup.placement.gap);
}

test "anchored without popup declares nothing and stays hit-testable" {
    const inner_label: Widget = .{ .text = .{ .value = "Clock" } };
    const clickable: Widget = .{ .clickable = .{
        .id = "clock-tap",
        .child = &inner_label,
        .on_click = testTapCallback(),
    } };
    const anchored: Widget = .{ .anchored = .{ .id = "clock", .child = &clickable } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(std.testing.allocator, &build_scope, &anchored, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &built_element);
    const root = try layoutElement(std.testing.allocator, &built_element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    var requests: std.ArrayList(PopupRequest) = .empty;
    defer requests.deinit(std.testing.allocator);
    try collectPopupRequests(std.testing.allocator, &built_element, &requests);
    try std.testing.expectEqual(@as(usize, 0), requests.items.len);

    const hit = hitTestClick(root, .{ .x = 2, .y = 2 }, .left).?;
    try std.testing.expectEqualStrings("clock-tap", hit.id);
}

test "clickable hit testing carries activation mode" {
    const label: Widget = .{ .text = .{ .value = "Press" } };
    const button: Widget = .{ .clickable = .{
        .id = "pressable",
        .child = &label,
        .on_click = testTapCallback(),
        .activation = .press,
    } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(std.testing.allocator, &build_scope, &button, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &built_element);
    const root = try layoutElement(std.testing.allocator, &built_element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    const hit = hitTestClick(root, .{ .x = 2, .y = 2 }, .left).?;
    try std.testing.expectEqual(Widget.ClickActivation.press, hit.activation);
}

test "clickable hit testing carries gesture callbacks" {
    const label: Widget = .{ .text = .{ .value = "Gesture" } };
    const button: Widget = .{ .clickable = .{
        .id = "gesture",
        .child = &label,
        .on_tap_down = testTapCallback(),
        .on_tap_up = testTapCallback(),
        .on_tap_cancel = testTapCallback(),
    } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(std.testing.allocator, &build_scope, &button, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &built_element);
    const root = try layoutElement(std.testing.allocator, &built_element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    const hit = hitTestClick(root, .{ .x = 2, .y = 2 }, .left).?;
    try std.testing.expect(hit.tap_down != null);
    try std.testing.expect(hit.tap_up != null);
    try std.testing.expect(hit.tap_cancel != null);
}

test "clickable without callback is inert" {
    const label: Widget = .{ .text = .{ .value = "Inert" } };
    const clickable: Widget = .{ .clickable = .{ .id = "inert", .child = &label } };

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(std.testing.allocator, &build_scope, &clickable, .{ .max_width = 100, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &built_element);
    const root = try layoutElement(std.testing.allocator, &built_element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(?ClickHit, null), hitTestClick(root, .{ .x = 2, .y = 2 }, .left));
    const targets = try collectFocusTargets(std.testing.allocator, root);
    defer std.testing.allocator.free(targets);
    try std.testing.expectEqual(@as(usize, 0), targets.len);
}

test "shortcuts invoke ambient actions" {
    const Counter = struct {
        value: usize = 0,

        fn increment(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.value += 1;
        }
    };

    const allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(allocator);
    defer build_arena.deinit();

    var counter: Counter = .{};
    const child = widgets.text("Shortcut child");
    const shortcut_bindings = [_]Widget.ShortcutBinding{.{ .key = .enter, .intent = .action("increment") }};
    const action_bindings = [_]Widget.ActionBinding{.{ .id = "increment", .callback = .{ .ptr = &counter, .call_fn = Counter.increment } }};
    const shortcuts_widget = try widgets.shortcuts(build_arena.allocator(), &shortcut_bindings, child);
    const actions_widget = try widgets.actions(build_arena.allocator(), &action_bindings, shortcuts_widget);

    var element = try buildElementTree(allocator, &actions_widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &element);

    const callback = findShortcutAction(&element, .enter).?;
    try callback.call();
    try std.testing.expectEqual(@as(usize, 1), counter.value);
    try std.testing.expect(findShortcutAction(&element, .space) == null);
}

test "button and shortcut can share an intent" {
    const Counter = struct {
        value: usize = 0,

        fn increment(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.value += 1;
        }
    };

    const allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(allocator);
    defer build_arena.deinit();

    var counter: Counter = .{};
    const intent = Intent.action("increment");
    var button = try widgets.clickable(build_arena.allocator(), "increment-button", widgets.text("Increment"), null);
    button.clickable.intent = intent;
    button.clickable.activation = .release;
    const shortcut_bindings = [_]Widget.ShortcutBinding{.{ .key = .enter, .intent = intent }};
    const action_bindings = [_]Widget.ActionBinding{.{ .id = "increment", .callback = .{ .ptr = &counter, .call_fn = Counter.increment } }};
    const root_widget = try widgets.actions(
        build_arena.allocator(),
        &action_bindings,
        try widgets.shortcuts(build_arena.allocator(), &shortcut_bindings, button),
    );

    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(allocator, &scope, &root_widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &element);
    const root = try layoutElement(allocator, &element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    try findShortcutAction(&element, .enter).?.call();
    const hit = hitTestClick(root, .{ .x = 2, .y = 2 }, .left).?;
    try hit.callback.?.call(.{ .source = .keyboard });
    try std.testing.expectEqual(@as(usize, 2), counter.value);

    try updateElementTreeScoped(allocator, &scope, &element, &root_widget, .{ .max_width = 200, .max_height = 80 });
    const updated_root = try layoutElement(allocator, &element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);
    const updated_hit = hitTestClick(updated_root, .{ .x = 2, .y = 2 }, .left).?;
    try updated_hit.callback.?.call(.{ .source = .keyboard });
    try std.testing.expectEqual(@as(usize, 3), counter.value);
}

test "focused shortcut resolution prefers nearest shortcut and action scopes" {
    const Counters = struct {
        global: usize = 0,
        local: usize = 0,

        fn incrementGlobal(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.global += 1;
        }

        fn incrementLocal(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.local += 1;
        }
    };

    const allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(allocator);
    defer build_arena.deinit();

    var counters: Counters = .{};
    var global_button = try widgets.clickable(build_arena.allocator(), "global-button", widgets.text("Global"), null);
    global_button.clickable.intent = .action("activate");
    global_button.clickable.activation = .release;
    var local_button = try widgets.clickable(build_arena.allocator(), "local-button", widgets.text("Local"), null);
    local_button.clickable.intent = .action("activate");
    local_button.clickable.activation = .release;
    const local_actions = [_]Widget.ActionBinding{.{ .id = "activate", .callback = .{ .ptr = &counters, .call_fn = Counters.incrementLocal } }};
    const local_shortcuts = [_]Widget.ShortcutBinding{.{ .key = .space, .intent = .action("activate") }};
    const local_subtree = try widgets.actions(
        build_arena.allocator(),
        &local_actions,
        try widgets.shortcuts(build_arena.allocator(), &local_shortcuts, local_button),
    );
    const children = [_]Widget{ global_button, local_subtree };
    const column = try widgets.column(build_arena.allocator(), &children, 4);
    const global_actions = [_]Widget.ActionBinding{.{ .id = "activate", .callback = .{ .ptr = &counters, .call_fn = Counters.incrementGlobal } }};
    const global_shortcuts = [_]Widget.ShortcutBinding{.{ .key = .space, .intent = .action("activate") }};
    const root_widget = try widgets.actions(
        build_arena.allocator(),
        &global_actions,
        try widgets.shortcuts(build_arena.allocator(), &global_shortcuts, column),
    );

    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(allocator, &scope, &root_widget, .{ .max_width = 200, .max_height = 120 });
    defer destroyElementTree(allocator, &element);

    try findFocusedShortcutAction(&element, .space, "local-button").?.call();
    try std.testing.expectEqual(@as(usize, 0), counters.global);
    try std.testing.expectEqual(@as(usize, 1), counters.local);

    try findFocusedShortcutAction(&element, .space, "global-button").?.call();
    try std.testing.expectEqual(@as(usize, 1), counters.global);
    try std.testing.expectEqual(@as(usize, 1), counters.local);
}

test "component widget builds into the render tree" {
    const LabelComponent = struct {
        value: []const u8,

        const vtable: Widget.Component.VTable = .{ .build = build };

        fn widget(self: *const @This()) Widget {
            return .{ .component = .{ .ptr = self, .vtable = &vtable } };
        }

        fn build(ptr: *const anyopaque, scope: *BuildScope, context: Widget.BuildContext) !Widget {
            _ = scope;
            _ = context;
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            return .{ .text = .{ .value = self.value } };
        }
    };

    const component: LabelComponent = .{ .value = "Component" };
    const widget = component.widget();

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(std.testing.allocator, &build_scope, &widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &built_element);
    const root = try layoutElement(std.testing.allocator, &built_element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(RenderNode.Kind, .component), root.kind);
    try std.testing.expectEqual(@as(RenderNode.Kind, .text), root.children[0].kind);
    try std.testing.expectEqualStrings("Component", root.children[0].text.?);
}

test "element tree retains cloned callbacks beyond build scope" {
    const CallbackState = struct {
        calls: *usize,
        clones: *usize,
        destroys: *usize,

        fn callback(self: *@This()) Widget.TapCallback {
            return .{
                .ptr = self,
                .call_fn = call,
                .clone_fn = clone,
                .destroy_fn = destroy,
            };
        }

        fn call(ptr: *anyopaque, _: TapEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
        }

        fn clone(allocator: std.mem.Allocator, ptr: *anyopaque) !*anyopaque {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.clones.* += 1;
            const result = try allocator.create(@This());
            result.* = self.*;
            return result;
        }

        fn destroy(allocator: std.mem.Allocator, ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroys.* += 1;
            allocator.destroy(self);
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    var calls: usize = 0;
    var clones: usize = 0;
    var destroys: usize = 0;
    const build_allocator = build_arena.allocator();
    const state = try build_allocator.create(CallbackState);
    state.* = .{ .calls = &calls, .clones = &clones, .destroys = &destroys };
    const label_value = try build_allocator.dupe(u8, "arena label");
    const label: Widget = .{ .text = .{ .value = label_value } };
    const button: Widget = .{ .clickable = .{
        .id = try build_allocator.dupe(u8, "arena-button"),
        .child = &label,
        .on_click = state.callback(),
    } };
    var scope: BuildScope = .{ .allocator = build_allocator };

    var element = try buildElementTreeScoped(retained_allocator, &scope, &button, .{ .max_width = 100, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 1), clones);
    try std.testing.expectEqual(@as(usize, 0), destroys);

    try std.testing.expect(build_arena.reset(.free_all));
    try element.widget.clickable.on_click.?.call(.{ .source = .keyboard });
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqualStrings("arena-button", element.widget.clickable.id);
    try std.testing.expectEqualStrings("arena label", element.children[0].widget.text.value);

    destroyElementTree(retained_allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), destroys);
}

test "element tree retains cloned render objects beyond build scope" {
    const RenderState = struct {
        clones: *usize,
        destroys: *usize,

        const vtable: Widget.RenderObject.VTable = .{
            .layout = layout,
            .paint = paintObject,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .render_object = .{
                .ptr = self,
                .vtable = &vtable,
                .clone_fn = clone,
                .destroy_fn = destroy,
            } };
        }

        fn layout(ptr: *const anyopaque, context: Widget.RenderObject.LayoutContext) !Size {
            _ = ptr;
            return context.constraints.clamp(.{ .width = 24, .height = 12 });
        }

        fn paintObject(ptr: *const anyopaque, context: Widget.RenderObject.PaintContext) !void {
            _ = ptr;
            try context.display_list.fillRect(context.allocator, context.rect, colors.accent);
        }

        fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.clones.* += 1;
            const result = try allocator.create(@This());
            result.* = self.*;
            return result;
        }

        fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroys.* += 1;
            allocator.destroy(@constCast(self));
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    var clones: usize = 0;
    var destroys: usize = 0;
    const state = try build_arena.allocator().create(RenderState);
    state.* = .{ .clones = &clones, .destroys = &destroys };
    const widget = state.widget();
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };

    var element = try buildElementTreeScoped(retained_allocator, &scope, &widget, .{ .max_width = 100, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 1), clones);
    try std.testing.expectEqual(@as(usize, 0), destroys);

    try std.testing.expect(build_arena.reset(.free_all));
    const root = try layoutElement(retained_allocator, &element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(@as(RenderNode.Kind, .render_object), root.kind);
    try std.testing.expectEqual(@as(f32, 24), root.rect.width);

    var display_list: DisplayList = .{};
    defer display_list.deinit(retained_allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(retained_allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(retained_allocator);
    try paint(retained_allocator, root, &display_list, &raster_cache);
    try std.testing.expectEqual(@as(usize, 1), display_list.commands.items.len);

    destroyElementTree(retained_allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), destroys);
}

test "element tree retains cloned stateful widgets beyond build scope" {
    const StatefulSource = struct {
        clones: *usize,
        destroys: *usize,
        states_created: *usize,
        states_destroyed: *usize,

        const State = struct {};
        const vtable: Widget.Stateful.VTable = .{
            .create_state = createState,
            .update = update,
            .build = build,
            .destroy_state = destroyState,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .stateful = .{
                .ptr = self,
                .vtable = &vtable,
                .clone_fn = clone,
                .destroy_fn = destroy,
            } };
        }

        fn createState(ptr: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.states_created.* += 1;
            const state = try allocator.create(State);
            state.* = .{};
            return state;
        }

        fn update(ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator, context: Widget.BuildContext) !void {
            _ = ptr;
            _ = state;
            _ = allocator;
            _ = context;
        }

        fn build(ptr: *const anyopaque, state: *anyopaque, scope: *BuildScope, context: Widget.BuildContext) !Widget {
            _ = ptr;
            _ = state;
            _ = context;
            const value = try std.fmt.allocPrint(scope.allocator, "stateful survives", .{});
            return .{ .text = .{ .value = value } };
        }

        fn destroyState(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.states_destroyed.* += 1;
            const state: *State = @ptrCast(@alignCast(state_ptr));
            allocator.destroy(state);
        }

        fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.clones.* += 1;
            const result = try allocator.create(@This());
            result.* = self.*;
            return result;
        }

        fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroys.* += 1;
            allocator.destroy(@constCast(self));
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    var clones: usize = 0;
    var destroys: usize = 0;
    var states_created: usize = 0;
    var states_destroyed: usize = 0;
    const source = try build_arena.allocator().create(StatefulSource);
    source.* = .{
        .clones = &clones,
        .destroys = &destroys,
        .states_created = &states_created,
        .states_destroyed = &states_destroyed,
    };
    const widget = source.widget();
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };

    var element = try buildElementTreeScoped(retained_allocator, &scope, &widget, .{ .max_width = 100, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 1), clones);
    try std.testing.expectEqual(@as(usize, 1), states_created);

    try std.testing.expect(build_arena.reset(.free_all));
    try std.testing.expectEqualStrings("stateful survives", element.children[0].widget.text.value);

    destroyElementTree(retained_allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), states_destroyed);
    try std.testing.expectEqual(@as(usize, 1), destroys);
}

test "element tree retains cloned custom elements beyond build scope" {
    const CustomSource = struct {
        clones: *usize,
        destroys: *usize,

        const vtable: Widget.CustomElement.VTable = .{ .build = build };

        fn widget(self: *const @This()) Widget {
            return .{ .element = .{
                .ptr = self,
                .vtable = &vtable,
                .clone_fn = clone,
                .destroy_fn = destroy,
            } };
        }

        fn build(ptr: *const anyopaque, allocator: std.mem.Allocator, scope: *BuildScope, context: Widget.BuildContext) !Element {
            _ = ptr;
            const value = try std.fmt.allocPrint(scope.allocator, "custom element {d}", .{@as(u32, 7)});
            const label: Widget = .{ .text = .{ .value = value, .color = colors.accent } };
            return buildElementTreeScoped(allocator, scope, &label, context.constraints);
        }

        fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.clones.* += 1;
            const result = try allocator.create(@This());
            result.* = self.*;
            return result;
        }

        fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroys.* += 1;
            allocator.destroy(@constCast(self));
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    var clones: usize = 0;
    var destroys: usize = 0;
    const source = try build_arena.allocator().create(CustomSource);
    source.* = .{ .clones = &clones, .destroys = &destroys };
    const widget = source.widget();
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };

    var element = try buildElementTreeScoped(retained_allocator, &scope, &widget, .{ .max_width = 100, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 1), clones);
    try std.testing.expectEqual(@as(usize, 0), destroys);

    try std.testing.expect(build_arena.reset(.free_all));
    try std.testing.expectEqualStrings("custom element 7", element.children[0].widget.text.value);

    destroyElementTree(retained_allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), destroys);
}

test "component build products are retained outside the build arena" {
    const ArenaComponent = struct {
        value: usize,

        const vtable: Widget.Component.VTable = .{ .build = build };

        fn widget(self: *const @This()) Widget {
            return .{ .component = .{ .ptr = self, .vtable = &vtable } };
        }

        fn build(ptr: *const anyopaque, scope: *BuildScope, context: Widget.BuildContext) !Widget {
            _ = context;
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            const value = try std.fmt.allocPrint(scope.allocator, "component {d}", .{self.value});
            return .{ .text = .{ .value = value } };
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const component: ArenaComponent = .{ .value = 42 };
    const widget = component.widget();
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(retained_allocator, &element);

    try std.testing.expect(build_arena.reset(.free_all));
    try std.testing.expectEqualStrings("component 42", element.children[0].widget.text.value);

    const root = try layoutElement(retained_allocator, &element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expectEqual(@as(RenderNode.Kind, .component), root.kind);
    try std.testing.expectEqual(@as(RenderNode.Kind, .text), root.children[0].kind);
    try std.testing.expectEqualStrings("component 42", root.children[0].text.?);
}

test "stateful widget creates state once across matching updates" {
    const StatefulCounter = struct {
        label: []const u8,
        created: *usize,
        updated: *usize,
        destroyed: *usize,

        const State = struct {
            builds: usize = 0,
        };

        const vtable: Widget.Stateful.VTable = .{
            .create_state = createState,
            .update = update,
            .build = build,
            .destroy_state = destroyState,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .stateful = .{ .ptr = self, .vtable = &vtable } };
        }

        fn createState(ptr: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.created.* += 1;
            const state = try allocator.create(State);
            state.* = .{};
            return state;
        }

        fn update(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator, context: Widget.BuildContext) !void {
            _ = state_ptr;
            _ = allocator;
            _ = context;
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.updated.* += 1;
        }

        fn build(ptr: *const anyopaque, state_ptr: *anyopaque, scope: *BuildScope, context: Widget.BuildContext) !Widget {
            _ = scope;
            _ = context;
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            const state: *State = @ptrCast(@alignCast(state_ptr));
            state.builds += 1;
            return .{ .text = .{ .value = self.label } };
        }

        fn destroyState(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroyed.* += 1;
            const state: *State = @ptrCast(@alignCast(state_ptr));
            allocator.destroy(state);
        }
    };

    var created: usize = 0;
    var updated: usize = 0;
    var destroyed: usize = 0;
    const first: StatefulCounter = .{ .label = "first", .created = &created, .updated = &updated, .destroyed = &destroyed };
    const first_widget = first.widget();
    var element = try buildElementTree(std.testing.allocator, &first_widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &element);

    const original_state = element.state.?;
    try std.testing.expectEqual(@as(usize, 1), created);
    try std.testing.expectEqual(@as(usize, 0), updated);
    try std.testing.expectEqualStrings("first", element.children[0].widget.text.value);

    const second: StatefulCounter = .{ .label = "second", .created = &created, .updated = &updated, .destroyed = &destroyed };
    const second_widget = second.widget();
    try updateElementTree(std.testing.allocator, &element, &second_widget, .{ .max_width = 200, .max_height = 80 });

    try std.testing.expectEqual(original_state, element.state.?);
    try std.testing.expectEqual(@as(usize, 1), created);
    try std.testing.expectEqual(@as(usize, 1), updated);
    try std.testing.expectEqual(@as(usize, 0), destroyed);
    try std.testing.expectEqualStrings("second", element.children[0].widget.text.value);
}

test "clean subtrees skip layout and dirty stateful subtrees relayout" {
    const CountingBackend = struct {
        measures: usize = 0,

        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scaleFn } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(ptr: *anyopaque, value: []const u8, style: ResolvedTextStyle) !Size {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.measures += 1;
            return display.fixedMeasureText(value, style);
        }

        fn scaleFn(_: *anyopaque) f32 {
            return 1;
        }
    };

    const ToggleStateful = struct {
        const State = struct {
            rebuild_generation: u64 = 0,
            built_generation: u64 = 0,
            builds: usize = 0,
            invalidate_during_build: bool = false,
            label: []const u8 = "one",
        };

        const vtable: Widget.Stateful.VTable = .{
            .create_state = createState,
            .update = update,
            .build = build,
            .destroy_state = destroyState,
            .rebuild_token = rebuildToken,
            .finish_rebuild = finishRebuild,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .stateful = .{ .ptr = self, .vtable = &vtable } };
        }

        fn createState(_: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
            const state = try allocator.create(State);
            state.* = .{};
            return state;
        }

        fn update(_: *const anyopaque, _: *anyopaque, _: std.mem.Allocator, _: Widget.BuildContext) !void {}

        fn build(_: *const anyopaque, state_ptr: *anyopaque, _: *BuildScope, _: Widget.BuildContext) !Widget {
            const state: *State = @ptrCast(@alignCast(state_ptr));
            state.builds += 1;
            if (state.invalidate_during_build) {
                state.invalidate_during_build = false;
                state.rebuild_generation +%= 1;
            }
            return .{ .text = .{ .value = state.label } };
        }

        fn destroyState(_: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
            allocator.destroy(@as(*State, @ptrCast(@alignCast(state_ptr))));
        }

        fn rebuildToken(state_ptr: *anyopaque, force: bool) ?u64 {
            const state: *State = @ptrCast(@alignCast(state_ptr));
            if (!force and state.rebuild_generation == state.built_generation) return null;
            return state.rebuild_generation;
        }

        fn finishRebuild(state_ptr: *anyopaque, token: u64) void {
            @as(*State, @ptrCast(@alignCast(state_ptr))).built_generation = token;
        }
    };

    const allocator = std.testing.allocator;
    var built_arena = std.heap.ArenaAllocator.init(allocator);
    defer built_arena.deinit();

    var backend_state: CountingBackend = .{};
    const measurer: TextMeasurer = .{ .backend = backend_state.backend() };

    const stateful: ToggleStateful = .{};
    const children = [_]Widget{ .{ .text = .{ .value = "static" } }, stateful.widget() };
    const column: Widget = .{ .column = .{ .children = &children, .gap = 32 } };
    const constraints: Constraints = .{ .max_width = 200, .max_height = 120 };

    var scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var element = try buildElementTreeScoped(allocator, &scope, &column, constraints);
    defer destroyElementTree(allocator, &element);

    const root = try layoutElement(allocator, &element, constraints, .{ .x = 0, .y = 0 }, measurer);
    const initial_measures = backend_state.measures;
    // Finite-width text is measured once while selecting a line break and
    // once as the final multiline run.
    try std.testing.expectEqual(@as(usize, 4), initial_measures);
    try std.testing.expect(collectDamage(root) != null);

    // A clean tree re-laid out with identical constraints skips entirely
    // and accumulates no damage.
    _ = try layoutElement(allocator, &element, constraints, .{ .x = 0, .y = 0 }, measurer);
    try std.testing.expectEqual(initial_measures, backend_state.measures);
    try std.testing.expectEqual(@as(?Rect, null), collectDamage(root));

    // Dirtying the stateful subtree relayouts it, but the clean sibling
    // text is never re-measured.
    const state: *ToggleStateful.State = @ptrCast(@alignCast(element.children[1].state.?));
    state.rebuild_generation += 1;
    state.label = "two";
    _ = built_arena.reset(.retain_capacity);
    var rebuild_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    try std.testing.expect(try rebuildDirtyElementTreeScoped(allocator, &rebuild_scope, &element, constraints));

    _ = try layoutElement(allocator, &element, constraints, .{ .x = 0, .y = 0 }, measurer);
    try std.testing.expectEqual(initial_measures + 2, backend_state.measures);
    try std.testing.expectEqualStrings("two", root.children[1].children[0].text.?);

    // Damage covers the relaid stateful subtree, not the clean sibling
    // above it.
    const damage = collectDamage(root).?;
    const sibling = root.children[0];
    try std.testing.expect(damage.y >= sibling.rect.y + sibling.rect.height);

    // A full update consumes an already-pending state generation, so a later
    // dirty pass does not rebuild the same state again.
    state.rebuild_generation += 1;
    _ = built_arena.reset(.retain_capacity);
    var full_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    try updateElementTreeScoped(allocator, &full_scope, &element, &column, constraints);
    try std.testing.expectEqual(state.rebuild_generation, state.built_generation);
    try std.testing.expect(!root.needs_layout);
    _ = try layoutElement(allocator, &element, constraints, .{ .x = 0, .y = 0 }, measurer);
    try std.testing.expectEqual(initial_measures + 2, backend_state.measures);
    try std.testing.expectEqual(@as(?Rect, null), collectDamage(root));
    const builds_after_full_update = state.builds;
    _ = built_arena.reset(.retain_capacity);
    var clean_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    try std.testing.expect(!try rebuildDirtyElementTreeScoped(allocator, &clean_scope, &element, constraints));
    try std.testing.expectEqual(builds_after_full_update, state.builds);

    // A generation raised from inside build is newer than the token being
    // acknowledged and therefore survives for the next pass.
    state.rebuild_generation += 1;
    state.invalidate_during_build = true;
    _ = built_arena.reset(.retain_capacity);
    var invalidating_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    try std.testing.expect(try rebuildDirtyElementTreeScoped(allocator, &invalidating_scope, &element, constraints));
    try std.testing.expect(state.rebuild_generation != state.built_generation);
    _ = built_arena.reset(.retain_capacity);
    var followup_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    try std.testing.expect(try rebuildDirtyElementTreeScoped(allocator, &followup_scope, &element, constraints));
    try std.testing.expectEqual(state.rebuild_generation, state.built_generation);
}

test "stateful widgets with different type tokens never share state" {
    const Tokens = struct {
        var first_token: u8 = 0;
        var second_token: u8 = 0;
    };

    const Counted = struct {
        token: *const anyopaque,
        created: *usize,
        destroyed: *usize,

        const vtable: Widget.Stateful.VTable = .{
            .create_state = createState,
            .update = update,
            .build = build,
            .destroy_state = destroyState,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .stateful = .{ .ptr = self, .vtable = &vtable, .type_token = self.token } };
        }

        fn createState(ptr: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.created.* += 1;
            return try allocator.create(u8);
        }

        fn update(_: *const anyopaque, _: *anyopaque, _: std.mem.Allocator, _: Widget.BuildContext) !void {}

        fn build(_: *const anyopaque, _: *anyopaque, _: *BuildScope, _: Widget.BuildContext) !Widget {
            return .{ .text = .{ .value = "counted" } };
        }

        fn destroyState(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroyed.* += 1;
            allocator.destroy(@as(*u8, @ptrCast(state_ptr)));
        }
    };

    var created: usize = 0;
    var destroyed: usize = 0;
    const first: Counted = .{ .token = &Tokens.first_token, .created = &created, .destroyed = &destroyed };
    const second: Counted = .{ .token = &Tokens.second_token, .created = &created, .destroyed = &destroyed };

    const first_widget = first.widget();
    var element = try buildElementTree(std.testing.allocator, &first_widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), created);

    // A different token at the same position replaces the element: the old
    // state is disposed and fresh state created, never silently reused.
    const second_widget = second.widget();
    try updateElementTree(std.testing.allocator, &element, &second_widget, .{ .max_width = 200, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 2), created);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "tokenless stateful widgets use vtable identity" {
    const Tokenless = struct {
        created: *usize,
        destroyed: *usize,

        const State = struct {};
        const first_vtable: Widget.Stateful.VTable = .{
            .create_state = createState,
            .update = update,
            .build = buildFirst,
            .destroy_state = destroyState,
        };
        const second_vtable: Widget.Stateful.VTable = .{
            .create_state = createState,
            .update = update,
            .build = buildSecond,
            .destroy_state = destroyState,
        };

        fn widget(self: *const @This(), vtable: *const Widget.Stateful.VTable) Widget {
            return .{ .stateful = .{ .ptr = self, .vtable = vtable } };
        }

        fn createState(ptr: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.created.* += 1;
            const state = try allocator.create(State);
            state.* = .{};
            return state;
        }

        fn update(_: *const anyopaque, _: *anyopaque, _: std.mem.Allocator, _: Widget.BuildContext) !void {}

        fn buildFirst(_: *const anyopaque, _: *anyopaque, _: *BuildScope, _: Widget.BuildContext) !Widget {
            return .{ .text = .{ .value = "first" } };
        }

        fn buildSecond(_: *const anyopaque, _: *anyopaque, _: *BuildScope, _: Widget.BuildContext) !Widget {
            return .{ .text = .{ .value = "second" } };
        }

        fn destroyState(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroyed.* += 1;
            allocator.destroy(@as(*State, @ptrCast(@alignCast(state_ptr))));
        }
    };

    var created: usize = 0;
    var destroyed: usize = 0;
    const stateful: Tokenless = .{ .created = &created, .destroyed = &destroyed };
    const first = stateful.widget(&Tokenless.first_vtable);
    var element = try buildElementTree(std.testing.allocator, &first, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &element);
    const first_state = element.state.?;

    const matching = stateful.widget(&Tokenless.first_vtable);
    try updateElementTree(std.testing.allocator, &element, &matching, .{ .max_width = 200, .max_height = 80 });
    try std.testing.expectEqual(first_state, element.state.?);
    try std.testing.expectEqual(@as(usize, 1), created);
    try std.testing.expectEqual(@as(usize, 0), destroyed);

    const different = stateful.widget(&Tokenless.second_vtable);
    try updateElementTree(std.testing.allocator, &element, &different, .{ .max_width = 200, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 2), created);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
    try std.testing.expectEqualStrings("second", element.children[0].widget.text.value);
}

test "changing a nested key replaces state" {
    const Counted = struct {
        created: *usize,
        destroyed: *usize,

        const State = struct {};
        const vtable: Widget.Stateful.VTable = .{
            .create_state = createState,
            .update = update,
            .build = build,
            .destroy_state = destroyState,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .stateful = .{ .ptr = self, .vtable = &vtable } };
        }

        fn createState(ptr: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.created.* += 1;
            const state = try allocator.create(State);
            state.* = .{};
            return state;
        }

        fn update(_: *const anyopaque, _: *anyopaque, _: std.mem.Allocator, _: Widget.BuildContext) !void {}

        fn build(_: *const anyopaque, _: *anyopaque, _: *BuildScope, _: Widget.BuildContext) !Widget {
            return .{ .text = .{ .value = "stateful" } };
        }

        fn destroyState(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroyed.* += 1;
            allocator.destroy(@as(*State, @ptrCast(@alignCast(state_ptr))));
        }
    };

    const allocator = std.testing.allocator;
    const constraints: Constraints = .{ .max_width = 200, .max_height = 80 };
    var created: usize = 0;
    var destroyed: usize = 0;
    const counted: Counted = .{ .created = &created, .destroyed = &destroyed };
    const stateful = counted.widget();
    const first_keyed: Widget = .{ .keyed = .{ .key = .{ .string = "first" }, .child = &stateful } };
    const first: Widget = .{ .box = .{ .child = &first_keyed } };
    var element = try buildElementTree(allocator, &first, constraints);
    defer destroyElementTree(allocator, &element);

    const second_keyed: Widget = .{ .keyed = .{ .key = .{ .string = "second" }, .child = &stateful } };
    const second: Widget = .{ .box = .{ .child = &second_keyed } };
    try updateElementTree(allocator, &element, &second, constraints);

    try std.testing.expectEqual(@as(usize, 2), created);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "stateful widget destroys state on element destruction and replacement" {
    const Lifecycle = struct {
        created: *usize,
        destroyed: *usize,

        const State = struct {};
        const vtable: Widget.Stateful.VTable = .{
            .create_state = createState,
            .update = update,
            .build = build,
            .destroy_state = destroyState,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .stateful = .{ .ptr = self, .vtable = &vtable } };
        }

        fn createState(ptr: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.created.* += 1;
            const state = try allocator.create(State);
            state.* = .{};
            return state;
        }

        fn update(ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator, context: Widget.BuildContext) !void {
            _ = ptr;
            _ = state;
            _ = allocator;
            _ = context;
        }

        fn build(ptr: *const anyopaque, state: *anyopaque, scope: *BuildScope, context: Widget.BuildContext) !Widget {
            _ = ptr;
            _ = state;
            _ = scope;
            _ = context;
            return .{ .text = .{ .value = "stateful" } };
        }

        fn destroyState(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroyed.* += 1;
            const state: *State = @ptrCast(@alignCast(state_ptr));
            allocator.destroy(state);
        }
    };

    var created: usize = 0;
    var destroyed: usize = 0;
    const lifecycle: Lifecycle = .{ .created = &created, .destroyed = &destroyed };
    const widget = lifecycle.widget();
    var element = try buildElementTree(std.testing.allocator, &widget, .{ .max_width = 200, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 1), created);

    const replacement: Widget = .{ .text = .{ .value = "replacement" } };
    try updateElementTree(std.testing.allocator, &element, &replacement, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
    try std.testing.expectEqual(@as(Element.Kind, .text), element.kind);

    var destroyed_on_deinit: usize = 0;
    const second_lifecycle: Lifecycle = .{ .created = &created, .destroyed = &destroyed_on_deinit };
    const second_widget = second_lifecycle.widget();
    var second_element = try buildElementTree(std.testing.allocator, &second_widget, .{ .max_width = 200, .max_height = 80 });
    destroyElementTree(std.testing.allocator, &second_element);
    try std.testing.expectEqual(@as(usize, 1), destroyed_on_deinit);
}

test "element clone preserves text wrapping options" {
    const widget: Widget = .{ .text = .{
        .value = "song title",
        .max_lines = 2,
        .overflow = .clip,
        .line_break = .knuth_plass,
    } };
    var element = try buildElementTree(std.testing.allocator, &widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &element);

    try std.testing.expectEqual(@as(?u32, 2), element.widget.text.max_lines);
    try std.testing.expectEqual(Widget.TextOverflow.clip, element.widget.text.overflow);
    try std.testing.expectEqual(Widget.LineBreakStrategy.knuth_plass, element.widget.text.line_break);
}

test "element clone preserves text_input style overrides" {
    const widget: Widget = .{ .text_input = .{
        .id = "search",
        .focus_node = .named("search"),
        .value = "",
        .placeholder = "type…",
        .style = .{ .padding_x = 0, .padding_y = 0, .radius = 0 },
    } };
    var element = try buildElementTree(std.testing.allocator, &widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &element);

    const style = element.widget.text_input.style;
    try std.testing.expectEqual(@as(?f32, 0), style.padding_x);
    try std.testing.expectEqual(@as(?f32, 0), style.padding_y);
    try std.testing.expectEqual(@as(?f32, 0), style.radius);
}

test "element clone preserves clickable buttons" {
    const child: Widget = widgets.text("buttons");
    const widget: Widget = .{ .clickable = .{
        .id = "buttons",
        .child = &child,
        .on_click = testTapCallback(),
        .buttons = .{ .left = false, .right = true, .back = true },
    } };
    var clone = try cloneWidgetForElement(std.testing.allocator, widget);
    defer destroyElementWidget(std.testing.allocator, &clone);

    try std.testing.expect(!clone.clickable.buttons.left);
    try std.testing.expect(clone.clickable.buttons.right);
    try std.testing.expect(clone.clickable.buttons.back);
}

test "custom element widget builds an element subtree" {
    const LabelElement = struct {
        value: []const u8,

        const vtable: Widget.CustomElement.VTable = .{ .build = build };

        fn widget(self: *const @This()) Widget {
            return .{ .element = .{ .ptr = self, .vtable = &vtable } };
        }

        fn build(ptr: *const anyopaque, allocator: std.mem.Allocator, scope: *BuildScope, context: Widget.BuildContext) !Element {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            const label: Widget = .{ .text = .{ .value = self.value, .color = colors.accent } };
            return buildElementTreeScoped(allocator, scope, &label, context.constraints);
        }
    };

    const custom: LabelElement = .{ .value = "Element" };
    const widget = custom.widget();

    var element = try buildElementTree(std.testing.allocator, &widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &element);

    try std.testing.expectEqual(@as(Element.Kind, .element), element.kind);
    try std.testing.expectEqual(@as(Element.Kind, .text), element.children[0].kind);

    const root = try layoutElement(std.testing.allocator, &element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(RenderNode.Kind, .element), root.kind);
    try std.testing.expectEqual(@as(RenderNode.Kind, .text), root.children[0].kind);
    try std.testing.expectEqualStrings("Element", root.children[0].text.?);
    try std.testing.expectEqual(colors.accent, root.children[0].foreground);
}

test "element update reuses matching children and replaces shape changes" {
    const allocator = std.testing.allocator;

    const first_children = [_]Widget{
        .{ .text = .{ .value = "A" } },
        .{ .text = .{ .value = "B" } },
    };
    const first: Widget = .{ .column = .{ .children = &first_children, .gap = 2 } };
    var element = try buildElementTree(allocator, &first, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &element);

    const original_children = element.children.ptr;
    const second_children = [_]Widget{
        .{ .text = .{ .value = "C" } },
        .{ .text = .{ .value = "D" } },
    };
    const second: Widget = .{ .column = .{ .children = &second_children, .gap = 6 } };
    try updateElementTree(allocator, &element, &second, .{ .max_width = 200, .max_height = 80 });

    try std.testing.expectEqual(original_children, element.children.ptr);
    try std.testing.expectEqual(@as(usize, 2), element.children.len);
    try std.testing.expectEqual(@as(f32, 6), element.widget.column.gap);
    try std.testing.expectEqualStrings("C", element.children[0].widget.text.value);
    try std.testing.expectEqualStrings("D", element.children[1].widget.text.value);

    const third_children = [_]Widget{
        .{ .text = .{ .value = "E" } },
    };
    const third: Widget = .{ .column = .{ .children = &third_children, .gap = 1 } };
    try updateElementTree(allocator, &element, &third, .{ .max_width = 200, .max_height = 80 });

    try std.testing.expectEqual(@as(usize, 1), element.children.len);
    try std.testing.expectEqual(@as(f32, 1), element.widget.column.gap);
    try std.testing.expectEqualStrings("E", element.children[0].widget.text.value);
}

test "linear update preserves compatible unkeyed suffix across insertion and removal" {
    const allocator = std.testing.allocator;
    const constraints: Constraints = .{ .max_width = 300, .max_height = 120 };

    const input: Widget = .{ .text_input = .{
        .id = "query",
        .focus_node = .named("query"),
        .value = "initial",
        .placeholder = "Search",
    } };
    const tail: Widget = .{ .text = .{ .value = "tail" } };
    const initial_children = [_]Widget{ input, tail };
    const initial: Widget = .{ .column = .{ .children = &initial_children } };
    var element = try buildElementTree(allocator, &initial, constraints);
    defer destroyElementTree(allocator, &element);

    const input_state = textInputState(&element.children[0]);
    input_state.text.clearRetainingCapacity();
    try input_state.text.appendSlice(allocator, "edited");

    const inserted_text: Widget = .{ .text = .{ .value = "inserted" } };
    const inserted_box: Widget = .{ .box = .{ .child = &inserted_text } };
    const inserted_children = [_]Widget{ inserted_box, input, tail };
    const inserted: Widget = .{ .column = .{ .children = &inserted_children } };
    try updateElementTree(allocator, &element, &inserted, constraints);

    try std.testing.expectEqual(input_state, textInputState(&element.children[1]));
    try std.testing.expectEqualStrings("edited", input_state.text.items);

    const removed_children = [_]Widget{ input, tail };
    const removed: Widget = .{ .column = .{ .children = &removed_children } };
    try updateElementTree(allocator, &element, &removed, constraints);

    try std.testing.expectEqual(input_state, textInputState(&element.children[0]));
    try std.testing.expectEqualStrings("edited", input_state.text.items);
}

test "keyed linear update matches children by key" {
    const allocator = std.testing.allocator;

    const a_text: Widget = .{ .text = .{ .value = "A" } };
    const b_text: Widget = .{ .text = .{ .value = "B" } };
    const first_children = [_]Widget{
        .{ .keyed = .{ .key = .{ .string = "a" }, .child = &a_text } },
        .{ .keyed = .{ .key = .{ .string = "b" }, .child = &b_text } },
    };
    const first: Widget = .{ .column = .{ .children = &first_children } };
    var element = try buildElementTree(allocator, &first, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &element);

    const old_b_child = element.children[1].children.ptr;

    const b2_text: Widget = .{ .text = .{ .value = "B2" } };
    const c_text: Widget = .{ .text = .{ .value = "C" } };
    const a2_text: Widget = .{ .text = .{ .value = "A2" } };
    const second_children = [_]Widget{
        .{ .keyed = .{ .key = .{ .string = "b" }, .child = &b2_text } },
        .{ .keyed = .{ .key = .{ .string = "c" }, .child = &c_text } },
        .{ .keyed = .{ .key = .{ .string = "a" }, .child = &a2_text } },
    };
    const second: Widget = .{ .column = .{ .children = &second_children } };
    try updateElementTree(allocator, &element, &second, .{ .max_width = 200, .max_height = 80 });

    try std.testing.expectEqual(@as(usize, 3), element.children.len);
    try std.testing.expectEqual(old_b_child, element.children[0].children.ptr);
    try std.testing.expectEqualStrings("b", element.children[0].key.?.string);
    try std.testing.expectEqualStrings("B2", element.children[0].children[0].widget.text.value);
    try std.testing.expectEqualStrings("c", element.children[1].key.?.string);
    try std.testing.expectEqualStrings("C", element.children[1].children[0].widget.text.value);
    try std.testing.expectEqualStrings("a", element.children[2].key.?.string);
    try std.testing.expectEqualStrings("A2", element.children[2].children[0].widget.text.value);
}

test "keyed linear update retains valid ownership after child update error" {
    const FallibleComponent = struct {
        value: []const u8,
        fail: bool = false,

        const vtable: Widget.Component.VTable = .{ .build = build };

        fn widget(self: *const @This()) Widget {
            return .{ .component = .{ .ptr = self, .vtable = &vtable } };
        }

        fn build(ptr: *const anyopaque, _: *BuildScope, _: Widget.BuildContext) !Widget {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            if (self.fail) return error.ExpectedUpdateFailure;
            return .{ .text = .{ .value = self.value } };
        }
    };

    const allocator = std.testing.allocator;
    const constraints: Constraints = .{ .max_width = 200, .max_height = 80 };
    const initial_component: FallibleComponent = .{ .value = "old" };
    const old_text: Widget = .{ .text = .{ .value = "removed" } };
    const initial_component_widget = initial_component.widget();
    const initial_children = [_]Widget{
        .{ .keyed = .{ .key = .{ .string = "a" }, .child = &initial_component_widget } },
        .{ .keyed = .{ .key = .{ .string = "b" }, .child = &old_text } },
    };
    const initial: Widget = .{ .column = .{ .children = &initial_children } };
    var element = try buildElementTree(allocator, &initial, constraints);
    defer destroyElementTree(allocator, &element);
    _ = try layoutElement(allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);

    const failing_component: FallibleComponent = .{ .value = "new", .fail = true };
    const failing_component_widget = failing_component.widget();
    const new_text: Widget = .{ .text = .{ .value = "new child" } };
    const failing_children = [_]Widget{
        .{ .keyed = .{ .key = .{ .string = "a" }, .child = &failing_component_widget } },
        .{ .keyed = .{ .key = .{ .string = "c" }, .child = &new_text } },
    };
    const failing: Widget = .{ .column = .{ .children = &failing_children } };
    try std.testing.expectError(error.ExpectedUpdateFailure, updateElementTree(allocator, &element, &failing, constraints));

    try std.testing.expectEqual(@as(usize, 2), element.children.len);
    try std.testing.expectEqualStrings("a", element.children[0].key.?.string);
    try std.testing.expectEqual(@as(Element.Kind, .spacer), element.children[1].kind);
    try std.testing.expectEqual(@as(usize, 0), element.render_node.?.children.len);

    const recovered_component: FallibleComponent = .{ .value = "recovered" };
    const recovered_component_widget = recovered_component.widget();
    const recovered_children = [_]Widget{
        .{ .keyed = .{ .key = .{ .string = "a" }, .child = &recovered_component_widget } },
        .{ .keyed = .{ .key = .{ .string = "c" }, .child = &new_text } },
    };
    const recovered: Widget = .{ .column = .{ .children = &recovered_children } };
    try updateElementTree(allocator, &element, &recovered, constraints);
    const root = try layoutElement(allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(usize, 2), root.children.len);
    try std.testing.expectEqualStrings("recovered", root.children[0].children[0].children[0].text.?);
    try std.testing.expectEqualStrings("new child", root.children[1].children[0].text.?);

    // A newly inserted keyed child can also fail while being built, after an
    // earlier moved child was already updated. Its preinitialized slot stays
    // valid and owns no resources.
    const updated_component: FallibleComponent = .{ .value = "updated" };
    const updated_component_widget = updated_component.widget();
    const newly_failing_component: FallibleComponent = .{ .value = "never built", .fail = true };
    const newly_failing_component_widget = newly_failing_component.widget();
    const build_failing_children = [_]Widget{
        .{ .keyed = .{ .key = .{ .string = "a" }, .child = &updated_component_widget } },
        .{ .keyed = .{ .key = .{ .string = "d" }, .child = &newly_failing_component_widget } },
    };
    const build_failing: Widget = .{ .column = .{ .children = &build_failing_children } };
    try std.testing.expectError(error.ExpectedUpdateFailure, updateElementTree(allocator, &element, &build_failing, constraints));

    try std.testing.expectEqualStrings("updated", element.children[0].children[0].children[0].widget.text.value);
    try std.testing.expectEqual(@as(Element.Kind, .spacer), element.children[1].kind);
    try std.testing.expectEqual(@as(usize, 0), element.render_node.?.children.len);
}

test "render object widget owns custom layout paint and hit testing" {
    const BadgeRenderObject = struct {
        id: []const u8,

        const vtable: Widget.RenderObject.VTable = .{
            .layout = layoutBadge,
            .paint = paintBadge,
            .hit_test = hitTest,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .render_object = .{ .ptr = self, .vtable = &vtable } };
        }

        fn layoutBadge(ptr: *const anyopaque, context: Widget.RenderObject.LayoutContext) !Size {
            _ = ptr;
            _ = context.measurer;
            return context.constraints.clamp(.{ .width = 48, .height = 20 });
        }

        fn paintBadge(ptr: *const anyopaque, context: Widget.RenderObject.PaintContext) !void {
            _ = ptr;
            try context.display_list.fillRect(context.allocator, context.rect, colors.accent);
        }

        fn hitTest(ptr: *const anyopaque, rect: Rect, point: Point) ?[]const u8 {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            return if (rect.contains(point)) self.id else null;
        }
    };

    const badge: BadgeRenderObject = .{ .id = "badge" };
    const widget = badge.widget();

    var built_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer built_arena.deinit();
    var build_scope: BuildScope = .{ .allocator = built_arena.allocator() };
    var built_element = try buildElementTreeScoped(std.testing.allocator, &build_scope, &widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &built_element);
    const root = try layoutElement(std.testing.allocator, &built_element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);

    try std.testing.expectEqual(@as(RenderNode.Kind, .render_object), root.kind);
    try std.testing.expectEqual(@as(f32, 48), root.rect.width);
    try std.testing.expectEqual(@as(f32, 20), root.rect.height);

    var display_list: DisplayList = .{};
    defer display_list.deinit(std.testing.allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(std.testing.allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(std.testing.allocator);
    try paint(std.testing.allocator, root, &display_list, &raster_cache);

    try std.testing.expectEqual(@as(usize, 1), display_list.commands.items.len);
    try std.testing.expectEqualStrings("badge", hitTestButton(root, .{ .x = 8, .y = 8 }).?);
    try std.testing.expect(hitTestButton(root, .{ .x = 80, .y = 8 }) == null);
}
