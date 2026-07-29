# AGENTS.md

keywork-shell is a Linux desktop shell built on [keywork](../keywork), a Lua/Wayland
app runtime under active development. This repo is a playground for keywork's APIs:
when we hit pain points or bugs, note them in NOTES.md and fix them in `../keywork`
rather than working around them here.

First target: a bar + launcher in a single keywork process, using the multi-window
API (`kw.app({ windows = function(ctx) ... end })`). The shell owns
`dev.rockorager.keywork` on the session bus (`lua/shell/ipc.lua`); keybindings
toggle the launcher via `keywork-shell launcher` (dbus-send).

## Conventions

- Lua (LuaJIT) targeting the keywork runtime; structure mirrors the sibling repos:
  `bin/` shell wrapper, `lua/shell/` modules, Makefile with `check` / `run` / `install`.
- Theme via `kw.resolve_theme` / `context.theme`; no hardcoded colors outside a
  palette module (see `lua/shell/bar/colors.lua`).
- `make check` byte-compiles all Lua with `luajit -b` — run it before finishing.
