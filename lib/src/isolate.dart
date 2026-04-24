import 'dart:isolate';

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

  factory IsolateMessage._initialMessage(_SpawnMessage message) {
    return IsolateMessage(id: 'initial', method: 'init', param: message);
  }

  factory IsolateMessage.fromFunc(Function func, [dynamic param]) {
    _incrementId++;
    return IsolateMessage(
      id: '$_incrementId',
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

class _SpawnMessage {
  final SendPort sendPort;
  final RWKVFactory factory;

  _SpawnMessage({required this.sendPort, required this.factory});
}

class RWKVIsolateProxy with _ProxyCombinedMixin {
  late final SendPort sendPort;
  late final Stream<IsolateMessage> events;
  late final ReceivePort receivePort;
  late final Isolate isolate;

  @override
  RWKV? get callee => null;

  final RWKVFactory _factory;

  RWKVIsolateProxy(this._factory);

  @override
  Future init([InitParam? param]) async {
    // init isolate
    receivePort = ReceivePort('rwkv_proxy_receive_port');
    events = receivePort.cast<IsolateMessage>().asBroadcastStream();
    isolate = await _IsolatedRWKV.spawn(
      _SpawnMessage(sendPort: receivePort.sendPort, factory: _factory),
    );
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

  @override
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
  late final RWKV rwkv;

  late final SendPort sendPort;
  late final ReceivePort receivePort = ReceivePort('rwkv_isolate_receive_port');

  @override
  RWKV? get callee => rwkv;

  @override
  dynamic _call(Function method, [dynamic param]) {
    throw UnsupportedError('not supported');
  }

  _IsolatedRWKV._();

  static Future<Isolate> spawn(_SpawnMessage msg) async {
    final rwkvIsolate = _IsolatedRWKV._();
    final initialMessage = IsolateMessage._initialMessage(msg);
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
    final msg = init.param as _SpawnMessage;
    rwkv = msg.factory();
    sendPort = msg.sendPort;
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
      //
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

  dynamic _call(Function method, [dynamic param]) {
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
    dumpLog,
    loadInitialState,
    setDecodeParam,
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
    return callee?.chat(parma) ?? _call(chat, parma).cast<GenerationResponse>();
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
  Future setDecodeParam(DecodeParam param) {
    if (callee != null) {
      return callee!.setDecodeParam(param);
    }
    return _call(setDecodeParam, param);
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

}
