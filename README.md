# Keywork

This repository contains the Keywork native application runtime and UI,
Wayland compositor, and desktop shell. Their histories remain intact while a
single build graph enables explicit modules and coordinated changes without
erasing component ownership.

## Repository layout

| Path | Owner |
| --- | --- |
| `src/loop/` | The reusable Linux event loop exposed as the `keywork-loop` Zig module |
| `src/ui/` | The platform-neutral retained UI model and engine |
| `src/runtime/` | The native Wayland application runtime and platform backends |
| `src/lua/` | The LuaJIT adapter, `keywork` executable, examples, and public Lua types |
| `src/compositor/` | The Wayland compositor, `keyworkctl`, and compositor-owned session integration |
| `src/shell/` | The Lua desktop shell and its native C helpers |
| `protocols/` | All checked-in Wayland protocol XML and its provenance metadata |
| `build/` | Helpers used only by the root Zig build graph |
| `scripts/` | Procedural repository automation that does not belong directly in `build.zig` |

See [ARCHITECTURE.md](ARCHITECTURE.md) for ownership and dependency rules.

## Build model

Root `build.zig` and `build.zig.zon` build every Zig artifact in one graph and
cache. Current named source modules include `keywork-loop`, `keywork-ui`,
`keywork-ui-engine`, `keywork-runtime`, `keywork-lua`, `linebreak`, `varlink`,
and `keywork-control`. Source may use relative imports within a cohesive
module; dependencies between modules are explicit named imports wired by the
root build.

Native UI and runtime modules allow Zig applications to use the full Wayland
platform without building or linking LuaJIT. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the target graph, migration gates, and
monorepo stop conditions.

The same Zig graph builds the shell's native C modules, generates its Wayland
bindings, checks its Lua sources, and installs its application and service
assets. There is no secondary task runner or component-local build graph.

Zig 0.16 and the native development libraries used by both products are
developer prerequisites. Shell linting and formatting additionally require
`emmylua_check` and `luafmt`; this repository does not install or select tools
or system packages.

Common commands:

| Command | Action |
| --- | --- |
| `zig build` | Build and install all artifacts under `zig-out`, including the shell |
| `zig build test` | Run all native tests, shell checks, and formatting checks |
| `zig build check` | Run all tests and static analysis |
| `zig build lint` | Run shell static analysis |
| `zig build fmt` | Check Zig, Lua, and Lua type formatting |
| `zig build format` | Format Zig, Lua, and Lua type sources |
| `zig build run-shell` | Build, validate, and run the desktop shell |
| `zig build -p ~/.local` | Install all artifacts and service assets under `~/.local` |
| `sudo zig build install-pam` | Install the PAM service under `/etc/pam.d` |

Additional focused steps such as `zig build run`, `zig build
run-native-example`, `zig build run-compositor`, and `zig build renderer-check`
are available from the repository root. The native example opens a Wayland
window without compiling or linking LuaJIT.

## Migration status

The source repositories were imported with unsquashed history at fixed
revisions before files were reorganized:

| Source | Imported revision |
| --- | --- |
| `https://github.com/rockorager/keywork.git` | `0c381bd544ab8ffedc97f28fb3bfe3f85b5a79bc` |
| `https://github.com/rockorager/keywork-compositor.git` | `6f26973d4451b804a80e6511002a5fc824590f85` |
| `https://github.com/rockorager/keywork-shell.git` | `d37444d3d183dfe0cba0f695c32abd71a707051c` |

Migration phases:

- [x] Import all three source histories without changing their contents.
- [x] Establish repository-wide guidance and scoped component guidance.
- [x] Extract the Linux reactor as the named `keywork-loop` module.
- [x] Replace the two independent Zig builds with one root build graph.
- [x] Promote the native UI model and orchestration to named modules.
- [x] Replace runner callback fields with one typed host-binding contract.
- [x] Expose the Lua-free `keywork-runtime` module.
- [x] Add a native Wayland application proving the no-LuaJIT path.
- [x] Relocate native UI and Lua host source to top-level components.
- [x] Elevate shared vendored Wayland XML to `protocols/` with provenance.
- [x] Make the root Zig graph the sole build, test, format, and install interface.
- [x] Remove transitional component build and tool-runner configuration.
- [x] Consolidate implementation components under one root `src/` tree.
