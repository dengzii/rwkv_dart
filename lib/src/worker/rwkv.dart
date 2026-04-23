import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rwkv_dart/src/logger.dart';
import 'package:rwkv_dart/src/rwkv.dart';
import 'package:rwkv_dart/src/worker/ipc.dart';
import 'package:rwkv_dart/src/worker/serialize.dart';

class RWKVProcess implements RWKV {
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;
  final bool includeParentEnvironment;
  final bool runInShell;
  final Duration ipcConnectTimeout;
  final Duration shutdownTimeout;

  Process? _process;
  Future<void>? _startFuture;
  IOSink? _protocolOutput;
  Socket? _ipcSocket;
  ServerSocket? _ipcServer;
  StreamSubscription<String>? _protocolSubscription;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Future<void> _sendQueue = Future<void>.value();
  bool _closing = false;

  final Map<String, Completer<dynamic>> _pendingFutures = {};
  final Map<String, StreamController<dynamic>> _pendingStreams = {};

  RWKVProcess(
    this.executable, {
    List<String> arguments = const [],
    this.workingDirectory,
    this.environment,
    this.includeParentEnvironment = true,
    this.runInShell = false,
    this.ipcConnectTimeout = const Duration(seconds: 2),
    this.shutdownTimeout = const Duration(seconds: 5),
  }) : arguments = List.unmodifiable(arguments);

  Future<void> _ensureStarted() {
    if (_process != null) {
      return Future.value();
    }
    return _startFuture ??= _start();
  }

