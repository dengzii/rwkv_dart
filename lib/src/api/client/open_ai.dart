import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart' hide HttpClientAdapter;
import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/bean/openai/openai_model_bean.dart';
import 'package:rwkv_dart/src/api/common/errors.dart';
import 'package:rwkv_dart/src/api/common/sse_event_transformer.dart';
import 'package:rwkv_dart/src/logger.dart';

import 'http_client.dart'
    if (dart.library.js_interop) 'package:rwkv_dart/src/web/http_client.dart'
    if (dart.library.html) 'package:rwkv_dart/src/web/http_client.dart'
    as adapter;

class OpenAiApiClient implements RWKV {
  final String url;
  final String apiKey;

  GenerationConfig _config = GenerationConfig.initial();
  DecodeParam _decodeParam = DecodeParam.initial();
  final GenerationState _generationState = GenerationState.initial();

  final _controllerState = StreamController<GenerationState>.broadcast();

  CancelToken? _cancelToken;

  late final _dio = Dio(
    BaseOptions(
      baseUrl: '',
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
    ),
  );

  OpenAiApiClient(this.url, {this.apiKey = ''}) {
    _dio.options.baseUrl = url;
    if (apiKey.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $apiKey';
    }
    _dio.httpClientAdapter = adapter.createAdapter();
  }

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
    final path = '/v1/chat/completions';

    if (param.model == null || param.model!.isEmpty) {
      throw 'param.model is null or empty';
    }

    final history = param.messages!;

    final reasoning = param.reasoning?.name ?? _config.reasoningEffort.name;
    final enableThinking = reasoning != 'none';

    final data = {
      'model': param.model!,
      'stream': true,
      'max_tokens': param.maxTokens ?? _decodeParam.maxTokens,
      'temperature': _decodeParam.temperature,
      'top_p': _decodeParam.topP,
      'frequency_penalty': _decodeParam.frequencyPenalty,
      'presence_penalty': _decodeParam.presencePenalty,
      'stop': param.stopSequence,
      'penalty_decay': _decodeParam.penaltyDecay,

      /// Non-standard parameters
      if (enableThinking) 'enable_thinking': enableThinking,

      if (enableThinking) 'reasoning_effort': reasoning,
      'messages': [
        if (param.systemPrompt != null && param.systemPrompt!.trim().isNotEmpty)
          {'role': 'system', 'content': param.systemPrompt!.trim()},
        if (_config.prompt.isNotEmpty)
          {'role': 'system', 'content': _config.prompt},
        for (final msg in history) {'role': msg.role, 'content': msg.content},
      ],
    };

    logv(data);

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
      yield* body.stream.transform(sseEventTransformer(param.batch?.length));
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
    final path = '/v1/completions';
    final data = {
      'model': param.model!,
      'stream': true,
      'seed': null,
      'max_tokens': param.maxTokens ?? _decodeParam.maxTokens,
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
      yield* body.stream.transform(sseEventTransformer(1));
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
  Future<dynamic> setGenerationConfig(GenerationConfig param) async {
    _config = param;
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
  Future<dynamic> setLogLevel(RWKVLogLevel level) {
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
