# Examples

This directory contains only supported examples for the current libkeywork
API. Both are built by `zig build test` and use the host-owned event-loop
model.

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

The earlier Node/N-API and embedded-Lua programs targeted the pre-rewrite API
and are intentionally not retained as examples. A future Node binding should
live under `bindings/node/` and get its own example once it targets the stable
document and event APIs.
