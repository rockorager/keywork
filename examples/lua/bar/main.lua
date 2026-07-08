local ffi = require("ffi")
local keywork = require("keywork")
local bit = require("bit")

local ui = keywork.ui
local has_uv, uv = pcall(require, "luv")
local has_unix_socket, unix_socket = pcall(require, "socket.unix")

ffi.cdef[[
typedef unsigned long nfds_t;
struct pollfd {
  int fd;
  short events;
  short revents;
};
int poll(struct pollfd *fds, nfds_t nfds, int timeout);
]]

local POLLIN = 1
local POLLERR = 8
local POLLHUP = 16
local IPC_COMMAND = 0
local IPC_GET_WORKSPACES = 1
local IPC_SUBSCRIBE = 2

local state = {
  workspaces = {},
  clock = "",
  sway = nil,
}

local function le32(value)
  return string.char(
    bit.band(value, 0xff),
    bit.band(bit.rshift(value, 8), 0xff),
    bit.band(bit.rshift(value, 16), 0xff),
    bit.band(bit.rshift(value, 24), 0xff)
  )
end

local function read_le32(value, offset)
  local b1, b2, b3, b4 = value:byte(offset, offset + 3)
  if not b4 then return nil end
  return b1 + bit.lshift(b2, 8) + bit.lshift(b3, 16) + bit.lshift(b4, 24)
end

local function write_all(socket, data)
  local sent = 0
  while sent < #data do
    local index, err, partial = socket:send(data, sent + 1)
    if index then
      sent = index
    elseif err == "timeout" and partial and partial > sent then
      sent = partial
    else
      return false
    end
  end
  return true
end

