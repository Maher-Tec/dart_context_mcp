import 'dart:io';

import 'package:dart_context_mcp/dart_context_mcp.dart';

Future<void> main(List<String> arguments) async {
  final code = await runCli(arguments);
  if (code != 0) {
    exitCode = code;
  }
}
