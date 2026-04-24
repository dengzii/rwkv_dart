import 'dart:convert';

import 'package:rwkv_dart/rwkv_dart.dart';

class WorkerMethod {
  static const heartbeat = 'heartbeat';
  static const init = 'init';
  static const setLogLevel = 'set_log_level';
  static const loadModel = 'load_model';
  static const chat = 'chat';
  static const clearState = 'clear_state';
  static const generate = 'generate';
  static const release = 'release';
  static const dumpLog = 'dump_log';
  static const loadInitialState = 'load_initial_state';
  static const setDecodeParam = 'set_decode_param';
  static const getGenerationState = 'get_generation_state';
  static const generationStateStream = 'generation_state_stream';
  static const stopGenerate = 'stop_generate';
  static const getSeed = 'get_seed';
  static const setSeed = 'set_seed';
  static const cancelStream = 'cancel_stream';
}

class WorkerMessage {
  static int _incrementId = 0;
  static const Object _notSet = Object();

  final String id;
  final String method;
  final dynamic param;
  final String error;
  final bool done;

  const WorkerMessage({
    required this.id,
    required this.method,
    this.param,
    this.error = '',
    this.done = false,
  });

  factory WorkerMessage.request(String method, [dynamic param]) {
    _incrementId++;
    return WorkerMessage(id: '$_incrementId', method: method, param: param);
  }

  factory WorkerMessage.fromJson(Map<String, dynamic> json) {
    return WorkerMessage(
      id: json['id']?.toString() ?? '',
      method: json['method']?.toString() ?? '',
      param: Serializer.fromJson(json['param']),
      error: json['error']?.toString() ?? '',
      done: json['done'] == true,
    );
  }

  factory WorkerMessage.fromLine(String line) {
    final decoded = jsonDecode(line);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Worker message must be a JSON object');
    }
    return WorkerMessage.fromJson(decoded);
  }

  WorkerMessage copyWith({
    String? id,
    String? method,
    Object? param = _notSet,
    String? error,
    bool? done,
  }) {
    return WorkerMessage(
      id: id ?? this.id,
      method: method ?? this.method,
      param: identical(param, _notSet) ? this.param : param,
      error: error ?? this.error,
      done: done ?? this.done,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'method': method,
      'param': Serializer.toJson(param),
      'error': error,
      'done': done,
    };
  }

  String toLine() => jsonEncode(toJson());
}

class Serializer {
  static const _typeKey = r'$rwkv_type';

  static String serialize(dynamic data) => jsonEncode(toJson(data));

  static dynamic deserialize(String data) => fromJson(jsonDecode(data));

