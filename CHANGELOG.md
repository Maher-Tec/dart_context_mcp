# Changelog

## 0.10.1

- Rewrote the README: badges, a one-line pitch, and quick start up top;
  deep details (full benchmark methodology, dependency graph feature list,
  indexing/limitations) moved into collapsible sections. Quick start now
  uses `dart pub global activate` + the plain `dart_context_mcp`
  executable instead of `dart run bin/...`, matching how someone actually
  installs this from pub.dev. Also fixed a chart bug where the subtitle
  and a bar's value label overlapped into garbled text.
- Replaced a personal local path in the old README's CLI examples with a
  generic placeholder.
- pub.dev package-score fixes: shortened the pubspec description (was over
  the 180-character limit), widened the `analyzer` constraint so a newer
  Dart SDK can resolve a newer analyzer version, added dartdoc comments
  across the public API (constructors, fields, and methods that previously
  had none), and added a runnable `example/`.

## 0.10.0

- Added an optional `format: json` to `overview`, `context`, `impact`, and
  `query` (CLI `--format json`, MCP tool argument `format`). The default
  stays the existing compact text; JSON returns the same underlying data
  (symbol details, references, risk level, folder breakdown, hubs, ...) as
  a single object, for a caller that needs to read one specific field
  programmatically rather than re-parsing prose whose layout it would
  otherwise have to guess at. Both formats are produced from the same
  computed data, so they can't drift apart from each other.
- Verified: JSON mode round-trips correctly through the real MCP server
  (not just the CLI) against a real project, and all existing text-format
  tests pass unchanged, confirming the default output didn't change at all.

## 0.9.1

- Fixed inconsistent path formatting on Windows: `file.path`/`symbol.path`
  (used by `symbols`, `context`, `impact`, `query`, `overview`) were stored
  with the OS-native separator (`lib\main.dart`), while `graph` normalized
  to posix internally (`lib/main.dart`) - so the same file was spelled two
  different ways depending on which tool answered it, which breaks a naive
  string comparison an agent might do across two tool calls. Every path is
  now stored and displayed posix-style everywhere, on every platform.
  Reusing the same file-path resolution logic across two different tool
  outputs no longer requires normalizing them yourself first.
  Normalizing at the source meant also updating the index staleness check,
  which compares a freshly-scanned (still OS-native, from directory
  listing) file list against the indexed paths - without that companion
  fix, every project on Windows would have looked "stale" on every single
  call and silently re-indexed from scratch every time.

## 0.9.0

