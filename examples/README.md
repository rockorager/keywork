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

Lua applications run on the `keywork` runtime binary:

```sh
zig build
./zig-out/bin/keywork examples/lua/counter.lua
```

`lua/counter.lua` is the canonical example: widgets as plain tables,
handlers as Lua functions. The platform API (`kw.every`, `kw.task`,
`kw.exec`, `kw.socket`) lands next.
