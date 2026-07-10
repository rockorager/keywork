--- Lua-level helpers layered over the native keywork.process primitives.
--- Loaded by the module loader with the native process table as its sole
--- argument; augments it in place.

local process = ...

--- Runs a command to completion and returns its wait() result table
--- augmented with collected `stdout` and `stderr` strings, or nil, err
--- when the spawn fails or the process is canceled. Accepts a plain argv
--- array or a spec table with `argv`. Must be called from a task; the
--- runtime buffers pipe output, so reading the two pipes sequentially
--- cannot deadlock.
function process.capture(spec)
  if spec.argv == nil then
    spec = { argv = spec }
  end
  local proc, err = process.spawn({
    argv = spec.argv,
    stdout = "pipe",
    stderr = "pipe",
  })
  if not proc then
    return nil, err
  end
  local stdout = {}
  for chunk in proc:stdout() do
    table.insert(stdout, chunk)
  end
  local stderr = {}
  for chunk in proc:stderr() do
    table.insert(stderr, chunk)
  end
  local result = proc:wait()
  if not result then
    return nil, "canceled"
  end
  result.stdout = table.concat(stdout)
  result.stderr = table.concat(stderr)
  return result
end
