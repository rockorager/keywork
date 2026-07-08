# Examples

## Zig

`zig/main.zig` exercises the toolkit core directly from Zig: it submits
typed `ui.Widget` trees, polls the context, and handles semantic events. It
is a substrate example, not the primary authoring story — Lua applications
on the keywork runtime are.

```sh
zig build run-zig-example
```

The example requires a running Wayland session.

## Lua

Lua examples land together with the `keywork` runtime binary. The intended
shape:

```sh
keywork bar.lua
```

with widgets as tables, handlers as plain Lua functions, and the platform
API (`kw.every`, `kw.task`, `kw.exec`, `kw.socket`) for everything around
the UI.
