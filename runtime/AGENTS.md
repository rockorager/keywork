# AGENTS.md

The root guidance applies here. Read `VISION.md` for Keywork's product model
and design priorities. Read `DESIGN.md` before changing the built-in visual
system.

## Runtime ownership

- Keep the runtime useful as a general Wayland application platform. Do not
  add shell policy or compositor implementation details to its APIs.
- Treat Lua-facing declarations as public contracts. Keep native bindings,
  Lua modules, examples, and `types/` information synchronized when an API
  changes.
- Fix runtime pain discovered by the shell here rather than adding a shell
  workaround. Record unresolved consumer pain in `../shell/NOTES.md`.
- Keep native widget defaults synchronized with the built-in profile as
  described in `DESIGN.md`.
- Keep tests inline and ensure `keywork-ui`, `keywork-ui-runtime`, and the
  executable runtime rooted at `src/main.zig` remain registered in the root
  build's `test` step.
- Code outside `keywork-ui` and `keywork-ui-runtime` must import those modules
  by name. Do not reach into their source trees from application, backend,
  graphics, or Lua code.
- The current UI and Lua nesting is transitional. Do not add new imports from
  `app/`, `backend/`, `graphics/`, or `linux/` into `lua/`; the existing
  executable lifecycle edges are migration inventory, not precedent.
- New native runtime APIs must not require Lua state or LuaJIT types. Put
  language-specific adaptation in `lua/` and express native host interaction
  through typed contracts.
