--- XDG Desktop Entry parsing and launching: locale-aware parse of
--- .desktop files, desktop-id lookup across XDG data dirs, Exec field
--- code substitution, and launch with Terminal and DBusActivatable
--- handling. Enumeration and watching stay in app code. launch() may
--- yield (D-Bus activation, spawning), so call it from a task.

local unpack = unpack or table.unpack

local M = {}

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The locale for key resolution, per the spec's LC_MESSAGES lookup
-- order, with the .encoding part dropped (it never affects matching in
-- practice: modern files are UTF-8).
local function current_locale()
  local locale = os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or os.getenv("LANG") or ""
  locale = locale:gsub("%..-@", "@"):gsub("%.[^@]*$", "")
  if locale == "" or locale == "C" or locale == "POSIX" then
    return nil
  end
  return locale
end

-- Match candidates in precedence order: lang_COUNTRY@MODIFIER,
-- lang_COUNTRY, lang@MODIFIER, lang.
local function locale_variants(locale)
  if not locale then
    return {}
  end
  local lang, country, modifier = locale:match("^([^_@]+)_([^@]+)@(.+)$")
  if not lang then
    lang, country = locale:match("^([^_@]+)_([^@]+)$")
  end
  if not lang then
    lang, modifier = locale:match("^([^_@]+)@(.+)$")
  end
  if not lang then
    lang = locale
  end
  local variants = {}
  if country and modifier then
    table.insert(variants, lang .. "_" .. country .. "@" .. modifier)
  end
  if country then
    table.insert(variants, lang .. "_" .. country)
  end
  if modifier then
    table.insert(variants, lang .. "@" .. modifier)
  end
  table.insert(variants, lang)
  return variants
end

-- Values of type string escape whitespace and backslashes.
local escapes = { s = " ", n = "\n", t = "\t", r = "\r", ["\\"] = "\\" }
local function unescape(value)
  return (value:gsub("\\(.)", function(ch)
    return escapes[ch] or ("\\" .. ch)
  end))
end

-- Multiple values are ;-separated with \; escaping the separator.
local function split_list(value)
  local items = {}
  local current = {}
  local index = 1
  while index <= #value do
    local ch = value:sub(index, index)
    if ch == "\\" and index < #value then
      table.insert(current, value:sub(index + 1, index + 1))
      index = index + 2
    elseif ch == ";" then
      local item = unescape(table.concat(current))
      if item ~= "" then
        table.insert(items, item)
      end
      current = {}
      index = index + 1
    else
      table.insert(current, ch)
      index = index + 1
    end
  end
  local tail = unescape(table.concat(current))
  if tail ~= "" then
    table.insert(items, tail)
  end
  return items
end

-- Reads a group's key with locale fallback: Key[variant] wins over Key.
local function localized(group, key, variants)
  for _, variant in ipairs(variants) do
    local value = group[key .. "[" .. variant .. "]"]
    if value then
      return unescape(value)
    end
  end
  local value = group[key]
  return value and unescape(value) or nil
end

-- Splits an Exec value into raw tokens per the spec's quoting rules:
-- arguments separated by spaces, optionally double-quoted; inside
-- quotes, backslash escapes the next character.
local function tokenize_exec(exec)
  local tokens = {}
  local current = nil
  local index = 1
  local quoted = false
  while index <= #exec do
    local ch = exec:sub(index, index)
    if quoted then
      if ch == "\\" and index < #exec then
        current = current .. exec:sub(index + 1, index + 1)
        index = index + 2
      elseif ch == '"' then
        quoted = false
        index = index + 1
      else
        current = current .. ch
        index = index + 1
      end
    elseif ch == '"' then
      quoted = true
      current = current or ""
      index = index + 1
    elseif ch == " " or ch == "\t" then
      if current then
        table.insert(tokens, current)
        current = nil
      end
      index = index + 1
    else
      current = (current or "") .. ch
      index = index + 1
    end
  end
  if quoted then
    return nil, "unterminated quote in Exec"
  end
  if current then
    table.insert(tokens, current)
  end
  return tokens
end

local function basename(path)
  return path:match("([^/]+)$") or path
end

