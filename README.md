# Keywork

This repository contains the Keywork native application runtime and UI,
Wayland compositor, and desktop shell. Their histories remain intact while a
single build graph enables explicit modules and coordinated changes without
erasing component ownership.

## Repository layout

| Path | Owner |
| --- | --- |
| `loop/` | The reusable Linux event loop exposed as the `keywork-loop` Zig module |
| `runtime/` | The Zig/Lua application runtime currently developed as `keywork` |
| `compositor/` | The Wayland compositor, `keyworkctl`, and compositor-owned session integration |
| `shell/` | The Lua desktop shell and its native C helpers |
| `protocols/` | Shared vendored Wayland protocol XML and its provenance metadata |
| `build/` | Helpers used only by the root Zig build graph |
| `scripts/` | Procedural repository automation that does not belong in Make or `build.zig` |

See [ARCHITECTURE.md](ARCHITECTURE.md) for ownership and dependency rules.

## Build model

Root `build.zig` and `build.zig.zon` build every Zig artifact in one graph and
cache. Current named source modules include `keywork-loop`, `keywork-ui`,
`keywork-ui-runtime`, `linebreak`, `varlink`, and `keywork-control`. Source may
use relative imports within a cohesive module; dependencies between modules
are explicit named imports wired by the root build.

The current physical layout is transitional. The target separates native UI,
native application runtime, and the Lua host so Zig applications can use the
full Wayland platform without building or linking LuaJIT. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the target graph, migration gates, and
monorepo stop conditions.

The shell's existing Makefile remains responsible for its C modules and
Wayland code generation. The root Makefile is the human-facing task facade and
delegates shell work to `$(MAKE) -C shell`.

Zig 0.16 and the native development libraries used by both products are
developer prerequisites. Shell linting and formatting additionally require
`emmylua_check` and `luafmt`; this repository does not install or select tools
or system packages.

Common commands:

| Command | Action |
| --- | --- |
| `make` | Build all Zig artifacts and validate/build shell native modules |
| `make test` | Run all Zig tests |
| `make check` | Run all Zig tests and shell checks |
| `make lint` | Run shell static analysis |
| `make fmt` | Format Zig, Lua, and Lua type sources |
| `make install` | Install Zig artifacts under `PREFIX` (default `~/.local`) |
| `make install-shell` | Install the shell and its user service under `PREFIX` |

Direct Zig steps such as `zig build test`, `zig build run`,
`zig build run-compositor`, and `zig build renderer-check` are also available
from the repository root.

## Migration status

The source repositories are imported with unsquashed history at fixed
revisions before any files are reorganized:

| Destination | Source | Imported revision |
| --- | --- | --- |
| `runtime/` | `https://github.com/rockorager/keywork.git` | `0c381bd544ab8ffedc97f28fb3bfe3f85b5a79bc` |
| `compositor/` | `https://github.com/rockorager/keywork-compositor.git` | `6f26973d4451b804a80e6511002a5fc824590f85` |
| `shell/` | `https://github.com/rockorager/keywork-shell.git` | `d37444d3d183dfe0cba0f695c32abd71a707051c` |

Migration phases:

- [x] Import all three source histories without changing their contents.
- [x] Establish repository-wide guidance and scoped component guidance.
- [x] Extract the Linux reactor as the named `keywork-loop` module.
- [x] Replace the two independent Zig builds with one root build graph.
- [x] Promote the native UI model and orchestration to named modules.
- [x] Replace runner callback fields with one typed host-binding contract.
- [ ] Expose the Lua-free `keywork-runtime` module.
- [ ] Add a native Wayland application proving the no-LuaJIT path.
- [ ] Relocate native UI and Lua host source to top-level components.
- [ ] Elevate shared vendored Wayland XML to `protocols/` with provenance.
- [x] Add the root Make task facade and verify build, test, and formatting parity.
- [x] Remove transitional component build and tool-runner configuration.
