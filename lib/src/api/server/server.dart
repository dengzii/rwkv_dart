import 'dart:convert';
import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/bean/openai/choices_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/chunk_data_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/completion_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/delta_bean.dart';
import 'package:rwkv_dart/src/api/bean/openai/openai_model_bean.dart';
import 'package:rwkv_dart/src/api/common/id.dart';
import 'package:rwkv_dart/src/api/common/sse.dart';
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

class RwkvHttpApiService {
  final Map<String, HttpServiceModelInstance> _instances = {};
  String _modelListPath = '';

  List<ModelBean> _models = [];

  HttpServer? _server;

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
    List<HttpServiceModelInstance> instances = const [],
  }) async {
    _modelListPath = modelListPath;

    _instances.clear();
    for (final inst in instances) {
      _instances[inst.info.id] = inst;
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
          return _SSE(service: this).handle(request);
        case 'v1/responses':
          print(await request.readAsString());
          return Response.ok('');
        default:
          return Response.notFound('Not found');
      }
    });
    logd('run service on ${host}:${port}');
    _server = await shelf_io.serve(handler, host, port);
  }

  Response _modelList() {
    final map = {
      'data': _models
          .map(
            (e) =>
        {
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
  late final HttpServiceModelInstance instance;
  ChatParam? chatParam;
  GenerationParam? genParam;

  final RwkvHttpApiService service;
  bool _closeNormal = false;
  bool _ready = false;

  _SSE({required this.service}) : super(id: 'chatcmpl-${generateId()}');

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
      final system = ms
          .where((e) => e.role == 'system')
          .firstOrNull;
      if (system != null) {
        ms.remove(system);
      }
      final reasoning = completion.reasoningEffort == null
          ? null
          : ReasoningEffort.values
          .where((e) => e.name == completion.reasoningEffort)
          .firstOrNull;
      final cm = ms
          .map((e) => ChatMessage(role: e.role, content: e.content))
          .toList();
      chatParam = ChatParam(
        model: completion.model,
        systemPrompt: system?.content,
        reasoning: reasoning,
        messages: cm,
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

    if (service._instances[completion.model] == null) {
      throw 'invalid model';
    }

    instance = service._instances[completion.model]!;
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
    final created = (DateTime
        .now()
        .millisecondsSinceEpoch / 1000).toInt();
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
