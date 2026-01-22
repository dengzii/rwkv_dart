import 'dart:convert';
import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/bean/openai/choices_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/chunk_data_bean.dart';
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
  }) async {
    _modelListPath = modelListPath;

    await _launchInstance();

    var handler = const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(cross())
        .addHandler((request) async {
          switch (request.url.path) {
            case 'health':
              return Response.ok('rwkv');
            case 'v1/models':
              final map = {'data': _models.map((e) => e.toJson()).toList()};
              return Response.ok(jsonEncode(map));
            case 'v1/completions':
            case 'v1/chat/completions':
              return _SSE().handle(request);
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
        resp = resp.change(
          headers: {
            ...resp.headers,
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
            'Access-Control-Allow-Headers':
                'Content-Type, Authorization, x-access-key, Cache-Control',
            'Access-Control-Max-Age': '3600',
            'Access-Control-Allow-Credentials': 'true',
            'Content-Type': 'application/json',
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

  _SSE() : super(id: 'chatcmpl-${generateId()}');

  @override
  Future onConnectionReady(Request req) async {
    super.onConnectionReady(req);

    final body = await req.readAsString();
    final json = jsonDecode(body);
    final model = json['model'] as String;
    final messages = json['messages'] as Iterable?;
    final prompt = json['prompt'] as String?;

    if (messages != null && messages.isNotEmpty) {
      chatParam = ChatParam(
        model: model,
        messages: [for (final item in messages) item['content']],
      );
    } else if (prompt != null && prompt.isNotEmpty) {
      genParam = GenerationParam(model: model, prompt: prompt);
    }
    instance = RwkvService._instances[model]!;
    logd('sse connection ready, $id');
  }

  @override
  void onConnectionClosed() {
    super.onConnectionClosed();
    if (!_closeNormal) {
      logd('close unexcepted');
      instance.rwkv.stopGenerate();
    }
    logd('sse connection closed, $id');
  }

  @override
  Stream<SseEvent> emitting(Request req) async* {
    final created = (DateTime.now().millisecondsSinceEpoch / 1000).toInt();

    logd('handle chat: ${instance.info.id}, $id');

    final isChat = chatParam != null;

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
