import 'dart:async';

import 'package:dio/dio.dart' hide HttpClientAdapter;
import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/bean/openai/messages_bean.dart';
import 'package:rwkv_dart/src/api/common/sse_event_transformer.dart';
import 'package:rwkv_dart/src/logger.dart';

import 'http_client.dart'
    if (dart.library.js_interop) 'package:rwkv_dart/src/web/http_client.dart'
    if (dart.library.html) 'package:rwkv_dart/src/web/http_client.dart'
    as adapter;

/// Albatross HTTP API Client
///
class AlbatrossClient implements RWKV {
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
      headers: {'Content-Type': 'application/json'},
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
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

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
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

    Response resp;
    try {
      _cancelToken = CancelToken();
      resp = await _dio.post(
        '/FIM/v1/batch-FIM',
        data: data,
        cancelToken: _cancelToken,
        options: Options(responseType: ResponseType.stream),
      );
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(text: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(sseEventTransformer(request.suffix.length));
  }

  // ==================== Translation API ====================

  /// Batch Translation
  ///
  /// Endpoint: POST /translate/v1/batch-translate
  ///
  /// Compatible with Immersive Translate.
  /// [sourceLang]: auto, zh-CN, zh-TW, en, ja, fr, de, es, ru
  /// [targetLang]: zh-CN, zh-TW, en, ja, fr, de, es, ru
  Future<TranslateResponse> translateBatch(TranslateRequest request) async {
    final data = request.toJson();
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

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

  // ==================== Chat v1 API (Batch) ====================

  /// Batch Chat Completions (v1)
  ///
  /// Endpoint: POST /v1/chat/completions
  ///
  /// Standard batch synchronous inference.
  Future<ChatResponse> chatV1(ChatRequest request) async {
    final data = _applyConfig(request).toJson();
    data['stream'] = false;
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

    final response = await _dio.post('/v1/chat/completions', data: data);

    if (response.data is Map && response.data['error'] != null) {
      final error = ErrorResponse.fromJson(response.data);
      throw Exception('Chat v1 error: ${error.error}');
    }

    return ChatResponse.fromJson(response.data);
  }

  /// Stream Chat Completions (v1)
  Stream<GenerationResponse> chatV1Stream(ChatRequest request) async* {
    final data = _applyConfig(request).toJson();
    data['stream'] = true;
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

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
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(text: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(sseEventTransformer(1));
  }

  // ==================== Chat v2 API (Continuous Batch) ====================

  /// Continuous Batch Chat (v2)
  ///
  /// Endpoint: POST /v2/chat/completions
  ///
  /// Supports dynamic scheduling, automatically loads new requests after tasks complete.
  Future<ChatResponse> chatV2(ChatRequest request) async {
    final data = _applyConfig(request).toJson();
    data['stream'] = false;
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

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
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

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
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(
          text: '',
          choices: List.filled(request.contents?.length ?? 1, ''),
          stopReason: StopReason.canceled,
        );
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(
      sseEventTransformer(request.contents?.length ?? 1),
    );
  }

  // ==================== Chat v3 API (Fast) ====================

  /// Fast Chat (v3) - Optimized for BatchSize=1
  ///
  /// Endpoint: POST /v3/chat/completions
  ///
  /// Either [contents] or [messages] must be provided.
  /// [enableThink]: Add `<think>` tags for reasoning.
  Future<ChatResponse> chatV3(ChatRequest request) async {
    final data = _applyConfig(request).toJson();
    data['stream'] = false;
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

    final response = await _dio.post('/v3/chat/completions', data: data);

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
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

    Response resp;
    try {
      logi('/v3/chat/completions');
      logi(data);

      _cancelToken = CancelToken();
      resp = await _dio.post(
        '/v3/chat/completions',
        data: data,
        cancelToken: _cancelToken,
        options: Options(responseType: ResponseType.stream),
      );
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(text: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(sseEventTransformer(1));
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
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

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
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

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
        yield GenerationResponse(text: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(sseEventTransformer(1));
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
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

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
    if (password != null && data['password'] == null) {
      data['password'] = password;
    }

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
        yield GenerationResponse(text: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
    }

    final body = resp.data as ResponseBody;
    yield* body.stream.transform(sseEventTransformer(1));
  }

  // ==================== Session Management ====================

  /// Query all session cache status
  ///
  /// Endpoint: POST /state/status
  Future<SessionStatusResponse> getSessionStatus({String? password}) async {
    final request = SessionStatusRequest(password: password ?? this.password);
    final response = await _dio.post('/state/status', data: request.toJson());

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
      password: password ?? this.password,
    );
    final response = await _dio.post('/state/delete', data: request.toJson());

    return DeleteSessionResponse.fromJson(response.data);
  }

  // ==================== RWKV Interface Implementation ====================

  @override
  Stream<GenerationResponse> chat(ChatParam param) async* {
    // Use v3 API for chat by default (optimized for BatchSize=1)
    // Convert ChatParam to ChatRequest
    final messages = <MessageBean>[];
    if (param.prompt != null && param.prompt!.trim().isNotEmpty) {
      messages.add(MessageBean(role: 'system', content: param.prompt!));
    }
    if (param.generationPrompt != null &&
        param.generationPrompt!.trim().isNotEmpty) {
      messages.add(
        MessageBean(role: 'system', content: param.generationPrompt!.trim()),
      );
    }
    for (final m in param.messages ?? []) {
      messages.add(MessageBean(role: m.role, content: m.content));
    }

    final contents = <String>[];
    for (final m in param.batch ?? []) {
      contents.add(m.content);
    }

    final batch = param.batch != null;

    final request = ChatRequest(
      messages: batch ? null : messages,
      contents: batch ? contents : null,
      maxTokens: param.maxTokens ?? _decodeParam.maxTokens,
      temperature: _decodeParam.temperature,
      topK: _decodeParam.topK,
      topP: _decodeParam.topP,
      alphaPresence: _decodeParam.presencePenalty,
      alphaFrequency: _decodeParam.frequencyPenalty,
      stopTokens: param.stopSequence?.map((e) => e.hashCode).toList(),
      stream: true,
      enableThink: param.reasoning == null
          ? (param.reasoning == null
                ? null
                : param.reasoning != ReasoningEffort.none)
          : param.reasoning != ReasoningEffort.none,
    );

    if (param.batch != null) {
      yield* chatV2Stream(request);
    } else {
      yield* chatV3Stream(request);
    }
  }

  @override
  Stream<GenerationResponse> generate(GenerationParam param) async* {
    // Use v3 API with contents format
    final request = ChatRequest(
      contents: [
        if (param.generationPrompt != null &&
            param.generationPrompt!.trim().isNotEmpty)
          '${param.generationPrompt!.trim()}\n${param.prompt}'
        else
          param.prompt,
      ],
      maxTokens:
          param.maxCompletionTokens ??
          param.maxTokens ??
          _decodeParam.maxTokens,
      temperature: _decodeParam.temperature,
      topK: _decodeParam.topK,
      topP: _decodeParam.topP,
      alphaPresence: _decodeParam.presencePenalty,
      alphaFrequency: _decodeParam.frequencyPenalty,
      stopTokens: param.stopSequence?.map((e) => e.hashCode).toList(),
      stream: true,
      enableThink: param.reasoningEffort == null
          ? null
          : param.reasoningEffort != ReasoningEffort.none,
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
  Future<dynamic> setLogLevel(RWKVLogLevel level) {
    throw UnimplementedError('setLogLevel is not supported in AlbatrossClient');
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
}
