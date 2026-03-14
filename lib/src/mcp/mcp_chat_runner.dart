import 'dart:async';
import 'dart:convert';

import 'package:rwkv_dart/rwkv_dart.dart';

class McpChatResult {
  final String content;
  final List<ChatMessage> messages;
  final int rounds;

  const McpChatResult({
    required this.content,
    required this.messages,
    required this.rounds,
  });
}

class McpToolExecution {
  final McpToolReference tool;
  final ToolCall toolCall;
  final Map<String, dynamic> arguments;

  const McpToolExecution({
    required this.tool,
    required this.toolCall,
    required this.arguments,
  });
}

class McpChatRunner {
  final RWKVBase llm;
  final List<McpClient> servers;
  final String model;
  final int maxToolRounds;
  final bool namespaceTools;

  const McpChatRunner({
    required this.llm,
    required this.servers,
    required this.model,
    this.maxToolRounds = 8,
    this.namespaceTools = false,
  });

  Future<McpChatResult> run({
    required List<ChatMessage> messages,
    String? prompt,
    ReasoningEffort reasoning = ReasoningEffort.none,
    int? maxTokens,
    int? maxCompletionTokens,
    ToolChoice? toolChoice,
    bool? parallelToolCalls,
    Map<String, dynamic>? additional,
    void Function(String delta)? onTextDelta,
    void Function(McpToolExecution execution)? onToolCall,
    void Function(McpToolExecution execution, McpToolResult result)?
    onToolResult,
  }) async {
    final workingMessages = List<ChatMessage>.from(messages);
    final toolCatalog = await _loadToolCatalog();

    for (var round = 1; round <= maxToolRounds; round++) {
      final turn = await _collectAssistantTurn(
        llm.chat(
          ChatParam.openAi(
            model: model,
            reasoning: reasoning,
            messages: workingMessages,
            maxTokens: maxTokens,
            maxCompletionTokens: maxCompletionTokens,
            additional: additional,
            prompt: prompt,
            tools: toolCatalog.tools,
            toolChoice: toolChoice,
            parallelToolCalls: parallelToolCalls,
          ),
        ),
        onTextDelta: onTextDelta,
      );

      if (turn.content.isNotEmpty || turn.toolCalls.isNotEmpty) {
        workingMessages.add(
          ChatMessage(
            role: 'assistant',
            content: turn.content,
            toolCalls: turn.toolCalls.isEmpty ? null : turn.toolCalls,
          ),
        );
      }

      if (turn.toolCalls.isEmpty) {
        return McpChatResult(
          content: turn.content,
          messages: List.unmodifiable(workingMessages),
          rounds: round,
        );
      }

      final executions = [
        for (final call in turn.toolCalls)
          _prepareToolExecution(call, toolCatalog),
      ];

      final results = parallelToolCalls == true && executions.length > 1
          ? await Future.wait(executions.map(_executeToolCall))
          : await _executeSequentially(executions);

      for (var i = 0; i < executions.length; i++) {
        final execution = executions[i];
        final result = results[i];

        if (execution.execution != null && result.parsed != null) {
          onToolCall?.call(execution.execution!);
          onToolResult?.call(execution.execution!, result.parsed!);
        }

        workingMessages.add(
          ChatMessage(
            role: 'tool',
            toolCallId: execution.toolCall.id,
            content: result.messageContent,
          ),
        );
      }
    }

    throw StateError(
      'Stopped after $maxToolRounds tool rounds to avoid an infinite loop.',
    );
  }

  Future<List<_ExecutedToolCall>> _executeSequentially(
    List<_PreparedToolExecution> executions,
  ) async {
    final results = <_ExecutedToolCall>[];
    for (final execution in executions) {
      results.add(await _executeToolCall(execution));
    }
    return results;
  }

