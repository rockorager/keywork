# AGENTS.md

The root Zig, safety, documentation, and module-boundary guidance applies
here. Read `../DESIGN.md` before changing the built-in visual system.

## UI ownership

- `keywork-ui` owns platform-neutral widgets, types, layout, painting, hit
  testing, display lists, and the render-backend contract.
- `keywork-ui-engine` owns retained-tree lifecycle, reconciliation, input,
  focus, and rendering orchestration around `keywork-ui`.
- Neither module may depend on the event loop, native runtime, Lua, Wayland,
  or a concrete rendering backend. Platform and host integration belongs in
  consumers of their public contracts.
- The engine imports `keywork-ui` by module name. Code outside these modules
  must do the same rather than reaching into `ui/src` or `ui/engine`.
- `lib/linebreak` is an implementation module owned by UI text layout. Keep
  its Unicode data and license provenance with it.
- Keep native widget defaults synchronized with the built-in profile in
  `../DESIGN.md`.
- Keep tests inline and register `keywork-ui`, `keywork-ui-engine`, and the
  line-breaking module as separate roots in the repository test graph.
