# AGENTS.md

The root Zig, safety, documentation, and module-boundary guidance applies
here. Read `../VISION.md` for product priorities and `../DESIGN.md` before
changing the built-in visual system.

## Lua host ownership

- `keywork-lua` owns the LuaJIT adapter, Lua-facing APIs, bundled Lua modules,
  and language-specific FFI. The `keywork` executable owns CLI, Storybook,
  test-command, and script lifecycle.
- Consume the loop, UI, UI engine, and native runtime only through their named
  public modules. Never reach into another component with relative imports.
- Keep native Lua bindings, bundled Lua modules, `types/`, and examples
  synchronized when a Lua-facing contract changes.
- Keep general application-platform behavior in `keywork-runtime`; do not hide
  missing native abstractions in language-specific workarounds.
- Keep `keywork-lua` and the executable lifecycle registered as separate test
  roots. Adapter implementation tests belong to `keywork-lua`; CLI and host
  lifecycle tests belong to the executable root.
- `.emmyrc.json` and `.luafmt.toml` define Lua development tooling for this
  component. Run repository-level build and test commands from the root.
