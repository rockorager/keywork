--- XDG base directories and filesystem helpers for application state.
--- Loaded by the module loader with the native xdg table (mkdir_all,
--- read_dir, read_file, write_file) as its sole argument; augments it in
--- place. Directory functions follow the XDG Base Directory spec:
--- environment overrides win, otherwise the spec's defaults apply.

local xdg = ...

local function env_dir(name)
  local value = os.getenv(name)
  if value and value ~= "" and value:sub(1, 1) == "/" then
    return value
  end
  return nil
end

local function home()
  return os.getenv("HOME") or ""
end

function xdg.data_home()
  return env_dir("XDG_DATA_HOME") or (home() .. "/.local/share")
end

function xdg.config_home()
  return env_dir("XDG_CONFIG_HOME") or (home() .. "/.config")
end

function xdg.cache_home()
  return env_dir("XDG_CACHE_HOME") or (home() .. "/.cache")
end

function xdg.state_home()
  return env_dir("XDG_STATE_HOME") or (home() .. "/.local/state")
end

--- The per-session runtime directory, or nil when the session did not
--- provide one (the spec has no fallback).
function xdg.runtime_dir()
  return env_dir("XDG_RUNTIME_DIR")
end

local function split_dirs(value)
  local dirs = {}
  for dir in value:gmatch("[^:]+") do
    if dir:sub(1, 1) == "/" then
      table.insert(dirs, dir)
    end
  end
  return dirs
end

--- Data search path: data_home first, then XDG_DATA_DIRS (or the spec
--- default /usr/local/share:/usr/share).
function xdg.data_dirs()
  local dirs = { xdg.data_home() }
  local system = os.getenv("XDG_DATA_DIRS")
  if not system or system == "" then
    system = "/usr/local/share:/usr/share"
  end
  for _, dir in ipairs(split_dirs(system)) do
    table.insert(dirs, dir)
  end
  return dirs
end

--- Config search path: config_home first, then XDG_CONFIG_DIRS (or the
--- spec default /etc/xdg).
function xdg.config_dirs()
  local dirs = { xdg.config_home() }
  local system = os.getenv("XDG_CONFIG_DIRS")
  if not system or system == "" then
    system = "/etc/xdg"
  end
  for _, dir in ipairs(split_dirs(system)) do
    table.insert(dirs, dir)
  end
  return dirs
end
