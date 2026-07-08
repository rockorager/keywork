# Widget system

Keywork's widget model is Flutter's, with the cut point moved down: the
widget, element, and state machinery that Flutter implements in Dart lives
in Zig here. Lua supplies only what must be dynamic — build functions,
state, and handlers. We keep Flutter's nomenclature (`build`,
`createState`, `initState`, `setState`, `didUpdateWidget`, `dispose`,
`key`) and lifecycle so its documentation and instincts transfer;
deviations are deliberate and Lua-idiomatic.

Three trees, two owners:

- Widget tree: plain Lua tables. Immutable configuration, rebuilt freely,
  garbage the moment the reconciler has consumed them.
- Element tree: Zig, persistent. Identity, state, dirty tracking. Holds
  pinned Lua refs (`luaL_ref`) to build functions and state tables.
- Render tree: Zig, persistent. Layout geometry, painting, hit testing.

Putting elements in Zig instead of Lua does not add boundary crossings —
`build` is a Lua closure and gets called across the boundary either way —
and it keeps per-frame garbage out of the Lua heap: only dirty subtrees
allocate widget tables, and they die as soon as reconciliation consumes
them.

## Widgets

A widget is any Lua value satisfying one of three shapes. The interface is
structural, not nominal — having the method makes you a widget:

- **Primitive**: a table produced by a `kw` constructor (`kw.text`,
  `kw.row`, `kw.column`, `kw.padding`, `kw.button`, ...). Maps directly to
  a core render object. The constructors are the public API; the tables
  they produce are an internal format.
- **Stateless composite**: any table with `build(self, ctx) -> widget`.
- **Stateful composite**: any table with `createState(self) -> state`.
  The state table defines `build(state, ctx) -> widget` (required) and
  optionally `initState(state)`, `didUpdateWidget(state, old_widget)`,
  and `dispose(state)`. The engine injects `setState` into the state
  table at mount.

Every widget may carry a `key` for sibling identity. The `ctx` parameter
is the element handle; it exists now so that scoped/inherited data can be
added later without changing the shape of `build`.

The script's return value is the root widget. Nothing about the root is
special: window and application configuration is itself a widget,

```lua
return kw.app {
  app_id = "dev.keywork.LuaCounter",
  title = "Counter",
  width = 480,
  height = 240,
  child = Counter,
}
```

which also gives multi-window a natural future shape — window widgets in
the tree — rather than a bolted-on API.

## Elements and reconciliation

Reconciliation matches new widgets against existing elements per sibling
list, Flutter's rules:

- Primitives match on their type; composites match on their widget
  identity: the metatable if the widget has one, otherwise the identity of
  its `createState`/`build` function.
- `key` overrides positional matching among siblings.
- A match updates the element in place: `didUpdateWidget(state, old)` then
  rebuild. A non-match unmounts the old element (children first, `dispose`
  innermost-out) and mounts the new one (`createState`, `initState`,
  build).

Because composite identity can fall back to function identity, a stateful
widget whose `createState` closure is created inline inside a parent's
`build` gets a fresh identity every rebuild and its state cannot persist.
Define stateful widgets once, at module scope; the engine logs a
state-loss warning when an element with live state is replaced by a
same-shaped widget with a new function identity.

Rebuild propagation is Flutter's: a dirty element rebuilds, its returned
subtree reconciles, and composite children rebuild in turn. The skip
heuristic is also Flutter's `identical()`: if a child position receives
the *same table reference* (`rawequal`) it received last build, the
subtree is unchanged and reconciliation skips it. Hoisting a widget table
into a local is keywork's `const` widget.

`setState(state, fn?)` runs `fn` if given, marks the element dirty, and
schedules a frame. Any number of `setState` calls within one loop
iteration coalesce into at most one rebuild and one submission per surface
per frame.

## Phases

The engine runs a phase flag; every Zig→Lua callback is tagged with the
phase it runs in, and the `kw` API asserts on calls made in the wrong
phase. This replaces the old rule "Lua never runs during dispatch, layout,
or paint" — that was ABI-era defensiveness. The rule now is Flutter's:
callbacks are phase-restricted, not forbidden. Mutation in the wrong phase
is an error (`setState() called during build`), computation is not.

| Zig→Lua callback                          | phase    | Lua may                                      |
| ----------------------------------------- | -------- | -------------------------------------------- |
| event handlers, task resumes, timers      | idle     | anything: `setState`, tasks, IO, window ops  |
| `build`, `initState`, `didUpdateWidget`, `dispose` | build    | read state, construct widget tables          |
| `layout` delegate                          | layout   | `child:layout`, `child:position` only        |
| `paint` recorder                           | paint    | canvas recording only                        |

Wayland dispatch never calls Lua; input becomes semantic events drained at
the loop boundary, as before. The two mid-pipeline entry points — layout
and paint — are pure functions from engine-provided inputs to
engine-consumed outputs, which is what keeps re-entrancy bounded: they
cannot observe or mutate tree state mid-flight.

Lua→Zig entry points, by phase:

- idle: script return of the root widget (startup), `setState`, tasks,
  timers, platform IO.
- build: none (widget tables are returned, not pushed).
- layout: methods on the child handles passed to a layout delegate.
- paint: methods on the canvas passed to a paint recorder.

## Custom widgets at every level

The ladder, top rung first. Rungs 1–3 are Lua; rung 4 is Zig.

**1. Composite widgets** — `build`/`createState`. The 95% case; covered
above.

**2. Custom paint — `kw.custom_paint`.**

```lua
kw.custom_paint {
  paint = function(canvas, size)
    canvas:move_to(0, 0)
    canvas:line_to(size.width, size.height)
    canvas:stroke { width = 2 }
  end,
}
```

The `canvas` records commands into a display list retained by the render
object; the backend replays it at paint time. The recorder runs when the
render object is dirty — newly mounted, resized, or its widget config
changed — never per frame. Compositor-side effects (scrolling, opacity,
transforms) replay the retained list without touching Lua. Hit testing
defaults to the widget's bounds; a `hit_test` callback can be added later
if something needs it.

**3. Custom layout — `kw.custom_layout`.** The RenderBox protocol:
constraints down, sizes up, parent positions children.

```lua
kw.custom_layout {
  layout = function(constraints, children)
    local x = 0
    for _, child in ipairs(children) do
      local size = child:layout(kw.loose(constraints))
      child:position(x, 0)
      x = x + size.width
    end
    return { width = x, height = constraints.max_height }
  end,
  ...,
}
```

The delegate runs synchronously inside engine layout, in the layout phase.
Child handles are valid only for the duration of the call; the engine
asserts each child is laid out exactly once and positioned before return.

**4. Custom render objects — Zig.** For text shaping, GPU resources,
per-frame animation internals: keywork is a Zig library as well as a
runtime binary. An application that needs an engine-level widget compiles
its own binary linking keywork and registers the render object natively.
The registration API is specified when the first real user appears.

**Custom elements are not exposed**, matching Flutter practice: element
behavior (identity, keys, scoped data) is engine machinery. If scoped
inherited data is needed it arrives as an engine feature surfaced through
`ctx`, not as user-defined element types.

## Status

This document is the contract for the element-tree move into the core and
the `kw` module rework. Where code and document disagree, the document
wins. The current table-walker submission path (`surface:submit`) is
interim and is replaced by root-widget return plus engine-side
reconciliation.