  static dynamic toJson(dynamic data) {
    if (data == null || data is num || data is String || data is bool) {
      return data;
    }
    if (data is Map) {
      return {
        for (final entry in data.entries)
          entry.key.toString(): toJson(entry.value),
      };
    }
    if (data is List<String>) {
      return {_typeKey: 'string_list', 'values': data};
    }
    if (data is List<int>) {
      return {_typeKey: 'int_list', 'values': data};
    }
    if (data is List<double>) {
      return {_typeKey: 'double_list', 'values': data};
    }
    if (data is List<bool>) {
      return {_typeKey: 'bool_list', 'values': data};
    }
    if (data is List) {
      return data.map(toJson).toList();
    }
    if (data is RWKVLogLevel) {
      return {_typeKey: 'rwkv_log_level', 'name': data.name};
    }
    if (data is Backend) {
      return {_typeKey: 'backend', 'name': data.name};
    }
    if (data is ReasoningEffort) {
      return {_typeKey: 'reasoning_effort', 'name': data.name};
    }
    if (data is StopReason) {
      return {_typeKey: 'stop_reason', 'name': _stopReasonName(data)};
    }
    if (data is InitParam) {
      return {
        _typeKey: 'init_param',
        'dynamic_lib_dir': data.dynamicLibDir,
        'log_level': toJson(data.logLevel),
        'qnn_lib_dir': data.qnnLibDir,
        'extra': toJson(data.extra),
      };
    }
    if (data is TTSModelConfig) {
      return {
        _typeKey: 'tts_model_config',
        'text_normalizers': data.textNormalizers,
        'wav2vec2_model_path': data.wav2vec2ModelPath,
        'bi_codec_tokenizer_path': data.biCodecTokenizerPath,
        'bi_codec_detokenizer_path': data.biCodecDetokenizerPath,
      };
    }
    if (data is LoadModelParam) {
      return {
        _typeKey: 'load_model_param',
        'model_path': data.modelPath,
        'tokenizer_path': data.tokenizerPath,
        'backend': toJson(data.backend),
        'tts_model_config': toJson(data.ttsModelConfig),
      };
    }
    if (data is DecodeParam) {
      return {
        _typeKey: 'decode_param',
        'temperature': data.temperature,
        'top_k': data.topK,
        'top_p': data.topP,
        'presence_penalty': data.presencePenalty,
        'frequency_penalty': data.frequencyPenalty,
        'penalty_decay': data.penaltyDecay,
        'max_tokens': data.maxTokens,
      };
    }
    if (data is GenerationParam) {
      return {
        _typeKey: 'generation_param',
        'prompt': data.prompt,
        'model': data.model,
        'max_completion_tokens': data.maxCompletionTokens,
        'reasoning': data.reasoning,
        'stop_sequence': data.stopSequence,
        'additional': toJson(data.additional),
        'completion_stop_token': data.completionStopToken,
        'eos_token': data.eosToken,
        'bos_token': data.bosToken,
        'token_banned': data.tokenBanned,
        'return_whole_generated_result': data.returnWholeGeneratedResult,
      };
    }
    if (data is ChatMessage) {
      return {
        _typeKey: 'chat_message',
        'role': data.role,
        'content': data.content,
        'tool_call_id': data.toolCallId,
        'tool_calls': toJson(data.toolCalls),
      };
    }
    if (data is ChatParam) {
      return {
        _typeKey: 'chat_param',
        'messages': toJson(data.messages),
        'batch': toJson(data.batch),
        'tools': toJson(data.tools),
        'tool_choice': toJson(data.toolChoice),
        'parallel_tool_calls': data.parallelToolCalls,
        'model': data.model,
        'max_completion_tokens': data.maxCompletionTokens,
        'max_tokens': data.maxTokens,
        'reasoning': toJson(data.reasoning),
        'stop_sequence': data.stopSequence,
        'additional': toJson(data.additional),
        'prompt': data.prompt,
        'completion_stop_token': data.completionStopToken,
        'thinking_token': data.thinkingToken,
        'eos_token': data.eosToken,
        'bos_token': data.bosToken,
        'token_banned': data.tokenBanned,
        'return_whole_generated_result': data.returnWholeGeneratedResult,
        'add_generation_prompt': data.addGenerationPrompt,
        'space_after_role': data.spaceAfterRole,
      };
    }
    if (data is GenerationResponse) {
      return {
        _typeKey: 'generation_response',
        'content': data.content,
        'reasoning_content': data.reasoningContent,
        'token_count': data.tokenCount,
        'stop_reason': toJson(data.stopReason),
        'choices': data.choices,
        'stop_reasons': toJson(data.stopReasons),
        'tool_calls': toJson(data.toolCalls),
        'choice_tool_calls': toJson(data.choiceToolCalls),
      };
    }
    if (data is GenerationState) {
      return {
        _typeKey: 'generation_state',
        'is_generating': data.isGenerating,
        'prefill_progress': data.prefillProgress,
        'prefill_speed': data.prefillSpeed,
        'decode_speed': data.decodeSpeed,
        'timestamp': data.timestamp,
      };
    }
    if (data is ToolFunction) {
      return {
        _typeKey: 'tool_function',
        'name': data.name,
        'description': data.description,
        'parameters': toJson(data.parameters),
        'strict': data.strict,
      };
    }
    if (data is ToolDefinition) {
      return {
        _typeKey: 'tool_definition',
        'type': data.type,
        'function': toJson(data.function),
      };
    }
    if (data is ToolChoice) {
      return {
        _typeKey: 'tool_choice',
        'mode': data.mode,
        'function_name': data.functionName,
      };
    }
    if (data is ToolCallFunction) {
      return {
        _typeKey: 'tool_call_function',
        'name': data.name,
        'arguments': data.arguments,
      };
    }
    if (data is ToolCall) {
      return {
        _typeKey: 'tool_call',
        'index': data.index,
        'id': data.id,
        'type': data.type,
        'function': toJson(data.function),
      };
    }
    throw UnsupportedError('Unsupported type: ${data.runtimeType}');
  }

