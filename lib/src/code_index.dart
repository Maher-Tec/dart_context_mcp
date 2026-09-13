import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_scan.dart';
import 'import_resolver.dart';
import 'indexer.dart';
import 'model.dart';

/// Name of the directory (under a project root) the index and generated
/// files (`index.json`, `graph.html`) are stored in.
const String indexDirectoryName = '.dart_context';

/// Filename of the persisted index within [indexDirectoryName].
const String indexFileName = 'index.json';

/// Output of a read-only query against a [CodeIndex]. [isError] mirrors the
/// distinction the CLI makes between stdout/exit-0 and stderr/exit-1, and
/// maps directly onto the MCP `isError` field on a tool result.
class CommandOutput {
  /// The report text (or a JSON-encoded string, when a `format: json`
  /// request produced this output).
  final String text;

  /// Whether this represents a failure (unknown symbol, invalid input, ...).
  final bool isError;

  const CommandOutput(this.text, {this.isError = false});
}

/// A parsed, queryable snapshot of a Dart/Flutter project: every indexed
/// file's imports and symbols, plus the read-only queries built on top of
/// them ([findSymbols], [referencesTo], [query]).
class CodeIndex {
  /// Absolute path to the project root this index was built from.
  final String rootPath;

  /// The project's directory name, used for display (e.g. "Overview: name").
  final String projectName;

  /// When this index was built.
  final DateTime generatedAt;

  /// Every indexed `.dart` file.
  final List<DartFileIndex> files;

  List<DartSymbol>? _symbolsCache;

  /// In-memory cache of file contents, keyed by relative path, so a
  /// long-lived process (the MCP server) doesn't re-read every source file
  /// from disk on every `context`/`impact`/`query` call. Invalidated
  /// per-file by comparing mtimes.
  final Map<String, _CachedLines> _lineCache = {};

  CodeIndex({
    required this.rootPath,
    required this.projectName,
    required this.generatedAt,
    required this.files,
  });

  /// Absolute path to the persisted index file under [rootPath].
  String get indexPath => p.join(rootPath, indexDirectoryName, indexFileName);

  /// Every symbol across every indexed file, flattened and cached.
  List<DartSymbol> get symbols =>
      _symbolsCache ??= [for (final file in files) ...file.symbols];

