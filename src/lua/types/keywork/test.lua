---@meta keywork.test

--- Test declarations and assertions available only under `keywork test`.
--- Files register cases while loading; case bodies currently run
--- synchronously in registration order. Every file gets a fresh Lua VM.
--- Run `keywork test --help` for discovery and filtering options.
---@class keywork.test

---@class keywork.test.Context
local Context = {}

--- Registers cleanup for the current case. Deferred functions run in reverse
--- order after the body, including after assertions and unexpected errors.
---@param fn fun(context: keywork.test.Context)
function Context:defer(fn) end

--- Fails the current case immediately.
---@param message? string
function Context:fail(message) end

--- Compares recursively and reports the first mismatched path.
--- Arguments are actual, expected.
---@param actual   any
---@param expected any
function Context:equal(actual, expected) end

--- Compares with `rawequal`. Arguments are actual, expected.
---@param actual   any
---@param expected any
function Context:same(actual, expected) end

--- Requires a value other than false or nil.
---@param value any
function Context:truthy(value) end

--- Requires false or nil.
---@param value any
function Context:falsy(value) end

--- Requires nil.
---@param value any
function Context:is_nil(value) end

--- Requires Lua's `type(value)` to equal `expected`.
---@param value    any
---@param expected string
function Context:type(value, expected) end

--- Requires a plain substring or a structurally equal table value.
---@param value    string | table
---@param expected any
function Context:contains(value, expected) end

--- Requires `value` to match a Lua pattern.
---@param value   string
---@param pattern string
function Context:matches(value, pattern) end

--- Requires the absolute numeric difference to be at most `tolerance`.
---@param actual    number
---@param expected  number
---@param tolerance number
function Context:near(actual, expected, tolerance) end

--- Requires `fn` to raise. The optional message is matched as a plain substring.
---@param fn                fun()
---@param expected_message? string
function Context:raises(fn, expected_message) end

local M = {}

--- Groups cases and hooks under a name. Groups may be nested.
---@param name string
---@param body fun()
function M.describe(name, body) end

--- Registers one synchronous test case.
---@param name string
---@param body fun(context: keywork.test.Context)
function M.case(name, body) end

--- Registers a skipped case without running its hooks.
---@param name    string
---@param reason? string
function M.skip(name, reason) end

--- Runs before each case. Outer-group hooks run first.
---@param fn fun(context: keywork.test.Context)
function M.before_each(fn) end

--- Runs after each case, including failures. Inner-group hooks run first.
---@param fn fun(context: keywork.test.Context)
function M.after_each(fn) end

return M
