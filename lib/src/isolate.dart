import 'dart:isolate';

import 'package:rwkv_dart/src/backend.dart';
import 'package:rwkv_dart/src/logger.dart';
import 'package:rwkv_dart/src/rwkv.dart';

class IsolateMessage {
  final String id;
  final String method;
  final dynamic param;
  final String error;
  final bool done;

  static int _incrementId = 0;

  bool get isInitialMessage => id == 'initial';

  const IsolateMessage({
    required this.id,
    required this.method,
    required this.param,
    this.done = false,
    this.error = '',
  });

  factory IsolateMessage.initialMessage(SendPort sendPort) {
    return IsolateMessage(id: 'initial', method: 'init', param: sendPort);
  }

  factory IsolateMessage.fromFunc(Function func, [dynamic param]) {
    _incrementId++;
    return IsolateMessage(
      id: '${_incrementId}',
      method: func.toString(),
      param: param,
    );
  }

  IsolateMessage copyWith({
    String? id,
    String? method,
    dynamic param,
    bool? done,
    String? error,
  }) {
    return IsolateMessage(
      id: id ?? this.id,
      method: method ?? this.method,
      param: param ?? this.param,
      done: done ?? this.done,
      error: error ?? this.error,
    );
  }

  @override
  String toString() {
    return 'IsolateMessage{id: $id, method: $method, param: $param, done: $done, error: $error}';
  }
}

class RWKVIsolateProxy with _ProxyCombinedMixin {
  late final SendPort sendPort;
  late final Stream<IsolateMessage> events;
  late final ReceivePort receivePort;
  late final Isolate isolate;

  RWKV? get callee => null;

  @override
  Future init([InitParam? param]) async {
    // init isolate
    receivePort = ReceivePort('rwkv_proxy_receive_port');
    events = receivePort.cast<IsolateMessage>().asBroadcastStream();
    isolate = await _IsolatedRWKV.spawn(receivePort.sendPort);
    final initMessage = await events.firstWhere((e) => e.isInitialMessage);
    sendPort = initMessage.param as SendPort;
    logd('isolate proxy initialized');
    // init runtime
    await _call(init, param);
  }

  @override
  Future release() async {
    await _call(release);
    receivePort.close();
    events.cast().drain();
    isolate.kill();
    logd('rwkv isolate proxy released');
  }

  dynamic _call(Function method, [dynamic param]) {
    final isStream = method.toString().contains('=> Stream');
    final isFuture = method.toString().contains('=> Future');
    final message = IsolateMessage.fromFunc(method, param);
    sendPort.send(message);
    if (isFuture) {
      return events.firstWhere((e) => e.id == message.id).then((e) {
        if (e.error != '') {
          throw e.error;
        }
        return e.param;
      });
    }
    if (isStream) {
      final ret = events.where((e) => e.id == message.id);
      return _awaitStream(ret);
    }
    throw 'not supported, should be Future or Stream';
  }

  Stream _awaitStream(Stream<IsolateMessage> stream) async* {
    await for (var e in stream) {
      if (e.error != '') {
        throw e.error;
      }
      if (e.done) {
        break;
      }
      yield e.param;
    }
  }
}

class _IsolatedRWKV with _ProxyCombinedMixin {
  final Map<String, Function> handlers = {};
  late final RWKVBackend runtime = RWKVBackend();
  late final SendPort sendPort;
  late final ReceivePort receivePort = ReceivePort('rwkv_isolate_receive_port');

  RWKV? get callee => runtime;

  @override
  dynamic _call(Function method, [dynamic param]) {
    throw UnsupportedError('not supported');
  }

  _IsolatedRWKV._();

  static Future<Isolate> spawn(SendPort sendPort) async {
    final rwkvIsolate = _IsolatedRWKV._();
    final initialMessage = IsolateMessage.initialMessage(sendPort);
    final isolate = await Isolate.spawn<IsolateMessage>(
      rwkvIsolate._onIsolateSpawn,
      initialMessage,
    );
    return isolate;
  }

  @override
  Future release() async {
    await super.release();
    receivePort.close();
    logd('rwkv isolate released');
  }

  Future _onIsolateSpawn(IsolateMessage init) async {
    sendPort = init.param as SendPort;
    sendPort.send(init.copyWith(param: receivePort.sendPort));
    for (var func in interfaces) {
      handlers[func.toString()] = func;
    }
    receivePort.cast<IsolateMessage>().listen(
      (message) async {
        try {
          await _handleMessage(message.copyWith(error: '', done: false));
        } on NoSuchMethodError {
          final msg =
              'MethodInvocationError: method:${message.method}, param:${message.param}.';
          sendPort.send(message.copyWith(error: msg));
        } catch (e, s) {
          loge(e);
          loge(s);
          sendPort.send(message.copyWith(error: e.toString()));
        }
      },
      onError: (e) {
        loge(e);
      },
      onDone: () {
        logd('rwkv isolate receive port closed');
      },
    );
  }

