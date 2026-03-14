import 'dart:convert';

import 'package:rwkv_dart/rwkv_dart.dart';

const String mcpLatestProtocolVersion = '2025-11-25';

Map<String, dynamic> _jsonMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.from(value);
  }
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _jsonMapList(dynamic value) {
  if (value is! Iterable) {
    return const <Map<String, dynamic>>[];
  }
  return value.map(_jsonMap).toList();
}

class McpImplementationInfo {
  final String name;
  final String version;
  final String? title;

  const McpImplementationInfo({
    required this.name,
    required this.version,
    this.title,
  });

  factory McpImplementationInfo.fromJson(dynamic data) {
    final json = _jsonMap(data);
    return McpImplementationInfo(
      name: json['name']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      title: json['title']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'version': version,
      if (title != null && title!.isNotEmpty) 'title': title,
    };
  }
}

class McpInitializeResult {
  final String protocolVersion;
  final Map<String, dynamic> capabilities;
  final McpImplementationInfo serverInfo;
  final String? instructions;

  const McpInitializeResult({
    required this.protocolVersion,
    required this.capabilities,
    required this.serverInfo,
    this.instructions,
  });

  factory McpInitializeResult.fromJson(dynamic data) {
    final json = _jsonMap(data);
    return McpInitializeResult(
      protocolVersion: json['protocolVersion']?.toString() ?? '',
      capabilities: _jsonMap(json['capabilities']),
      serverInfo: McpImplementationInfo.fromJson(json['serverInfo']),
      instructions: json['instructions']?.toString(),
    );
  }
}

class McpTool {
  final String name;
  final String? title;
  final String? description;
  final Map<String, dynamic> inputSchema;
  final Map<String, dynamic>? outputSchema;
  final Map<String, dynamic> raw;

  const McpTool({
    required this.name,
    this.title,
    this.description,
    required this.inputSchema,
    this.outputSchema,
    this.raw = const <String, dynamic>{},
  });

  factory McpTool.fromJson(dynamic data) {
    final json = _jsonMap(data);
    return McpTool(
      name: json['name']?.toString() ?? '',
      title: json['title']?.toString(),
      description: json['description']?.toString(),
      inputSchema: _jsonMap(json['inputSchema']),
      outputSchema: json['outputSchema'] == null
          ? null
          : _jsonMap(json['outputSchema']),
      raw: json,
    );
  }

  ToolDefinition toToolDefinition({
    required String exposedName,
    String? serverId,
  }) {
    final descriptionParts = <String>[
      if (serverId != null && serverId.isNotEmpty) 'MCP server: $serverId.',
      if (title != null && title!.isNotEmpty && title != name) 'Title: $title.',
      if (description != null && description!.trim().isNotEmpty)
        description!.trim(),
    ];
    return ToolDefinition.function(
      function: ToolFunction(
        name: exposedName,
        description: descriptionParts.isEmpty
            ? null
            : descriptionParts.join(' '),
        parameters: inputSchema.isEmpty
            ? <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{},
              }
            : Map<String, dynamic>.from(inputSchema),
      ),
    );
  }
}

class McpToolReference {
  final String serverId;
  final String exposedName;
  final McpTool tool;

  const McpToolReference({
    required this.serverId,
    required this.exposedName,
    required this.tool,
  });
}

class McpToolResult {
  final List<Map<String, dynamic>> content;
  final Map<String, dynamic>? structuredContent;
  final bool isError;
  final Map<String, dynamic> raw;

  const McpToolResult({
    required this.content,
    this.structuredContent,
    required this.isError,
    this.raw = const <String, dynamic>{},
  });

  factory McpToolResult.fromJson(dynamic data) {
    final json = _jsonMap(data);
    return McpToolResult(
      content: _jsonMapList(json['content']),
      structuredContent: json['structuredContent'] == null
          ? null
          : _jsonMap(json['structuredContent']),
      isError: json['isError'] == true,
      raw: json,
    );
  }

  String toToolMessageContent() {
    final parts = <String>[
      for (final block in content)
        if (_contentBlockToText(block) case final text? when text.isNotEmpty)
          text,
    ];

    if (parts.isEmpty && structuredContent != null) {
      parts.add(jsonEncode(structuredContent));
    }

    if (parts.isEmpty) {
      parts.add(jsonEncode(raw));
    }

    final body = parts.join('\n\n');
    if (!isError) {
      return body;
    }
    return 'MCP tool call failed\n$body';
  }

  static String? _contentBlockToText(Map<String, dynamic> block) {
    final type = block['type']?.toString() ?? '';
    switch (type) {
      case 'text':
        return block['text']?.toString() ?? '';
      case 'image':
        return '[image content omitted]';
      case 'audio':
        return '[audio content omitted]';
      case 'resource_link':
        final uri = block['uri']?.toString() ?? '';
        return uri.isEmpty ? '[resource link]' : '[resource link: $uri]';
      case 'resource':
        final resource = _jsonMap(block['resource']);
        final text = resource['text']?.toString();
        if (text != null && text.isNotEmpty) {
          return text;
        }
        final uri = resource['uri']?.toString() ?? '';
        return uri.isEmpty ? '[resource content]' : '[resource: $uri]';
      default:
        if (block.isEmpty) {
          return null;
        }
        return jsonEncode(block);
    }
  }
}

