import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mcp_logging.dart';
import 'mcp_transport.dart';

class McpStreamableHttpTransport implements McpTransport {
  final Uri endpoint;
  final Map<String, String> headers;
  final Duration requestTimeout;
  final bool openEventStream;
  final bool deleteSessionOnClose;
  final http.Client? client;

  final _messagesController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _stderrController = StreamController<String>.broadcast();

  late final _client = client ?? http.Client();
  late final _ownsClient = client == null;

  bool _started = false;
  bool _closed = false;
  bool _streamUnsupported = false;
  bool _openingStream = false;
  bool _backgroundStreamOpen = false;
  String? _protocolVersion;
  String? _sessionId;
  String? _lastEventId;
  Duration _reconnectDelay = const Duration(seconds: 1);

  String get _logPrefix => '[MCP/http $endpoint]';

  McpStreamableHttpTransport({
    required this.endpoint,
    this.headers = const <String, String>{},
    this.requestTimeout = const Duration(seconds: 30),
    this.openEventStream = true,
    this.deleteSessionOnClose = true,
    this.client,
  });

  @override
  Stream<Map<String, dynamic>> get messages => _messagesController.stream;

  @override
  Stream<String> get stderrLines => _stderrController.stream;

  @override
  Future<void> start() async {
    if (_started) {
      mcpLogDebug('$_logPrefix start skipped: already started');
      return;
    }
    if (_closed) {
      throw StateError('transport already closed');
    }
    _started = true;
    mcpLogDebug('$_logPrefix transport started');
  }

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (!_started) {
      throw StateError('transport not started');
    }
    if (_closed) {
      throw StateError('transport already closed');
    }

    mcpLogDebug(
      '$_logPrefix POST ${message['method'] ?? 'response'} '
      'id=${message['id'] ?? '-'}',
    );
    mcpLogTrace('$_logPrefix send payload: $message');
    final request = http.Request('POST', endpoint)
      ..headers.addAll(
        _requestHeaders(acceptSse: true, includeContentType: true),
      )
      ..body = jsonEncode(message);

    final response = await _client.send(request).timeout(requestTimeout);
    _captureSession(response);
    mcpLogDebug(
      '$_logPrefix POST response status=${response.statusCode} '
      'content-type=${response.headers['content-type'] ?? ''}',
    );

