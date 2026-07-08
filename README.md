# Keywork

Keywork is a native UI and rendering library for Wayland hosts. It is a
library, not an application runtime: the host owns application state, timers,
networking, child processes, application-specific D-Bus services, and the
blocking event loop.

Keywork owns:

- Wayland and layer-shell protocol state
- layout, rendering, hit testing, focus, and hover state
- input processing and toolkit-internal timers
- toolkit-relevant desktop integration, including portal appearance settings
- the currently submitted UI document
- context-local image resources and XDG icon-theme lookup caches
- automatic Vulkan rendering with a Wayland SHM fallback

The repository exposes two first-class interfaces:

- a typed Zig module rooted at `src/keywork.zig`
- a stable C ABI in `include/keywork.h`

Language bindings should build an ergonomic, typed tree in the host language,
encode that tree once per update, and call the C ABI. Application authors do
not need to see the wire representation.

## Event-loop contract

Each context exposes one stable aggregate file descriptor. A host watches it
for readability in its native event loop and then calls non-blocking
`dispatch`. Dispatch never calls host code; semantic events are read afterward
from the context queue.

```text
host state changes  -> submit a complete document
context fd readable -> dispatch
dispatch completes  -> drain handler/configured/closed/appearance events
handler event        -> update host state and submit again
```

There is no Keywork thread and no library-owned blocking loop.

## Rendering backends

Surface creation defaults to `auto`. Keywork dynamically loads the Vulkan
loader, checks for a graphics/present device and required swapchain
capabilities, and selects its Vulkan renderer when available. If that setup
fails, `auto` creates a fresh Wayland SHM backend instead. Hosts can explicitly
request Vulkan or SHM for diagnostics and controlled deployments; an explicit
Vulkan request returns the initialization error rather than falling back.

Backend selection is internal to the surface. Both paths consume the same
display list and preserve the same host fd/dispatch/event-queue contract.

## Desktop settings

Each context connects to the session bus through libdbus and observes
`org.freedesktop.portal.Settings`. The portal color-scheme preference is
available through `Context.colorScheme` and the C getter, automatically drives
default widget themes, and produces an `appearance_changed` semantic event.
The D-Bus connection, watches, and timeouts are all folded into the context's
single aggregate fd. If the session bus or portal is unavailable, context
creation still succeeds with `no_preference`.

Keywork owns D-Bus protocols that directly affect toolkit behavior. Arbitrary
application services and protocols such as StatusNotifierItem remain host
responsibilities.

## Images and icons

Hosts upload explicit image data with `Context.createImageRgba8` or
`Context.createAlphaMaskA8` (and the equivalent C ABI functions). Upload data
is borrowed for the call and copied into a context-owned resource store; IDs are
nonzero, context-local, and safe to release after submitted documents retain
them. Named `ui.icon` widgets use the context icon theme, defaulting to
`KEYWORK_ICON_THEME`, `GTK_ICON_THEME`, then `Adwaita`; `setIconTheme` clears
icon caches and invalidates surfaces. SVG icons are rasterized by NanoSVG; PNG
icons and image scaling use stb. Both are pinned, content-hashed GitHub source
dependencies compiled into libkeywork. Image support does not add GLib,
GObject, or GdkPixbuf dependencies.

See [Architecture](docs/architecture.md), [C API](include/keywork.h), and the
[widget schema](docs/widget-schema-v0.md).

## Build

```sh
zig build
zig build test
```

The build installs `libkeywork.a`, `libkeywork.so`, and `keywork.h`. Zig
consumers import the package's `keywork` module.

The maintained examples are indexed in [`examples/README.md`](examples/README.md):

```sh
zig build run-zig-example
zig build run-c-example
```

Both examples intentionally own their polling loops and application state.
