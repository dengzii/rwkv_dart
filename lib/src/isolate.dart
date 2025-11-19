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

  RWKV? get callee => null;

  @override
  Future init([InitParam? param]) async {
    // init isolate
    ReceivePort receivePort = ReceivePort('rwkv_proxy_receive_port');
    events = receivePort.cast<IsolateMessage>().asBroadcastStream();
    await _IsolatedRWKV.spawn(receivePort.sendPort);
    final initMessage = await events.firstWhere((e) => e.isInitialMessage);
    sendPort = initMessage.param as SendPort;
    logd('isolate init done');

    // init runtime
    await _call(init, param);
  }

  dynamic _call(Function method, [dynamic param]) {
    final isStream = method.toString().contains('=> Stream');
    final isFuture = method.toString().contains('=> Future');
    final message = IsolateMessage.fromFunc(method, param);
    sendPort.send(message);
    if (isFuture) {
      return events.firstWhere((e) => e.id == message.id).then((e) {
        if (e.error != '') {
          throw Exception(e.error);
        }
        return e.param;
      });
    }
    if (isStream) {
      return events.where((e) => e.id == message.id).map((e) {
        if (e.error != '') {
          throw Exception(e.error);
        }
        return e.param;
      });
    }
    throw UnsupportedError('not supported, should be Future or Stream');
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
          loge(s);
          sendPort.send(message.copyWith(error: e.toString()));
        }
      },
      onError: (e) {
        loge(e);
      },
      onDone: () {
        logd('rwkv isolate receive port done');
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
        throw Exception(
          '😡 Unknown method: $method, did you register it in _ProxyCombinedMixin.getInterfaces()?',
        );
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
    setGenerateConfig,
    getGenerateState,
    generatingStateStream,
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
  Stream<String> chat(List<String> history) {
    return callee?.chat(history) ?? _call(chat, history).cast<String>();
  }

  @override
  Future clearState() {
    return callee?.clearState() ?? _call(clearState);
  }

  @override
  Stream<String> generate(String prompt) {
    if (callee != null) {
      return callee!.generate(prompt);
    }
    return _call(generate, prompt).cast<String>();
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
  Future setGenerateConfig(GenerateConfig param) {
    if (callee != null) {
      return callee!.setGenerateConfig(param);
    }
    return _call(setGenerateConfig, param);
  }

  @override
  Future<GenerateState> getGenerateState() async {
    if (callee != null) {
      return callee!.getGenerateState();
    }
    return await _call(getGenerateState);
  }

  @override
  Stream<GenerateState> generatingStateStream() {
    if (callee != null) {
      return callee!.generatingStateStream();
    }
    return _call(generatingStateStream).cast<GenerateState>();
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
