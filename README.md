# Keywork

This repository contains the Keywork Lua application platform, native UI and
Wayland runtime, compositor, and desktop shell. Applications use the supported
Lua API while the native Zig modules own rendering, platform integration, and
host lifecycle. A single build graph enables explicit modules and coordinated
changes without erasing component ownership.

## Repository layout

| Path | Owner |
| --- | --- |
| `src/loop/` | The reusable Linux event loop exposed as the `keywork-loop` Zig module |
| `src/ui/` | The platform-neutral retained UI model and engine |
| `src/runtime/` | The native Wayland host runtime and platform backends |
| `src/lua/` | The supported Lua application API, `keywork` executable, examples, and public types |
| `src/compositor/` | The Wayland compositor, its control adapter, and compositor-owned session integration |
| `src/keyworkctl/` | The umbrella `keyworkctl` CLI and application-control commands |
| `src/shell/` | The Lua desktop shell and its native C helpers |
| `protocols/` | All checked-in Wayland protocol XML and its provenance metadata |
| `build/` | Helpers used only by the root Zig build graph |
| `scripts/` | Procedural repository automation that does not belong directly in `build.zig` |

See [ARCHITECTURE.md](ARCHITECTURE.md) for ownership and dependency rules.

## Applications

Keywork applications are trusted Lua scripts that return a `keywork.app`.
Application state, components, widgets, asynchronous work, platform services,
testing, and Storybook all use the Lua API; the Zig modules are native host
implementation rather than an alternative application SDK.

```lua
local kw = require("keywork")

return kw.app({
    app_id = "dev.keywork.Hello",
    width = 480,
    height = 240,
    child = kw.center({
        child = kw.text("Hello from Keywork"),
    }),
})
```

Run an installed application with `keywork app.lua`. During development, use
`zig build run -- app.lua`. See `src/lua/examples/` for applications covering
components, reactive state, layer-shell windows, services, and Storybook.

Applications access the desktop secret store through the standard Secret
Service client rather than prompt UI primitives:

```lua
local secrets = require("keywork.secrets")

local password, metadata, err = secrets.lookup({
    application = "dev.keywork.Example",
    account = "alice",
})
```

`keywork.secrets` also provides `store` and `delete`. These yielding operations
run in a `keywork.loop` task. The client uses Secret Service's baseline `plain`
session algorithm and relies on local session-bus isolation;
application-facing secret values are ordinary Lua strings.

## Build model

Root `build.zig` and `build.zig.zon` build every Zig artifact in one graph and
cache. Current named source modules include `keywork-loop`, `keywork-ui`,
`keywork-ui-engine`, `keywork-runtime`, `keywork-lua`, `linebreak`, `varlink`,
and `keywork-control`. Source may use relative imports within a cohesive
module; dependencies between modules are explicit named imports wired by the
root build.

Native UI and runtime modules are independently testable implementation and
host boundaries consumed by the Lua adapter; they are not a second supported
application SDK. See [ARCHITECTURE.md](ARCHITECTURE.md) for the dependency
graph, API policy, and ownership boundaries.

The same Zig graph builds the shell's native C modules, generates its Wayland
bindings, checks its Lua sources, and installs its application and service
assets.

The bundled Keywork icon theme is generated in the Zig cache from the pinned
Fluent package dependency and installed under `share/icons`; generated SVGs
are not checked into the repository.

Zig 0.16, Meson, Ninja, and the native development libraries used by the
products are developer prerequisites. Meson and Ninja build the pinned static
Wayland libraries in Zig's build graph. Shell linting and formatting
additionally require `emmylua_check` and `luafmt`; this repository does not
install or select tools or system packages.

Common commands:

| Command | Action |
| --- | --- |
| `zig build` | Build and install all artifacts under `zig-out`, including the shell |
| `zig build test` | Run all native tests, shell checks, and formatting checks |
| `zig build check` | Run all tests and static analysis |
| `zig build lint` | Run shell static analysis |
| `zig build fmt` | Check Zig, Lua, and Lua type formatting |
| `zig build format` | Format Zig, Lua, and Lua type sources |
| `zig build release -Doptimize=ReleaseSafe -Dcpu=baseline` | Package a portable, versioned Linux compositor bundle under `zig-out/release` |
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

Additional focused steps such as `zig build run`, `zig build run-compositor`,
and `zig build renderer-check` are available from the repository root.

## Shell bar configuration

`keywork-shell` loads `$XDG_CONFIG_HOME/keywork/shell/init.lua` when it exists
and otherwise uses the built-in shell configuration. `KEYWORK_SHELL_CONFIG`
selects an explicit entry point. A user entry point calls the public shell
factory and declares ordered bar items:

