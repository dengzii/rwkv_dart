import 'dart:async';

import 'package:dio/dio.dart' hide HttpClientAdapter;
import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/common/errors.dart';
import 'package:rwkv_dart/src/api/common/sse_event_transformer_v1.dart';
import 'package:rwkv_dart/src/logger.dart';

import 'http_client.dart'
    if (dart.library.js_interop) 'package:rwkv_dart/src/web/http_client.dart'
    if (dart.library.html) 'package:rwkv_dart/src/web/http_client.dart'
    as adapter;

/// Albatross HTTP API Client
///
class AlbatrossClient extends RWKV {
  final String baseUrl;
  final String? password;

  DecodeParam _decodeParam = DecodeParam.initial();

  CancelToken? _cancelToken;

  late final _dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 300),
      sendTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        if (password != null && password!.isNotEmpty)
          "Authorization": 'Bearer $password',
      },
    ),
  );

  AlbatrossClient(this.baseUrl, {this.password}) {
    _dio.httpClientAdapter = adapter.createAdapter();
  }

  ChatRequest _applyConfig(ChatRequest request) {
    return ChatRequest(
      model: request.model,
      contents: request.contents,
      prefix: request.prefix,
      suffix: request.suffix,
      messages: request.messages,
      maxTokens: request.maxTokens ?? _decodeParam.maxTokens,
      temperature: request.temperature ?? _decodeParam.temperature,
      topK: request.topK ?? _decodeParam.topK,
      topP: request.topP ?? _decodeParam.topP,
      noise: request.noise,
      alphaPresence: request.alphaPresence ?? _decodeParam.presencePenalty,
      alphaFrequency: request.alphaFrequency ?? _decodeParam.frequencyPenalty,
      alphaDecay: request.alphaDecay ?? _decodeParam.penaltyDecay,
      stopTokens: request.stopTokens,
      stream: request.stream,
      chunkSize: request.chunkSize,
      padZero: request.padZero,
      enableThink: request.enableThink,
      sessionId: request.sessionId,
      dialogueIdx: request.dialogueIdx,
      password: request.password,
    );
  }

  // ==================== FIM API ====================

  /// Fill-In-Middle (FIM) - Code/文本补全
  ///
  /// Endpoint: POST /FIM/v1/batch-FIM
  ///
  /// [prefix] and [suffix] must have the same length.
  Future<FimResponse> fimBatch(FimRequest request) async {
    final data = request.toJson();

    final response = await _dio.post('/FIM/v1/batch-FIM', data: data);

    if (response.data is Map && response.data['error'] != null) {
      final error = ErrorResponse.fromJson(response.data);
      throw Exception('FIM error: ${error.error}');
    }

    return FimResponse.fromJson(response.data);
  }

  /// Stream FIM completion
  Stream<GenerationResponse> fimBatchStream(FimRequest request) async* {
    final data = request.toJson();
    data['stream'] = true;

    Response resp;
    try {
      logi('/FIM/v1/batch-FIM');
      logi(data);

      _cancelToken = CancelToken();
      resp = await _dio.post(
        '/FIM/v1/batch-FIM',
        data: data,
        cancelToken: _cancelToken,
        options: Options(responseType: ResponseType.stream),
      );
    } catch (e) {
      await checkError(e);
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(content: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(sseEventTransformerV1(request.suffix.length));
  }

  Future<TranslateResponse> translateBatch(TranslateRequest request) async {
    final data = request.toJson();

    final response = await _dio.post(
      '/translate/v1/batch-translate',
      data: data,
    );

    if (response.data is Map && response.data['error'] != null) {
      final error = ErrorResponse.fromJson(response.data);
      throw Exception('Translate error: ${error.error}');
    }

    return TranslateResponse.fromJson(response.data);
  }

  /// Stream Chat Completions (v1)
  Stream<GenerationResponse> chatV1Stream(ChatRequest request) async* {
    final data = _applyConfig(request).toJson();
    data['stream'] = true;

    Response resp;
    try {
      _cancelToken = CancelToken();
      resp = await _dio.post(
        '/v1/chat/completions',
        data: data,
        cancelToken: _cancelToken,
        options: Options(responseType: ResponseType.stream),
      );
    } catch (e) {
      await checkError(e);
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(content: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(
      sseEventTransformerV1(1, fixThinkStartTag: true),
    );
  }

  Future<ChatResponse> chatV2(ChatRequest request) async {
    final data = _applyConfig(request).toJson();
    data['stream'] = false;

    final response = await _dio.post('/v2/chat/completions', data: data);

    if (response.data is Map && response.data['error'] != null) {
      final error = ErrorResponse.fromJson(response.data);
      throw Exception('Chat v2 error: ${error.error}');
    }

    return ChatResponse.fromJson(response.data);
  }

  /// Stream Continuous Batch Chat (v2)
  Stream<GenerationResponse> chatV2Stream(ChatRequest request) async* {
    final r = ChatRequest(
      model: request.model,
      contents: request.contents,
      stopTokens: request.stopTokens,
      temperature: request.temperature ?? _decodeParam.temperature,
      topK: request.topK ?? _decodeParam.topK,
      topP: request.topP ?? _decodeParam.topP,
      maxTokens: request.maxTokens ?? _decodeParam.maxTokens,
      alphaDecay: request.alphaDecay ?? _decodeParam.penaltyDecay,
      alphaPresence: request.alphaPresence ?? _decodeParam.presencePenalty,
      alphaFrequency: request.alphaFrequency ?? _decodeParam.frequencyPenalty,
      padZero: false,
      stream: true,
    );

    final data = r.toJson();
    data['stream'] = true;

    logi('request /v2/chat/completions');
    logi(data);

    Response resp;
    try {
      _cancelToken = CancelToken();
      resp = await _dio.post(
        '/v2/chat/completions',
        data: data,
        cancelToken: _cancelToken,
        options: Options(responseType: ResponseType.stream),
      );
    } catch (e) {
      checkError(e);
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(
          content: '',
          choices: List.filled(request.contents?.length ?? 1, ''),
          stopReason: StopReason.canceled,
        );
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(
      sseEventTransformerV1(
        request.contents?.length ?? 1,
        fixThinkStartTag: true,
      ),
    );
  }

  // ==================== Chat v3 API (Fast) ====================
  Future<ChatResponse> chatV3(ChatRequest request) async {
    final data = _applyConfig(request).toJson();
    data['stream'] = false;

    final response = await _dio.post('/v1/chat/completions', data: data);

    if (response.data is Map && response.data['error'] != null) {
      final error = ErrorResponse.fromJson(response.data);
      throw Exception('Chat v3 error: ${error.error}');
    }

    return ChatResponse.fromJson(response.data);
  }

  /// Stream Fast Chat (v3)
  Stream<GenerationResponse> chatV3Stream(ChatRequest request) async* {
    final data = _applyConfig(request).toJson();
    data['stream'] = true;

    Response resp;
    try {
      logi('/v1/chat/completions');
      logi(data);

      _cancelToken = CancelToken();
      resp = await _dio.post(
        '/v1/chat/completions',
        data: data,
        cancelToken: _cancelToken,
        options: Options(responseType: ResponseType.stream),
      );
    } catch (e) {
      await checkError(e);
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(content: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(
      sseEventTransformerV1(1, fixThinkStartTag: true),
    );
  }

  // ==================== State Chat API ====================

  /// Chat with Session State Caching
  ///
  /// Endpoint: POST /state/chat/completions
  ///
  /// Limitation: Only supports BatchSize = 1
  /// [sessionId]: Unique session identifier for conversation memory.
  Future<ChatResponse> chatWithState(ChatRequest request) async {
    final data = _applyConfig(request).toJson();
    data['stream'] = false;

    final response = await _dio.post('/state/chat/completions', data: data);

    if (response.data is Map && response.data['error'] != null) {
      final error = ErrorResponse.fromJson(response.data);
      throw Exception('State chat error: ${error.error}');
    }

    return ChatResponse.fromJson(response.data);
  }

  /// Stream Chat with Session State
  Stream<GenerationResponse> chatWithStateStream(ChatRequest request) async* {
    final data = _applyConfig(request).toJson();
    data['stream'] = true;

    Response resp;
    try {
      _cancelToken = CancelToken();
      resp = await _dio.post(
        '/state/chat/completions',
        data: data,
        cancelToken: _cancelToken,
        options: Options(responseType: ResponseType.stream),
      );
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(content: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(
      sseEventTransformerV1(1, fixThinkStartTag: true),
    );
  }

  // ==================== Multi-State API ====================

  /// Multi-branch Stateful Chat
  ///
  /// Endpoint: POST /multi_state/chat/completions
  ///
  /// Requires [sessionId], [dialogueIdx], and single prompt in [contents].
  Future<ChatResponse> chatBatchState(ChatRequest request) async {
    final data = _applyConfig(request).toJson();
    data['stream'] = false;

    final response = await _dio.post(
      '/multi_state/chat/completions',
      data: data,
    );

    if (response.data is Map && response.data['error'] != null) {
      final error = ErrorResponse.fromJson(response.data);
      throw Exception('Multi-state chat error: ${error.error}');
    }

    return ChatResponse.fromJson(response.data);
  }

  /// Stream Multi-branch Stateful Chat
  Stream<GenerationResponse> chatBatchStateStream(ChatRequest request) async* {
    final data = _applyConfig(request).toJson();
    data['stream'] = true;

    Response resp;
    try {
      _cancelToken = CancelToken();
      resp = await _dio.post(
        '/multi_state/chat/completions',
        data: data,
        cancelToken: _cancelToken,
        options: Options(responseType: ResponseType.stream),
      );
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(content: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(sseEventTransformerV1(1));
  }

  // ==================== Session Management ====================

  /// Query all session cache status
  ///
  /// Endpoint: POST /state/status
  Future<SessionStatusResponse> getSessionStatus() async {
    final response = await _dio.get('/state/status');

    if (response.data is Map && response.data['error'] != null) {
      final error = ErrorResponse.fromJson(response.data);
      throw Exception('Session status error: ${error.error}');
    }

    return SessionStatusResponse.fromJson(response.data);
  }

  /// Delete specified session cache
  ///
  /// Endpoint: POST /state/delete
  Future<DeleteSessionResponse> deleteSession(
    String sessionId, {
    bool deletePrefix = false,
    String? password,
  }) async {
    final request = DeleteSessionRequest(
      sessionId: sessionId,
      deletePrefix: deletePrefix,
    );
    final response = await _dio.post('/state/delete', data: request.toJson());

    return DeleteSessionResponse.fromJson(response.data);
  }

  // ==================== RWKV Interface Implementation ====================

  @override
  Stream<GenerationResponse> chat(ChatParam param) async* {
    yield* chatOpenAi(param);
  }

  @override
  Stream<GenerationResponse> generate(GenerationParam param) async* {
    // Use v3 API with contents format
    final request = ChatRequest(
      contents: [param.prompt],
      maxTokens: param.maxCompletionTokens ?? _decodeParam.maxTokens,
      temperature: _decodeParam.temperature,
      topK: _decodeParam.topK,
      topP: _decodeParam.topP,
      alphaPresence: _decodeParam.presencePenalty,
      alphaFrequency: _decodeParam.frequencyPenalty,
      stopTokens: param.stopSequence?.toList(),
      stream: true,
    );

    yield* chatV3Stream(request);
  }

  @override
  Future<dynamic> init([InitParam? param]) async {
    // HTTP client doesn't need initialization
    return null;
  }

  @override
  Future<int> loadModel(LoadModelParam param) async {
    // HTTP client doesn't load models locally
    return 0;
  }

  @override
  Future<dynamic> release() async {
    _cancelToken?.cancel();
    _cancelToken = null;
    return null;
  }

  @override
  Future<dynamic> stopGenerate() async {
    _cancelToken?.cancel();
    _cancelToken = null;
    return null;
  }

  @override
  Future<dynamic> setDecodeParam(DecodeParam param) async {
    _decodeParam = param;
    return null;
  }

  // ==================== Unsupported RWKV Methods ====================

  @override
  Future<dynamic> clearState() async {
    // Not applicable for HTTP client
    return null;
  }

  @override
  Future<String> dumpLog() {
    throw UnimplementedError('dumpLog is not supported in AlbatrossClient');
  }

  @override
  Future<String> dumpStateInfo() {
    throw UnimplementedError(
      'dumpStateInfo is not supported in AlbatrossClient',
    );
  }

  @override
  Stream<GenerationState> generationStateStream() async* {
    // Not applicable for HTTP client
  }

  @override
  Future<GenerationState> getGenerationState() async {
    return GenerationState.initial();
  }

  @override
  Future<String> getHtpArch() {
    throw UnimplementedError('getHtpArch is not supported in AlbatrossClient');
  }

  @override
  Future<int> getSeed() {
    throw UnimplementedError('getSeed is not supported in AlbatrossClient');
  }

  @override
  Future<String> getSocName() {
    throw UnimplementedError('getSocName is not supported in AlbatrossClient');
  }

  @override
  Future<dynamic> loadInitialState(String statePath) {
    throw UnimplementedError(
      'loadInitialState is not supported in AlbatrossClient',
    );
  }

  @override
  Future<RunEvaluationResult> runEvaluation(RunEvaluationParam param) {
    throw UnimplementedError(
      'runEvaluation is not supported in AlbatrossClient',
    );
  }

  @override
  Future<dynamic> setImage(String path) {
    throw UnimplementedError('setImage is not supported in AlbatrossClient');
  }

  @override
  Future<dynamic> setImageId(String id) {
    throw UnimplementedError('setImageId is not supported in AlbatrossClient');
  }

  @override
  Future<dynamic> setSeed(int seed) {
    throw UnimplementedError('setSeed is not supported in AlbatrossClient');
  }

  @override
  Stream<List<double>> textToSpeech(TextToSpeechParam param) {
    throw UnimplementedError(
      'textToSpeech is not supported in AlbatrossClient',
    );
  }

  Stream<GenerationResponse> chatOpenAi(ChatParam param) async* {
    final history = param.messages!;
    final reasoning = param.reasoning?.name ?? ReasoningEffort.none.name;
    final enableThinking = reasoning != 'none';
    final path = '/openai/v1/chat/completions';
    final data = <String, dynamic>{
      ...?param.additional,
      'model': param.model,
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

      if (enableThinking) 'reasoning_effort': reasoning,
      if (param.toolChoice != null) 'tool_choice': param.toolChoice!.toJson(),
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
    } catch (e) {
      await checkError(e);
      if (e is DioException) {
        rethrow;
      }
      throw 'request failed';
    }
    final body = resp.data as ResponseBody;

    try {
      final transformer = sseEventTransformerV1(param.batch?.length);
      yield* body.stream.transform(transformer);
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(content: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    } finally {
      _cancelToken = null;
    }
  }

  Map<String, dynamic> _serializeChatCompletionMessage(ChatMessage message) {
    final hasToolCalls = message.toolCalls?.isNotEmpty ?? false;
    return {
      'role': message.role,
      if (message.content.isNotEmpty || !hasToolCalls)
        'content': message.content,
      if (message.toolCallId != null && message.toolCallId!.isNotEmpty)
        'tool_call_id': message.toolCallId,
      if (hasToolCalls)
        'tool_calls': message.toolCalls!.map((e) => e.toJson()).toList(),
    };
  }
}
