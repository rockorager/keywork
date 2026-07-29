# Keywork

This repository is the future home of the Keywork runtime, compositor, and
desktop shell. The monorepo migration is intentionally incremental: first
preserve each repository and its history, then consolidate shared build and
protocol infrastructure without mixing those moves with product changes.

## Repository layout

| Path | Owner |
| --- | --- |
| `runtime/` | The Zig/Lua application runtime currently developed as `keywork` |
| `compositor/` | The Wayland compositor, `keyworkctl`, and compositor-owned session integration |
| `shell/` | The Lua desktop shell and its native C helpers |
| `protocols/` | Shared vendored Wayland protocol XML and its provenance metadata |
| `build/` | Helpers used only by the root Zig build graph |
| `scripts/` | Procedural repository automation that does not belong in Make or `build.zig` |

See [ARCHITECTURE.md](ARCHITECTURE.md) for ownership and dependency rules.

## Build model

The completed repository will have one root `build.zig` and
`build.zig.zon`. The root build will create named modules for every Zig
subproject and build all Zig artifacts in one graph and cache. Source code may
use relative imports within a module, but dependencies between modules must be
explicit named imports wired by the root build.

The shell's existing Makefile remains responsible for its C modules and
Wayland code generation. A small root Makefile will be the human-facing task
facade and will delegate to the Zig build and to `$(MAKE) -C shell`.

Zig 0.16 is a developer prerequisite. This repository does not install or
select compilers or system packages.

## Migration status

The source repositories are imported with unsquashed history at fixed
revisions before any files are reorganized:

| Destination | Source | Imported revision |
| --- | --- | --- |
| `runtime/` | `https://github.com/rockorager/keywork.git` | `0c381bd544ab8ffedc97f28fb3bfe3f85b5a79bc` |
| `compositor/` | `https://github.com/rockorager/keywork-compositor.git` | `6f26973d4451b804a80e6511002a5fc824590f85` |
| `shell/` | `https://github.com/rockorager/keywork-shell.git` | `d37444d3d183dfe0cba0f695c32abd71a707051c` |

Migration phases:

1. Import all three source histories without changing their contents.
2. Establish repository-wide guidance and scoped component guidance.
3. Replace the two independent Zig builds with one root build graph.
4. Elevate shared vendored Wayland XML to `protocols/` with provenance.
5. Add the root Make task facade and verify build, test, and formatting parity.
6. Remove transitional component build and tool-runner configuration.

Until those phases are complete, component-local commands remain the source
of truth for validation.
