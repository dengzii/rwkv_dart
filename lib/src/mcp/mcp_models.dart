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

String? _contentBlockToText(Map<String, dynamic> block) {
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
}

class McpResource {
  final String uri;
  final String? name;
  final String? title;
  final String? description;
  final String? mimeType;
  final int? size;
  final Map<String, dynamic>? annotations;
  final Map<String, dynamic> raw;

  const McpResource({
    required this.uri,
    this.name,
    this.title,
    this.description,
    this.mimeType,
    this.size,
    this.annotations,
    this.raw = const <String, dynamic>{},
  });

  factory McpResource.fromJson(dynamic data) {
    final json = _jsonMap(data);
    return McpResource(
      uri: json['uri']?.toString() ?? '',
      name: json['name']?.toString(),
      title: json['title']?.toString(),
      description: json['description']?.toString(),
      mimeType: json['mimeType']?.toString(),
      size: (json['size'] as num?)?.toInt(),
      annotations: json['annotations'] == null
          ? null
          : _jsonMap(json['annotations']),
      raw: json,
    );
  }
}

class McpResourceReference {
  final String serverId;
  final String qualifiedUri;
  final McpResource resource;

  const McpResourceReference({
    required this.serverId,
    required this.qualifiedUri,
    required this.resource,
  });
}

class McpResourceTemplate {
  final String uriTemplate;
  final String? name;
  final String? title;
  final String? description;
  final String? mimeType;
  final Map<String, dynamic>? annotations;
  final Map<String, dynamic> raw;

  const McpResourceTemplate({
    required this.uriTemplate,
    this.name,
    this.title,
    this.description,
    this.mimeType,
    this.annotations,
    this.raw = const <String, dynamic>{},
  });

  factory McpResourceTemplate.fromJson(dynamic data) {
    final json = _jsonMap(data);
    return McpResourceTemplate(
      uriTemplate: json['uriTemplate']?.toString() ?? '',
      name: json['name']?.toString(),
      title: json['title']?.toString(),
      description: json['description']?.toString(),
      mimeType: json['mimeType']?.toString(),
      annotations: json['annotations'] == null
          ? null
          : _jsonMap(json['annotations']),
      raw: json,
    );
  }
}

class McpResourceTemplateReference {
  final String serverId;
  final String qualifiedUriTemplate;
  final McpResourceTemplate template;

  const McpResourceTemplateReference({
    required this.serverId,
    required this.qualifiedUriTemplate,
    required this.template,
  });
}

class McpResourceContent {
  final String uri;
  final String? mimeType;
  final String? text;
  final String? blob;
  final Map<String, dynamic> raw;

  const McpResourceContent({
    required this.uri,
    this.mimeType,
    this.text,
    this.blob,
    this.raw = const <String, dynamic>{},
  });

  factory McpResourceContent.fromJson(dynamic data) {
    final json = _jsonMap(data);
    return McpResourceContent(
      uri: json['uri']?.toString() ?? '',
      mimeType: json['mimeType']?.toString(),
      text: json['text']?.toString(),
      blob: json['blob']?.toString(),
      raw: json,
    );
  }

  String toText() {
    if (text != null && text!.isNotEmpty) {
      return text!;
    }
    if (blob != null && blob!.isNotEmpty) {
      return '[binary resource: $uri]';
    }
    return jsonEncode(raw);
  }
}

class McpReadResourceResult {
  final List<McpResourceContent> contents;
  final Map<String, dynamic> raw;

  const McpReadResourceResult({
    required this.contents,
    this.raw = const <String, dynamic>{},
  });

  factory McpReadResourceResult.fromJson(dynamic data) {
    final json = _jsonMap(data);
    final contents = (json['contents'] as Iterable? ?? const <dynamic>[])
        .map(McpResourceContent.fromJson)
        .toList();
    return McpReadResourceResult(contents: contents, raw: json);
  }

  String toText() {
    if (contents.isEmpty) {
      return jsonEncode(raw);
    }
    return contents.map((item) => item.toText()).join('\n\n');
  }
}

class McpPromptArgument {
  final String name;
  final String? title;
  final String? description;
  final bool required;

  const McpPromptArgument({
    required this.name,
    this.title,
    this.description,
    required this.required,
  });

  factory McpPromptArgument.fromJson(dynamic data) {
    final json = _jsonMap(data);
    return McpPromptArgument(
      name: json['name']?.toString() ?? '',
      title: json['title']?.toString(),
      description: json['description']?.toString(),
      required: json['required'] == true,
    );
  }
}

class McpPrompt {
  final String name;
  final String? title;
  final String? description;
  final List<McpPromptArgument> arguments;
  final Map<String, dynamic> raw;

  const McpPrompt({
    required this.name,
    this.title,
    this.description,
    this.arguments = const <McpPromptArgument>[],
    this.raw = const <String, dynamic>{},
  });

  factory McpPrompt.fromJson(dynamic data) {
    final json = _jsonMap(data);
    final arguments = (json['arguments'] as Iterable? ?? const <dynamic>[])
        .map(McpPromptArgument.fromJson)
        .toList();
    return McpPrompt(
      name: json['name']?.toString() ?? '',
      title: json['title']?.toString(),
      description: json['description']?.toString(),
      arguments: arguments,
      raw: json,
    );
  }
}

class McpPromptReference {
  final String serverId;
  final String exposedName;
  final McpPrompt prompt;

  const McpPromptReference({
    required this.serverId,
    required this.exposedName,
    required this.prompt,
  });
}

class McpPromptMessage {
  final String role;
  final Map<String, dynamic> content;
  final Map<String, dynamic> raw;

  const McpPromptMessage({
    required this.role,
    required this.content,
    this.raw = const <String, dynamic>{},
  });

  factory McpPromptMessage.fromJson(dynamic data) {
    final json = _jsonMap(data);
    return McpPromptMessage(
      role: json['role']?.toString() ?? 'user',
      content: _jsonMap(json['content']),
      raw: json,
    );
  }

  String toText() {
    final text = _contentBlockToText(content);
    if (text != null && text.isNotEmpty) {
      return text;
    }
    return jsonEncode(raw);
  }

  ChatMessage toChatMessage() {
    return ChatMessage(role: role, content: toText());
  }
}

class McpPromptResult {
  final String? description;
  final List<McpPromptMessage> messages;
  final Map<String, dynamic> raw;

  const McpPromptResult({
    this.description,
    this.messages = const <McpPromptMessage>[],
    this.raw = const <String, dynamic>{},
  });

  factory McpPromptResult.fromJson(dynamic data) {
    final json = _jsonMap(data);
    final messages = (json['messages'] as Iterable? ?? const <dynamic>[])
        .map(McpPromptMessage.fromJson)
        .toList();
    return McpPromptResult(
      description: json['description']?.toString(),
      messages: messages,
      raw: json,
    );
  }

  List<ChatMessage> toChatMessages() {
    return messages.map((message) => message.toChatMessage()).toList();
  }

  String toTextTranscript() {
    return messages
        .map((message) => '${message.role}: ${message.toText()}')
        .join('\n');
  }
}