- Added `overview` (CLI command / `dart_overview` MCP tool): the recommended
  first call on an unfamiliar project. One compact report covering
  dependencies (and whether it's a Flutter app or a plain Dart package),
  the Dart SDK constraint, a `lib/` folder breakdown (file/symbol counts
  per folder), the entry point's (`lib/main.dart`) own imports, and the
  most depended-upon files (fan-in hubs, reusing the same import-graph
  math as `graph`) - meant to replace the handful of exploratory reads
  (`pubspec.yaml`, `lib/main.dart`, poking around folders) an agent would
  otherwise burn tokens on just to get oriented in a project it's never
  seen before.
- Verified against a real Flutter project (HoloValue): correctly identified
  it as a Flutter app from its `flutter:` dependency, listed all 19
  dependencies, and correctly named its real fan-in hubs (a domain entity
  imported by 21 files, a theme file imported by 16).

## 0.8.1

- Dogfooded the actual MCP server process (not just the CLI or the unit
  test's in-process dispatch) against a real Flutter project: spawned
  `dart run bin/dart_context_mcp.dart mcp` and drove it over real stdio with
  a JSON-RPC client harness. Confirmed: warm in-memory index reuse across
  calls (~50ms per call after the initial index vs. the one-time cold
  build), a malformed JSON-RPC line doesn't crash the server or corrupt the
  stream (correctly answers with a spec-compliant `id: null` parse error and
  keeps serving later requests), a nonexistent project root returns a clean
  error instead of a stack trace, and an unknown tool/method name is
  rejected cleanly.
- Fixed `serverInfo.version` in the `initialize` response: it was hardcoded
  to `0.2.0` from early development and had drifted three releases behind
  the actual package version, which a real MCP client could use for
  compatibility checks. Added a test that reads `pubspec.yaml` and asserts
  the two stay in sync, so this can't silently drift again.

## 0.8.0

- Reduced false positives in `dart_context`/`dart_impact`/`dart_query`'s
  text-based reference matching (a known limitation - these tools don't
  resolve types through the analyzer):
  - A mention inside a `//` comment or a plain string literal is no longer
    counted as a reference (string interpolation - `$name` / `${expr}` - is
    still counted, since that's real code). Line-based, so multi-line
    strings/comments aren't handled - a heuristic improvement, not a fix.
  - When a name is declared more than once in the project (two unrelated
    classes both called `Item`), references are now scoped to the
    declaring file plus files that directly import it, instead of mixing
    every same-named declaration's references together project-wide.
    Doesn't follow transitive re-exports.
  - Extracted the import-URI-to-file-path resolution logic (previously
    private to the dependency graph) into `lib/src/import_resolver.dart` so
    both the graph and this scoping share one implementation.
  - Verified on a real Flutter project (not just synthetic fixtures) and
    with two new tests covering the comment/string and ambiguous-name
    cases directly.

## 0.7.0

- Visual polish pass (phase 3, completing the three-part graph upgrade):
  - Nodes now glow: circular-dependency nodes pulse red, the focused/hovered
    node lights up, and high fan-in/fan-out "hub" nodes get a gentle
    constant breathing glow, so importance reads at a glance before you
    interact with anything.
  - Import edges carry a small dot that continuously marches from source to
    target along the same curve the edge is drawn on - a lightweight motion
    cue reinforcing import direction (cycle edges' dots move faster and
    redder, matching their highlight color).
  - Layout switches, expand/collapse, and force-layout settling now animate
    into place (nodes ease toward their new position over a few frames)
    instead of snapping instantly - dragging a node is unaffected and still
    tracks the cursor with no lag.
  - All animation is driven by the existing per-frame render loop (no new
    timers), and pulse/flow phase is derived from each node/edge's id so
    nothing resyncs into a robotic unison when the graph rebuilds.

## 0.6.0

- Added a layout picker (phase 2 of the three-part graph upgrade): the
  dependency graph now offers Layered / Force / Radial as switchable
  layouts, matching the layout toggle in tools like GitNexus, instead of
  only the columns-by-import-depth view.
  - **Force**: classic force-directed placement (all-pairs repulsion + edge
    springs + weak centering). Unlike the layered algorithm, it doesn't
    force one axis to track import depth, so it doesn't degrade on
    chain-shaped graphs.
  - **Radial**: concentric rings by BFS distance from the graph's entry
    points (files nothing imports), spiraling outward ring by ring.
  - This directly fixes the layered layout's worst case: a long linear
    import chain (each file importing exactly one predecessor) lays out as
    one node per column, rendering as a visually flat line no matter how
    far `fitView()`'s scale floor (0.5.0) lets you zoom in - that's the
    layered algorithm doing exactly what it's designed to do (columns =
    depth), not a bug, but it looks broken for chain-shaped real projects.
    Force and Radial both spread such a graph into a compact, roughly
    square 2D shape instead (verified: a 60-file synthetic chain that
    rendered 15340 world-units wide by 0 tall in Layered comes out ~260x246
    in Force and ~16400x16900 in Radial - both a legible aspect ratio close
    to 1:1).
  - Fixed a bug caught while building Radial: BFS rings with exactly one
    node (the common case for a chain) all landed at the same angle,
    producing a straight line through the center instead of a spiral -
    rings now get a golden-angle rotation offset so this degenerate case
    spreads out too.

## 0.5.0

- Added a symbol-level graph, in the spirit of tools like GitNexus/Sourcetrail:
  the `graph` output now goes past files. Double-click a file to reveal its
  classes/mixins/enums/extensions/functions; double-click a class to reveal
  its methods/fields/constructors — each colored by kind (Contains edges for
  structural nesting, Imports edges for file dependencies, matching real
  code-graph tools' node/edge type distinction). Single-click still focuses
  a node (imports/importers or contains, depending on type) without
  expanding it. New `buildSymbolGraph()` in `lib/src/symbol_graph.dart`
  reuses the indexer's already-parsed symbol table (constructors, enum
  constants, typedefs, etc.), so it's zero extra parsing cost.
- This is phase 1 of a three-part upgrade (symbol graph now; a switchable
  layout picker — force/sequential/radial — and a broader visual-polish pass
  are follow-ups).
- Fixed a layout bug surfaced by testing the above: when many same-layer
  nodes shared a single collapsed target (e.g. 15 files all importing one
  folder), the row-spacing force and the edge-straightening force fought
  each other and nodes collapsed to ~0.5px apart instead of the intended
  46px, making labels unreadable. Replaced the soft spring-based spacing
  with a hard per-iteration separation pass (recentered so it doesn't drift
  the layer), verified with real coordinate measurements before and after.
- Fixed a second, distinct layout bug: fully expanding a deep import chain
  (a file importing exactly one predecessor, N layers deep) produces a
  graph tens of thousands of world-units wide with almost no height.
  `fitView()` used one uniform scale to fit both dimensions, so a very wide
  graph forced the scale down so far it crushed even correctly-spaced rows
  into an unreadable sliver. Added a scale floor (0.3) so "Fit view"/"Expand
  all" stop shrinking past a legible zoom level and let you pan for the
  rest, instead of always cramming the whole graph onto one screen -
  verified the same scenario now holds a ~14px row gap instead of ~5px.

## 0.4.0

- Reworked the `graph` output's layout from a generic force-directed blob to
  a leveled/layered diagram (columns by import depth, like a real dependency
  graph), with automatic folder-collapsing on large projects (>40 files
  default to one level of folders, click to drill in) so it stays legible
  instead of degrading into a hairball.
- Node size now reflects fan-in (heavily-imported "hub" files/folders stand
  out), added hover tooltips, and Fit view / Reset layout / Export PNG
  controls.
- Fixed two rendering bugs found during review: the page title placeholder
  wasn't substituted everywhere it appeared, and a circular import's two
  opposite-direction edges rendered as a single overlapping line instead of
  two visible curved arrows.
- Cycle detection now runs fresh on whatever graph is currently visible
  (files, or collapsed folders) instead of only reusing the file-level
  result: a folder-level circular dependency with no single-file cycle
  (e.g. `screens` imports `models` imports `services` imports `widgets`
  imports back into `screens`) is now caught and highlighted red, and a
  real file-level cycle fully hidden inside one collapsed folder is flagged
  amber ("contains a circular import internally") instead of silently
  disappearing.

## 0.3.0

- Added a `graph` command / `dart_graph` MCP tool that generates a
  self-contained, offline HTML visualization of the project's file import
  graph: force-directed layout, pan/zoom, drag, search, click-to-focus a
  file's imports/importers, and automatic circular-import detection (cycles
  are highlighted in red and listed in a sidebar).

## 0.2.0

- Added a real MCP stdio server (`dart_context_mcp mcp`) exposing `dart_index`,
  `dart_symbols`, `dart_context`, `dart_impact`, and `dart_query` as tools.
- Indexer now captures constructors (`Class.new` / `Class.named`), enum
  constants, and typedefs, which were previously invisible to every command.
- Fixed index staleness detection: adding or removing a `.dart` file now
  triggers a rebuild (previously only edits to already-indexed files did).
- Multi-line and named-parameter signatures are no longer truncated.
- The MCP server keeps one index per project root in memory across calls,
  with an in-memory file-content cache, instead of re-reading every source
  file from disk on every call.
- Split the single-file implementation into `lib/src/` modules
  (`model`, `file_scan`, `indexer`, `code_index`, `cli`, `mcp_server`).

## 0.1.0

- Initial Dart/Flutter project indexer.
- Added compact `index`, `symbols`, `context`, `impact`, and `query` commands.
- Added generated-file skips for Flutter localization and common Dart generated files.
