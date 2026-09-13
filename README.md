# dart_context_mcp

<p>
  <a href="https://pub.dev/packages/dart_context_mcp"><img src="https://img.shields.io/pub/v/dart_context_mcp.svg" alt="pub package"/></a>
  <a href="https://github.com/Maher-Tec/dart_context_mcp/actions/workflows/ci.yml"><img src="https://github.com/Maher-Tec/dart_context_mcp/actions/workflows/ci.yml/badge.svg" alt="CI"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"/></a>
  <a href="https://modelcontextprotocol.io"><img src="https://img.shields.io/badge/MCP-server-6366f1.svg" alt="MCP server"/></a>
</p>

**Give your AI coding agent a map of your Dart/Flutter project instead of
letting it grep and guess.**

A local CLI + [MCP](https://modelcontextprotocol.io) server that indexes a
Dart/Flutter project and answers the questions an agent normally burns
tokens finding out for itself: what does this project depend on, where is
this symbol, what breaks if I change it, where does X happen. Everything
local — no network calls, no code ever leaves your machine.

## Quick start

```bash
dart pub global activate dart_context_mcp
dart_context_mcp overview path/to/your_flutter_project
```

`overview` is the best first call on any project — dependencies, folder
layout, entry point, and the files everything else depends on, in one
compact call.

**As an MCP server** (Claude Code, Claude Desktop, Cursor, or any MCP client):

```json
{
  "mcpServers": {
    "dart_context": {
      "command": "dart_context_mcp",
      "args": ["mcp"]
    }
  }
}
```

That exposes `dart_overview`, `dart_index`, `dart_symbols`, `dart_context`,
`dart_impact`, `dart_query`, and `dart_graph` as tools your agent can call
directly.

## Why

![Bytes read to accomplish the same task: task 1 goes from 29.4 KB to 4.3 KB (6.9x smaller), task 2 goes from 53.5 KB to 4.0 KB (13.3x smaller)](doc/token_efficiency.svg)

Two real tasks, done two ways, on the same 46-file Flutter project — plain
`grep` + reading full files, vs. this tool. **6.9x–13.3x fewer bytes** for
the same outcome, because the tool already knows the project structure
instead of re-deriving it from scratch on every question.

<details>
<summary>Full methodology, both tasks, and honest caveats</summary>

### Task 1 — understand a feature and its blast radius

"Understand the Collection feature and what breaks if `CollectionState`
changes."

**Without this tool** — list `lib/`, grep for `CollectionState`, read
`pubspec.yaml` plus the 6 files that make up the feature (bloc, event,
state, screen, repository interface, repository impl) in full:

| Step | Bytes |
| --- | --- |
| Directory listing (`find lib -name "*.dart"`) | 1,871 |
| `grep -rn "CollectionState" lib/` | 1,239 |
| `pubspec.yaml` | 1,287 |
| 6 full source files | 25,732 |
| **Total** | **30,129 bytes** |

**With this tool** — `overview` once, then `context CollectionState` and
`impact CollectionState`:

| Step | Bytes |
| --- | --- |
| `overview` | 1,306 |
| `context CollectionState` | 2,248 |
| `impact CollectionState` | 841 |
| **Total** | **4,395 bytes** |

**≈6.9x fewer bytes.** `impact` also already groups, dedupes, and
risk-rates the references — work a no-tool agent still has to do itself
after reading raw grep output.

### Task 2 — fuzzy "where does X happen" search

"Find where the app handles camera permissions and image picking, to add a
new permission check" — the symbol name isn't known up front, so this
exercises `query` instead of `context`/`impact`.

**Without this tool** — grep for permission/camera/image-picker terms, then
read the 4 matching files in full: **54,785 bytes** (3,975 grep + 50,810
source).

**With this tool** — one `query "camera permission image picker"` call:
**4,121 bytes**.

**≈13.3x fewer bytes** — but with a real quality caveat: `query`'s
free-text term matching is looser than grep's exact patterns. Splitting the
query into individual words pulled in 6 extra files that only matched the
generic word "image" alongside the 4 truly relevant ones. Nothing grep
found was *missed* — all 4 real files ranked in the top 6 — but a real
agent has to skim past some noise that grep's tighter phrasing wouldn't
have produced.

**Caveats:** these are two tasks on one project, and "which files a
thorough agent reads" is a judgment call — a lazier read is smaller, a more
paranoid one is bigger. Treat the 6.9x–13.3x range as a representative
order of magnitude, not a guaranteed number for every task or project.

</details>

## Tools

| Tool | Purpose |
| --- | --- |
| `overview` | Dependencies, SDK constraint, folder breakdown, entry point, and the most depended-upon files — the best first call on an unfamiliar project. |
| `index` | Build/rebuild the symbol index. |
| `symbols` | List symbols, filtered by kind and/or text. |
| `context` | Everything about one symbol: location, signature, imports, nearby symbols, references. |
| `impact` | Blast-radius estimate for changing a symbol (LOW/MEDIUM/HIGH), grouped and deduped. |
| `query` | Free-text search across symbol names and source lines. |
| `graph` | An interactive, offline HTML dependency graph — pan/zoom, drill into symbols, circular-import detection. |

Each is a CLI command (`dart_context_mcp <tool> ...`) and an MCP tool
(`dart_<tool>`) with the same behavior. `overview`, `context`, `impact`,
and `query` accept `--format json` (CLI) / `format: "json"` (MCP) to get
structured data instead of the default compact text.

```bash
dart_context_mcp symbols --root path/to/project --query background
dart_context_mcp context SessionScreen --root path/to/project
dart_context_mcp impact SettingsProvider --root path/to/project
dart_context_mcp query "app background settings" --root path/to/project
dart_context_mcp graph path/to/project --open
```

<details>
<summary>Dependency graph details</summary>

Writes a self-contained, offline HTML file (default:
`.dart_context/graph.html`, or `--out <path>`) — no CDN, no network, opens
straight from `file://`.

- **Three switchable layouts**: Layered (columns by import depth), Force
  (spreads chain-shaped graphs into a compact 2D shape), Radial
  (concentric rings from the entry points outward). Switch anytime;
  drill-down state carries over.
- **Folder collapsing** past ~40 files, so large projects stay readable
  instead of turning into a hairball. Double-click to drill in.
- **Symbol-level drill-down**: double-click a file to reveal its
  classes/functions, a class to reveal its methods/fields.
- Node size reflects fan-in; hubs glow, circular-dependency nodes pulse
  red, import edges carry an animated direction indicator.
- Circular imports detected automatically (Tarjan's SCC), highlighted and
  listed in the sidebar — re-run fresh at whatever collapse level is
  currently visible, so folder-level cycles are caught too.
- Pan/zoom/drag, search, click a file to see its imports/importers,
  "Export PNG".

</details>

<details>
<summary>What gets indexed, and known limitations</summary>

**Indexed:** classes, mixins, enums, enum constants, extensions, typedefs,
top-level functions/variables, constructors (`Class.new` / `Class.named`),
methods, fields, imports. Generated files (`.g.dart`, `.freezed.dart`,
`.mocks.dart`) are skipped by default (`--include-generated` to include
them). The index is cached in `.dart_context/index.json` and rebuilt
automatically when tracked files change.

**Limitations:** `context`/`impact`/`query` find references by scanning
source text for a symbol's bare name, not by resolving types through the
analyzer. Two heuristics narrow the common false positives:

- A mention inside a `//` comment or a plain string literal doesn't count
  (string interpolation like `$name`/`${expr}` still does — that's real
  code). Line-based, not a real lexer, so multi-line strings/comments can
  still slip through.
- When a name is declared more than once (two unrelated classes both
  called `Item`), references are scoped to the declaring file plus files
  that directly import it. Doesn't follow transitive `export` re-exports.

Treat these tools as a fast way to narrow down where to look, not a
substitute for reading the flagged lines — full analyzer-based type
resolution would close the remaining gaps but is a much heavier lift.

</details>

## Roadmap

- Richer analyzer-backed (type-resolved) references
- Optional embeddings for semantic query

## License

[MIT](LICENSE)
