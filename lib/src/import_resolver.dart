import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves a Dart import URI to the project-relative (posix-style) path of
/// the file it points at, or `null` if it doesn't resolve to a file inside
/// this project (a `dart:*` import, an external package, or anything else
/// with no local file to point at).
String? resolveImportToPosixPath(
  String importUri,
  String fromDirPosix,
  String? packageName,
) {
  if (importUri.startsWith('dart:')) return null;
  if (importUri.contains('://') && !importUri.startsWith('package:')) {
    return null; // dart-ext:, http(s):, etc.
  }
  if (importUri.startsWith('package:')) {
    if (packageName == null) return null;
    final prefix = 'package:$packageName/';
    if (!importUri.startsWith(prefix)) return null; // external dependency
    return p.posix.normalize('lib/${importUri.substring(prefix.length)}');
  }
  return p.posix.normalize(p.posix.join(fromDirPosix, importUri));
}

String toPosixPath(String path) => path.replaceAll('\\', '/');

/// Reads the `name:` field out of the project's `pubspec.yaml`, needed to
/// tell a `package:<name>/...` self-import apart from an external
/// dependency.
String? readPackageName(String rootPath) {
  final file = File(p.join(rootPath, 'pubspec.yaml'));
  if (!file.existsSync()) return null;
  for (final line in file.readAsLinesSync()) {
    final match = RegExp(r'^name:\s*(\S+)').firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}
