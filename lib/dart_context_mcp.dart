/// Local Dart/Flutter code context indexer, usable as a CLI or as an MCP
/// stdio server.
library;

export 'src/cli.dart' show runCli;
export 'src/code_index.dart'
    show
        CodeIndex,
        CommandOutput,
        IndexCache,
        indexDirectoryName,
        indexFileName,
        buildContextReport,
        buildImpactReport,
        buildIndexReport,
        buildQueryReport,
        buildSymbolsReport,
        parseLimit,
        riskFor;
export 'src/graph.dart'
    show
        DependencyGraph,
        GraphEdge,
        GraphNode,
        buildDependencyGraph,
        buildDependencyGraphHtml,
        detectCycles;
export 'src/indexer.dart' show DartContextIndexer;
export 'src/mcp_server.dart' show runMcpServer, toolDefinitions;
export 'src/model.dart'
    show
        CodeReference,
        DartFileIndex,
        DartSymbol,
        OutputFormat,
        QueryResult,
        parseOutputFormat;
export 'src/overview.dart' show buildOverviewReport;
export 'src/symbol_graph.dart'
    show SymbolGraph, SymbolGraphEdge, SymbolGraphNode, buildSymbolGraph;

const String toolName = 'dart_context_mcp';
