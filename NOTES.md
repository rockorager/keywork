# NOTES.md

Keywork API pain points and bugs found while building the shell.
Fix these in `../keywork`, then simplify here.

## Open

- **Popup content cannot open a nested popup.** A submenu can be composed from
  `kw.anchored`, `kw.popup`, and the menu widgets, but popup reconciliation
  currently scans only the parent window's runtime. Keywork needs hierarchical
  popup ownership, one-level Escape dismissal, and nested input routing before
  a `kw.submenu_item` can provide correct behavior.

## Resolved

- **Timed surfaces could not preserve their remaining lifetime across hover.**
  Keywork exposed timers but no monotonic time to Lua, and its composed button
  widgets dropped the underlying pressable's hover callback. Keywork now
  provides `loop.monotonic_ms()` and forwards button hover changes, allowing
  notifications to pause expiry and resume with the exact time remaining.
- **Window-set changes rebuilt every existing window.** `kw.app.invalidate()`
  was the only way to add or remove a managed window, so showing the OSD also
  rebuilt and repainted both full-resolution background surfaces. Keywork now
  provides `kw.app.reconcile()` for changes limited to window existence; the
  OSD uses scoped widget invalidation for level updates and only reconciles
  when its surface appears or disappears.
- **Large Vulkan backgrounds could fail on higher-resolution outputs.** Atlas
  growth and staging-buffer growth shared an eight-retry budget, so a 4K
  wallpaper exhausted it even though both resources could still grow. Keywork
  now grows staging as needed and only stops atlas recovery after one clean
  current-frame repack at the device limit.
- **Client shadows were clipped at layer-shell and popup boundaries.** Keywork
  sized native surfaces from layout bounds, so painted shadows had nowhere to
  go unless every caller duplicated their outsets as transparent padding.
  Keywork now derives native frame gutters from retained subtree paint bounds,
  keeps layer placement and popup window geometry tied to visible content,
  and excludes transparent gutters from input and blur regions.
- **Managed top-level windows could not reflect compositor closes into app
  state.** Dropping a declaration destroyed a window, but closing an
  `xdg_toplevel` had no callback to clear the state that declared it, so the
  audio settings window could not be reopened. Keywork now supports
  `kw.window({ on_close = ... })` and dispatches it before reconciling the
  closed surface.
- **Icons could not prefer symbolic assets without losing the regular
  fallback.** Some shell contexts need a monochrome symbolic variant when one
  exists, while branded apps without one must retain their normal icon.
  Keywork's `kw.icon` and `kw.icon_theme` now accept an explicit
  `symbolic = true`, with the preference included in icon-cache keys. Tint and
  icon selection remain independent: the shell only tints known monochrome
  controls, while application and notification icons retain their own palette.
- **D-Bus replies could not carry Unix file descriptors.** A safe logind
  delay inhibitor requires retaining the descriptor returned by `Inhibit`
  until the lock screen is compositor-confirmed. Keywork now decodes `h`
  values as owning Lua userdata with explicit/idempotent close and GC cleanup.
- **Keywork could not implement a secure session lock.** It lacked the
  `ext-session-lock-v1` role and password-oriented text input behavior. Keywork
  now exposes compositor-backed multi-output session locks, while obscured
  inputs support submit-and-clear and zero their backing buffers. PAM remains
  a shell-owned native module, and the lock runs as a separate short-lived
  process so the long-running shell service never handles the password.
- **Background surfaces lacked image files, full-output sizing, and input
  passthrough.** Keywork's image widget only accepted decoded ARGB pixels,
  managed layer windows only delegated width (not height) to their anchors,
  and every surface used the default full input region. Keywork now supports
  path-backed `kw.image` sources with object-fit modes, compositor-sized `0x0`
  layer surfaces, and `layer_shell.pointer = "none"` for an empty input region.
  Frame-scoped image rasters let static full-surface images release decoded
  pixels after presentation instead of duplicating the retained Wayland frame.
- **Lua composition widgets lost ambient component themes.** `kw.theme`
  retained native colors and control styles but discarded Lua-only component
  data before stateful chips and menus built. Keywork now carries the original
  Lua theme through stateful and deferred builders, restoring selected and
  hover states without per-widget theme props.
- **Explicit line-height left labels visually high in their boxes.** A
  Storybook snapshot of the workspace switcher exposed that Keywork put all
  extra line-height below the baseline. Keywork now splits that leading above
  and below the natural line box, keeping chip labels vertically centered.
- **Menus repeated their surface and item styling at every call site.**
  Keywork now provides ambient-theme `kw.menu`, `kw.menu_item`,
  `kw.menu_label`, and `kw.menu_separator` composition widgets. The audio,
  Wi-Fi, and launcher action menus share them while retaining their own
  content, placement, and selection behavior.
- **PipeWire audio could only be observed, not controlled.** The shell would
  still have needed `wpctl` for volume/mute and default-device selection after
  adopting `keywork.audio`. Keywork now streams node volume/mute properties,
  writes matching device routes (with node-property fallback for virtual
  devices), and updates configured-default metadata. The bar and OSD no longer
  spawn `wpctl` or `pactl`.
- **Bluetooth hotplug could leave volume keys controlling a stale node.** A
  long-lived monitor could retain a false `device.routes` hint after AirPods
  connected, so successful volume writes changed only node properties while
  WirePlumber kept the headphones' route volume unchanged. Keywork now chooses
  a matching route from its actual volume/mute properties and observes that
  route as the source of truth, matching WirePlumber's mixer behavior.
