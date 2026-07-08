local ffi = require("ffi")

ffi.cdef[[
typedef struct keywork_context keywork_context_t;
typedef struct keywork_surface keywork_surface_t;

enum keywork_status {
    KEYWORK_OK = 0,
    KEYWORK_INVALID_ARGUMENT = 1,
    KEYWORK_OUT_OF_MEMORY = 2,
    KEYWORK_UNSUPPORTED = 3,
    KEYWORK_INVALID_DOCUMENT = 4,
    KEYWORK_SYSTEM_ERROR = 5,
    KEYWORK_INTERNAL_ERROR = 6,
};

enum keywork_backend {
    KEYWORK_BACKEND_AUTO = 0,
    KEYWORK_BACKEND_WAYLAND_SHM = 1,
    KEYWORK_BACKEND_VULKAN = 2,
    KEYWORK_BACKEND_HEADLESS = 3,
};

enum keywork_layer {
    KEYWORK_LAYER_BACKGROUND = 0,
    KEYWORK_LAYER_BOTTOM = 1,
    KEYWORK_LAYER_TOP = 2,
    KEYWORK_LAYER_OVERLAY = 3,
};

enum keywork_anchor {
    KEYWORK_ANCHOR_TOP = 1u << 0,
    KEYWORK_ANCHOR_BOTTOM = 1u << 1,
    KEYWORK_ANCHOR_LEFT = 1u << 2,
    KEYWORK_ANCHOR_RIGHT = 1u << 3,
};

enum keywork_keyboard_interactivity {
    KEYWORK_KEYBOARD_NONE = 0,
    KEYWORK_KEYBOARD_EXCLUSIVE = 1,
    KEYWORK_KEYBOARD_ON_DEMAND = 2,
};

enum keywork_event_kind {
    KEYWORK_EVENT_HANDLER = 1,
    KEYWORK_EVENT_CONFIGURED = 2,
    KEYWORK_EVENT_CLOSED = 3,
    KEYWORK_EVENT_APPEARANCE_CHANGED = 4,
    KEYWORK_EVENT_DOCUMENT_RETIRED = 5,
};

enum keywork_event_payload_kind {
    KEYWORK_EVENT_PAYLOAD_NONE = 0,
    KEYWORK_EVENT_PAYLOAD_BOOL = 1,
    KEYWORK_EVENT_PAYLOAD_TEXT = 2,
};

enum keywork_color_scheme {
    KEYWORK_COLOR_SCHEME_NO_PREFERENCE = 0,
    KEYWORK_COLOR_SCHEME_DARK = 1,
    KEYWORK_COLOR_SCHEME_LIGHT = 2,
};

struct keywork_surface_options {
    size_t struct_size;
    int backend;
    const char *title;
    const char *app_id;
    uint32_t width;
    uint32_t height;
    int layer_shell;
    const char *layer_namespace;
    int layer;
    uint32_t layer_anchors;
    int32_t layer_exclusive_zone;
    int32_t layer_margin_top;
    int32_t layer_margin_right;
    int32_t layer_margin_bottom;
    int32_t layer_margin_left;
    int layer_keyboard_interactivity;
};

struct keywork_event {
    size_t struct_size;
    int kind;
    uint64_t surface_id;
    uint64_t document_id;
    uint64_t handler_id;
    int payload_kind;
    const uint8_t *payload_ptr;
    size_t payload_len;
    int payload_bool;
    float width;
    float height;
};

struct keywork_theme_colors {
    size_t struct_size;
    int color_scheme;
    uint32_t primary;
    uint32_t on_primary;
    uint32_t primary_container;
    uint32_t on_primary_container;
    uint32_t surface;
    uint32_t on_surface;
    uint32_t on_surface_variant;
    uint32_t surface_container_low;
    uint32_t surface_container;
    uint32_t surface_container_high;
    uint32_t error;
    uint32_t on_error;
    uint32_t error_container;
    uint32_t on_error_container;
    uint32_t outline;
    uint32_t outline_variant;
};

uint32_t keywork_abi_version(void);
uint32_t keywork_widget_version(void);

int keywork_context_create(keywork_context_t **out_context);
void keywork_context_destroy(keywork_context_t *context);
int keywork_context_event_fd(keywork_context_t *context);
int keywork_context_dispatch(keywork_context_t *context);
int keywork_context_next_event(keywork_context_t *context, struct keywork_event *out_event);
int keywork_context_get_color_scheme(const keywork_context_t *context, int *out_color_scheme);
int keywork_context_get_theme_colors(const keywork_context_t *context, struct keywork_theme_colors *out_colors);
int keywork_context_set_icon_theme(keywork_context_t *context, const char *theme_name);
int keywork_context_create_image_rgba8(keywork_context_t *context, uint32_t width, uint32_t height, size_t stride_bytes, const uint8_t *pixels, size_t pixels_len, uint64_t *out_resource_id);
int keywork_context_create_alpha_mask_a8(keywork_context_t *context, uint32_t width, uint32_t height, size_t stride_bytes, const uint8_t *pixels, size_t pixels_len, uint64_t *out_resource_id);
void keywork_context_release_resource(keywork_context_t *context, uint64_t resource_id);

int keywork_surface_create(keywork_context_t *context, const struct keywork_surface_options *options, keywork_surface_t **out_surface);
void keywork_surface_destroy(keywork_context_t *context, keywork_surface_t *surface);
uint64_t keywork_surface_id(const keywork_surface_t *surface);
int keywork_surface_submit(keywork_surface_t *surface, const uint8_t *bytes, size_t bytes_len, uint64_t *out_document_id);
int keywork_surface_invalidate(keywork_surface_t *surface);

typedef union { float f; uint32_t u; } keywork_lua_f32;
]]

