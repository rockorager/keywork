--- Combinators over chunk iterators (proc:stdout(), socket:chunks()).

local stream = {}

--- Wraps a chunk iterator into a line iterator: yields each
--- "\n"-terminated line without its newline, buffering partial lines
--- across chunk boundaries, and yields an unterminated trailing line once
--- the underlying stream ends. Use directly in a generic for:
--- `for line in stream.lines(proc:stdout()) do ... end`.
function stream.lines(next_fn, state)
  local buffer = ""
  local ended = false
  return function()
    while true do
      local newline = buffer:find("\n", 1, true)
      if newline then
        local line = buffer:sub(1, newline - 1)
        buffer = buffer:sub(newline + 1)
        return line
      end
      if ended then
        if buffer == "" then
          return nil
        end
        local tail = buffer
        buffer = ""
        return tail
      end
      local chunk = next_fn(state)
      if chunk == nil then
        ended = true
      else
        buffer = buffer .. chunk
      end
    end
  end
end

return stream
