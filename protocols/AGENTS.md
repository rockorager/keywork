# AGENTS.md

The root repository guidance applies here.

## Wayland protocol ownership

- Keep every checked-in Wayland protocol XML file under `wayland/`, regardless
  of whether it has one or several Keywork consumers.
- Keep byte-for-byte external snapshots under `wayland/upstream/`.
- Keep adapted and first-party Wayland schemas directly under `wayland/` and
  document their behavioral owner and provenance in `README.md`.
- Do not put non-Wayland product interfaces here. Keep contracts such as the
  compositor Varlink control interface with the component that owns them.
- Never edit an upstream snapshot in place. Replace it from a pinned upstream
  revision and update `README.md` with its source, revision, SHA-256, license,
  snapshot status, and consumers.
- Validate every consuming build path when replacing or relocating a protocol.
  Centralized storage does not change behavioral ownership or permit source
  imports between consumers.
