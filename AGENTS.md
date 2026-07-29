# AGENTS.md

Read `ARCHITECTURE.md` before changing component boundaries or dependencies.
Read `VISION.md` before changing Keywork's product model or design priorities.
Read `DESIGN.md` before changing the built-in visual system. More specific
`AGENTS.md` files under `src/` add component-local rules.

## Monorepo boundaries

- Keep loop, UI, runtime, Lua, compositor, shell, and Wayland protocol
  ownership aligned with `ARCHITECTURE.md`.
- Keep implementation components as direct children of the repository-wide
  `src/` tree. Do not add a second component-local `src/` directory.
- Treat the dependency graph in `ARCHITECTURE.md` as authoritative.
- Native UI and runtime modules must compile without LuaJIT. Lua may consume
  their public contracts; they must never import Lua source.
- Relative Zig imports are allowed within one cohesive module. Cross-module
  and cross-component imports must use named modules wired in root
  `build.zig`; never reach through another component with relative paths.
- Treat module roots and their public declarations as API boundaries. Do not
  expose implementation directories to make a single consumer convenient.
- Do not create a generic shared-code directory. Promote code only when it has
  multiple real consumers, a coherent responsibility, and a clear owner.
- Keep every checked-in Wayland XML file and its provenance under
  `protocols/wayland/`, including single-consumer and first-party compatibility
  schemas. Centralized storage does not change the component that owns its
  behavior.
- Keep non-Wayland product contracts with their product. In particular, the
  compositor Varlink control interface remains compositor-owned.

## Build system ownership

- Root `build.zig` and `build.zig.zon` are the source of truth for all Zig
  modules, dependencies, artifacts, tests, generated bindings, and installs.
- Build graph construction must not execute system dependency probes. Attach
  checks and generators to the artifacts or steps that need them so focused
  component commands remain isolated.
- Run Zig build, test, and formatting steps from the repository root. There
  are no component-local Zig build graphs.
- Files under `build/` may organize root build logic but are not product
  modules.
- `zig build` is the only repository task entry point. Keep native shell
  modules, C/Wayland code generation, Lua checks, and installation in that
  graph rather than adding a second task runner.
- Put substantial procedural repository automation in `scripts/` rather than
  embedding shell programs in build configuration.
- Zig 0.16 is a prerequisite. Do not add automatic compiler or system package
  installation without an explicit toolchain policy change.

## Zig development

Use `zigdoc` to discover current APIs for the Zig standard library and
third-party dependencies before coding.

Examples:

```sh
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc vaxis.Window
```

Use current Zig 0.16 patterns:

```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);

var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

For buffered output:

```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};
try writer.interface.print("hello {s}\n", .{"world"});
```

For JSON output:

```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};

var json_writer: std.json.Stringify = .{
    .writer = &writer.interface,
    .options = .{ .whitespace = .indent_2 },
};
try json_writer.write(value);
```

For allocating output:

```zig
var writer: std.Io.Writer.Allocating = .init(allocator);
defer writer.deinit();
try writer.writer.print("hello {s}", .{"world"});
const output = try writer.toOwnedSlice();
```

## Zig style

- Use `camelCase` for functions and methods, lower-case `snake_case` for
  variables, parameters, and constants, and `PascalCase` for types, structs,
  and enums.
- Prefer `const value: Type = .{ .field = item };` over
  `const value = Type{ .field = item };`.
- Pass allocators explicitly and use `errdefer` for cleanup on error.
- Keep tests inline with the code they cover and register their module roots in
  the root build's test step.

### Files and types

- Treat every `.zig` file as a namespace. Make the file itself a type only
  when its root represents one primary stateful abstraction with fields and
  methods.
- Name a file-backed type `PascalCase.zig`, import it directly, and begin it
  with an optional `//!` container doc followed by
  `const ConcreteType = @This();`. Prefer the concrete name over `Self`.
- Use lower-case `snake_case.zig` for namespace modules containing related
  free functions, constants, multiple peer types, or package facades.
- Do not put a sole `pub const Widget = struct { ... };` in `Widget.zig`; the
  file root already provides that container. Do not create file-backed types
  merely to enforce one type per file.
- Preferred file order is container documentation when useful, the
  file-backed type alias when applicable, imports and local aliases, then a
  scoped logger.

### Comments and documentation

- Use `//!` to explain a nontrivial root namespace or file-backed type, its
  conceptual model, and major invariants.
- Use `///` for declaration contracts when names and signatures do not convey
  ownership, lifetime, allocation, pointer invalidation, errors, nullability,
  units, ranges, thread safety, side effects, or preconditions.
- Use `//` for rationale, invariants, workarounds, and non-obvious algorithm
  phases. Do not narrate syntax or restate code.
- Keep comments accurate. Delete stale or redundant comments instead of
  expanding them.

### Cohesion and file size

- Cohesion, not line count, determines when to split a file. Treat roughly
  1,000 hand-written lines as a prompt to look for a cohesive extraction and
  roughly 2,000 as exceptional, not as hard limits.
- Extract independently nameable responsibilities with their own invariants,
  such as a subordinate type, parser, formatter, backend, or pure algorithm.
- Keep a large cohesive type together when splitting would add forwarding
  APIs or obscure invariants. Generated code, data tables, and compatibility
  snapshots are exempt.

## Safety and verification

- Add assertions at meaningful API boundaries and state transitions; avoid
  trivial assertions.
- Keep functions small and push pure computation into helpers.
- Run the narrowest relevant formatter, test, or check for the components
  touched. Cross-component contract changes require validation on both sides.

## Licensing

- Keywork code is MIT-licensed. Vendored protocols and adapted reference
  material must have permissive licenses and recorded provenance.
- Do not inspect, copy, or adapt GPL-licensed compositor implementations.
