import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rwkv_dart/src/logger.dart';

import 'mcp_transport.dart';

class McpStdioTransport implements McpTransport {
  final String command;
  final List<String> args;
  final String? workingDirectory;
  final Map<String, String>? environment;
  final bool includeParentEnvironment;
  final Duration shutdownTimeout;

  final _messagesController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _stderrController = StreamController<String>.broadcast();

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  bool _started = false;
  bool _closed = false;

  McpStdioTransport({
    required this.command,
    this.args = const [],
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
      return;
    }
    if (_closed) {
      throw StateError('transport already closed');
    }

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
      }),
    );
  }

  void _handleStdoutLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) {
        throw const FormatException('MCP message must be a JSON object');
      }
      logd('MCP stdio transport received: $trimmed');
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
    final encoded = jsonEncode(message);
    logd('MCP stdio transport sending: $encoded');
    process.stdin.writeln(encoded);
    await process.stdin.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;

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
        process.kill();
      }
    }

    await _messagesController.close();
    await _stderrController.close();
  }
}
