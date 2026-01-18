import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';
import 'package:rwkv_dart/src/logger.dart';
import 'package:rwkv_dart/src/rwkv.dart';

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

enum GenerationType { TEXT, TTS, IMAGE }

extension _ on String {
  ffi.Pointer<ffi.Char> toNativeChar() => toNativeUtf8().cast<ffi.Char>();

  ffi.Pointer<ffi.Void> toNativeVoid() => toNativeUtf8().cast<ffi.Void>();
}

extension __ on ffi.Pointer<ffi.Char> {
  String toDartString() => cast<Utf8>().toDartString();
}

extension ___ on DecodeParam {
  toNativeSamplerParam() => Struct.create<sampler_params>()
    ..temperature = temperature
    ..top_k = topK
    ..top_p = topP;

  toNativePenaltyParam() => Struct.create<penalty_params>()
    ..presence_penalty = presencePenalty
    ..frequency_penalty = frequencyPenalty
    ..penalty_decay = penaltyDecay;
}

class RWKVBackend implements RWKV {
  final _utf8codec = Utf8Codec(allowMalformed: true);

  late final String dynamicLibraryDir;
  late final rwkv_mobile _rwkv;

  ffi.Pointer<ffi.Void> _handle = ffi.nullptr;

  RWKVLogLevel logLevel = RWKVLogLevel.error;
  int _lastGenerationAt = 0;
  int _generationPosition = 0;
  int _generatedTTSLen = 0;
  int _modelId = -1;
  String? _qnnLibDir;

  GenerationConfig generationParam = GenerationConfig.initial();
  DecodeParam decodeParam = DecodeParam.initial();
  GenerationState generationState = GenerationState.initial();
  StreamController<GenerationState> _controllerGenerationState =
      StreamController.broadcast();

  RWKVBackend([String? _]);

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

    _qnnLibDir = param?.qnnLibDir;
    _rwkv = rwkv_mobile(_loadDynamicLib());

    await setLogLevel(param?.logLevel ?? RWKVLogLevel.error);