```lua
local shell = require("shell")
local hostname = require("modules.hostname")

return shell.app({
    bar = {
        height = 40,
        right = {
            shell.bar.tray({ outputs = "first" }),
            shell.bar.volume(),
            shell.bar.network(),
            shell.bar.cpu(),
            hostname(),
            shell.bar.battery({ show_percent = true }),
            shell.bar.clock({ format = "%a %b %d  %I:%M %p" }),
        },
    },
})
```

Omitted `left` or `right` lists retain that side's built-in defaults; an empty
list disables it. Items appear on every output by default. Set `outputs` to
`"first"`, an output name, or a list of output names to limit an item. Built-in
constructors are `workspaces`, `tray`, `volume`, `network`, `cpu`, `battery`,
and `clock`. The tray must target exactly one output because the shell owns one
StatusNotifierWatcher name.

Custom modules return the same item descriptors as the built-ins and build
ordinary Keywork widgets:

```lua
-- $XDG_CONFIG_HOME/keywork/shell/modules/hostname.lua
local shell = require("shell")

return function(options)
    options = options or {}
    return shell.bar.item({
        id = options.id or "hostname",
        outputs = options.outputs,
        widget = function(context)
            return shell.bar.pill({
                id = "hostname-pill",
                icon = "computer",
                label = os.getenv("HOSTNAME") or "host",
                color = context.colors.foreground,
            })
        end,
    })
end
```

A custom item may return a `kw.component` and use scoped timers, processes,
D-Bus, or `keywork.service` values exactly like any other Keywork application.
Configuration is trusted Lua running inside the shell process, not a sandbox.
The user entry point and its sibling Lua modules participate in explicit
application reloads. Restart `keywork-shell` after creating or removing
`init.lua`; entry-point selection happens at process startup.

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

Signals are the render-state API. Create state that affects build output with
`kw.signal`, read it by calling the signal in `build`, and change it with
`:set`, `:update`, or `:mutate`. A computed value tracks the signals it reads
and is also read by calling it. Reads are tracked dynamically; writes are
synchronous, while affected component rebuilds are deferred and coalesced by
the runtime. Equality defaults to `rawequal`; use `:mutate` when changing a
table in place, or pass an `equals` function when identity is not sufficient:

```lua
local kw = require("keywork")

local Counter = kw.component({
    hot_id = "Counter",
    hot_version = 1,
    init = function(self)
        self.count = kw.signal(0)
        self.label = kw.computed(function()
            return "Count: " .. self.count()
        end)
    end,
    build = function(self)
        return kw.pressable({
            on_activate = function()
                self.count:update(function(value) return value + 1 end)
            end,
            child = kw.text(self.label()),
        })
    end,
})
```

Components retain their mounted state when the source file, `hot_id`, and
`hot_version` identify the same family. Their lifecycle remains
`init`/`start`/`update`/`build`/`dispose`. Services expose readable signals
from `:use(scope)`; call the returned signal in `build` rather than subscribing
from a UI callback:

```lua
local kw = require("keywork")
local service = require("counter.service")

local ServiceCounter = kw.component({
    start = function(self)
        self.value = service:use(self.scope)
    end,
    build = function(self)
        return kw.text(tostring(self.value()))
    end,
})
```

Window-defining state uses a hot signal. Reading it inside `windows(ctx)`
automatically reconciles the window set; no explicit invalidation is needed.
Values retained through reload must be nil, booleans, numbers, strings, or
plain acyclic tables. Increment `version` to run `migrate` (or reset to the
initial value when no migration is supplied):

```lua
local launcher_open = kw.app.hot.signal("launcher-open", false, {
    version = 2,
    migrate = function(previous, previous_version)
        return previous_version == 1 and previous == "open" or previous
    end,
})

local app = kw.app({
    windows = function(ctx)
        return launcher_open() and { launcher_window(ctx) } or {}
    end,
})
```

Changing a component's `hot_id` or `hot_version` intentionally remounts it.
`init` creates durable component state only on mount. `start` runs after
`init` and again after every compatible reload with a fresh `self.scope`;
tasks, timers, services, and other generation-owned effects belong there.
Arbitrary closures, userdata, coroutine stacks, and Lua heaps are not patched
or retained.

GDM discovers session definitions only from system data directories and does
not expand `$HOME` in `Exec`. The `install-gdm-session` step therefore runs the
build as the current user, generates a descriptor containing the selected
prefix's absolute compositor path, and elevates only the final `install`
command. `install-pam` follows the same privilege boundary. Set `SUDO=doas` to
use `doas` instead of `sudo` for either focused step.
