import 'dart:convert';
import 'dart:io';

import 'package:rwkv_dart/src/api/model_base_info.dart';
import 'package:rwkv_dart/src/api/models_bean.dart';
import 'package:rwkv_dart/src/api/service_status.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

class RwkvService {
  static final Map<String, _RwkvApiServerInstance> _instances = {};
  static int _uptime = 0;
  static int _nextPort = 8000;
  static String _modelConfigPath = '';
  static String _modelListPath = '';
  static String _id = '';

  static late ServiceStatus _serviceStatus;

  static Future<void> run({
    required String host,
    int port = 8000,
    required String accessKey,
    String modelConfigPath = '',
    String modelListPath = '',
  }) async {
    _id = DateTime.now().millisecondsSinceEpoch.toString();
    _nextPort = port;
    _modelListPath = modelListPath;
    _modelConfigPath = modelConfigPath;
    var handler = const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(cross())
        .addHandler((request) async {
          switch (request.url.path) {
            case 'model_config.json':
              return _modelConfig(request);
            case 'status':
              return await _status(request);
            case 'create':
              return _create(request);
            case 'connect':
              return _connect(request);
            default:
              return Response.notFound('Not found');
          }
        });
    var server = await shelf_io.serve(handler, host, _nextPort);
    _nextPort++;
    _uptime = DateTime.now().millisecondsSinceEpoch;
    server.autoCompress = true;
  }

  static Response _modelConfig(Request request) {
    final file = File(_modelConfigPath).openRead();
    return Response.ok(file);
  }

  static Response _connect(Request request) {
    final instance = request.url.queryParameters['instanceId'];
    if (instance == null || instance.isEmpty) {
      return Response.badRequest(body: 'instanceId is required');
    }
    final modelId = instance.split('_')[1];
    final r = _instances[modelId];
    if (r == null) {
      return Response.badRequest(body: 'instanceId is invalid');
    }
    return Response.ok(jsonEncode({'port': r.port, 'model': r.info.toJson()}));
  }

  static Response _create(Request request) {
    final modelId = request.url.queryParameters['model_id'];
    if (modelId == null || modelId.isEmpty) {
      return Response.badRequest(body: 'model_id is required');
    }

    final model = _serviceStatus.models
        .where((e) => e.id == modelId)
        .firstOrNull;
    if (model == null) {
      return Response.badRequest(body: 'model_id is invalid');
    }
    final r = _RwkvApiServerInstance(
      host: '0.0.0.0',
      port: _nextPort,
      info: ModelBaseInfo(
        name: model.name,
        modelId: modelId,
        instanceId: "${_id}_${modelId}",
        port: _nextPort,
      ),
    );
    _nextPort++;
    // r.run();

    _instances[modelId] = r;
    return Response.ok(jsonEncode({'port': r.port, 'model': r.info.toJson()}));
  }

  static Future<Response> _status(Request request) async {
    final json = await File(_modelListPath).readAsString();
    final modelList = jsonDecode(json)['models'] as List<dynamic>;

    _serviceStatus = ServiceStatus(
      hostname: Platform.localHostname,
      system: Platform.operatingSystem,
      serviceId: _id,
      id: _id,
      uptime: _uptime,
      models: modelList.map(ModelsBean.fromJson).toList(),
      loadedModels: _instances.values.map((e) => e.info).toList(),
    );

    return Response.ok(jsonEncode(_serviceStatus.toJson()));
  }
}

class _RwkvApiServerInstance {
  final String host;
  final int port;
  final ModelBaseInfo info;

  _RwkvApiServerInstance({
    required this.host,
    required this.port,
    required this.info,
  });

  Future run() async {
    var handler = const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(cross())
        .addHandler(_status);
    var server = await shelf_io.serve(handler, host, port);
    server.autoCompress = true;
  }

  Response _status(Request request) {
    return Response.ok('OK');
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
            'Access-Control-Allow-Headers': 'Content-Type, Authorization',
            'Access-Control-Max-Age': '3600',
            'Access-Control-Allow-Credentials': 'true',
            'Content-Type': 'application/json',
          },
        );
        return resp;
      };
    };
