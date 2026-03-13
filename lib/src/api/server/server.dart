import 'dart:convert';
import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/bean/openai/choices_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/chunk_data_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/delta_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/messages_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/openai_model_bean.dart';
import 'package:rwkv_dart/src/api/common/id.dart';
import 'package:rwkv_dart/src/api/common/sse.dart';
import 'package:rwkv_dart/src/api/server/request.dart';
import 'package:rwkv_dart/src/logger.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

class HttpServiceModelInstance {
  final RWKV rwkv;
  final ModelBean info;
  final bool fromConfigFile;

  HttpServiceModelInstance({
    required this.rwkv,
    required this.info,
    this.fromConfigFile = false,
  });
}

String? _mapFinishReason(StopReason stopReason) {
  switch (stopReason) {
    case StopReason.maxTokens:
      return 'length';
    case StopReason.toolCalls:
      return 'tool_calls';
    case StopReason.canceled:
      return 'cancelled';
    case StopReason.error:
      return 'error';
    case StopReason.timeout:
      return 'timeout';
    case StopReason.eos:
    case StopReason.unknown:
      return 'stop';
    case StopReason.none:
      return null;
  }
}

class RwkvHttpApiService {
  final Map<String, HttpServiceModelInstance> _instances = {};
  String _modelListPath = '';

  List<ModelBean> _models = [];

  HttpServer? _server;

  bool isRunning() => _server != null;

  Future shutdown() async {
    await _server?.close(force: true);
    _server = null;
  }

  void updateInstances(List<HttpServiceModelInstance> instances) {
    for (final inst in _instances.values) {
      if (inst.fromConfigFile) {
        inst.rwkv.release();
      }
    }

    _instances.clear();
    _models.clear();
    for (final inst in instances) {
      _instances[inst.info.id] = inst;
      _models.add(inst.info);
    }
  }

  Future<void> run({
    required String host,
    int port = 8000,
    String accessKey = '',
    String modelListPath = '',
    List<HttpServiceModelInstance>? instances,
  }) async {
    _modelListPath = modelListPath;

    if (instances != null) {
      _instances.clear();
      for (final inst in instances) {
        _instances[inst.info.id] = inst;
      }
    }
    if (_modelListPath.isNotEmpty) {
      await _launchInstance();
    }

    var handler = const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(cross())
        .addHandler((request) async {
          if (request.method == 'OPTIONS') {
            return Response.ok('');
          }
          switch (request.url.path) {
            case 'health':
              return Response.ok('rwkv');
            case 'v1/models':
              return _modelList();
            case 'v1/completions':
            case 'v1/chat/completions':
              return _completion(request);
            case 'v1/responses':
              print(await request.readAsString());
              return Response.ok('');
            default:
              return Response.notFound('Not found');
          }
        });
    logd('run service on $host:$port');
    _server = await shelf_io.serve(handler, host, port);
  }

  Response _modelList() {
    final map = {
      'data': _models
          .map(
            (e) => {
              ...OpenaiModelBean(
                ownedBy: 'rwkv_dart',
                id: e.id,
                object: 'model',
              ).toJson(),
              'model_size': e.modelSize,
              'file_size': e.fileSize,
            },
          )
          .toList(),
    };
    return Response.ok(jsonEncode(map));
  }

  Future<Response> _completion(Request request) async {
    try {
      final parsed = await ParsedRequest.parse(request);
      final modelId = parsed.modelId;
      final instance = modelId == null ? null : _instances[modelId];
      if (instance == null) {
        return Response.notFound(
          jsonEncode({
            'error': {'message': 'model not found: $modelId'},
          }),
        );
      }
      if (parsed.decodeParam != null) {
        await instance.rwkv.setDecodeParam(parsed.decodeParam!);
      }
      if (parsed.stream) {
        return _SSE(instance: instance, parsed: parsed).handle(request);
      }
      return _nonStreamingCompletion(instance: instance, parsed: parsed);
    } catch (e, s) {
      loge(s);
      return Response.badRequest(
        body: jsonEncode({
          'error': {'message': '$e'},
        }),
      );
    }
  }

