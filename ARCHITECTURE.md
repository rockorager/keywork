# Keywork monorepo architecture

This document defines the target source ownership and allowed dependency
directions. A monorepo makes coordinated changes easier; it does not erase
component boundaries.

All implementation components are direct children of the repository-wide
`src/` tree. Component directories do not contain another nested `src/`.
Examples, resources, language metadata, and non-Wayland product interfaces may
remain with the component that owns them. Repository-wide build support and
all checked-in Wayland XML live outside `src/`.

## Target components

### Loop (`src/loop/`)

Owns the `keywork-loop` Zig module: a concrete Linux reactor built on epoll,
eventfd, timerfd, and inotify. It owns source dispatch and lifetime safety, but
not application lifecycle or protocol-specific policy.

The loop must not depend on the runtime, UI, Lua, compositor, systemd, or
Wayland libraries. Consumer-owned adapters may integrate those systems through
the loop's generic callback and phase contracts.

### UI (`src/ui/`)

Owns the platform-neutral native UI implementation:

- `keywork-ui` owns widgets, types, layout, painting, hit testing, display
  lists, and the render-backend contract.
- `keywork-ui-engine` owns retained-tree lifecycle, reconciliation, input,
  focus, and rendering orchestration around `keywork-ui`.

Neither module may depend on Lua, the event loop, a concrete application host,
Wayland, or a concrete rendering backend.

### Native runtime (`src/runtime/`)

Owns `keywork-runtime`: the general Wayland application platform, including
application lifecycle, window declarations, platform services, Wayland
backends, CPU and Vulkan renderers, Linux integration, and event-loop adapters.

The native runtime depends on the UI and loop modules. It must compile and link
without LuaJIT and must not acquire shell or compositor policy. Native Zig
applications and language adapters consume the same public runtime contract.

### Lua host (`src/lua/`)

Owns `keywork-lua`, the `keywork` executable, LuaJIT integration, Lua-facing
APIs, script lifecycle, Storybook and test commands, Lua examples, and public
Lua type information.

Lua is a first-class adapter to the native runtime, not the owner of native
application lifecycle. It may depend on the runtime, UI, and loop modules;
those modules must never depend on it.

### Compositor (`src/compositor/`)

Owns the Wayland compositor, window-management policy, renderer integration,
the compositor Varlink interface and server, `keyworkctl`, and session assets
that start or configure the compositor.

Its control implementation is compositor-private. User-facing commands must
remain synchronized across configuration keybindings, Varlink declarations
and dispatch, and `keyworkctl` parsing and help.

### Shell (`src/shell/`)

Owns the Lua desktop experience: bar, launcher, lock screen, notifications,
backgrounds, OSD, shell D-Bus API, native C helpers, PAM policy, and shell
service assets.

The shell is a demanding consumer of the runtime's public API. Runtime defects
or missing abstractions found while developing the shell should be fixed in
the runtime rather than hidden behind shell-specific workarounds.

### Protocols (`protocols/`)

Owns the repository-wide location and provenance manifest for every checked-in
Wayland protocol XML file. Byte-for-byte external snapshots live under
`protocols/wayland/upstream/`; adapted and first-party compatibility schemas
live directly under `protocols/wayland/`.

Centralized storage does not transfer behavioral ownership. The manifest names
each consumer, while non-Wayland product interfaces remain with their products.
In particular, the compositor Varlink interface is not Wayland protocol
infrastructure and remains compositor-owned.

## Dependency directions

Arrows mean "depends on":

```diagram
┌─────────┐  deployed Lua API  ┌──────────┐    ┌────────────────┐
│  shell  │───────────────────▶│ Lua host │───▶│ native runtime │
└─────────┘                    └────┬─────┘    └───────┬────────┘
                                  │                  │
                                  │                  ▼
                                  │          ┌───────────────────┐
                                  │          │ keywork-ui-engine │
                                  │          └─────────┬─────────┘
                                  │                    ▼
                                  │             ┌────────────┐
                                  │             │ keywork-ui │
                                  │             └────────────┘
                                  │
                                  └──────────┐   ┌──────────────┐
                                             └──▶│ keywork-loop │
                                native runtime ─▶│              │
                                                 └──────────────┘

┌─────────┐     ┌───────────────┐     ┌────────────┐
│  shell  │────▶│   protocols   │◀────│ compositor │
└─────────┘     └───────▲───────┘     └────────────┘
                        │
                ┌───────┴────────┐
                │ native runtime │
                └────────────────┘
```

The native runtime consumes `keywork-ui-engine`, `keywork-ui`, and
`keywork-loop`. The Lua host consumes public native modules and supplies an
application host; native Zig applications do the same without LuaJIT. The
shell relies on the deployed `keywork` executable and public Lua API.

