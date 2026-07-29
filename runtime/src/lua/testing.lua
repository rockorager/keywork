-- Test declaration, lifecycle hooks, and assertions for `keywork test`.

local M = {}

local root = {
    before_each = {},
    after_each = {},
}
local current = root
local cases = {}
local case_names = {}
local failure_metatable = {}

local Context = {}
Context.__index = Context

local function check_name(name, operation)
    if type(name) ~= "string" or name == "" then
        error(operation .. " requires a non-empty name", 3)
    end
end

local function check_function(fn, operation)
    if type(fn) ~= "function" then
        error(operation .. " requires a function", 3)
    end
end

local function full_name(suite, name)
    local parts = { name }
    while suite and suite.name do
        table.insert(parts, 1, suite.name)
        suite = suite.parent
    end
    return table.concat(parts, " > ")
end

local function register_case(name, fn, skipped, reason)
    check_name(name, skipped and "skip" or "case")
    if not skipped then
        check_function(fn, "case")
    end

    local qualified = full_name(current, name)
    if case_names[qualified] then
        error("duplicate test case '" .. qualified .. "'", 3)
    end
    case_names[qualified] = true
    cases[#cases + 1] = {
        name = qualified,
        fn = fn,
        suite = current,
        skipped = skipped,
        reason = reason,
    }
end

function M.describe(name, body)
    check_name(name, "describe")
    check_function(body, "describe")

    local parent = current
    current = {
        name = name,
        parent = parent,
        before_each = {},
        after_each = {},
    }
    local ok, err = pcall(body)
    current = parent
    if not ok then
        error(err, 0)
    end
end

function M.case(name, body)
    register_case(name, body, false, nil)
end

function M.skip(name, reason)
    if reason ~= nil and type(reason) ~= "string" then
        error("skip reason must be a string", 2)
    end
    register_case(name, nil, true, reason or "skipped")
end

