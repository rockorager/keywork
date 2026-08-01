# Keywork

This repository contains the Keywork native application runtime and UI,
Wayland compositor, and desktop shell. A single build graph enables explicit
modules and coordinated changes without erasing component ownership.

## Repository layout

| Path | Owner |
| --- | --- |
| `src/loop/` | The reusable Linux event loop exposed as the `keywork-loop` Zig module |
| `src/wayring/` | The sans-I/O Wayland engine, protocol scanner, and io_uring transport |
| `src/ui/` | The platform-neutral retained UI model and engine |
| `src/runtime/` | The native Wayland application runtime and platform backends |
| `src/lua/` | The LuaJIT adapter, `keywork` executable, examples, and public Lua types |
| `src/compositor/` | The Wayland compositor, its control adapter, and compositor-owned session integration |
| `src/keyworkctl/` | The umbrella `keyworkctl` CLI and application-control commands |
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
[ARCHITECTURE.md](ARCHITECTURE.md) for the dependency graph and ownership
boundaries.

The same Zig graph builds the shell's native C modules, generates its Wayland
bindings, checks its Lua sources, and installs its application and service
assets.

The bundled Keywork icon theme is generated in the Zig cache from the pinned
Fluent package dependency and installed under `share/icons`; generated SVGs
are not checked into the repository.

Zig 0.16, Go 1.26, and the native development libraries used by the products
are developer prerequisites. Node.js and npm are required for browser SDK
package validation and release packaging. The software streaming backend uses
FFmpeg at runtime. Shell linting and formatting additionally require
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
| `zig build release -Doptimize=ReleaseSafe` | Package a versioned Linux bundle and npm SDK preview under `zig-out/release` |
| `zig build run-shell` | Build, validate, and run the desktop shell |
| `zig build -p ~/.local` | Install all artifacts and service assets under `~/.local` |
| `zig build install-gdm-session -p ~/.local` | Install a system-visible GDM entry targeting the user-local compositor |
| `zig build install-pam` | Install the PAM service under `/etc/pam.d` |

Install a release build for the current user, followed by the two small system
integration files:

```sh
zig build -Doptimize=ReleaseSafe -p "$HOME/.local"
zig build install-gdm-session -p "$HOME/.local"
zig build install-pam
systemctl --user daemon-reload
```

Additional focused steps such as `zig build run`, `zig build
run-native-example`, `zig build run-compositor`, and `zig build renderer-check`
are available from the repository root. The native example opens a Wayland
window without compiling or linking LuaJIT.

## Application control and explicit reload

Every hosted Lua application automatically exposes the runtime-owned
`dev.rockorager.keywork.application` Varlink interface. Per-instance sockets
live under `$XDG_RUNTIME_DIR/keywork/apps/`; applications do not need to create
or manage a server in Lua. `keyworkctl` discovers and verifies those endpoints:

```sh
keyworkctl app list
keyworkctl app status [INSTANCE]
keyworkctl app reload [INSTANCE]
```

When exactly one application is running, `status` and `reload` may omit the
instance. `--address ADDRESS` targets an endpoint directly. Compositor commands
are namespaced as `keyworkctl compositor ...`; their original unnamespaced
forms remain compatibility aliases.

Reload is explicit rather than file-watch driven. A request compiles the entry
script and previously loaded application-local Lua modules before replacing
the current generation, so a syntax-invalid edit is reported to the caller
without tearing down the running generation. Application-local modules loaded
with `require` are evicted and evaluated again on a successful reload. The
entry script and lifecycle callbacks are then replaced and generation-owned
scopes, effects, tasks, and IPC resources restart. Compilation is the
preservation boundary; if candidate execution fails after teardown, Keywork
restarts the previous generation's lifecycle and reports the reload failure.

Lua applications can opt specific state into Fast Refresh. Retained
application data must be plain Lua tables containing only nil, booleans,
numbers, strings, and other plain acyclic tables:

```lua
local kw = require("keywork")

local state = kw.app.hot.state("settings", {
    version = 1,
    init = function()
        return { count = 0 }
    end,
    migrate = function(previous, previous_version)
        return previous
    end,
})
```

Changing `version` runs `migrate(previous, previous_version)` when provided,
or resets through `init`. Stateful widgets retain their state when the source
file, `hot_id`, and `hot_version` identify the same family:

```lua
local kw = require("keywork")
local service = require("counter.service")

local Counter = kw.stateful({
    hot_id = "Counter",
    hot_version = 1,
    init = function(self)
        self.count = 0
    end,
    start = function(self)
        self.subscription = service:use(self.scope, function(value)
            self.value = value
            self:set_state()
        end)
    end,
    build = function(self)
        return kw.text(tostring(self.count))
    end,
})
```

Changing `hot_id` or `hot_version` intentionally remounts the widget. Widget
`init` creates durable widget state only on mount. `start` runs after `init` and
again after every compatible reload with a fresh `self.scope`; subscriptions,
tasks, timers, and other generation-owned effects belong there. Arbitrary
closures, userdata, coroutine stacks, and Lua heaps are not patched or
retained.

GDM discovers session definitions only from system data directories and does
not expand `$HOME` in `Exec`. The `install-gdm-session` step therefore runs the
build as the current user, generates a descriptor containing the selected
prefix's absolute compositor path, and elevates only the final `install`
command. `install-pam` follows the same privilege boundary. Set `SUDO=doas` to
use `doas` instead of `sudo` for either focused step.
