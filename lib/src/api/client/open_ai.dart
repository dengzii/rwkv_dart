import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart' hide HttpClientAdapter;
import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/bean/openai/openai_model_bean.dart';
import 'package:rwkv_dart/src/api/common/errors.dart';
import 'package:rwkv_dart/src/api/common/sse_event_transformer_v1.dart';
import 'package:rwkv_dart/src/api/common/sse_event_transformer_v2.dart';
import 'package:rwkv_dart/src/logger.dart';

import 'http_client.dart'
    if (dart.library.js_interop) 'package:rwkv_dart/src/web/http_client.dart'
    if (dart.library.html) 'package:rwkv_dart/src/web/http_client.dart'
    as adapter;

Map<String, dynamic> _serializeChatCompletionMessage(ChatMessage message) {
  final hasToolCalls = message.toolCalls?.isNotEmpty ?? false;
  return {
    'role': message.role,
    if (message.content.isNotEmpty || !hasToolCalls) 'content': message.content,
    if (message.toolCallId != null && message.toolCallId!.isNotEmpty)
      'tool_call_id': message.toolCallId,
    if (hasToolCalls)
      'tool_calls': message.toolCalls!.map((e) => e.toJson()).toList(),
  };
}

Map<String, dynamic> _serializeResponsesTextMessage(
  String role,
  String content,
) {
  final itemType = role == 'assistant' ? 'output_text' : 'input_text';
  return {
    'type': 'message',
    'role': role,
    'content': [
      {'type': itemType, 'text': content},
    ],
  };
}

Map<String, dynamic> _serializeResponsesTool(ToolDefinition tool) {
  if (tool.type != 'function' || tool.function == null) {
    return tool.toJson();
  }

  final function = tool.function!;
  return {
    'type': 'function',
    'name': function.name,
    if (function.description != null) 'description': function.description,
    if (function.parameters != null) 'parameters': function.parameters,
    if (function.strict != null) 'strict': function.strict,
  };
}

dynamic _serializeResponsesToolChoice(ToolChoice choice) {
  if (choice.mode != null) {
    return choice.mode;
  }
  return {
    'type': 'function',
    if (choice.functionName != null) 'name': choice.functionName,
  };
}

Map<String, dynamic> _serializeResponsesFunctionCall(ToolCall toolCall) {
  final callId = toolCall.id;
  return {
    'type': 'function_call',
    if (callId != null && callId.isNotEmpty) 'call_id': callId,
    if (callId != null && callId.isNotEmpty) 'id': callId,
    if (toolCall.function?.name != null) 'name': toolCall.function!.name,
    'arguments': toolCall.function?.arguments ?? '',
    'status': 'completed',
  };
}

Iterable<Map<String, dynamic>> _serializeResponsesMessage(
  ChatMessage message,
) sync* {
  final hasToolCalls = message.toolCalls?.isNotEmpty ?? false;

  if (message.role == 'tool') {
    yield {
      'type': 'function_call_output',
      if (message.toolCallId != null && message.toolCallId!.isNotEmpty)
        'call_id': message.toolCallId,
      'output': message.content,
    };
    return;
  }

  if (message.content.isNotEmpty || !hasToolCalls) {
    yield _serializeResponsesTextMessage(message.role, message.content);
  }

  if (message.role == 'assistant' && hasToolCalls) {
    for (final toolCall in message.toolCalls!) {
      yield _serializeResponsesFunctionCall(toolCall);
    }
  }
}

List<Map<String, dynamic>> _serializeResponsesInput(
  List<ChatMessage> history, {
  String? prompt,
}) {
  final input = <Map<String, dynamic>>[];
  if (prompt != null && prompt.trim().isNotEmpty) {
    input.add(_serializeResponsesTextMessage('system', prompt.trim()));
  }
  for (final message in history) {
    input.addAll(_serializeResponsesMessage(message));
  }
  return input;
}

class OpenAiApiClient extends RWKV {
  final String url;
  final String apiKey;
  final OpenAiApiVersion apiVersion;

  DecodeParam _decodeParam = DecodeParam.initial();
  final GenerationState _generationState = GenerationState.initial();

  final _controllerState = StreamController<GenerationState>.broadcast();

  CancelToken? _cancelToken;

