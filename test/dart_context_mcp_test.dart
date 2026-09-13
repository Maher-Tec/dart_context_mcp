import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_context_mcp/dart_context_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dart_context_mcp_test_');
    Directory(
      p.join(tempDir.path, 'lib', 'screens'),
    ).createSync(recursive: true);
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_app
environment:
  sdk: ^3.10.0
''');
    File(
      p.join(tempDir.path, 'lib', 'screens', 'session_screen.dart'),
    ).writeAsStringSync('''
import 'package:flutter/material.dart';

class SessionScreen extends StatelessWidget {
  const SessionScreen({super.key});
  SessionScreen.named(String x);

  @override
  Widget build(BuildContext context) {
    return const Text('Home background');
  }
}

enum Status { active, inactive }

typedef Callback = void Function(int x);

class SettingsProvider {
  String get homeBackgroundId => 'default';
}
''');
    File(p.join(tempDir.path, 'lib', 'main.dart')).writeAsStringSync('''
import 'screens/session_screen.dart';

void main() {
  final provider = SettingsProvider();
  print(provider.homeBackgroundId);
  print(const SessionScreen());
}
''');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('indexes Dart symbols and saves an index file', () {
    final index = DartContextIndexer(tempDir.path).build();
    index.save();

    expect(File(index.indexPath).existsSync(), isTrue);
    expect(
      index.symbols.map((symbol) => symbol.name),
      contains('SessionScreen'),
    );
    expect(
      index.symbols.map((symbol) => symbol.name),
      contains('SettingsProvider'),
    );
  });

  test('stores and reports paths in posix style on every platform', () {
    // A real bug this session: file.path/symbol.path were stored with the
    // OS-native separator (backslash on Windows), while the graph/overview
    // tooling normalized to posix internally - so the same file was spelled
    // two different ways depending on which tool answered, breaking a naive
    // string comparison across two tool calls. Every path an agent sees
    // should be spelled the same way regardless of which tool produced it.
    final index = DartContextIndexer(tempDir.path).build();
    for (final file in index.files) {
      expect(file.path, isNot(contains('\\')));
    }
    for (final symbol in index.symbols) {
      expect(symbol.path, isNot(contains('\\')));
    }
    expect(
      index.symbols.map((s) => s.path),
      contains('lib/screens/session_screen.dart'),
    );

    // The staleness check compares this same path set against a fresh disk
    // scan - if that comparison normalizes only one side (a real bug this
    // session introduced and caught), every reload would look stale and
    // force an unnecessary rebuild instead of reusing the saved index.
    index.save();
    final reloaded = CodeIndex.loadOrBuild(tempDir.path);
    expect(
      reloaded.generatedAt,
      index.generatedAt,
      reason:
          'a matching generatedAt means the saved index was reused, not '
          'needlessly rebuilt because of a path-format mismatch',
    );
  });

  test('indexes constructors, enum constants, and typedefs', () {
    final index = DartContextIndexer(tempDir.path).build();
    final displayNames = index.symbols.map((s) => s.displayName).toSet();

    expect(displayNames, contains('SessionScreen.new'));
    expect(displayNames, contains('SessionScreen.named'));
    expect(displayNames, contains('Status.active'));
    expect(displayNames, contains('Status.inactive'));
    expect(displayNames, contains('Callback'));
    expect(
      index.symbols.firstWhere((s) => s.displayName == 'Callback').kind,
      'typedef',
    );

    // The unnamed constructor must not collide with the class's own name.
    final exactMatches = index.findSymbols('SessionScreen');
    expect(exactMatches, hasLength(1));
    expect(exactMatches.single.kind, 'class');
  });

  test('captures multi-line signatures without truncating at named params', () {
    final dir = Directory.systemTemp.createTempSync('dart_context_mcp_sig_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'lib.dart')).writeAsStringSync('''
