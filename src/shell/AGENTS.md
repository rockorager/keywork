# AGENTS.md

The root repository guidance applies here. Keywork Shell is a Linux desktop
shell built on the Lua/Wayland application runtime in `../runtime/`.

This component is a demanding consumer and playground for runtime APIs. When
it exposes runtime pain or bugs, fix them in `../runtime/` rather than working
around them here.

The bar and launcher run in a single Keywork process using the multi-window API
(`kw.app({ windows = function(ctx) ... end })`). The shell owns
`dev.rockorager.keywork` on the session bus (`lua/shell/ipc.lua`); keybindings
toggle the launcher via `keywork-shell launcher` (dbus-send).

## Conventions

- Use Lua targeting LuaJIT and the Keywork runtime. Keep the `bin/` wrapper,
  `lua/shell/` modules, and shell-owned native helpers within this component.
- Theme via `kw.resolve_theme` / `context.theme`; no hardcoded colors outside a
  palette module (see `lua/shell/bar/colors.lua`).
- Root `build.zig` owns C module compilation, C/Wayland code generation, Lua
  checks, formatting, and installation. Do not add a component-local build
  graph or task runner.
- Run `zig build shell` from the repository root before finishing shell
  changes. It builds native modules and byte-compiles all Lua with `luajit -b`.
