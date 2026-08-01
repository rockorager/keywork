-- Canonical reactive primitives. This module is public only so the bundled
-- keywork module can be assembled without a native dependency cycle.
local reactive = {}

local active_observer
local persisted_signals = setmetatable({}, { __mode = "k" })

local function pack(...)
    return { n = select("#", ...), ... }
end

local function weak_set()
    return setmetatable({}, { __mode = "k" })
end

local function remove_dependencies(observer, dependencies)
    for source in pairs(dependencies) do
        source.subscribers[observer] = nil
    end
end

local function run_tracked(observer, fn, ...)
    local parent = active_observer
    local previous = observer.dependencies
    local pending = {}
    observer.pending = pending
    active_observer = observer
    local results = pack(pcall(fn, ...))
    active_observer = parent
    observer.pending = nil
    if not results[1] then
        error(results[2], 0)
    end
    if observer.accumulate then
        for source in pairs(pending) do
            if not previous[source] then
                previous[source] = true
                source.subscribers[observer] = true
            end
        end
        observer.dependencies = previous
    else
        remove_dependencies(observer, previous)
        observer.dependencies = pending
        for source in pairs(pending) do
            source.subscribers[observer] = true
        end
    end
    return unpack(results, 2, results.n)
end

local function track(source)
    if active_observer then
        active_observer.pending[source] = true
    end
end

local function assert_writable()
    if active_observer then
        error("signals cannot be written during reactive evaluation", 3)
    end
end

local function publish(source)
    local pending = {}
    for observer in pairs(source.subscribers) do
        pending[#pending + 1] = observer
    end
    for _, observer in ipairs(pending) do
        if source.subscribers[observer] then observer:notify() end
    end
end

local signal_methods = {}
local signal_mt = {
    __index = signal_methods,
    __call = function(self)
        track(self)
        return self._value
    end,
}

function signal_methods:set(value)
    assert_writable()
    if self.equals(self._value, value) then return end
    self._value = value
    if self.on_write then self.on_write(value) end
    publish(self)
end

function signal_methods:update(fn)
    assert_writable()
    if type(fn) ~= "function" then error("signal update expects a function", 2) end
    self:set(fn(self._value))
end

function signal_methods:mutate(fn)
    assert_writable()
    if type(fn) ~= "function" then error("signal mutate expects a function", 2) end
    fn(self._value)
    if self.on_write then self.on_write(self._value) end
    publish(self)
end

local readonly_mt = {
    __call = function(self)
        return self.source()
    end,
}

function signal_methods:readonly()
    local value = self.readonly_view
    if value then return value end
    value = setmetatable({ source = self }, readonly_mt)
    self.readonly_view = value
    return value
end

function reactive.signal(value, options)
    options = options or {}
    if type(options) ~= "table" then error("signal options must be a table", 2) end
    local equals = options.equals or rawequal
    if type(equals) ~= "function" then error("signal equals must be a function", 2) end
    return setmetatable({
        _value = value,
        equals = equals,
        on_write = options.__on_write,
        subscribers = weak_set(),
    }, signal_mt)
end

function reactive.persisted(holder)
    local existing = persisted_signals[holder]
    if existing then return existing end
    local value = reactive.signal(holder.value, {
        __on_write = function(next_value)
            holder.value = next_value
        end,
    })
    persisted_signals[holder] = value
    return value
end

local computed_mt = {
    __call = function(self)
        if self.evaluating then error("recursive computed read", 2) end
        if self.dirty then
            self.evaluating = true
            local ok, value = pcall(run_tracked, self, self.fn)
            self.evaluating = false
            if not ok then error(value, 0) end
            self.value = value
            self.dirty = false
        end
        track(self)
        return self.value
    end,
}

function reactive.computed(fn)
    if type(fn) ~= "function" then error("computed expects a function", 2) end
    local result = {
        fn = fn,
        dirty = true,
        evaluating = false,
        dependencies = {},
        subscribers = weak_set(),
    }
    function result:notify()
        if self.dirty then return end
        self.dirty = true
        publish(self)
    end
    return setmetatable(result, computed_mt)
end

local function new_component_observer(invalidate)
    local observer = { dependencies = {}, dirty = false, alive = true }
    function observer:notify()
        if not self.alive or self.dirty then return end
        self.dirty = true
        invalidate()
    end
    return observer
end

local function dispose_observer(observer)
    if not observer then return end
    observer.alive = false
    remove_dependencies(observer, observer.dependencies)
    observer.dependencies = {}
end

-- Deferred widget builders have their own dynamic dependency sets, but dirty
-- the retained component that declared them. Ordinary callbacks are untouched.
function reactive.wrap_deferred(fn, accumulate)
    if type(fn) ~= "function" or not active_observer or not active_observer.component_invalidate then
        return fn
    end
    local observer = new_component_observer(active_observer.component_invalidate)
    observer.component_invalidate = active_observer.component_invalidate
    observer.accumulate = accumulate == true
    return function(...)
        local results = pack(pcall(run_tracked, observer, fn, ...))
        observer.dirty = false
        if not results[1] then error(results[2], 0) end
        return unpack(results, 2, results.n)
    end
end

local function wrap_root(fn, invalidate)
    local observer = new_component_observer(invalidate)
    observer.component_invalidate = function() observer:notify() end
    return function(...)
        local results = pack(pcall(run_tracked, observer, fn, ...))
        observer.dirty = false
        if not results[1] then error(results[2], 0) end
        return unpack(results, 2, results.n)
    end
end

function reactive.install_app(app)
    if rawget(app, "__reactive_installed") then return end
    rawset(app, "__reactive_installed", true)

    local mt = getmetatable(app)
    local native_call = mt.__call
    mt.__call = function(_, options)
        if options and type(options.windows) == "function" then
            options.windows = wrap_root(options.windows, app.__reconcile)
        end
        return native_call(app, options)
    end

    app.hot.signal = function(key, initial, options)
        options = options or {}
        if type(options) ~= "table" then error("hot signal options must be a table", 2) end
        local state_options = {
            version = options.version,
            init = function()
                return { __signal = true, value = initial }
            end,
        }
        if options.migrate then
            if type(options.migrate) ~= "function" then error("hot signal migrate must be a function", 2) end
            state_options.migrate = function(previous, previous_version)
                -- The marker lets an application migrate directly from a
                -- legacy hot.state value on the first signal-backed version.
                local previous_value = previous
                if type(previous) == "table" and previous.__signal then
                    previous_value = previous.value
                end
                return { __signal = true, value = options.migrate(previous_value, previous_version) }
            end
        end
        return reactive.persisted(app.hot.state(key, state_options))
    end
end

function reactive.component(native_stateful, spec, source)
    local user_build = spec.build
    if type(user_build) ~= "function" then error("component build must be a function", 2) end
    local user_dispose = spec.dispose
    local wrapped = setmetatable({}, { __index = spec })
    wrapped.build = function(self, context)
        local observer = rawget(self, "__reactive_observer")
        if not observer then
            local function invalidate() self:__invalidate() end
            observer = new_component_observer(invalidate)
            observer.component_invalidate = function() observer:notify() end
            rawset(self, "__reactive_observer", observer)
        end
        local results = pack(pcall(run_tracked, observer, user_build, self, context))
        observer.dirty = false
        if not results[1] then error(results[2], 0) end
        return unpack(results, 2, results.n)
    end
    wrapped.dispose = function(self)
        dispose_observer(rawget(self, "__reactive_observer"))
        rawset(self, "__reactive_observer", nil)
        if user_dispose then return user_dispose(self) end
    end
    return native_stateful(wrapped, source)
end

return reactive
