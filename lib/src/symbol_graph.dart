import 'package:path/path.dart' as p;

import 'code_index.dart';
import 'graph.dart';
import 'model.dart';

/// A node in the richer symbol-level graph: not just files, but the classes,
/// methods, functions, fields, etc. inside them, structured as a tree
/// (file -> top-level symbol -> member) via [parentId].
class SymbolGraphNode {
  /// Unique id: `file:<path>` for a file, `sym:<path>:<line>:<name>` for a
  /// symbol.
  final String id;

  /// `file`, or the symbol's kind (class, method, function, ...).
  final String kind;

  /// Display label (filename for a file, symbol name otherwise).
  final String label;

  /// Project-relative, posix-style path of the containing file.
  final String path;

  /// Source line, or `null` for a file node.
  final int? line;

  /// The enclosing node's [id] (a file, or a containing class), or `null`
  /// for a top-level file node.
  final String? parentId;

  SymbolGraphNode({
    required this.id,
    required this.kind,
    required this.label,
    required this.path,
    required this.line,
    required this.parentId,
  });
}

/// An edge in the symbol graph: 'contains' for structural nesting
/// (file contains a top-level symbol, a class contains its methods/fields),
/// or 'imports' for a file-to-file import dependency.
class SymbolGraphEdge {
  /// Source node id.
  final String from;

  /// Target node id.
  final String to;

  /// `'contains'` (structural nesting) or `'imports'` (file dependency).
  final String type;

  SymbolGraphEdge(this.from, this.to, this.type);
}

/// The full symbol-level graph for a project: files, their nested symbols,
/// and both the containment and import relationships between them. See
/// [buildSymbolGraph].
class SymbolGraph {
  final List<SymbolGraphNode> nodes;
  final List<SymbolGraphEdge> edges;

  SymbolGraph(this.nodes, this.edges);
}

const _containerKinds = {'class', 'mixin', 'enum', 'extension'};

/// The [SymbolGraphNode.id] for the file at [posixPath].
String fileNodeId(String posixPath) => 'file:$posixPath';

String _symbolNodeId(String posixPath, DartSymbol symbol) =>
    'sym:$posixPath:${symbol.line}:${symbol.name}';

/// Builds the full symbol-level graph for [index]: one node per file plus
/// one node per indexed symbol (classes, methods, functions, fields,
/// constructors, ...), linked by 'contains' edges reflecting the actual
/// nesting in the source, plus the same file-to-file 'imports' edges
/// [buildDependencyGraph] produces.
SymbolGraph buildSymbolGraph(CodeIndex index) {
  final nodes = <SymbolGraphNode>[];
  final edges = <SymbolGraphEdge>[];

  final depGraph = buildDependencyGraph(index);
  final filePaths = <String>{for (final n in depGraph.nodes) n.path};

  for (final file in index.files) {
    final posixPath = file.path.replaceAll('\\', '/');
    if (!filePaths.contains(posixPath)) continue;

    nodes.add(
      SymbolGraphNode(
        id: fileNodeId(posixPath),
        kind: 'file',
        label: p.posix.basename(posixPath),
        path: posixPath,
        line: null,
        parentId: null,
      ),
    );

    final containerIdByName = <String, String>{};
    for (final symbol in file.symbols) {
      if (symbol.container == null && _containerKinds.contains(symbol.kind)) {
        containerIdByName[symbol.name] = _symbolNodeId(posixPath, symbol);
      }
    }

    for (final symbol in file.symbols) {
      final id = _symbolNodeId(posixPath, symbol);
      final parentId = symbol.container == null
          ? fileNodeId(posixPath)
          : (containerIdByName[symbol.container] ?? fileNodeId(posixPath));
      nodes.add(
        SymbolGraphNode(
          id: id,
          kind: symbol.kind,
          label: symbol.name,
          path: posixPath,
          line: symbol.line,
          parentId: parentId,
        ),
      );
      edges.add(SymbolGraphEdge(parentId, id, 'contains'));
    }
  }

  for (final edge in depGraph.edges) {
    edges.add(
      SymbolGraphEdge(fileNodeId(edge.from), fileNodeId(edge.to), 'imports'),
    );
  }

  return SymbolGraph(nodes, edges);
}
