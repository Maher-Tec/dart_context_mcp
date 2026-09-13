import 'dart:io';

import 'package:path/path.dart' as p;

/// Lists the relative paths of `.dart` files under [rootPath], honoring the
/// same ignored-directory and generated-file rules the indexer uses. Shared
/// between the indexer (which parses each file) and the staleness check
/// (which only needs to know which files exist).
List<String> listDartFilePaths(
  String rootPath, {
  bool includeGenerated = false,
}) {
  final root = Directory(rootPath);
  if (!root.existsSync()) return const [];
  final results = <String>[];
  _walk(root, rootPath, includeGenerated, results);
  results.sort();
  return results;
}

void _walk(
  Directory dir,
  String rootPath,
  bool includeGenerated,
  List<String> results,
) {
  late List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } on FileSystemException {
    return;
  }

  for (final entry in entries) {
    final relative = p.relative(entry.path, from: rootPath);
    final parts = p.split(relative);
    if (parts.any(isIgnoredDirectory)) continue;

    if (entry is Directory) {
      _walk(entry, rootPath, includeGenerated, results);
      continue;
    }

    if (entry is! File || !entry.path.endsWith('.dart')) continue;
    if (!includeGenerated && isGeneratedDartFile(relative)) continue;
    results.add(relative);
  }
}

bool isIgnoredDirectory(String part) {
  return part == '.git' ||
      part == '.dart_tool' ||
      part == '.dart_context' ||
      part == 'build' ||
      part == '.gradle' ||
      part == '.gradle-user-home' ||
      part == 'Pods' ||
      part == '.idea';
}

bool isGeneratedDartFile(String relativePath) {
  final name = p.basename(relativePath);
  return name.endsWith('.g.dart') ||
      name.endsWith('.freezed.dart') ||
      name.endsWith('.mocks.dart') ||
      name.endsWith('.gr.dart') ||
      name == 'app_localizations.dart' ||
      (name.startsWith('app_localizations_') && name.endsWith('.dart'));
}
