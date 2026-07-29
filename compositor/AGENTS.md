# AGENTS.md

The root Zig, safety, documentation, module-boundary, and licensing guidance
applies here.

## Command Surfaces

- Keep user-facing compositor commands synchronized across configuration
  keybindings, the Varlink interface and server dispatch, and `keyworkctl`
  parsing, help, and calls. Update tests for every affected surface.
- Follow https://systemd.io/VARLINK/ for Varlink interfaces: use
  lower-camel-case field names, string enums, and meaningful interface and
  declaration documentation.
- Keep tests inline and ensure compositor tests rooted at
  `src/compositor/main.zig`, Varlink tests, renderer checks, and `keyworkctl`
  tests remain reachable from the root build.

## Protocols

- Keep first-party compositor protocols and interfaces in this component.
- When changing vendored or adapted Wayland XML, update its provenance,
  revision, and SHA-256 metadata. Until shared protocols are elevated, that
  metadata lives in `protocol/README.md`.