  Future _handleMessage(IsolateMessage message) async {
    final method = message.method;
    final param = message.param;

    dynamic res;
    if (message.isInitialMessage) {
      sendPort = param as SendPort;
      sendPort.send(message.copyWith(param: receivePort.sendPort));
    } else {
      final handler = handlers[method];
      if (handler == null) {
        throw 'Unknown isolate func: $method, did you register it in _ProxyCombinedMixin.getInterfaces()?';
      }
      res = param == null ? handler() : handler(param);
    }
    if (res is Future) {
      res = await res;
      sendPort.send(message.copyWith(param: res));
    } else if (res is Stream) {
      res.listen(
        (event) {
          sendPort.send(message.copyWith(param: event));
        },
        onDone: () {
          sendPort.send(message.copyWith(done: true));
        },
        onError: (e) {
          sendPort.send(message.copyWith(error: e.toString()));
        },
      );
    } else {
      sendPort.send(message.copyWith(param: res));
    }
  }
}

mixin _ProxyCombinedMixin implements RWKV {
  RWKV? get callee {
    throw UnimplementedError("override me");
  }

  _call(Function method, [dynamic param]) {
    throw UnimplementedError("override me");
  }

  Set<Function> get interfaces => {
    init,
    setLogLevel,
    loadModel,
    chat,
    clearState,
    generate,
    release,
    getHtpArch,
    dumpStateInfo,
    dumpLog,
    getSocName,
    loadInitialState,
    textToSpeech,
    setImage,
    setDecodeParam,
    setGenerationConfig,
    getGenerationState,
    generationStateStream,
    stopGenerate,
    getSeed,
    setSeed,
  };

  @override
  Future init([InitParam? param]) async {
    return callee?.init(param) ?? _call(init, param);
  }

  @override
  Future setLogLevel(RWKVLogLevel level) {
    return callee?.setLogLevel(level) ?? _call(setLogLevel, level);
  }

  @override
  Future<int> loadModel(LoadModelParam param) async {
    if (callee != null) {
      return callee!.loadModel(param);
    }
    return await _call(loadModel, param);
  }

  @override
  Stream<GenerationResponse> chat(ChatParam parma) {
    return callee?.chat(parma) ??
        _call(chat, parma).cast<GenerationResponse>();
  }

  @override
  Future clearState() {
    return callee?.clearState() ?? _call(clearState);
  }

  @override
  Stream<GenerationResponse> generate(GenerationParam param) {
    if (callee != null) {
      return callee!.generate(param);
    }
    return _call(generate, param).cast<GenerationResponse>();
  }

  @override
  Future setImage(String path) {
    if (callee != null) {
      return callee!.setImage(path);
    }
    return _call(setImage, path);
  }

  @override
  Future setDecodeParam(DecodeParam param) {
    if (callee != null) {
      return callee!.setDecodeParam(param);
    }
    return _call(setDecodeParam, param);
  }

  @override
  Future setGenerationConfig(GenerationConfig param) {
    if (callee != null) {
      return callee!.setGenerationConfig(param);
    }
    return _call(setGenerationConfig, param);
  }

  @override
  Future<GenerationState> getGenerationState() async {
    if (callee != null) {
      return callee!.getGenerationState();
    }
    return await _call(getGenerationState);
  }

  @override
  Stream<GenerationState> generationStateStream() {
    if (callee != null) {
      return callee!.generationStateStream();
    }
    return _call(generationStateStream).cast<GenerationState>();
  }

  @override
  Future stopGenerate() {
    if (callee != null) {
      return callee!.stopGenerate();
    }
    return _call(stopGenerate);
  }

  @override
  Future loadInitialState(String path) {
    if (callee != null) {
      return callee!.loadInitialState(path);
    }
    return _call(loadInitialState, path);
  }

  @override
  Future release() {
    return callee?.release() ?? _call(release);
  }

  @override
  Future<String> dumpLog() async {
    if (callee != null) {
      return callee!.dumpLog();
    }
    return await _call(dumpLog);
  }

  @override
  Future<String> getHtpArch() async {
    if (callee != null) {
      return callee!.getHtpArch();
    }
    return await _call(getHtpArch);
  }

  @override
  Future<String> getSocName() async {
    if (callee != null) {
      return callee!.getSocName();
    }
    return await _call(getSocName);
  }

  @override
  Future<int> getSeed() async {
    if (callee != null) {
      return callee!.getSeed();
    }
    return await _call(getSeed);
  }

  @override
  Future setSeed(int seed) {
    return callee?.setSeed(seed) ?? _call(setSeed, seed);
  }

  @override
  Future<RunEvaluationResult> runEvaluation(RunEvaluationParam param) async {
    if (callee != null) {
      return callee!.runEvaluation(param);
    }
    return await _call(runEvaluation, param);
  }

  @override
  Future<String> dumpStateInfo() async {
    if (callee != null) {
      return callee!.dumpStateInfo();
    }
    return await _call(dumpStateInfo);
  }

  @override
  Future setImageId(String id) {
    if (callee != null) {
      return callee!.setImageId(id);
    }
    return _call(setImageId, id);
  }

  @override
  Stream<List<double>> textToSpeech(TextToSpeechParam param) {
    if (callee != null) {
      return callee!.textToSpeech(param);
    }
    return _call(textToSpeech, param).cast<List<double>>();
  }
}
