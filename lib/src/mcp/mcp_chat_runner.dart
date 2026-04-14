import 'dart:async';
import 'dart:convert';

import 'package:rwkv_dart/rwkv_dart.dart';

sealed class McpChatEvent {
  final List<ChatMessage> messages;
  final int rounds;

  const McpChatEvent({required this.messages, required this.rounds});
}

class McpAssistantEvent extends McpChatEvent {
  final String content;
  final String reasoningContent;
  final String delta;
  final String reasoningDelta;
  final List<ToolCall> toolCalls;
  final bool isPartial;
  final bool isFinal;
  final StopReason stopReason;

  const McpAssistantEvent({
    required this.content,
    required this.delta,
    this.reasoningContent = '',
    this.reasoningDelta = '',
    required this.stopReason,
    required super.messages,
    required super.rounds,
    this.toolCalls = const [],
    this.isPartial = false,
    this.isFinal = false,
  });
}

class McpToolCallEvent extends McpChatEvent {
  final ToolCall toolCall;
  final McpToolExecution? toolExecution;
  final bool isPartial;

  const McpToolCallEvent({
    required this.toolCall,
    required super.messages,
    required super.rounds,
    this.toolExecution,
    this.isPartial = false,
  });
}

class McpToolResultEvent extends McpChatEvent {
  final McpToolCallResult toolResult;

  ToolCall get toolCall => toolResult.toolCall;

  McpToolExecution? get toolExecution => toolResult.execution;