  /// Writes this index to [indexPath] as pretty-printed JSON.
  void save() {
    final directory = Directory(p.join(rootPath, indexDirectoryName));
    directory.createSync(recursive: true);
    File(
      indexPath,
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
  }

  /// Loads the persisted index at [rootPath] if one exists and is still
  /// fresh, otherwise builds (and persists) a new one from source.
  static CodeIndex loadOrBuild(String rootPath) {
    final normalizedRoot = p.normalize(p.absolute(rootPath));
    final indexFile = File(
      p.join(normalizedRoot, indexDirectoryName, indexFileName),
    );
    if (!indexFile.existsSync()) {
      final index = DartContextIndexer(normalizedRoot).build();
      index.save();
      return index;
    }
    final index = CodeIndex.fromJson(
      jsonDecode(indexFile.readAsStringSync()) as Map<String, Object?>,
    );
    if (index._isStale()) {
      final rebuilt = DartContextIndexer(normalizedRoot).build();
      rebuilt.save();
      return rebuilt;
    }
    return index;
  }

  /// The indexed file at [relativePath] (posix-style), or `null` if it
  /// isn't tracked.
  DartFileIndex? fileFor(String relativePath) {
    for (final file in files) {
      if (file.path == relativePath) return file;
    }
    return null;
  }

  /// Finds symbols matching [query]: an exact (case-insensitive) name match
  /// if one exists, otherwise every symbol whose display name contains
  /// [query] as a substring.
  List<DartSymbol> findSymbols(String query) {
    final normalized = query.toLowerCase();
    final exact = symbols
        .where((symbol) => symbol.name.toLowerCase() == normalized)
        .toList();
    if (exact.isNotEmpty) return exact;
    return symbols
        .where(
          (symbol) => symbol.displayName.toLowerCase().contains(normalized),
        )
        .toList();
  }

  /// Text-based references to [symbolName]: every line (outside comments
  /// and plain string literals) that mentions it as a whole word, up to
  /// [limit]. Pass [excludeDeclaration] to skip the declaration's own line.
  /// See the class-level heuristics this applies for ambiguous names.
  List<CodeReference> referencesTo(
    String symbolName, {
    DartSymbol? excludeDeclaration,
    int limit = 40,
  }) {
    final matcher = RegExp(r'\b' + RegExp.escape(symbolName) + r'\b');

    // If more than one declared symbol shares this name (e.g. two unrelated
    // classes both called `Item`), a plain project-wide text search mixes
    // their references together with no way to tell which is which. Narrow
    // the search to files that could plausibly mean *this* declaration: the
    // declaring file itself, plus files that directly import it. This is a
    // heuristic, not a resolver - it misses a name reached only through a
    // transitive re-export (`export` barrel files), and it still can't tell
    // two same-named symbols apart if they're imported into the same file
    // under no prefix - but it eliminates the common case of unrelated
    // same-named symbols in unrelated parts of the project bleeding into
    // each other's results.
    Set<String>? scopeFiles;
    if (excludeDeclaration != null &&
        symbols.where((s) => s.name == symbolName).length > 1) {
      scopeFiles = _filesThatImport(excludeDeclaration.path);
    }

    final references = <CodeReference>[];
    for (final file in files) {
      if (scopeFiles != null && !scopeFiles.contains(file.path)) continue;
      final lines = _linesFor(file.path);
      if (lines == null) continue;
      for (var i = 0; i < lines.length; i++) {
        final lineNumber = i + 1;
        if (excludeDeclaration != null &&
            file.path == excludeDeclaration.path &&
            lineNumber == excludeDeclaration.line) {
          continue;
        }
        final line = lines[i];
        // Match against the comment/string-masked line so a name that only
        // appears inside a `//` comment or a plain string literal (e.g. a
        // user-facing message that happens to contain the symbol's name)
        // isn't counted as a real reference. Code inside string
        // interpolation (`$name` / `${expr}`) is left unmasked since that's
        // an actual usage, not incidental text.
        if (!matcher.hasMatch(_maskCommentsAndStrings(line))) continue;
        references.add(
          CodeReference(
            path: file.path,
            line: lineNumber,
            snippet: compactSnippet(line),
          ),
        );
        if (references.length >= limit) return references;
      }
    }
    return references;
  }

  /// Files that are `declaringPath` itself, or that directly `import` it
  /// (resolved the same way the dependency graph resolves imports). Doesn't
  /// follow transitive re-exports - see [referencesTo].
  Set<String> _filesThatImport(String declaringPath) {
    final packageName = readPackageName(rootPath);
    final declaringPosix = toPosixPath(declaringPath);
    final result = <String>{declaringPath};
    for (final file in files) {
      final fromPosix = toPosixPath(file.path);
      final fromDir = p.posix.dirname(fromPosix);
      for (final import in file.imports) {
        final targetPosix = resolveImportToPosixPath(
          import,
          fromDir,
          packageName,
        );
        if (targetPosix == declaringPosix) {
          result.add(file.path);
          break;
        }
      }
    }
    return result;
  }

  /// Free-text search across symbol names and source lines, ranked by a
  /// simple term-frequency score, returning up to [limit] files.
  List<QueryResult> query(String query, {int limit = 10}) {
    final terms = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9_]+'))
        .where((term) => term.length >= 2)
        .toSet()
        .toList();
    if (terms.isEmpty) return const [];

    final results = <QueryResult>[];
    for (final file in files) {
      final lines = _linesFor(file.path);
      if (lines == null) continue;
      var score = 0;
      final hits = <CodeReference>[];

      for (final symbol in file.symbols) {
        final haystack =
            '${symbol.displayName} ${symbol.kind} ${symbol.path} ${symbol.signature}'
                .toLowerCase();
        for (final term in terms) {
          if (haystack.contains(term)) score += 12;
        }
      }

      for (var i = 0; i < lines.length; i++) {
        final lower = _maskCommentsAndStrings(lines[i]).toLowerCase();
        var lineScore = 0;
        for (final term in terms) {
          if (lower.contains(term)) lineScore += 2;
        }
        if (lineScore == 0) continue;
        score += lineScore;
        if (hits.length < 6) {
          hits.add(
            CodeReference(
              path: file.path,
              line: i + 1,
              snippet: compactSnippet(lines[i]),
            ),
          );
        }
      }

      if (score > 0) {
        results.add(
          QueryResult(
            path: file.path,
            score: score,
            symbols: file.symbols.map((symbol) => symbol.displayName).toList(),
            hits: hits,
          ),
        );
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(limit).toList();
  }

  List<String>? _linesFor(String relativePath) {
    final absolute = File(p.join(rootPath, relativePath));
    FileStat stat;
    try {
      stat = absolute.statSync();
    } on FileSystemException {
      return null;
    }
    if (stat.type == FileSystemEntityType.notFound) return null;

    final cached = _lineCache[relativePath];
    if (cached != null && cached.mtime == stat.modified) {
      return cached.lines;
    }
    try {
      final lines = absolute.readAsLinesSync();
      _lineCache[relativePath] = _CachedLines(stat.modified, lines);
      return lines;
    } on FileSystemException {
      return null;
    }
  }

  /// True if the persisted index no longer reflects what's on disk: a
  /// tracked file changed or disappeared, or a new (non-ignored, non
  /// -generated) `.dart` file was added. Checking the current file listing
  /// (not just the mtimes of files already in the index) is what lets a
  /// freshly-added file get picked up on the next load.
  bool _isStale() {
    // listDartFilePaths returns OS-native relative paths (it uses p.split
    // internally to check ignored directories); indexed file.path is
    // posix-normalized (see indexer.dart). Normalize both to the same form
    // before comparing, or this would report every file as added+removed
    // on every check on Windows.
    final currentPaths = listDartFilePaths(rootPath).map(toPosixPath).toSet();
    final indexedPaths = files.map((file) => file.path).toSet();
    if (!_setsEqual(currentPaths, indexedPaths)) return true;

    for (final file in files) {
      final sourceFile = File(p.join(rootPath, file.path));
      FileStat stat;
      try {
        stat = sourceFile.statSync();
      } on FileSystemException {
        return true;
      }
      if (stat.type == FileSystemEntityType.notFound) return true;
      if (file.mtime == null) return true;
      if (stat.modified.toUtc().isAfter(file.mtime!)) return true;
    }
    return false;
  }

  static bool _setsEqual(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  /// Serializes this index for [save]/persistence.
  Map<String, Object?> toJson() => {
    'rootPath': rootPath,
    'projectName': projectName,
    'generatedAt': generatedAt.toIso8601String(),
    'files': files.map((file) => file.toJson()).toList(),
  };

  /// Deserializes an index previously written by [toJson].
  factory CodeIndex.fromJson(Map<String, Object?> json) => CodeIndex(
    rootPath: json['rootPath'] as String,
    projectName: json['projectName'] as String,
    generatedAt: DateTime.parse(json['generatedAt'] as String),
    files: (json['files'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(DartFileIndex.fromJson)
        .toList(),
  );
}

/// Keeps one [CodeIndex] per project root alive across repeated calls (used
/// by the MCP server, which is a long-lived process) so the in-memory line
/// cache and the parsed symbol table survive between tool calls. A cheap
/// staleness check runs before every reuse, so edits on disk are still
/// picked up without restarting the server.
class IndexCache {
  final Map<String, CodeIndex> _cache = {};

  /// The cached index for [root], reused as-is if still fresh, otherwise
  /// reloaded/rebuilt via [CodeIndex.loadOrBuild] and re-cached.
  CodeIndex get(String root) {
    final normalized = p.normalize(p.absolute(root));
    final cached = _cache[normalized];
    if (cached != null && !cached._isStale()) return cached;
    final fresh = CodeIndex.loadOrBuild(normalized);
    _cache[normalized] = fresh;
    return fresh;
  }

  /// Registers [index] as the cached index for [root], e.g. right after an
  /// explicit rebuild so the next [get] doesn't reload it from disk.
  void put(String root, CodeIndex index) {
    _cache[p.normalize(p.absolute(root))] = index;
  }
}

/// Blanks out `//` line comments and string literal contents (keeping the
/// line the same length, since callers report literal snippets from the
/// original) so name-matching doesn't fire on an incidental mention inside
/// a comment or a user-facing message. String interpolation (`$name` /
/// `${expr}`) is passed through unmasked - that's real code, not text.
/// Line-based and not a real Dart lexer: it doesn't handle multi-line
/// strings/comments (`'''...'''`, `/* ... */`), so those false positives
/// can still slip through - a best-effort heuristic, not a guarantee.
String _maskCommentsAndStrings(String line) {
  final out = StringBuffer();
  final n = line.length;
  var i = 0;
  String? quote;
  while (i < n) {
    final ch = line[i];
    if (quote == null) {
      if (ch == '/' && i + 1 < n && line[i + 1] == '/') {
        out.write(' ' * (n - i));
        break;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        out.write(' ');
        i++;
        continue;
      }
      out.write(ch);
      i++;
      continue;
    }
    if (ch == r'\' && i + 1 < n) {
      out.write('  ');
      i += 2;
      continue;
    }
    if (ch == quote) {
      quote = null;
      out.write(' ');
      i++;
      continue;
    }
    if (ch == r'$' && i + 1 < n && line[i + 1] == '{') {
      out.write('  ');
      i += 2;
      var depth = 1;
      while (i < n && depth > 0) {
        final c2 = line[i];
        if (c2 == '{') depth++;
        if (c2 == '}') depth--;
        out.write(depth > 0 ? c2 : ' ');
        i++;
      }
      continue;
    }
    if (ch == r'$' && i + 1 < n && _isIdentStart(line[i + 1])) {
      out.write(' ');
      i++;
      while (i < n && _isIdentPart(line[i])) {
        out.write(line[i]);
        i++;
      }
      continue;
    }
    out.write(' ');
    i++;
  }
  return out.toString();
}

bool _isIdentStart(String c) => RegExp(r'[A-Za-z_]').hasMatch(c);
bool _isIdentPart(String c) => RegExp(r'[A-Za-z0-9_]').hasMatch(c);

class _CachedLines {
  final DateTime mtime;
  final List<String> lines;

  _CachedLines(this.mtime, this.lines);
}

/// Parses a `--limit`/`limit` CLI argument, falling back to
/// [defaultValue] for anything missing or non-positive, and clamping to
/// a sane range of 1 to 500.
int parseLimit(String? raw, {required int defaultValue}) {
  final parsed = int.tryParse(raw ?? '');
  if (parsed == null || parsed <= 0) return defaultValue;
  return parsed.clamp(1, 500).toInt();
}

/// A LOW/MEDIUM/HIGH heuristic risk rating for `dart_impact`, based on how
/// many distinct files ([fileCount]) and total lines ([referenceCount])
/// reference a symbol.
String riskFor(int fileCount, int referenceCount) {
  if (fileCount >= 12 || referenceCount >= 80) return 'HIGH';
  if (fileCount >= 5 || referenceCount >= 25) return 'MEDIUM';
  return 'LOW';
}

/// Report for the `index` command: file/symbol counts and where the index
/// was written.
CommandOutput buildIndexReport(CodeIndex index) {
  final buffer = StringBuffer()
    ..writeln('Indexed ${index.projectName}')
    ..writeln('Root: ${index.rootPath}')
    ..writeln('Files: ${index.files.length}')
    ..writeln('Symbols: ${index.symbols.length}')
    ..writeln('Index: ${index.indexPath}');
  return CommandOutput(buffer.toString().trimRight());
}

/// Report for the `symbols` command: a filtered, capped list of indexed
/// symbols matching [kind] and/or [query].
CommandOutput buildSymbolsReport(
  CodeIndex index, {
  String? kind,
  String? query,
  required int limit,
}) {
  final normalizedKind = kind?.toLowerCase();
  final normalizedQuery = query?.toLowerCase();
  final matches = index.symbols
      .where((symbol) {
        final kindMatches =
            normalizedKind == null || symbol.kind == normalizedKind;
        final queryMatches =
            normalizedQuery == null ||
            symbol.name.toLowerCase().contains(normalizedQuery) ||
            symbol.path.toLowerCase().contains(normalizedQuery) ||
            (symbol.container ?? '').toLowerCase().contains(normalizedQuery);
        return kindMatches && queryMatches;
      })
      .take(limit)
      .toList();

  final buffer = StringBuffer()
    ..writeln('Symbols (${matches.length} shown of ${index.symbols.length})');
  for (final symbol in matches) {
    buffer.writeln(symbol.toOneLine());
  }
  return CommandOutput(buffer.toString().trimRight());
}

/// Report for the `context` command: full detail on the symbol matching
/// [name] - location, signature, imports, nearby symbols, and references -
/// or a disambiguation list if more than one symbol matches.
CommandOutput buildContextReport(
  CodeIndex index,
  String name, {
  required int limit,
  OutputFormat format = OutputFormat.text,
}) {
  final matches = index.findSymbols(name);
  if (matches.isEmpty) {
    return CommandOutput(
      'No symbol found for "$name". Try the query tool/command instead.',
      isError: true,
    );
  }

  if (matches.length > 1) {
    if (format == OutputFormat.json) {
      return CommandOutput(
        jsonEncode({
          'ambiguous': true,
          'query': name,
          'matches': matches.take(20).map((s) => s.toJson()).toList(),
        }),
      );
    }
    final buffer = StringBuffer()..writeln('Multiple symbols match "$name":');
    for (final symbol in matches.take(20)) {
      buffer.writeln(symbol.toOneLine());
    }
    buffer.writeln('Use a more specific name if needed.');
    return CommandOutput(buffer.toString().trimRight());
  }

  final symbol = matches.single;
  final file = index.fileFor(symbol.path);
  final references = index.referencesTo(
    symbol.name,
    excludeDeclaration: symbol,
    limit: limit,
  );
  final nearby = index.symbols
      .where((candidate) => candidate.path == symbol.path)
      .where((candidate) => candidate.name != symbol.name)
      .take(16)
      .toList();

  if (format == OutputFormat.json) {
    return CommandOutput(
      jsonEncode({
        'symbol': symbol.toJson(),
        'imports': file?.imports ?? const [],
        'nearby': nearby.map((s) => s.toJson()).toList(),
        'references': references.map((r) => r.toJson()).toList(),
      }),
    );
  }

  final buffer = StringBuffer()
    ..writeln('Symbol: ${symbol.displayName}')
    ..writeln('Kind: ${symbol.kind}')
    ..writeln('Location: ${symbol.path}:${symbol.line}');
  if (symbol.container != null) {
    buffer.writeln('Container: ${symbol.container}');
  }
  if (symbol.signature.isNotEmpty) {
    buffer.writeln('Signature: ${symbol.signature}');
  }
  if (file != null && file.imports.isNotEmpty) {
    buffer.writeln('\nImports (${file.imports.length}):');
    for (final import in file.imports.take(12)) {
      buffer.writeln('- $import');
    }
  }

  buffer.writeln('\nNearby symbols:');
  for (final candidate in nearby) {
    buffer.writeln(
      '- ${candidate.displayName} (${candidate.kind}) line ${candidate.line}',
    );
  }

  buffer.writeln('\nReferences:');
  if (references.isEmpty) {
    buffer.writeln('- No direct text references found.');
  } else {
    for (final reference in references) {
      buffer.writeln(reference.toOneLine());
    }
  }
  return CommandOutput(buffer.toString().trimRight());
}

/// Report for the `impact` command: a LOW/MEDIUM/HIGH risk rating and the
/// grouped, deduped references to the symbol matching [name].
CommandOutput buildImpactReport(
  CodeIndex index,
  String name, {
  required int limit,
  OutputFormat format = OutputFormat.text,
}) {
  final matches = index.findSymbols(name);
  if (matches.isEmpty) {
    return CommandOutput(
      'No symbol found for "$name". Try the query tool/command instead.',
      isError: true,
    );
  }

  final symbol = matches.first;
  final references = index.referencesTo(
    symbol.name,
    excludeDeclaration: symbol,
    limit: limit,
  );
  final touchedFiles = references.map((reference) => reference.path).toSet();
  final risk = riskFor(touchedFiles.length, references.length);

  final grouped = <String, List<CodeReference>>{};
  for (final reference in references) {
    grouped.putIfAbsent(reference.path, () => []).add(reference);
  }

  if (format == OutputFormat.json) {
    return CommandOutput(
      jsonEncode({
        'symbol': symbol.toJson(),
        'risk': risk,
        'referencingFiles': touchedFiles.length,
        'referenceHits': references.length,
        'references': references.map((r) => r.toJson()).toList(),
      }),
    );
  }

  final buffer = StringBuffer()
    ..writeln('Impact: ${symbol.displayName}')
    ..writeln('Declaration: ${symbol.path}:${symbol.line}')
    ..writeln('Risk: $risk')
    ..writeln('Referencing files: ${touchedFiles.length}')
    ..writeln('Reference hits: ${references.length}')
    ..writeln('');

  for (final entry in grouped.entries) {
    buffer.writeln(entry.key);
    for (final reference in entry.value.take(5)) {
      buffer.writeln('  ${reference.line}: ${reference.snippet}');
    }
  }
  return CommandOutput(buffer.toString().trimRight());
}

/// Report for the `query` command: free-text search results ranked by
/// score.
CommandOutput buildQueryReport(
  CodeIndex index,
  String query, {
  required int limit,
  OutputFormat format = OutputFormat.text,
}) {
  final results = index.query(query, limit: limit);
  if (results.isEmpty) {
    return CommandOutput('No results for "$query".', isError: true);
  }

  if (format == OutputFormat.json) {
    return CommandOutput(
      jsonEncode({
        'query': query,
        'results': [
          for (final result in results)
            {
              'path': result.path,
              'score': result.score,
              'symbols': result.symbols,
              'hits': result.hits.map((h) => h.toJson()).toList(),
            },
        ],
      }),
    );
  }

  final buffer = StringBuffer()..writeln('Query: $query');
  for (var i = 0; i < results.length; i++) {
    final result = results[i];
    buffer.writeln('\n${i + 1}. ${result.path}  score=${result.score}');
    if (result.symbols.isNotEmpty) {
      buffer.writeln('   symbols: ${result.symbols.take(6).join(', ')}');
    }
    for (final hit in result.hits.take(4)) {
      buffer.writeln('   ${hit.line}: ${hit.snippet}');
    }
  }
  return CommandOutput(buffer.toString().trimRight());
}
