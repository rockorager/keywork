# Keywork monorepo architecture

This document defines source ownership and allowed dependency directions. A
monorepo makes coordinated changes easier; it does not erase component
boundaries.

## Components

### Runtime (`runtime/`)

Owns the native Zig engine, LuaJIT integration, Lua-facing APIs, retained UI
model, rendering backends, asynchronous application services, runtime
resources, examples, and public Lua type information.

The runtime is a general Wayland application platform. It must not acquire
shell policy or compositor implementation details to make an individual
consumer easier to implement.

### Compositor (`compositor/`)

Owns the Wayland compositor, window-management policy, renderer integration,
the compositor Varlink interface and server, `keyworkctl`, and session assets
that start or configure the compositor.

Its control implementation is compositor-private. User-facing commands must
remain synchronized across configuration keybindings, Varlink declarations
and dispatch, and `keyworkctl` parsing and help.

### Shell (`shell/`)

Owns the Lua desktop experience: bar, launcher, lock screen, notifications,
backgrounds, OSD, shell D-Bus API, native C helpers, PAM policy, and shell
service assets.

The shell is a demanding consumer of the runtime's public API. Runtime defects
or missing abstractions found while developing the shell should be fixed in
the runtime rather than hidden behind shell-specific workarounds.

### Protocols (`protocols/`)

Owns byte-for-byte shared snapshots of external Wayland protocol XML and a
manifest recording source revision, hash, license, and whether each file is an
upstream snapshot or an adaptation.

Product-owned interfaces remain with their products. In particular, the
compositor Varlink interface is not shared protocol infrastructure. A protocol
used by only one component may also remain component-owned when elevating it
would obscure its ownership.

## Dependency directions

Arrows mean "depends on":

```diagram
┌─────────┐    public Lua/application API    ┌─────────┐
│  shell  │ ────────────────────────────────▶│ runtime │
└────┬────┘                                  └────┬────┘
     │                                            │
     │ shared protocol XML                        │ shared protocol XML
     │             ┌───────────┐                  │
     └────────────▶│ protocols │◀─────────────────┘
                   └─────▲─────┘
                         │ shared protocol XML
                   ┌─────┴──────┐
                   │ compositor │
                   └────────────┘
```

The compositor and runtime have no source-code dependency on each other. The
shell may rely on the runtime's public Lua/application contract, but it may not
reach into runtime implementation files. Session integration between the
compositor and shell is a deployed-process contract, not permission for source
imports between them.

There is intentionally no general-purpose `common/` directory. Shared code is
promoted only when it has a stable responsibility and a clear owner.

## Zig module boundaries

The root `build.zig` is the only owner of the repository's Zig build graph. It
creates each module and wires dependencies explicitly.

- A relative `@import("path.zig")` is allowed within one cohesive module.
- Crossing a module or component boundary requires a named `@import("...")`
  supplied by the root build.
- Imports such as `@import("../../compositor/src/...")` are forbidden.
- A module exposes dependencies through its root's public API; consumers do
  not reach through it to implementation files.
- Build helpers under `build/` configure the graph. Product source does not
  import them.

Module names and roots are part of the architecture. Add or change them in the
root build and document non-obvious dependency direction changes here.

## Build ownership

- `build.zig` and `build.zig.zon` own Zig dependencies, modules, artifacts,
  tests, generated Zig bindings, installation, and Zig cache reuse.
- `shell/Makefile` owns shell C compilation, C Wayland binding generation,
  shell checks, and shell installation details.
- The root `Makefile` is a phony task facade only. It must not duplicate Zig
  source dependencies. It delegates recursively with `$(MAKE) -C shell` so
  Make flags and jobserver behavior are preserved.
- Procedural automation belongs in `scripts/`, not embedded shell fragments in
  configuration files.

## Change placement

Put a change in the component that owns the behavior. A coordinated feature
may change several components, but each side should communicate through an
explicit module, protocol, or deployed-process contract. Do not introduce a
shared helper solely to avoid a small amount of duplication.
