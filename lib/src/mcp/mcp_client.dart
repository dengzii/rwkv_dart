import 'dart:async';

import 'mcp_models.dart';
import 'mcp_stdio_transport.dart';
import 'mcp_transport.dart';

class McpRpcException implements Exception {
  final int code;
  final String message;
  final dynamic data;

  const McpRpcException({required this.code, required this.message, this.data});

  factory McpRpcException.fromJson(dynamic data) {
    final json = data is Map<String, dynamic>
        ? Map<String, dynamic>.from(data)
        : <String, dynamic>{};
    return McpRpcException(
      code: json['code'] as int? ?? -1,
      message: json['message']?.toString() ?? 'unknown MCP error',
      data: json['data'],
    );
  }

  @override
  String toString() => 'McpRpcException(code: $code, message: $message)';
}

class McpClient {
  final String id;
  final McpTransport transport;
  final McpImplementationInfo clientInfo;
  final Duration requestTimeout;
  final void Function(String line)? onStderr;

  final Map<Object, Completer<dynamic>> _pending =
      <Object, Completer<dynamic>>{};

  StreamSubscription<Map<String, dynamic>>? _messagesSubscription;
  StreamSubscription<String>? _stderrSubscription;
  int _nextRequestId = 0;
  bool _connected = false;
  bool _closed = false;
  bool _toolsDirty = true;
  List<McpTool>? _toolCache;
  McpInitializeResult? _initializeResult;

  McpClient({
    required this.id,
    required this.transport,
    McpImplementationInfo? clientInfo,
    this.requestTimeout = const Duration(seconds: 30),
    this.onStderr,
  }) : clientInfo =
           clientInfo ??
           const McpImplementationInfo(name: 'rwkv_dart', version: '1.1.2');

  factory McpClient.stdio({
    required String id,
    required String command,
    List<String> args = const [],
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    Duration shutdownTimeout = const Duration(seconds: 2),
    Duration requestTimeout = const Duration(seconds: 30),
    McpImplementationInfo? clientInfo,
    void Function(String line)? onStderr,
  }) {
    return McpClient(
      id: id,
      requestTimeout: requestTimeout,
      clientInfo: clientInfo,
      onStderr: onStderr,
      transport: McpStdioTransport(
        command: command,
        args: args,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        shutdownTimeout: shutdownTimeout,
      ),
    );
  }

  bool get isConnected => _connected;

  McpInitializeResult? get initializeResult => _initializeResult;

  McpImplementationInfo? get serverInfo => _initializeResult?.serverInfo;

  Future<void> connect() async {
    if (_connected) {
      return;
    }
    if (_closed) {
      throw StateError('MCP client already closed');
    }

    await transport.start();

    _messagesSubscription ??= transport.messages.listen(
      _handleMessage,
      onError: _handleTransportError,
    );
    _stderrSubscription ??= transport.stderrLines.listen((line) {
      if (onStderr != null) {
        onStderr!(line);
      }
    });

    final result = await _request(
      'initialize',
      params: {
        'protocolVersion': mcpLatestProtocolVersion,
        'capabilities': {'tools': {}},
        'clientInfo': clientInfo.toJson(),
      },
    );

    _initializeResult = McpInitializeResult.fromJson(result);
    _connected = true;
    await _notify('notifications/initialized');
  }

  Future<List<McpTool>> listTools({bool refresh = false}) async {
    await connect();
    if (!refresh && !_toolsDirty && _toolCache != null) {
      return List<McpTool>.unmodifiable(_toolCache!);
    }

    final tools = <McpTool>[];
    String? cursor;
    do {
      final result = await _request(
        'tools/list',
        params: <String, dynamic>{
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
      );
      final json = result is Map<String, dynamic>
          ? Map<String, dynamic>.from(result)
          : <String, dynamic>{};
      final rawTools = json['tools'] as Iterable? ?? const <dynamic>[];
      tools.addAll(rawTools.map(McpTool.fromJson));
      cursor = json['nextCursor']?.toString();
    } while (cursor != null && cursor.isNotEmpty);

    _toolCache = tools;
    _toolsDirty = false;
    return List<McpTool>.unmodifiable(tools);
  }

  Future<McpToolResult> callTool(
    String name, {
    Map<String, dynamic>? arguments,
  }) async {
    await connect();
    final result = await _request(
      'tools/call',
      params: <String, dynamic>{'name': name, 'arguments': ?arguments},
    );
    return McpToolResult.fromJson(result);
  }

  Future<dynamic> _request(
    String method, {
    Map<String, dynamic>? params,
  }) async {
    final requestId = ++_nextRequestId;
    final completer = Completer<dynamic>();
    _pending[requestId] = completer;

    await transport.send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': requestId,
      'method': method,
      'params': ?params,
    });

    return completer.future.timeout(
      requestTimeout,
      onTimeout: () {
        _pending.remove(requestId);
        throw TimeoutException(
          'MCP request timed out: $method',
          requestTimeout,
        );
      },
    );
  }

  Future<void> _notify(String method, {Map<String, dynamic>? params}) {
    return transport.send(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': ?params,
    });
  }

  void _handleMessage(Map<String, dynamic> message) {
    final id = message['id'];
    final method = message['method']?.toString();

    if (method != null && id != null) {
      unawaited(_replyMethodNotFound(id));
      return;
    }

    if (method != null) {
      if (method == 'notifications/tools/list_changed') {
        _toolsDirty = true;
        _toolCache = null;
      }
      return;
    }

    if (id == null) {
      return;
    }

    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) {
      return;
    }

    if (message['error'] != null) {
      completer.completeError(McpRpcException.fromJson(message['error']));
      return;
    }

    completer.complete(message['result']);
  }

  Future<void> _replyMethodNotFound(Object id) {
    return transport.send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, dynamic>{'code': -32601, 'message': 'Method not found'},
    });
  }

  void _handleTransportError(Object error, [StackTrace? stackTrace]) {
    final pending = Map<Object, Completer<dynamic>>.from(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _connected = false;

    await _messagesSubscription?.cancel();
    await _stderrSubscription?.cancel();

    final pending = Map<Object, Completer<dynamic>>.from(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('MCP client closed'));
      }
    }

    await transport.close();
  }
}
