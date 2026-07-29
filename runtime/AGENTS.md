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
- Keep tests inline and ensure the runtime test roots, including
  `src/main.zig`, remain registered in the root build's `test` step.

During build migration, use `zig build test` from this directory to verify the
unchanged component build. Use the root task once the root build graph lands.
