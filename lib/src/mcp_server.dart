import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'code_index.dart';
import 'graph.dart';
import 'indexer.dart';
import 'model.dart';
import 'overview.dart';
import 'symbol_graph.dart';

const String _protocolVersion = '2025-06-18';
const String _serverName = 'dart_context_mcp';
// Kept in sync with pubspec.yaml's `version:` by
// test/dart_context_mcp_test.dart's "MCP server" group - bump both together.
const String _serverVersion = '0.10.0';

/// Runs a Model Context Protocol server over stdio: newline-delimited
/// JSON-RPC 2.0 messages in on [input] (defaults to stdin), same on
/// [output] (defaults to stdout). Never writes anything to stdout other
/// than protocol messages — diagnostics go to stderr instead, since stray
/// stdout output would corrupt the JSON-RPC stream.
Future<void> runMcpServer({
  String? currentDirectory,
  Stream<List<int>>? input,
  IOSink? output,
}) async {
  final stdoutSink = output ?? stdout;
  final cwd = currentDirectory ?? Directory.current.path;
  final cache = IndexCache();

  final lines = (input ?? stdin)
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  await for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    Object? id;
    try {
      final message = jsonDecode(trimmed);
      if (message is! Map<String, Object?>) {
        _writeError(stdoutSink, null, -32600, 'Invalid Request');
        continue;
      }
      id = message['id'];
      final method = message['method'];
      if (method is! String) {
        if (id != null) {
          _writeError(stdoutSink, id, -32600, 'Invalid Request');
        }
        continue;
      }
      await _dispatch(method, message, id, stdoutSink, cache, cwd);
    } on FormatException {
      _writeError(stdoutSink, null, -32700, 'Parse error');
    } catch (error) {
      if (id != null) {
        _writeError(stdoutSink, id, -32603, 'Internal error: $error');
      }
    }
  }
}

Future<void> _dispatch(
  String method,
  Map<String, Object?> message,
  Object? id,
  IOSink out,
  IndexCache cache,
  String cwd,
) async {
  switch (method) {
    case 'initialize':
      _writeResult(out, id, {
        'protocolVersion': _protocolVersion,
        'capabilities': {'tools': {}},
        'serverInfo': {'name': _serverName, 'version': _serverVersion},
      });
      return;
    case 'notifications/initialized':
    case 'initialized':
    case 'notifications/cancelled':
      return; // Notifications never get a response.
    case 'ping':
      _writeResult(out, id, {});
      return;
    case 'tools/list':
      _writeResult(out, id, {'tools': toolDefinitions});
      return;
    case 'tools/call':
      final params = (message['params'] as Map<String, Object?>?) ?? const {};
      final result = _callTool(params, cache, cwd);
      _writeResult(out, id, result);
      return;
    default:
      if (id != null) {
        _writeError(out, id, -32601, 'Method not found: $method');
      }
  }
}

