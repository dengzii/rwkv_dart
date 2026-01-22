import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/bean/openai/chunk_data_bean.dart';
import 'package:rwkv_dart/src/api/common/sse.dart';
import 'package:rwkv_dart/src/logger.dart';

class OpenAiApiClient implements RWKV {
  final String url;
  final String apiKey;

  GenerationConfig _config = GenerationConfig.initial();
  DecodeParam _decodeParam = DecodeParam.initial();

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
    _dio.options.headers['Authorization'] = 'Bearer ${apiKey}';
    logd('rwkv client created: ${url}');
  }

  Future getModelList() async {
    final response = await _dio.get('/v1/models');
    return response.data;
  }

  @override
  Stream<GenerationResponse> chat(ChatParam param) async* {
    final path = '/v1/chat/completions';

    if (param.model == null || param.model!.isEmpty) {
      throw 'param.model is null or empty';
    }
    if (param.messages.length % 2 != 1) {
      throw 'param.messages.length must be odd';
    }

    final history = param.messages;

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
      'messages': [
        for (final (index, message) in history.indexed)
          {
            'role': index % 2 == 0
                ? _config.userRole.toLowerCase()
                : _config.assistantRole.toLowerCase(),
            'content': message,
          },
      ],
    };
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
    } catch (e, s) {
      if (e is DioException) {
        throw "${e.type}, $s";
      }
      throw 'request failed';
    }

    final body = resp.data as ResponseBody;
    final stream = body.stream.map(SseEvent.decode);

    final transformer = StreamTransformer.fromBind(_sseEventTransformer);

    try {
      yield* stream.transform(transformer);
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(text: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
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
      _cancelToken = CancelToken();
      resp = await _dio.post(
        path,
        cancelToken: _cancelToken,
        data: data,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Content-Type': 'application/json'},
        ),
      );
    } catch (e, s) {
      if (e is DioException) {
        throw "${e.type}, $s";
      }
      throw 'request failed';
    }

    final body = resp.data as ResponseBody;
    final stream = body.stream.map(SseEvent.decode);
    final transformer = StreamTransformer.fromBind(_sseEventTransformer);

    try {
      yield* stream.transform(transformer);
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        yield GenerationResponse(text: '', stopReason: StopReason.canceled);
        return;
      }
      rethrow;
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
  Stream<GenerationState> generationStateStream() async* {
    //
  }

  @override
  Future<GenerationState> getGenerationState() async {
    await _dio.get('/generation_state');
    return GenerationState.initial();
  }

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
  Future<dynamic> init([InitParam? param]) async {
    //
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
  Future<dynamic> setDecodeParam(DecodeParam param) async {}

  @override
  Future<dynamic> setGenerationConfig(GenerationConfig param) {
    throw UnimplementedError();
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

Stream<GenerationResponse> _sseEventTransformer(
  Stream<SseEvent> stream,
) async* {
  await for (final event in stream) {
    if (event.event == 'DONE') {
      yield GenerationResponse(
        text: '',
        tokenCount: -1,
        stopReason: StopReason.eos,
      );
      break;
    }
    if (event.event == 'PING') {
      logd('PING');
      continue;
    }
    if (event.event == 'ERROR') {
      yield GenerationResponse(
        text: '',
        tokenCount: -1,
        stopReason: StopReason.error,
      );
      break;
    }
    if (event.data.trim().isEmpty) {
      continue;
    }
    final map = jsonDecode(event.data.trim());
    final data = ChunkDataBean.fromJson(map);

    final choose = data.choices.first;
    final text = choose.delta != null ? choose.delta?.content : choose.text;
    yield GenerationResponse(
      text: text ?? '',
      tokenCount: -1,
      stopReason: StopReason.none,
    );
  }
}
