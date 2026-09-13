import 'dart:convert';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'code_index.dart';
import 'import_resolver.dart';
import 'model.dart';
import 'symbol_graph.dart';

class GraphNode {
  final String path;
  final int symbolCount;

  GraphNode(this.path, this.symbolCount);
}

class GraphEdge {
  final String from;
  final String to;

  GraphEdge(this.from, this.to);
}

class DependencyGraph {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  DependencyGraph(this.nodes, this.edges);
}

/// Builds a file-level import dependency graph from an already-built
/// [CodeIndex]. Only imports that resolve to another file inside the
/// project are kept as edges — `dart:*` imports and imports of external
/// packages (anything not under this project's own package name) are
/// dropped, since there's no local file to point an edge at.
DependencyGraph buildDependencyGraph(CodeIndex index) {
  final packageName = readPackageName(index.rootPath);
  final byPosixPath = <String, DartFileIndex>{
    for (final file in index.files) toPosixPath(file.path): file,
  };

  final edges = <GraphEdge>[];
  for (final file in index.files) {
    final fromPosix = toPosixPath(file.path);
    final fromDir = p.posix.dirname(fromPosix);
    for (final import in file.imports) {
      final targetPosix = resolveImportToPosixPath(
        import,
        fromDir,
        packageName,
      );
      if (targetPosix == null) continue;
      if (targetPosix == fromPosix) continue;
      if (!byPosixPath.containsKey(targetPosix)) continue;
      edges.add(GraphEdge(fromPosix, targetPosix));
    }
  }

  final nodes = [
    for (final entry in byPosixPath.entries)
      GraphNode(entry.key, entry.value.symbols.length),
  ];
  return DependencyGraph(nodes, edges);
}

/// Finds circular import chains using Tarjan's strongly-connected-components
/// algorithm. Returns one list of file paths per cycle (a component with
/// more than one file, or a single file that imports itself).
List<List<String>> detectCycles(DependencyGraph graph) {
  final adjacency = <String, List<String>>{};
  for (final edge in graph.edges) {
    adjacency.putIfAbsent(edge.from, () => []).add(edge.to);
  }

  var counter = 0;
  final indices = <String, int>{};
  final lowlink = <String, int>{};
  final onStack = <String, bool>{};
  final stack = <String>[];
  final sccs = <List<String>>[];

  void strongConnect(String v) {
    indices[v] = counter;
    lowlink[v] = counter;
    counter++;
    stack.add(v);
    onStack[v] = true;

    for (final w in adjacency[v] ?? const <String>[]) {
      if (!indices.containsKey(w)) {
        strongConnect(w);
        lowlink[v] = math.min(lowlink[v]!, lowlink[w]!);
      } else if (onStack[w] == true) {
        lowlink[v] = math.min(lowlink[v]!, indices[w]!);
      }
    }

    if (lowlink[v] == indices[v]) {
      final scc = <String>[];
      while (true) {
        final w = stack.removeLast();
        onStack[w] = false;
        scc.add(w);
        if (w == v) break;
      }
      final selfLoop = scc.length == 1 && (adjacency[v]?.contains(v) ?? false);
      if (scc.length > 1 || selfLoop) sccs.add(scc);
    }
  }

  for (final node in graph.nodes) {
    if (!indices.containsKey(node.path)) strongConnect(node.path);
  }
  return sccs;
}

/// Renders [graph] as a self-contained, offline HTML page: a canvas-based
/// force-directed layout with pan/zoom, drag, search, click-to-focus
/// dependencies/dependents, and circular-import highlighting. No external
/// scripts or network access — the file works from a plain `file://` open.
String buildDependencyGraphHtml(
  DependencyGraph graph,
  List<List<String>> cycles, {
  required String title,
  SymbolGraph? symbols,
}) {
  final cycleGroupOf = <String, int>{};
  for (var i = 0; i < cycles.length; i++) {
    for (final path in cycles[i]) {
      cycleGroupOf[path] = i;
    }
  }

  final nodesJson = [
    for (final node in graph.nodes)
      {
        'id': node.path,
        'label': p.posix.basename(node.path),
        'group': _groupFor(node.path),
        'symbols': node.symbolCount,
        'cycle': cycleGroupOf[node.path],
      },
  ];
  final edgesJson = [
    for (final edge in graph.edges)
      {
        'from': edge.from,
        'to': edge.to,
        'cycle':
            cycleGroupOf[edge.from] != null &&
            cycleGroupOf[edge.from] == cycleGroupOf[edge.to],
      },
  ];

  final symbolNodesJson = [
    for (final node in symbols?.nodes ?? const <SymbolGraphNode>[])
      {
        'id': node.id,
        'kind': node.kind,
        'label': node.label,
        'path': node.path,
        'line': node.line,
        'parentId': node.parentId,
      },
  ];
  final symbolEdgesJson = [
    for (final edge in symbols?.edges ?? const <SymbolGraphEdge>[])
      {'from': edge.from, 'to': edge.to, 'type': edge.type},
  ];

  final payload = jsonEncode({
    'title': title,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'nodes': nodesJson,
    'edges': edgesJson,
    'cycles': cycles,
    'symbolNodes': symbolNodesJson,
    'symbolEdges': symbolEdgesJson,
  });

  return _template
      .replaceAll('__TITLE__', title)
      .replaceFirst('__DATA_JSON__', payload);
}

String _groupFor(String posixPath) {
  final parts = posixPath.split('/');
  if (parts.length <= 1) return parts.isEmpty ? '' : parts.first;
  if (parts.first == 'lib' && parts.length > 2) return 'lib/${parts[1]}';
  return parts.first;
}