Map<String, Object?> _callTool(
  Map<String, Object?> params,
  IndexCache cache,
  String cwd,
) {
  final name = params['name'] as String?;
  final args = (params['arguments'] as Map<String, Object?>?) ?? const {};
  if (name == null) return _errorContent('Missing tool name.');

  try {
    final root = _rootFrom(args, cwd);
    switch (name) {
      case 'dart_overview':
        final index = cache.get(root);
        return _textContent(
          buildOverviewReport(
            index,
            format: parseOutputFormat(args['format'] as String?),
          ),
        );

      case 'dart_index':
        final includeGenerated = args['includeGenerated'] == true;
        final index = DartContextIndexer(
          root,
          includeGenerated: includeGenerated,
        ).build();
        index.save();
        cache.put(root, index);
        return _textContent(buildIndexReport(index));

      case 'dart_symbols':
        final index = cache.get(root);
        return _textContent(
          buildSymbolsReport(
            index,
            kind: args['kind'] as String?,
            query: args['query'] as String?,
            limit: _limitFrom(args, defaultValue: 80),
          ),
        );

      case 'dart_context':
        final symbol = args['symbol'] as String?;
        if (symbol == null || symbol.trim().isEmpty) {
          return _errorContent('Missing required argument: symbol');
        }
        final index = cache.get(root);
        return _textContent(
          buildContextReport(
            index,
            symbol,
            limit: _limitFrom(args, defaultValue: 12),
            format: parseOutputFormat(args['format'] as String?),
          ),
        );

      case 'dart_impact':
        final symbol = args['symbol'] as String?;
        if (symbol == null || symbol.trim().isEmpty) {
          return _errorContent('Missing required argument: symbol');
        }
        final index = cache.get(root);
        return _textContent(
          buildImpactReport(
            index,
            symbol,
            limit: _limitFrom(args, defaultValue: 40),
            format: parseOutputFormat(args['format'] as String?),
          ),
        );

      case 'dart_query':
        final query = args['query'] as String?;
        if (query == null || query.trim().isEmpty) {
          return _errorContent('Missing required argument: query');
        }
        final index = cache.get(root);
        return _textContent(
          buildQueryReport(
            index,
            query,
            limit: _limitFrom(args, defaultValue: 10),
            format: parseOutputFormat(args['format'] as String?),
          ),
        );

      case 'dart_graph':
        final index = cache.get(root);
        final graph = buildDependencyGraph(index);
        final cycles = detectCycles(graph);
        final symbolGraph = buildSymbolGraph(index);
        final html = buildDependencyGraphHtml(
          graph,
          cycles,
          title: '${index.projectName} dependency graph',
          symbols: symbolGraph,
        );
        final rawOut = args['output'] as String?;
        final outputPath = rawOut != null
            ? p.normalize(p.absolute(rawOut))
            : p.join(root, indexDirectoryName, 'graph.html');
        Directory(p.dirname(outputPath)).createSync(recursive: true);
        File(outputPath).writeAsStringSync(html);
        final summary = StringBuffer()
          ..writeln('Wrote dependency graph to $outputPath')
          ..writeln('Files: ${graph.nodes.length}')
          ..writeln('Import edges: ${graph.edges.length}')
          ..writeln('Circular import chains: ${cycles.length}');
        for (final cycle in cycles) {
          summary.writeln('- ${cycle.join(' -> ')}');
        }
        summary.write('\nOpen the file in a browser to view it interactively.');
        return _textContent(CommandOutput(summary.toString()));

      default:
        return _errorContent('Unknown tool: $name');
    }
  } on FileSystemException catch (error) {
    final suffix = error.path != null ? ' (${error.path})' : '';
    return _errorContent('Filesystem error: ${error.message}$suffix');
  } on FormatException catch (error) {
    return _errorContent('Error: ${error.message}');
  }
}

String _rootFrom(Map<String, Object?> args, String cwd) {
  final raw = args['root'] as String?;
  return p.normalize(p.absolute(raw ?? cwd));
}

int _limitFrom(Map<String, Object?> args, {required int defaultValue}) {
  final raw = args['limit'];
  if (raw is num) return raw.toInt().clamp(1, 500);
  if (raw is String) return parseLimit(raw, defaultValue: defaultValue);
  return defaultValue;
}

Map<String, Object?> _textContent(CommandOutput output) => {
  'content': [
    {'type': 'text', 'text': output.text},
  ],
  'isError': output.isError,
};

Map<String, Object?> _errorContent(String message) => {
  'content': [
    {'type': 'text', 'text': message},
  ],
  'isError': true,
};

void _writeResult(IOSink out, Object? id, Object? result) {
  _writeMessage(out, {'jsonrpc': '2.0', 'id': id, 'result': result});
}

void _writeError(IOSink out, Object? id, int code, String message) {
  _writeMessage(out, {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  });
}

void _writeMessage(IOSink out, Map<String, Object?> message) {
  out.writeln(jsonEncode(message));
}

const String _rootProperty =
    'Absolute path to the Dart or Flutter project root. Defaults to the '
    "server process's working directory if omitted.";

const Map<String, Object?> _formatProperty = {
  'type': 'string',
  'enum': ['text', 'json'],
  'description':
      "Output shape. 'text' (default) is a compact human-readable report. "
      "'json' returns the same data as a single JSON object - use it when "
      'you need to read one specific field programmatically instead of '
      're-parsing prose.',
};

