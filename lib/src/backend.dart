import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:rwkv_dart/src/logger.dart';
import 'package:rwkv_dart/src/rwkv.dart';
import 'package:rwkv_dart/src/utils.dart';

import 'rwkv_mobile_ffi.dart';

const RWKV_SUCCESS = 0;
const RWKV_ERROR_IO = 1 << 0;
const RWKV_ERROR_INIT = 1 << 1;
const RWKV_ERROR_EVAL = 1 << 2;
const RWKV_ERROR_INVALID_PARAMETERS = 1 << 3;
const RWKV_ERROR_BACKEND = 1 << 4;
const RWKV_ERROR_MODEL = 1 << 5;
const RWKV_ERROR_TOKENIZER = 1 << 6;
const RWKV_ERROR_SAMPLER = 1 << 7;
const RWKV_ERROR_RUNTIME = 1 << 8;
const RWKV_ERROR_UNSUPPORTED = 1 << 9;
const RWKV_ERROR_ALLOC = 1 << 10;
const RWKV_ERROR_RELEASE = 1 << 11;

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

  GenerationParam generationParam = GenerationParam.initial();
  TextGenerationState generationState = TextGenerationState.initial();
  StreamController<TextGenerationState> _controllerGenerationState =
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

    _rwkv = rwkv_mobile(_loadDynamicLib());
    _rwkv.rwkvmobile_set_loglevel(logLevel.index);

    if (param?.initBackend == true) {
      final r = Backend.webRwkv.asArgument.toNativeChar();
      _handlerPtr = _rwkv.rwkvmobile_runtime_init_with_name(r);
    }

    logDebug('ffi initialized');
  }

  @override
  Future initBackend(InitBackendParam param) async {
    if (_handlerPtr.address != 0) {
      final retVal = _rwkv.rwkvmobile_runtime_release(_handlerPtr);
      _tryThrowErrorRetVal(retVal);
      logDebug('release runtime');
      _handlerPtr = ffi.nullptr;
    }
    String modelPath = param.modelPath;
    final backendName = param.backend.asArgument.toNativeChar();
    switch (param.backend) {
      case Backend.ncnn:
      case Backend.llamacpp:
      case Backend.webRwkv:
      case Backend.mnn:
      case Backend.coreml:
        _handlerPtr = _rwkv.rwkvmobile_runtime_init_with_name(backendName);
        break;
      case Backend.qnn:
        // TODO: better solution for this
        final tempDir = '';

        _handlerPtr = _rwkv.rwkvmobile_runtime_init_with_name_extra(
          backendName,
          (tempDir + '/assets/lib/libQnnHtp.so').toNativeVoid(),
        );
        _rwkv.rwkvmobile_runtime_set_qnn_library_path(
          _handlerPtr,
          (tempDir + '/assets/lib/').toNativeChar(),
        );
    }
    if (_handlerPtr.address == 0) {
      throw Exception('failed to initialize runtime');
    }
    var retVal = _rwkv.rwkvmobile_runtime_load_tokenizer(
      _handlerPtr,
      param.tokenizerPath.toNativeChar(),
    );

    _tryThrowErrorRetVal(retVal);
    logDebug('tokenizer loaded');

    if (modelPath.endsWith(".zip")) {
      modelPath = modelPath.substring(0, modelPath.lastIndexOf('.zip'));
      await Utils.unzip(modelPath);
    }

    retVal = _rwkv.rwkvmobile_runtime_load_model(
      _handlerPtr,
      modelPath.toNativeChar(),
    );

    _tryThrowErrorRetVal(retVal);
    logDebug('model loaded');
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
    final retVal = _rwkv.rwkvmobile_runtime_clear_state(_handlerPtr);
    _tryThrowErrorRetVal(retVal);
  }

  @override
  Stream<String> completion(String prompt) {
    _lastGenerationAt = DateTime.now().millisecondsSinceEpoch;

    _checkGenerateState();

    final retVal = _rwkv.rwkvmobile_runtime_gen_completion_async(
      _handlerPtr,
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
      path.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);
  }

  @override
  Future setImage(String path) async {
    final retVal = _rwkv.rwkvmobile_runtime_set_image_prompt(
      _handlerPtr,
      path.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);
  }

  @override
  Future setPenaltyParam(PenaltyParam param) async {
    _rwkv.rwkvmobile_runtime_set_penalty_params(
      _handlerPtr,
      param.toFfiParam(),
    );
  }

  @override
  Future setSamplerParam(SamplerParam param) async {
    _rwkv.rwkvmobile_runtime_set_sampler_params(
      _handlerPtr,
      param.toFfiParam(),
    );
  }

  @override
  Future setGenerationParam(GenerationParam param) async {
    this.generationParam = param;

    int retVal = _rwkv.rwkvmobile_runtime_set_prompt(
      _handlerPtr,
      generationParam.prompt.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);

    retVal = _rwkv.rwkvmobile_runtime_set_thinking_token(
      _handlerPtr,
      generationParam.thinkingToken.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);
  }

  @override
  Stream<TextGenerationState> generationStateChangeStream() =>
      _controllerGenerationState.stream;

  @override
  Future<TextGenerationState> getGenerationState() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - generationState.timestamp > 100) {
      _updateTextGenerationState();
    }
    return generationState;
  }

  @override
  Future stopGeneration() async {
    final retVal = _rwkv.rwkvmobile_runtime_stop_generation(_handlerPtr);
    _tryThrowErrorRetVal(retVal);
    await Future.delayed(Duration(milliseconds: 50));
    _updateTextGenerationState();
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
    if (_rwkv.rwkvmobile_runtime_is_generating(_handlerPtr) != 0) {
      throw Exception('LLM is already generating');
    }
  }

  void _tryThrowErrorRetVal(int retVal) {
    if (retVal == RWKV_ERROR_INVALID_PARAMETERS) {
      throw Exception('invalid param');
    }
    if (retVal != 0) {
      throw Exception('non-zero return value: $retVal');
    }
  }

  TextGenerationState _updateTextGenerationState() {
    final prefillSpeed = _rwkv.rwkvmobile_runtime_get_avg_prefill_speed(
      _handlerPtr,
    );
    final decodeSpeed = _rwkv.rwkvmobile_runtime_get_avg_decode_speed(
      _handlerPtr,
    );
    final prefillProgress = _rwkv.rwkvmobile_runtime_get_prefill_progress(
      _handlerPtr,
    );
    final isGenerating =
        _rwkv.rwkvmobile_runtime_is_generating(_handlerPtr) != 0;
    final state = TextGenerationState(
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
}
