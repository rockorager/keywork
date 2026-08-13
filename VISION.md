# Keywork Vision

Keywork is a Lua application and UI platform for Wayland, powered by a native
Zig runtime. LuaJIT is the supported application language; the UI engine,
event loop, rendering, and platform integration remain native implementation
components.

Keywork aims to be **systemd for the desktop**: a coherent, Varlink-first
foundation for the runtime, service, integration, and UI facilities that
desktop applications otherwise assemble piecemeal.

Applications are Lua scripts (`keywork <script.lua>`) running on the retained
widget tree and Vulkan or CPU rendering backends. The platform should scale
from status bars and layer-shell overlays to full desktop applications while
providing one coherent lifecycle, state, and standard-library model.

Beyond the UI engine, Keywork provides an asynchronous runtime and standard
library for application code: common utilities desktop applications need —
Varlink-first service IPC, D-Bus compatibility, PipeWire, XDG integration,
processes, timers, robust client-side networking — built on the same event
loop that drives the UI.

Applications use `keywork.secrets` to look up, store, and delete credentials
through the standard freedesktop.org Secret Service API. Keywork remains
provider-neutral and does not introduce its own secret storage protocol.

## Principles

1. **Low resource usage, high performance.** The native engine does the
   heavy lifting — layout, painting, text shaping, compositing. Lua
   applications declare structure and handle events. Minimize
   language-boundary crossings; idle applications cost nothing.

2. **Flutter-like vocabulary and model.** Composable widgets, explicit
   constraint-based layout, themes. Rows, columns, padding — not a
   CSS/HTML-style system.

3. **Wayland only.** No X11, no cross-platform abstraction layer. Wayland
   concepts (layer-shell, xdg-toplevel, fractional scaling) are exposed
   directly rather than hidden behind portability shims.

4. **Varlink first, D-Bus compatible.** Every Keywork-owned service interface
   and IPC contract uses Varlink as its canonical API. D-Bus is a compatibility
   and interoperability layer for existing desktop services, never the model
   new Keywork interfaces are designed around.

5. **Faithful to Linux desktop standards.** XDG base directories, icon
   themes, desktop entries, D-Bus interoperability, portals. Keywork
   applications behave like first-class citizens of the Linux desktop, not a
   parallel ecosystem.

6. **One application API.** Lua is the supported, compatibility-conscious
   application surface. Native modules remain independently testable and keep
   typed boundaries for the Lua host and first-party infrastructure, but they
   are not a second application SDK. Native integrations should prefer
   focused Lua bindings, shared image buffers, or service protocols such as
   Varlink over bypassing the Lua application model.
