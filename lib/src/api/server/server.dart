import 'dart:convert';
import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/bean/openai/choices_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/chunk_data_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/completion_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/delta_bean.dart';
import 'package:rwkv_dart/src/api/common/id.dart';
import 'package:rwkv_dart/src/api/common/sse.dart';
import 'package:rwkv_dart/src/logger.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

class _RWKVInstance {
  final RWKV rwkv;
  final ModelBean info;

  _RWKVInstance({required this.rwkv, required this.info});
}

class RwkvService {
  static final Map<String, _RWKVInstance> _instances = {};
  static String _modelListPath = '';

  static List<ModelBean> _models = [];

  static Future<void> run({
    required String host,
    int port = 8000,
    required String accessKey,
    String modelListPath = '',
    Map<ModelBean, RWKV> instances = const {},
  }) async {
    _modelListPath = modelListPath;

    _instances.clear();
    for (final entry in instances.entries) {
      _instances[entry.key.id] = _RWKVInstance(
        rwkv: entry.value,
        info: entry.key,
      );
    }
    await _launchInstance();

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
              final map = {'data': _models.map((e) => e.toJson()).toList()};
              return Response.ok(jsonEncode(map));
            case 'v1/completions':
            case 'v1/chat/completions':
              return _SSE().handle(request);
            case 'v1/responses':
              print(await request.readAsString());
              return Response.ok('');
            default:
              return Response.notFound('Not found');
          }
        });
    logd('run service on ${host}:${port}');
    final server = await shelf_io.serve(handler, host, port);
    server.autoCompress = false;
  }

  static Future _launchInstance() async {
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
      final instance = _RWKVInstance(rwkv: rwkv, info: model);
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
        resp = resp.change(
          headers: {
            'Access-Control-Allow-Origin': '*',
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
  late final _RWKVInstance instance;
  ChatParam? chatParam;
  GenerationParam? genParam;

  bool _closeNormal = false;
  bool _ready = false;

  _SSE() : super(id: 'chatcmpl-${generateId()}');

  @override
  Future onConnectionReady(Request req) async {
    super.onConnectionReady(req);

    final body = await req.readAsString();

    if (body.isEmpty) {
      logw('request body is empty');
      write(SseEvent.error('body is empty'));
      close();
      return;
    }

    final json = jsonDecode(body);
    final completion = CompletionBean.fromJson(json);

    if (completion.messages.isNotEmpty) {
      final ms = completion.messages.toList();
      final system = ms.where((e) => e.role == 'system').firstOrNull;
      if (system != null) {
        ms.remove(system);
      }
      chatParam = ChatParam(
        model: completion.model,
        system: system?.content,
        messages: ms.map((e) => e.content).toList(),
      );
    } else if (completion.prompt != null) {
      genParam = GenerationParam(
        model: completion.model,
        prompt: completion.prompt!,
      );
    }
    if (chatParam == null && genParam == null) {
      throw 'invalid request';
    }
    instance = RwkvService._instances[completion.model]!;
    _ready = true;
    logd('sse connection ready, $id\n$body');
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
    final isChat = chatParam != null;
    logd('handle ${isChat ? 'chat' : 'gen'}: ${instance.info.id}, $id');

    if (!_ready) {
      yield SseEvent.error('internal server error, NOT READY.');
      return;
    }

    final object = !isChat ? 'text_completion' : 'chat.completion.chunk';

    final stream = !isChat
        ? await instance.rwkv.generate(genParam!)
        : await instance.rwkv.chat(chatParam!);

    await for (final resp in stream) {
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
            finishReason: null,
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
