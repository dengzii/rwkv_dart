import 'dart:async';

import 'mcp_logging.dart';
import 'mcp_models.dart';
import 'mcp_stdio_transport.dart';
import 'mcp_streamable_http_transport.dart';
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
  bool _resourcesDirty = true;
  bool _resourceTemplatesDirty = true;
  bool _promptsDirty = true;

  List<McpTool>? _toolCache;
  List<McpResource>? _resourceCache;
  List<McpResourceTemplate>? _resourceTemplateCache;
  List<McpPrompt>? _promptCache;
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
    List<String> args = const <String>[],
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

  factory McpClient.streamableHttp({
    required String id,
    required Uri endpoint,
    Map<String, String> headers = const <String, String>{},
    Duration requestTimeout = const Duration(seconds: 30),
    bool openEventStream = true,
    bool deleteSessionOnClose = true,
    McpImplementationInfo? clientInfo,
  }) {
    return McpClient(
      id: id,
      requestTimeout: requestTimeout,
      clientInfo: clientInfo,
      transport: McpStreamableHttpTransport(
        endpoint: endpoint,
        headers: headers,
        requestTimeout: requestTimeout,
        openEventStream: openEventStream,
        deleteSessionOnClose: deleteSessionOnClose,
      ),
    );
  }

  bool get isConnected => _connected;

  McpInitializeResult? get initializeResult => _initializeResult;

  McpImplementationInfo? get serverInfo => _initializeResult?.serverInfo;

  Map<String, dynamic> get serverCapabilities =>
      _initializeResult?.capabilities ?? const <String, dynamic>{};

  bool get _alwaysRefreshCatalogs => transport is McpStreamableHttpTransport;

  String get _logPrefix => '[MCP/$id]';

  Future<void> connect() async {
    if (_connected) {
      mcpLogDebug('$_logPrefix connect skipped: already connected');
      return;
    }
    if (_closed) {
      throw StateError('MCP client already closed');
    }

    mcpLogDebug('$_logPrefix starting transport ${transport.runtimeType}');
    await transport.start();

    _messagesSubscription ??= transport.messages.listen(
      _handleMessage,
      onError: _handleTransportError,
    );
    _stderrSubscription ??= transport.stderrLines.listen((line) {
      mcpLogWarning('$_logPrefix stderr: $line');
      if (onStderr != null) {
        onStderr!(line);
      }
    });

    mcpLogDebug('$_logPrefix initializing session');
    final result = await _request(
      'initialize',
      params: {
        'protocolVersion': mcpLatestProtocolVersion,
        'capabilities': {'tools': {}, 'resources': {}, 'prompts': {}},
        'clientInfo': clientInfo.toJson(),
      },
    );

    _initializeResult = McpInitializeResult.fromJson(result);
    transport.setProtocolVersion(_initializeResult!.protocolVersion);
    _connected = true;
    mcpLogDebug(
      '$_logPrefix connected: '
      'server=${_initializeResult!.serverInfo.name} '
      'version=${_initializeResult!.serverInfo.version} '
      'protocol=${_initializeResult!.protocolVersion}',
    );
    await _notify('notifications/initialized');
  }

  void invalidateAllCaches() {
    mcpLogDebug('$_logPrefix invalidating all MCP catalogs');
    _toolsDirty = true;
    _resourcesDirty = true;
    _resourceTemplatesDirty = true;
    _promptsDirty = true;
    _toolCache = null;
    _resourceCache = null;
    _resourceTemplateCache = null;
    _promptCache = null;
  }

  Future<List<McpTool>> listTools({bool refresh = false}) async {
    await connect();
    if (!refresh &&
        !_alwaysRefreshCatalogs &&
        !_toolsDirty &&
        _toolCache != null) {
      mcpLogDebug(
        '$_logPrefix listTools cache hit: ${_toolCache!.length} tools',
      );
      return List<McpTool>.unmodifiable(_toolCache!);
    }

    mcpLogDebug(
      '$_logPrefix listTools fetching '
      '(refresh=$refresh, streamable_http_fresh=$_alwaysRefreshCatalogs)',
    );
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
    mcpLogDebug('$_logPrefix listTools fetched: ${tools.length} tools');
    return List<McpTool>.unmodifiable(tools);
  }

  Future<McpToolResult> callTool(
    String name, {
    Map<String, dynamic>? arguments,
  }) async {
    await connect();
    mcpLogDebug(
      '$_logPrefix callTool name=$name '
      'args=${arguments == null ? 0 : arguments.length}',
    );
    mcpLogTrace(
      '$_logPrefix callTool payload: ${arguments ?? const <String, dynamic>{}}',
    );
    final result = await _request(
      'tools/call',
      params: <String, dynamic>{
        'name': name,
        if (arguments != null) 'arguments': arguments,
      },
    );
    final parsed = McpToolResult.fromJson(result);
    mcpLogDebug(
      '$_logPrefix callTool done name=$name '
      'isError=${parsed.isError} blocks=${parsed.content.length}',
    );
    return parsed;
  }

  Future<List<McpResource>> listResources({bool refresh = false}) async {
    await connect();
    if (!refresh &&
        !_alwaysRefreshCatalogs &&
        !_resourcesDirty &&
        _resourceCache != null) {
      mcpLogDebug(
        '$_logPrefix listResources cache hit: ${_resourceCache!.length} resources',
      );
      return List<McpResource>.unmodifiable(_resourceCache!);
    }

    mcpLogDebug(
      '$_logPrefix listResources fetching '
      '(refresh=$refresh, streamable_http_fresh=$_alwaysRefreshCatalogs)',
    );
    final resources = <McpResource>[];
    String? cursor;
    do {
      final result = await _request(
        'resources/list',
        params: <String, dynamic>{
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
      );
      final json = result is Map<String, dynamic>
          ? Map<String, dynamic>.from(result)
          : <String, dynamic>{};
      final rawResources = json['resources'] as Iterable? ?? const <dynamic>[];
      resources.addAll(rawResources.map(McpResource.fromJson));
      cursor = json['nextCursor']?.toString();
    } while (cursor != null && cursor.isNotEmpty);

    _resourceCache = resources;
    _resourcesDirty = false;
    mcpLogDebug(
      '$_logPrefix listResources fetched: ${resources.length} resources',
    );
    return List<McpResource>.unmodifiable(resources);
  }

  Future<List<McpResourceTemplate>> listResourceTemplates({
    bool refresh = false,
  }) async {
    await connect();
    if (!refresh &&
        !_resourceTemplatesDirty &&
        _resourceTemplateCache != null) {
      mcpLogDebug(
        '$_logPrefix listResourceTemplates cache hit: '
        '${_resourceTemplateCache!.length} templates',
      );
      return List<McpResourceTemplate>.unmodifiable(_resourceTemplateCache!);
    }

    mcpLogDebug(
      '$_logPrefix listResourceTemplates fetching (refresh=$refresh)',
    );
    final templates = <McpResourceTemplate>[];
    String? cursor;
    do {
      final result = await _request(
        'resources/templates/list',
        params: <String, dynamic>{
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
      );
      final json = result is Map<String, dynamic>
          ? Map<String, dynamic>.from(result)
          : <String, dynamic>{};
      final rawTemplates =
          json['resourceTemplates'] as Iterable? ??
          json['templates'] as Iterable? ??
          const <dynamic>[];
      templates.addAll(rawTemplates.map(McpResourceTemplate.fromJson));
      cursor = json['nextCursor']?.toString();
    } while (cursor != null && cursor.isNotEmpty);

    _resourceTemplateCache = templates;
    _resourceTemplatesDirty = false;
    mcpLogDebug(
      '$_logPrefix listResourceTemplates fetched: ${templates.length} templates',
    );
    return List<McpResourceTemplate>.unmodifiable(templates);
  }

  Future<McpReadResourceResult> readResource(String uri) async {
    await connect();
    mcpLogDebug('$_logPrefix readResource uri=$uri');
    final result = await _request(
      'resources/read',
      params: <String, dynamic>{'uri': uri},
    );
    final parsed = McpReadResourceResult.fromJson(result);
    mcpLogDebug(
      '$_logPrefix readResource done uri=$uri contents=${parsed.contents.length}',
    );
    return parsed;
  }

  Future<List<McpPrompt>> listPrompts({bool refresh = false}) async {
    await connect();
    if (!refresh &&
        !_alwaysRefreshCatalogs &&
        !_promptsDirty &&
        _promptCache != null) {
      mcpLogDebug(
        '$_logPrefix listPrompts cache hit: ${_promptCache!.length} prompts',
      );
      return List<McpPrompt>.unmodifiable(_promptCache!);
    }

    mcpLogDebug(
      '$_logPrefix listPrompts fetching '
      '(refresh=$refresh, streamable_http_fresh=$_alwaysRefreshCatalogs)',
    );
    final prompts = <McpPrompt>[];
    String? cursor;
    do {
      final result = await _request(
        'prompts/list',
        params: <String, dynamic>{
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
      );
      final json = result is Map<String, dynamic>
          ? Map<String, dynamic>.from(result)
          : <String, dynamic>{};
      final rawPrompts = json['prompts'] as Iterable? ?? const <dynamic>[];
      prompts.addAll(rawPrompts.map(McpPrompt.fromJson));
      cursor = json['nextCursor']?.toString();
    } while (cursor != null && cursor.isNotEmpty);

    _promptCache = prompts;
    _promptsDirty = false;
    mcpLogDebug('$_logPrefix listPrompts fetched: ${prompts.length} prompts');
    return List<McpPrompt>.unmodifiable(prompts);
  }

  Future<McpPromptResult> getPrompt(
    String name, {
    Map<String, String>? arguments,
  }) async {
    await connect();
    mcpLogDebug(
      '$_logPrefix getPrompt name=$name '
      'args=${arguments == null ? 0 : arguments.length}',
    );
    final result = await _request(
      'prompts/get',
      params: <String, dynamic>{
        'name': name,
        if (arguments != null) 'arguments': arguments,
      },
    );
    final parsed = McpPromptResult.fromJson(result);
    mcpLogDebug(
      '$_logPrefix getPrompt done name=$name messages=${parsed.messages.length}',
    );
    return parsed;
  }

  Future<dynamic> _request(
    String method, {
    Map<String, dynamic>? params,
  }) async {
    final requestId = ++_nextRequestId;
    final completer = Completer<dynamic>();
    _pending[requestId] = completer;
    mcpLogDebug('$_logPrefix request#$requestId -> $method');
    if (params != null && params.isNotEmpty) {
      mcpLogTrace('$_logPrefix request#$requestId params: $params');
    }

    await transport.send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': requestId,
      'method': method,
      if (params != null) 'params': params,
    });

    return completer.future.timeout(
      requestTimeout,
      onTimeout: () {
        _pending.remove(requestId);
        mcpLogError('$_logPrefix request#$requestId timed out: $method');
        throw TimeoutException(
          'MCP request timed out: $method',
          requestTimeout,
        );
      },
    );
  }

  Future<void> _notify(String method, {Map<String, dynamic>? params}) {
    mcpLogDebug('$_logPrefix notify -> $method');
    if (params != null && params.isNotEmpty) {
      mcpLogTrace('$_logPrefix notify params: $params');
    }
    return transport.send(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    });
  }

  void _handleMessage(Map<String, dynamic> message) {
    final id = message['id'];
    final method = message['method']?.toString();

    if (method != null && id != null) {
      mcpLogWarning(
        '$_logPrefix unexpected server request id=$id method=$method',
      );
      unawaited(_replyMethodNotFound(id));
      return;
    }

    if (method != null) {
      mcpLogDebug('$_logPrefix notification <- $method');
      if (method == 'notifications/tools/list_changed') {
        _toolsDirty = true;
        _toolCache = null;
        mcpLogDebug('$_logPrefix tools catalog marked dirty');
      } else if (method == 'notifications/resources/list_changed') {
        _resourcesDirty = true;
        _resourceTemplatesDirty = true;
        _resourceCache = null;
        _resourceTemplateCache = null;
        mcpLogDebug('$_logPrefix resources catalog marked dirty');
      } else if (method == 'notifications/prompts/list_changed') {
        _promptsDirty = true;
        _promptCache = null;
        mcpLogDebug('$_logPrefix prompts catalog marked dirty');
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
      final error = McpRpcException.fromJson(message['error']);
      mcpLogWarning('$_logPrefix response#$id error: $error');
      completer.completeError(error);
      return;
    }

    mcpLogDebug('$_logPrefix response#$id ok');
    mcpLogTrace('$_logPrefix response#$id payload: ${message['result']}');
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
    mcpLogError('$_logPrefix transport error: $error');
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
      mcpLogDebug('$_logPrefix close skipped: already closed');
      return;
    }
    _closed = true;
    _connected = false;
    mcpLogDebug('$_logPrefix closing client');

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
    mcpLogDebug('$_logPrefix client closed');
  }
}