  const McpToolResultEvent({
    required this.toolResult,
    required super.messages,
    required super.rounds,
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

class McpToolCallResult {
  final ToolCall toolCall;
  final McpToolExecution? execution;
  final McpToolCallPermission? permission;
  final String messageContent;
  final McpToolResult? result;
  final bool wasExecuted;

  const McpToolCallResult({
    required this.toolCall,
    required this.messageContent,
    required this.wasExecuted,
    this.execution,
    this.permission,
    this.result,
  });
}

class McpToolCallPermission {
  final bool isAllowed;
  final String? code;
  final String? message;

  const McpToolCallPermission.allow()
    : isAllowed = true,
      code = null,
      message = null;

  const McpToolCallPermission.deny({
    this.code = 'tool_permission_denied',
    this.message = 'MCP tool call denied by policy',
  }) : isAllowed = false;
}

typedef McpToolCallAuthorizer =
    FutureOr<McpToolCallPermission> Function(McpToolExecution execution);

class McpChatRunner {
  final LLM llm;
  final McpHub hub;
  final String model;
  final int maxToolRounds;
  final McpToolCallAuthorizer? toolCallAuthorizer;

  String get _logPrefix => '[MCP/runner]';

  McpChatRunner({
    required this.llm,
    required List<McpClient> servers,
    required this.model,
    this.maxToolRounds = 8,
    this.toolCallAuthorizer,
    bool namespaceTools = false,
  }) : hub = McpHub(servers: servers, namespaceTools: namespaceTools);

  McpChatRunner.withHub({
    required this.llm,
    required this.hub,
    required this.model,
    this.maxToolRounds = 8,
    this.toolCallAuthorizer,
  });

  Stream<McpChatEvent> run({
    required List<ChatMessage> messages,
    String? prompt,
    ReasoningEffort reasoning = ReasoningEffort.none,
    int? maxTokens,
    int? maxCompletionTokens,
    ToolChoice? toolChoice,
    bool? parallelToolCalls,
    Map<String, dynamic>? additional,
    McpToolCallAuthorizer? toolCallAuthorizer,
    void Function(String delta)? onTextDelta,
    void Function(McpToolExecution execution)? onToolCall,
    void Function(McpToolExecution execution, McpToolResult result)?
    onToolResult,
  }) async* {
    mcpLogDebug(
      '$_logPrefix run start '
      'messages=${messages.length} maxRounds=$maxToolRounds '
      'parallel=${parallelToolCalls == true}',
    );
    final workingMessages = List<ChatMessage>.from(messages);
    final effectiveToolCallAuthorizer =
        toolCallAuthorizer ?? this.toolCallAuthorizer;

    for (var round = 1; round <= maxToolRounds; round++) {
      mcpLogDebug('$_logPrefix round $round building tool catalog');
      final toolCatalog = await hub.buildToolCatalog();
      mcpLogDebug('$_logPrefix round $round tools=${toolCatalog.tools.length}');
      _AssistantTurn? turn;
      final stream = llm.chat(
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
      );
      mcpLogDebug('$_logPrefix round $round assistant response stream opened');
      final emittedToolCallKeys = <int>{};
      await for (final progress in _collectAssistantTurn(
        stream,
        onTextDelta: onTextDelta,
      )) {
        turn = _AssistantTurn(
          content: progress.content,
          reasoningContent: progress.reasoningContent,
          toolCalls: progress.toolCalls,
          stopReason: progress.stopReason,
        );
        for (var i = 0; i < progress.toolCalls.length; i++) {
          if (!emittedToolCallKeys.add(i)) {
            continue;
          }
          yield McpToolCallEvent(
            toolCall: progress.toolCalls[i],
            messages: _previewMessages(workingMessages, turn),
            rounds: round,
            isPartial: true,
          );
        }
        if (!progress.isComplete || progress.toolCalls.isNotEmpty) {
          yield McpAssistantEvent(
            delta: progress.delta,
            reasoningDelta: progress.reasoningDelta,
            content: progress.content,
            reasoningContent: progress.reasoningContent,
            messages: _previewMessages(workingMessages, turn),
            rounds: round,
            toolCalls: List.unmodifiable(progress.toolCalls),
            isPartial: !progress.isComplete,
            stopReason: progress.stopReason,
          );
        }
      }
      turn ??= const _AssistantTurn(
        content: '',
        reasoningContent: '',
        toolCalls: [],
        stopReason: StopReason.none,
      );

      mcpLogDebug(
        '$_logPrefix round $round assistant turn '
        'contentChars=${turn.content.length} toolCalls=${turn.toolCalls.length}',
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
        mcpLogDebug(
          '$_logPrefix run finished at round $round without tool calls, reason:${turn.stopReason}',
        );
        yield McpAssistantEvent(
          content: turn.content,
          reasoningContent: turn.reasoningContent,
          delta: '',
          reasoningDelta: '',
          messages: List.unmodifiable(workingMessages),
          rounds: round,
          isFinal: true,
          stopReason: turn.stopReason,
        );
        return;
      }

      final executions = <_PreparedToolExecution>[
        for (final call in turn.toolCalls)
          _prepareToolExecution(call, toolCatalog),
      ];

      final preparedCount = executions
          .where((execution) => execution.execution != null)
          .length;
      mcpLogDebug(
        '$_logPrefix round $round prepared '
        '$preparedCount/${executions.length} tool execution(s)',
      );

      for (final execution in executions) {
        yield McpToolCallEvent(
          toolCall: execution.toolCall,
          toolExecution: execution.execution,
          messages: List<ChatMessage>.unmodifiable(workingMessages),
          rounds: round,
          isPartial: false,
        );
        if (execution.execution != null) {
          onToolCall?.call(execution.execution!);
        }
      }

      final results = parallelToolCalls == true && executions.length > 1
          ? await _executeInParallel(executions, effectiveToolCallAuthorizer)
          : await _executeSequentially(executions, effectiveToolCallAuthorizer);

      for (var i = 0; i < executions.length; i++) {
        final execution = executions[i];
        final result = results[i];

        if (execution.execution != null && result.parsed != null) {
          onToolResult?.call(execution.execution!, result.parsed!);
        }

        workingMessages.add(
          ChatMessage(
            role: 'tool',
            toolCallId: execution.toolCall.id,
            content: result.messageContent,
          ),
        );
        final toolResult = McpToolCallResult(
          toolCall: execution.toolCall,
          execution: execution.execution,
          permission: result.permission,
          messageContent: result.messageContent,
          result: result.parsed,
          wasExecuted: result.wasExecuted,
        );
        yield McpToolResultEvent(
          toolResult: toolResult,
          messages: List<ChatMessage>.unmodifiable(workingMessages),
          rounds: round,
        );
      }

      mcpLogDebug(
        '$_logPrefix round $round appended ${results.length} tool result message(s)',
      );
    }

    mcpLogError('$_logPrefix stopped after $maxToolRounds rounds');
    throw StateError(
      'Stopped after $maxToolRounds tool rounds to avoid an infinite loop.',
    );
  }

  Future<McpChatEvent> runToCompletion({
    required List<ChatMessage> messages,
    String? prompt,
    ReasoningEffort reasoning = ReasoningEffort.none,
    int? maxTokens,
    int? maxCompletionTokens,
    ToolChoice? toolChoice,
    bool? parallelToolCalls,
    Map<String, dynamic>? additional,
    McpToolCallAuthorizer? toolCallAuthorizer,
    void Function(String delta)? onTextDelta,
    void Function(McpToolExecution execution)? onToolCall,
    void Function(McpToolExecution execution, McpToolResult result)?
    onToolResult,
  }) async {
    McpChatEvent? last;
    await for (final event in run(
      messages: messages,
      prompt: prompt,
      reasoning: reasoning,
      maxTokens: maxTokens,
      maxCompletionTokens: maxCompletionTokens,
      toolChoice: toolChoice,
      parallelToolCalls: parallelToolCalls,
      additional: additional,
      toolCallAuthorizer: toolCallAuthorizer,
      onTextDelta: onTextDelta,
      onToolCall: onToolCall,
      onToolResult: onToolResult,
    )) {
      last = event;
    }

    if (last == null) {
      throw StateError('MCP chat run produced no events');
    }
    return last;
  }

  Future<List<_ExecutedToolCall>> _executeInParallel(
    List<_PreparedToolExecution> executions,
    McpToolCallAuthorizer? toolCallAuthorizer,
  ) async {
    mcpLogDebug(
      '$_logPrefix executing ${executions.length} tool call(s) in parallel',
    );
    return Future.wait(
      executions.map(
        (execution) => _executeToolCall(execution, toolCallAuthorizer),
      ),
    );
  }

  Future<List<_ExecutedToolCall>> _executeSequentially(
    List<_PreparedToolExecution> executions,
    McpToolCallAuthorizer? toolCallAuthorizer,
  ) async {
    mcpLogDebug(
      '$_logPrefix executing ${executions.length} tool call(s) sequentially',
    );
    final results = <_ExecutedToolCall>[];
    for (final execution in executions) {
      results.add(await _executeToolCall(execution, toolCallAuthorizer));
    }
    return results;
  }

  _PreparedToolExecution _prepareToolExecution(
    ToolCall toolCall,
    McpToolCatalog catalog,
  ) {
    final functionName = toolCall.function?.name;
    if (functionName == null || functionName.isEmpty) {
      mcpLogWarning(
        '$_logPrefix tool call missing function name id=${toolCall.id ?? '-'}',
      );
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
      mcpLogWarning('$_logPrefix unsupported tool requested: $functionName');
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
      mcpLogDebug(
        '$_logPrefix prepared tool call name=$functionName '
        'args=${arguments.length} id=${toolCall.id ?? '-'}',
      );
      mcpLogTrace(
        '$_logPrefix tool arguments name=$functionName payload=$arguments',
      );
      return _PreparedToolExecution(
        toolCall: toolCall,
        execution: McpToolExecution(
          tool: reference,
          toolCall: toolCall,
          arguments: arguments,
        ),
      );
    } catch (error) {
      mcpLogWarning(
        '$_logPrefix invalid tool arguments name=$functionName error=$error',
      );
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
    McpToolCallAuthorizer? toolCallAuthorizer,
  ) async {
    if (prepared.errorMessage != null) {
      mcpLogWarning(
        '$_logPrefix skipping tool execution due to preparation error',
      );
      return _ExecutedToolCall(
        messageContent: prepared.errorMessage!,
        wasExecuted: false,
        permission: null,
      );
    }

    final execution = prepared.execution!;
    final permission = await _authorizeToolCall(execution, toolCallAuthorizer);
    if (!permission.isAllowed) {
      mcpLogWarning(
        '$_logPrefix tool denied name=${execution.tool.exposedName} '
        'server=${execution.tool.serverId}',
      );
      return _ExecutedToolCall(
        messageContent: _toolError(
          code: permission.code ?? 'tool_permission_denied',
          message: permission.message ?? 'MCP tool call denied by policy',
        ),
        permission: permission,
        wasExecuted: false,
      );
    }

    try {
      mcpLogDebug(
        '$_logPrefix calling tool name=${execution.tool.exposedName} '
        'server=${execution.tool.serverId}',
      );
      final result = await hub.callTool(
        execution.tool.exposedName,
        arguments: execution.arguments,
      );
      mcpLogDebug(
        '$_logPrefix tool completed name=${execution.tool.exposedName} '
        'isError=${result.isError} blocks=${result.content.length}',
      );
      return _ExecutedToolCall(
        messageContent: result.toToolMessageContent(),
        parsed: result,
        permission: permission,
        wasExecuted: true,
      );
    } catch (error) {
      mcpLogError(
        '$_logPrefix tool failed name=${execution.tool.exposedName} error=$error',
      );
      return _ExecutedToolCall(
        messageContent: _toolError(
          code: 'tool_execution_failed',
          message: error.toString(),
        ),
        permission: permission,
        wasExecuted: true,
      );
    }
  }

  Future<McpToolCallPermission> _authorizeToolCall(
    McpToolExecution execution,
    McpToolCallAuthorizer? toolCallAuthorizer,
  ) async {
    if (toolCallAuthorizer == null) {
      return const McpToolCallPermission.allow();
    }

    try {
      return await toolCallAuthorizer(execution);
    } catch (error) {
      mcpLogError(
        '$_logPrefix tool authorization failed '
        'name=${execution.tool.exposedName} error=$error',
      );
      return McpToolCallPermission.deny(
        code: 'tool_permission_error',
        message: error.toString(),
      );
    }
  }

  Stream<_AssistantTurnProgress> _collectAssistantTurn(
    Stream<GenerationResponse> stream, {
    void Function(String delta)? onTextDelta,
  }) async* {
    final content = StringBuffer();
    final reasoningContent = StringBuffer();
    final toolCalls = <int, ToolCall>{};
    var stopReason = StopReason.none;
    var chunkCount = 0;

    await for (final chunk in stream) {
      chunkCount++;
      var changed = false;
      if (chunk.stopReason != StopReason.none) {
        stopReason = chunk.stopReason;
      }
      if (chunk.content.isNotEmpty) {
        content.write(chunk.content);
        onTextDelta?.call(chunk.content);
        changed = true;
        mcpLogTrace(
          '$_logPrefix chunk#$chunkCount textLen=${chunk.content.length}',
        );
      }
      if (chunk.reasoningContent.isNotEmpty) {
        reasoningContent.write(chunk.reasoningContent);
        changed = true;
        mcpLogTrace(
          '$_logPrefix chunk#$chunkCount reasoningLen=${chunk.reasoningContent.length}',
        );
      }

      for (final call in chunk.toolCalls ?? const <ToolCall>[]) {
        final key = call.index ?? toolCalls.length;
        toolCalls[key] = _mergeToolCall(toolCalls[key], call);
        changed = true;
        mcpLogTrace(
          '$_logPrefix chunk#$chunkCount toolDelta '
          'index=$key id=${call.id ?? '-'} name=${call.function?.name ?? '-'}',
        );
      }

      if (changed) {
        yield _AssistantTurnProgress(
          content: content.toString(),
          reasoningContent: reasoningContent.toString(),
          delta: chunk.content,
          reasoningDelta: chunk.reasoningContent,
          toolCalls: _sortedToolCalls(toolCalls),
          isComplete: false,
          stopReason: stopReason,
        );
      }
    }

    final sortedToolCalls = _sortedToolCalls(toolCalls);
    mcpLogDebug(
      '$_logPrefix assistant stream complete '
      'chunks=$chunkCount contentChars=${content.length} toolCalls=${sortedToolCalls.length}',
    );
    yield _AssistantTurnProgress(
      content: content.toString(),
      reasoningContent: reasoningContent.toString(),
      toolCalls: sortedToolCalls,
      delta: '',
      reasoningDelta: '',
      isComplete: true,
      stopReason: stopReason,
    );
  }

  List<ChatMessage> _previewMessages(
    List<ChatMessage> workingMessages,
    _AssistantTurn turn,
  ) {
    if (turn.content.isEmpty && turn.toolCalls.isEmpty) {
      return List<ChatMessage>.unmodifiable(workingMessages);
    }
    return List<ChatMessage>.unmodifiable(<ChatMessage>[
      ...workingMessages,
      ChatMessage(
        role: 'assistant',
        content: turn.content,
        toolCalls: turn.toolCalls.isEmpty ? null : turn.toolCalls,
      ),
    ]);
  }

  List<ToolCall> _sortedToolCalls(Map<int, ToolCall> toolCalls) {
    final sortedKeys = toolCalls.keys.toList()..sort();
    return <ToolCall>[for (final key in sortedKeys) toolCalls[key]!];
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
      mcpLogTrace('$_logPrefix empty tool arguments, using {}');
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
    mcpLogTrace('$_logPrefix tool error payload code=$code message=$message');
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
  final McpToolCallPermission? permission;
  final bool wasExecuted;

  const _ExecutedToolCall({
    required this.messageContent,
    required this.wasExecuted,
    this.parsed,
    this.permission,
  });
}

class _AssistantTurn {
  final String content;
  final String reasoningContent;
  final List<ToolCall> toolCalls;
  final StopReason stopReason;

  const _AssistantTurn({
    required this.content,
    required this.reasoningContent,
    required this.toolCalls,
    required this.stopReason,
  });
}

class _AssistantTurnProgress {
  final String content;
  final String reasoningContent;
  final String delta;
  final String reasoningDelta;
  final List<ToolCall> toolCalls;
  final bool isComplete;
  final StopReason stopReason;

  const _AssistantTurnProgress({
    required this.content,
    required this.reasoningContent,
    required this.delta,
    required this.reasoningDelta,
    required this.toolCalls,
    required this.isComplete,
    required this.stopReason,
  });
}