  static dynamic fromJson(dynamic data) {
    if (data == null || data is num || data is String || data is bool) {
      return data;
    }
    if (data is List) {
      return data.map(fromJson).toList();
    }
    if (data is! Map) {
      throw UnsupportedError('Unsupported json value: ${data.runtimeType}');
    }

    final json = data.cast<String, dynamic>();
    if (json.containsKey(r'$rwkvType')) {
      throw UnsupportedError(
        'Legacy worker type tag "\$rwkvType" is not supported',
      );
    }
    final type = json[_typeKey] as String?;
    if (type == null) {
      return {
        for (final entry in json.entries) entry.key: fromJson(entry.value),
      };
    }

    switch (type) {
      case 'rwkv_log_level':
        return RWKVLogLevel.values.byName(_string(_value(json, 'name')));
      case 'backend':
        return Backend.fromString(_string(_value(json, 'name')));
      case 'reasoning_effort':
        return ReasoningEffort.fromName(_string(_value(json, 'name')));
      case 'stop_reason':
        return _parseStopReason(_string(_value(json, 'name')));
      case 'string_list':
        return _stringList(_value(json, 'values')) ?? const <String>[];
      case 'int_list':
        return _intList(_value(json, 'values')) ?? const <int>[];
      case 'double_list':
        return _doubleList(_value(json, 'values')) ?? const <double>[];
      case 'bool_list':
        return _boolList(_value(json, 'values')) ?? const <bool>[];
      case 'init_param':
        return InitParam(
          dynamicLibDir: _stringOrNull(_value(json, 'dynamic_lib_dir')),
          logLevel:
              fromJson(_value(json, 'log_level')) as RWKVLogLevel? ??
              RWKVLogLevel.debug,
          qnnLibDir: _stringOrNull(_value(json, 'qnn_lib_dir')),
          extra: _map(_value(json, 'extra')) ?? const {},
        );
      case 'tts_model_config':
        return TTSModelConfig(
          textNormalizers: _stringList(_value(json, 'text_normalizers')) ?? const [],
          wav2vec2ModelPath: _string(
            _value(json, 'wav2vec2_model_path'),
          ),
          biCodecTokenizerPath: _string(
            _value(json, 'bi_codec_tokenizer_path'),
          ),
          biCodecDetokenizerPath: _string(
            _value(json, 'bi_codec_detokenizer_path'),
          ),
        );
      case 'load_model_param':
        return LoadModelParam(
          modelPath: _string(_value(json, 'model_path')),
          tokenizerPath: _string(_value(json, 'tokenizer_path')),
          backend: fromJson(_value(json, 'backend')) as Backend?,
          ttsModelConfig: fromJson(_value(json, 'tts_model_config')) as TTSModelConfig?,
        );
      case 'decode_param':
        return DecodeParam(
          temperature: _double(_value(json, 'temperature')),
          topK: _int(_value(json, 'top_k')),
          topP: _double(_value(json, 'top_p')),
          presencePenalty: _double(_value(json, 'presence_penalty')),
          frequencyPenalty: _double(_value(json, 'frequency_penalty')),
          penaltyDecay: _double(_value(json, 'penalty_decay')),
          maxTokens: _int(_value(json, 'max_tokens')),
        );
      case 'generation_param':
        return GenerationParam(
          prompt: _string(_value(json, 'prompt')),
          model: _stringOrNull(_value(json, 'model')),
          maxCompletionTokens: _intOrNull(_value(json, 'max_completion_tokens')),
          reasoning: _stringOrNull(_value(json, 'reasoning')),
          stopSequence: _intList(_value(json, 'stop_sequence')),
          additional: _map(_value(json, 'additional')),
          completionStopToken: _intOrNull(_value(json, 'completion_stop_token')),
          eosToken: _stringOrNull(_value(json, 'eos_token')),
          bosToken: _stringOrNull(_value(json, 'bos_token')),
          tokenBanned: _intList(_value(json, 'token_banned')),
          returnWholeGeneratedResult: _boolOrNull(
            _value(json, 'return_whole_generated_result'),
          ),
        );
      case 'chat_message':
        return ChatMessage(
          role: _string(_value(json, 'role')),
          content: _stringOrNull(_value(json, 'content')) ?? '',
          toolCallId: _stringOrNull(_value(json, 'tool_call_id')),
          toolCalls: _list<ToolCall>(_value(json, 'tool_calls')),
        );
      case 'chat_param':
        return ChatParam(
          messages: _list<ChatMessage>(_value(json, 'messages')),
          batch: _list<ChatMessage>(_value(json, 'batch')),
          tools: _list<ToolDefinition>(_value(json, 'tools')),
          toolChoice: fromJson(_value(json, 'tool_choice')) as ToolChoice?,
          parallelToolCalls: _boolOrNull(_value(json, 'parallel_tool_calls')),
          model: _stringOrNull(_value(json, 'model')),
          reasoning: fromJson(_value(json, 'reasoning')) as ReasoningEffort?,
          additional: _map(_value(json, 'additional')),
          stopSequence: _intList(_value(json, 'stop_sequence')),
          maxTokens: _intOrNull(_value(json, 'max_tokens')),
          maxCompletionTokens: _intOrNull(_value(json, 'max_completion_tokens')),
          prompt: _stringOrNull(_value(json, 'prompt')),
          completionStopToken: _intOrNull(_value(json, 'completion_stop_token')),
          thinkingToken: _stringOrNull(_value(json, 'thinking_token')),
          eosToken: _stringOrNull(_value(json, 'eos_token')),
          bosToken: _stringOrNull(_value(json, 'bos_token')),
          tokenBanned: _intList(_value(json, 'token_banned')),
          returnWholeGeneratedResult: _boolOrNull(
            _value(json, 'return_whole_generated_result'),
          ),
          addGenerationPrompt: _boolOrNull(_value(json, 'add_generation_prompt')),
          spaceAfterRole: _boolOrNull(_value(json, 'space_after_role')),
        );
      case 'generation_response':
        return GenerationResponse(
          content: _string(_value(json, 'content')),
          reasoningContent: _stringOrNull(_value(json, 'reasoning_content')) ??
              '',
          tokenCount: _intOrNull(_value(json, 'token_count')) ?? -1,
          stopReason:
              fromJson(_value(json, 'stop_reason')) as StopReason? ??
              StopReason.none,
          choices: _stringList(_value(json, 'choices')),
          stopReasons: _list<StopReason>(_value(json, 'stop_reasons')),
          toolCalls: _list<ToolCall>(_value(json, 'tool_calls')),
          choiceToolCalls: _choiceToolCalls(_value(json, 'choice_tool_calls')),
        );
      case 'generation_state':
        return GenerationState(
          isGenerating: _bool(_value(json, 'is_generating')),
          prefillProgress: _double(_value(json, 'prefill_progress')),
          prefillSpeed: _double(_value(json, 'prefill_speed')),
          decodeSpeed: _double(_value(json, 'decode_speed')),
          timestamp: _int(_value(json, 'timestamp')),
        );
      case 'tool_function':
        return ToolFunction(
          name: _string(_value(json, 'name')),
          description: _stringOrNull(_value(json, 'description')),
          parameters: _map(_value(json, 'parameters')),
          strict: _boolOrNull(_value(json, 'strict')),
        );
      case 'tool_definition':
        return ToolDefinition.function(
          function: fromJson(_value(json, 'function')) as ToolFunction?,
        );
      case 'tool_choice':
        final mode = _stringOrNull(_value(json, 'mode'));
        if (mode == 'none') {
          return const ToolChoice.none();
        }
        if (mode == 'auto') {
          return const ToolChoice.auto();
        }
        if (mode == 'required') {
          return const ToolChoice.required();
        }
        return ToolChoice.function(_string(_value(json, 'function_name')));
      case 'tool_call_function':
        return ToolCallFunction(
          name: _stringOrNull(_value(json, 'name')),
          arguments: _stringOrNull(_value(json, 'arguments')) ?? '',
        );
      case 'tool_call':
        return ToolCall(
          index: _intOrNull(_value(json, 'index')),
          id: _stringOrNull(_value(json, 'id')),
          type: _stringOrNull(_value(json, 'type')),
          function: fromJson(_value(json, 'function')) as ToolCallFunction?,
        );
      default:
        throw UnsupportedError('Unsupported serialized type: $type');
    }
  }

