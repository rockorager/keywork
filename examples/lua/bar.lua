local ui = require("ui")
local keywork = require("keywork")
local ffi = require("ffi")
local bit = require("bit")

if not rawget(_G, "keywork_bar_ffi_loaded") then
  ffi.cdef([[
typedef unsigned int socklen_t;
typedef long ssize_t;
typedef unsigned short sa_family_t;
struct sockaddr { sa_family_t sa_family; char sa_data[14]; };
struct sockaddr_un { sa_family_t sun_family; char sun_path[108]; };
int socket(int domain, int type, int protocol);
int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
ssize_t read(int fd, void *buf, size_t count);
ssize_t recv(int sockfd, void *buf, size_t len, int flags);
ssize_t write(int fd, const void *buf, size_t count);
int close(int fd);
int fcntl(int fd, int cmd, ...);
]])
  _G.keywork_bar_ffi_loaded = true
end

local AF_UNIX = 1
local SOCK_STREAM = 1
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 2048
local MSG_DONTWAIT = 64
local EAGAIN = 11
local EWOULDBLOCK = 11
local EPOLLIN = 1
local EPOLLERR = 8
local EPOLLHUP = 16
local IPC_COMMAND = 0
local IPC_GET_WORKSPACES = 1
local IPC_SUBSCRIBE = 2

local colors = {
  background = 0xff16161e,
  surface = 0xff1f2335,
  foreground = 0xffc0caf5,
  muted = 0xff565f89,
  blue = 0xff7aa2f7,
  cyan = 0xff7dcfff,
  green = 0xff9ece6a,
  yellow = 0xffe0af68,
  magenta = 0xffbb9af7,
  red = 0xfff7768e,
}

local function trim(value)
  local trimmed = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed
end

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
  if not b4 then
    return nil
  end
  return b1 + bit.lshift(b2, 8) + bit.lshift(b3, 16) + bit.lshift(b4, 24)
end

