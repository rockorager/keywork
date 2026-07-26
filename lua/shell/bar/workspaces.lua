local kw = require("keywork")
local log = require("keywork.log")
local loop = require("keywork.loop")
local service = require("keywork.service")
local wayland = require("shell.wayland")
local util = require("shell.bar.util")

local label = util.label

---@class WorkspaceSnapshot
---@field workspaces shell.wayland.Workspace[]
---@field connected  boolean
---@field loading?   boolean
---@field activate?  fun(id: number)

---@param list   shell.wayland.Workspace[]
---@param client shell.wayland.WorkspaceClient
---@return WorkspaceSnapshot
local function snapshot(list, client)
    return {
        workspaces = list,
        connected = true,
        activate = function(id)
            local ok, err = client:activate(id)
            if not ok then
                log.warn("workspace activation failed", err or "unknown")
            end
        end,
    }
end

---@type keywork.service.Service<WorkspaceSnapshot>
local workspace_service = service.define("shell.bar.workspaces", function(self)
    local client, connect_err = wayland.connect_workspaces()
    if not client then
        log.warn("workspace switcher disabled", connect_err or "Wayland unavailable")
        self:publish({ workspaces = {}, connected = false })
        return
    end

    local fd = client:fd()
    if not fd then
        client:close()
        log.warn("workspace switcher disabled", "Wayland connection has no file descriptor")
        self:publish({ workspaces = {}, connected = false })
        return
    end

    local fd_watch = loop.fd(fd, { read = true })
    local closed = false
    local function close()
        if closed then
            return
        end
        closed = true
        fd_watch:cancel()
        client:close()
    end
    self.scope:on_cancel(close)

    local initial, snapshot_err = client:snapshot()
    if not initial then
        log.warn("workspace switcher disabled", snapshot_err or "could not read workspace state")
        close()
        self:publish({ workspaces = {}, connected = false })
        return
    end
    self:publish(snapshot(initial, client))

    for event in fd_watch:events() do
        if event.err or event.hup then
            log.warn("workspace switcher disconnected from Wayland")
            break
        end
        if event.read then
            local updated, dispatch_err = client:dispatch()
            if dispatch_err then
                log.warn("workspace switcher dispatch failed", dispatch_err)
                break
            end
            if updated then
                self:publish(snapshot(updated, client))
            end
        end
    end
    close()
    self:publish({ workspaces = {}, connected = false })
end)

local function belongs_to_output(workspace, output)
    if not output then
        return true
    end
    for _, name in ipairs(workspace.outputs or {}) do
        if name == output then
            return true
        end
    end
    return false
end

local function workspace_less(left, right)
    local left_number = tonumber(left.name:match("^%d+"))
    local right_number = tonumber(right.name:match("^%d+"))
    if left_number and right_number and left_number ~= right_number then
        return left_number < right_number
    elseif left_number and not right_number then
        return true
    elseif right_number and not left_number then
        return false
    end
    return left.name < right.name
end

local function WorkspaceSwitcher(props)
    local palette = props.colors
    local state = props.state
    local visible = {}
    for _, workspace in ipairs(state.workspaces or {}) do
        if not workspace.hidden and belongs_to_output(workspace, props.output) then
            visible[#visible + 1] = workspace
        end
    end
    table.sort(visible, workspace_less)

    local items = {}
    for _, workspace in ipairs(visible) do
        local on_activate = nil
        if workspace.can_activate and state.activate then
            local id = workspace.id
            on_activate = function()
                state.activate(id)
            end
        end
        items[#items + 1] = kw.toggle_button({
            id = "workspace-" .. workspace.id,
            label = workspace.name,
            selected = workspace.active,
            size = "medium",
            appearance = "subtle",
            tone = workspace.urgent and "danger" or nil,
            on_activate = on_activate,
        })
    end

    if #items == 0 then
        local message = state.loading and "loading workspaces" or state.connected and "no workspaces"
            or "workspaces unavailable"
        items[1] = label(message, palette.muted)
    end
    return kw.row({ spacing = palette.space[1], children = items })
end

local Workspaces = kw.stateful({
    init = function(self)
        self.workspace_state = workspace_service:use(self.scope, function(next_snapshot)
            self.workspace_state = next_snapshot
            self:set_state()
        end)
            or { workspaces = {}, connected = true, loading = true }
    end,

    build = function(self)
        return WorkspaceSwitcher({
            colors = self.props.colors,
            output = self.props.output,
            state = self.workspace_state,
        })
    end,
})

return {
    Switcher = WorkspaceSwitcher,
    Workspaces = Workspaces,
}