final List<Map<String, Object?>> toolDefinitions = [
  {
    'name': 'dart_overview',
    'description':
        'The best first call on an unfamiliar Dart/Flutter project: a '
        'compact one-shot snapshot covering dependencies, the Dart SDK '
        'constraint, the lib/ folder breakdown with file/symbol counts, '
        "the entry point's (lib/main.dart) imports, and the most "
        'depended-upon files (fan-in hubs worth reading first). Meant to '
        'replace several exploratory file reads with one cheap call.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'root': {'type': 'string', 'description': _rootProperty},
        'format': _formatProperty,
      },
      'required': ['root'],
    },
  },
  {
    'name': 'dart_index',
    'description':
        'Build (or rebuild) the symbol index for a Dart/Flutter project. '
        'Run this once per project before the other tools, or after large '
        'changes that add/remove files.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'root': {'type': 'string', 'description': _rootProperty},
        'includeGenerated': {
          'type': 'boolean',
          'description':
              'Include generated files (.g.dart, .freezed.dart, etc). '
              'Defaults to false.',
        },
      },
      'required': ['root'],
    },
  },
  {
    'name': 'dart_symbols',
    'description':
        'List indexed symbols (classes, methods, functions, fields, '
        'constructors, ...), optionally filtered by kind and/or text.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'root': {'type': 'string', 'description': _rootProperty},
        'kind': {
          'type': 'string',
          'description':
              'Filter by symbol kind, e.g. class, method, function, field, '
              'constructor, enum, enum_constant, mixin, extension, typedef.',
        },
        'query': {
          'type': 'string',
          'description': 'Filter by substring match on name/path/container.',
        },
        'limit': {
          'type': 'integer',
          'description': 'Maximum symbols to return. Defaults to 80.',
        },
      },
      'required': ['root'],
    },
  },
  {
    'name': 'dart_context',
    'description':
        'Show everything known about one symbol: declaration location, '
        'signature, imports of its file, nearby symbols, and text '
        'references elsewhere in the project.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'root': {'type': 'string', 'description': _rootProperty},
        'symbol': {
          'type': 'string',
          'description': 'Symbol name to look up, e.g. SessionScreen.',
        },
        'limit': {
          'type': 'integer',
          'description': 'Maximum references to return. Defaults to 12.',
        },
        'format': _formatProperty,
      },
      'required': ['root', 'symbol'],
    },
  },
  {
    'name': 'dart_impact',
    'description':
        'Estimate the blast radius of changing a symbol: how many files '
        'and lines reference its name, with a LOW/MEDIUM/HIGH risk rating. '
        'References are matched by name only (a lightweight text search), '
        'not full type resolution, so treat the risk rating as a heuristic.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'root': {'type': 'string', 'description': _rootProperty},
        'symbol': {'type': 'string', 'description': 'Symbol name to check.'},
        'limit': {
          'type': 'integer',
          'description': 'Maximum reference hits to return. Defaults to 40.',
        },
        'format': _formatProperty,
      },
      'required': ['root', 'symbol'],
    },
  },
  {
    'name': 'dart_query',
    'description':
        'Free-text search across symbol names and source lines, ranked by '
        'a simple term-frequency score. Good for "where is the code that '
        'does X" style questions.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'root': {'type': 'string', 'description': _rootProperty},
        'query': {'type': 'string', 'description': 'Free-text search terms.'},
        'limit': {
          'type': 'integer',
          'description': 'Maximum files to return. Defaults to 10.',
        },
        'format': _formatProperty,
      },
      'required': ['root', 'query'],
    },
  },
  {
    'name': 'dart_graph',
    'description':
        'Generate an interactive, self-contained HTML visualization of the '
        "project's file import graph (pan/zoom, click a file to see its "
        'imports and importers, search) and detect circular imports. Writes '
        'the file to disk and returns its path — open it in a browser.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'root': {'type': 'string', 'description': _rootProperty},
        'output': {
          'type': 'string',
          'description':
              'Where to write the HTML file. Defaults to '
              '.dart_context/graph.html under the project root.',
        },
      },
      'required': ['root'],
    },
  },
];
