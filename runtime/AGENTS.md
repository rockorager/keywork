# AGENTS.md

The root guidance applies here. Read `VISION.md` for Keywork's product model
and design priorities.

## Runtime ownership

- Keep the runtime useful as a general Wayland application platform. Do not
  add shell policy or compositor implementation details to its APIs.
- Treat Lua-facing declarations as public contracts. Keep native bindings,
  Lua modules, examples, and `types/` information synchronized when an API
  changes.
- Fix runtime pain discovered by the shell here rather than adding a shell
  workaround. Record unresolved consumer pain in `../shell/NOTES.md`.
- Keep tests inline and ensure `keywork-runtime` and the Lua executable rooted
  at `src/main.zig` remain registered as separate roots in the repository test
  graph.
- Consume `keywork-ui` and `keywork-ui-engine` by name; never reach into
  `../ui/` with relative source imports.
- The current Lua nesting is transitional. Keep `app/`, `backend/`,
  `graphics/`, and `linux/` free of Lua imports. Lua consumes their public
  declarations through `keywork-runtime`, never through relative source
  paths.
- New native runtime APIs must not require Lua state or LuaJIT types. Put
  language-specific adaptation in `lua/` and express native host interaction
  through typed contracts.
