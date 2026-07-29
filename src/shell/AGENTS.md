# AGENTS.md

The root repository guidance applies here. Keywork Shell is a Linux desktop
shell built on the Lua/Wayland application runtime in `../runtime/`.

This component is a demanding consumer and playground for runtime APIs. When
it exposes runtime pain or bugs, record them in `NOTES.md` and fix them in
`../runtime/` rather than working around them here.

First target: a bar + launcher in a single keywork process, using the multi-window
API (`kw.app({ windows = function(ctx) ... end })`). The shell owns
`dev.rockorager.keywork` on the session bus (`lua/shell/ipc.lua`); keybindings
toggle the launcher via `keywork-shell launcher` (dbus-send).

## Conventions

- Use Lua targeting LuaJIT and the Keywork runtime. Keep the `bin/` wrapper,
  `lua/shell/` modules, and shell-owned native helpers within this component.
- Theme via `kw.resolve_theme` / `context.theme`; no hardcoded colors outside a
  palette module (see `lua/shell/bar/colors.lua`).
- `src/shell/Makefile` owns C module compilation and C/Wayland code generation;
  do not move those dependencies into the root task facade.
- Run `make check` from this directory before finishing shell changes. It
  builds native modules and byte-compiles all Lua with `luajit -b`.
