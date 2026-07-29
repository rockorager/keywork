# Shared Wayland protocol provenance

This directory contains byte-for-byte snapshots of external Wayland protocols
used by multiple Keywork components. It is deliberately not a home for
first-party interfaces, locally adapted schemas, or protocols with one active
consumer; those remain with their owning component.

## Upstream snapshots

| File | Consumers | Upstream source | Revision | SHA-256 | License | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `wayland/wlr-layer-shell-unstable-v1.xml` | runtime, compositor | [wlr-protocols `unstable/wlr-layer-shell-unstable-v1.xml`](https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/2b8d43325b7012cc3f9b55c08d26e50e42beac7d/unstable/wlr-layer-shell-unstable-v1.xml) | `2b8d43325b7012cc3f9b55c08d26e50e42beac7d` | `87e0b9c837aecd6977f76f3c47d73088b7159871f5d979dc1840f6cadb5e2ed8` | MIT/X11-style, embedded | byte-for-byte upstream snapshot |
| `wayland/wlr-output-power-management-unstable-v1.xml` | shell, compositor | [wlr-protocols `unstable/wlr-output-power-management-unstable-v1.xml`](https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/9b9479f9a3f982a811e483b45be3fd4ad726999c/unstable/wlr-output-power-management-unstable-v1.xml) | `9b9479f9a3f982a811e483b45be3fd4ad726999c` | `7ebd98f3449d246a57829e4b4dd9fbc3ef98e3dd42fa94ea102f14f490eb20de` | MIT/Expat-style, embedded | byte-for-byte upstream snapshot |

Verify the committed snapshots after an update:

```sh
sha256sum protocols/wayland/*.xml
```
