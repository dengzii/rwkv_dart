import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';
import 'package:rwkv_dart/src/logger.dart';
import 'package:rwkv_dart/src/rwkv.dart';
import 'package:rwkv_dart/src/utils.dart';

import 'rwkv_mobile_ffi.dart';

enum ErrorFlag {
  SUCCESS(0),
  ERROR_IO(1 << 0),
  ERROR_INIT(1 << 1),
  ERROR_EVAL(1 << 2),
  ERROR_INVALID_PARAMETERS(1 << 3),
  ERROR_BACKEND(1 << 4),
  ERROR_MODEL(1 << 5),
  ERROR_TOKENIZER(1 << 6),
  ERROR_SAMPLER(1 << 7),
  ERROR_RUNTIME(1 << 8),
  ERROR_UNSUPPORTED(1 << 9),
  ERROR_ALLOC(1 << 10),
  ERROR_RELEASE(1 << 11);

  final int code;

  const ErrorFlag(this.code);

  static List<ErrorFlag> fromRetVal(int value) {
    final errors = <ErrorFlag>[];
    for (var e in values) {
      if ((value & e.code) != 0) {
        errors.add(e);
      }
    }
    final code = errors.map((e) => e.code).reduce((a, b) => a | b);
    // check if all errors are included
    if (code != value) {
      return [];
    }
    return errors;
  }
}

extension _ on String {
  ffi.Pointer<ffi.Char> toNativeChar() => toNativeUtf8().cast<ffi.Char>();

  ffi.Pointer<ffi.Void> toNativeVoid() => toNativeUtf8().cast<ffi.Void>();
}

extension __ on ffi.Pointer<ffi.Char> {
  String toDartString() => cast<Utf8>().toDartString();
}

class RWKVBackend implements RWKV {
  late final String dynamicLibraryDir;
  late final RWKVLogLevel logLevel;
  late final rwkv_mobile _rwkv;

  ffi.Pointer<ffi.Void> _handlerPtr = ffi.nullptr;
  final _utf8codec = Utf8Codec(allowMalformed: true);
  int _lastGenerationAt = 0;
  int _generationPosition = 0;
  int _modelId = 0;

  GenerateConfig generationParam = GenerateConfig.initial();
  GenerateState generationState = GenerateState.initial();
  StreamController<GenerateState> _controllerGenerationState =
      StreamController.broadcast();

  RWKVBackend();

  ffi.DynamicLibrary _loadDynamicLib() {
    ffi.DynamicLibrary openDynamicLib(String file) =>
        ffi.DynamicLibrary.open('$dynamicLibraryDir$file');

    if (Platform.isAndroid) return openDynamicLib('librwkv_mobile.so');
    if (Platform.isIOS) return ffi.DynamicLibrary.process();
    if (Platform.isMacOS) {
      return openDynamicLib('librwkv_mobile.dylib');
    }
    if (Platform.isWindows) {
      final abi = ffi.Abi.current();
      if (abi == ffi.Abi.windowsX64) {
        return openDynamicLib('rwkv_mobile.dll');
      }
      if (abi == ffi.Abi.windowsArm64) {
        return openDynamicLib('rwkv_mobile-arm64.dll');
      }
      throw Exception('Unsupported ABI: ${abi.toString()}');
    }
    if (Platform.isLinux) {
      final abi = ffi.Abi.current();
      if (abi == ffi.Abi.linuxX64) {
        return openDynamicLib('librwkv_mobile-linux-x86_64.so');
      }
      if (abi == ffi.Abi.linuxArm64) {
        return openDynamicLib('librwkv_mobile-linux-aarch64.so');
      }
      throw Exception('Unsupported ABI: ${abi.toString()}');
    }
    throw Exception('Unsupported platform');
  }

  Future init([InitParam? param]) async {
    dynamicLibraryDir = param?.dynamicLibDir ?? '';
    logLevel = param?.logLevel ?? RWKVLogLevel.error;
    setLogLevel(
      {
        RWKVLogLevel.verbose: Level.ALL,
        RWKVLogLevel.info: Level.CONFIG,
        RWKVLogLevel.debug: Level.INFO,
        RWKVLogLevel.warning: Level.WARNING,
        RWKVLogLevel.error: Level.SEVERE,
      }[logLevel]!,
    );

    _rwkv = rwkv_mobile(_loadDynamicLib());
    _rwkv.rwkvmobile_set_loglevel(logLevel.index);

    _handlerPtr = _rwkv.rwkvmobile_runtime_init();
    if (_handlerPtr == ffi.nullptr) {
      throw Exception('Failed to initialize RWKV backend');
    }
    logd('ffi initialized');
  }

