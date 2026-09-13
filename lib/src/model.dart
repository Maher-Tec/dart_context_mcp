/// One indexed Dart declaration: a class, method, function, field,
/// constructor, enum, enum constant, extension, mixin, or typedef.
class DartSymbol {
  /// The symbol's bare name, e.g. `build` for a method or `Widget` for a
  /// class. Does not include the enclosing [container].
  final String name;

  /// One of: class, mixin, enum, enum_constant, extension, typedef,
  /// function, variable, constructor, method, field.
  final String kind;

  /// Project-relative, posix-style path (forward slashes on every
  /// platform) of the file this symbol is declared in.
  final String path;

  /// 1-based source line of the declaration.
  final int line;

  /// 1-based source column of the declaration.
  final int column;

  /// The enclosing class/mixin/enum/extension name, or `null` for a
  /// top-level declaration.
  final String? container;

  /// The declaration's signature (return type, parameters, or a doc
  /// comment prefix for fields/enum constants), used for display.
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

  /// `Container.name` when nested, otherwise just [name] - matches how
  /// Dart 3 constructor tear-offs and member references are written.
  String get displayName => container == null ? name : '$container.$name';

  /// A single-line summary: `kind displayName  path:line`.
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

/// One indexed `.dart` file: its imports and the symbols declared in it.
class DartFileIndex {
  /// Project-relative, posix-style path of this file.
  final String path;

  /// Raw import URIs as written in the source (`package:...`, relative,
  /// or `dart:...`) - not yet resolved to other indexed files.
  final List<String> imports;

  /// Every symbol declared directly in this file, including nested ones
  /// (a class's methods/fields appear here too, not just the class itself).
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

/// One line of source text that mentions a symbol's name, found by
/// [CodeIndex.referencesTo] or [CodeIndex.query].
class CodeReference {
  /// Project-relative, posix-style path of the file containing this line.
  final String path;

  /// 1-based line number.
  final int line;

  /// The line's text, whitespace-collapsed and truncated for display.
  final String snippet;

  CodeReference({
    required this.path,
    required this.line,
    required this.snippet,
  });

  /// A single-line summary: `- path:line  snippet`.
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
enum OutputFormat {
  /// Compact, human-readable report text (the default).
  text,

  /// The same data as a single JSON object.
  json,
}

/// Parses a `--format`/`format` argument into an [OutputFormat], defaulting
/// to [OutputFormat.text] for `null` or anything other than `"json"`.
OutputFormat parseOutputFormat(String? raw) =>
    raw?.toLowerCase() == 'json' ? OutputFormat.json : OutputFormat.text;

/// One file's free-text search score and matching lines, from
/// [CodeIndex.query].
class QueryResult {
  /// Project-relative, posix-style path of the matching file.
  final String path;

  /// Relevance score - higher means a stronger match. Not normalized or
  /// comparable across different queries.
  final int score;

  /// Display names of every symbol declared in this file, regardless of
  /// whether they matched the query.
  final List<String> symbols;

  /// The matching lines, in file order.
  final List<CodeReference> hits;

  QueryResult({
    required this.path,
    required this.score,
    required this.symbols,
    required this.hits,
  });
}

/// Trims whitespace, collapses internal runs of whitespace to a single
/// space, and truncates to 120 characters - used to keep a source line
/// short enough for a one-line report entry.
String compactSnippet(String line) {
  final compact = line.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (compact.length <= 120) return compact;
  return '${compact.substring(0, 117)}...';
}
