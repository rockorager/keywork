# Keywork Vision

Keywork is a native Zig application and UI platform for Wayland. LuaJIT is its
first high-level application host, not a requirement of the UI engine or event
loop.

Applications may be native Zig programs or Lua scripts (`keywork <script.lua>`)
running on the same retained widget tree and Vulkan or CPU rendering backends.
The platform should scale from status bars and layer-shell overlays to full
desktop applications without forcing native applications through Lua.

Beyond the UI engine, Keywork provides an asynchronous runtime and standard
library for application code: common utilities desktop applications need —
D-Bus, PipeWire, XDG integration, processes, timers, robust client-side
networking — built on the same event loop that drives the UI.

## Principles

1. **Low resource usage, high performance.** The native engine does the
   heavy lifting — layout, painting, text shaping, compositing. Lua-hosted
   applications declare structure and handle events while native applications
   use the same engine directly. Minimize language-boundary crossings; idle
   applications cost nothing.

2. **Flutter-like vocabulary and model.** Composable widgets, explicit
   constraint-based layout, themes. Rows, columns, padding — not a
   CSS/HTML-style system.

3. **Wayland only.** No X11, no cross-platform abstraction layer. Wayland
   concepts (layer-shell, xdg-toplevel, fractional scaling) are exposed
   directly rather than hidden behind portability shims.

4. **Faithful to Linux desktop standards.** XDG base directories, icon
   themes, desktop entries, D-Bus, portals. Keywork applications behave like
   first-class citizens of the Linux desktop, not a parallel ecosystem.