local function write_all(fd, data)
  local written = 0
  while written < #data do
    local rc = ffi.C.write(fd, data:sub(written + 1), #data - written)
    if rc <= 0 then
      return false
    end
    written = written + tonumber(rc)
  end
  return true
end

local function sway_send(client, message_type, payload)
  payload = payload or ""
  return write_all(client.fd, "i3-ipc" .. le32(#payload) .. le32(message_type) .. payload)
end

local function json_string(value)
  return tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"')
end

local function parse_workspaces(payload)
  local workspaces = {}
  for object in payload:gmatch("%b{}") do
    local name = object:match('"name"%s*:%s*"(.-)"')
    if name then
      table.insert(workspaces, {
        name = name,
        focused = object:match('"focused"%s*:%s*true') ~= nil,
        urgent = object:match('"urgent"%s*:%s*true') ~= nil,
      })
    end
  end
  return workspaces
end

local function handle_sway_frame(client, message_type, payload)
  if message_type == IPC_GET_WORKSPACES then
    client.workspaces = parse_workspaces(payload)
    return true
  end

  if bit.band(message_type, 0x80000000) ~= 0 then
    sway_send(client, IPC_GET_WORKSPACES, "")
  end
  return false
end

local function drain_sway(client)
  local changed = false
  local buffer = ffi.new("uint8_t[4096]")
  while true do
    local count = ffi.C.recv(client.fd, buffer, ffi.sizeof(buffer), MSG_DONTWAIT)
    if count > 0 then
      client.buffer = client.buffer .. ffi.string(buffer, tonumber(count))
    elseif count == 0 then
      client.connected = false
      return changed
    else
      local err = ffi.errno()
      if err == EAGAIN or err == EWOULDBLOCK then
        break
      end
      client.connected = false
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
    if not length or not message_type or #client.buffer < 14 + length then
      break
    end
    local payload = client.buffer:sub(15, 14 + length)
    client.buffer = client.buffer:sub(15 + length)
    changed = handle_sway_frame(client, message_type, payload) or changed
  end
  return changed
end

local function connect_sway()
  local path = os.getenv("SWAYSOCK")
  if not path or path == "" or #path >= 108 then
    return nil
  end

  local fd = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
  if fd < 0 then
    return nil
  end

  local addr = ffi.new("struct sockaddr_un")
  addr.sun_family = AF_UNIX
  ffi.copy(addr.sun_path, path, #path)
  if ffi.C.connect(fd, ffi.cast("const struct sockaddr *", addr), ffi.sizeof(addr)) ~= 0 then
    ffi.C.close(fd)
    return nil
  end

  local flags = ffi.C.fcntl(fd, F_GETFL, 0)
  if flags >= 0 then
    ffi.C.fcntl(fd, F_SETFL, bit.bor(flags, O_NONBLOCK))
  end

  local client = {
    fd = tonumber(fd),
    buffer = "",
    workspaces = {},
    connected = true,
  }

  keywork.watch_fd(client.fd, function(_, events)
    if bit.band(events, bit.bor(EPOLLERR, EPOLLHUP)) ~= 0 then
      client.connected = false
    end
    if bit.band(events, EPOLLIN) ~= 0 then
      return drain_sway(client)
    end
    return false
  end)
  sway_send(client, IPC_GET_WORKSPACES, "")
  sway_send(client, IPC_SUBSCRIBE, '["workspace"]')
  return client
end

local sway = rawget(_G, "keywork_bar_sway")
if not sway then
  sway = connect_sway() or { fd = -1, buffer = "", workspaces = {}, connected = false }
  _G.keywork_bar_sway = sway
end

local function command_output(command)
  local pipe = io.popen(command .. " 2>/dev/null")
  if not pipe then
    return ""
  end
  local output = pipe:read("*a") or ""
  pipe:close()
  return trim(output)
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local value = file:read("*a")
  file:close()
  return trim(value)
end

local function label(value, color)
  return ui.label(value, { color = color or colors.foreground })
end

local function status_pill(id, icon_name, text, color, options)
  options = options or {}
  return ui.chip({
    id = id,
    icon = icon_name,
    label = text,
    icon_size = options.icon_size or 16,
    color = color,
    background = colors.surface,
    radius = 10,
    min_height = 30,
    align = "center",
    padding = { x = 7 },
    on_tap = function()
      print("clicked " .. id)
    end,
  })
end

local function workspaces()
  local items = {}
  for _, workspace in ipairs(sway.workspaces or {}) do
    local name = workspace.name
    local fg = colors.muted
    local bg = colors.background
    if workspace.urgent then
      fg = colors.background
      bg = colors.red
    elseif workspace.focused then
      fg = colors.background
      bg = colors.blue
    end
    table.insert(items, ui.chip({
      id = "workspace-" .. name,
      label = name,
      color = fg,
      background = bg,
      radius = 9,
      min_height = 30,
      align = "center",
      padding = { x = 8 },
      on_tap_down = function()
        if sway.connected then
          sway_send(sway, IPC_COMMAND, 'workspace "' .. json_string(name) .. '"')
        end
      end,
    }))
  end

  if #items == 0 then
    table.insert(items, label(sway.connected and "loading sway" or "no sway", colors.muted))
  end
  return ui.row(items, 4)
end

local function volume_status()
  local output = command_output("wpctl get-volume @DEFAULT_AUDIO_SINK@")
  local raw = tonumber(output:match("Volume:%s*([%d%.]+)")) or 0
  local percent = math.floor(raw * 100 + 0.5)
  local muted = output:find("MUTED", 1, true) ~= nil
  local name = "audio-volume-high"
  local color = colors.magenta
  if muted or percent <= 0 then
    name = "audio-volume-muted"
    color = colors.muted
  elseif percent < 34 then
    name = "audio-volume-low"
  elseif percent < 67 then
    name = "audio-volume-medium"
  end
  return status_pill("volume", name, nil, color)
end

local function wifi_quality()
  local wireless = read_file("/proc/net/wireless") or ""
  local iface, quality = wireless:match("\n%s*([^:]+):%s+[%d]+%s+([%d%.]+)")
  if not iface then
    iface = command_output("sh -c 'ls /sys/class/net | grep -E \"^wl|^wlan\" | head -n1'")
  end
  if iface == "" then
    return { connected = false, percent = 0, essid = "" }
  end
  local operstate = read_file("/sys/class/net/" .. iface .. "/operstate") or "down"
  local essid = command_output("iwgetid -r")
  local percent = 0
  if quality then
    percent = math.max(0, math.min(100, math.floor((tonumber(quality) or 0) * 100 / 70 + 0.5)))
  elseif operstate == "up" then
    percent = 100
  end
  return { connected = operstate == "up", percent = percent, essid = essid }
end

local function network_status()
  local wifi = wifi_quality()
  local name = "network-wireless-offline"
  local color = colors.red
  if wifi.connected then
    color = colors.blue
    if wifi.percent >= 80 then
      name = "network-wireless-signal-excellent"
    elseif wifi.percent >= 60 then
      name = "network-wireless-signal-good"
    elseif wifi.percent >= 40 then
      name = "network-wireless-signal-ok"
    elseif wifi.percent >= 20 then
      name = "network-wireless-signal-weak"
    else
      name = "network-wireless-signal-none"
    end
  end
  return status_pill("network", name, nil, color)
end

local function battery_status()
  local battery = command_output("sh -c 'ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n1'")
  if battery == "" then
    return status_pill("battery", "battery-level-0", "", colors.muted, { icon_size = 14 })
  end
  local capacity = tonumber(read_file(battery .. "/capacity")) or 0
  local status = read_file(battery .. "/status") or "Unknown"
  local level = math.floor(capacity / 10) * 10
  if capacity > 0 and level == 0 then
    level = 10
  end
  if capacity >= 95 then
    level = 100
  end

  local name = "battery-level-" .. tostring(level)
  if status == "Charging" then
    name = name .. "-charging"
  elseif status == "Full" then
    name = "battery-level-100-charged"
  end

  local color = colors.green
  if status ~= "Charging" and status ~= "Full" then
    if capacity <= 15 then
      color = colors.red
    elseif capacity <= 30 then
      color = colors.yellow
    end
  end
  return status_pill("battery", name, tostring(capacity) .. "%", color, { icon_size = 14 })
end

local StatusItems = ui.stateful({
  init = function()
    return {}
  end,

  build = function(self, state)
    if self.pulse ~= state.pulse then
      self.pulse = state.pulse
      self.volume = volume_status()
      self.network = network_status()
      self.battery = battery_status()
      self.time = os.date("%a %b %d  %I:%M %p")
    end

    return ui.row({
      gap = 8,
      align = "center",
      children = {
        self.volume,
        self.network,
        self.battery,
        label(self.time, colors.foreground),
      },
    })
  end,
})

return function(state)
  local theme = ui.theme_for(state)
  local left = ui.row({
    gap = 10,
    align = "center",
    children = {
      workspaces(),
      ui.row({
        gap = 6,
        align = "center",
        children = {
          ui.svg_icon("examples/lua/icons/bolt.svg", 16, colors.magenta),
          label("Keywork", colors.foreground),
        },
      }),
    },
  })

  return ui.theme(theme, ui.container({ background = colors.background, padding = { all = 4 } },
    ui.row({
      gap = 12,
      align = "center",
      children = {
        left,
        ui.spacer(),
        StatusItems({ key = "status" }),
      },
    })
  ))
end
