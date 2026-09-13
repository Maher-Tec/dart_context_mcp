// ignore_for_file: avoid_print
import 'package:dart_context_mcp/dart_context_mcp.dart';

/// Indexes a Dart/Flutter project and prints a compact overview - the same
/// data the `overview` CLI command and `dart_overview` MCP tool return.
///
/// Run with: `dart run example/dart_context_mcp_example.dart <project_root>`
/// (defaults to the current directory if no argument is given).
void main(List<String> arguments) {
  final root = arguments.isNotEmpty ? arguments.first : '.';
  final index = CodeIndex.loadOrBuild(root);
  print(buildOverviewReport(index).text);

  // The same index also answers targeted questions without re-parsing:
  final settingsMatches = index.findSymbols('main');
  if (settingsMatches.isNotEmpty) {
    print('\n---');
    print(buildContextReport(index, 'main', limit: 5).text);
  }
}