  Future<Response> _nonStreamingCompletion({
    required HttpServiceModelInstance instance,
    required ParsedRequest parsed,
  }) async {
    final created = (DateTime.now().millisecondsSinceEpoch / 1000).toInt();
    final isChat = parsed.chatParam != null;
    logd('handle non-stream ${isChat ? 'chat' : 'gen'}: ${instance.info.id}');

    final stream = isChat
        ? instance.rwkv.chat(parsed.chatParam!)
        : instance.rwkv.generate(parsed.genParam!);

    final content = StringBuffer();
    StopReason stopReason = StopReason.none;
    await for (final resp in stream) {
      if (resp.text.isNotEmpty) {
        content.write(resp.text);
      }
      if (resp.stopReason != StopReason.none) {
        stopReason = resp.stopReason;
      }
    }

    final finishReason = _mapFinishReason(stopReason);
    final text = content.toString();
    final bean = ChunkDataBean(
      created: created,
      model: instance.info.id,
      id: 'chatcmpl-${generateId()}',
      systemFingerprint: instance.info.id,
      object: isChat ? 'chat.completion' : 'text_completion',
      choices: [
        ChoicesBean(
          index: 0,
          text: isChat ? null : text,
          delta: null,
          message: isChat
              ? MessageBean(role: 'assistant', content: text)
              : null,
          finishReason: finishReason,
          logprobs: null,
        ),
      ],
    );
    return Response.ok(jsonEncode(bean.toJson()));
  }

  Future _launchInstance() async {
    final json = await File(_modelListPath).readAsString();
    final modelList = jsonDecode(json)['models'] as List<dynamic>;
    _models = modelList.map(ModelBean.fromJson).toList();
    for (final model in _models) {
      final rwkv = RWKV.isolated();
      logd('launch instance: ${model.name}, ${model.tokenizer}');
      await rwkv.init();
      await rwkv.loadModel(
        LoadModelParam(modelPath: model.path, tokenizerPath: model.tokenizer),
      );
      final instance = HttpServiceModelInstance(
        rwkv: rwkv,
        info: model,
        fromConfigFile: true,
      );
      _instances[model.id] = instance;
    }
    logd('launch instance done: ${_instances.length}');
  }
}

Middleware cross({void Function(String message, bool isError)? logger}) =>
    (innerHandler) {
      return (request) async {
        Response resp = await innerHandler(request);
        final hasType = resp.headers.containsKey(HttpHeaders.contentTypeHeader);
        final origin = request.requestedUri.origin;
        resp = resp.change(
          headers: {
            'Access-Control-Allow-Origin': origin,
            'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
            'Access-Control-Allow-Headers':
                'Content-Type, Authorization, x-access-key, Cache-Control',
            'Access-Control-Max-Age': '3600',
            'Access-Control-Allow-Credentials': 'true',
            if (!hasType) 'Content-Type': 'application/json',
          },
        );
        return resp;
      };
    };

class _SSE extends SseHandler {
  final HttpServiceModelInstance instance;
  final ParsedRequest parsed;
  bool _closeNormal = false;
  bool _ready = false;

  _SSE({required this.instance, required this.parsed})
    : super(id: 'chatcmpl-${generateId()}');

  @override
  Future onConnectionReady(Request req) async {
    super.onConnectionReady(req);
    _ready = true;
    logd('sse connection ready, $id\n${parsed.raw}');
  }

  @override
  void onConnectionClosed() {
    super.onConnectionClosed();
    if (!_closeNormal && _ready) {
      logd('close unexcepted');
      instance.rwkv.stopGenerate();
    }
    logd('sse connection closed, $id');
  }

  @override
  Stream<SseEvent> emitting(Request req) async* {
    final created = (DateTime.now().millisecondsSinceEpoch / 1000).toInt();
    final isChat = parsed.chatParam != null;
    logd('handle ${isChat ? 'chat' : 'gen'}: ${instance.info.id}, $id');

    if (!_ready) {
      yield SseEvent.error('internal server error, NOT READY.');
      return;
    }

    final object = !isChat ? 'text_completion' : 'chat.completion.chunk';

    final stream = !isChat
        ? instance.rwkv.generate(parsed.genParam!)
        : instance.rwkv.chat(parsed.chatParam!);

    await for (final resp in stream) {
      final finishReason = _mapFinishReason(resp.stopReason);
      final bean = ChunkDataBean(
        created: created,
        model: instance.info.id,
        id: id,
        systemFingerprint: instance.info.id,
        object: object,
        choices: [
          ChoicesBean(
            index: 0,
            text: isChat ? null : resp.text,
            delta: !isChat ? null : DeltaBean(content: resp.text),
            finishReason: finishReason,
            logprobs: null,
          ),
        ],
      );
      final chunk = jsonEncode(bean.toJson());
      yield SseEvent.data(chunk);
    }
    yield SseEvent.done();
    _closeNormal = true;
    close();
  }
}