local function sway_send(client, message_type, payload)
  payload = payload or ""
  return write_all(client.socket, "i3-ipc" .. le32(#payload) .. le32(message_type) .. payload)
end

local function json_string(value)
  return tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"')
end

local function parse_workspaces(payload)
  local result = {}
  for object in payload:gmatch("%b{}") do
    local name = object:match('"name"%s*:%s*"(.-)"')
    if name then
      result[#result + 1] = {
        name = name,
        focused = object:match('"focused"%s*:%s*true') ~= nil,
        urgent = object:match('"urgent"%s*:%s*true') ~= nil,
      }
    end
  end
  return result
end

local function handle_sway_frame(client, message_type, payload)
  if message_type == IPC_GET_WORKSPACES then
    state.workspaces = parse_workspaces(payload)
    return true
  end

  if bit.band(message_type, 0x80000000) ~= 0 then
    sway_send(client, IPC_GET_WORKSPACES, "")
  end
  return false
end

local function drain_sway(client)
  local changed = false
  while true do
    local data, err, partial = client.socket:receive(4096)
    local chunk = data or partial
    if chunk and #chunk > 0 then client.buffer = client.buffer .. chunk end
    if data then
      -- A full read may have left more data queued; keep draining.
    elseif err == "timeout" then
      break
    else
      if err == "closed" then client.connected = false end
      return changed
    end
  end

  while #client.buffer >= 14 do
    if client.buffer:sub(1, 6) ~= "i3-ipc" then
      client.connected = false
      return changed
    end
    local length = read_le32(client.buffer, 7)
    local message_type = read_le32(client.buffer, 11)
    if not length or not message_type or #client.buffer < 14 + length then break end
    local payload = client.buffer:sub(15, 14 + length)
    client.buffer = client.buffer:sub(15 + length)
    changed = handle_sway_frame(client, message_type, payload) or changed
  end
  return changed
end

local function connect_sway()
  local path = os.getenv("SWAYSOCK")
  if not has_unix_socket or not path or path == "" then return nil end

  local socket = unix_socket()
  if not socket then return nil end
  if not socket:connect(path) then
    socket:close()
    return nil
  end
  socket:settimeout(0)

  local client = {
    socket = socket,
    fd = socket:getfd(),
    buffer = "",
    connected = true,
  }
  sway_send(client, IPC_GET_WORKSPACES, "")
  sway_send(client, IPC_SUBSCRIBE, '["workspace"]')
  return client
end

local function refresh_clock()
  state.clock = os.date("%a %b %d  %I:%M %p")
end

local function bar_colors(theme)
  local scheme = theme.colors
  return {
    background = scheme.surface,
    border = scheme.outline_variant,
    foreground = scheme.on_surface,
    muted = scheme.on_surface_variant,
    subtle = scheme.on_surface_variant,
    hover = scheme.surface_container_low,
    active = scheme.surface_container_high,
    active_hover = scheme.surface_container_high,
    on_active = scheme.on_surface,
    error = scheme.error,
    on_error = scheme.on_error,
    accent = scheme.on_surface,
  }
end

local function label(palette, text, color)
  return ui.label(text, { color = color or palette.foreground, font_size = 13 })
end

local function status_pill(palette, id, text, color)
  return ui.chip({
    id = id,
    child = label(palette, text, color),
    radius = 8,
    min_height = 28,
    align = "center",
    padding = { x = 8 },
    hover_background = palette.hover,
  })
end

local function workspace_chip(palette, workspace)
  local selected = workspace.focused or workspace.urgent
  return ui.chip({
    key = "workspace-" .. workspace.name,
    id = "workspace-" .. workspace.name,
    label = workspace.name,
    color = palette.muted,
    hover_background = palette.hover,
    selected = selected,
    selected_background = palette.active,
    selected_hover_background = palette.active_hover,
    selected_color = palette.on_active,
    radius = 8,
    min_height = 28,
    align = "center",
    padding = { x = 12 },
    on_tap_down = function()
      if state.sway and state.sway.connected then
        sway_send(state.sway, IPC_COMMAND, 'workspace "' .. json_string(workspace.name) .. '"')
      end
    end,
  })
end

local function build(theme)
  local palette = bar_colors(theme)
  local workspace_widgets = {}
  for _, workspace in ipairs(state.workspaces) do
    workspace_widgets[#workspace_widgets + 1] = workspace_chip(palette, workspace)
  end
  if #workspace_widgets == 0 then
    workspace_widgets[1] = label(palette, os.getenv("SWAYSOCK") and "loading sway" or "no sway", palette.muted)
  end

  local status_widgets = {}
  status_widgets[#status_widgets + 1] = status_pill(palette, "clock", state.clock, palette.foreground)

  return ui.column({
    align = "stretch",
    children = {
      ui.expanded(ui.container({
        background = palette.background,
        vertical_align = "center",
        padding = { x = 6, y = 5 },
      }, ui.row({
        spacing = 12,
        align = "center",
        children = {
          ui.row({ spacing = 4, align = "center", children = workspace_widgets }),
          ui.spacer(),
          ui.row({ spacing = 8, align = "center", children = status_widgets }),
        },
      }))),
      ui.container({ background = palette.border, min_height = 1 }, ui.sized_box({ height = 1 }, ui.text(""))),
    },
  })
end

local function submit(context, surface)
  refresh_clock()
  surface:submit(build(context:theme()))
end

local function submit_if_sway_changed(context, surface)
  if state.sway and drain_sway(state.sway) then
    surface:submit(build(context:theme()))
  end
end

local function drain(context, stop)
  context:dispatch()
  context:drain_events(function(event)
    if event.kind == 3 then stop() end
  end)
end

local function run_with_luv(context, surface)
  local closed = false
  local poll = assert(uv.new_poll(context:event_fd()))
  local sway_poll = state.sway and assert(uv.new_poll(state.sway.fd)) or nil
  local timer = assert(uv.new_timer())

  local function close()
    if closed then return end
    closed = true
    poll:stop()
    if sway_poll then sway_poll:stop() end
    timer:stop()
    poll:close()
    if sway_poll then sway_poll:close() end
    timer:close()
    if state.sway then state.sway.socket:close() end
    surface:destroy()
    context:destroy()
    uv.stop()
  end

  submit(context, surface)
  timer:start(1000, 1000, function()
    submit(context, surface)
  end)
  poll:start("r", function(err)
    if err then error(err) end
    drain(context, close)
  end)
  if sway_poll then
    sway_poll:start("r", function(err)
      if err then
        state.sway.connected = false
      else
        submit_if_sway_changed(context, surface)
      end
    end)
  end
  uv.run()
end

local function run_with_poll(context, surface)
  local poll_count = state.sway and 2 or 1
  local fds = ffi.new("struct pollfd[?]", poll_count)
  fds[0].fd = context:event_fd()
  fds[0].events = POLLIN
  if state.sway then
    fds[1].fd = state.sway.fd
    fds[1].events = POLLIN
  end

  local running = true
  local next_refresh = 0
  local function stop()
    running = false
  end

  while running do
    local now = os.time()
    if now >= next_refresh then
      submit(context, surface)
      next_refresh = now + 1
    end

    local timeout = math.max(0, (next_refresh - os.time()) * 1000)
    local ready = ffi.C.poll(fds, poll_count, timeout)
    if ready < 0 then error("poll failed") end
    if ready > 0 then
      if fds[0].revents ~= 0 then drain(context, stop) end
      if state.sway and fds[1].revents ~= 0 then
        if bit.band(fds[1].revents, bit.bor(POLLERR, POLLHUP)) ~= 0 then
          state.sway.connected = false
        end
        if bit.band(fds[1].revents, POLLIN) ~= 0 then
          submit_if_sway_changed(context, surface)
        end
      end
    end
  end

  if state.sway then state.sway.socket:close() end
  surface:destroy()
  context:destroy()
end

local function main()
  local context = keywork.context()
  local surface = context:create_surface({
    app_id = "dev.keywork.LuaBarExample",
    title = "Keywork Lua bar example",
    backend = os.getenv("KEYWORK_BACKEND") or "auto",
    width = 0,
    height = 40,
    layer_shell = {
      layer = "top",
      anchor = { "top", "left", "right" },
      exclusive_zone = 40,
    },
  })
  state.sway = connect_sway()

  if has_uv then
    run_with_luv(context, surface)
  else
    run_with_poll(context, surface)
  end
end

main()
