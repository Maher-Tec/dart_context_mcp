import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import 'code_index.dart';
import 'file_scan.dart';
import 'import_resolver.dart';
import 'model.dart';

class DartContextIndexer {
  final String rootPath;
  final bool includeGenerated;

  DartContextIndexer(this.rootPath, {this.includeGenerated = false});

  CodeIndex build() {
    final root = Directory(rootPath);
    if (!root.existsSync()) {
      throw FileSystemException('Project root does not exist', rootPath);
    }

    final files = <DartFileIndex>[];
    for (final file in _dartFiles(root)) {
      // Stored (and therefore displayed, everywhere) as posix-style even on
      // Windows: this is the one place a file's path is first computed, so
      // normalizing it here means every downstream consumer - CLI/MCP
      // output, the dependency graph, cross-tool comparisons an agent might
      // do - sees one consistent spelling instead of `lib\main.dart` from
      // some tools and `lib/main.dart` from others (the graph module
      // already normalized to posix internally; other reports didn't).
      final relativePath = toPosixPath(p.relative(file.path, from: rootPath));
      try {
        final content = file.readAsStringSync();
        final mtime = file.lastModifiedSync().toUtc();
        files.add(_parseFile(relativePath, content, file.path, mtime));
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }

    return CodeIndex(
      rootPath: rootPath,
      projectName: p.basename(rootPath),
      generatedAt: DateTime.now().toUtc(),
      files: files,
    );
  }

  Iterable<File> _dartFiles(Directory root) {
    return listDartFilePaths(
      rootPath,
      includeGenerated: includeGenerated,
    ).map((relative) => File(p.join(rootPath, relative)));
  }

  DartFileIndex _parseFile(
    String relativePath,
    String content,
    String path,
    DateTime mtime,
  ) {
    final result = parseString(
      content: content,
      path: path,
      throwIfDiagnostics: false,
    );
    final imports = result.unit.directives
        .whereType<ImportDirective>()
        .map((directive) => directive.uri.stringValue)
        .whereType<String>()
        .toList();
    final visitor = _SymbolVisitor(relativePath, content, result.lineInfo);
    result.unit.accept(visitor);
    return DartFileIndex(
      path: relativePath,
      imports: imports,
      symbols: visitor.symbols,
      mtime: mtime,
    );
  }
}

class _SymbolVisitor extends RecursiveAstVisitor<void> {
  final String path;
  final String content;
  final LineInfo lineInfo;
  final List<DartSymbol> symbols = [];
  String? _container;

  _SymbolVisitor(this.path, this.content, this.lineInfo);

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final name = node.namePart.typeName.lexeme;
    _add(name, 'class', node.offset, node.body.offset);
    _withContainer(name, () => super.visitClassDeclaration(node));
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    _add(node.name.lexeme, 'mixin', node.offset, node.body.offset);
    _withContainer(node.name.lexeme, () => super.visitMixinDeclaration(node));
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    final name = node.namePart.typeName.lexeme;
    _add(name, 'enum', node.offset, node.body.offset);
    _withContainer(name, () => super.visitEnumDeclaration(node));
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    _add(node.name.lexeme, 'enum_constant', node.offset, node.end);
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final name =
        node.name?.lexeme ?? 'extension@${_location(node.offset).lineNumber}';
    _add(name, 'extension', node.offset, node.body.offset);
    _withContainer(name, () => super.visitExtensionDeclaration(node));
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _add(node.name.lexeme, 'function', node.offset, node.end);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _add(node.name.lexeme, 'method', node.offset, node.end);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    // Unnamed constructors are indexed as `<Class>.new`, mirroring Dart 3's
    // constructor-tearoff syntax, so an exact-name lookup for the class
    // itself doesn't collide with its own default constructor.
    final constructorName = node.name?.lexeme ?? 'new';
    _add(constructorName, 'constructor', node.offset, node.end);
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    _add(node.name.lexeme, 'typedef', node.offset, node.end);
    super.visitGenericTypeAlias(node);
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    _add(node.name.lexeme, 'typedef', node.offset, node.end);
    super.visitFunctionTypeAlias(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    for (final variable in node.variables.variables) {
      _add(variable.name.lexeme, 'variable', variable.offset, node.end);
    }
    super.visitTopLevelVariableDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    for (final variable in node.fields.variables) {
      _add(variable.name.lexeme, 'field', variable.offset, node.end);
    }
    super.visitFieldDeclaration(node);
  }

  void _withContainer(String container, void Function() visitChildren) {
    final previous = _container;
    _container = container;
    visitChildren();
    _container = previous;
  }

  void _add(String name, String kind, int offset, int signatureEnd) {
    final location = _location(offset);
    symbols.add(
      DartSymbol(
        name: name,
        kind: kind,
        path: path,
        line: location.lineNumber,
        column: location.columnNumber,
        container: _container,
        signature: _signatureFor(offset, signatureEnd),
      ),
    );
  }

  CharacterLocation _location(int offset) => lineInfo.getLocation(offset);

  /// Builds a compact, single-line signature for the declaration starting at
  /// [offset]. Scans forward to the first `{` or `;` that is *not* inside a
  /// parenthesized parameter list (which may itself contain `{`/`}` for
  /// named parameters), so multi-line signatures are captured correctly
  /// instead of being cut off after the first physical line.
  String _signatureFor(int offset, int hardEnd) {
    final end = hardEnd.clamp(offset, content.length);
    final raw = content.substring(offset, end);
    var depth = 0;
    var cut = raw.length;
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        if (depth > 0) depth--;
      } else if ((ch == '{' || ch == ';') && depth == 0) {
        cut = i;
        break;
      }
    }
    var sig = raw.substring(0, cut).trim().replaceAll(RegExp(r'\s+'), ' ');
    if (sig.isEmpty) {
      sig = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    }
    if (sig.length > 200) {
      sig = '${sig.substring(0, 197)}...';
    }
    return sig;
  }
}
