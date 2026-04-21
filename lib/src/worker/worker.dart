import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rwkv_dart/src/rwkv.dart';
import 'package:rwkv_dart/src/worker/serialize.dart';

class WorkerIPC {
  final RWKV rwkv;
  final Stream<List<int>> input;
  final IOSink output;

  StreamSubscription<String>? _subscription;
  final Completer<void> _done = Completer<void>();
  final Map<String, StreamSubscription<dynamic>> _streamSubscriptions = {};
  bool _closed = false;

  WorkerIPC(this.rwkv, {Stream<List<int>>? input, IOSink? output})
    : input = input ?? stdin,
      output = output ?? stdout;

  Future<void> start() {
    _subscription = input
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: (Object error, StackTrace stackTrace) {
            _send(WorkerMessage(id: '', method: '', error: '$error'));
          },
          onDone: _complete,
          cancelOnError: false,
        );
    return _done.future;
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }

    () async {
      WorkerMessage? message;
      try {
        message = WorkerMessage.fromLine(line);
        await _handleMessage(message);
      } catch (e, s) {
        stderr.writeln(e);
        stderr.writeln(s);
        await _send(
          (message ?? const WorkerMessage(id: '', method: '')).copyWith(
            error: e.toString(),
          ),
        );
      }
    }();
  }

  Future<void> _handleMessage(WorkerMessage message) async {
    if (message.method == WorkerMethod.cancelStream) {
      await _cancelStream(message);
      return;
    }

    final result = _invoke(message.method, message.param);
    if (result is Stream) {
      late final StreamSubscription<dynamic> subscription;
      subscription = result.listen(
        (event) {
          _send(message.copyWith(param: event));
        },
        onError: (Object error, StackTrace stackTrace) {
          _streamSubscriptions.remove(message.id);
          stderr.writeln(error);
          stderr.writeln(stackTrace);
          _send(message.copyWith(error: error.toString(), done: true));
        },
        onDone: () {
          _streamSubscriptions.remove(message.id);
          _send(message.copyWith(param: null, done: true));
        },
        cancelOnError: true,
      );
      _streamSubscriptions[message.id] = subscription;
      return;
    }

    final response = result is Future ? await result : result;
    await _send(message.copyWith(param: response));
    if (message.method == WorkerMethod.release) {
      await close();
    }
  }

  Future<void> _cancelStream(WorkerMessage message) async {
    final streamId = message.param?.toString() ?? '';
    final subscription = _streamSubscriptions.remove(streamId);
    await subscription?.cancel();
    await _send(message.copyWith(param: subscription != null, done: true));
  }

  dynamic _invoke(String method, dynamic param) {
    switch (method) {
      case WorkerMethod.init:
        return rwkv.init(param as InitParam?);
      case WorkerMethod.setLogLevel:
        return rwkv.setLogLevel(param as RWKVLogLevel);
      case WorkerMethod.loadModel:
        return rwkv.loadModel(param as LoadModelParam);
      case WorkerMethod.chat:
        return rwkv.chat(param as ChatParam);
      case WorkerMethod.clearState:
        return rwkv.clearState();
      case WorkerMethod.generate:
        return rwkv.generate(param as GenerationParam);
      case WorkerMethod.release:
        return rwkv.release();
      case WorkerMethod.getHtpArch:
        return rwkv.getHtpArch();
      case WorkerMethod.dumpStateInfo:
        return rwkv.dumpStateInfo();
      case WorkerMethod.dumpLog:
        return rwkv.dumpLog();
      case WorkerMethod.getSocName:
        return rwkv.getSocName();
      case WorkerMethod.loadInitialState:
        return rwkv.loadInitialState(param as String);
      case WorkerMethod.textToSpeech:
        return rwkv.textToSpeech(param as TextToSpeechParam);
      case WorkerMethod.setImage:
        return rwkv.setImage(param as String);
      case WorkerMethod.setDecodeParam:
        return rwkv.setDecodeParam(param as DecodeParam);
      case WorkerMethod.getGenerationState:
        return rwkv.getGenerationState();
      case WorkerMethod.generationStateStream:
        return rwkv.generationStateStream();
      case WorkerMethod.stopGenerate:
        return rwkv.stopGenerate();
      case WorkerMethod.getSeed:
        return rwkv.getSeed();
      case WorkerMethod.setSeed:
        return rwkv.setSeed(param as int);
      case WorkerMethod.setImageId:
        return rwkv.setImageId(param as String);
      case WorkerMethod.runEvaluation:
        return rwkv.runEvaluation(param as RunEvaluationParam);
      default:
        throw UnsupportedError('Unknown worker method: $method');
    }
  }

  Future<void> _send(WorkerMessage message) async {
    if (_closed) {
      return;
    }
    output.writeln(message.toLine());
    await output.flush();
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final subscription in _streamSubscriptions.values) {
      await subscription.cancel();
    }
    _streamSubscriptions.clear();
    await _subscription?.cancel();
    _complete();
  }

  void _complete() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

class Worker implements RWKV {
  final RWKV _instance;

  Worker(this._instance);

  @override
  Stream<GenerationResponse> chat(ChatParam param) => _instance.chat(param);

  @override
  Future clearState() => _instance.clearState();

  @override
  Future<String> dumpLog() => _instance.dumpLog();

  @override
  Future<String> dumpStateInfo() => _instance.dumpStateInfo();

  @override
  Stream<GenerationResponse> generate(GenerationParam param) {
    return _instance.generate(param);
  }

  @override
  Stream<GenerationState> generationStateStream() {
    return _instance.generationStateStream();
  }

  @override
  Future<GenerationState> getGenerationState() =>
      _instance.getGenerationState();

  @override
  Future<String> getHtpArch() => _instance.getHtpArch();

  @override
  Future<int> getSeed() => _instance.getSeed();

  @override
  Future<String> getSocName() => _instance.getSocName();

  @override
  Future init([InitParam? param]) => _instance.init(param);

  @override
  Future loadInitialState(String statePath) {
    return _instance.loadInitialState(statePath);
  }

  @override
  Future<int> loadModel(LoadModelParam param) => _instance.loadModel(param);

  @override
  Future release() => _instance.release();

  @override
  Future<RunEvaluationResult> runEvaluation(RunEvaluationParam param) {
    return _instance.runEvaluation(param);
  }

  @override
  Future setDecodeParam(DecodeParam param) => _instance.setDecodeParam(param);

  @override
  Future setImage(String path) => _instance.setImage(path);

  @override
  Future setImageId(String id) => _instance.setImageId(id);

  @override
  Future setLogLevel(RWKVLogLevel level) => _instance.setLogLevel(level);

  @override
  Future setSeed(int seed) => _instance.setSeed(seed);

  @override
  Future stopGenerate() => _instance.stopGenerate();

  @override
  Stream<List<double>> textToSpeech(TextToSpeechParam param) {
    return _instance.textToSpeech(param);
  }
}
