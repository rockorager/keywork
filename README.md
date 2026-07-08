# Keywork

Keywork is a GUI runtime for building beautiful, performant Wayland desktop
UIs — bars, launchers, notification daemons, and full shells — scripted in
Lua. The core is written in Zig; applications are written in Lua running on
an embedded LuaJIT.

```lua
local kw = require("keywork")

local state = { time = os.date("%H:%M") }

kw.every("1s", function()
  state.time = os.date("%H:%M")
  kw.invalidate()
end)

kw.surface({ layer = "top", anchor = { "top", "left", "right" }, height = 32 }, function()
  return kw.row({ gap = 8 }, {
    kw.text(state.time),
    kw.spacer(),
    kw.button("quit", { on_click = function() kw.quit() end }),
  })
end)

kw.run()
```

The runtime owns the process: the event loop, Wayland and layer-shell
protocol state, layout, rendering, hit testing, focus, input, timers,
subprocesses, sockets, and desktop integration. Applications describe their
UI as plain Lua tables, attach Lua functions as handlers, and let the
runtime schedule everything else.

## Design

- **Widgets are tables, handlers are functions.** Every update, the
  application returns a complete widget tree. The toolkit reconciles it
  against retained element and render trees, so rebuilds are cheap and
  rendering is damage-driven.
- **One event loop, owned by the runtime.** A single epoll loop drives
  Wayland, D-Bus, timers, subprocesses, sockets, and file watches. The
  scheduler is frame-aware: timers coalesce toward frame callbacks and
  rebuilds are batched per frame.
- **Structured concurrency in Lua.** `kw.task` starts a coroutine-backed
  task; IO primitives yield instead of blocking, tasks are awaitable and
  cancellable at every yield point. No callback soup, no function coloring.
- **Lua never runs inside layout or paint.** The toolkit queues semantic
  events during dispatch and the runtime invokes Lua handlers only at loop
  iteration boundaries.
- **Semantics live in the toolkit.** Themed widgets (buttons, text fields)
  derive their presentation from the active theme, which follows the desktop
  color-scheme preference through the XDG Settings portal. A theme change
  restyles a running application without any Lua involvement.
- **Automatic rendering backend.** Vulkan when available, Wayland SHM
  otherwise. Both consume the same display list.

## Platform API

Lua applications get a small, Linux-native platform surface, all integrated
with the one loop:

- `kw.every` / `kw.after` — timers (timerfd)
- `kw.task` — coroutine tasks with `await`, `cancel`, `kw.all`, `kw.race`
- `kw.exec` — subprocesses with captured output (pidfd)
- `kw.socket` — unix sockets (compositor IPC, mpd, ...)
- `kw.watch` — file watching (inotify)
- signals, idle callbacks, and frame-aligned scheduling

## Zig

The toolkit core is an ordinary Zig module (`src/keywork.zig`): typed
widgets, contexts, and surfaces. The runtime is its first client; compiled
Zig applications can use it directly. There is no C ABI and no serialized
widget format — Lua tables are converted straight into typed widget trees
in-process.

## Status

The toolkit core (layout, rendering, input, theming, icons, images) is
functional; see `examples/zig`. The LuaJIT runtime — the `keywork` binary,
the `kw` module, and the platform API — is under construction. LuaJIT is
vendored and built from source by `zig build`; the only system dependencies
are Wayland, xkbcommon, fontconfig, freetype, harfbuzz, and dbus.

## Build

```sh
zig build
zig build test
zig build run-zig-example
```

See [Architecture](docs/architecture.md) and
[`examples/README.md`](examples/README.md).