  @override
  Future<int> loadModel(LoadModelParam param) async {
    String modelPath = param.modelPath;
    if (modelPath.endsWith(".zip")) {
      modelPath = modelPath.substring(0, modelPath.lastIndexOf('.zip'));
      await Utils.unzip(modelPath);
    }

    final backendName = param.backend.name.toNativeChar();

    if (param.backend == Backend.qnn) {
      final tempDir = param.qnnLibDir;
      if (tempDir == null) {
        throw Exception('qnnLibDir is not set');
      }
      _rwkv.rwkvmobile_runtime_set_qnn_library_path(
        _handlerPtr,
        '$tempDir/assets/lib/'.toNativeChar(),
      );
      _modelId = _rwkv.rwkvmobile_runtime_load_model_with_extra(
        _handlerPtr,
        modelPath.toNativeChar(),
        backendName,
        param.tokenizerPath.toNativeChar(),
        '$tempDir/assets/lib/libQnnHtp.so'.toNativeVoid(),
      );
    } else {
      _modelId = _rwkv.rwkvmobile_runtime_load_model(
        _handlerPtr,
        modelPath.toNativeChar(),
        backendName,
        param.tokenizerPath.toNativeChar(),
      );
    }
    if (_modelId < 0) {
      throw Exception('Failed to load model');
    }
    logd('model loaded');
    return _modelId;
  }

  Future<String> dumpLog() async {
    final log = _rwkv.rwkvmobile_dump_log().toDartString();
    return log;
  }

  @override
  Stream<String> chat(List<String> history) {
    _lastGenerationAt = DateTime.now().millisecondsSinceEpoch;

    ffi.Pointer<ffi.Pointer<ffi.Char>> inputsPtr = calloc
        .allocate<ffi.Pointer<ffi.Char>>(1000);
    for (var i = 0; i < history.length; i++) {
      inputsPtr[i] = history[i].toNativeChar();
    }
    final numInputs = history.length;

    _checkGenerateState();

    final retVal = _rwkv.rwkvmobile_runtime_eval_chat_with_history_async(
      _handlerPtr,
      _modelId,
      inputsPtr,
      numInputs,
      generationParam.maxTokens,
      ffi.nullptr,
      generationParam.chatReasoning ? 1 : 0,
    );
    _tryThrowErrorRetVal(retVal);

    final isResume = history.length % 2 == 0;
    return _generationResultPolling(resume: isResume);
  }

  @override
  Future clearState() async {
    final retVal = _rwkv.rwkvmobile_runtime_clear_state(_handlerPtr, _modelId);
    _tryThrowErrorRetVal(retVal);
  }

  @override
  Stream<String> generate(String prompt) {
    _lastGenerationAt = DateTime.now().millisecondsSinceEpoch;

    _checkGenerateState();

    final retVal = _rwkv.rwkvmobile_runtime_gen_completion_async(
      _handlerPtr,
      _modelId,
      prompt.toNativeChar(),
      generationParam.maxTokens,
      generationParam.completionStopToken,
      ffi.nullptr,
    );
    _tryThrowErrorRetVal(retVal);

    return _generationResultPolling();
  }

  @override
  Future setAudio(String path) async {
    final retVal = _rwkv.rwkvmobile_runtime_set_audio_prompt(
      _handlerPtr,
      _modelId,
      path.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);
  }

  @override
  Future setImage(String path) async {
    throw Exception('Not implemented');
  }

  @override
  Future setDecodeParam(DecodeParam param) async {
    _rwkv.rwkvmobile_runtime_set_sampler_params(
      _handlerPtr,
      _modelId,
      param.toNativeSamplerParam(),
    );
    _rwkv.rwkvmobile_runtime_set_penalty_params(
      _handlerPtr,
      _modelId,
      param.toNativePenaltyParam(),
    );
  }

  @override
  Future setGenerateConfig(GenerateConfig param) async {
    this.generationParam = param;

    int retVal = _rwkv.rwkvmobile_runtime_set_prompt(
      _handlerPtr,
      _modelId,
      generationParam.prompt.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);

    if (param.eosToken != null) {
      retVal = _rwkv.rwkvmobile_runtime_set_eos_token(
        _handlerPtr,
        _modelId,
        param.eosToken!.toNativeChar(),
      );
      _tryThrowErrorRetVal(retVal);
    }
    if (param.bosToken != null) {
      retVal = _rwkv.rwkvmobile_runtime_set_bos_token(
        _handlerPtr,
        _modelId,
        param.bosToken!.toNativeChar(),
      );
      _tryThrowErrorRetVal(retVal);
    }

    if (param.tokenBanned.isNotEmpty) {
      final ptr = calloc.allocate<ffi.Int>(param.tokenBanned.length);
      for (var i = 0; i < param.tokenBanned.length; i++) {
        ptr[i] = param.tokenBanned[i];
      }
      retVal = _rwkv.rwkvmobile_runtime_set_token_banned(
        _handlerPtr,
        _modelId,
        ptr,
        param.tokenBanned.length,
      );
      _tryThrowErrorRetVal(retVal);
    }

    retVal = _rwkv.rwkvmobile_runtime_set_user_role(
      _handlerPtr,
      _modelId,
      param.userRole.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);

    retVal = _rwkv.rwkvmobile_runtime_set_response_role(
      _handlerPtr,
      _modelId,
      param.assistantRole.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);

    retVal = _rwkv.rwkvmobile_runtime_set_thinking_token(
      _handlerPtr,
      _modelId,
      generationParam.thinkingToken.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);
  }

