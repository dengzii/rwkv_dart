import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_logging.dart';
import 'mcp_transport.dart';

class McpStdioTransport implements McpTransport {
  final String command;
  final List<String> args;
  final String? workingDirectory;
  final Map<String, String>? environment;
  final bool includeParentEnvironment;
  final Duration shutdownTimeout;

  final StreamController<Map<String, dynamic>> _messagesController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<String> _stderrController =
      StreamController<String>.broadcast();

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  bool _started = false;
  bool _closed = false;

  String get _logPrefix => '[MCP/stdio]';

  McpStdioTransport({
    required this.command,
    this.args = const <String>[],
    this.workingDirectory,
    this.environment,
    this.includeParentEnvironment = true,
    this.shutdownTimeout = const Duration(seconds: 2),
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

    mcpLogDebug(
      '$_logPrefix starting process command=$command args=${args.length}'
      '${workingDirectory == null ? '' : ' cwd=$workingDirectory'}',
    );
    final process = await Process.start(
      command,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: false,
    );

    _process = process;
    _started = true;
    mcpLogDebug('$_logPrefix process started');

    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStdoutLine, onError: _messagesController.addError);

    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_stderrController.add, onError: _stderrController.addError);

    unawaited(
      process.exitCode.then((code) {
        if (_closed || _messagesController.isClosed) {
          return;
        }
        _messagesController.addError(
          StateError('MCP process exited unexpectedly with code $code'),
        );
        mcpLogWarning(
          '$_logPrefix process exited unexpectedly with code $code',
        );
      }),
    );
  }

  void _handleStdoutLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return;
    }
    mcpLogTrace('$_logPrefix stdout: $trimmed');

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) {
        throw const FormatException('MCP message must be a JSON object');
      }
      _messagesController.add(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (error, stackTrace) {
      _messagesController.addError(
        FormatException('invalid MCP message from stdout: $trimmed'),
        stackTrace,
      );
    }
  }

  @override
  Future<void> send(Map<String, dynamic> message) async {
    final process = _process;
    if (!_started || process == null) {
      throw StateError('transport not started');
    }
    if (_closed) {
      throw StateError('transport already closed');
    }

    mcpLogTrace('$_logPrefix send: $message');
    process.stdin.writeln(jsonEncode(message));
    await process.stdin.flush();
  }

  @override
  void setProtocolVersion(String version) {
    // stdio transport does not need protocol version headers
  }

  @override
  Future<void> close() async {
    if (_closed) {
      mcpLogDebug('$_logPrefix close skipped: already closed');
      return;
    }
    _closed = true;
    mcpLogDebug('$_logPrefix closing transport');

    final process = _process;
    _process = null;

    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();

    if (process != null) {
      try {
        await process.stdin.close();
      } catch (_) {
        // ignore close errors during shutdown
      }

      try {
        await process.exitCode.timeout(shutdownTimeout);
      } on TimeoutException {
        mcpLogWarning('$_logPrefix process exit timed out, killing process');
        process.kill();
      }
    }

    await _messagesController.close();
    await _stderrController.close();
    mcpLogDebug('$_logPrefix transport closed');
  }
}
