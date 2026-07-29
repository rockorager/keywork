# AGENTS.md

The root repository guidance applies here.

## Shared protocol ownership

- Keep only byte-for-byte external protocol snapshots with multiple active
  Keywork consumers in this component.
- Do not put first-party interfaces or single-product compatibility schemas
  here. Keep those with the component that owns their behavior.
- Never edit an upstream snapshot in place. Replace it from a pinned upstream
  revision and update `README.md` with its source, revision, SHA-256, license,
  snapshot status, and consumers.
- Validate every consuming build path when replacing or relocating a shared
  protocol. A shared file is one source contract, not permission for source
  imports between its consumers.