void configure({
  required int width,
  required int height,
}) {}
''');
    final index = DartContextIndexer(dir.path).build();
    final symbol = index.symbols.single;
    expect(symbol.signature, contains('required int width'));
    expect(symbol.signature, contains('required int height'));
  });

  test('finds context references and query results', () {
    final index = DartContextIndexer(tempDir.path).build();
    index.save();
    final loaded = CodeIndex.loadOrBuild(tempDir.path);

    final symbols = loaded.findSymbols('SessionScreen');
    expect(symbols, hasLength(1));

    final references = loaded.referencesTo('SessionScreen');
    expect(
      references.any((reference) => reference.path.endsWith('main.dart')),
      isTrue,
    );

    final results = loaded.query('home background settings');
    expect(results.first.path, contains('session_screen.dart'));
  });

  test('referencesTo ignores mentions inside comments and string literals', () {
    final dir = Directory.systemTemp.createTempSync('dart_context_mcp_mask_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: mask_app
''');
    Directory(p.join(dir.path, 'lib')).createSync(recursive: true);
    File(p.join(dir.path, 'lib', 'a.dart')).writeAsStringSync('''
class Widget {}

// A Widget is just an example here, not a real usage.
void build() {
  final w = Widget(); // real usage
  print('Please configure your Widget in settings');
  print('Interpolated: \${Widget()}');
}
''');
    final index = DartContextIndexer(dir.path).build();
    final symbol = index.findSymbols('Widget').single;
    final refs = index.referencesTo('Widget', excludeDeclaration: symbol);

    expect(refs.any((r) => r.snippet.contains('final w = Widget();')), isTrue);
    expect(
      refs.any((r) => r.snippet.contains('Interpolated')),
      isTrue,
      reason: 'a reference inside string interpolation is real code',
    );
    expect(
      refs.any((r) => r.snippet.contains('just an example')),
      isFalse,
      reason: 'a mention inside a comment is not a real reference',
    );
    expect(
      refs.any((r) => r.snippet.contains('Please configure')),
      isFalse,
      reason: 'a mention inside a plain string literal is not a reference',
    );
  });

  test(
    'referencesTo scopes an ambiguous name to files that import the declaration',
    () {
      final dir = Directory.systemTemp.createTempSync(
        'dart_context_mcp_ambiguous_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: ambiguous_app
''');
      Directory(p.join(dir.path, 'lib')).createSync(recursive: true);
      // Two unrelated classes both named `Item`.
      File(p.join(dir.path, 'lib', 'shop_item.dart')).writeAsStringSync('''
class Item {
  final String name = 'shop';
}
''');
      File(p.join(dir.path, 'lib', 'todo_item.dart')).writeAsStringSync('''
class Item {
  final bool done = false;
}
''');
      // Only imports the shop Item.
      File(p.join(dir.path, 'lib', 'shop_screen.dart')).writeAsStringSync('''
import 'shop_item.dart';

void render() {
  final it = Item();
  print(it);
}
''');
      // Only imports the todo Item.
      File(p.join(dir.path, 'lib', 'todo_screen.dart')).writeAsStringSync('''
import 'todo_item.dart';

void render() {
  final it = Item();
  print(it);
}
''');
      final index = DartContextIndexer(dir.path).build();
      final shopItem = index.symbols.firstWhere(
        (s) => s.path.endsWith('shop_item.dart') && s.name == 'Item',
      );
      final refs = index.referencesTo('Item', excludeDeclaration: shopItem);
      final touchedFiles = refs.map((r) => r.path).toSet();

      expect(touchedFiles.any((f) => f.endsWith('shop_screen.dart')), isTrue);
      expect(
        touchedFiles.any((f) => f.endsWith('todo_screen.dart')),
        isFalse,
        reason:
            "todo_screen.dart imports the OTHER Item - it shouldn't be "
            'attributed to the shop one',
      );
    },
  );

  test('rebuilds the index when a new file is added', () {
    DartContextIndexer(tempDir.path).build().save();

    File(p.join(tempDir.path, 'lib', 'new_file.dart')).writeAsStringSync('''
class BrandNewClass {}
''');

    final reloaded = CodeIndex.loadOrBuild(tempDir.path);
    expect(reloaded.symbols.map((s) => s.name), contains('BrandNewClass'));
  });

  test('rebuilds the index when a tracked file is removed', () {
    DartContextIndexer(tempDir.path).build().save();

    File(p.join(tempDir.path, 'lib', 'main.dart')).deleteSync();

    final reloaded = CodeIndex.loadOrBuild(tempDir.path);
    expect(reloaded.fileFor('lib/main.dart'), isNull);
  });

  test('impact reports a risk level and grouped references', () {
    final index = DartContextIndexer(tempDir.path).build();
    final result = buildImpactReport(index, 'SessionScreen', limit: 40);
    expect(result.isError, isFalse);
    expect(result.text, contains('Risk:'));
    expect(result.text, contains('main.dart'));
  });

  test('context reports ambiguity when multiple symbols match', () {
    final index = DartContextIndexer(tempDir.path).build();
    final result = buildContextReport(index, 'session', limit: 12);
    expect(result.isError, isFalse);
    expect(result.text, contains('Multiple symbols match'));
  });

  test('context reports an error for an unknown symbol', () {
    final index = DartContextIndexer(tempDir.path).build();
    final result = buildContextReport(index, 'NoSuchSymbol', limit: 12);
    expect(result.isError, isTrue);
  });

  group('JSON output format', () {
    test('context returns structured JSON when requested', () {
      final index = DartContextIndexer(tempDir.path).build();
      final result = buildContextReport(
        index,
        'SessionScreen',
        limit: 12,
        format: OutputFormat.json,
      );

      final decoded = jsonDecode(result.text) as Map<String, Object?>;
      final symbol = decoded['symbol'] as Map<String, Object?>;
      expect(symbol['name'], 'SessionScreen');
      expect(symbol['kind'], 'class');
      expect(decoded['references'], isA<List>());
    });

    test('context returns structured JSON for an ambiguous name', () {
      final index = DartContextIndexer(tempDir.path).build();
      final result = buildContextReport(
        index,
        'session',
        limit: 12,
        format: OutputFormat.json,
      );

      final decoded = jsonDecode(result.text) as Map<String, Object?>;
      expect(decoded['ambiguous'], isTrue);
      expect((decoded['matches'] as List), isNotEmpty);
    });

    test('impact returns structured JSON with a risk field', () {
      final index = DartContextIndexer(tempDir.path).build();
      final result = buildImpactReport(
        index,
        'SessionScreen',
        limit: 40,
        format: OutputFormat.json,
      );

      final decoded = jsonDecode(result.text) as Map<String, Object?>;
      expect(decoded['risk'], anyOf('LOW', 'MEDIUM', 'HIGH'));
      expect(decoded['referencingFiles'], isA<int>());
    });

    test('query returns structured JSON results', () {
      final index = DartContextIndexer(tempDir.path).build();
      final result = buildQueryReport(
        index,
        'home background settings',
        limit: 10,
        format: OutputFormat.json,
      );

      final decoded = jsonDecode(result.text) as Map<String, Object?>;
      final results = decoded['results'] as List;
      expect(results, isNotEmpty);
      expect((results.first as Map)['path'], contains('session_screen.dart'));
    });

    test('overview returns structured JSON', () {
      final index = DartContextIndexer(tempDir.path).build();
      final result = buildOverviewReport(index, format: OutputFormat.json);

      final decoded = jsonDecode(result.text) as Map<String, Object?>;
      expect(decoded['type'], anyOf('flutter_app', 'dart_package'));
      expect(decoded['folders'], isA<List>());
      expect(decoded['hubs'], isA<List>());
    });
  });

  group('overview', () {
    test('summarizes dependencies, folders, entry point, and hub files', () {
      // tempDir's fixture (see setUp) already has lib/screens/session_screen.dart
      // and lib/main.dart, both importing/depending in a way that gives at
      // least one real fan-in hub, but add one more importer of the screen
      // file so the "most depended-upon" section has something to show.
      File(p.join(tempDir.path, 'lib', 'second_user.dart')).writeAsStringSync(
        '''
import 'screens/session_screen.dart';

void second() {
  print(const SessionScreen());
}
''',
      );

      final index = DartContextIndexer(tempDir.path).build();
      final result = buildOverviewReport(index);

      expect(result.isError, isFalse);
      expect(result.text, contains('Overview: ${index.projectName}'));
      expect(result.text, contains('Type: Dart package'));
      expect(result.text, contains('Entry point: '));
      expect(result.text, contains('main.dart'));
      expect(result.text, contains('Folders:'));
      expect(result.text, contains('screens'));
      expect(result.text, contains('Most depended-upon files'));
      expect(result.text, contains('session_screen.dart'));
    });

    test('detects a Flutter app via the flutter dependency', () {
      final dir = Directory.systemTemp.createTempSync(
        'dart_context_mcp_flutter_app_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: some_flutter_app
environment:
  sdk: ^3.10.0
dependencies:
  flutter:
    sdk: flutter
  equatable: ^2.0.0
''');
      Directory(p.join(dir.path, 'lib')).createSync(recursive: true);
      File(p.join(dir.path, 'lib', 'main.dart')).writeAsStringSync('''
void main() {}
''');

      final index = DartContextIndexer(dir.path).build();
      final result = buildOverviewReport(index);

      expect(result.text, contains('Type: Flutter app'));
      expect(result.text, contains('Dependencies (2): flutter, equatable'));
      expect(result.text, contains('Dart SDK: ^3.10.0'));
    });
  });

  group('dependency graph', () {
    late Directory graphDir;

    setUp(() {
      graphDir = Directory.systemTemp.createTempSync('dart_context_mcp_graph_');
      Directory(
        p.join(graphDir.path, 'lib', 'models'),
      ).createSync(recursive: true);
      Directory(
        p.join(graphDir.path, 'lib', 'screens'),
      ).createSync(recursive: true);
      File(p.join(graphDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: dgtest
environment:
  sdk: ^3.10.0
''');
      File(p.join(graphDir.path, 'lib', 'main.dart')).writeAsStringSync('''
import 'screens/home_screen.dart';
void main() { print(HomeScreen); }
''');
      File(
        p.join(graphDir.path, 'lib', 'screens', 'home_screen.dart'),
      ).writeAsStringSync('''
import '../models/user.dart';
class HomeScreen { User? user; }
''');
      // A relative import and a self-referencing package: import that
      // together form a genuine circular import between user.dart and
      // session.dart.
      File(
        p.join(graphDir.path, 'lib', 'models', 'user.dart'),
      ).writeAsStringSync('''
import 'package:dgtest/models/session.dart';
class User { Session? session; }
''');
      File(
        p.join(graphDir.path, 'lib', 'models', 'session.dart'),
      ).writeAsStringSync('''
import 'package:dgtest/models/user.dart';
class Session { User? owner; }
''');
    });

    tearDown(() {
      graphDir.deleteSync(recursive: true);
    });

    test('resolves relative and self-package imports to file nodes', () {
      final index = DartContextIndexer(graphDir.path).build();
      final graph = buildDependencyGraph(index);

      expect(graph.nodes, hasLength(4));
      final edgePairs = graph.edges.map((e) => '${e.from}->${e.to}').toSet();
      expect(
        edgePairs,
        containsAll([
          'lib/main.dart->lib/screens/home_screen.dart',
          'lib/screens/home_screen.dart->lib/models/user.dart',
          'lib/models/user.dart->lib/models/session.dart',
          'lib/models/session.dart->lib/models/user.dart',
        ]),
      );
    });

    test('detects the user.dart <-> session.dart cycle', () {
      final index = DartContextIndexer(graphDir.path).build();
      final graph = buildDependencyGraph(index);
      final cycles = detectCycles(graph);

      expect(cycles, hasLength(1));
      expect(cycles.single.toSet(), {
        'lib/models/user.dart',
        'lib/models/session.dart',
      });
    });

    test('does not report a cycle for an acyclic graph', () {
      final acyclicDir = Directory.systemTemp.createTempSync(
        'dart_context_mcp_acyclic_',
      );
      addTearDown(() => acyclicDir.deleteSync(recursive: true));
      File(p.join(acyclicDir.path, 'a.dart')).writeAsStringSync('''
import 'b.dart';
class A {}
''');
      File(p.join(acyclicDir.path, 'b.dart')).writeAsStringSync('''
class B {}
''');
      final index = DartContextIndexer(acyclicDir.path).build();
      final graph = buildDependencyGraph(index);
      expect(detectCycles(graph), isEmpty);
    });

    test('renders self-contained HTML with the graph data embedded', () {
      final index = DartContextIndexer(graphDir.path).build();
      final graph = buildDependencyGraph(index);
      final cycles = detectCycles(graph);
      final html = buildDependencyGraphHtml(graph, cycles, title: 'dgtest');

      expect(html, contains('<!doctype html>'));
      expect(html, contains('dgtest'));
      expect(html, contains('lib/models/session.dart'));
      // Every placeholder occurrence must be substituted, not just the
      // first one (the title appears both in <title> and in the sidebar).
      expect(html, isNot(contains('__TITLE__')));
      expect(html, isNot(contains('__DATA_JSON__')));
      // No external network dependency: the page must not load anything
      // over http(s).
      expect(html, isNot(contains('http://')));
      expect(html, isNot(contains('https://')));

      final marker = 'const DATA = ';
      final start = html.indexOf(marker) + marker.length;
      final end = html.indexOf(';\n(function');
      final decoded = jsonDecode(html.substring(start, end)) as Map;
      expect((decoded['nodes'] as List), hasLength(4));
      expect((decoded['cycles'] as List), hasLength(1));
    });

    test('large graphs collapse to folder nodes in the rendered page', () {
      final bigDir = Directory.systemTemp.createTempSync(
        'dart_context_mcp_biggraph_',
      );
      addTearDown(() => bigDir.deleteSync(recursive: true));
      const dirs = ['screens', 'models', 'widgets', 'services'];
      for (final dir in dirs) {
        Directory(p.join(bigDir.path, 'lib', dir)).createSync(recursive: true);
      }
      File(p.join(bigDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: bigfix
environment:
  sdk: ^3.10.0
''');
      for (var i = 0; i < 60; i++) {
        final dir = dirs[i % dirs.length];
        File(
          p.join(bigDir.path, 'lib', dir, 'file$i.dart'),
        ).writeAsStringSync('class File$i {}\n');
      }

      final index = DartContextIndexer(bigDir.path).build();
      final graph = buildDependencyGraph(index);
      expect(graph.nodes, hasLength(60));

      final html = buildDependencyGraphHtml(graph, [], title: 'bigfix');
      // The auto-collapse threshold and layered-layout logic must both be
      // present in the shipped page - these are the two features that make
      // the graph usable/readable on a real project rather than a blob.
      expect(html, contains('AUTO_COLLAPSE_THRESHOLD'));
      expect(html, contains('function layoutLayered'));
      expect(html, contains('folder:'));
    });

    test('buildSymbolGraph exposes classes/methods/fields as nodes', () {
      final index = DartContextIndexer(graphDir.path).build();
      final symbolGraph = buildSymbolGraph(index);

      final userFile = symbolGraph.nodes.singleWhere(
        (n) => n.id == 'file:lib/models/user.dart',
      );
      expect(userFile.kind, 'file');
      expect(userFile.parentId, isNull);

      final userClass = symbolGraph.nodes.singleWhere(
        (n) => n.kind == 'class' && n.label == 'User',
      );
      expect(userClass.parentId, userFile.id);

      // The class's field must be nested under the class node, not the file
      // node directly.
      final sessionField = symbolGraph.nodes.singleWhere(
        (n) => n.kind == 'field' && n.path == 'lib/models/user.dart',
      );
      expect(sessionField.label, 'session');
      expect(sessionField.parentId, userClass.id);

      final containsEdges = symbolGraph.edges.where(
        (e) => e.type == 'contains',
      );
      expect(
        containsEdges,
        contains(
          predicate<SymbolGraphEdge>(
            (e) => e.from == userFile.id && e.to == userClass.id,
          ),
        ),
      );

      // File-to-file import edges are still present, just re-typed.
      final importEdges = symbolGraph.edges.where((e) => e.type == 'imports');
      expect(
        importEdges,
        contains(
          predicate<SymbolGraphEdge>(
            (e) =>
                e.from == 'file:lib/screens/home_screen.dart' &&
                e.to == 'file:lib/models/user.dart',
          ),
        ),
      );
    });

    test('rendered page embeds the symbol graph for drill-down', () {
      final index = DartContextIndexer(graphDir.path).build();
      final graph = buildDependencyGraph(index);
      final symbolGraph = buildSymbolGraph(index);
      final html = buildDependencyGraphHtml(
        graph,
        [],
        title: 'dgtest',
        symbols: symbolGraph,
      );

      expect(html, contains('symbolNodes'));
      expect(html, contains('function applyDrillDown'));
      expect(html, contains('"kind":"class"'));
      expect(html, contains('sym:lib/models/user.dart'));
    });
  });

  group('MCP server', () {
    late StreamController<List<int>> stdinController;
    late IOSink stdoutSink;
    late StringBuffer stdoutBuffer;

    setUp(() {
      stdinController = StreamController<List<int>>();
      stdoutBuffer = StringBuffer();
      stdoutSink = IOSink(
        StreamController<List<int>>()
          ..stream.listen((bytes) => stdoutBuffer.write(utf8.decode(bytes))),
      );
    });

    List<Map<String, Object?>> parseResponses() {
      return stdoutBuffer
          .toString()
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .map((line) => jsonDecode(line) as Map<String, Object?>)
          .toList();
    }

    void send(Map<String, Object?> message) {
      stdinController.add(utf8.encode('${jsonEncode(message)}\n'));
    }

    test('handles initialize, tools/list, and tools/call', () async {
      final serverDone = runMcpServer(
        currentDirectory: tempDir.path,
        input: stdinController.stream,
        output: stdoutSink,
      );

      send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'});
      send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
      send({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'dart_symbols',
          'arguments': {'root': tempDir.path, 'query': 'SessionScreen'},
        },
      });
      send({
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {
          'name': 'dart_context',
          'arguments': {'root': tempDir.path, 'symbol': 'NoSuchThing'},
        },
      });

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await stdinController.close();
      await serverDone;

      final responses = parseResponses();
      expect(responses, hasLength(4));

      expect(
        responses[0]['result'],
        containsPair('protocolVersion', isA<String>()),
      );

      final tools = (responses[1]['result'] as Map)['tools'] as List;
      expect(
        tools.map((t) => (t as Map)['name']),
        containsAll([
          'dart_index',
          'dart_symbols',
          'dart_context',
          'dart_impact',
          'dart_query',
        ]),
      );

      final symbolsContent =
          ((responses[2]['result'] as Map)['content'] as List).first as Map;
      expect(symbolsContent['text'], contains('SessionScreen'));

      final errorResult = responses[3]['result'] as Map;
      expect(errorResult['isError'], isTrue);
    });

    test('advertises a serverInfo version matching pubspec.yaml', () async {
      final serverDone = runMcpServer(
        currentDirectory: tempDir.path,
        input: stdinController.stream,
        output: stdoutSink,
      );

      send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await stdinController.close();
      await serverDone;

      final responses = parseResponses();
      final serverInfo =
          (responses.single['result'] as Map)['serverInfo'] as Map;

      // Reads the package's own pubspec.yaml (dart test's working directory
      // is the package root) so a version bump that forgets to update the
      // hardcoded serverInfo constant in mcp_server.dart fails loudly here
      // instead of silently shipping a stale version to MCP clients.
      final pubspecVersion = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);

      expect(serverInfo['version'], pubspecVersion);
    });
  });
}