  late final _dio = Dio(
    BaseOptions(
      baseUrl: url,
      connectTimeout: const Duration(minutes: 3),
      receiveTimeout: const Duration(minutes: 3),
      sendTimeout: const Duration(minutes: 3),
      headers: {'Authorization': 'Bearer $apiKey'},
    ),
  )..httpClientAdapter = adapter.createAdapter();

  OpenAiApiClient(
    this.url, {
    this.apiKey = '',
    this.apiVersion = OpenAiApiVersion.chatCompletions,
  });

  Future getModelList() async {
    try {
      final response = await _dio.get('/v1/models');
      return response.data;
    } catch (e) {
      checkError(e);
      rethrow;
    }
  }

  @override
  Stream<GenerationResponse> chat(ChatParam param) async* {
    if (param.model == null || param.model!.isEmpty) {
      throw 'param.model is null or empty';
    }

    final history = param.messages!;
    final reasoning = param.reasoning?.name ?? ReasoningEffort.none.name;
    final enableThinking = reasoning != 'none';
    final path = apiVersion == OpenAiApiVersion.responses
        ? '/v1/responses'
        : '/v1/chat/completions';
    final data = apiVersion == OpenAiApiVersion.responses
        ? <String, dynamic>{
            ...?param.additional,
            'model': param.model!,
            'stream': true,
            'input': _serializeResponsesInput(history, prompt: param.prompt),
            'max_output_tokens':
                param.maxCompletionTokens ??
                param.maxTokens ??
                _decodeParam.maxTokens,
            'temperature': _decodeParam.temperature,
            'top_p': _decodeParam.topP,
            if (enableThinking)
              'reasoning': <String, dynamic>{'effort': reasoning},
            if (param.toolChoice != null)
              'tool_choice': _serializeResponsesToolChoice(param.toolChoice!),
            if (param.parallelToolCalls != null)
              'parallel_tool_calls': param.parallelToolCalls,
            if (param.tools != null && param.tools!.isNotEmpty)
              'tools': param.tools!.map(_serializeResponsesTool).toList(),
          }
        : <String, dynamic>{
            ...?param.additional,
            'model': param.model!,
            'stream': true,
            'max_tokens':
                param.maxCompletionTokens ??
                param.maxTokens ??
                _decodeParam.maxTokens,
            'temperature': _decodeParam.temperature,
            'top_p': _decodeParam.topP,
            'frequency_penalty': _decodeParam.frequencyPenalty,
            'presence_penalty': _decodeParam.presencePenalty,
            'stop': param.stopSequence,
            'penalty_decay': _decodeParam.penaltyDecay,

            /// Non-standard parameters
            if (enableThinking) 'enable_thinking': enableThinking,
            if (enableThinking) 'reasoning_effort': reasoning,
            if (param.toolChoice != null)
              'tool_choice': param.toolChoice!.toJson(),
            if (param.parallelToolCalls != null)
              'parallel_tool_calls': param.parallelToolCalls,
            'messages': [
              if (param.prompt != null && param.prompt!.trim().isNotEmpty)
                _serializeChatCompletionMessage(
                  ChatMessage(role: 'system', content: param.prompt!.trim()),
                ),
              for (final msg in history) _serializeChatCompletionMessage(msg),
            ],
            if (param.tools != null && param.tools!.isNotEmpty)
              'tools': param.tools!.map((e) => e.toJson()).toList(),
          };

    logd(path);
    logi(data);

    Response resp;
    try {
      _controllerState.add(_generationState.copyWith(isGenerating: true));
      _cancelToken = CancelToken();
      resp = await _dio.post(
        path,
        data: data,
        cancelToken: _cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Content-Type': 'application/json'},
        ),
      );
    } catch (e, s) {
      checkError(e);
      if (e is DioException) {
        throw "${e.type} ${e.response?.statusCode}\n$s";
      }
      throw 'request failed';
    }
    final body = resp.data as ResponseBody;

    try {
      final transformer = apiVersion == OpenAiApiVersion.responses
          ? sseEventTransformerV2(param.batch?.length)
          : sseEventTransformerV1(param.batch?.length);
      yield* body.stream.transform(transformer);
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(text: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    } finally {
      _controllerState.add(_generationState.copyWith(isGenerating: false));
      _cancelToken = null;
    }
  }