  Future<_ToolCatalog> _loadToolCatalog() async {
    final references = <String, McpToolReference>{};
    final definitions = <ToolDefinition>[];
    final useNamespace = namespaceTools || servers.length > 1;

    for (final server in servers) {
      await server.connect();
      final tools = await server.listTools();
      for (final tool in tools) {
        final exposedName = useNamespace
            ? '${server.id}__${tool.name}'
            : tool.name;
        if (references.containsKey(exposedName)) {
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

    return _ToolCatalog(
      tools: List.unmodifiable(definitions),
      references: Map.unmodifiable(references),
    );
  }

  _PreparedToolExecution _prepareToolExecution(
    ToolCall toolCall,
    _ToolCatalog catalog,
  ) {
    final functionName = toolCall.function?.name;
    if (functionName == null || functionName.isEmpty) {
      return _PreparedToolExecution(
        toolCall: toolCall,
        errorMessage: _toolError(
          code: 'invalid_tool_call',
          message: 'Tool call is missing function.name',
        ),
      );
    }

    final reference = catalog.references[functionName];
    if (reference == null) {
      return _PreparedToolExecution(
        toolCall: toolCall,
        errorMessage: _toolError(
          code: 'tool_not_found',
          message: 'Unsupported MCP tool: $functionName',
        ),
      );
    }

    try {
      final arguments = _parseArguments(toolCall.function?.arguments ?? '');
      return _PreparedToolExecution(
        toolCall: toolCall,
        execution: McpToolExecution(
          tool: reference,
          toolCall: toolCall,
          arguments: arguments,
        ),
      );
    } catch (error) {
      return _PreparedToolExecution(
        toolCall: toolCall,
        errorMessage: _toolError(
          code: 'invalid_tool_arguments',
          message: error.toString(),
        ),
      );
    }
  }

  Future<_ExecutedToolCall> _executeToolCall(
    _PreparedToolExecution prepared,
  ) async {
    if (prepared.errorMessage != null) {
      return _ExecutedToolCall(messageContent: prepared.errorMessage!);
    }

    final execution = prepared.execution!;
    final server = servers.firstWhere(
      (item) => item.id == execution.tool.serverId,
    );

    try {
      final result = await server.callTool(
        execution.tool.tool.name,
        arguments: execution.arguments,
      );
      return _ExecutedToolCall(
        messageContent: result.toToolMessageContent(),
        parsed: result,
      );
    } catch (error) {
      return _ExecutedToolCall(
        messageContent: _toolError(
          code: 'tool_execution_failed',
          message: error.toString(),
        ),
      );
    }
  }

  Future<_AssistantTurn> _collectAssistantTurn(
    Stream<GenerationResponse> stream, {
    void Function(String delta)? onTextDelta,
  }) async {
    final content = StringBuffer();
    final toolCalls = <int, ToolCall>{};

    await for (final chunk in stream) {
      if (chunk.text.isNotEmpty) {
        content.write(chunk.text);
        onTextDelta?.call(chunk.text);
      }

      for (final call in chunk.toolCalls ?? const <ToolCall>[]) {
        final key = call.index ?? toolCalls.length;
        toolCalls[key] = _mergeToolCall(toolCalls[key], call);
      }
    }

    final sortedKeys = toolCalls.keys.toList()..sort();
    return _AssistantTurn(
      content: content.toString(),
      toolCalls: <ToolCall>[for (final key in sortedKeys) toolCalls[key]!],
    );
  }

  ToolCall _mergeToolCall(ToolCall? previous, ToolCall current) {
    if (previous == null) {
      return current;
    }

    final previousFunction = previous.function;
    final currentFunction = current.function;

    return previous.copyWith(
      index: current.index ?? previous.index,
      id: current.id ?? previous.id,
      type: current.type ?? previous.type,
      function: previousFunction == null
          ? currentFunction
          : currentFunction == null
          ? previousFunction
          : previousFunction.copyWith(
              name: currentFunction.name ?? previousFunction.name,
              arguments: _mergeDeltaText(
                previousFunction.arguments,
                currentFunction.arguments,
              ),
            ),
    );
  }

  String _mergeDeltaText(String previous, String current) {
    if (current.isEmpty) {
      return previous;
    }
    if (previous.isEmpty || current.startsWith(previous)) {
      return current;
    }
    return '$previous$current';
  }

  Map<String, dynamic> _parseArguments(String rawArguments) {
    if (rawArguments.trim().isEmpty) {
      return const <String, dynamic>{};
    }

    final decoded = jsonDecode(rawArguments);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    throw const FormatException('tool arguments must be a JSON object');
  }

  String _toolError({required String code, required String message}) {
    return jsonEncode(<String, dynamic>{'error': code, 'message': message});
  }
}

class _PreparedToolExecution {
  final ToolCall toolCall;
  final McpToolExecution? execution;
  final String? errorMessage;

  const _PreparedToolExecution({
    required this.toolCall,
    this.execution,
    this.errorMessage,
  });
}

class _ExecutedToolCall {
  final String messageContent;
  final McpToolResult? parsed;

  const _ExecutedToolCall({required this.messageContent, this.parsed});
}

class _ToolCatalog {
  final List<ToolDefinition> tools;
  final Map<String, McpToolReference> references;

  const _ToolCatalog({required this.tools, required this.references});
}

class _AssistantTurn {
  final String content;
  final List<ToolCall> toolCalls;

  const _AssistantTurn({required this.content, required this.toolCalls});
}