- **`require` needed a LUA_PATH bootstrap.** Both `bin/keywork-shell` and
  `make run` exported `LUA_PATH` so `require("shell.*")` could resolve.
  Fixed in keywork: the script's directory is prepended to `package.path`
  (`<dir>/?.lua;<dir>/?/init.lua`). The entry point moved to `lua/init.lua`
  so `lua/` is the module root, and the bootstrap is gone.
- **App enumeration was hand-rolled.** The apps provider shelled out to
  `find` and reimplemented data-dir precedence/shadowing. Now keywork's
  `xdg.applications.list()` owns enumeration; the provider only filters
  `no_display`/`hidden` and shapes launcher entries.
- **Launched apps couldn't take focus under focus-stealing prevention.**
  Now `kw.window.request_activation_token()` is requested on the launch
  input event and passed to `xdg.launch` — and injected into the transient
  systemd unit via `--setenv`, since units inherit the user manager's
  environment rather than the spawn env.
- **SVG icons lost `<use>`-cloned shapes.** Even with the right file
  resolved, GNOME's Files icon rendered with one drawer handle instead
  of three: the icon draws one handle and clones the rest with
  `<use xlink:href>`, which nanosvg silently dropped. Originally fixed
  in keywork `e1e8eee4` with a text-level expansion pass; superseded by
  switching keywork to resvg, which supports `<use>` directly.

- **App icons resolved to their symbolic variants.** GNOME Files showed
  the grey symbolic cabinet instead of its full-color icon. index.theme
  parsing let `Size=` clobber an already-parsed `MinSize=`/`MaxSize=`
  (hicolor writes MinSize before Size), so `hicolor/scalable/apps`
  collapsed to range [128, 256], launcher-sized lookups skipped it, and
  the `-symbolic` name fallback in `symbolic/apps` won. Fixed in keywork
  `e9abe79e`: MinSize/MaxSize are optionals that default to Size at use
  time, making the parse order-independent (with regression test
  "scalable directory size range survives any key order").

- **Tab couldn't be bound as a shortcut.** `shortcutKeyForInput` mapped
  `.tab` to null unconditionally, so the launcher's actions menu had no
  key to open it. Fixed in keywork: plain tab is a bindable `ShortcutKey`
  (`tab = "..."` in `kw.shortcuts`); unbound tab still falls through to
  focus traversal and shift-tab always keeps reverse traversal (with
  regression test "bound tab fires its shortcut instead of traversal").

- **Auto-sized popups didn't resize when their content changed.** The Wi-Fi
  menu rebuilt with newly discovered rows, but its `xdg_popup` retained the
  height measured when it opened and clipped them. Fixed in keywork: dirty
  parent-owned popup content is remeasured and size changes are applied with
  `xdg_popup.reposition`.
- **Clicking parent-window empty space didn't dismiss anchored popups.**
  Fixed in keywork: a press on the parent surface outside every live
  popup's anchor calls the popups' `on_close` and consumes the press
  (macOS menu semantics — the click never activates what's beneath).
  Presses on the anchor still pass through so its gesture toggles.
- **Popups were CPU-backend only.** `runner.zig` hard-gated popups to the
  shm backend and `PopupManager` was hard-typed to it. Fixed in keywork:
  `PopupManager` is generic over the backend, the vulkan backend gained
  `createPopup` (the xdg_popup plumbing was already shared in window.zig),
  and the gate is now `@hasDecl(Backend, "createPopup")`. Verified live:
  popup renders in its own Vulkan swapchain. The *multi-window* host
  (`windows = function(ctx)`) was shm-only at the time but has since
  gained Vulkan too (verified live in keywork-files).
- **Popup surfaces cleared to opaque theme background.** Rounded menu
  corners showed opaque squares: layer-shell windows get
  `setFrameBackground(transparent)` but popup runtimes in
  [runner.zig](../keywork/src/app/runner.zig) `createPopup` didn't. Fixed in
  keywork — popups now clear transparent and content paints its own
  background.
- **Hover highlight lost on rebuild while pointer rests on target.** Any
  full rebuild (clock tick, status update) rewrote hovered clickables with
  their base background: `updateElementTreeScoped`'s `.clickable` branch in
  [model.zig](../keywork/src/ui/model.zig) passed the raw child instead of
  `clickableStyledChild(...)` like the build path does. Fixed in keywork
  (with regression test "clickable keeps hover background through tree
  update"); highlight now survives rebuilds until the pointer moves off.
- **Resolved theme drops the font-size scale.** Fixed in keywork `7e84d0aa`:
  `resolve_theme` now returns `font_size`. The launcher footer hints use
  `theme.font_size[1]`.
- **`kw.chip` has no component theme.** Fixed in keywork `7e84d0aa`: chips
  read metrics/colors from `theme.components.chip` (explicit options win).
  The bar defines its chip design once in the ambient bar theme, and call
  sites only pass what differs; widgets no longer require an explicit theme.
- **`--script=` swallows app args.** Fixed in keywork `708a6ac1`:
  `keywork --script=foo.lua bar` now lands `bar` in the Lua `arg` table.
  `bin/keywork-shell` already passed `"$@"` through; no change needed here.
- **D-Bus introspection collapsed compound signatures into one argument.**
  The notification daemon's `Notify` signature (`susssasa{sv}i`) worked at
  runtime, but generated introspection described it as one argument, causing
  `gdbus` to warn and miscount parameters. Fixed in keywork: introspection now
  emits one `<arg>` per complete D-Bus type, with a regression test covering
  basic, array, and dictionary arguments.
- **D-Bus byte arrays expanded into Lua number tables.** Notification
  `image-data` arrived as one boxed Lua number per byte, then had to be copied
  again into the image widget's ARGB input. Fixed in keywork: `ay` values now
  decode directly to binary Lua strings, matching the image widget's fast
  input path (with a decode regression test).
