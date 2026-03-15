import 'package:rwkv_dart/rwkv_dart.dart';

class McpToolCatalog {
  final List<ToolDefinition> tools;
  final Map<String, McpToolReference> references;

  const McpToolCatalog({required this.tools, required this.references});
}

class McpHub {
  final List<McpClient> servers;
  final bool namespaceTools;
  final bool namespacePrompts;
  final bool namespaceResources;

  const McpHub({
    required this.servers,
    this.namespaceTools = false,
    this.namespacePrompts = false,
    this.namespaceResources = false,
  });

  bool get _shouldNamespaceTools => namespaceTools || servers.length > 1;
  bool get _shouldNamespacePrompts => namespacePrompts || servers.length > 1;
  bool get _shouldNamespaceResources =>
      namespaceResources || servers.length > 1;

  String get _logPrefix => '[MCP/hub]';

  Future<void> connectAll() async {
    mcpLogDebug('$_logPrefix connecting ${servers.length} server(s)');
    for (final server in servers) {
      mcpLogDebug('$_logPrefix connect server=${server.id}');
      await server.connect();
    }
    mcpLogDebug('$_logPrefix all servers connected');
  }

  Future<void> invalidateAllCaches() async {
    mcpLogDebug(
      '$_logPrefix invalidating caches for ${servers.length} server(s)',
    );
    for (final server in servers) {
      server.invalidateAllCaches();
    }
  }

  Future<McpToolCatalog> buildToolCatalog({bool refresh = false}) async {
    mcpLogDebug(
      '$_logPrefix building tool catalog '
      '(refresh=$refresh, namespaced=$_shouldNamespaceTools)',
    );
    final references = <String, McpToolReference>{};
    final definitions = <ToolDefinition>[];

    for (final server in servers) {
      final tools = await server.listTools(refresh: refresh);
      mcpLogDebug(
        '$_logPrefix server=${server.id} exported ${tools.length} tool(s)',
      );
      for (final tool in tools) {
        final exposedName = _shouldNamespaceTools
            ? '${server.id}__${tool.name}'
            : tool.name;
        if (references.containsKey(exposedName)) {
          mcpLogError('$_logPrefix duplicate tool name detected: $exposedName');
          throw StateError('duplicate MCP tool name: $exposedName');
        }
        references[exposedName] = McpToolReference(
          serverId: server.id,
          exposedName: exposedName,
          tool: tool,
        );
        definitions.add(
          tool.toToolDefinition(exposedName: exposedName, serverId: server.id),
        );
      }
    }

    mcpLogDebug(
      '$_logPrefix tool catalog ready: ${definitions.length} tool(s)',
    );
    return McpToolCatalog(
      tools: List<ToolDefinition>.unmodifiable(definitions),
      references: Map<String, McpToolReference>.unmodifiable(references),
    );
  }

  Future<McpToolResult> callTool(
    String exposedName, {
    Map<String, dynamic>? arguments,
  }) async {
    mcpLogDebug(
      '$_logPrefix resolving tool call name=$exposedName '
      'args=${arguments == null ? 0 : arguments.length}',
    );
    final catalog = await buildToolCatalog();
    final reference = catalog.references[exposedName];
    if (reference == null) {
      mcpLogError('$_logPrefix unknown tool: $exposedName');
      throw StateError('unknown MCP tool: $exposedName');
    }
    final server = _serverById(reference.serverId);
    mcpLogDebug(
      '$_logPrefix routing tool name=$exposedName '
      'server=${server.id} raw=${reference.tool.name}',
    );
    return server.callTool(reference.tool.name, arguments: arguments);
  }

  Future<List<McpPromptReference>> listPrompts({bool refresh = false}) async {
    mcpLogDebug(
      '$_logPrefix listing prompts '
      '(refresh=$refresh, namespaced=$_shouldNamespacePrompts)',
    );
    final result = <McpPromptReference>[];
    for (final server in servers) {
      final prompts = await server.listPrompts(refresh: refresh);
      mcpLogDebug(
        '$_logPrefix server=${server.id} exported ${prompts.length} prompt(s)',
      );
      for (final prompt in prompts) {
        result.add(
          McpPromptReference(
            serverId: server.id,
            exposedName: _shouldNamespacePrompts
                ? '${server.id}__${prompt.name}'
                : prompt.name,
            prompt: prompt,
          ),
        );
      }
    }
    mcpLogDebug('$_logPrefix prompts ready: ${result.length} prompt(s)');
    return result;
  }

