import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'code_index.dart';
import 'graph.dart';
import 'import_resolver.dart';
import 'model.dart';

/// A compact, one-call snapshot of an unfamiliar Dart/Flutter project: what
/// it depends on, how `lib/` is organized, where execution starts, and
/// which files the rest of the codebase leans on most. Meant to replace the
/// handful of exploratory reads (`pubspec.yaml`, `lib/main.dart`, poking
/// around folders) an agent would otherwise burn tokens on just to get
/// oriented before doing real work.
CommandOutput buildOverviewReport(
  CodeIndex index, {
  OutputFormat format = OutputFormat.text,
}) {
  final pubspecFile = File(p.join(index.rootPath, 'pubspec.yaml'));
  final pubspecContent = pubspecFile.existsSync()
      ? pubspecFile.readAsStringSync()
      : '';
  final dependencies = _parseSectionKeys(pubspecContent, 'dependencies');
  final sdkConstraint = _parseSdkConstraint(pubspecContent);
  final isFlutter = dependencies.contains('flutter');

  final graph = buildDependencyGraph(index);
  final cycles = detectCycles(graph);
  final inDegree = <String, int>{};
  for (final edge in graph.edges) {
    inDegree[edge.to] = (inDegree[edge.to] ?? 0) + 1;
  }

  // Files directly under lib/ (main.dart, app.dart, ...) are called out
  // individually - they're usually the small set of entry-ish files worth
  // naming, unlike a flat file directly under some other top-level
  // directory (test/foo_test.dart), which is grouped like anything else.
  final topLevelFiles = <String>[];
  final folders = <String, _FolderStats>{};
  for (final file in index.files) {
    final posix = toPosixPath(file.path);
    final parts = posix.split('/');
    if (parts.length == 2 && parts[0] == 'lib') {
      topLevelFiles.add(posix);
      continue;
    }
    final key = parts.length > 2 ? '${parts[0]}/${parts[1]}' : parts[0];
    final stats = folders.putIfAbsent(key, () => _FolderStats());
    stats.fileCount++;
    stats.symbolCount += file.symbols.length;
  }
  topLevelFiles.sort();
  final sortedFolders = folders.entries.toList()
    ..sort((a, b) => b.value.fileCount.compareTo(a.value.fileCount));

  DartFileIndex? mainFile;
  for (final file in index.files) {
    if (toPosixPath(file.path) == 'lib/main.dart') {
      mainFile = file;
      break;
    }
  }

  final hubs = inDegree.entries.where((entry) => entry.value > 1).toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  if (format == OutputFormat.json) {
    return CommandOutput(
      jsonEncode({
        'project': index.projectName,
        'type': isFlutter ? 'flutter_app' : 'dart_package',
        'dartSdk': sdkConstraint,
        'dependencies': dependencies,
        'files': index.files.length,
        'symbols': index.symbols.length,
        'importEdges': graph.edges.length,
        'circularImports': cycles.length,
        'topLevelFiles': topLevelFiles,
        'folders': [
          for (final entry in sortedFolders)
            {
              'path': entry.key,
              'files': entry.value.fileCount,
              'symbols': entry.value.symbolCount,
            },
        ],
        'entryPoint': mainFile == null
            ? null
            : {'path': mainFile.path, 'imports': mainFile.imports},
        'hubs': [
          for (final entry in hubs.take(8))
            {'path': entry.key, 'importedBy': entry.value},
        ],
      }),
    );
  }

  final buffer = StringBuffer()
    ..writeln('Overview: ${index.projectName}')
    ..writeln('Type: ${isFlutter ? 'Flutter app' : 'Dart package'}');
  if (sdkConstraint != null) buffer.writeln('Dart SDK: $sdkConstraint');
  if (dependencies.isNotEmpty) {
    buffer.writeln(
      'Dependencies (${dependencies.length}): ${dependencies.join(', ')}',
    );
  }
  buffer
    ..writeln()
    ..writeln(
      'Files: ${index.files.length}   Symbols: ${index.symbols.length}   '
      'Import edges: ${graph.edges.length}   '
      'Circular imports: ${cycles.length}',
    );

  if (topLevelFiles.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('Top-level files:');
    for (final path in topLevelFiles) {
      buffer.writeln('- $path');
    }
  }

  if (sortedFolders.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('Folders:');
    for (final entry in sortedFolders) {
      buffer.writeln(
        '- ${entry.key}  ${entry.value.fileCount} files, '
        '${entry.value.symbolCount} symbols',
      );
    }
  }

  if (mainFile != null) {
    buffer
      ..writeln()
      ..writeln('Entry point: ${mainFile.path}');
    if (mainFile.imports.isNotEmpty) {
      buffer.writeln('  imports: ${mainFile.imports.join(', ')}');
    }
  }

  if (hubs.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('Most depended-upon files (start here):');
    for (final entry in hubs.take(8)) {
      buffer.writeln('- ${entry.key}  imported by ${entry.value}');
    }
  }

  return CommandOutput(buffer.toString().trimRight());
}

class _FolderStats {
  int fileCount = 0;
  int symbolCount = 0;
}

String? _parseSdkConstraint(String pubspecContent) {
  final body = _sectionBody(pubspecContent, 'environment');
  if (body == null) return null;
  return RegExp(
    r'^\s*sdk:\s*(\S+)',
    multiLine: true,
  ).firstMatch(body)?.group(1);
}

/// Top-level keys directly under a `section:` block (e.g. dependency names
/// under `dependencies:`), ignoring further-nested lines (like a git/path
/// dependency's `url:`/`path:` sub-keys).
List<String> _parseSectionKeys(String pubspecContent, String section) {
  final body = _sectionBody(pubspecContent, section);
  if (body == null) return const [];
  final names = <String>[];
  for (final line in body.split('\n')) {
    final match = RegExp(r'^ {2}([a-zA-Z0-9_]+):').firstMatch(line);
    if (match != null) names.add(match.group(1)!);
  }
  return names;
}

/// Returns the indented body text under a top-level `key:` line in a YAML
/// file, up to (but not including) the next top-level key or end of file.
/// A minimal line-based substitute for a real YAML parser, sufficient for
/// pubspec.yaml's simple, well-known structure.
String? _sectionBody(String content, String key) {
  final lines = content.split('\n');
  final keyPattern = RegExp('^$key:\\s*\$');
  final startIndex = lines.indexWhere(keyPattern.hasMatch);
  if (startIndex == -1) return null;
  final body = <String>[];
  for (var i = startIndex + 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      body.add(line);
      continue;
    }
    if (!line.startsWith(' ') && !line.startsWith('\t')) break;
    body.add(line);
  }
  return body.join('\n');
}