local M = {}

local HEADER_SIZE = 48
local WIDGET_SIZE = 80
local BINDING_SIZE = 16
local KEY_FLAG = 0x8000

local library_handle

local function C()
  if not library_handle then
    library_handle = ffi.load(os.getenv("KEYWORK_LIBKEYWORK") or "keywork")
  end
  return library_handle
end

M.C = C

local status_names = {
  [0] = "ok",
  [1] = "invalid argument",
  [2] = "out of memory",
  [3] = "unsupported",
  [4] = "invalid document",
  [5] = "system error",
  [6] = "internal error",
}

local function check(status, what)
  if status ~= 0 then
    error((what or "keywork call") .. " failed: " .. (status_names[tonumber(status)] or tostring(status)), 2)
  end
end

local function u64_number(value)
  local number = tonumber(value)
  if not number or number < 0 then
    error("expected non-negative integer", 3)
  end
  return number
end

local function u64_key(value)
  return tostring(u64_number(value))
end

local f32_union = ffi.new("keywork_lua_f32")
local function f32_bits(value)
  f32_union.f = tonumber(value or 0)
  return tonumber(f32_union.u)
end

local function put_u16(out, offset, value)
  value = math.floor(tonumber(value) or 0)
  out[offset] = value % 256
  out[offset + 1] = math.floor(value / 256) % 256
end

local function put_u32(out, offset, value)
  value = math.floor(tonumber(value) or 0)
  if value < 0 then value = value + 4294967296 end
  out[offset] = value % 256
  out[offset + 1] = math.floor(value / 256) % 256
  out[offset + 2] = math.floor(value / 65536) % 256
  out[offset + 3] = math.floor(value / 16777216) % 256
end

local function put_u64(out, offset, value)
  value = u64_number(value or 0)
  put_u32(out, offset, value % 4294967296)
  put_u32(out, offset + 4, math.floor(value / 4294967296))
end

local function put_f32(out, offset, value)
  put_u32(out, offset, f32_bits(value))
end

local function child_from_args(options, child)
  if child ~= nil then return options or {}, child end
  if type(options) == "table" and options.kind == nil and options.child ~= nil then return options, options.child end
  return {}, options
end

local function widget(kind, fields)
  fields = fields or {}
  fields.kind = kind
  return fields
end

local function option(options, snake_name, camel_name)
  if options[snake_name] ~= nil then return options[snake_name] end
  return options[camel_name]
end

local ui = {}
M.ui = ui

function ui.argb(a, r, g, b)
  return ((a or 255) * 16777216) + ((r or 0) * 65536) + ((g or 0) * 256) + (b or 0)
end

function ui.text(value, options)
  options = options or {}
  return widget("text", {
    value = tostring(value or ""),
    key = options.key,
    color = options.color,
    font_size = option(options, "font_size", "fontSize") or options.size,
    role = options.role,
  })
end

function ui.label(value, options)
  options = options or {}
  options.role = options.role or "label"
  return ui.text(value, options)
end

function ui.row(options)
  options = options or {}
  return widget("row", {
    key = options.key,
    children = options.children or options,
    gap = options.gap or options.spacing,
    cross_align = options.cross_align or options.align,
    main_align = options.main_align,
  })
end

function ui.column(options)
  options = options or {}
  return widget("column", {
    key = options.key,
    children = options.children or options,
    gap = options.gap or options.spacing,
    cross_align = options.cross_align or options.align,
    main_align = options.main_align,
  })
end

function ui.container(options, child)
  options, child = child_from_args(options, child)
  return widget("container", {
    key = options.key,
    child = child,
    background = options.background,
    border = options.border,
    border_width = options.border_width,
    radius = options.radius,
    min_width = options.min_width,
    min_height = options.min_height,
    horizontal_align = options.horizontal_align or options.align,
    vertical_align = options.vertical_align or options.align or options.vertical_align,
    padding = options.padding,
  })
end

