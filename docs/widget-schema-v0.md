# Widget Schema v0

Widget Schema is the low-level document format consumed by
`keywork_surface_submit`. Official bindings should expose typed widgets and
keep this encoding private. All integers and IEEE-754 `f32` bit patterns are
little-endian.

The submitted bytes are borrowed only for the call. A successful submission
returns a nonzero document ID and installs a decoded, library-owned copy.

## File layout

```text
header (48 bytes)
widget table (widget_count × 80 bytes)
child-index table (child_count × u32)
shortcut-binding table (binding_count × 16 bytes)
string table (string_size bytes)
```

There is no alignment padding. Widget records form one rooted tree. Every
record must be reachable from the root exactly once; cycles, shared records,
and unreachable records are rejected. An encoder must emit a distinct record
for every occurrence even when host-language widget values are reused.

### Header

| Offset | Type | Meaning |
|---:|---|---|
| 0 | `u8[4]` | magic `KWW0` |
| 4 | `u16` | widget format version, `0` |
| 6 | `u16` | header size, `48` |
| 8 | `u32` | exact total byte length |
| 12 | `u32` | root widget index |
| 16 | `u32` | widget count |
| 20 | `u32` | child-index count |
| 24 | `u32` | shortcut-binding count |
| 28 | `u32` | string-table byte length |
| 32 | `u32[4]` | reserved, write zero |

### Widget record

Every widget occupies 80 bytes. Unused fields and unknown flag bits must be
zero. Strings are UTF-8 byte ranges in the string table and are not
NUL-terminated. Colors are `0xAARRGGBB`.

| Offset | Type | Name |
|---:|---|---|
| 0 | `u16` | tag |
| 2 | `u16` | flags |
| 4 | `u32` | first child-table index |
| 8 | `u32` | child count |
| 12 | `u32` | key string offset |
| 16 | `u32` | key string length |
| 20 | `u32` | primary string offset |
| 24 | `u32` | primary string length |
| 28 | `u64` | handler or resource ID (`id0`) |
| 36 | `u32` | `a` (`f32` bits when documented as a float) |
| 40 | `u32` | `b` |
| 44 | `u32` | `c` |
| 48 | `u32` | `d` |
| 52 | `u32` | `color0` |
| 56 | `u32` | `color1` |
| 60 | `u32` | `extra0` |
| 64 | `u32` | `extra1` |
| 68 | `u32` | `extra2` |
| 72 | `u32` | `extra3` |
| 76 | `u32` | reserved, write zero |

Flag bit 15 (`0x8000`) is common to every tag. When set, `key offset/length`
contains that widget's reconciliation key. Otherwise both key fields must be
zero. Keys must be unique among the immediate children of each row or column.
All remaining flag bits are tag-specific.

A child range addresses the child-index table; each `u32` entry identifies a
widget-table record.

## Widget tags

The `a`–`d` fields below are `f32` unless stated otherwise.

| Tag | Widget | Encoding |
|---:|---|---|
| 1 | text | primary string=value; flag 0=`color0` present; flag 1=`a` font size present; `extra0`=text role |
| 2 | row | child range; `a`=gap; `extra0`=cross alignment; `extra1`=main alignment |
| 3 | column | same as row |
| 4 | container | one child; `color0`=background; flag 0=`color1` border present; `a`=border width; `b`=radius; `c`=minimum width; `d`=minimum height; `extra0/1`=horizontal/vertical alignment |
| 5 | padding | one child; `a/b/c/d`=left/top/right/bottom |
| 6 | spacer | no children; `a`=positive flex |
| 7 | flexible | one child; `a`=positive flex; `extra0`=fit |
| 8 | gesture detector | one child; primary string=interaction ID; `id0`=nonzero handler ID; flag 0=`color0` hover background present; flag 1=activate on press rather than release |
| 9 | center | one child |
| 10 | sized box | one child; flags 0/1 indicate `a/b` width/height; `c/d`=minimum width/height; flags 2/3 indicate `extra0/1` maximum width/height (`f32` bits) |
| 11 | image | no children; `id0`=nonzero resource ID; flags 0/1 indicate `a/b` width/height; flag 2=`color0` A8 tint present |
| 12 | icon | no children; primary string=icon name; `a`=positive size; flag 0=`color0` tint present |
| 13 | single child scroll view | one child; primary string=interaction ID; `extra0`=scroll axes |
| 14 | focus | one child; primary string=focus ID; `id0`=optional focus-change handler; flags 0/1/2=autofocus/skip traversal/can request focus |
| 15 | focus scope | one child; primary string=scope ID; flag 0=modal |
| 16 | text field | no children; primary string=interaction and focus ID; `id0`=optional change handler; `extra0/1`=value string offset/length; `extra2/3`=placeholder string offset/length; flag 0=autofocus |
| 17 | shortcuts | one child; `extra0/1`=first binding/binding count |
| 18 | default text style | one child; flag 0=`color0` present; flag 1=`a` font size present |
| 19 | filled button | one child; primary string=interaction ID; `id0`=handler ID, or zero for disabled; flag 0=activate on release rather than the default press; surface, hover, pressed, focused, disabled, foreground, padding, and radius states come from the active libkeywork theme |

Enum values are:

- text role: `0=body`, `1=label`, `2=title`
- cross alignment: `0=start`, `1=center`, `2=end`, `3=stretch`
- main alignment: `0=start`, `1=center`, `2=end`,
  `3=space-between`, `4=space-around`, `5=space-evenly`
- container alignment: `0=start`, `1=center`, `2=end`
- flex fit: `0=tight`, `1=loose`
- scroll axes: `0=vertical`, `1=horizontal`, `2=both`

### Shortcut bindings

Each 16-byte shortcut binding contains:

| Offset | Type | Meaning |
|---:|---|---|
| 0 | `u32` | shortcut key |
| 4 | `u32` | reserved, write zero |
| 8 | `u64` | nonzero handler ID |

Shortcut keys are `0=enter`, `1=space`, `2=backspace`, `3=escape`, `4=up`,
and `5=down`.

## Images and icons

Image records reference context-local resources created before submission.
RGBA8 resources use straight-alpha R,G,B,A upload bytes. A8 resources render
as masks and may carry a tint; tinting an RGBA8 resource is invalid. Supplying
only one dimension preserves intrinsic aspect ratio. Documents retain their
resources until retired even after host ownership is released.

Icons are resolved by libkeywork through its context-local XDG icon-theme
service. Missing icons retain square layout and are cached as misses.

## Handlers and document lifetime

Handler IDs are opaque nonzero `u64` values chosen by the binding and scoped
to the submitted document. Keywork never calls a host function from dispatch.
It emits `(surface ID, document ID, handler ID, payload)` events instead:

- filled button, gesture detector, and shortcut: no payload
- focus change: boolean payload
- text field change: UTF-8 text payload

A binding normally keeps a callback registry per document. Events are matched
against both document and handler ID. Replacing a document removes its queued
handler events and later emits `KEYWORK_EVENT_DOCUMENT_RETIRED`; the binding
can then release that document's callback registry. Text event payload bytes
remain valid only until the next `keywork_context_next_event` call.

## Versioning

The widget format version is independent of `KEYWORK_ABI_VERSION`. A decoder
rejects an unknown widget version. C structures carry `struct_size`; changing
an existing entry point in a way that requires a larger structure requires a
new C ABI version.
