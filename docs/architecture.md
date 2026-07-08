# Architecture

## Public model

A `Context` is the unit integrated into a host event loop. It owns an internal
epoll set and exposes that epoll descriptor as one stable, readable fd. The set
contains Wayland display fds, a wake eventfd, and toolkit-internal timerfds.
Those subordinate descriptors are implementation details.

A `Surface` belongs to one context. A host submits a complete declarative
document to a surface. Submission is atomic from the caller's perspective:
Keywork copies or decodes the new document before replacing the old one. The
host may release its input buffers as soon as submission returns.

Image resources and icon-theme lookup are context-owned services, not global
runtime state. Uploaded RGBA8/A8 image data is copied into a private resource
store and addressed by nonzero context-local IDs. Documents retain resource
references while installed, so releasing host ownership does not invalidate an
already submitted tree. Named icons are resolved through a per-context XDG
theme cache; changing the theme clears that cache and invalidates all surfaces.
The selected SVG and PNG files are decoded with pinned NanoSVG and stb source
dependencies compiled into libkeywork, not a desktop-framework image loader.

Input handlers produce semantic events. In particular, a gesture detector widget
stores an integer handler ID, not a function pointer. Native dispatch appends
that ID and the installed document ID to the context event queue. Only after
dispatch returns does the binding invoke a host-language function from its own
per-document callback registry.

Toolkit-owned desktop protocols follow the same rule. A private libdbus
connection integrates all of its watches and timeouts into the context epoll
set. The XDG Settings portal currently supplies the system color-scheme
preference. Changes update default themes, invalidate surfaces, and enqueue an
`appearance_changed` event; D-Bus never invokes host callbacks directly.

This keeps JS, Lua, Go, and other runtimes off the native dispatch stack and
avoids reentrancy into host code.

## Boundaries

```text
┌──────────────────────────────────────────────────────────┐
│ Host / binding                                           │
│ state, callbacks, timers, sockets, application DBus, poll│
└───────────────┬───────────────────────────▲──────────────┘
                │ document / invalidate     │ event queue
┌───────────────▼───────────────────────────┴──────────────┐
│ Public Keywork API                                      │
│ Context, Surface, typed Zig widgets, versioned C document│
├──────────────────────────────────────────────────────────┤
│ Toolkit                                                 │
│ owned document, reconciliation, layout, input, rendering│
├──────────────────────────────────────────────────────────┤
│ Platform                                                │
│ epoll/timerfd/eventfd, Wayland, layer-shell, portal DBus │
└──────────────────────────────────────────────────────────┘
```

## Typed and encoded submissions

The Zig API accepts borrowed `keywork.ui.Widget` values. Widgets use slices and
child pointers and are pleasant to construct from native Zig. `Surface.submit`
validates and deep-copies the whole tree.

The C ABI accepts Widget Schema v0 bytes. It is the stable cross-language ABI,
not the intended application-authoring API. Official bindings should expose
typed builders and keep their encoder private.

Both paths produce the same canonical widget tree. Reconciliation retains an
internal element tree by widget type and optional sibling key; elements own
interaction state and retained render objects. Layout then updates a retained
render tree. There is no public `Node` model, callback-bearing compatibility
tree, or second widget engine.

Semantic toolkit widgets are resolved on the library side. For example, a
filled button document record carries content and behavior but not a hardcoded
surface palette: libkeywork derives its background, hover background,
pressed background, focus border, disabled presentation, foreground, padding,
and radius from the current `Theme`. A null handler marks a filled button disabled and
removes it from pointer activation and keyboard focus traversal. A portal
appearance change therefore restyles an installed document without requiring
every host binding to select and resubmit colors. Low-level primitives such as
container and gesture detector remain available when an application intentionally wants
explicit styling.

## Event-loop sequence

1. Create a context and one or more surfaces.
2. Watch `Context.eventFd()` or `keywork_context_event_fd()` for readability.
3. Submit a document. Submission wakes the aggregate fd when work is queued.
4. On readability, call `dispatch`. It is non-blocking and must be called from
   the same thread that owns the context.
5. Drain all context events.
6. Apply semantic events to host state and submit replacement documents.

Contexts and their surfaces are opaque, heap-stable handles owned by Keywork.
They are single-thread-affine; no public operation is currently thread-safe.

## Rendering backends

The default `auto` surface backend attempts Vulkan first and falls back to
Wayland SHM when the Vulkan loader, device, presentation support, required
extension, surface format, or swapchain usage is unavailable. The failed
Vulkan backend fully unwinds its independent Wayland/Vulkan state before the
SHM backend opens a new Wayland connection. Explicit `vulkan` selection does
not fall back, which keeps failures observable in tests and diagnostics.

Selection does not cross the public event-loop boundary: every Wayland
backend registers its display fd and toolkit timers in the context's aggregate
epoll set. Both renderers consume the same toolkit display list. Runtime GPU
or swapchain failures after a Vulkan surface has initialized are reported to
the host; automatic live migration of an existing surface is not supported.

## Repository layout

- `src/keywork.zig`: public Zig exports only
- `src/context.zig`: context/surface lifecycle and host-loop boundary
- `src/appearance.zig`: shared public desktop appearance values
- `src/dbus_adapter.zig`: libdbus watch/timeout integration
- `src/desktop_settings.zig`: XDG Settings portal client
- `src/ui.zig`: public aliases and helpers for the canonical widget model
- `src/document.zig`: widget ownership, validation, and Widget Schema decoder
- `src/resources.zig`: context-owned explicit RGBA8/A8 resource store
- `src/icon_theme.zig`: context-owned XDG icon-theme lookup/cache
- `src/icon_render.zig`: NanoSVG/stb icon decoding and rasterization
- `src/c_api.zig`: narrow C ABI adapter
- `src/event_loop.zig`: internal aggregate epoll and timer machinery
- `src/core.zig`: layout, element/render trees, painting, and hit testing
- `src/runtime.zig`: per-surface toolkit state and input orchestration
- `src/wayland_shm.zig`: Wayland/layer-shell CPU rendering backend
- `src/wayland_vulkan.zig`: Wayland/layer-shell Vulkan rendering backend
- `src/wayland_input.zig`: seat, pointer, keyboard, and repeat handling
- `src/text_renderer.zig`: shaping and text rasterization
- `include/keywork.h`: installed stable C header
- `docs/widget-schema-v0.md`: binding wire contract
- `examples/`: complete host-owned event-loop examples

Backend and internal toolkit modules are not public Zig API. Compatibility is
promised at `src/keywork.zig`, `include/keywork.h`, and versioned document
format boundaries only.
