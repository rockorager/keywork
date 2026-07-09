# Keywork Vision

Keywork is a runtime for building Wayland applications in Lua.

An application is a Lua script (`keywork <script.lua>`) running on a native
Zig engine: LuaJIT for application logic, a retained widget tree, and both
Vulkan and CPU rendering backends. From status bars and layer-shell overlays
to full desktop applications.

Beyond the UI engine, Keywork provides an asynchronous runtime and standard
library for application code: common utilities desktop applications need —
D-Bus, XDG integration, processes, timers, robust client-side networking —
built on the same event loop that drives the UI.

## Principles

1. **Low resource usage, high performance.** The native engine does the
   heavy lifting — layout, painting, text shaping, compositing. Lua declares
   structure and handles events. Minimize Lua↔native crossings; idle
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
