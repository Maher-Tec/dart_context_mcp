/// Data types shared by the indexer, the CLI, and the MCP server.
class DartSymbol {
  final String name;
  final String kind;
  final String path;
  final int line;
  final int column;
  final String? container;
  final String signature;

  DartSymbol({
    required this.name,
    required this.kind,
    required this.path,
    required this.line,
    required this.column,
    required this.container,
    required this.signature,
  });

  String get displayName => container == null ? name : '$container.$name';

  String toOneLine() => '$kind $displayName  $path:$line';

  Map<String, Object?> toJson() => {
    'name': name,
    'kind': kind,
    'path': path,
    'line': line,
    'column': column,
    'container': container,
    'signature': signature,
  };

  factory DartSymbol.fromJson(Map<String, Object?> json) => DartSymbol(
    name: json['name'] as String,
    kind: json['kind'] as String,
    path: json['path'] as String,
    line: json['line'] as int,
    column: json['column'] as int,
    container: json['container'] as String?,
    signature: json['signature'] as String,
  );
}

class DartFileIndex {
  final String path;
  final List<String> imports;
  final List<DartSymbol> symbols;

  /// Modification time of the source file when it was parsed, used for
  /// staleness detection. Not required for older, already-persisted indexes.
  final DateTime? mtime;

  DartFileIndex({
    required this.path,
    required this.imports,
    required this.symbols,
    this.mtime,
  });

  Map<String, Object?> toJson() => {
    'path': path,
    'imports': imports,
    'symbols': symbols.map((symbol) => symbol.toJson()).toList(),
    if (mtime != null) 'mtime': mtime!.toIso8601String(),
  };

  factory DartFileIndex.fromJson(Map<String, Object?> json) => DartFileIndex(
    path: json['path'] as String,
    imports: (json['imports'] as List<Object?>).cast<String>(),
    symbols: (json['symbols'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(DartSymbol.fromJson)
        .toList(),
    mtime: json['mtime'] == null
        ? null
        : DateTime.parse(json['mtime'] as String),
  );
}

class CodeReference {
  final String path;
  final int line;
  final String snippet;

  CodeReference({
    required this.path,
    required this.line,
    required this.snippet,
  });

  String toOneLine() => '- $path:$line  $snippet';

  Map<String, Object?> toJson() => {
    'path': path,
    'line': line,
    'snippet': snippet,
  };
}

/// Output shape for `context`/`impact`/`query`/`overview`: the default
/// `text` is the existing compact, human-readable report; `json` returns
/// the same underlying data as a single JSON object, for an agent that
/// needs to read one field (a risk level, a file path) without re-parsing
/// prose it would otherwise have to guess the layout of.
enum OutputFormat { text, json }

OutputFormat parseOutputFormat(String? raw) =>
    raw?.toLowerCase() == 'json' ? OutputFormat.json : OutputFormat.text;

class QueryResult {
  final String path;
  final int score;
  final List<String> symbols;
  final List<CodeReference> hits;

  QueryResult({
    required this.path,
    required this.score,
    required this.symbols,
    required this.hits,
  });
}

String compactSnippet(String line) {
  final compact = line.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (compact.length <= 120) return compact;
  return '${compact.substring(0, 117)}...';
}
