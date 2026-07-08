# Architecture

Keywork is a single process with three layers: a Lua application on top, the
runtime in the middle, and the toolkit core underneath. The runtime owns the
process event loop; the application owns state and describes UI; the toolkit
owns everything between a widget tree and pixels.

```text
╭──────────────────────────────────────────────────────────╮
│ Lua application                                          │
│ state, widget tables, handler functions, tasks           │
╰───────────────┬──────────────────────────▲───────────────╯
                │ widget tables            │ handler calls, task resumes
╭───────────────▼──────────────────────────┴───────────────╮
│ Runtime (keywork binary)                                 │
│ embedded LuaJIT, event loop, scheduler, platform API     │
├──────────────────────────────────────────────────────────┤
│ Toolkit core (Zig module)                                │
│ widgets, reconciliation, layout, input, rendering        │
├──────────────────────────────────────────────────────────┤
│ Platform                                                 │
│ epoll, timerfd, pidfd, inotify, Wayland, layer-shell,    │
│ portal D-Bus, Vulkan/SHM                                 │
╰──────────────────────────────────────────────────────────╯
```

## The event loop

There is exactly one loop, owned by the runtime. It is an epoll set into
which every subsystem registers sources: Wayland display fds, toolkit
timers, D-Bus watches and timeouts, and the Lua platform primitives
(timerfd timers, pidfd subprocesses, sockets, signalfd, inotify). Nothing in
the process blocks anywhere else.

The scheduler on top of the loop is frame-aware. Surface invalidation is
coalesced: any number of state changes and handler calls within one loop
iteration produce at most one rebuild and one submission per surface per
frame. Timers may be coalesced toward the next Wayland frame callback, and
idle work runs only when no frame is pending.

## Lua boundary

Lua runs only at loop iteration boundaries — never inside Wayland dispatch,
layout, or paint. The toolkit emits semantic events (activations, focus
changes, text edits) into a queue during dispatch; the runtime drains the
queue afterward and calls the corresponding Lua functions. This keeps the
VM off the native dispatch stack and makes reentrancy into mid-mutation
toolkit state impossible.

Widget trees flow the other way. The application returns plain Lua tables;
the runtime walks them once into typed `ui.Widget` values allocated in an
arena and hands the arena to the surface. Handler slots in widget tables
hold Lua functions; the runtime pins each with `luaL_ref` and stores the
ref as the widget's opaque `u64` handler identity, scoped to the submitted
document. The toolkit core never sees Lua.

## Tasks

`kw.task` wraps a Lua function in a coroutine scheduled on the loop.
Platform IO primitives are "register interest, yield, resume with result":
a task calling `sock:recv()` suspends until the loop marks the fd readable.
Because LuaJIT coroutines are stackful there is no function coloring — any
function called from a task may perform IO. Task handles are awaitable
(`task:await()`, `kw.all`, `kw.race`) and every yield point is a
cancellation point; the loop owns cleanup of pending registrations when a
task is cancelled.

## Toolkit core

The core is a Zig module with no knowledge of Lua or the loop's platform
API.

A `Context` owns Wayland protocol state, the image resource store, the XDG
icon-theme cache, and the portal settings connection. A `Surface` belongs
to a context and holds the installed document. Contexts register their fd
sources into the runtime's loop; they do not own a loop of their own.

Submission installs a complete widget tree. Reconciliation retains an
element tree matched by widget type and optional sibling key; elements own
interaction state (scroll offsets, text input state, focus) and retained
render objects. Layout updates a retained render tree; painting produces a
display list with damage rectangles.

Semantic widgets resolve presentation in the core. A button document record
carries content and behavior, not colors: background, hover, pressed,
focused, and disabled presentation derive from the active `Theme`, which
follows the desktop color-scheme preference. A portal appearance change
restyles installed documents without application involvement. Low-level
primitives (container, gesture detector) remain for intentional explicit
styling.

Image resources are uploaded explicitly (RGBA8/A8), copied into a
context-owned store, and addressed by nonzero context-local IDs; documents
retain their resources while installed. Named icons resolve through the
per-context XDG theme cache; SVG and PNG decoding use pinned NanoSVG and
stb sources compiled in.

## Rendering backends

Surface creation defaults to `auto`: Vulkan when the loader, device,
presentation support, and swapchain requirements are available, otherwise a
fresh Wayland SHM backend. Explicit `vulkan` selection does not fall back,
keeping failures observable. Both backends consume the same display list
and register their fds in the same loop.

## Repository layout

- `src/keywork.zig`: toolkit core public exports
- `src/context.zig`: context/surface lifecycle
- `src/ui.zig`: canonical widget model helpers
- `src/document.zig`: widget tree ownership and validation
- `src/core.zig`: layout, element/render trees, painting, hit testing
- `src/runtime.zig`: per-surface toolkit state and input orchestration
- `src/loop.zig`: epoll and timer machinery
- `src/appearance.zig`, `src/desktop_settings.zig`, `src/dbus_adapter.zig`:
  desktop appearance via the XDG Settings portal over libdbus
- `src/resources.zig`, `src/icon_theme.zig`, `src/icon_render.zig`,
  `src/image_render.zig`: images and icons
- `src/wayland_shm.zig`, `src/wayland_vulkan.zig`, `src/wayland_input.zig`:
  Wayland backends and input
- `src/text_renderer.zig`: shaping and text rasterization
- `examples/`: Zig substrate example; Lua examples arrive with the runtime

Planned as the runtime lands: `src/runtime/` (main binary, embedded LuaJIT,
`kw` module, loop ownership, scheduler, platform API) and vendored LuaJIT
built by `zig build`.

## Status

The toolkit core above is implemented. The runtime layer — the loop
inversion (contexts registering into a runtime-owned loop), the LuaJIT
embed, the `kw` module, tasks, and the platform API — is the current work.
This document describes the target design; where code and document
disagree, the document wins and the code is being moved toward it.
