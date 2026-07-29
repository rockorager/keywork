# Protocol provenance

Keywork generates bindings for standard protocols supplied by `zig-wayland`
and for the compositor-owned definitions under `wayland/` and `varlink/`.
This manifest covers files owned by this component; shared snapshots and their
provenance live in [`../../../protocols/`](../../../protocols/README.md). System
protocol files named in the root build remain owned and versioned by the
`zig-wayland` dependency.

`wayland/upstream/` is reserved for byte-for-byte upstream snapshots. Wayland
files directly under `wayland/` are first-party interfaces or documented
adaptations. All committed XML carries a permissive license notice in the file
itself.

## Pristine upstream snapshots

The hashes below were verified against the pinned repository objects. Updating
one of these files means replacing it in full and updating both its revision
and SHA-256 here; local edits belong outside `wayland/upstream/`.

| File | Upstream source | Revision | SHA-256 | License |
| --- | --- | --- | --- | --- |
| `wayland/upstream/input-method-unstable-v2.xml` | [wlroots `protocol/input-method-unstable-v2.xml`](https://gitlab.freedesktop.org/wlroots/wlroots/-/blob/dc3d1530bf58ca68ac81d2a809cc416ff7f71938/protocol/input-method-unstable-v2.xml) | `dc3d1530bf58ca68ac81d2a809cc416ff7f71938` | `99414dbad9458e71aa1fa01bc45f94ca6685787bfcb4d98948f72c1b45b60703` | MIT/Expat-style, embedded |
| `wayland/upstream/wlr-data-control-unstable-v1.xml` | [wlr-protocols `unstable/wlr-data-control-unstable-v1.xml`](https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/92feabdfd77ab141ff76c3a9ce327dcbb8e57b1c/unstable/wlr-data-control-unstable-v1.xml) | `92feabdfd77ab141ff76c3a9ce327dcbb8e57b1c` | `5f10d6bf9bfa9d12266a6f423fb77bbb98e415f6d64fe24680710ffb362a7082` | MIT/X11-style, embedded |
| `wayland/upstream/wlr-foreign-toplevel-management-unstable-v1.xml` | [wlr-protocols `unstable/wlr-foreign-toplevel-management-unstable-v1.xml`](https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/005d69d048ccceb2af3f5b86665821e8fa9a87b8/unstable/wlr-foreign-toplevel-management-unstable-v1.xml) | `005d69d048ccceb2af3f5b86665821e8fa9a87b8` | `4ecc4588858e29fe680a33521e1f22bcf22071d66d1553fe96b4ddec03d591d2` | MIT/X11-style, embedded |
| `wayland/upstream/wlr-gamma-control-unstable-v1.xml` | [wlr-protocols `unstable/wlr-gamma-control-unstable-v1.xml`](https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/29d4a59df8cbbc719fea9fe84689a45569410a86/unstable/wlr-gamma-control-unstable-v1.xml) | `29d4a59df8cbbc719fea9fe84689a45569410a86` | `4065cbc291a80348b7ef311168fbfb5cf245efe977a6dc32211291ef1a9529a1` | MIT/X11-style, embedded |
| `wayland/upstream/wlr-virtual-pointer-unstable-v1.xml` | [wlr-protocols `unstable/wlr-virtual-pointer-unstable-v1.xml`](https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/c11408942e2fb54d41dadb84cdf844331076ae11/unstable/wlr-virtual-pointer-unstable-v1.xml) | `c11408942e2fb54d41dadb84cdf844331076ae11` | `3ff6d540be0bc5228195bf072bde42117ea17945a5c2061add5d3cf97d6bb524` | MIT/Expat-style, embedded |

`input-method-unstable-v2` was proposed to wayland-protocols but never merged;
the pinned wlroots copy is the deployed external protocol, not a
wayland-protocols standard.

## Adapted compatibility schemas

| File | Permissive source | Revision | SHA-256 | Local adaptation |
| --- | --- | --- | --- | --- |
| `wayland/virtual-keyboard-unstable-v1.xml` | [wlroots `protocol/virtual-keyboard-unstable-v1.xml`](https://gitlab.freedesktop.org/wlroots/wlroots/-/blob/5334ee8bfd93b2bfdc077f422b87c2509f04d5d4/protocol/virtual-keyboard-unstable-v1.xml) | `5334ee8bfd93b2bfdc077f422b87c2509f04d5d4` | `b4898f92c27db08c75bb82e9eeec5b179b80a4d6aeb34c26da60b485fca9c450` | Links the keymap format to the core enum and adds the `invalid_keymap_format` protocol error enforced by Keywork. Embedded MIT/Expat-style notice retained. |
| `wayland/wlr-output-management-unstable-v1.xml` | [wlr-protocols version 4 schema](https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/4264185db3b7e961e7f157e1cc4fd0ab75137568/unstable/wlr-output-management-unstable-v1.xml) | `4264185db3b7e961e7f157e1cc4fd0ab75137568` | `0a81c5a49bf60aa0c96d796e5c86adc28700baed4a2c44b8d20b04e70b9b4de2` | Preserves the version 4 request, event, enum, and argument schema while replacing upstream explanatory prose with a concise specification. Embedded MIT/X11-style notice retained. |
| `wayland/wlr-screencopy-unstable-v1.xml` | [wlr-protocols version 3 schema](https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/8b96da0afbf50340d2f078d8601388733de08925/unstable/wlr-screencopy-unstable-v1.xml) | `8b96da0afbf50340d2f078d8601388733de08925` | `062c2410790ec33f98f3ba704a9cd1d5f3e049a714cae07f31489346cd2a0ed9` | Wire-identical version 3 schema with comment removal and paragraph reflow only. Embedded MIT/Expat-style notice retained. |

## First-party interfaces

- `wayland/gtk-shell.xml` is an independently authored, MIT-licensed compatibility
  declaration of the public GTK shell wire ABI through interface version 5.
  It intentionally contains no copied upstream descriptions. Compatibility is
  checked against GTK's version 5 interface at revision
  [`0c7b1431d7e1157c389d3cf1e895eaf5aaaa62fb`](https://gitlab.gnome.org/GNOME/gtk/-/blob/0c7b1431d7e1157c389d3cf1e895eaf5aaaa62fb/gdk/wayland/protocol/gtk-shell.xml).
  Its SHA-256 is
  `81d03940d70f1ca8e92201b60712f39d2576b4fbb47c169f45f58921d86840fa`.
- `varlink/dev.rockorager.keywork.compositor.varlink` is Keywork's first-party control
  interface and is covered by the repository MIT license.

To verify the committed XML after an update:

```sh
find protocol -type f -name '*.xml' -print0 | sort -z | xargs -0 sha256sum
```