  Future<void> _start() async {
    _closing = false;
    try {
      final socketConfig = await _createSocketIpcConfig();
      final process = await Process.start(
        executable,
        [...arguments, ...socketConfig.toArgs()],
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell,
      );
      _process = process;
      _stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty) {
              stderr.writeln('[rwkv-worker][stdout] $line');
            }
          });
      _stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty) {
              stderr.writeln(line);
            }
          });
      await _connectSocketIpc();

      process.exitCode.then((code) {
        _process = null;
        _startFuture = null;
        if (!_closing ||
            _pendingFutures.isNotEmpty ||
            _pendingStreams.isNotEmpty) {
          _failPending('RWKV worker exited with code $code');
        }
      });
    } catch (_) {
      await _shutdownProcess();
      rethrow;
    }
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    try {
      _routeMessage(WorkerMessage.fromLine(line));
    } catch (e) {
      logi('[worker] $line');
    }
  }

  void _routeMessage(WorkerMessage message) {
    final future = _pendingFutures.remove(message.id);
    if (future != null) {
      if (message.error.isNotEmpty) {
        future.completeError(message.error);
      } else {
        future.complete(message.param);
      }
      return;
    }

    final stream = _pendingStreams[message.id];
    if (stream == null) {
      return;
    }
    if (message.error.isNotEmpty) {
      _closePendingStream(message.id, error: message.error);
      return;
    }
    if (message.done) {
      _closePendingStream(message.id);
      return;
    }
    stream.add(message.param);
  }

  void _closePendingStream(String id, {Object? error, StackTrace? stackTrace}) {
    final stream = _pendingStreams.remove(id);
    if (stream == null || stream.isClosed) {
      return;
    }
    if (error != null) {
      stream.addError(error, stackTrace);
    }
    stream.close();
  }

  Future<T> _callFuture<T>(String method, [dynamic param]) async {
    await _ensureStarted();
    final message = WorkerMessage.request(method, param);
    final completer = Completer<dynamic>();
    _pendingFutures[message.id] = completer;
    try {
      await _send(message);
    } catch (e) {
      _pendingFutures.remove(message.id);
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    }
    final result = await completer.future;
    return result as T;
  }

  Stream<T> _callStream<T>(String method, [dynamic param]) {
    final message = WorkerMessage.request(method, param);
    final controller = StreamController<dynamic>();
    _pendingStreams[message.id] = controller;
    controller.onCancel = () {
      final removed = _pendingStreams.remove(message.id);
      if (removed == null) {
        return;
      }
      final process = _process;
      if (process != null) {
        _send(
          WorkerMessage.request(WorkerMethod.cancelStream, message.id),
        ).ignore();
      }
    };

    _ensureStarted().then((_) => _send(message)).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _closePendingStream(message.id, error: error, stackTrace: stackTrace);
    });

    return controller.stream.cast<T>();
  }

  Future<void> _send(WorkerMessage message) async {
    final sendFuture = _sendQueue.then((_) async {
      final output = _protocolOutput;
      if (output == null) {
        throw StateError('RWKV worker process is not running');
      }
      output.writeln(message.toLine());
      await output.flush();
    });
    _sendQueue = sendFuture.catchError((Object _, StackTrace _) {});
    await sendFuture;
  }

  Future<WorkerSocketIpcConfig> _createSocketIpcConfig() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _ipcServer = server;
    return WorkerSocketIpcConfig(
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
    );
  }

  Future<void> _connectSocketIpc() async {
    final server = _ipcServer;
    if (server == null) {
      throw StateError('RWKV worker IPC server is not running');
    }

    try {
      final socket = await server.first.timeout(
        ipcConnectTimeout,
        onTimeout: () {
          throw TimeoutException(
            'RWKV worker failed to connect to the IPC socket within '
            '${ipcConnectTimeout.inMilliseconds}ms',
          );
        },
      );
      _ipcSocket = socket;
      _protocolOutput = socket;
      _protocolSubscription = socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _handleLine,
            onError: (Object error, StackTrace stackTrace) {
              _failPending('RWKV worker socket error: $error');
            },
            onDone: () {
              if (!_closing) {
                _failPending('RWKV worker socket closed');
              }
            },
            cancelOnError: false,
          );
    } finally {
      await server.close();
      _ipcServer = null;
    }
  }

  void _failPending(String error) {
    for (final completer in _pendingFutures.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pendingFutures.clear();

    for (final controller in _pendingStreams.values) {
      if (!controller.isClosed) {
        controller.addError(error);
        controller.close();
      }
    }
    _pendingStreams.clear();
  }

  Future<void> _shutdownProcess() async {
    _closing = true;
    final process = _process;
    _process = null;
    _startFuture = null;
    final socket = _ipcSocket;
    _ipcSocket = null;
    _protocolOutput = null;

    try {
      await socket?.close();
    } catch (_) {
      // The worker may have already closed the IPC channel while exiting.
    }

    if (process != null) {
      try {
        await process.exitCode.timeout(shutdownTimeout);
      } on TimeoutException {
        process.kill();
        await process.exitCode;
      }
    }

    await _protocolSubscription?.cancel();
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    await _ipcServer?.close();
    _protocolSubscription = null;
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _ipcServer = null;
  }

  @override
  Stream<GenerationResponse> chat(ChatParam param) {
    return _callStream<GenerationResponse>(WorkerMethod.chat, param);
  }

  @override
  Future clearState() => _callFuture<dynamic>(WorkerMethod.clearState);

  @override
  Future<String> dumpLog() => _callFuture<String>(WorkerMethod.dumpLog);

  @override
  Future<String> dumpStateInfo() {
    return _callFuture<String>(WorkerMethod.dumpStateInfo);
  }

  @override
  Stream<GenerationResponse> generate(GenerationParam param) {
    return _callStream<GenerationResponse>(WorkerMethod.generate, param);
  }

  @override
  Stream<GenerationState> generationStateStream() {
    return _callStream<GenerationState>(WorkerMethod.generationStateStream);
  }

  @override
  Future<GenerationState> getGenerationState() {
    return _callFuture<GenerationState>(WorkerMethod.getGenerationState);
  }

  @override
  Future<String> getHtpArch() => _callFuture<String>(WorkerMethod.getHtpArch);

  @override
  Future<int> getSeed() => _callFuture<int>(WorkerMethod.getSeed);

  @override
  Future<String> getSocName() => _callFuture<String>(WorkerMethod.getSocName);

  @override
  Future init([InitParam? param]) =>
      _callFuture<dynamic>(WorkerMethod.init, param);

  @override
  Future loadInitialState(String statePath) {
    return _callFuture<dynamic>(WorkerMethod.loadInitialState, statePath);
  }

  @override
  Future<int> loadModel(LoadModelParam param) {
    return _callFuture<int>(WorkerMethod.loadModel, param);
  }

  @override
  Future release() async {
    if (_process == null && _startFuture == null) {
      return;
    }
    try {
      await _callFuture<dynamic>(WorkerMethod.release);
    } finally {
      await _shutdownProcess();
    }
  }

  @override
  Future<RunEvaluationResult> runEvaluation(RunEvaluationParam param) {
    return _callFuture<RunEvaluationResult>(WorkerMethod.runEvaluation, param);
  }

  @override
  Future setDecodeParam(DecodeParam param) {
    return _callFuture<dynamic>(WorkerMethod.setDecodeParam, param);
  }

  @override
  Future setImage(String path) {
    return _callFuture<dynamic>(WorkerMethod.setImage, path);
  }

  @override
  Future setImageId(String id) {
    return _callFuture<dynamic>(WorkerMethod.setImageId, id);
  }

  @override
  Future setLogLevel(RWKVLogLevel level) {
    return _callFuture<dynamic>(WorkerMethod.setLogLevel, level);
  }

  @override
  Future setSeed(int seed) {
    return _callFuture<dynamic>(WorkerMethod.setSeed, seed);
  }

  @override
  Future stopGenerate() => _callFuture<dynamic>(WorkerMethod.stopGenerate);

  @override
  Stream<List<double>> textToSpeech(TextToSpeechParam param) {
    return _callStream<List<double>>(WorkerMethod.textToSpeech, param);
  }
}
