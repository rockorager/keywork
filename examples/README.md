# Examples

This directory contains supported examples for the current libkeywork API.
The Zig and C examples are built by `zig build test`; all examples use the
host-owned event-loop model.

## Zig

`zig/main.zig` is the primary application-authoring example. It uses the
typed `keywork` Zig module, submits borrowed `ui.Widget` trees, polls the
context's aggregate fd, and handles semantic events.

```sh
zig build run-zig-example
```

## C

`c/main.c` is the binding-author example. It uses the stable C ABI and encodes
a Widget Schema v0 document before submission. Normal C applications are
expected to consume a higher-level binding rather than hand-encode documents.

```sh
zig build run-c-example
```

The Zig example explicitly uses the CPU-rendered Wayland SHM backend. The C
example uses the automatic renderer: Vulkan when available, with Wayland SHM
as the fallback. Both require a running Wayland session.

## LuaJIT

`lua/bar/main.lua` is a LuaJIT FFI binding exercise. It loads
`bindings/lua/keywork.lua`, owns its event loop with `luv` when available and
`poll(2)` otherwise, reads resolved theme colors from libkeywork, reads Sway
workspace state over the i3/Sway IPC Unix socket, encodes a bar document, and
submits it through the stable C ABI.

```sh
zig build
KEYWORK_LIBKEYWORK=$PWD/zig-out/lib/libkeywork.so \
LUA_PATH="$PWD/bindings/lua/?.lua;;" \
luajit examples/lua/bar/main.lua
```

The earlier Node/N-API and embedded-Lua programs targeted the pre-rewrite API
and are intentionally not retained as examples. A future Node binding should
live under `bindings/node/` and get its own example once it targets the stable
document and event APIs.
