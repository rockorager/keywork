# AGENTS.md

The root guidance applies here. Read `../../VISION.md` for Keywork's product
model and design priorities.

## Runtime ownership

- Keep the runtime useful as the general Wayland host platform behind Lua
  applications. Do not add shell policy or compositor implementation details
  to its APIs.
- Fix runtime pain discovered by the shell here rather than adding a shell
  workaround.
- Keep tests inline and ensure `keywork-runtime` remains registered as its own
  root in the repository test graph.
- Consume `keywork-ui` and `keywork-ui-engine` by name; never reach into
  `../ui/` with relative source imports.
- Keep `app/`, `backend/`, `graphics/`, and `linux/` free of Lua imports. Lua
  consumes their public declarations through `keywork-runtime`.
- New native runtime APIs must not require Lua state or LuaJIT types. Put
  language-specific adaptation in `../lua/` and express native host
  interaction through typed contracts.
- Treat exported Zig declarations as repository-internal host contracts, not
  a supported application SDK. Application-facing lifecycle, state, and
  tooling APIs belong to Lua; do not broaden native APIs solely for external
  application authoring.