  Future<McpPromptResult> getPrompt(
    String exposedName, {
    Map<String, String>? arguments,
  }) async {
    mcpLogDebug(
      '$_logPrefix resolving prompt name=$exposedName '
      'args=${arguments == null ? 0 : arguments.length}',
    );
    final prompts = await listPrompts();
    final reference = prompts.firstWhere(
      (item) => item.exposedName == exposedName,
      orElse: () {
        mcpLogError('$_logPrefix unknown prompt: $exposedName');
        throw StateError('unknown MCP prompt: $exposedName');
      },
    );
    final server = _serverById(reference.serverId);
    mcpLogDebug(
      '$_logPrefix routing prompt name=$exposedName '
      'server=${server.id} raw=${reference.prompt.name}',
    );
    return server.getPrompt(reference.prompt.name, arguments: arguments);
  }

  Future<List<McpResourceReference>> listResources({
    bool refresh = false,
  }) async {
    mcpLogDebug(
      '$_logPrefix listing resources '
      '(refresh=$refresh, namespaced=$_shouldNamespaceResources)',
    );
    final result = <McpResourceReference>[];
    for (final server in servers) {
      final resources = await server.listResources(refresh: refresh);
      mcpLogDebug(
        '$_logPrefix server=${server.id} exported ${resources.length} resource(s)',
      );
      for (final resource in resources) {
        result.add(
          McpResourceReference(
            serverId: server.id,
            qualifiedUri: _shouldNamespaceResources
                ? '${server.id}::${resource.uri}'
                : resource.uri,
            resource: resource,
          ),
        );
      }
    }
    mcpLogDebug('$_logPrefix resources ready: ${result.length} resource(s)');
    return result;
  }

  Future<List<McpResourceTemplateReference>> listResourceTemplates({
    bool refresh = false,
  }) async {
    mcpLogDebug(
      '$_logPrefix listing resource templates '
      '(refresh=$refresh, namespaced=$_shouldNamespaceResources)',
    );
    final result = <McpResourceTemplateReference>[];
    for (final server in servers) {
      final templates = await server.listResourceTemplates(refresh: refresh);
      mcpLogDebug(
        '$_logPrefix server=${server.id} exported ${templates.length} template(s)',
      );
      for (final template in templates) {
        result.add(
          McpResourceTemplateReference(
            serverId: server.id,
            qualifiedUriTemplate: _shouldNamespaceResources
                ? '${server.id}::${template.uriTemplate}'
                : template.uriTemplate,
            template: template,
          ),
        );
      }
    }
    mcpLogDebug(
      '$_logPrefix resource templates ready: ${result.length} template(s)',
    );
    return result;
  }

  Future<McpReadResourceResult> readResource(String qualifiedUri) async {
    mcpLogDebug('$_logPrefix resolving resource uri=$qualifiedUri');
    final resources = await listResources();
    final reference = resources.firstWhere(
      (item) => item.qualifiedUri == qualifiedUri,
      orElse: () {
        mcpLogError('$_logPrefix unknown resource: $qualifiedUri');
        throw StateError('unknown MCP resource: $qualifiedUri');
      },
    );
    final server = _serverById(reference.serverId);
    mcpLogDebug(
      '$_logPrefix routing resource uri=$qualifiedUri '
      'server=${server.id} raw=${reference.resource.uri}',
    );
    return server.readResource(reference.resource.uri);
  }

  McpClient _serverById(String id) {
    return servers.firstWhere(
      (server) => server.id == id,
      orElse: () {
        mcpLogError('$_logPrefix unknown server id: $id');
        throw StateError('unknown MCP server: $id');
      },
    );
  }
}