local function to_file_uri(path)
  if path:match("^%a[%w+.-]*:") then
    return path
  end
  return "file://" .. path:gsub("([^%w/_.~-])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end)
end

local function to_path(uri)
  local path = uri:match("^file://([^#?]*)")
  if not path then
    return nil
  end
  return (path:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Parses a desktop file into an entry table. Localized keys resolve
--- against opts.locale (default: process locale). Returns nil, err when
--- the file is unreadable or not an application entry. NoDisplay and
--- Hidden are reported, not filtered: visibility is app policy.
function M.parse(path, opts)
  opts = opts or {}
  local file, err = io.open(path, "r")
  if not file then
    return nil, err or ("cannot open " .. path)
  end

  local groups = {}
  local group = nil
  for line in file:lines() do
    local header = line:match("^%[(.-)%]%s*$")
    if header then
      group = {}
      groups[header] = group
    elseif group and not line:match("^%s*#") then
      local key, value = line:match("^([%w%-]+%[?[%w%-_@.]*%]?)%s*=%s*(.-)%s*$")
      if key then
        group[key] = value
      end
    end
  end
  file:close()

  local main = groups["Desktop Entry"]
  if not main then
    return nil, "missing Desktop Entry group"
  end
  if (main.Type or "Application") ~= "Application" then
    return nil, "not an application: " .. (main.Type or "?")
  end

  local variants = locale_variants(opts.locale or current_locale())
  local entry = {
    path = path,
    id = opts.id or basename(path),
    name = localized(main, "Name", variants),
    generic_name = localized(main, "GenericName", variants),
    comment = localized(main, "Comment", variants),
    icon = localized(main, "Icon", variants),
    exec = main.Exec and unescape(main.Exec) or nil,
    try_exec = main.TryExec and unescape(main.TryExec) or nil,
    wd = main.Path and unescape(main.Path) or nil,
    terminal = main.Terminal == "true",
    dbus_activatable = main.DBusActivatable == "true",
    no_display = main.NoDisplay == "true",
    hidden = main.Hidden == "true",
    single_main_window = main.SingleMainWindow == "true",
    startup_wm_class = main.StartupWMClass,
    keywords = split_list(localized(main, "Keywords", variants) or ""),
    categories = split_list(main.Categories or ""),
    mime_types = split_list(main.MimeType or ""),
    only_show_in = split_list(main.OnlyShowIn or ""),
    not_show_in = split_list(main.NotShowIn or ""),
    fields = main,
  }
  if not entry.name then
    return nil, "missing Name"
  end

  entry.actions = {}
  for _, action_id in ipairs(split_list(main.Actions or "")) do
    local action_group = groups["Desktop Action " .. action_id]
    if action_group then
      table.insert(entry.actions, {
        id = action_id,
        name = localized(action_group, "Name", variants) or action_id,
        icon = localized(action_group, "Icon", variants),
        exec = action_group.Exec and unescape(action_group.Exec) or nil,
      })
    end
  end
  return entry
end

--- The XDG data dir search list, highest priority first: XDG_DATA_HOME
--- (default ~/.local/share) then XDG_DATA_DIRS (default
--- /usr/local/share:/usr/share). Callers enumerating desktop files
--- should scan <dir>/applications for each.
function M.data_dirs()
  local dirs = {}
  local seen = {}
  local function add(dir)
    dir = trim(dir)
    if dir ~= "" and not seen[dir] then
      seen[dir] = true
      table.insert(dirs, dir)
    end
  end
  local data_home = os.getenv("XDG_DATA_HOME")
  if not data_home or data_home == "" then
    data_home = (os.getenv("HOME") or "") .. "/.local/share"
  end
  add(data_home)
  local data_paths = os.getenv("XDG_DATA_DIRS")
  if not data_paths or data_paths == "" then
    data_paths = "/usr/local/share:/usr/share"
  end
  for dir in data_paths:gmatch("[^:]+") do
    add(dir)
  end
  return dirs
end

local function file_exists(path)
  local file = io.open(path, "r")
  if not file then
    return false
  end
  file:close()
  return true
end

-- Desktop file ids replace "/" with "-", which is ambiguous to reverse;
-- try the literal name first, then each dash as a possible subdirectory
-- split, left to right (the GLib strategy).
local function find_by_id(base, id)
  local direct = base .. "/" .. id
  if file_exists(direct) then
    return direct
  end
  local from = 1
  while true do
    local dash = id:find("-", from, true)
    if not dash then
      return nil
    end
    local nested = find_by_id(base .. "/" .. id:sub(1, dash - 1), id:sub(dash + 1))
    if nested then
      return nested
    end
    from = dash + 1
  end
end

--- Finds and parses a desktop entry by id ("org.example.App.desktop";
--- a missing .desktop suffix is added). Earlier data dirs win. opts.dirs
--- overrides the XDG data dir list; other opts pass through to parse.
function M.lookup(desktop_id, opts)
  opts = opts or {}
  assert(type(desktop_id) == "string" and desktop_id ~= "", "lookup requires a desktop id")
  if not desktop_id:match("%.desktop$") then
    desktop_id = desktop_id .. ".desktop"
  end
  for _, dir in ipairs(opts.dirs or M.data_dirs()) do
    local path = find_by_id(dir .. "/applications", desktop_id)
    if path then
      return M.parse(path, { locale = opts.locale, id = desktop_id })
    end
  end
  return nil, "no desktop entry for " .. desktop_id
end

-- Expands one token's inline field codes. Standalone list codes are
-- handled by the caller; here %f/%u fall back to the first value so
-- lenient files still work.
local function expand_inline(token, context)
  local out = {}
  local index = 1
  while index <= #token do
    local ch = token:sub(index, index)
    if ch == "%" and index < #token then
      local code = token:sub(index + 1, index + 1)
      if code == "%" then
        table.insert(out, "%")
      elseif code == "f" or code == "F" then
        table.insert(out, context.files[1] or "")
      elseif code == "u" or code == "U" then
        table.insert(out, context.uris[1] or "")
      elseif code == "c" then
        table.insert(out, context.name or "")
      elseif code == "k" then
        table.insert(out, context.path or "")
      end
      -- Deprecated codes (%d %D %n %N %v %m) and %i expand to nothing
      -- inline; %i is only meaningful as a standalone token.
      index = index + 2
    else
      table.insert(out, ch)
      index = index + 1
    end
  end
  return table.concat(out)
end

--- Builds the argv for an entry (or one of its actions via
--- opts.action): tokenizes Exec and substitutes field codes. opts.files
--- and opts.uris supply %f/%F/%u/%U arguments; paths and URIs are
--- converted as needed. Returns nil, err for entries without Exec.
function M.exec_argv(entry, opts)
  opts = opts or {}
  local exec = entry.exec
  local name = entry.name
  if opts.action then
    local found = nil
    for _, action in ipairs(entry.actions or {}) do
      if action.id == opts.action then
        found = action
        break
      end
    end
    if not found then
      return nil, "unknown action " .. tostring(opts.action)
    end
    exec = found.exec
    name = found.name
  end
  if not exec or exec == "" then
    return nil, "entry has no Exec"
  end

  local files = {}
  local uris = {}
  for _, file in ipairs(opts.files or {}) do
    table.insert(files, file)
    table.insert(uris, to_file_uri(file))
  end
  for _, uri in ipairs(opts.uris or {}) do
    table.insert(uris, uri)
    local path = to_path(uri)
    if path then
      table.insert(files, path)
    end
  end

  local tokens, err = tokenize_exec(exec)
  if not tokens then
    return nil, err
  end

  local context = { files = files, uris = uris, name = name, path = entry.path }
  local argv = {}
  for _, token in ipairs(tokens) do
    if token == "%f" then
      if files[1] then table.insert(argv, files[1]) end
    elseif token == "%F" then
      for _, file in ipairs(files) do table.insert(argv, file) end
    elseif token == "%u" then
      if uris[1] then table.insert(argv, uris[1]) end
    elseif token == "%U" then
      for _, uri in ipairs(uris) do table.insert(argv, uri) end
    elseif token == "%i" then
      if entry.icon then
        table.insert(argv, "--icon")
        table.insert(argv, entry.icon)
      end
    elseif token:match("^%%[dDnNvm]$") then
      -- Deprecated standalone codes drop out entirely.
    else
      table.insert(argv, expand_inline(token, context))
    end
  end
  if #argv == 0 then
    return nil, "Exec expanded to nothing"
  end
  return argv
end

-- PATH lookup by readability: Lua cannot test the executable bit, but a
-- readable file at the resolved path is close enough for TryExec's
-- "is this installed?" intent.
local function try_exec_ok(try_exec)
  if try_exec:find("/", 1, true) then
    return file_exists(try_exec)
  end
  for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
    if file_exists(dir .. "/" .. try_exec) then
      return true
    end
  end
  return false
end

-- D-Bus activation per the Application interface: the bus name is the
-- desktop id minus .desktop, the object path is the name with . and -
-- mapped to / and _.
local function dbus_activate(entry, opts, uris)
  local dbus = require("keywork.dbus")
  local bus = dbus.session()
  if not bus then
    return nil, "session bus unavailable"
  end
  local app_id = (entry.id or basename(entry.path)):gsub("%.desktop$", "")
  local object_path = "/" .. app_id:gsub("%-", "_"):gsub("%.", "/")
  local platform_data = dbus.array("{sv}", {})
  local call = {
    destination = app_id,
    path = object_path,
    interface = "org.freedesktop.Application",
    timeout_ms = opts.timeout_ms or 5000,
  }
  if opts.action then
    call.member = "ActivateAction"
    call.args = { opts.action, dbus.array("v", {}), platform_data }
  elseif #uris > 0 then
    call.member = "Open"
    call.args = { dbus.array("s", uris), platform_data }
  else
    call.member = "Activate"
    call.args = { platform_data }
  end
  local reply, err = bus:call(call)
  bus:close()
  if not reply then
    return nil, err or "activation failed"
  end
  return true
end

--- Launches an entry. Yieldable: call from a task. In order:
--- 1. TryExec, when present, must resolve or launch fails.
--- 2. DBusActivatable entries activate over the session bus
---    (Activate/Open/ActivateAction), falling back to Exec on error.
--- 3. Exec argv is built (opts.files/uris/action), wrapped for
---    Terminal=true entries (opts.terminal_argv or $TERMINAL -e), then
---    passed through opts.wrap(argv, entry) — the hook for detached or
---    scoped launchers (systemd-run and friends) — and spawned.
--- Returns the process handle (true for D-Bus activation), or nil, err.
function M.launch(entry, opts)
  opts = opts or {}
  assert(type(entry) == "table", "launch requires a parsed entry")

  if entry.try_exec and entry.try_exec ~= "" and not try_exec_ok(entry.try_exec) then
    return nil, "TryExec not found: " .. entry.try_exec
  end

  local uris = {}
  for _, file in ipairs(opts.files or {}) do
    table.insert(uris, to_file_uri(file))
  end
  for _, uri in ipairs(opts.uris or {}) do
    table.insert(uris, uri)
  end

  if entry.dbus_activatable and opts.dbus ~= false then
    local ok = dbus_activate(entry, opts, uris)
    if ok then
      return true
    end
    -- Activation failing (no bus, name not activatable) falls back to
    -- Exec, matching what desktop environments do.
  end

  local argv, err = M.exec_argv(entry, opts)
  if not argv then
    return nil, err
  end

  if entry.terminal then
    local terminal_argv = opts.terminal_argv
    if not terminal_argv then
      local terminal = os.getenv("TERMINAL")
      if not terminal or terminal == "" then
        return nil, "terminal entry but no terminal configured"
      end
      terminal_argv = { terminal, "-e" }
    end
    local wrapped = {}
    for _, arg in ipairs(terminal_argv) do table.insert(wrapped, arg) end
    for _, arg in ipairs(argv) do table.insert(wrapped, arg) end
    argv = wrapped
  end

  if opts.wrap then
    argv = opts.wrap(argv, entry)
    if not argv then
      return nil, "wrap returned no argv"
    end
  end

  local process = require("keywork.process")
  return process.spawn({ argv = argv })
end

return M