    _handle = _rwkv.rwkvmobile_runtime_init();
    if (_handle == ffi.nullptr) {
      throw Exception('Failed to initialize RWKV backend');
    }
    ffi.Pointer<ffi.Char> ptr = malloc.allocate<ffi.Char>(64);
    final retVal = _rwkv.rwkvmobile_runtime_get_available_backend_names(
      ptr,
      64,
    );
    _tryThrowErrorRetVal(retVal);
    final names = ptr.cast<Utf8>().toDartString();
    logd('ffi initialized, available backend: $names');
  }

  @override
  Future setLogLevel(RWKVLogLevel level) async {
    logLevel = level;
    Logger.root.level = {
      RWKVLogLevel.verbose: Level.ALL,
      RWKVLogLevel.info: Level.CONFIG,
      RWKVLogLevel.debug: Level.INFO,
      RWKVLogLevel.warning: Level.WARNING,
      RWKVLogLevel.error: Level.SEVERE,
    }[logLevel]!;
    _rwkv.rwkvmobile_set_loglevel(logLevel.index);
    logd('log level set to $logLevel');
  }

  @override
  Future<int> loadModel(LoadModelParam param) async {
    if (_modelId != -1) {
      final retVal = _rwkv.rwkvmobile_runtime_release_model(_handle, _modelId);
      _tryThrowErrorRetVal(retVal);
      _modelId = -1;
    }

    String modelPath = param.modelPath;

    final backend = Backend.fromModelPath(param.modelPath);
    if (backend == null) {
      throw Exception(
        'auto detect backend failed for $modelPath, please specify backend explicitly',
      );
    }

    final backendName = backend.name.toNativeChar();

    if (param.backend == Backend.qnn) {
      final qnnLibs = _qnnLibDir;
      if (qnnLibs == null || qnnLibs.isEmpty) {
        throw Exception(
          'qnn libs is required when using qnn backend, set it in InitParam',
        );
      }
      _rwkv.rwkvmobile_runtime_set_qnn_library_path(
        _handle,
        qnnLibs.toNativeChar(),
      );
      _modelId = _rwkv.rwkvmobile_runtime_load_model_with_extra(
        _handle,
        modelPath.toNativeChar(),
        backendName,
        param.tokenizerPath.toNativeChar(),
        '$qnnLibs/libQnnHtp.so'.toNativeVoid(),
      );
    } else {
      _modelId = _rwkv.rwkvmobile_runtime_load_model(
        _handle,
        modelPath.toNativeChar(),
        backendName,
        param.tokenizerPath.toNativeChar(),
      );
    }
    if (_modelId < 0) {
      throw 'Failed to load model, $_modelId';
    }

    final ttsConfig = param.ttsModelConfig;
    if (ttsConfig != null) {
      for (final normalizer in ttsConfig.textNormalizers) {
        final retVal = _rwkv.rwkvmobile_runtime_tts_register_text_normalizer(
          _handle,
          normalizer.toNativeChar(),
        );
        _tryThrowErrorRetVal(retVal);
      }
      final retVal = _rwkv.rwkvmobile_runtime_sparktts_load_models(
        _handle,
        ttsConfig.wav2vec2ModelPath.toNativeChar(),
        ttsConfig.biCodecTokenizerPath.toNativeChar(),
        ttsConfig.biCodecDetokenizerPath.toNativeChar(),
      );
      _tryThrowErrorRetVal(retVal);
      logd('tts model loaded');
    }

    logd(
      'model loaded, id:$_modelId, backend:${backend.name}, path:${param.modelPath}, ${param.tokenizerPath}',
    );
    return _modelId;
  }

  Future<String> dumpLog() async {
    final log = _rwkv.rwkvmobile_dump_log().toDartString();
    return log;
  }

  @override
  Stream<GenerationResponse> chat(List<String> history) {
    _lastGenerationAt = DateTime.now().millisecondsSinceEpoch;

    ffi.Pointer<ffi.Pointer<ffi.Char>> inputsPtr = calloc
        .allocate<ffi.Pointer<ffi.Char>>(1000);
    for (var i = 0; i < history.length; i++) {
      inputsPtr[i] = history[i].toNativeChar();
    }
    final numInputs = history.length;

    _checkGenerationState();

    final retVal = _rwkv.rwkvmobile_runtime_eval_chat_with_history_async(
      _handle,
      _modelId,
      inputsPtr,
      numInputs,
      decodeParam.maxTokens,
      ffi.nullptr,
      generationParam.chatReasoning ? 1 : 0,
      generationParam.forceReasoning ? 1 : 0,
      generationParam.addGenerationPrompt ? 1 : 0,
    );
    _tryThrowErrorRetVal(retVal);

    final isResume = history.length % 2 == 0;

    if (isResume && !generationParam.returnWholeGeneratedResult) {
      _generationPosition = history.last.length;
    }
    return _pollingGenerationResult(resume: isResume).cast();
  }

  @override
  Future clearState() async {
    if (_modelId == -1) {
      logd('clear state skipped, model not loaded');
      return;
    }
    logd('clear state');
    final retVal = _rwkv.rwkvmobile_runtime_clear_state(_handle, _modelId);
    _tryThrowErrorRetVal(retVal);
  }

  @override
  Stream<GenerationResponse> generate(String prompt) {
    logd(
      'generate start, '
      'model_id=${_modelId}, '
      'prompt_len=${prompt.length}, '
      'max_tokens=${decodeParam.maxTokens}, '
      'stop_token=${generationParam.completionStopToken}',
    );

    _lastGenerationAt = DateTime.now().millisecondsSinceEpoch;
    _checkGenerationState();

    final retVal = _rwkv.rwkvmobile_runtime_gen_completion_async(
      _handle,
      _modelId,
      prompt.toNativeChar(),
      decodeParam.maxTokens,
      generationParam.completionStopToken,
      ffi.nullptr,
    );
    _tryThrowErrorRetVal(retVal);

    if (generationParam.returnWholeGeneratedResult) {
      _generationPosition = prompt.length;
    }
    return _pollingGenerationResult().cast();
  }

  @override
  Future setImage(String path) async {
    throw Exception('Not implemented');
  }

  @override
  Future setDecodeParam(DecodeParam param) async {
    logd('set decode param: $param');
    this.decodeParam = param;
    _rwkv.rwkvmobile_runtime_set_sampler_params(
      _handle,
      _modelId,
      param.toNativeSamplerParam(),
    );
    _rwkv.rwkvmobile_runtime_set_penalty_params(
      _handle,
      _modelId,
      param.toNativePenaltyParam(),
    );
  }

  @override
  Future setGenerationConfig(GenerationConfig param) async {
    logd('set generation config: $param');

    int retVal = 0;
    if (param.prompt != generationParam.prompt) {
      retVal = _rwkv.rwkvmobile_runtime_set_prompt(
        _handle,
        _modelId,
        param.prompt.toNativeChar(),
      );
      _tryThrowErrorRetVal(retVal);
    }

    if (param.eosToken != generationParam.eosToken) {
      retVal = _rwkv.rwkvmobile_runtime_set_eos_token(
        _handle,
        _modelId,
        param.eosToken!.toNativeChar(),
      );
      _tryThrowErrorRetVal(retVal);
    }
    if (param.bosToken != generationParam.bosToken) {
      retVal = _rwkv.rwkvmobile_runtime_set_bos_token(
        _handle,
        _modelId,
        param.bosToken!.toNativeChar(),
      );
      _tryThrowErrorRetVal(retVal);
    }

    if (param.tokenBanned != generationParam.tokenBanned) {
      final ptr = calloc.allocate<ffi.Int>(param.tokenBanned.length);
      for (var i = 0; i < param.tokenBanned.length; i++) {
        ptr[i] = param.tokenBanned[i];
      }
      retVal = _rwkv.rwkvmobile_runtime_set_token_banned(
        _handle,
        _modelId,
        ptr,
        param.tokenBanned.length,
      );
      _tryThrowErrorRetVal(retVal);
    }

    if (param.userRole != generationParam.userRole) {
      retVal = _rwkv.rwkvmobile_runtime_set_user_role(
        _handle,
        _modelId,
        param.userRole.toNativeChar(),
      );
      _tryThrowErrorRetVal(retVal);
    }

    if (param.assistantRole != generationParam.assistantRole) {
      retVal = _rwkv.rwkvmobile_runtime_set_response_role(
        _handle,
        _modelId,
        param.assistantRole.toNativeChar(),
      );
      _tryThrowErrorRetVal(retVal);
    }

    if (param.thinkingToken != generationParam.thinkingToken) {
      retVal = _rwkv.rwkvmobile_runtime_set_thinking_token(
        _handle,
        _modelId,
        param.thinkingToken.toNativeChar(),
      );
      _tryThrowErrorRetVal(retVal);
    }

    if (param.spaceAfterRole != generationParam.spaceAfterRole) {
      retVal = _rwkv.rwkvmobile_runtime_set_space_after_roles(
        _handle,
        _modelId,
        param.spaceAfterRole ? 1 : 0,
      );
      _tryThrowErrorRetVal(retVal);
    }
    this.generationParam = param;
  }

  @override
  Stream<GenerationState> generationStateStream() =>
      _controllerGenerationState.stream;

  @override
  Future<GenerationState> getGenerationState() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - generationState.timestamp > 100) {
      _updateTextGenerationState();
    }
    return generationState;
  }

  @override
  Future stopGenerate() async {
    try {
      await Future.doWhile(() async {
        final retVal = _rwkv.rwkvmobile_runtime_stop_generation(
          _handle,
          _modelId,
        );
        _tryThrowErrorRetVal(retVal);
        await Future.delayed(Duration(milliseconds: 100));
        _updateTextGenerationState();
        return generationState.isGenerating;
      }).timeout(Duration(seconds: 5));
      logd('generate stopped!');
    } on TimeoutException {
      loge('stop generate failed');
    }
  }

  @override
  Future release() async {
    _controllerGenerationState.stream.drain();
    _controllerGenerationState.close();
    final retVal = _rwkv.rwkvmobile_runtime_release(_handle);
    _tryThrowErrorRetVal(retVal);
    _handle = ffi.nullptr;
    _modelId = -1;
    logd('rwkv runtime released!');
  }

  Stream _pollingGenerationResult({
    bool resume = false,
    GenerationType type = GenerationType.TEXT,
  }) {
    final generationId = _lastGenerationAt;
    if (!resume) {
      _generationPosition = 0;
      _generatedTTSLen = 0;
    }
    return Stream.periodic(const Duration(milliseconds: 20))
        .map((e) {
          if (generationId != _lastGenerationAt) {
            throw Exception('stopped due to generationId changed');
          }
          _updateTextGenerationState();
          switch (type) {
            case GenerationType.TEXT:
              return _getGenerationTextBuffer();
            case GenerationType.TTS:
              return _getGenerateAudioBuffer();
            default:
              throw UnimplementedError();
          }
        })
        .takeWhile((_) => generationState.isGenerating)
        .where((e) => type == GenerationType.TEXT ? e.text != '' : e != null);
  }

  GenerationResponse _getGenerationTextBuffer() {
    final resp = _rwkv.rwkvmobile_runtime_get_response_buffer_content(
      _handle,
      _modelId,
    );
    if (resp.length == 0) {
      return GenerationResponse(
        text: '',
        tokenCount: 0,
        stopReason: StopReason.none,
      );
    }
    final bytes = resp.content.cast<ffi.Uint8>().asTypedList(resp.length);
    String text = _utf8codec.decode(bytes).trimLeft();

    if (!generationParam.returnWholeGeneratedResult) {
      final append = text.substring(_generationPosition);
      _generationPosition = text.length;
      text = append;
    }
    return GenerationResponse(
      text: text,
      tokenCount: -1,
      stopReason: resp.eos_found == 1 ? StopReason.eos : StopReason.none,
    );
  }

  dynamic _getGenerateAudioBuffer() {
    final len = _rwkv.rwkvmobile_runtime_get_tts_streaming_buffer_length(
      _handle,
    );
    if (len == _generatedTTSLen) {
      return null;
    }
    final buffer = _rwkv.rwkvmobile_runtime_get_tts_streaming_buffer(_handle);
    var samples = buffer.samples.asTypedList(buffer.length).toList();
    _rwkv.rwkvmobile_runtime_free_tts_streaming_buffer(buffer);
    if (!generationParam.returnWholeGeneratedResult) {
      samples = samples.sublist(_generatedTTSLen);
    }
    _generatedTTSLen = buffer.length;
    return samples;
  }

  void _checkGenerationState() {
    if (_rwkv.rwkvmobile_runtime_is_generating(_handle, _modelId) != 0) {
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

  GenerationState _updateTextGenerationState() {
    final prefillSpeed = _rwkv.rwkvmobile_runtime_get_avg_prefill_speed(
      _handle,
      _modelId,
    );
    final decodeSpeed = _rwkv.rwkvmobile_runtime_get_avg_decode_speed(
      _handle,
      _modelId,
    );
    final prefillProgress = _rwkv.rwkvmobile_runtime_get_prefill_progress(
      _handle,
      _modelId,
    );
    final isGenerating =
        _rwkv.rwkvmobile_runtime_is_generating(_handle, _modelId) != 0;
    final state = GenerationState(
      isGenerating: isGenerating,
      prefillProgress: prefillProgress,
      prefillSpeed: prefillSpeed,
      decodeSpeed: decodeSpeed,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    if (generationState.isGenerating != state.isGenerating) {
      logd('generation state changed: ${state.isGenerating}');
    }

    if (!state.equals(generationState) &&
        !_controllerGenerationState.isClosed) {
      _controllerGenerationState.add(state);
    }
    generationState = state;
    return state;
  }

  @override
  Future loadInitialState(String path) async {
    final retVal = _rwkv.rwkvmobile_runtime_load_initial_state(
      _handle,
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

  @override
  Future<int> getSeed() async {
    final retVal = _rwkv.rwkvmobile_runtime_get_seed(_handle, _modelId);
    return retVal;
  }

  @override
  Future setSeed(int seed) async {
    final retVal = _rwkv.rwkvmobile_runtime_set_seed(_handle, _modelId, seed);
    _tryThrowErrorRetVal(retVal);
  }

  @override
  Future<RunEvaluationResult> runEvaluation(RunEvaluationParam param) async {
    final r = _rwkv.rwkvmobile_runtime_run_evaluation(
      _handle,
      _modelId,
      param.source.toNativeChar(),
      param.target.toNativeChar(),
    );
    final List<double> logits = r.logits_vals.asTypedList(r.count).toList();
    final List<bool> corrects = r.corrects
        .cast<ffi.Int32>()
        .asTypedList(r.count)
        .toList()
        .map((e) => e != 0)
        .toList();
    _rwkv.rwkvmobile_runtime_free_evaluation_results(r);
    return RunEvaluationResult(logits: logits, corrects: corrects);
  }

  @override
  Future<String> dumpStateInfo() async {
    final r = _rwkv.rwkvmobile_get_state_cache_info(_handle, _modelId);
    return r.cast<Utf8>().toDartString();
  }

  @override
  Future setImageId(String id) async {
    final retVal = _rwkv.rwkvmobile_runtime_set_image_unique_identifier(
      _handle,
      id.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);
  }

  @override
  Stream<List<double>> textToSpeech(TextToSpeechParam param) {
    final retVal = _rwkv.rwkvmobile_runtime_run_spark_tts_streaming_async(
      _handle,
      _modelId,
      param.text.toNativeChar(),
      (param.inputAudioText ?? "").toNativeChar(),
      param.inputAudioPath.toNativeChar(),
      param.outputAudioPath.toNativeChar(),
    );
    _tryThrowErrorRetVal(retVal);
    logd(
      'tts streaming started, '
      'text:${param.text}, '
      'audioText:${param.inputAudioText}, '
      'audioPath:${param.inputAudioPath}'
      'output:${param.outputAudioPath}',
    );
    return _pollingGenerationResult(type: GenerationType.TTS).cast();
  }
}