function M.before_each(fn)
    check_function(fn, "before_each")
    current.before_each[#current.before_each + 1] = fn
end

function M.after_each(fn)
    check_function(fn, "after_each")
    current.after_each[#current.after_each + 1] = fn
end

local type_order = {
    number = 1,
    string = 2,
    boolean = 3,
    table = 4,
    ["function"] = 5,
    userdata = 6,
    thread = 7,
}

local function sorted_keys(value)
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        local left_type = type(left)
        local right_type = type(right)
        local left_order = type_order[left_type] or 100
        local right_order = type_order[right_type] or 100
        if left_order ~= right_order then
            return left_order < right_order
        end
        if left_type == "number" or left_type == "string" then
            return left < right
        end
        return tostring(left) < tostring(right)
    end)
    return keys
end

local function format_value(value, seen)
    local value_type = type(value)
    if value_type == "string" then
        return string.format("%q", value)
    end
    if value_type ~= "table" then
        return tostring(value)
    end

    seen = seen or {}
    if seen[value] then
        return "<cycle>"
    end
    seen[value] = true

    local fields = {}
    for _, key in ipairs(sorted_keys(value)) do
        fields[#fields + 1] = "[" .. format_value(key, seen) .. "] = " .. format_value(value[key], seen)
    end
    seen[value] = nil
    return "{ " .. table.concat(fields, ", ") .. " }"
end

local function key_path(path, key)
    if type(key) == "string" and string.match(key, "^[%a_][%w_]*$") then
        return path .. "." .. key
    end
    return path .. "[" .. format_value(key) .. "]"
end

local function compare_values(actual, expected, path, seen_actual, seen_expected)
    local actual_type = type(actual)
    local expected_type = type(expected)
    if actual_type ~= expected_type then
        return false, path, "expected type " .. expected_type .. ", got " .. actual_type
    end
    if actual_type ~= "table" then
        if actual == expected then
            return true
        end
        return false, path, "values differ"
    end

    local previous_expected = seen_actual[actual]
    local previous_actual = seen_expected[expected]
    if previous_expected or previous_actual then
        if previous_expected == expected and previous_actual == actual then
            return true
        end
        return false, path, "table cycles differ"
    end
    seen_actual[actual] = expected
    seen_expected[expected] = actual

    for _, key in ipairs(sorted_keys(actual)) do
        if rawget(expected, key) == nil then
            return false, key_path(path, key), "unexpected key"
        end
        local equal, mismatch_path, reason = compare_values(
            actual[key],
            expected[key],
            key_path(path, key),
            seen_actual,
            seen_expected
        )
        if not equal then
            return false, mismatch_path, reason
        end
    end
    for _, key in ipairs(sorted_keys(expected)) do
        if rawget(actual, key) == nil then
            return false, key_path(path, key), "missing key"
        end
    end
    return true
end

local function values_equal(actual, expected)
    return compare_values(actual, expected, "$", {}, {})
end

local function raise_failure(message)
    error(setmetatable({ message = tostring(message) }, failure_metatable), 0)
end

function Context:defer(fn)
    check_function(fn, "defer")
    self._defers[#self._defers + 1] = fn
end

function Context:fail(message)
    raise_failure(message or "test failed")
end

function Context:equal(actual, expected)
    local equal, path, reason = values_equal(actual, expected)
    if equal then
        return
    end
    raise_failure(
        string.format(
            "%s at %s\nexpected: %s\nactual:   %s",
            reason,
            path,
            format_value(expected),
            format_value(actual)
        )
    )
end

function Context:same(actual, expected)
    if rawequal(actual, expected) then
        return
    end
    raise_failure(
        "expected identical values\nexpected: " .. format_value(expected) .. "\nactual:   " .. format_value(actual)
    )
end

function Context:truthy(value)
    if value then
        return
    end
    raise_failure("expected a truthy value, got " .. format_value(value))
end

function Context:falsy(value)
    if not value then
        return
    end
    raise_failure("expected a falsy value, got " .. format_value(value))
end

function Context:is_nil(value)
    if value == nil then
        return
    end
    raise_failure("expected nil, got " .. format_value(value))
end

function Context:type(value, expected)
    if type(value) == expected then
        return
    end
    raise_failure("expected type " .. tostring(expected) .. ", got " .. type(value))
end

function Context:contains(value, expected)
    if type(value) == "string" and type(expected) == "string" then
        if string.find(value, expected, 1, true) then
            return
        end
    elseif type(value) == "table" then
        for _, item in pairs(value) do
            if values_equal(item, expected) then
                return
            end
        end
    end
    raise_failure(format_value(value) .. " does not contain " .. format_value(expected))
end

function Context:matches(value, pattern)
    if type(value) ~= "string" or type(pattern) ~= "string" then
        raise_failure("matches requires a string value and pattern")
    end
    if string.match(value, pattern) then
        return
    end
    raise_failure(format_value(value) .. " does not match " .. format_value(pattern))
end

function Context:near(actual, expected, tolerance)
    if type(actual) ~= "number" or type(expected) ~= "number" or type(tolerance) ~= "number" then
        raise_failure("near requires numeric actual, expected, and tolerance values")
    end
    if tolerance < 0 then
        raise_failure("near tolerance must be non-negative")
    end
    if math.abs(actual - expected) <= tolerance then
        return
    end
    raise_failure(
        string.format("expected %s within %s of %s", tostring(actual), tostring(tolerance), tostring(expected))
    )
end

function Context:raises(fn, expected_message)
    check_function(fn, "raises")
    if expected_message ~= nil and type(expected_message) ~= "string" then
        raise_failure("raises expected message must be a string")
    end
    local ok, err = pcall(fn)
    if ok then
        raise_failure("expected function to raise")
    end
    if expected_message == nil then
        return
    end
    local message = type(err) == "table" and err.message or tostring(err)
    if not string.find(message or "", expected_message, 1, true) then
        raise_failure(
            "expected error containing " .. format_value(expected_message) .. ", got " .. format_value(message)
        )
    end
end

local function clean_traceback(message)
    local lines = { message, "stack traceback:" }
    local traceback = debug.traceback("", 2)
    for line in string.gmatch(traceback, "[^\n]+") do
        local framework_line = string.find(line, "keywork/testing.lua", 1, true)
        local protected_call_line = string.find(line, "in function 'xpcall'", 1, true)
        local raise_line = string.find(line, "in function 'error'", 1, true)
        if line ~= "stack traceback:" and not framework_line and not protected_call_line and not raise_line then
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, "\n")
end

local function capture_error(err)
    local is_failure = type(err) == "table" and getmetatable(err) == failure_metatable
    local message = is_failure and err.message or tostring(err)
    return {
        status = is_failure and "fail" or "error",
        message = clean_traceback(message),
    }
end

local function protected_call(fn, context)
    local ok, result = xpcall(function()
        fn(context)
    end, capture_error)
    if ok then
        return nil
    end
    return result
end

local function append_issue(primary, issue, phase)
    if not issue then
        return primary
    end
    if not primary then
        return issue
    end
    if issue.status == "error" then
        primary.status = "error"
    end
    primary.message = primary.message .. "\n" .. phase .. ":\n" .. issue.message
    return primary
end

local function suite_chain(suite)
    local chain = {}
    while suite do
        table.insert(chain, 1, suite)
        suite = suite.parent
    end
    return chain
end

local function run_case(case)
    local context = setmetatable({ _defers = {} }, Context)
    local chain = suite_chain(case.suite)
    local issue

    for _, suite in ipairs(chain) do
        for _, hook in ipairs(suite.before_each) do
            issue = protected_call(hook, context)
            if issue then
                break
            end
        end
        if issue then
            break
        end
    end

    if not issue then
        issue = protected_call(case.fn, context)
    end

    for index = #context._defers, 1, -1 do
        issue = append_issue(issue, protected_call(context._defers[index], context), "deferred cleanup failed")
    end
    for suite_index = #chain, 1, -1 do
        local hooks = chain[suite_index].after_each
        for hook_index = #hooks, 1, -1 do
            issue = append_issue(issue, protected_call(hooks[hook_index], context), "after_each failed")
        end
    end

    if issue then
        return {
            name = case.name,
            status = issue.status,
            message = issue.message,
        }
    end
    return {
        name = case.name,
        status = "pass",
    }
end

function M._run(filter)
    if filter ~= nil and type(filter) ~= "string" then
        error("test filter must be a string", 2)
    end

    local results = {}
    for _, case in ipairs(cases) do
        if filter == nil or string.find(case.name, filter, 1, true) then
            if case.skipped then
                results[#results + 1] = {
                    name = case.name,
                    status = "skip",
                    message = case.reason,
                }
            else
                results[#results + 1] = run_case(case)
            end
        end
    end
    return results
end

return M
