import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'code_index.dart';
import 'graph.dart';
import 'indexer.dart';
import 'mcp_server.dart';
import 'model.dart';
import 'overview.dart';
import 'symbol_graph.dart';

Future<int> runCli(
  List<String> arguments, {
  String? currentDirectory,
  IOSink? out,
  IOSink? err,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;

  if (arguments.isEmpty ||
      arguments.first == 'help' ||
      arguments.first == '--help' ||
      arguments.first == '-h') {
    stdoutSink.writeln(_helpText);
    return 0;
  }

  final command = arguments.first;
  final rest = arguments.skip(1).toList();
  try {
    switch (command) {
      case 'overview':
        return _runOverview(rest, currentDirectory, stdoutSink);
      case 'index':
        return _runIndex(rest, currentDirectory, stdoutSink);
      case 'symbols':
        return _runSymbols(rest, currentDirectory, stdoutSink);
      case 'context':
        return _runContext(rest, currentDirectory, stdoutSink, stderrSink);
      case 'impact':
        return _runImpact(rest, currentDirectory, stdoutSink, stderrSink);
      case 'query':
        return _runQuery(rest, currentDirectory, stdoutSink, stderrSink);
      case 'graph':
        return _runGraph(rest, currentDirectory, stdoutSink);
      case 'mcp':
        await runMcpServer(currentDirectory: currentDirectory);
        return 0;
      default:
        stderrSink.writeln('Unknown command: $command\n');
        stderrSink.writeln(_helpText);
        return 64;
    }
  } on FormatException catch (error) {
    stderrSink.writeln('Error: ${error.message}');
    return 64;
  } on FileSystemException catch (error) {
    stderrSink.writeln('Filesystem error: ${error.message}');
    if (error.path != null) stderrSink.writeln('Path: ${error.path}');
    return 74;
  }
}

int _runOverview(List<String> args, String? cwd, IOSink out) {
  final parser = ArgParser()
    ..addOption('root', abbr: 'r', help: 'Dart or Flutter project root.')
    ..addOption(
      'format',
      allowed: ['text', 'json'],
      defaultsTo: 'text',
      help: 'Output format.',
    );
  final parsed = parser.parse(args);
  final root = _resolveRoot(parsed, cwd, positionalRoot: true);
  final index = CodeIndex.loadOrBuild(root);
  out.writeln(
    buildOverviewReport(
      index,
      format: parseOutputFormat(parsed.option('format')),
    ).text,
  );
  return 0;
}

int _runIndex(List<String> args, String? cwd, IOSink out) {
  final parser = ArgParser()
    ..addOption('root', abbr: 'r', help: 'Dart or Flutter project root.')
    ..addFlag('include-generated', defaultsTo: false);
  final parsed = parser.parse(args);
  final root = _resolveRoot(parsed, cwd, positionalRoot: true);
  final index = DartContextIndexer(
    root,
    includeGenerated: parsed.flag('include-generated'),
  ).build();
  index.save();

  out.writeln(buildIndexReport(index).text);
  return 0;
}

int _runSymbols(List<String> args, String? cwd, IOSink out) {
  final parser = ArgParser()
    ..addOption('root', abbr: 'r', help: 'Dart or Flutter project root.')
    ..addOption('kind', abbr: 'k', help: 'Filter by class, method, function.')
    ..addOption('query', abbr: 'q', help: 'Filter by text.')
    ..addOption('limit', abbr: 'n', defaultsTo: '80');
  final parsed = parser.parse(args);
  final root = _resolveRoot(parsed, cwd);
  final index = CodeIndex.loadOrBuild(root);
  final result = buildSymbolsReport(
    index,
    kind: parsed.option('kind'),
    query: parsed.option('query'),
    limit: parseLimit(parsed.option('limit'), defaultValue: 80),
  );
  out.writeln(result.text);
  return 0;
}

int _runContext(List<String> args, String? cwd, IOSink out, IOSink err) {
  final parser = ArgParser()
    ..addOption('root', abbr: 'r', help: 'Dart or Flutter project root.')
    ..addOption('limit', abbr: 'n', defaultsTo: '12')
    ..addOption(
      'format',
      allowed: ['text', 'json'],
      defaultsTo: 'text',
      help: 'Output format.',
    );
  final parsed = parser.parse(args);
  if (parsed.rest.isEmpty) {
    throw const FormatException('context requires a symbol name.');
  }

  final root = _resolveRoot(parsed, cwd);
  final index = CodeIndex.loadOrBuild(root);
  final name = parsed.rest.join(' ');
  final result = buildContextReport(
    index,
    name,
    limit: parseLimit(parsed.option('limit'), defaultValue: 12),
    format: parseOutputFormat(parsed.option('format')),
  );
  if (result.isError) {
    err.writeln(result.text);
    return 1;
  }
  out.writeln(result.text);
  return 0;
}

int _runImpact(List<String> args, String? cwd, IOSink out, IOSink err) {
  final parser = ArgParser()
    ..addOption('root', abbr: 'r', help: 'Dart or Flutter project root.')
    ..addOption('limit', abbr: 'n', defaultsTo: '40')
    ..addOption(
      'format',
      allowed: ['text', 'json'],
      defaultsTo: 'text',
      help: 'Output format.',
    );
  final parsed = parser.parse(args);
  if (parsed.rest.isEmpty) {
    throw const FormatException('impact requires a symbol name.');
  }

  final root = _resolveRoot(parsed, cwd);
  final index = CodeIndex.loadOrBuild(root);
  final name = parsed.rest.join(' ');
  final result = buildImpactReport(
    index,
    name,
    limit: parseLimit(parsed.option('limit'), defaultValue: 40),
    format: parseOutputFormat(parsed.option('format')),
  );
  if (result.isError) {
    err.writeln(result.text);
    return 1;
  }
  out.writeln(result.text);
  return 0;
}

int _runQuery(List<String> args, String? cwd, IOSink out, IOSink err) {
  final parser = ArgParser()
    ..addOption('root', abbr: 'r', help: 'Dart or Flutter project root.')
    ..addOption('limit', abbr: 'n', defaultsTo: '10')
    ..addOption(
      'format',
      allowed: ['text', 'json'],
      defaultsTo: 'text',
      help: 'Output format.',
    );
  final parsed = parser.parse(args);
  if (parsed.rest.isEmpty) {
    throw const FormatException('query requires search text.');
  }

  final root = _resolveRoot(parsed, cwd);
  final index = CodeIndex.loadOrBuild(root);
  final query = parsed.rest.join(' ');
  final result = buildQueryReport(
    index,
    query,
    limit: parseLimit(parsed.option('limit'), defaultValue: 10),
    format: parseOutputFormat(parsed.option('format')),
  );
  if (result.isError) {
    err.writeln(result.text);
    return 1;
  }
  out.writeln(result.text);
  return 0;
}

int _runGraph(List<String> args, String? cwd, IOSink out) {
  final parser = ArgParser()
    ..addOption('root', abbr: 'r', help: 'Dart or Flutter project root.')
    ..addOption('out', abbr: 'o', help: 'Output HTML file path.')
    ..addFlag(
      'open',
      defaultsTo: false,
      help: 'Open the graph in the default browser once written.',
    );
  final parsed = parser.parse(args);
  final root = _resolveRoot(parsed, cwd, positionalRoot: true);
  final index = CodeIndex.loadOrBuild(root);
  final graph = buildDependencyGraph(index);
  final cycles = detectCycles(graph);
  final symbols = buildSymbolGraph(index);
  final html = buildDependencyGraphHtml(
    graph,
    cycles,
    title: '${index.projectName} dependency graph',
    symbols: symbols,
  );

  final rawOut = parsed.option('out');
  final outputPath = rawOut != null
      ? p.normalize(p.absolute(rawOut))
      : p.join(root, indexDirectoryName, 'graph.html');
  Directory(p.dirname(outputPath)).createSync(recursive: true);
  File(outputPath).writeAsStringSync(html);

  out.writeln('Dependency graph: ${index.projectName}');
  out.writeln('Files: ${graph.nodes.length}');
  out.writeln('Import edges: ${graph.edges.length}');
  out.writeln('Circular import chains: ${cycles.length}');
  out.writeln('Output: $outputPath');

  if (parsed.flag('open')) _openInBrowser(outputPath);
  return 0;
}

void _openInBrowser(String path) {
  try {
    if (Platform.isWindows) {
      Process.runSync('cmd', ['/c', 'start', '', path]);
    } else if (Platform.isMacOS) {
      Process.runSync('open', [path]);
    } else {
      Process.runSync('xdg-open', [path]);
    }
  } on ProcessException {
    // Best-effort; the output path is already printed above.
  }
}

String _resolveRoot(
  ArgResults parsed,
  String? cwd, {
  bool positionalRoot = false,
}) {
  final optionRoot = parsed.option('root');
  final positional = positionalRoot && parsed.rest.isNotEmpty
      ? parsed.rest.first
      : null;
  final rawRoot = optionRoot ?? positional ?? cwd ?? Directory.current.path;
  return p.normalize(p.absolute(rawRoot));
}

const String _helpText = '''
dart_context_mcp - local Dart/Flutter code context for agents

Usage:
  dart_context_mcp overview [projectRoot] [--format json]
  dart_context_mcp index [projectRoot]
  dart_context_mcp symbols --root <projectRoot> [--kind class] [--query text]
  dart_context_mcp context <SymbolName> --root <projectRoot> [--format json]
  dart_context_mcp impact <SymbolName> --root <projectRoot> [--format json]
  dart_context_mcp query "settings background" --root <projectRoot> [--format json]
  dart_context_mcp graph [projectRoot] [--out file.html] [--open]
  dart_context_mcp mcp

Commands return compact text with file:line anchors to save tokens.
`overview`/`context`/`impact`/`query` accept `--format json` to get the same
data as a single JSON object instead - useful when a caller needs to read
one field programmatically rather than a human reading prose.

`overview` is the best first call on an unfamiliar project: dependencies,
Dart SDK constraint, `lib/` folder breakdown, the entry point's imports, and
the most depended-upon files - a single compact call meant to replace
several exploratory file reads.

`graph` writes a self-contained, offline HTML file (default:
.dart_context/graph.html) showing the project's file import graph as an
interactive, pannable/zoomable diagram, with circular imports detected and
highlighted. Open it in any browser.

`mcp` starts a Model Context Protocol server on stdio, exposing
dart_overview, dart_index, dart_symbols, dart_context, dart_impact,
dart_query, and dart_graph as tools. Every tool call takes a `root`
argument (an absolute or cwd-relative project path).
''';
