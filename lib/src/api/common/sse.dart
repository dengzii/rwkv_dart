import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rwkv_dart/src/logger.dart';
import 'package:shelf/shelf.dart';

class SseEvent {
  final String event;
  final String data;

  SseEvent._({required this.event, required this.data});

  factory SseEvent.done() {
    return SseEvent._(event: 'DONE', data: '');
  }

  factory SseEvent.data(String data) {
    return SseEvent._(event: '', data: data);
  }

  factory SseEvent.error(String error) {
    return SseEvent._(event: 'ERROR', data: error);
  }

  factory SseEvent.ping() {
    return SseEvent._(event: 'PING', data: '');
  }

  factory SseEvent.lineSeparator() {
    return SseEvent._(event: '\n\n', data: '');
  }

  factory SseEvent.decode(List<int> raw) {
    if (raw.isEmpty) {
      return SseEvent._(event: '', data: '');
    }
    String data = utf8.decode(raw);

    if (data.startsWith('data: ')) {
      data = data.substring(6);
    }
    String event = '';
    if (data.startsWith('[')) {
      final end = data.indexOf(']');
      event = data.substring(1, end);
      data = data.substring(end + 1).trim();
    }
    return SseEvent._(event: event, data: data);
  }

  List<int> encode() {
    if (event == '\n\n') {
      return utf8.encode('\n\n');
    }
    return utf8.encode(encodeString());
  }

  String encodeString() {
    if (event == '') {
      return 'data: ${data}';
    }
    return 'data: [$event] ${data}'.trim();
  }
}

abstract class SseHandler {
  final _controller = StreamController<SseEvent>();
  final String id;
  Timer? _pingTimer;

  final bool heartbeat;

  bool get isClosed => _controller.isClosed;

  SseHandler({this.heartbeat = true, required this.id});

  void stopHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void write(SseEvent event) {
    logi('sse-write($id)>${event.event} ${event.data}');
    _controller.add(event);
    _controller.add(SseEvent.lineSeparator());
  }

  Stream<SseEvent> emitting(Request req);

  Future onConnectionReady(Request req) async {
    if (heartbeat) {
      startHeartbeat();
    }
  }

  void onConnectionClosed() {
    _pingTimer?.cancel();
  }

  void close() {
    _controller.close();
  }

  Response handle(Request req) {
    _controller
      ..onListen = () async {
        try {
          await onConnectionReady(req);

          await for (final event in emitting(req)) {
            if (isClosed) {
              break;
            }
            write(event);
          }
        } catch (e, s) {
          loge(s);
          write(SseEvent.error("$e"));
          close();
          return;
        }
      }
      ..onCancel = () {
        onConnectionClosed();
      };

    return Response.ok(
      _controller.stream.map((e) => e.encode()),
      headers: <String, Object>{
        HttpHeaders.contentTypeHeader: 'text/event-stream',
        HttpHeaders.cacheControlHeader: 'no-cache',
        HttpHeaders.connectionHeader: 'keep-alive',
        HttpHeaders.accessControlAllowOriginHeader: '*',
        HttpHeaders.accessControlAllowHeadersHeader:
            'Content-Type, Authorization, x-access-key, Cache-Control',
        HttpHeaders.accessControlAllowMethodsHeader: 'GET, POST, OPTIONS',
        HttpHeaders.accessControlAllowCredentialsHeader: 'true',
        'X-Accel-Buffering': 'no',
      },
      context: const {'shelf.io.buffer_output': false},
    );
  }

  void startHeartbeat() {
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_controller.isClosed && _controller.hasListener) {
        _controller.add(SseEvent.ping());
      } else {
        stopHeartbeat();
      }
    });
  }
}