ui.container = ui.container

function ui.padding(options, child)
  options, child = child_from_args(options, child)
  return widget("padding", { key = options.key, insets = options.insets or options.padding or options, child = child })
end

function ui.center(options, child)
  options, child = child_from_args(options, child)
  return widget("center", { key = options.key, child = child })
end

function ui.spacer(options)
  if type(options) ~= "table" then options = { flex = options } end
  options = options or {}
  return widget("spacer", { key = options.key, flex = options.flex or 1 })
end

function ui.flexible(options, child)
  options, child = child_from_args(options, child)
  return widget("flexible", { key = options.key, child = child, flex = options.flex or 1, fit = options.fit })
end

function ui.expanded(options, child)
  options, child = child_from_args(options, child)
  options.fit = options.fit or "tight"
  return ui.flexible(options, child)
end

function ui.sized_box(options, child)
  options, child = child_from_args(options, child)
  return widget("sized_box", {
    key = options.key,
    child = child,
    width = options.width,
    height = options.height,
    min_width = options.min_width,
    min_height = options.min_height,
    max_width = options.max_width,
    max_height = options.max_height,
  })
end

function ui.filled_button(options, child)
  options, child = child_from_args(options, child)
  local on_tap = option(options, "on_tap", "onTap")
  local on_tap_down = option(options, "on_tap_down", "onTapDown")
  return widget("filled_button", {
    key = options.key,
    id = options.id,
    handler = options.handler or on_tap or on_tap_down,
    activation = options.activation or (on_tap and "release" or "press"),
    child = child or (options.label and ui.label(options.label)) or options.child,
  })
end

function ui.gesture_detector(options, child)
  options, child = child_from_args(options, child)
  local on_tap = option(options, "on_tap", "onTap")
  local on_tap_down = option(options, "on_tap_down", "onTapDown")
  local hover_background = option(options, "hover_background", "hoverBackground")
  return widget("gesture_detector", {
    key = options.key,
    id = options.id,
    handler = options.handler or on_tap or on_tap_down,
    activation = options.activation or (on_tap_down and "press" or "release"),
    hover_background = hover_background,
    child = child or options.child,
  })
end

function ui.chip(options)
  options = options or {}
  local on_tap = option(options, "on_tap", "onTap")
  local on_tap_down = option(options, "on_tap_down", "onTapDown")
  local hover_background = option(options, "hover_background", "hoverBackground")
  local selected_background = option(options, "selected_background", "selectedBackground")
  local selected_hover_background = option(options, "selected_hover_background", "selectedHoverBackground")
  local selected_color = option(options, "selected_color", "selectedColor")
  local color = options.selected and options.selected_color or options.color
  color = options.selected and selected_color or color
  local background = options.selected and selected_background or options.background
  local hover = options.selected and selected_hover_background or hover_background
  local child = options.child or ui.label(options.label or "", { color = color })
  child = ui.container({
    background = background,
    radius = options.radius,
    min_width = options.min_width,
    min_height = options.min_height,
    align = options.align,
    padding = options.padding,
  }, child)
  if on_tap or on_tap_down or options.handler then
    return ui.gesture_detector({
      key = options.key,
      id = options.id,
      handler = options.handler or on_tap or on_tap_down,
      activation = on_tap_down and "press" or "release",
      hover_background = hover,
    }, child)
  end
  return child
end

function ui.image(options)
  options = options or {}
  return widget("image", {
    key = options.key,
    resource = options.resource or options.resource_id or options.id,
    width = options.width,
    height = options.height,
    tint = options.tint or options.color,
  })
end

function ui.icon(name, options)
  options = options or {}
  return widget("icon", { key = options.key, name = name, size = options.size, color = options.color })
end