  @override
  Stream<GenerationResponse> generate(GenerationParam param) async* {
    final path = apiVersion == OpenAiApiVersion.responses
        ? '/v1/responses'
        : '/v1/completions';
    final enableThinking =
        param.reasoning != null &&
        param.reasoning!.isNotEmpty &&
        param.reasoning != ReasoningEffort.none.name;
    final data = apiVersion == OpenAiApiVersion.responses
        ? <String, dynamic>{
            ...?param.additional,
            'model': param.model!,
            'stream': true,
            'input': param.prompt,
            'max_output_tokens':
                param.maxCompletionTokens ?? _decodeParam.maxTokens,
            'temperature': _decodeParam.temperature,
            'top_p': _decodeParam.topP,
            if (enableThinking)
              'reasoning': <String, dynamic>{'effort': param.reasoning},
          }
        : <String, dynamic>{
            ...?param.additional,
            'model': param.model!,
            'stream': true,
            'seed': null,
            'max_tokens': param.maxCompletionTokens ?? _decodeParam.maxTokens,
            'temperature': _decodeParam.temperature,
            'top_p': _decodeParam.topP,
            'frequency_penalty': _decodeParam.frequencyPenalty,
            'presence_penalty': _decodeParam.presencePenalty,
            'stop': param.stopSequence,
            'penalty_decay': _decodeParam.penaltyDecay,
            'prompt': param.prompt,
          };
    Response resp;
    try {
      _controllerState.add(_generationState.copyWith(isGenerating: true));
      _cancelToken = CancelToken();
      resp = await _dio.post(
        path,
        cancelToken: _cancelToken,
        data: data,
        options: Options(
          responseType: ResponseType.stream,
          persistentConnection: true,
          headers: {'Content-Type': 'application/json'},
        ),
      );
    } catch (e, s) {
      checkError(e);
      _cancelToken = null;
      _controllerState.add(_generationState.copyWith(isGenerating: false));
      if (e is DioException) {
        throw "${e.type}, $s";
      }
      throw 'request failed';
    }

    final body = resp.data as ResponseBody;

    try {
      final transformer = apiVersion == OpenAiApiVersion.responses
          ? sseEventTransformerV2(1)
          : sseEventTransformerV1(1);
      yield* body.stream.transform(transformer);
    } catch (e) {
      checkError(e);
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(text: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    } finally {
      _controllerState.add(_generationState.copyWith(isGenerating: false));
      _cancelToken = null;
    }
  }

  @override
  Future<dynamic> clearState() async {
    //
  }

  @override
  Future<String> dumpLog() {
    throw UnimplementedError();
  }

  @override
  Future<String> dumpStateInfo() {
    throw UnimplementedError();
  }

  @override
  Stream<GenerationState> generationStateStream() => _controllerState.stream;

  @override
  Future<GenerationState> getGenerationState() async => _generationState;

  @override
  Future<String> getHtpArch() {
    throw UnimplementedError();
  }

  @override
  Future<int> getSeed() {
    throw UnimplementedError();
  }

  @override
  Future<String> getSocName() {
    throw UnimplementedError();
  }

  @override
  Future<List<OpenaiModelBean>> init([InitParam? param]) async {
    final resp = await _dio.get('/v1/models');
    if (resp.statusCode != 200) {
      throw 'request failed, HTTP ${resp.statusCode}';
    }
    final body = resp.data['data'] as Iterable;
    return body.map((m) => OpenaiModelBean.fromJson(m)).toList();
  }

  @override
  Future<dynamic> loadInitialState(String statePath) {
    throw UnimplementedError();
  }

  @override
  Future<int> loadModel(LoadModelParam param) async {
    return 0;
  }

  @override
  Future<dynamic> release() {
    throw UnimplementedError();
  }

  @override
  Future<RunEvaluationResult> runEvaluation(RunEvaluationParam param) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> setDecodeParam(DecodeParam param) async {
    _decodeParam = param;
  }

  @override
  Future<dynamic> setImage(String path) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> setImageId(String id) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> setSeed(int seed) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> stopGenerate() async {
    _cancelToken?.cancel();
    _cancelToken = null;
  }

  @override
  Stream<List<double>> textToSpeech(TextToSpeechParam param) {
    throw UnimplementedError();
  }
}

StreamTransformer<Uint8List, String> unit8ListToString =
    StreamTransformer.fromHandlers(
      handleData: (data, sink) {
        sink.add(utf8.decode(data));
      },
    );