  static dynamic _value(Map<String, dynamic> json, String key) => json[key];

  static List<T>? _list<T>(dynamic value) {
    final decoded = fromJson(value);
    if (decoded == null) {
      return null;
    }
    return (decoded as List).cast<T>();
  }

  static Map<String, dynamic>? _map(dynamic value) {
    final decoded = fromJson(value);
    if (decoded == null) {
      return null;
    }
    return (decoded as Map).cast<String, dynamic>();
  }

  static List<List<ToolCall>?>? _choiceToolCalls(dynamic value) {
    final decoded = fromJson(value);
    if (decoded == null) {
      return null;
    }
    return (decoded as List)
        .map((item) => item == null ? null : (item as List).cast<ToolCall>())
        .toList();
  }

  static String _string(dynamic value) => value?.toString() ?? '';

  static String? _stringOrNull(dynamic value) => value?.toString();

  static int _int(dynamic value) => _intOrNull(value) ?? 0;

  static int? _intOrNull(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString());
  }

  static double _double(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  static bool _bool(dynamic value) => value == true;

  static bool? _boolOrNull(dynamic value) => value is bool ? value : null;

  static String _stopReasonName(StopReason value) {
    return switch (value) {
      StopReason.maxTokens => 'max_tokens',
      StopReason.toolCalls => 'tool_calls',
      _ => value.name,
    };
  }

  static StopReason _parseStopReason(String value) {
    return switch (value) {
      'max_tokens' => StopReason.maxTokens,
      'tool_calls' => StopReason.toolCalls,
      'none' => StopReason.none,
      'eos' => StopReason.eos,
      'canceled' => StopReason.canceled,
      'error' => StopReason.error,
      'timeout' => StopReason.timeout,
      'unknown' => StopReason.unknown,
      _ => throw UnsupportedError('Unsupported stop reason: $value'),
    };
  }

  static List<String>? _stringList(dynamic value) {
    final decoded = fromJson(value);
    if (decoded == null) {
      return null;
    }
    return (decoded as List).map((e) => e.toString()).toList();
  }

  static List<int>? _intList(dynamic value) {
    final decoded = fromJson(value);
    if (decoded == null) {
      return null;
    }
    return (decoded as List).map(_int).toList();
  }

  static List<double>? _doubleList(dynamic value) {
    final decoded = fromJson(value);
    if (decoded == null) {
      return null;
    }
    return (decoded as List).map(_double).toList();
  }

  static List<bool>? _boolList(dynamic value) {
    final decoded = fromJson(value);
    if (decoded == null) {
      return null;
    }
    return (decoded as List).map(_bool).toList();
  }
}