function ui.icon_label(icon_name, text, options)
  options = options or {}
  local children = { ui.icon(icon_name, { size = options.size, color = options.color }) }
  if text ~= nil and text ~= "" then
    children[#children + 1] = ui.label(text, { font_size = options.font_size, color = options.color })
  end
  return ui.row({ spacing = options.spacing or 4, align = "center", children = children })
end

function ui.icon_theme(options)
  options = options or {}
  return widget("icon_theme", { key = options.key, color = options.color, size = options.size, child = options.child })
end

function ui.default_text_style(options, child)
  options, child = child_from_args(options, child)
  return widget("default_text_style", { key = options.key, color = options.color, font_size = option(options, "font_size", "fontSize") or options.size, child = child })
end

function ui.theme(options)
  options = options or {}
  return widget("theme", { key = options.key, data = options.data, child = options.child })
end

function ui.single_child_scroll_view(options, child)
  options, child = child_from_args(options, child)
  return widget("single_child_scroll_view", { key = options.key, id = options.id, axes = options.axes, child = child })
end

function ui.focus(options, child)
  options, child = child_from_args(options, child)
  return widget("focus", {
    key = options.key,
    id = options.id,
    child = child,
    autofocus = options.autofocus,
    skip_traversal = options.skip_traversal,
    can_request_focus = options.can_request_focus,
    on_focus_change = options.on_focus_change,
  })
end

function ui.focus_scope(options, child)
  options, child = child_from_args(options, child)
  return widget("focus_scope", { key = options.key, id = options.id, child = child, modal = options.modal })
end

function ui.text_field(options)
  options = options or {}
  return widget("text_field", {
    key = options.key,
    id = options.id,
    value = options.value or "",
    placeholder = options.placeholder or "",
    on_change = option(options, "on_change", "onChanged"),
    autofocus = options.autofocus,
  })
end

function ui.shortcuts(options, child)
  options, child = child_from_args(options, child)
  return widget("shortcuts", { key = options.key, bindings = options.bindings or {}, child = child })
end

ui.Text = ui.text
ui.Row = ui.row
ui.Column = ui.column
ui.Container = ui.container
ui.Padding = ui.padding
ui.Center = ui.center
ui.Spacer = ui.spacer
ui.Flexible = ui.flexible
ui.Expanded = ui.expanded
ui.SizedBox = ui.sized_box
ui.FilledButton = ui.filled_button
ui.TextButton = ui.filled_button
ui.GestureDetector = ui.gesture_detector
ui.Chip = ui.chip
ui.Image = ui.image
ui.Icon = ui.icon
ui.IconTheme = ui.icon_theme
ui.DefaultTextStyle = ui.default_text_style
ui.Theme = ui.theme
ui.SingleChildScrollView = ui.single_child_scroll_view
ui.Focus = ui.focus
ui.FocusScope = ui.focus_scope
ui.TextField = ui.text_field
ui.Shortcuts = ui.shortcuts

ui.filledButton = ui.filled_button
ui.gestureDetector = ui.gesture_detector
ui.sizedBox = ui.sized_box
ui.singleChildScrollView = ui.single_child_scroll_view
ui.textField = ui.text_field
ui.text_button = ui.filled_button

local text_roles = { body = 0, label = 1, title = 2 }
local cross_alignments = { start = 0, center = 1, ["end"] = 2, stretch = 3 }
local main_alignments = { start = 0, center = 1, ["end"] = 2, ["space-between"] = 3, space_between = 3, ["space-around"] = 4, space_around = 4, ["space-evenly"] = 5, space_evenly = 5 }
local box_alignments = { start = 0, center = 1, ["end"] = 2 }
local flex_fits = { tight = 0, loose = 1 }
local scroll_axes = { vertical = 0, horizontal = 1, both = 2 }
local shortcut_keys = { enter = 0, space = 1, backspace = 2, escape = 3, up = 4, down = 5 }

local function enum(map, value, default)
  if value == nil then return default or 0 end
  if type(value) == "number" then return value end
  local result = map[value]
  if result == nil then error("unknown enum value: " .. tostring(value), 3) end
  return result
end

local function insets(value)
  if type(value) == "number" then return value, value, value, value end
  value = value or {}
  local all = value.all or 0
  local x = value.x or all
  local y = value.y or all
  return value.left or x, value.top or y, value.right or x, value.bottom or y
end

local function child_array(children)
  local result = {}
  for i = 1, #(children or {}) do
    result[#result + 1] = children[i]
  end
  return result
end

local Encoder = {}
Encoder.__index = Encoder

function Encoder.new()
  return setmetatable({
    widgets = {},
    children = {},
    bindings = {},
    strings = {},
    string_size = 0,
    callbacks = {},
    next_handler = 1,
  }, Encoder)
end

function Encoder:string(value)
  if value == nil then return 0, 0 end
  value = tostring(value)
  local offset = self.string_size
  self.strings[#self.strings + 1] = value
  self.string_size = self.string_size + #value
  return offset, #value
end

function Encoder:handler(value, optional)
  if value == nil then
    if optional then return 0 end
    error("widget requires a handler", 3)
  end
  if type(value) == "function" then
    local id = self.next_handler
    self.next_handler = self.next_handler + 1
    self.callbacks[id] = value
    return id
  end
  return u64_number(value)
end

function Encoder:record(tag, fields)
  fields = fields or {}
  fields.tag = tag
  local index = #self.widgets
  self.widgets[index + 1] = fields
  return index, fields
end

function Encoder:with_key(node, record)
  if node.key ~= nil then
    record.flags = (record.flags or 0) + KEY_FLAG
    record.key_offset, record.key_len = self:string(node.key)
  end
end

function Encoder:children_range(nodes, context)
  local direct = {}
  for _, child in ipairs(nodes or {}) do
    direct[#direct + 1] = self:encode_node(child, context)
  end

  local first = #self.children
  for _, child_index in ipairs(direct) do
    self.children[#self.children + 1] = child_index
  end
  return first, #self.children - first
end

function Encoder:one_child(node, context)
  if node == nil then error("widget requires a child", 3) end
  return self:children_range({ node }, context)
end

function Encoder:encode_node(node, context)
  context = context or {}
  if type(node) == "string" or type(node) == "number" then node = ui.text(node) end
  if type(node) ~= "table" or not node.kind then error("expected widget", 3) end

  if node.kind == "theme" then
    return self:encode_node(node.child, context)
  elseif node.kind == "icon_theme" then
    local next_context = { icon_color = node.color or context.icon_color, icon_size = node.size or context.icon_size }
    return self:encode_node(node.child, next_context)
  end

  local index, record

  if node.kind == "text" then
    index, record = self:record(1, { extra0 = enum(text_roles, node.role, 0) })
    record.primary_offset, record.primary_len = self:string(node.value or "")
    if node.color ~= nil then record.flags = (record.flags or 0) + 1; record.color0 = node.color end
    if node.font_size ~= nil then record.flags = (record.flags or 0) + 2; record.a = node.font_size end
  elseif node.kind == "row" or node.kind == "column" then
    index, record = self:record(node.kind == "row" and 2 or 3, {
      a = node.gap or 0,
      extra0 = enum(cross_alignments, node.cross_align, 0),
      extra1 = enum(main_alignments, node.main_align, 0),
    })
    record.first_child, record.child_count = self:children_range(child_array(node.children), context)
  elseif node.kind == "container" or node.kind == "box" then
    local child = node.child
    if node.padding ~= nil then child = ui.padding({ padding = node.padding }, child) end
    index, record = self:record(4, {
      color0 = node.background or 0,
      a = node.border_width or 1,
      b = node.radius or 0,
      c = node.min_width or 0,
      d = node.min_height or 0,
      extra0 = enum(box_alignments, node.horizontal_align, 0),
      extra1 = enum(box_alignments, node.vertical_align, 0),
    })
    if node.border ~= nil then record.flags = (record.flags or 0) + 1; record.color1 = node.border end
    record.first_child, record.child_count = self:one_child(child, context)
  elseif node.kind == "padding" then
    local left, top, right, bottom = insets(node.insets)
    index, record = self:record(5, { a = left, b = top, c = right, d = bottom })
    record.first_child, record.child_count = self:one_child(node.child, context)
  elseif node.kind == "spacer" then
    index, record = self:record(6, { a = node.flex or 1 })
  elseif node.kind == "flexible" then
    index, record = self:record(7, { a = node.flex or 1, extra0 = enum(flex_fits, node.fit, 0) })
    record.first_child, record.child_count = self:one_child(node.child, context)
  elseif node.kind == "gesture_detector" or node.kind == "clickable" then
    index, record = self:record(8, { id0 = self:handler(node.handler), flags = node.activation == "press" and 2 or 0 })
    record.primary_offset, record.primary_len = self:string(node.id or ("gesture-detector-" .. tostring(record.id0)))
    if node.hover_background ~= nil then record.flags = (record.flags or 0) + 1; record.color0 = node.hover_background end
    record.first_child, record.child_count = self:one_child(node.child, context)
  elseif node.kind == "center" then
    index, record = self:record(9)
    record.first_child, record.child_count = self:one_child(node.child, context)
  elseif node.kind == "sized_box" or node.kind == "sized" then
    index, record = self:record(10, { c = node.min_width or 0, d = node.min_height or 0 })
    if node.width ~= nil then record.flags = (record.flags or 0) + 1; record.a = node.width end
    if node.height ~= nil then record.flags = (record.flags or 0) + 2; record.b = node.height end
    if node.max_width ~= nil then record.flags = (record.flags or 0) + 4; record.extra0 = f32_bits(node.max_width) end
    if node.max_height ~= nil then record.flags = (record.flags or 0) + 8; record.extra1 = f32_bits(node.max_height) end
    record.first_child, record.child_count = self:one_child(node.child, context)
  elseif node.kind == "image" then
    index, record = self:record(11, { id0 = node.resource })
    if node.width ~= nil then record.flags = (record.flags or 0) + 1; record.a = node.width end
    if node.height ~= nil then record.flags = (record.flags or 0) + 2; record.b = node.height end
    if node.tint ~= nil then record.flags = (record.flags or 0) + 4; record.color0 = node.tint end
  elseif node.kind == "icon" then
    index, record = self:record(12, { a = node.size or context.icon_size or 16 })
    record.primary_offset, record.primary_len = self:string(node.name or "")
    local color = node.color
    if color == nil then color = context.icon_color end
    if color ~= nil then record.flags = (record.flags or 0) + 1; record.color0 = color end
  elseif node.kind == "single_child_scroll_view" or node.kind == "scroll" then
    index, record = self:record(13, { extra0 = enum(scroll_axes, node.axes, 0) })
    record.primary_offset, record.primary_len = self:string(node.id or "scroll")
    record.first_child, record.child_count = self:one_child(node.child, context)
  elseif node.kind == "focus" then
    local flags = 0
    if node.autofocus then flags = flags + 1 end
    if node.skip_traversal then flags = flags + 2 end
    if node.can_request_focus ~= false then flags = flags + 4 end
    index, record = self:record(14, { flags = flags, id0 = self:handler(node.on_focus_change, true) })
    record.primary_offset, record.primary_len = self:string(node.id or "focus")
    record.first_child, record.child_count = self:one_child(node.child, context)
  elseif node.kind == "focus_scope" then
    index, record = self:record(15, { flags = node.modal and 1 or 0 })
    record.primary_offset, record.primary_len = self:string(node.id or "scope")
    record.first_child, record.child_count = self:one_child(node.child, context)
  elseif node.kind == "text_field" or node.kind == "text_input" then
    index, record = self:record(16, { flags = node.autofocus and 1 or 0, id0 = self:handler(node.on_change, true) })
    record.primary_offset, record.primary_len = self:string(node.id or "input")
    record.extra0, record.extra1 = self:string(node.value or "")
    record.extra2, record.extra3 = self:string(node.placeholder or "")
  elseif node.kind == "shortcuts" then
    local first = #self.bindings
    for _, binding in ipairs(node.bindings or {}) do
      self.bindings[#self.bindings + 1] = { key = enum(shortcut_keys, binding.key or binding[1], 0), handler = self:handler(binding.handler or binding[2]) }
    end
    index, record = self:record(17, { extra0 = first, extra1 = #self.bindings - first })
    record.first_child, record.child_count = self:one_child(node.child, context)
  elseif node.kind == "default_text_style" then
    index, record = self:record(18)
    if node.color ~= nil then record.flags = (record.flags or 0) + 1; record.color0 = node.color end
    if node.font_size ~= nil then record.flags = (record.flags or 0) + 2; record.a = node.font_size end
    record.first_child, record.child_count = self:one_child(node.child, context)
  elseif node.kind == "filled_button" or node.kind == "button" then
    index, record = self:record(19, { id0 = self:handler(node.handler, true), flags = node.activation == "release" and 1 or 0 })
    record.primary_offset, record.primary_len = self:string(node.id or ("filled-button-" .. tostring(record.id0)))
    record.first_child, record.child_count = self:one_child(node.child, context)
  else
    error("unknown widget kind: " .. tostring(node.kind), 3)
  end

  self:with_key(node, record)
  return index
end

function Encoder:pack(root)
  local root_index = self:encode_node(root)
  local widget_count = #self.widgets
  local child_count = #self.children
  local binding_count = #self.bindings
  local child_offset = HEADER_SIZE + widget_count * WIDGET_SIZE
  local binding_offset = child_offset + child_count * 4
  local string_offset = binding_offset + binding_count * BINDING_SIZE
  local total_size = string_offset + self.string_size
  local out = ffi.new("uint8_t[?]", total_size)

  ffi.copy(out, "KWW0", 4)
  put_u16(out, 4, 0)
  put_u16(out, 6, HEADER_SIZE)
  put_u32(out, 8, total_size)
  put_u32(out, 12, root_index)
  put_u32(out, 16, widget_count)
  put_u32(out, 20, child_count)
  put_u32(out, 24, binding_count)
  put_u32(out, 28, self.string_size)

  for i, record in ipairs(self.widgets) do
    local offset = HEADER_SIZE + (i - 1) * WIDGET_SIZE
    put_u16(out, offset, record.tag or 0)
    put_u16(out, offset + 2, record.flags or 0)
    put_u32(out, offset + 4, record.first_child or 0)
    put_u32(out, offset + 8, record.child_count or 0)
    put_u32(out, offset + 12, record.key_offset or 0)
    put_u32(out, offset + 16, record.key_len or 0)
    put_u32(out, offset + 20, record.primary_offset or 0)
    put_u32(out, offset + 24, record.primary_len or 0)
    put_u64(out, offset + 28, record.id0 or 0)
    put_f32(out, offset + 36, record.a or 0)
    put_f32(out, offset + 40, record.b or 0)
    put_f32(out, offset + 44, record.c or 0)
    put_f32(out, offset + 48, record.d or 0)
    put_u32(out, offset + 52, record.color0 or 0)
    put_u32(out, offset + 56, record.color1 or 0)
    put_u32(out, offset + 60, record.extra0 or 0)
    put_u32(out, offset + 64, record.extra1 or 0)
    put_u32(out, offset + 68, record.extra2 or 0)
    put_u32(out, offset + 72, record.extra3 or 0)
  end

  for i, child in ipairs(self.children) do
    put_u32(out, child_offset + (i - 1) * 4, child)
  end

  for i, binding in ipairs(self.bindings) do
    local offset = binding_offset + (i - 1) * BINDING_SIZE
    put_u32(out, offset, binding.key)
    put_u64(out, offset + 8, binding.handler)
  end

  local cursor = string_offset
  for _, value in ipairs(self.strings) do
    ffi.copy(out + cursor, value, #value)
    cursor = cursor + #value
  end

  return ffi.string(out, total_size), self.callbacks
end

local function encode(root)
  local encoder = Encoder.new()
  return encoder:pack(root)
end

M.encode = encode

local Context = {}
Context.__index = Context

local Surface = {}
Surface.__index = Surface

function M.context()
  local out = ffi.new("keywork_context_t *[1]")
  check(C().keywork_context_create(out), "keywork_context_create")
  return setmetatable({ handle = ffi.gc(out[0], C().keywork_context_destroy), surfaces = {} }, Context)
end

function M.abiVersion()
  return tonumber(C().keywork_abi_version())
end

function M.widgetVersion()
  return tonumber(C().keywork_widget_version())
end

M.abi_version = M.abiVersion
M.widget_version = M.widgetVersion
Context.create = M.context

local backends = { auto = 0, cpu = 1, shm = 1, wayland_shm = 1, vulkan = 2, headless = 3 }
local layers = { background = 0, bottom = 1, top = 2, overlay = 3 }
local keyboard_interactivity = { none = 0, exclusive = 1, on_demand = 2, ["on-demand"] = 2 }
local anchors = { top = 1, bottom = 2, left = 4, right = 8 }

local function anchor_mask(value)
  local mask = 0
  for _, anchor in ipairs(value or {}) do
    local bit = anchors[anchor]
    if not bit then error("unknown layer-shell anchor: " .. tostring(anchor), 3) end
    mask = mask + bit
  end
  return mask
end

function Context:create_surface(options)
  options = options or {}
  local raw = ffi.new("struct keywork_surface_options")
  raw.struct_size = ffi.sizeof(raw)
  raw.backend = enum(backends, options.backend, 0)
  raw.title = options.title or nil
  raw.app_id = options.app_id or nil
  raw.width = options.width or 640
  raw.height = options.height or 480
  if options.layer_shell then
    local layer = options.layer_shell == true and {} or options.layer_shell
    raw.layer_shell = 1
    raw.layer_namespace = layer.namespace or options.app_id or nil
    raw.layer = enum(layers, layer.layer, 2)
    raw.layer_anchors = anchor_mask(layer.anchor)
    raw.layer_exclusive_zone = layer.exclusive_zone or 0
    local margin = layer.margin or {}
    raw.layer_margin_top = margin.top or margin.y or margin.all or 0
    raw.layer_margin_right = margin.right or margin.x or margin.all or 0
    raw.layer_margin_bottom = margin.bottom or margin.y or margin.all or 0
    raw.layer_margin_left = margin.left or margin.x or margin.all or 0
    raw.layer_keyboard_interactivity = enum(keyboard_interactivity, layer.keyboard_interactivity, 0)
  end

  local out = ffi.new("keywork_surface_t *[1]")
  check(C().keywork_surface_create(self.handle, raw, out), "keywork_surface_create")
  local surface_id = u64_key(C().keywork_surface_id(out[0]))
  local surface = setmetatable({ context = self, handle = out[0], id = surface_id, callbacks = {} }, Surface)
  self.surfaces[surface_id] = surface
  return surface
end

Context.createSurface = Context.create_surface

function Context:event_fd()
  return tonumber(C().keywork_context_event_fd(self.handle))
end

Context.eventFd = Context.event_fd

function Context:dispatch()
  check(C().keywork_context_dispatch(self.handle), "keywork_context_dispatch")
end

function Context:next_event()
  local event = ffi.new("struct keywork_event")
  event.struct_size = ffi.sizeof(event)
  local result = C().keywork_context_next_event(self.handle, event)
  if result == 0 then return nil end
  if result < 0 then check(-result, "keywork_context_next_event") end

  local payload
  if event.payload_kind == 1 then
    payload = event.payload_bool ~= 0
  elseif event.payload_kind == 2 then
    payload = ffi.string(event.payload_ptr, event.payload_len)
  end
  return {
    kind = tonumber(event.kind),
    surface_id = u64_number(event.surface_id),
    document_id = u64_number(event.document_id),
    handler_id = u64_number(event.handler_id),
    payload = payload,
    width = tonumber(event.width),
    height = tonumber(event.height),
  }
end

Context.nextEvent = Context.next_event

function Context:drain_events(callback)
  while true do
    local event = self:next_event()
    if not event then break end

    if event.kind == 1 then
      local surface = self.surfaces[tostring(event.surface_id)]
      local document = surface and surface.callbacks[tostring(event.document_id)]
      local handler = document and document[event.handler_id]
      if handler then handler(event.payload, event) end
    elseif event.kind == 4 then
      self.cached_theme = nil
    elseif event.kind == 5 then
      local surface = self.surfaces[tostring(event.surface_id)]
      if surface then surface.callbacks[tostring(event.document_id)] = nil end
    end

    if callback then callback(event) end
  end
end

Context.drainEvents = Context.drain_events

function Context:color_scheme()
  local out = ffi.new("int[1]")
  check(C().keywork_context_get_color_scheme(self.handle, out), "keywork_context_get_color_scheme")
  return tonumber(out[0])
end

Context.colorScheme = Context.color_scheme

local color_scheme_names = {
  [0] = "no-preference",
  [1] = "dark",
  [2] = "light",
}

function Context:theme()
  if self.cached_theme then return self.cached_theme end

  local out = ffi.new("struct keywork_theme_colors")
  out.struct_size = ffi.sizeof(out)
  check(C().keywork_context_get_theme_colors(self.handle, out), "keywork_context_get_theme_colors")
  local color_scheme = tonumber(out.color_scheme)
  local colors = {
    primary = tonumber(out.primary),
    on_primary = tonumber(out.on_primary),
    primary_container = tonumber(out.primary_container),
    on_primary_container = tonumber(out.on_primary_container),
    surface = tonumber(out.surface),
    on_surface = tonumber(out.on_surface),
    on_surface_variant = tonumber(out.on_surface_variant),
    surface_container_low = tonumber(out.surface_container_low),
    surface_container = tonumber(out.surface_container),
    surface_container_high = tonumber(out.surface_container_high),
    error = tonumber(out.error),
    on_error = tonumber(out.on_error),
    error_container = tonumber(out.error_container),
    on_error_container = tonumber(out.on_error_container),
    outline = tonumber(out.outline),
    outline_variant = tonumber(out.outline_variant),
  }

  colors.onPrimary = colors.on_primary
  colors.primaryContainer = colors.primary_container
  colors.onPrimaryContainer = colors.on_primary_container
  colors.onSurface = colors.on_surface
  colors.onSurfaceVariant = colors.on_surface_variant
  colors.surfaceContainerLow = colors.surface_container_low
  colors.surfaceContainer = colors.surface_container
  colors.surfaceContainerHigh = colors.surface_container_high
  colors.onError = colors.on_error
  colors.errorContainer = colors.error_container
  colors.onErrorContainer = colors.on_error_container
  colors.outlineVariant = colors.outline_variant

  self.cached_theme = {
    color_scheme = color_scheme_names[color_scheme] or "unknown",
    colors = colors,
  }
  return self.cached_theme
end

function Context:set_icon_theme(theme_name)
  check(C().keywork_context_set_icon_theme(self.handle, theme_name), "keywork_context_set_icon_theme")
end

Context.setIconTheme = Context.set_icon_theme

function Context:create_image_rgba8(width, height, stride_bytes, pixels)
  local out = ffi.new("uint64_t[1]")
  check(C().keywork_context_create_image_rgba8(self.handle, width, height, stride_bytes, pixels, #pixels, out), "keywork_context_create_image_rgba8")
  return u64_number(out[0])
end

Context.createImageRgba8 = Context.create_image_rgba8

function Context:create_alpha_mask_a8(width, height, stride_bytes, pixels)
  local out = ffi.new("uint64_t[1]")
  check(C().keywork_context_create_alpha_mask_a8(self.handle, width, height, stride_bytes, pixels, #pixels, out), "keywork_context_create_alpha_mask_a8")
  return u64_number(out[0])
end

Context.createAlphaMaskA8 = Context.create_alpha_mask_a8

function Context:release_resource(resource_id)
  C().keywork_context_release_resource(self.handle, resource_id)
end

Context.releaseResource = Context.release_resource

function Context:destroy()
  if self.handle then
    for _, surface in pairs(self.surfaces) do
      surface.handle = nil
    end
    self.surfaces = {}
    ffi.gc(self.handle, nil)
    C().keywork_context_destroy(self.handle)
    self.handle = nil
  end
end

function Surface:submit(root)
  local bytes, callbacks = encode(root)
  local out = ffi.new("uint64_t[1]")
  check(C().keywork_surface_submit(self.handle, bytes, #bytes, out), "keywork_surface_submit")
  local document_id = u64_number(out[0])
  self.callbacks[tostring(document_id)] = callbacks
  return document_id
end

function Surface:invalidate()
  check(C().keywork_surface_invalidate(self.handle), "keywork_surface_invalidate")
end

function Surface:destroy()
  if self.handle then
    C().keywork_surface_destroy(self.context.handle, self.handle)
    self.context.surfaces[self.id] = nil
    self.handle = nil
  end
end

M.Context = Context
M.Surface = Surface

return M