  @override
  Stream<GenerateState> generatingStateStream() =>
      _controllerGenerationState.stream;

  @override
  Future<GenerateState> getGenerateState() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - generationState.timestamp > 100) {
      _updateTextGenerationState();
    }
    return generationState;
  }

  @override
  Future stopGenerate() async {
    await Future.doWhile(() async {
      final retVal = _rwkv.rwkvmobile_runtime_stop_generation(
        _handlerPtr,
        _modelId,
      );
      _tryThrowErrorRetVal(retVal);
      await Future.delayed(Duration(milliseconds: 50));
      _updateTextGenerationState();
      return !generationState.isGenerating;
    }).timeout(Duration(seconds: 5));
  }

  @override
  Future release() async {
    final retVal = _rwkv.rwkvmobile_runtime_release(_handlerPtr);
    _tryThrowErrorRetVal(retVal);
    _handlerPtr = ffi.nullptr;
  }

  Stream<String> _generationResultPolling({bool resume = false}) {
    final generationId = _lastGenerationAt;
    if (!resume) {
      _generationPosition = 0;
    }
    return Stream.periodic(const Duration(milliseconds: 20))
        .map((e) {
          if (generationId != _lastGenerationAt) {
            throw Exception('stopped due to generationId changed');
          }
          _updateTextGenerationState();
          final resp = _rwkv.rwkvmobile_runtime_get_response_buffer_content(
            _handlerPtr,
            _modelId,
          );
          if (resp.length == 0) {
            return '';
          }
          final bytes = resp.content
              .cast<ffi.Uint8>()
              .asTypedList(resp.length)
              .sublist(_generationPosition);

          if (!generationParam.returnWholeGeneratedResult) {
            _generationPosition = resp.length;
          }
          return _utf8codec.decode(bytes);
        })
        .takeWhile((_) => generationState.isGenerating)
        .where((e) => e != '');
  }

  void _checkGenerateState() {
    if (_rwkv.rwkvmobile_runtime_is_generating(_handlerPtr, _modelId) != 0) {
      throw Exception('LLM is already generating');
    }
  }

  void _tryThrowErrorRetVal(int retVal) {
    if (retVal == ErrorFlag.SUCCESS.code) {
      return;
    }
    final errors = ErrorFlag.fromRetVal(retVal);
    if (errors.isEmpty) {
      throw Exception('non-zero return value: $retVal');
    }
    throw Exception('runtime error: ${errors.join(' | ')}');
  }

  GenerateState _updateTextGenerationState() {
    final prefillSpeed = _rwkv.rwkvmobile_runtime_get_avg_prefill_speed(
      _handlerPtr,
      _modelId,
    );
    final decodeSpeed = _rwkv.rwkvmobile_runtime_get_avg_decode_speed(
      _handlerPtr,
      _modelId,
    );
    final prefillProgress = _rwkv.rwkvmobile_runtime_get_prefill_progress(
      _handlerPtr,
      _modelId,
    );
    final isGenerating =
        _rwkv.rwkvmobile_runtime_is_generating(_handlerPtr, _modelId) != 0;
    final state = GenerateState(
      isGenerating: isGenerating,
      prefillProgress: prefillProgress,
      prefillSpeed: prefillSpeed,
      decodeSpeed: decodeSpeed,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    if (!state.equals(generationState)) {
      _controllerGenerationState.add(state);
    }
    generationState = state;
    return state;
  }

  @override
  Future loadInitialState(String path) async {
    final retVal = _rwkv.rwkvmobile_runtime_load_initial_state(
      _handlerPtr,
      _modelId,
      path.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);
  }

  @override
  Future<String> getHtpArch() async {
    final ptr = _rwkv.rwkvmobile_get_htp_arch();
    return ptr.toDartString();
  }

  @override
  Future<String> getSocName() async {
    final ptr = _rwkv.rwkvmobile_get_soc_name();
    return ptr.toDartString();
  }
}