const String _template = r'''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>__TITLE__</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; background: #0f1420; color: #e5e7eb; font: 13px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif; }
  #app { display: flex; height: 100%; }
  #sidebar { width: 300px; flex: none; background: #161c2c; border-right: 1px solid #232b3f; padding: 14px; overflow-y: auto; }
  #sidebar h1 { font-size: 15px; margin: 0 0 4px; word-break: break-word; }
  #sidebar .muted { color: #8b93a7; font-size: 12px; }
  #stats { display: flex; gap: 10px; margin: 10px 0 14px; }
  #stats div { background: #1f2740; border-radius: 6px; padding: 6px 10px; flex: 1; text-align: center; }
  #stats b { display: block; font-size: 16px; }
  input#search { width: 100%; padding: 7px 8px; border-radius: 6px; border: 1px solid #2a3350; background: #0f1420; color: #e5e7eb; margin-bottom: 14px; }
  section { margin-bottom: 16px; }
  section h2 { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; color: #8b93a7; margin: 0 0 6px; }
  ul { list-style: none; margin: 0; padding: 0; }
  #cycles li { padding: 6px 8px; border-radius: 5px; cursor: pointer; color: #f5989d; background: rgba(229,72,77,.12); margin-bottom: 4px; }
  #cycles li:hover { background: rgba(229,72,77,.25); }
  #expandedList li { display: flex; align-items: center; justify-content: space-between; gap: 6px; padding: 4px 8px; border-radius: 5px; background: #1f2740; margin-bottom: 4px; font-size: 12px; word-break: break-all; }
  #expandedList button { flex: none; background: none; border: none; color: #8b93a7; cursor: pointer; font-size: 13px; line-height: 1; padding: 2px 4px; }
  #expandedList button:hover { color: #e5e7eb; }
  .btnRow { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 14px; }
  .btnRow button { flex: 1 1 auto; padding: 6px 8px; border-radius: 6px; border: 1px solid #2a3350; background: #1f2740; color: #e5e7eb; cursor: pointer; font-size: 11px; white-space: nowrap; }
  .btnRow button:hover { background: #2a3350; }
  .layoutBtn.active { background: #3b4874; border-color: #5064a3; color: #fff; }
  #focusPanel { display: none; }
  #focusPanel .path { color: #8b93a7; font-size: 11px; margin-bottom: 8px; word-break: break-all; }
  #focusPanel ul { max-height: 160px; overflow-y: auto; }
  #focusPanel li { padding: 2px 0; font-size: 12px; word-break: break-all; }
  #legend div { display: flex; align-items: center; gap: 6px; margin-bottom: 4px; font-size: 12px; }
  #legend span.swatch { width: 10px; height: 10px; border-radius: 50%; flex: none; }
  #canvasWrap { position: relative; flex: 1; overflow: hidden; }
  canvas { display: block; width: 100%; height: 100%; cursor: grab; }
  #hint { position: absolute; bottom: 10px; right: 14px; color: #576082; font-size: 11px; }
  #tooltip { position: absolute; pointer-events: none; background: #1f2740; border: 1px solid #2a3350; border-radius: 6px; padding: 8px 10px; font-size: 12px; max-width: 320px; display: none; z-index: 5; box-shadow: 0 4px 16px rgba(0,0,0,.4); }
  #tooltip .path { color: #8b93a7; font-size: 11px; word-break: break-all; margin-bottom: 4px; }
  #tooltip .row { display: flex; gap: 10px; }
</style>
</head>
<body>
<div id="app">
  <div id="sidebar">
    <h1>__TITLE__</h1>
    <div class="muted">Import dependency graph &middot; <span id="modeLabel">leveled by depth</span></div>
    <div id="stats">
      <div><b id="statFiles">0</b>files</div>
      <div><b id="statEdges">0</b>imports</div>
      <div><b id="statCycles">0</b>cycles</div>
    </div>
    <input id="search" placeholder="Filter files...">
    <div class="btnRow">
      <button class="layoutBtn active" data-mode="layered">Layered</button>
      <button class="layoutBtn" data-mode="force">Force</button>
      <button class="layoutBtn" data-mode="radial">Radial</button>
    </div>
    <div class="btnRow">
      <button id="btnFit">Fit view</button>
      <button id="btnReset">Reset layout</button>
      <button id="btnExpandAll">Expand all</button>
      <button id="btnCollapse">Collapse to folders</button>
      <button id="btnExport">Export PNG</button>
    </div>
    <section>
      <h2>Circular imports</h2>
      <ul id="cycles"></ul>
    </section>
    <section id="expandedSection" hidden>
      <h2>Expanded</h2>
      <ul id="expandedList"></ul>
    </section>
    <section id="focusPanel">
      <h2 id="focusTitle">Selected</h2>
    </section>
    <section>
      <h2>Groups</h2>
      <div id="legend"></div>
    </section>
  </div>
  <div id="canvasWrap">
    <canvas id="c"></canvas>
    <div id="tooltip"></div>
    <div id="hint">scroll = zoom &middot; drag bg = pan &middot; drag node = move &middot; click = focus &middot; double-click folder/file/class = expand</div>
  </div>
</div>
<script>
const DATA = __DATA_JSON__;
(function () {
  const canvas = document.getElementById('c');
  const ctx = canvas.getContext('2d');
  const tooltip = document.getElementById('tooltip');

  function resize() {
    const rect = canvas.parentElement.getBoundingClientRect();
    canvas.width = rect.width * devicePixelRatio;
    canvas.height = rect.height * devicePixelRatio;
    canvas.style.width = rect.width + 'px';
    canvas.style.height = rect.height + 'px';
    ctx.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
  }
  window.addEventListener('resize', resize);

  // ---- Static indexes over the full (uncollapsed) file graph ----
  const fileById = new Map(DATA.nodes.map(n => [n.id, n]));
  const rawEdges = DATA.edges;

  function ancestorsOf(id) {
    const parts = id.split('/');
    const res = [];
    for (let i = 1; i < parts.length; i++) res.push(parts.slice(0, i).join('/'));
    return res;
  }
  const nodeAncestors = new Map(DATA.nodes.map(n => [n.id, ancestorsOf(n.id)]));

  function groupForPath(path) {
    const parts = path.split('/');
    if (parts.length <= 1) return parts[0] || '';
    if (parts[0] === 'lib' && parts.length > 2) return 'lib/' + parts[1];
    return parts[0];
  }

  function hashHue(s) {
    let h = 0;
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
    return Math.abs(h) % 360;
  }

  // ---- Symbol-level graph (classes/methods/functions/...), used for
  // drill-down past the file level via double-click. Not shown by default -
  // see applyDrillDown(). ----
  const symbolNodeById = new Map(DATA.symbolNodes.map(n => [n.id, n]));
  const symbolChildrenByParent = new Map();
  for (const n of DATA.symbolNodes) {
    if (!n.parentId) continue;
    if (!symbolChildrenByParent.has(n.parentId)) symbolChildrenByParent.set(n.parentId, []);
    symbolChildrenByParent.get(n.parentId).push(n);
  }
  function fileNodeId(path) { return 'file:' + path; }

  const KIND_COLORS = {
    file: '#5b8dee',
    class: '#f2a93b', mixin: '#f2a93b',
    enum: '#c66fd8', enum_constant: '#c66fd8',
    extension: '#4fd1c5', typedef: '#4fd1c5',
    function: '#57c785', method: '#57c785',
    constructor: '#e5747a',
    field: '#9aa5b1', variable: '#9aa5b1',
  };
  function kindColor(kind) { return KIND_COLORS[kind] || '#9aa5b1'; }
  const CONTAINER_KINDS = new Set(['class', 'mixin', 'enum', 'extension']);

  // ---- Directory-collapse state ----
  // Large projects default to one level of folders (lib/screens, lib/models,
  // ...) instead of every file at once, or everything would collapse into a
  // single top-level blob; small projects just show every file. Folders
  // expand on click and collapse back via the sidebar list.
  const AUTO_COLLAPSE_THRESHOLD = 40;
  const expanded = new Set();
  function resetExpansion(showAllFiles) {
    expanded.clear();
    if (showAllFiles) {
      for (const anc of nodeAncestors.values()) for (const a of anc) expanded.add(a);
    } else if (DATA.nodes.length <= AUTO_COLLAPSE_THRESHOLD) {
      for (const anc of nodeAncestors.values()) for (const a of anc) expanded.add(a);
    } else {
      for (const anc of nodeAncestors.values()) if (anc.length > 0) expanded.add(anc[0]);
    }
  }
  resetExpansion(false);

  function visibleIdFor(fileId) {
    for (const anc of nodeAncestors.get(fileId)) {
      if (!expanded.has(anc)) return 'folder:' + anc;
    }
    return fileId;
  }

  let nodes = [], edges = [], nodeById = new Map();

  // Tarjan's strongly-connected-components algorithm, run fresh on whatever
  // graph is currently visible (files, or collapsed folders). This matters:
  // collapsing a strictly acyclic file graph into folders can still surface
  // a genuine folder-level circular dependency (A's folder imports B's,
  // B's imports C's, C's imports back into A's) even when no single file
  // participates in a cycle - a real architectural signal that file-level
  // cycle detection alone would miss entirely.
  function computeSccCycles(nodesArr, edgesArr) {
    const adj = new Map(nodesArr.map(n => [n.id, []]));
    for (const e of edgesArr) adj.get(e.from)?.push(e.to);
    let counter = 0;
    const indices = new Map(), lowlink = new Map(), onStack = new Map();
    const stack = [];
    const sccs = [];
    function strongConnect(v) {
      indices.set(v, counter); lowlink.set(v, counter); counter++;
      stack.push(v); onStack.set(v, true);
      for (const w of adj.get(v) || []) {
        if (!indices.has(w)) {
          strongConnect(w);
          lowlink.set(v, Math.min(lowlink.get(v), lowlink.get(w)));
        } else if (onStack.get(w)) {
          lowlink.set(v, Math.min(lowlink.get(v), indices.get(w)));
        }
      }
      if (lowlink.get(v) === indices.get(v)) {
        const scc = [];
        let w;
        do {
          w = stack.pop();
          onStack.set(w, false);
          scc.push(w);
        } while (w !== v);
        const selfLoop = scc.length === 1 && (adj.get(v) || []).includes(v);
        if (scc.length > 1 || selfLoop) sccs.push(scc);
      }
    }
    for (const n of nodesArr) if (!indices.has(n.id)) strongConnect(n.id);
    return sccs;
  }

  function rebuild() {
    const groupsMap = new Map();
    for (const n of DATA.nodes) {
      const vid = visibleIdFor(n.id);
      let g = groupsMap.get(vid);
      if (!g) {
        g = vid.startsWith('folder:')
          ? { id: vid, type: 'folder', path: vid.slice(7), files: [] }
          : { id: vid, type: 'file', path: n.id, files: [n.id] };
        groupsMap.set(vid, g);
      }
      if (g.type === 'folder' && !g.files.includes(n.id)) g.files.push(n.id);
    }

    const visNodes = [...groupsMap.values()].map(g => {
      const label = g.type === 'folder' ? g.path.split('/').pop() : fileById.get(g.files[0]).label;
      const group = groupForPath(g.path);
      const symbols = g.files.reduce((s, f) => s + (fileById.get(f).symbols || 0), 0);
      return {
        id: g.id, type: g.type, label, path: g.path, group,
        fileCount: g.files.length, symbols,
        crossCycleGroup: null, hasHiddenCycle: false,
        x: 0, y: 0, vx: 0, vy: 0, fixed: false, layer: 0, inDegree: 0, outDegree: 0,
      };
    });
    const visNodeById = new Map(visNodes.map(n => [n.id, n]));

    const edgeMap = new Map();
    for (const e of rawEdges) {
      const vf = visibleIdFor(e.from), vt = visibleIdFor(e.to);
      if (vf === vt) continue; // internal to a collapsed folder - nothing to draw
      const key = vf + '|' + vt;
      let ed = edgeMap.get(key);
      if (!ed) { ed = { from: vf, to: vt, weight: 0, cycle: false, type: 'imports' }; edgeMap.set(key, ed); }
      ed.weight++;
    }
    const visEdges = [...edgeMap.values()];
    for (const e of visEdges) {
      const f = visNodeById.get(e.from), t = visNodeById.get(e.to);
      if (f) f.outDegree++;
      if (t) t.inDegree++;
    }
    // Mark edges that are half of a mutual A<->B pair so they can be bowed
    // apart when drawn - otherwise two opposite-direction edges between the
    // same two nodes render as one indistinguishable line.
    for (const e of visEdges) {
      e.mutual = visEdges.some(o => o !== e && o.from === e.to && o.to === e.from);
    }

    // Cycles visible at the current collapse level (may be a cross-folder
    // cycle that doesn't correspond to any single-file cycle).
    const visibleCycles = computeSccCycles(visNodes, visEdges);
    const crossCycleGroupOf = new Map();
    visibleCycles.forEach((scc, i) => { for (const id of scc) crossCycleGroupOf.set(id, i); });
    for (const e of visEdges) {
      e.cycle = crossCycleGroupOf.has(e.from) && crossCycleGroupOf.get(e.from) === crossCycleGroupOf.get(e.to);
    }
    for (const n of visNodes) {
      n.crossCycleGroup = crossCycleGroupOf.has(n.id) ? crossCycleGroupOf.get(n.id) : null;
    }

    // Real per-file cycles (from the analyzer-backed index) that are
    // currently hidden because every file in them collapsed into the same
    // folder - the folder itself won't show a cycle edge (it'd be a
    // self-loop, and those are dropped), so flag it separately.
    const hiddenInternalCycle = new Set();
    for (const cyc of DATA.cycles) {
      const vids = new Set(cyc.map(f => visibleIdFor(f)));
      if (vids.size === 1) hiddenInternalCycle.add([...vids][0]);
    }
    for (const n of visNodes) n.hasHiddenCycle = hiddenInternalCycle.has(n.id);

    nodes = visNodes; nodeById = visNodeById; edges = visEdges;
    applyMainLayout();
    applyDrillDown();
    for (let pass = 0; pass < 3; pass++) layoutSymbolChildren();
    document.getElementById('statFiles').textContent = DATA.nodes.length;
    document.getElementById('statEdges').textContent = rawEdges.length;
    document.getElementById('statCycles').textContent = visibleCycles.length + hiddenInternalCycle.size;
    renderExpandedList();
    renderLegend();
    if (focused && !nodeById.has(focused)) { focused = null; }
    renderFocusPanel();
  }

  // Splices the symbol-level graph (classes/methods/functions/...) into the
  // currently-visible file/folder graph, wherever the user has drilled in.
  // Unlike folder collapse (which *replaces* a folder with its children),
  // this is additive: a drilled file or class stays visible as its own node
  // (import edges still need somewhere to attach), with its members added
  // alongside it via 'contains' edges. Grows `nodes` while iterating it, so
  // multi-level drill-down (file -> class -> method) resolves in one pass.
  function applyDrillDown() {
    const seen = new Set(nodes.map(n => n.id));
    let i = 0;
    while (i < nodes.length) {
      const n = nodes[i];
      i++;
      const key = n.type === 'file' ? fileNodeId(n.path) : n.id;
      if (!expanded.has(key)) continue;
      const children = symbolChildrenByParent.get(key) || [];
      for (const child of children) {
        if (seen.has(child.id)) continue;
        seen.add(child.id);
        const childNode = makeSymbolVisNode(child);
        nodes.push(childNode);
        nodeById.set(childNode.id, childNode);
        edges.push({ from: key, to: child.id, type: 'contains', weight: 1, mutual: false, cycle: false });
      }
    }
  }

  function makeSymbolVisNode(child) {
    return {
      id: child.id, type: 'symbol', kind: child.kind, label: child.label,
      path: child.path, line: child.line, group: groupForPath(child.path),
      fileCount: 0, symbols: 0, crossCycleGroup: null, hasHiddenCycle: false,
      x: 0, y: 0, vx: 0, vy: 0, fixed: false, layer: 0, inDegree: 0, outDegree: 0,
    };
  }

  // Positions a drilled-in node's members in a small grid beside it. Runs a
  // few passes per rebuild so multi-level nesting (file -> class -> method)
  // settles: each pass needs the parent's position from the previous one.
  function layoutSymbolChildren() {
    const byParent = new Map();
    for (const e of edges) {
      if (e.type !== 'contains') continue;
      if (!byParent.has(e.from)) byParent.set(e.from, []);
      byParent.get(e.from).push(e.to);
    }
    for (const [parentId, childIds] of byParent) {
      const parent = nodeById.get(parentId);
      if (!parent) continue;
      const children = childIds.map(id => nodeById.get(id)).filter(Boolean);
      const cols = Math.max(1, Math.ceil(Math.sqrt(children.length)));
      const rows = Math.ceil(children.length / cols);
      children.forEach((child, idx) => {
        if (child.fixed) return; // respect manual drags
        const col = idx % cols, row = Math.floor(idx / cols);
        child.x = parent.x + 90 + col * 60;
        child.y = parent.y + (row - (rows - 1) / 2) * 36;
      });
    }
  }

  // Removes any previously-drilled descendants of `key` from the expansion
  // state, so collapsing a file/class doesn't leave orphaned entries in the
  // "Expanded" sidebar list for members that are no longer reachable.
  function purgeDescendants(key) {
    for (const child of symbolChildrenByParent.get(key) || []) {
      expanded.delete(child.id);
      purgeDescendants(child.id);
    }
  }

  function isExpandable(n) {
    if (n.type === 'folder') return true;
    if (n.type !== 'file' && n.type !== 'symbol') return false;
    const key = n.type === 'file' ? fileNodeId(n.path) : n.id;
    return (symbolChildrenByParent.get(key) || []).length > 0;
  }
  function isDrilled(n) {
    if (n.type === 'folder') return false;
    const key = n.type === 'file' ? fileNodeId(n.path) : n.id;
    return expanded.has(key);
  }

  // Which main-graph layout algorithm currently positions file/folder nodes.
  // Symbol children (drilled-in members) are always positioned afterward by
  // layoutSymbolChildren(), regardless of mode.
  let layoutMode = 'layered';
  function applyMainLayout() {
    if (layoutMode === 'force') layoutForce();
    else if (layoutMode === 'radial') layoutRadial();
    else layoutLayered();
  }

  // Classic force-directed placement (Fruchterman-Reingold-ish): all-pairs
  // repulsion keeps nodes apart, edge springs pull connected nodes together,
  // a weak centering force stops the whole graph drifting off-origin. Unlike
  // the layered algorithm, this doesn't force one axis to track import
  // depth, so a long linear import chain spreads into a compact 2D shape
  // instead of a single-pixel-tall row - the layered layout's worst case.
  // Runs as a one-shot batch of iterations (not per animation frame), same
  // as layoutLayered().
  function layoutForce() {
    const n = nodes.length;
    if (n === 0) return;
    nodes.forEach((node, i) => {
      if (node.x === 0 && node.y === 0) {
        const angle = (i / n) * Math.PI * 2;
        const radius = 160 + (i % 5) * 40;
        node.x = Math.cos(angle) * radius;
        node.y = Math.sin(angle) * radius;
      }
      node.vx = 0; node.vy = 0;
      node.fixed = false;
    });
    const idealLen = 130;
    const repulsion = 5000;
    const iterations = n > 400 ? 80 : n > 150 ? 150 : 250;
    for (let iter = 0; iter < iterations; iter++) {
      for (let i = 0; i < nodes.length; i++) {
        const a = nodes[i];
        let fx = 0, fy = 0;
        for (let j = 0; j < nodes.length; j++) {
          if (i === j) continue;
          const b = nodes[j];
          let dx = a.x - b.x, dy = a.y - b.y;
          let distSq = dx * dx + dy * dy;
          if (distSq < 0.01) { dx = Math.random() - 0.5; dy = Math.random() - 0.5; distSq = 0.01; }
          const dist = Math.sqrt(distSq);
          const force = repulsion / distSq;
          fx += (dx / dist) * force;
          fy += (dy / dist) * force;
        }
        a.vx += fx * 0.01;
        a.vy += fy * 0.01;
      }
      for (const e of edges) {
        const s = nodeById.get(e.from), t = nodeById.get(e.to);
        if (!s || !t) continue;
        const dx = t.x - s.x, dy = t.y - s.y;
        const dist = Math.max(Math.sqrt(dx * dx + dy * dy), 0.01);
        const force = (dist - idealLen) * 0.02;
        const fx = (dx / dist) * force, fy = (dy / dist) * force;
        s.vx += fx; s.vy += fy;
        t.vx -= fx; t.vy -= fy;
      }
      for (const node of nodes) {
        node.vx = node.vx * 0.85 - node.x * 0.002;
        node.vy = node.vy * 0.85 - node.y * 0.002;
        node.x += node.vx;
        node.y += node.vy;
      }
    }
  }

  // Radial placement: BFS distance-from-root determines which concentric
  // ring a node sits on (roots = nodes nothing imports, i.e. entry points),
  // with nodes spread evenly around each ring by angle. Like force layout,
  // this avoids the layered algorithm's flat-line failure mode on long
  // chains - a chain just spirals outward ring by ring instead of running
  // off in one direction.
  function layoutRadial() {
    if (nodes.length === 0) return;
    const outAdj = new Map(nodes.map(n => [n.id, []]));
    const inAdj = new Map(nodes.map(n => [n.id, []]));
    for (const e of edges) {
      outAdj.get(e.from)?.push(e.to);
      inAdj.get(e.to)?.push(e.from);
    }
    let roots = nodes.filter(n => (inAdj.get(n.id) || []).length === 0);
    if (roots.length === 0) {
      roots = [nodes.reduce((a, b) => ((b.outDegree || 0) > (a.outDegree || 0) ? b : a), nodes[0])];
    }

    const dist = new Map();
    const queue = [];
    for (const r of roots) { dist.set(r.id, 0); queue.push(r.id); }
    let qi = 0;
    while (qi < queue.length) {
      const id = queue[qi++];
      const d = dist.get(id);
      for (const nb of [...(outAdj.get(id) || []), ...(inAdj.get(id) || [])]) {
        if (!dist.has(nb)) { dist.set(nb, d + 1); queue.push(nb); }
      }
    }
    const maxD = Math.max(0, ...[...dist.values()]);
    for (const n of nodes) if (!dist.has(n.id)) dist.set(n.id, maxD + 1);

    const byRing = new Map();
    for (const n of nodes) {
      const d = dist.get(n.id);
      if (!byRing.has(d)) byRing.set(d, []);
      byRing.get(d).push(n);
    }
    // Each ring gets its own rotation offset (golden angle) before spreading
    // its members evenly - without this, a long chain (one node per ring)
    // has every ring's lone node land at the same fixed angle, producing a
    // straight line through the center instead of a spiral. Real diagrams
    // with wide rings barely notice the offset; it only matters for the
    // degenerate single-node-per-ring case.
    const GOLDEN_ANGLE = 2.399963229728653;
    const ringSpacing = 150;
    for (const [d, ringNodes] of byRing) {
      ringNodes.sort((a, b) => (a.group + a.label).localeCompare(b.group + b.label));
      const count = ringNodes.length;
      const radius = d === 0 ? (count > 1 ? 40 : 0) : d * ringSpacing;
      const baseAngle = d * GOLDEN_ANGLE - Math.PI / 2;
      ringNodes.forEach((n, i) => {
        const angle = baseAngle + (i / count) * Math.PI * 2;
        n.x = Math.cos(angle) * radius;
        n.y = Math.sin(angle) * radius;
        n.fixed = false;
      });
    }
  }

  // Longest-path layering (a lightweight Sugiyama-style leveling): a node's
  // layer is how deep its import chain goes, so entry points naturally end
  // up on the left and leaf dependencies on the right. Cycle back-edges are
  // neutralized (treated as contributing layer 0) to avoid infinite
  // recursion - the exact layer of a node inside a cycle is inherently
  // ambiguous, so this is a best-effort placement, not a guarantee.
  function layoutLayered() {
    const outVis = new Map(nodes.map(n => [n.id, []]));
    for (const e of edges) outVis.get(e.from)?.push(e.to);
    const layerOf = new Map();
    const onStack = new Set();
    function computeLayer(id) {
      if (layerOf.has(id)) return layerOf.get(id);
      if (onStack.has(id)) return 0;
      onStack.add(id);
      let maxL = -1;
      for (const t of outVis.get(id) || []) maxL = Math.max(maxL, computeLayer(t));
      onStack.delete(id);
      const result = maxL + 1;
      layerOf.set(id, result);
      return result;
    }
    for (const n of nodes) n.layer = computeLayer(n.id);
    const maxLayer = Math.max(0, ...nodes.map(n => n.layer));

    const byLayer = [];
    for (let l = 0; l <= maxLayer; l++) byLayer.push([]);
    for (const n of nodes) byLayer[n.layer].push(n);
    for (const layerNodes of byLayer) {
      layerNodes.sort((a, b) => (a.group + a.label).localeCompare(b.group + b.label));
    }

    const colSpacing = 260, rowSpacing = 70;
    for (let l = 0; l <= maxLayer; l++) {
      byLayer[l].forEach((n, i) => {
        n.x = (maxLayer - l) * colSpacing + 80;
        n.y = i * rowSpacing + 60;
        n.fixed = false;
      });
    }

    // Refine row (y) positions only - x stays fixed per layer. Each node is
    // pulled toward the average y of its neighbors (straightens edges,
    // reduces crossings), then every layer is hard-separated to a minimum
    // gap. The separation MUST be a hard constraint, not a soft spring
    // force competing with the pull: when many same-layer nodes share a
    // single neighbor (e.g. 15 files all importing one collapsed folder),
    // the pull step drives them all toward that one neighbor's y every
    // iteration, and a soft repulsion that only activates once nodes are
    // already close can't out-race that - in practice it collapses to a
    // near-zero gap instead of the intended spacing. Re-asserting a hard
    // minimum after every pull step (recentered so the layer's centroid
    // doesn't drift) fixes that regardless of how many nodes fan into one
    // shared target.
    const neighborsOfNode = new Map(nodes.map(n => [n.id, []]));
    for (const e of edges) {
      neighborsOfNode.get(e.from)?.push(e.to);
      neighborsOfNode.get(e.to)?.push(e.from);
    }
    const minGap = 46;
    function separateLayer(layerNodes) {
      if (layerNodes.length < 2) return;
      const sorted = [...layerNodes].sort((a, b) => a.y - b.y);
      const meanBefore = sorted.reduce((s, n) => s + n.y, 0) / sorted.length;
      for (let i = 1; i < sorted.length; i++) {
        const minY = sorted[i - 1].y + minGap;
        if (sorted[i].y < minY) sorted[i].y = minY;
      }
      const meanAfter = sorted.reduce((s, n) => s + n.y, 0) / sorted.length;
      const shift = meanBefore - meanAfter;
      for (const n of sorted) n.y += shift;
    }
    const iterations = nodes.length > 300 ? 60 : 150;
    for (let iter = 0; iter < iterations; iter++) {
      for (const n of nodes) {
        const neighborIds = neighborsOfNode.get(n.id) || [];
        if (neighborIds.length === 0) continue;
        let sum = 0;
        for (const id of neighborIds) sum += nodeById.get(id).y;
        n.y += (sum / neighborIds.length - n.y) * 0.12;
      }
      for (const layerNodes of byLayer) separateLayer(layerNodes);
    }
  }

  function nodeRadius(n) {
    if (n.type === 'symbol') return CONTAINER_KINDS.has(n.kind) ? 8 : 4.5;
    const bySymbols = Math.min(Math.sqrt(n.symbols || 0) * 1.6, 12);
    const byDegree = Math.min((n.inDegree || 0) * 1.4, 10);
    const base = n.type === 'folder' ? 9 : 6;
    return base + bySymbols + byDegree;
  }

  let scale = 0.9, offsetX = 0, offsetY = 0;
  let dragging = null, panStart = null, moved = false;

  function toScreen(x, y) { return [x * scale + offsetX, y * scale + offsetY]; }
  function toWorld(x, y) { return [(x - offsetX) / scale, (y - offsetY) / scale]; }

  // A deep import chain (each file importing exactly one predecessor) turns
  // into a graph with as many layers/columns as files, tens of thousands of
  // world units wide with almost no height. Fitting *that* to the viewport
  // with one uniform scale forces the scale down so far the whole graph
  // (including any real row spacing) becomes an illegible sliver. Real
  // diagramming tools don't try to cram an arbitrarily wide graph onto one
  // screen either - past a point they stop shrinking and let you pan. The
  // floor below is chosen so the 46-unit row gap from layoutLayered() stays
  // at least ~14 screen px (bare minimum before an 11px label starts
  // touching its neighbor).
  const MIN_FIT_SCALE = 0.3;
  function fitView() {
    if (nodes.length === 0) return;
    const xs = nodes.map(n => n.x), ys = nodes.map(n => n.y);
    const minX = Math.min(...xs), maxX = Math.max(...xs);
    const minY = Math.min(...ys), maxY = Math.max(...ys);
    const rect = canvas.parentElement.getBoundingClientRect();
    const w = Math.max(maxX - minX, 1), h = Math.max(maxY - minY, 1);
    scale = Math.max(
      Math.min((rect.width - 140) / w, (rect.height - 140) / h, 2),
      MIN_FIT_SCALE,
    );
    offsetX = rect.width / 2 - ((minX + maxX) / 2) * scale;
    offsetY = rect.height / 2 - ((minY + maxY) / 2) * scale;
  }

  function nodeColor(n) {
    if (n.crossCycleGroup != null) return '#e5484d';
    if (n.hasHiddenCycle) return '#d68a3f';
    if (n.type === 'symbol') return kindColor(n.kind);
    return `hsl(${hashHue(n.group)} 55% 58%)`;
  }

  let focused = null, searchTerm = '', hoverNode = null;

  function neighborsOf(id) {
    const set = new Set();
    for (const e of edges) {
      if (e.from === id) set.add(e.to);
      if (e.to === id) set.add(e.from);
    }
    return set;
  }

  // Per-node phase offset for glow/flow animation, stable across frames (and
  // rebuilds, since it's derived from the id) so pulses don't resync into a
  // robotic unison every time a node object is recreated.
  function animPhase(id) { return (hashHue(id) % 360) / 360; }

  function draw() {
    const rect = canvas.parentElement.getBoundingClientRect();
    ctx.clearRect(0, 0, rect.width, rect.height);
    const now = performance.now() / 1000;

    // Smoothly ease rendered position toward the logical (simulation) one -
    // layout switches, expand/collapse, and force-sim settling animate into
    // place instead of snapping instantly. Interaction logic (dragging,
    // picking) still reads the logical x/y directly, so a dragged node
    // tracks the cursor with no lag: its render position is pinned to match.
    for (const n of nodes) {
      if (n.renderX == null) { n.renderX = n.x; n.renderY = n.y; }
      if (n.fixed) { n.renderX = n.x; n.renderY = n.y; }
      else { n.renderX += (n.x - n.renderX) * 0.12; n.renderY += (n.y - n.renderY) * 0.12; }
    }

    for (const e of edges) {
      const source = nodeById.get(e.from), target = nodeById.get(e.to);
      if (!source || !target) continue;
      const [x1, y1] = toScreen(source.renderX, source.renderY);
      const [x2, y2] = toScreen(target.renderX, target.renderY);
      const dim = focused && !(source.id === focused || target.id === focused);

      if (e.type === 'contains') {
        // Structural nesting (file -> symbol, class -> member): thin, muted,
        // no cycle logic (a tree can't have cycles) and no arrowhead - the
        // 'imports' edges below carry all the visual weight.
        ctx.strokeStyle = `rgba(140,150,175,${dim ? 0.04 : 0.22})`;
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
        ctx.stroke();
        continue;
      }

      const alpha = e.cycle ? (dim ? 0.15 : 0.9) : (dim ? 0.05 : 0.32);
      const color = e.cycle ? `rgba(229,72,77,${alpha})` : `rgba(140,150,175,${alpha})`;
      ctx.strokeStyle = color;
      ctx.lineWidth = e.cycle ? 2 : Math.min(1 + Math.log2(e.weight), 3);

      // A<->B pairs would otherwise draw as one indistinguishable line, so
      // bow each half of a mutual pair to the opposite side of the straight
      // path between the two nodes. The perpendicular direction is anchored
      // to the lexicographically smaller node id (not this edge's own
      // from->to order), so both directed edges of the pair agree on the
      // same axis and only differ in which side they bow to.
      let cx = (x1 + x2) / 2, cy = (y1 + y2) / 2;
      if (e.mutual) {
        const lowIsSource = e.from < e.to;
        const lx1 = lowIsSource ? x1 : x2, ly1 = lowIsSource ? y1 : y2;
        const lx2 = lowIsSource ? x2 : x1, ly2 = lowIsSource ? y2 : y1;
        const dx = lx2 - lx1, dy = ly2 - ly1;
        const len = Math.max(Math.sqrt(dx * dx + dy * dy), 1);
        const nx = -dy / len, ny = dx / len;
        const side = lowIsSource ? 1 : -1;
        cx += nx * 16 * side;
        cy += ny * 16 * side;
      }

      ctx.beginPath();
      ctx.moveTo(x1, y1);
      ctx.quadraticCurveTo(cx, cy, x2, y2);
      ctx.stroke();

      const angle = Math.atan2(y2 - cy, x2 - cx);
      const r = nodeRadius(target) * scale + 6;
      const ax = x2 - Math.cos(angle) * r, ay = y2 - Math.sin(angle) * r;
      ctx.beginPath();
      ctx.moveTo(ax, ay);
      ctx.lineTo(ax - 7 * Math.cos(angle - 0.4), ay - 7 * Math.sin(angle - 0.4));
      ctx.lineTo(ax - 7 * Math.cos(angle + 0.4), ay - 7 * Math.sin(angle + 0.4));
      ctx.closePath();
      ctx.fillStyle = color;
      ctx.fill();

      // A small dot marches from source to target along the same curve as
      // the edge, looping continuously - a lightweight motion cue for "data
      // flows this way" that reads as alive without needing per-edge
      // particle systems. Skipped when dimmed (unrelated to the current
      // focus/search) so it doesn't compete for attention.
      if (!dim) {
        const speed = e.cycle ? 0.35 : 0.22;
        const tt = (now * speed + animPhase(e.from + '|' + e.to)) % 1;
        const mt = 1 - tt;
        const px = mt * mt * x1 + 2 * mt * tt * cx + tt * tt * x2;
        const py = mt * mt * y1 + 2 * mt * tt * cy + tt * tt * y2;
        ctx.beginPath();
        ctx.arc(px, py, e.cycle ? 2.6 : 2, 0, Math.PI * 2);
        ctx.fillStyle = e.cycle ? '#ff8a8f' : '#aeb8d6';
        ctx.fill();
      }
    }

    for (const n of nodes) {
      const [x, y] = toScreen(n.renderX, n.renderY);
      const r = nodeRadius(n) * scale;
      const matches = searchTerm && n.path.toLowerCase().includes(searchTerm);
      const dim = (focused && n.id !== focused && !neighborsOf(focused).has(n.id)) ||
                  (searchTerm && !matches);
      const color = nodeColor(n);
      ctx.globalAlpha = dim ? 0.15 : 1;

      // Glow: a soft halo behind the node, stronger for things that deserve
      // attention (circular dependencies pulse, hover/focus light up, hubs
      // get a gentle constant breathing glow so they read as important at a
      // glance even before you interact with them).
      if (!dim) {
        const pulse = 0.5 + 0.5 * Math.sin(now * 2.4 + animPhase(n.id) * Math.PI * 2);
        const isHub = (n.inDegree || 0) + (n.outDegree || 0) >= 4;
        let blur = 0;
        if (n.crossCycleGroup != null) blur = 12 + pulse * 12;
        else if (n.id === focused) blur = 20;
        else if (n.id === hoverNode) blur = 14;
        else if (isHub) blur = 3 + pulse * 5;
        if (blur > 0) { ctx.shadowColor = color; ctx.shadowBlur = blur; }
      }

      ctx.beginPath();
      if (n.type === 'folder') {
        roundedRect(x - r, y - r, r * 2, r * 2, r * 0.5);
      } else {
        ctx.arc(x, y, r, 0, Math.PI * 2);
      }
      ctx.fillStyle = color;
      ctx.fill();
      ctx.shadowBlur = 0;
      if (n.hasHiddenCycle) {
        // A real per-file cycle is fully contained inside this collapsed
        // folder (invisible as an edge, since it'd be a self-loop) -
        // dashed border hints "expand me to see it".
        ctx.setLineDash([3, 2]); ctx.lineWidth = 1.5; ctx.strokeStyle = '#fff5';
        ctx.stroke(); ctx.setLineDash([]);
      }
      if (n.id === focused || n.id === hoverNode) {
        ctx.lineWidth = n.id === focused ? 3 : 1.5;
        ctx.strokeStyle = '#fff';
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
      if (scale > 0.55 || n.id === focused || matches) {
        ctx.fillStyle = '#e5e7eb';
        ctx.font = '11px system-ui, sans-serif';
        const label = n.type === 'folder' ? `${n.label}/ (${n.fileCount})` : n.label;
        ctx.fillText(label, x + r + 4, y + 3);
      }
    }
    requestAnimationFrame(draw);
  }

  function roundedRect(x, y, w, h, r) {
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
  }

  function pickNode(sx, sy) {
    const [wx, wy] = toWorld(sx, sy);
    for (const n of nodes) {
      const r = nodeRadius(n) + 3;
      if ((n.x - wx) ** 2 + (n.y - wy) ** 2 <= r * r) return n;
    }
    return null;
  }

  canvas.addEventListener('mousedown', e => {
    const rect = canvas.getBoundingClientRect();
    const sx = e.clientX - rect.left, sy = e.clientY - rect.top;
    moved = false;
    const n = pickNode(sx, sy);
    if (n) { dragging = n; n.fixed = true; }
    else { panStart = { x: e.clientX - offsetX, y: e.clientY - offsetY }; }
  });
  window.addEventListener('mousemove', e => {
    const rect = canvas.getBoundingClientRect();
    const sx = e.clientX - rect.left, sy = e.clientY - rect.top;
    if (dragging) {
      moved = true;
      const [wx, wy] = toWorld(sx, sy);
      dragging.x = wx; dragging.y = wy; dragging.vx = 0; dragging.vy = 0;
      tooltip.style.display = 'none';
    } else if (panStart) {
      moved = true;
      offsetX = e.clientX - panStart.x; offsetY = e.clientY - panStart.y;
      tooltip.style.display = 'none';
    } else {
      const n = pickNode(sx, sy);
      hoverNode = n ? n.id : null;
      canvas.style.cursor = n ? 'pointer' : 'grab';
      if (n) {
        tooltip.style.display = 'block';
        tooltip.style.left = Math.min(sx + 14, rect.width - 260) + 'px';
        tooltip.style.top = Math.min(sy + 14, rect.height - 100) + 'px';
        const kindLabel = n.type === 'folder' ? `Folder &middot; ${n.fileCount} file(s)`
          : n.type === 'file' ? 'File' : n.kind;
        let cycleNote = '';
        if (n.crossCycleGroup != null) {
          cycleNote = '<div style="color:#f5989d;margin-top:4px;">Circular dependency at this level</div>';
        } else if (n.hasHiddenCycle) {
          cycleNote = '<div style="color:#e0ac6b;margin-top:4px;">Contains a circular import internally - expand to see it</div>';
        }
        const body = n.type === 'symbol'
          ? `<div class="muted">${n.path}${n.line ? ':' + n.line : ''}</div>`
          : `<div class="row muted"><span>Imports: ${n.outDegree}</span><span>Imported by: ${n.inDegree}</span></div>` +
            `<div class="muted">Symbols: ${n.symbols}</div>`;
        const expandNote = isExpandable(n)
          ? `<div class="muted" style="margin-top:4px;">Double-click to ${isDrilled(n) ? 'collapse' : 'expand'}</div>`
          : '';
        tooltip.innerHTML = `<div class="path">${n.type === 'symbol' ? n.label : n.path}</div>` +
          `<div class="muted">${kindLabel}</div>` + body + cycleNote + expandNote;
      } else {
        tooltip.style.display = 'none';
      }
    }
  });
  window.addEventListener('mouseup', () => {
    if (dragging) dragging.fixed = false;
    dragging = null; panStart = null;
  });
  canvas.addEventListener('mouseleave', () => { tooltip.style.display = 'none'; hoverNode = null; });
  canvas.addEventListener('click', e => {
    if (moved) return;
    const rect = canvas.getBoundingClientRect();
    const n = pickNode(e.clientX - rect.left, e.clientY - rect.top);
    focused = n ? n.id : null;
    renderFocusPanel();
  });
  canvas.addEventListener('dblclick', e => {
    const rect = canvas.getBoundingClientRect();
    const n = pickNode(e.clientX - rect.left, e.clientY - rect.top);
    if (!n) return;
    if (n.type === 'folder') {
      expanded.add(n.path);
      rebuild();
      return;
    }
    if (!isExpandable(n)) return;
    const key = n.type === 'file' ? fileNodeId(n.path) : n.id;
    if (expanded.has(key)) {
      expanded.delete(key);
      purgeDescendants(key);
    } else {
      expanded.add(key);
    }
    rebuild();
  });
  canvas.addEventListener('wheel', e => {
    e.preventDefault();
    const rect = canvas.getBoundingClientRect();
    const sx = e.clientX - rect.left, sy = e.clientY - rect.top;
    const [wx, wy] = toWorld(sx, sy);
    scale = Math.min(Math.max(scale * (e.deltaY < 0 ? 1.1 : 0.9), 0.1), 6);
    offsetX = sx - wx * scale; offsetY = sy - wy * scale;
  }, { passive: false });

  document.getElementById('search').addEventListener('input', e => {
    searchTerm = e.target.value.trim().toLowerCase();
  });
  document.getElementById('btnFit').addEventListener('click', fitView);
  document.getElementById('btnReset').addEventListener('click', () => { applyMainLayout(); fitView(); });

  const MODE_LABELS = { layered: 'leveled by depth', force: 'force-directed', radial: 'radial by depth' };
  document.querySelectorAll('.layoutBtn').forEach(btn => {
    btn.addEventListener('click', () => {
      const mode = btn.dataset.mode;
      if (mode === layoutMode) return;
      layoutMode = mode;
      document.querySelectorAll('.layoutBtn').forEach(b => b.classList.toggle('active', b.dataset.mode === mode));
      document.getElementById('modeLabel').textContent = MODE_LABELS[mode];
      rebuild();
      fitView();
    });
  });
  document.getElementById('btnExpandAll').addEventListener('click', () => { resetExpansion(true); rebuild(); fitView(); });
  document.getElementById('btnCollapse').addEventListener('click', () => { resetExpansion(false); rebuild(); fitView(); });
  document.getElementById('btnExport').addEventListener('click', exportPng);

  function exportPng() {
    const link = document.createElement('a');
    link.download = 'dependency-graph.png';
    link.href = canvas.toDataURL('image/png');
    link.click();
  }

  function renderFocusPanel() {
    const el = document.getElementById('focusPanel');
    if (!focused || !nodeById.has(focused)) { el.style.display = 'none'; return; }
    const n = nodeById.get(focused);
    const contains = edges.filter(e => e.from === focused && e.type === 'contains').map(e => e.to);
    el.style.display = 'block';
    const title = n.type === 'folder' ? 'Selected folder'
      : n.type === 'file' ? 'Selected file' : 'Selected ' + n.kind;
    let html = `<h2>${title}</h2>` +
      '<div class="path">' + n.path + (n.line ? ':' + n.line : '') + '</div>';
    if (contains.length > 0) {
      html += '<div class="muted">Contains (' + contains.length + ')</div><ul>' +
        contains.map(d => '<li>' + labelFor(d) + '</li>').join('') + '</ul>';
    }
    if (n.type === 'file' || n.type === 'folder') {
      const deps = edges.filter(e => e.from === focused && e.type === 'imports').map(e => e.to);
      const dependents = edges.filter(e => e.to === focused && e.type === 'imports').map(e => e.from);
      html += '<div class="muted">Imports (' + deps.length + ')</div><ul>' +
        deps.map(d => '<li>' + labelFor(d) + '</li>').join('') + '</ul>' +
        '<div class="muted">Imported by (' + dependents.length + ')</div><ul>' +
        dependents.map(d => '<li>' + labelFor(d) + '</li>').join('') + '</ul>';
    }
    el.innerHTML = html;
  }
  function labelFor(id) {
    const n = nodeById.get(id);
    if (!n) return id;
    return n.type === 'symbol' ? `${n.label} (${n.kind})` : n.path;
  }

  function renderExpandedList() {
    const section = document.getElementById('expandedSection');
    const entries = [...expanded].filter(key => {
      if (key.startsWith('file:') || key.startsWith('sym:')) return true;
      // Plain folder path: only show ones the user drilled into beyond the
      // default depth-1 auto-expansion, so this list stays meaningful on
      // large projects.
      return key.includes('/') || DATA.nodes.length <= AUTO_COLLAPSE_THRESHOLD;
    });
    if (entries.length === 0) { section.hidden = true; return; }
    section.hidden = false;
    const listEl = document.getElementById('expandedList');
    listEl.innerHTML = entries.sort().map(key => {
      let label;
      if (key.startsWith('file:')) {
        label = key.slice(5) + ' (contents)';
      } else if (key.startsWith('sym:')) {
        const sn = symbolNodeById.get(key);
        label = sn ? `${sn.label} (${sn.kind} members)` : key;
      } else {
        label = key + '/';
      }
      return `<li><span>${label}</span><button data-key="${key}" title="Collapse">&times;</button></li>`;
    }).join('');
    listEl.querySelectorAll('button[data-key]').forEach(btn => {
      btn.addEventListener('click', () => {
        const key = btn.dataset.key;
        expanded.delete(key);
        purgeDescendants(key);
        rebuild();
      });
    });
  }

  const cyclesEl = document.getElementById('cycles');
  if (DATA.cycles.length === 0) {
    cyclesEl.innerHTML = '<li style="background:none;color:#8b93a7;cursor:default;">None detected</li>';
  } else {
    cyclesEl.innerHTML = DATA.cycles
      .map((c, i) => '<li data-i="' + i + '">Cycle ' + (i + 1) + ' &middot; ' + c.length + ' files</li>')
      .join('');
    cyclesEl.querySelectorAll('li[data-i]').forEach(li => {
      li.addEventListener('click', () => {
        const fileId = DATA.cycles[+li.dataset.i][0];
        // Expand every ancestor of the cycle's first file so it's visible
        // even when the graph currently has it collapsed into a folder.
        for (const anc of nodeAncestors.get(fileId) || []) expanded.add(anc);
        rebuild();
        focused = fileId;
        renderFocusPanel();
      });
    });
  }

  function renderLegend() {
    const legendEl = document.getElementById('legend');
    const groups = [...new Set(nodes.filter(n => n.type !== 'symbol').map(n => n.group))].sort();
    const kindsPresent = [...new Set(nodes.filter(n => n.type === 'symbol').map(n => n.kind))].sort();
    const hasCycleColor = nodes.some(n => n.crossCycleGroup != null);
    const hasHiddenColor = nodes.some(n => n.hasHiddenCycle && n.crossCycleGroup == null);
    let html = '';
    if (hasCycleColor) {
      html += '<div><span class="swatch" style="background:#e5484d"></span>circular dependency</div>';
    }
    if (hasHiddenColor) {
      html += '<div><span class="swatch" style="background:#d68a3f"></span>hidden cycle inside</div>';
    }
    html += groups.map(g =>
      '<div><span class="swatch" style="background:hsl(' + hashHue(g) + ' 55% 58%)"></span>' + g + '</div>'
    ).join('');
    if (kindsPresent.length > 0) {
      html += '<div class="muted" style="margin:10px 0 4px;">Symbol kinds (expanded)</div>' +
        kindsPresent.map(k =>
          '<div><span class="swatch" style="background:' + kindColor(k) + '"></span>' + k + '</div>'
        ).join('');
    }
    legendEl.innerHTML = html;
  }

  rebuild();
  resize();
  fitView();
  requestAnimationFrame(draw);
})();
</script>
</body>
</html>
''';
