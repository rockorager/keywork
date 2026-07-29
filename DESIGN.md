# Keywork Design System

Keywork uses a Fluent-derived visual system with a Flutter-like widget model.
Fluent supplies the token vocabulary, interaction-state model, color roles,
geometry, elevation, and icon family. Keywork adapts those foundations for a
compact, keyboard-focused Linux desktop rather than reproducing Windows UI.

## Sources of truth

The built-in profile is defined in `src/lua/design/fluent.lua`. It contains:

- light and dark semantic color schemes
- the Fluent Web brand ramp
- spacing, typography, line-height, and corner-radius scales
- elevation shadows
- component tokens and interaction states

`src/lua/ui.lua` contains only generic theme resolution and widget mechanics.
Native defaults in `src/ui/types.zig` mirror the built-in profile for widgets
created without a Lua theme. Keep those defaults synchronized when changing
the profile.

The current compact desktop baseline uses 14px/20px body text, 32px controls,
4px control radii, and Fluent overlay scrollbars. These are Keywork profile
decisions, not requirements imposed on applications.

## Using and customizing the theme

Applications should consume semantic roles such as `background`, `surface`,
`text`, `text_secondary`, `border`, `fill`, `accent`, and `danger`. Prefer
these roles over a particular ramp step so light and dark schemes remain
coherent.

Use `kw.theme_data` to derive a profile and `kw.resolve_theme` to select its
light or dark scheme:

```lua
local theme_family = kw.theme_data({
    schemes = {
        dark = {
            colors = {
                brand_background = 0xff7c3aed,
            },
        },
    },
    components = {
        button = {
            radius = 6,
        },
    },
})

local theme = kw.resolve_theme(theme_family, context)
```

Overrides are deep-merged with the built-in profile. Color values may refer
to other tokens by name; resolution rejects missing or cyclic aliases.

## Icons

Keywork packages the complete Fluent System Icons set as the `Keywork` XDG
icon theme. Upstream names remain available, including explicit variants such
as `search_20_regular` and `search_20_filled`. Curated Linux names such as
`system-search`, `network-wireless-signal-good`, and `audio-volume-high` are
provided as aliases.

Use regular monochrome icons for passive controls and status indicators. Use
filled icons to communicate selection, an engaged mode, or emphasis; do not
switch variants merely for hover. Application and tray icons should retain
the artwork supplied by their desktop entry or protocol.

The theme inherits `Adwaita` and `hicolor` so application and MIME icons keep
working. `KEYWORK_ICON_THEME` and then `GTK_ICON_THEME` override the default.

The icon package and its content hash are pinned in `build.zig.zon`. Normal
builds generate the theme deterministically in the Zig cache and install it
under `share/icons/Keywork`; generated icons are not checked into the
repository.
