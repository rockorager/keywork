local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")
local process = require("keywork.process")

local M = {}

local LOGIND = "org.freedesktop.login1"
local LOGIND_PATH = "/org/freedesktop/login1"
local LOGIND_MANAGER = "org.freedesktop.login1.Manager"
local LOCK_READY_TIMEOUT_MS = 4500

---@class SessionController
---@field lock_process?       keywork.process.Process
---@field lock_ready          boolean
---@field sleep_inhibitor?    keywork.dbus.UnixFd
---@field sleep_subscription? keywork.dbus.Subscription
---@field system_bus?         keywork.dbus.Bus
local Controller = {}
Controller.__index = Controller

function Controller:lock()
    if self.lock_process then
        return
    end

    local proc, err = process.spawn({
        argv = {
            "systemd-run",
            "--user",
            "--unit=keywork-shell-lock",
            "--collect",
            "--quiet",
            "--pipe",
            "--service-type=exec",
            "keywork-shell",
            "lock",
            "--foreground",
            "--ready",
        },
        stdout = "pipe",
    })
    if not proc then
        log.warn("lock screen failed to start", err or "unknown")
        return
    end

    self.lock_process = proc
    self.lock_ready = false

    loop.spawn(function()
        local output = ""
        for chunk in proc:stdout() do
            output = output .. chunk
            if output:find("ready\n", 1, true) then
                if self.lock_process == proc then
                    self.lock_ready = true
                    log.info("lock screen ready")
                end
                return
            end
            if #output > 64 then
                output = output:sub(-64)
            end
        end
    end)

    loop.spawn(function()
        local result = proc:wait()
        if self.lock_process == proc then
            self.lock_process = nil
            self.lock_ready = false
        end
        if result and not result.ok then
            log.warn("lock screen exited unsuccessfully")
        end
    end)
end

function Controller:acquire_sleep_inhibitor()
    local bus = self.system_bus
    if not bus then return end
    local reply, err = bus:call({
        destination = LOGIND,
        path = LOGIND_PATH,
        interface = LOGIND_MANAGER,
        member = "Inhibit",
        args = {
            "sleep",
            "keywork-shell",
            "Lock the session before sleeping",
            "delay",
        },
        timeout_ms = 1000,
    })
    local inhibitor = reply and reply.args and reply.args[1]
    if not inhibitor then
        log.warn("sleep lock inhibitor unavailable", err or "invalid logind reply")
        return
    end
    self.sleep_inhibitor = inhibitor
    log.info("sleep lock inhibitor acquired")
end

function Controller:release_sleep_inhibitor()
    if self.sleep_inhibitor then
        self.sleep_inhibitor:close()
        self.sleep_inhibitor = nil
    end
end

function Controller:prepare_for_sleep()
    self:lock()
    local waited = 0
    while not self.lock_ready and self.lock_process and waited < LOCK_READY_TIMEOUT_MS do
        loop.sleep(10)
        waited = waited + 10
    end
    if not self.lock_ready then
        log.warn("lock screen was not ready before sleep")
    end
    self:release_sleep_inhibitor()
end

function Controller:start_sleep_monitor()
    local ok, bus_or_err = pcall(function()
        return dbus.system()
    end)
    if not ok or not bus_or_err then
        log.warn("sleep locking disabled: system dbus unavailable")
        return
    end
    self.system_bus = bus_or_err

    local subscribed, subscription_or_err = pcall(function()
        return self.system_bus:subscribe({
            sender = LOGIND,
            path = LOGIND_PATH,
            interface = LOGIND_MANAGER,
            member = "PrepareForSleep",
        })
    end)
    if not subscribed or not subscription_or_err then
        log.warn("sleep locking disabled: logind subscription failed")
        return
    end
    self.sleep_subscription = subscription_or_err

    loop.spawn(function()
        self:acquire_sleep_inhibitor()
        for signal in self.sleep_subscription:events() do
            if signal.args[1] then
                self:prepare_for_sleep()
            else
                self:acquire_sleep_inhibitor()
            end
        end
    end)
end

function Controller:stop()
    self:release_sleep_inhibitor()
    if self.sleep_subscription then
        self.sleep_subscription:cancel()
        self.sleep_subscription = nil
    end
    if self.system_bus then
        self.system_bus:close()
        self.system_bus = nil
    end
end

function M.logout()
    local result, err = process.capture({ "keyworkctl", "quit" })
    if not result then
        return nil, err or "could not contact the compositor"
    end
    if not result.ok then
        return nil, result.stderr or "compositor rejected logout"
    end
    return true
end

function M.start()
    ---@type SessionController
    local controller = setmetatable({
        lock_process = nil,
        lock_ready = false,
        sleep_inhibitor = nil,
        sleep_subscription = nil,
        system_bus = nil,
    }, Controller)
    controller:start_sleep_monitor()
    return controller
end

return M