    final statusCode = response.statusCode;
    if (statusCode == 404 && _sessionId != null) {
      _sessionId = null;
      throw StateError('MCP HTTP session expired');
    }
    if (statusCode == 202) {
      await response.stream.drain<void>();
      mcpLogDebug('$_logPrefix request accepted asynchronously');
      _maybeOpenBackgroundStream();
      return;
    }
    if (statusCode < 200 || statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw StateError('MCP HTTP request failed: $statusCode $body');
    }

    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('text/event-stream')) {
      mcpLogDebug('$_logPrefix received SSE response stream');
      unawaited(_consumeSse(response.stream, reconnect: false));
      _maybeOpenBackgroundStream();
      return;
    }

    final body = await response.stream.bytesToString();
    if (body.trim().isEmpty) {
      _maybeOpenBackgroundStream();
      return;
    }

    final decoded = jsonDecode(body);
    _emitMessage(decoded);
    _maybeOpenBackgroundStream();
  }

  @override
  void setProtocolVersion(String version) {
    _protocolVersion = version;
    mcpLogDebug('$_logPrefix protocol version set to $version');
    _maybeOpenBackgroundStream();
  }

  void _maybeOpenBackgroundStream() {
    if (!openEventStream || _streamUnsupported || _closed) {
      return;
    }
    if (_protocolVersion == null || _sessionId == null) {
      return;
    }
    if (_openingStream || _backgroundStreamOpen) {
      return;
    }
    mcpLogDebug('$_logPrefix opening background SSE stream');
    unawaited(_openBackgroundStream());
  }

  Future<void> _openBackgroundStream() async {
    if (_openingStream || _closed || _streamUnsupported) {
      return;
    }

    _openingStream = true;
    try {
      while (!_closed && !_streamUnsupported && _sessionId != null) {
        final request = http.Request('GET', endpoint)
          ..headers.addAll(
            _requestHeaders(
              acceptSse: true,
              includeContentType: false,
              lastEventId: _lastEventId,
            ),
          );

        final response = await _client.send(request).timeout(requestTimeout);
        _captureSession(response);
        mcpLogDebug(
          '$_logPrefix GET stream status=${response.statusCode} '
          'content-type=${response.headers['content-type'] ?? ''}',
        );

        if (response.statusCode == 405 || response.statusCode == 501) {
          _streamUnsupported = true;
          await response.stream.drain<void>();
          mcpLogWarning('$_logPrefix server does not support GET event stream');
          return;
        }
        if (response.statusCode == 404) {
          _sessionId = null;
          _messagesController.addError(StateError('MCP HTTP session expired'));
          await response.stream.drain<void>();
          mcpLogWarning('$_logPrefix event stream session expired');
          return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.stream.bytesToString();
          _messagesController.addError(
            StateError('MCP event stream failed: ${response.statusCode} $body'),
          );
          mcpLogError(
            '$_logPrefix event stream failed: ${response.statusCode} $body',
          );
          return;
        }

        final contentType = response.headers['content-type'] ?? '';
        if (!contentType.contains('text/event-stream')) {
          await response.stream.drain<void>();
          _streamUnsupported = true;
          mcpLogWarning('$_logPrefix GET stream returned non-SSE response');
          return;
        }

        _backgroundStreamOpen = true;
        mcpLogDebug('$_logPrefix background SSE stream connected');
        await _consumeSse(response.stream, reconnect: true);
        _backgroundStreamOpen = false;
        mcpLogDebug('$_logPrefix background SSE stream disconnected');

        if (_closed || _streamUnsupported || _sessionId == null) {
          return;
        }
        await Future.delayed(_reconnectDelay);
      }
    } finally {
      _backgroundStreamOpen = false;
      _openingStream = false;
    }
  }

  Future<void> _consumeSse(
    Stream<List<int>> byteStream, {
    required bool reconnect,
  }) async {
    try {
      await for (final event in _decodeSse(byteStream)) {
        if (event.retry != null && event.retry! > 0) {
          _reconnectDelay = Duration(milliseconds: event.retry!);
          mcpLogDebug(
            '$_logPrefix SSE retry updated to ${_reconnectDelay.inMilliseconds}ms',
          );
        }
        if (event.id != null && event.id!.isNotEmpty) {
          _lastEventId = event.id;
          mcpLogTrace('$_logPrefix SSE lastEventId=${event.id}');
        }
        if (event.data.trim().isEmpty) {
          continue;
        }
        try {
          mcpLogTrace('$_logPrefix SSE data: ${event.data}');
          final decoded = jsonDecode(event.data);
          _emitMessage(decoded);
        } catch (error, stackTrace) {
          _messagesController.addError(
            FormatException('invalid MCP HTTP SSE message: ${event.data}'),
            stackTrace,
          );
        }
      }
    } catch (error, stackTrace) {
      if (!_closed) {
        _messagesController.addError(error, stackTrace);
        mcpLogError('$_logPrefix SSE consume error: $error');
      }
    }

    if (!reconnect) {
      return;
    }
  }

  Stream<_SseEvent> _decodeSse(Stream<List<int>> bytes) async* {
    final lines = bytes.transform(utf8.decoder).transform(const LineSplitter());

    String? currentId;
    int? currentRetry;
    final dataLines = <String>[];

    Future<_SseEvent?> flush() async {
      if (currentId == null && currentRetry == null && dataLines.isEmpty) {
        return null;
      }
      final event = _SseEvent(
        id: currentId,
        retry: currentRetry,
        data: dataLines.join('\n'),
      );
      currentId = null;
      currentRetry = null;
      dataLines.clear();
      return event;
    }

    await for (final line in lines) {
      if (line.isEmpty) {
        final event = await flush();
        if (event != null) {
          yield event;
        }
        continue;
      }
      if (line.startsWith(':')) {
        continue;
      }
      final index = line.indexOf(':');
      final field = index == -1 ? line : line.substring(0, index);
      final rawValue = index == -1 ? '' : line.substring(index + 1);
      final value = rawValue.startsWith(' ') ? rawValue.substring(1) : rawValue;
      if (field == 'data') {
        dataLines.add(value);
      } else if (field == 'id') {
        currentId = value;
      } else if (field == 'retry') {
        currentRetry = int.tryParse(value);
      }
    }

    final event = await flush();
    if (event != null) {
      yield event;
    }
  }

  Map<String, String> _requestHeaders({
    required bool acceptSse,
    required bool includeContentType,
    String? lastEventId,
  }) {
    return <String, String>{
      ...headers,
      'Accept': acceptSse
          ? 'text/event-stream, application/json'
          : 'application/json',
      if (includeContentType) 'Content-Type': 'application/json',
      'MCP-Protocol-Version': ?_protocolVersion,
      'MCP-Session-Id': ?_sessionId,
      if (lastEventId != null && lastEventId.isNotEmpty)
        'Last-Event-ID': lastEventId,
    };
  }

  void _captureSession(http.BaseResponse response) {
    final sessionId = response.headers['mcp-session-id'];
    if (sessionId != null && sessionId.isNotEmpty) {
      if (_sessionId != sessionId) {
        mcpLogDebug('$_logPrefix session id updated: $sessionId');
      }
      _sessionId = sessionId;
    }
  }

  void _emitMessage(dynamic value) {
    if (value is! Map) {
      throw const FormatException(
        'MCP transport message must be a JSON object',
      );
    }
    _messagesController.add(
      value.map((key, item) => MapEntry(key.toString(), item)),
    );
  }

  Future<void> _deleteSession() async {
    if (!deleteSessionOnClose || _sessionId == null) {
      return;
    }
    mcpLogDebug('$_logPrefix deleting session $_sessionId');
    final request = http.Request('DELETE', endpoint)
      ..headers.addAll(
        _requestHeaders(acceptSse: false, includeContentType: false),
      );
    try {
      final response = await _client.send(request).timeout(requestTimeout);
      await response.stream.drain<void>();
    } catch (_) {
      mcpLogWarning('$_logPrefix delete session failed during shutdown');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      mcpLogDebug('$_logPrefix close skipped: already closed');
      return;
    }
    _closed = true;
    mcpLogDebug('$_logPrefix closing transport');

    await _deleteSession();

    if (_ownsClient) {
      _client.close();
    }

    await _messagesController.close();
    await _stderrController.close();
    mcpLogDebug('$_logPrefix transport closed');
  }
}

class _SseEvent {
  final String? id;
  final int? retry;
  final String data;

  const _SseEvent({required this.id, required this.retry, required this.data});
}
