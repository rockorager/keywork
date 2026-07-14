local keywork = require("keywork")

-- Minimal application for startup benchmarking: one box, one text run.
--
-- Quitting in `start` stops the event loop before its first turn: the first
-- frame is painted, committed, and flushed, but the process exits without
-- waiting for the compositor to acknowledge it. That measures pure engine
-- startup work with low variance:
--   hyperfine 'zig-out/bin/keywork examples/lua/bench-startup.lua'
return keywork.app({
    app_id = "dev.keywork.BenchStartup",
    backend = "cpu",
    width = 320,
    height = 120,
    start = function()
        keywork.app.quit()
    end,
    child = keywork.box(
        { background = 0xff111113 },
        keywork.padding({
            all = 8,
            child = keywork.text("startup benchmark", { color = 0xffedeef0 }),
        })
    ),
})
