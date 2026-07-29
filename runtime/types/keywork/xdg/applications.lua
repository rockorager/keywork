---@meta keywork.xdg.applications

---@class keywork.xdg.applications.Action
---@field id    string
---@field name  string
---@field icon? string
---@field exec? string

---@class keywork.xdg.applications.Entry
---@field path               string
---@field id                 string
---@field name               string
---@field generic_name?      string
---@field comment?           string
---@field icon?              string
---@field exec?              string
---@field try_exec?          string
---@field wd?                string
---@field terminal           boolean
---@field dbus_activatable   boolean
---@field no_display         boolean
---@field hidden             boolean
---@field single_main_window boolean
---@field startup_wm_class?  string
---@field keywords           string[]
---@field categories         string[]
---@field mime_types         string[]
---@field only_show_in       string[]
---@field not_show_in        string[]
---@field fields             table<string, string>
---@field actions            keywork.xdg.applications.Action[]

---@class keywork.xdg.applications.ParseOptions
---@field locale? string
---@field id?     string

---@class keywork.xdg.applications.SearchOptions
---@field dirs?   string[]
---@field locale? string

---@class keywork.xdg.applications.ExecOptions
---@field action? string
---@field files?  string[]
---@field uris?   string[]

---@class keywork.xdg.applications.LaunchOptions: keywork.xdg.applications.ExecOptions
---@field dbus?             boolean
---@field timeout_ms?       integer
---@field terminal_argv?    string[]
---@field wrap?             fun(argv: string[], entry: keywork.xdg.applications.Entry): string[]?
---@field activation_token? string

local M = {}

---@param path     string
---@param options? keywork.xdg.applications.ParseOptions
---@return keywork.xdg.applications.Entry? entry
---@return string? error
function M.parse(path, options) end

---@return string[]
function M.data_dirs() end

---@param desktop_id string
---@param options?   keywork.xdg.applications.SearchOptions
---@return keywork.xdg.applications.Entry? entry
---@return string? error
function M.lookup(desktop_id, options) end

---@param options? keywork.xdg.applications.SearchOptions
---@return keywork.xdg.applications.Entry[]
function M.list(options) end

---@param entry    keywork.xdg.applications.Entry
---@param options? keywork.xdg.applications.ExecOptions
---@return string[]? argv
---@return string? error
function M.exec_argv(entry, options) end

--- Launches an entry. Must be called from a loop task.
---@param entry    keywork.xdg.applications.Entry
---@param options? keywork.xdg.applications.LaunchOptions
---@return keywork.process.Process | true | nil process_or_activated
---@return string? error
function M.launch(entry, options) end

return M