The compositor and runtime have no source-code dependency on each other.
Session integration between the compositor and shell is a deployed-process
contract, not permission for source imports between them. Compositor
consumption of `keywork-loop` may be added later without introducing a
compositor-runtime dependency.

There is intentionally no general-purpose `common/` directory. Shared code is
promoted only when it has a stable responsibility and a clear owner.

## Zig module boundaries

The root `build.zig` is the only owner of the repository's Zig build graph. It
creates each module and wires dependencies explicitly.

- A relative `@import("path.zig")` is allowed within one cohesive module.
- Crossing a module or component boundary requires a named `@import("...")`
  supplied by the root build.
- Imports such as `@import("../../compositor/...")` are forbidden.
- A module exposes dependencies through its root's public API; consumers do
  not reach through it to implementation files.
- Build helpers under `build/` configure the graph. Product source does not
  import them.

Module names and roots are part of the architecture. Add or change them in the
root build and document non-obvious dependency direction changes here.

Current source module roots are:

| Module | Root | Direct module dependencies |
| --- | --- | --- |
| `keywork-loop` | `src/loop/event_loop.zig` | none |
| `keywork-ui` | `src/ui/root.zig` | `uucode`, `linebreak`, `z2d` |
| `keywork-ui-engine` | `src/ui/engine/root.zig` | `keywork-ui`, `uucode` |
| `keywork-runtime` | `src/runtime/root.zig` | `keywork-loop`, `keywork-ui`, `keywork-ui-engine` |
| `keywork-lua` | `src/lua/root.zig` | public native modules |
| `linebreak` | `src/ui/linebreak/root.zig` | `uucode` |
| `varlink` | `src/compositor/varlink/root.zig` | none |
| `keywork-control` | `src/compositor/control/root.zig` | embedded compositor interface |

The `keywork` executable root is `src/lua/main.zig`. It consumes the adapter
through `keywork-lua`, and the adapter consumes native runtime source through
public named modules. Native modules must not import the Lua tree.

## Native application acceptance criteria

The native boundary is complete only when all of these are true:

- A repository example opens and drives a real Wayland window as a native Zig
  application using `keywork-runtime` and `keywork-ui`.
- Building that example does not build or link LuaJIT.
- `src/runtime/app/`, `backend/`, `graphics/`, and `linux/` have no imports from
  the Lua component.
- The Lua host consumes native source only through named modules and their
  public declarations.
- Native runtime tests run without LuaJIT; Lua adapter tests remain a separate
  test root.

## Build ownership

- `build.zig` and `build.zig.zon` own Zig dependencies, modules, artifacts,
  tests, generated Zig bindings, installation, and Zig cache reuse.
- Graph construction must not execute system dependency checks. A
  component-specific step must require only that component's system tools and
  libraries; attach probes and generators to the artifacts that consume them.
- Provide aggregate test/build steps and focused component steps. In
  particular, formatting and compositor-only work must not require runtime
  libraries, and native runtime work must not require LuaJIT unless it selects
  the Lua host.
- The root Zig graph owns shell C compilation, C Wayland binding generation,
  Lua checks, formatting, and installation alongside the native artifacts.
- `zig build` is the sole repository task interface. Aggregate steps whose
  names imply the whole repository operate on both native and shell sources;
  focused shell steps remain available where useful.
- Privileged PAM installation remains the explicit `install-pam` step and is
  never part of the default install.
- Procedural automation belongs in `scripts/`, not embedded shell fragments in
  configuration files.

## Migration gates

The migration was performed in this order:

1. Replace the runner's opaque context and callback collection with one typed
   host-binding interface.
2. Move Lua-owned lifecycle files beside the Lua host, without changing
   behavior.
3. Expose `keywork-runtime` and make the Lua host consume it by name.
4. Add the native Wayland example and enforce the no-LuaJIT acceptance gate.
5. Remove configuration-time dependency probes and add focused build steps.
6. Relocate the UI and Lua components in history-preserving move commits.
7. Establish repository-wide build and check semantics.
8. Centralize all checked-in Wayland XML and provenance under `protocols/`.
9. Consolidate implementation components under one root `src/` namespace.

All migration gates are complete. Future boundary changes remain subject to
the ownership and dependency rules above.

## Monorepo stop conditions

Reconsider separate repositories if components require incompatible Zig
versions for more than a transitional period, shared dependency-version
conflicts become routine, external consumers require independent module
versioning, or coordinated cross-component changes become rare. Do not split
the repository merely to compensate for a boundary that can be represented as
a named module.

## Change placement

Put a change in the component that owns the behavior. A coordinated feature
may change several components, but each side should communicate through an
explicit module, protocol, or deployed-process contract. Do not introduce a
shared helper solely to avoid a small amount of duplication.
