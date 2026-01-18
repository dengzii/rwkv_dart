import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

class RwkvService {
  static final Map<String, _RwkvApiServerInstance> _instances = {};
  static int _uptime = 0;
  static int _nextPort = 8000;

  static Future<void> run({
    required String host,
    int port = 8000,
    required String accessKey,
  }) async {
    _nextPort = port;
    var handler = const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(cross())
        .addHandler((request) {
          switch (request.url.path) {
            case '/status':
              return _status(request);
            case '/create':
              return _create(request);
            case '/instances':
              return _create(request);
            default:
              return Response.notFound('Not found');
          }
        });
    var server = await shelf_io.serve(handler, host, _nextPort);
    _nextPort++;
    _uptime = DateTime.now().millisecondsSinceEpoch;
    server.autoCompress = true;
  }

  static Response _getInstance(Request request) {
    return Response.ok('OK');
  }

  static Response _create(Request request) {
    return Response.ok(jsonEncode({'port': _nextPort}));
  }

  static Response _status(Request request) {
    return Response.ok(
      jsonEncode({
        'uptime': _uptime,
        'system': Platform.operatingSystem,
        'hostname': Platform.localHostname,
        'instance_count': _instances.length,
      }),
    );
  }
}

class _RwkvApiServerInstance {
  final String host;
  final int port;

  _RwkvApiServerInstance({required this.host, required this.port});

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
      return (request) {
        request.headers['Access-Control-Allow-Origin'] = '*';
        request.headers['Access-Control-Allow-Methods'] =
            'GET, POST, PUT, DELETE, OPTIONS';
        request.headers['Access-Control-Allow-Headers'] =
            'Content-Type, Authorization';
        request.headers['Access-Control-Max-Age'] = '3600';
        request.headers['Access-Control-Allow-Credentials'] = 'true';
        return innerHandler(request);
      };
    };
