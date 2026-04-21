import 'dart:convert';

import 'package:rwkv_dart/rwkv_dart.dart';

class WorkerMethod {
  static const init = 'init';
  static const setLogLevel = 'setLogLevel';
  static const loadModel = 'loadModel';
  static const chat = 'chat';
  static const clearState = 'clearState';
  static const generate = 'generate';
  static const release = 'release';
  static const getHtpArch = 'getHtpArch';
  static const dumpStateInfo = 'dumpStateInfo';
  static const dumpLog = 'dumpLog';
  static const getSocName = 'getSocName';
  static const loadInitialState = 'loadInitialState';
  static const textToSpeech = 'textToSpeech';
  static const setImage = 'setImage';
  static const setDecodeParam = 'setDecodeParam';
  static const getGenerationState = 'getGenerationState';
  static const generationStateStream = 'generationStateStream';
  static const stopGenerate = 'stopGenerate';
  static const getSeed = 'getSeed';
  static const setSeed = 'setSeed';
  static const setImageId = 'setImageId';
  static const runEvaluation = 'runEvaluation';
  static const cancelStream = 'cancelStream';
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
  static const _typeKey = r'$rwkvType';

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
      return {_typeKey: 'StringList', 'values': data};
    }
    if (data is List<int>) {
      return {_typeKey: 'IntList', 'values': data};
    }
    if (data is List<double>) {
      return {_typeKey: 'DoubleList', 'values': data};
    }
    if (data is List<bool>) {
      return {_typeKey: 'BoolList', 'values': data};
    }
    if (data is List) {
      return data.map(toJson).toList();
    }
    if (data is RWKVLogLevel) {
      return {_typeKey: 'RWKVLogLevel', 'name': data.name};
    }
    if (data is Backend) {
      return {_typeKey: 'Backend', 'name': data.name};
    }
    if (data is ReasoningEffort) {
      return {_typeKey: 'ReasoningEffort', 'name': data.name};
    }
    if (data is StopReason) {
      return {_typeKey: 'StopReason', 'name': data.name};
    }
    if (data is InitParam) {
      return {
        _typeKey: 'InitParam',
        'dynamicLibDir': data.dynamicLibDir,
        'logLevel': toJson(data.logLevel),
        'qnnLibDir': data.qnnLibDir,
        'extra': toJson(data.extra),
      };
    }
    if (data is TTSModelConfig) {
      return {
        _typeKey: 'TTSModelConfig',
        'textNormalizers': data.textNormalizers,
        'wav2vec2ModelPath': data.wav2vec2ModelPath,
        'biCodecTokenizerPath': data.biCodecTokenizerPath,
        'biCodecDetokenizerPath': data.biCodecDetokenizerPath,
      };
    }
    if (data is LoadModelParam) {
      return {
        _typeKey: 'LoadModelParam',
        'modelPath': data.modelPath,
        'tokenizerPath': data.tokenizerPath,
        'backend': toJson(data.backend),
        'ttsModelConfig': toJson(data.ttsModelConfig),
      };
    }
    if (data is DecodeParam) {
      return {
        _typeKey: 'DecodeParam',
        'temperature': data.temperature,
        'topK': data.topK,
        'topP': data.topP,
        'presencePenalty': data.presencePenalty,
        'frequencyPenalty': data.frequencyPenalty,
        'penaltyDecay': data.penaltyDecay,
        'maxTokens': data.maxTokens,
      };
    }
    if (data is GenerationParam) {
      return {
        _typeKey: 'GenerationParam',
        'prompt': data.prompt,
        'model': data.model,
        'maxCompletionTokens': data.maxCompletionTokens,
        'reasoning': data.reasoning,
        'stopSequence': data.stopSequence,
        'additional': toJson(data.additional),
        'completionStopToken': data.completionStopToken,
        'eosToken': data.eosToken,
        'bosToken': data.bosToken,
        'tokenBanned': data.tokenBanned,
        'returnWholeGeneratedResult': data.returnWholeGeneratedResult,
      };
    }
    if (data is ChatMessage) {
      return {
        _typeKey: 'ChatMessage',
        'role': data.role,
        'content': data.content,
        'toolCallId': data.toolCallId,
        'toolCalls': toJson(data.toolCalls),
      };
    }
    if (data is ChatParam) {
      return {
        _typeKey: 'ChatParam',
        'messages': toJson(data.messages),
        'batch': toJson(data.batch),
        'tools': toJson(data.tools),
        'toolChoice': toJson(data.toolChoice),
        'parallelToolCalls': data.parallelToolCalls,
        'model': data.model,
        'maxCompletionTokens': data.maxCompletionTokens,
        'maxTokens': data.maxTokens,
        'reasoning': toJson(data.reasoning),
        'stopSequence': data.stopSequence,
        'additional': toJson(data.additional),
        'prompt': data.prompt,
        'completionStopToken': data.completionStopToken,
        'thinkingToken': data.thinkingToken,
        'eosToken': data.eosToken,
        'bosToken': data.bosToken,
        'tokenBanned': data.tokenBanned,
        'returnWholeGeneratedResult': data.returnWholeGeneratedResult,
        'addGenerationPrompt': data.addGenerationPrompt,
        'spaceAfterRole': data.spaceAfterRole,
      };
    }
    if (data is GenerationResponse) {
      return {
        _typeKey: 'GenerationResponse',
        'content': data.content,
        'reasoningContent': data.reasoningContent,
        'tokenCount': data.tokenCount,
        'stopReason': toJson(data.stopReason),
        'choices': data.choices,
        'stopReasons': toJson(data.stopReasons),
        'toolCalls': toJson(data.toolCalls),
        'choiceToolCalls': toJson(data.choiceToolCalls),
      };
    }
    if (data is GenerationState) {
      return {
        _typeKey: 'GenerationState',
        'isGenerating': data.isGenerating,
        'prefillProgress': data.prefillProgress,
        'prefillSpeed': data.prefillSpeed,
        'decodeSpeed': data.decodeSpeed,
        'timestamp': data.timestamp,
      };
    }
    if (data is RunEvaluationParam) {
      return {
        _typeKey: 'RunEvaluationParam',
        'source': data.source,
        'target': data.target,
      };
    }
    if (data is RunEvaluationResult) {
      return {
        _typeKey: 'RunEvaluationResult',
        'corrects': data.corrects,
        'logits': data.logits,
      };
    }
    if (data is TextToSpeechParam) {
      return {
        _typeKey: 'TextToSpeechParam',
        'text': data.text,
        'outputAudioPath': data.outputAudioPath,
        'inputAudioPath': data.inputAudioPath,
        'inputAudioText': data.inputAudioText,
      };
    }
    if (data is ToolFunction) {
      return {
        _typeKey: 'ToolFunction',
        'name': data.name,
        'description': data.description,
        'parameters': toJson(data.parameters),
        'strict': data.strict,
      };
    }
    if (data is ToolDefinition) {
      return {
        _typeKey: 'ToolDefinition',
        'type': data.type,
        'function': toJson(data.function),
      };
    }
    if (data is ToolChoice) {
      return {
        _typeKey: 'ToolChoice',
        'mode': data.mode,
        'functionName': data.functionName,
      };
    }
    if (data is ToolCallFunction) {
      return {
        _typeKey: 'ToolCallFunction',
        'name': data.name,
        'arguments': data.arguments,
      };
    }
    if (data is ToolCall) {
      return {
        _typeKey: 'ToolCall',
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
    final type = json[_typeKey] as String?;
    if (type == null) {
      return {
        for (final entry in json.entries) entry.key: fromJson(entry.value),
      };
    }

    switch (type) {
      case 'RWKVLogLevel':
        return RWKVLogLevel.values.byName(_string(json['name']));
      case 'Backend':
        return Backend.fromString(_string(json['name']));
      case 'ReasoningEffort':
        return ReasoningEffort.fromName(_string(json['name']));
      case 'StopReason':
        return StopReason.values.byName(_string(json['name']));
      case 'StringList':
        return _stringList(json['values']) ?? const <String>[];
      case 'IntList':
        return _intList(json['values']) ?? const <int>[];
      case 'DoubleList':
        return _doubleList(json['values']) ?? const <double>[];
      case 'BoolList':
        return _boolList(json['values']) ?? const <bool>[];
      case 'InitParam':
        return InitParam(
          dynamicLibDir: _stringOrNull(json['dynamicLibDir']),
          logLevel:
              fromJson(json['logLevel']) as RWKVLogLevel? ?? RWKVLogLevel.debug,
          qnnLibDir: _stringOrNull(json['qnnLibDir']),
          extra: _map(json['extra']) ?? const {},
        );
      case 'TTSModelConfig':
        return TTSModelConfig(
          textNormalizers: _stringList(json['textNormalizers']) ?? const [],
          wav2vec2ModelPath: _string(json['wav2vec2ModelPath']),
          biCodecTokenizerPath: _string(json['biCodecTokenizerPath']),
          biCodecDetokenizerPath: _string(json['biCodecDetokenizerPath']),
        );
      case 'LoadModelParam':
        return LoadModelParam(
          modelPath: _string(json['modelPath']),
          tokenizerPath: _string(json['tokenizerPath']),
          backend: fromJson(json['backend']) as Backend?,
          ttsModelConfig: fromJson(json['ttsModelConfig']) as TTSModelConfig?,
        );
      case 'DecodeParam':
        return DecodeParam(
          temperature: _double(json['temperature']),
          topK: _int(json['topK']),
          topP: _double(json['topP']),
          presencePenalty: _double(json['presencePenalty']),
          frequencyPenalty: _double(json['frequencyPenalty']),
          penaltyDecay: _double(json['penaltyDecay']),
          maxTokens: _int(json['maxTokens']),
        );
      case 'GenerationParam':
        return GenerationParam(
          prompt: _string(json['prompt']),
          model: _stringOrNull(json['model']),
          maxCompletionTokens: _intOrNull(json['maxCompletionTokens']),
          reasoning: _stringOrNull(json['reasoning']),
          stopSequence: _intList(json['stopSequence']),
          additional: _map(json['additional']),
          completionStopToken: _intOrNull(json['completionStopToken']),
          eosToken: _stringOrNull(json['eosToken']),
          bosToken: _stringOrNull(json['bosToken']),
          tokenBanned: _intList(json['tokenBanned']),
          returnWholeGeneratedResult: _boolOrNull(
            json['returnWholeGeneratedResult'],
          ),
        );
      case 'ChatMessage':
        return ChatMessage(
          role: _string(json['role']),
          content: _stringOrNull(json['content']) ?? '',
          toolCallId: _stringOrNull(json['toolCallId']),
          toolCalls: _list<ToolCall>(json['toolCalls']),
        );
      case 'ChatParam':
        return ChatParam(
          messages: _list<ChatMessage>(json['messages']),
          batch: _list<ChatMessage>(json['batch']),
          tools: _list<ToolDefinition>(json['tools']),
          toolChoice: fromJson(json['toolChoice']) as ToolChoice?,
          parallelToolCalls: _boolOrNull(json['parallelToolCalls']),
          model: _stringOrNull(json['model']),
          reasoning: fromJson(json['reasoning']) as ReasoningEffort?,
          additional: _map(json['additional']),
          stopSequence: _intList(json['stopSequence']),
          maxTokens: _intOrNull(json['maxTokens']),
          maxCompletionTokens: _intOrNull(json['maxCompletionTokens']),
          prompt: _stringOrNull(json['prompt']),
          completionStopToken: _intOrNull(json['completionStopToken']),
          thinkingToken: _stringOrNull(json['thinkingToken']),
          eosToken: _stringOrNull(json['eosToken']),
          bosToken: _stringOrNull(json['bosToken']),
          tokenBanned: _intList(json['tokenBanned']),
          returnWholeGeneratedResult: _boolOrNull(
            json['returnWholeGeneratedResult'],
          ),
          addGenerationPrompt: _boolOrNull(json['addGenerationPrompt']),
          spaceAfterRole: _boolOrNull(json['spaceAfterRole']),
        );
      case 'GenerationResponse':
        return GenerationResponse(
          content: _string(json['content']),
          reasoningContent: _stringOrNull(json['reasoningContent']) ?? '',
          tokenCount: _intOrNull(json['tokenCount']) ?? -1,
          stopReason:
              fromJson(json['stopReason']) as StopReason? ?? StopReason.none,
          choices: _stringList(json['choices']),
          stopReasons: _list<StopReason>(json['stopReasons']),
          toolCalls: _list<ToolCall>(json['toolCalls']),
          choiceToolCalls: _choiceToolCalls(json['choiceToolCalls']),
        );
      case 'GenerationState':
        return GenerationState(
          isGenerating: _bool(json['isGenerating']),
          prefillProgress: _double(json['prefillProgress']),
          prefillSpeed: _double(json['prefillSpeed']),
          decodeSpeed: _double(json['decodeSpeed']),
          timestamp: _int(json['timestamp']),
        );
      case 'RunEvaluationParam':
        return RunEvaluationParam(
          source: _string(json['source']),
          target: _string(json['target']),
        );
      case 'RunEvaluationResult':
        return RunEvaluationResult(
          corrects: _boolList(json['corrects']) ?? const [],
          logits: _doubleList(json['logits']) ?? const [],
        );
      case 'TextToSpeechParam':
        return TextToSpeechParam(
          text: _string(json['text']),
          outputAudioPath: _string(json['outputAudioPath']),
          inputAudioPath: _string(json['inputAudioPath']),
          inputAudioText: _stringOrNull(json['inputAudioText']),
        );
      case 'ToolFunction':
        return ToolFunction(
          name: _string(json['name']),
          description: _stringOrNull(json['description']),
          parameters: _map(json['parameters']),
          strict: _boolOrNull(json['strict']),
        );
      case 'ToolDefinition':
        return ToolDefinition.function(
          function: fromJson(json['function']) as ToolFunction?,
        );
      case 'ToolChoice':
        final mode = _stringOrNull(json['mode']);
        if (mode == 'none') {
          return const ToolChoice.none();
        }
        if (mode == 'auto') {
          return const ToolChoice.auto();
        }
        if (mode == 'required') {
          return const ToolChoice.required();
        }
        return ToolChoice.function(_string(json['functionName']));
      case 'ToolCallFunction':
        return ToolCallFunction(
          name: _stringOrNull(json['name']),
          arguments: _stringOrNull(json['arguments']) ?? '',
        );
      case 'ToolCall':
        return ToolCall(
          index: _intOrNull(json['index']),
          id: _stringOrNull(json['id']),
          type: _stringOrNull(json['type']),
          function: fromJson(json['function']) as ToolCallFunction?,
        );
      default:
        throw UnsupportedError('Unsupported serialized type: $type');
    }
  }

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
