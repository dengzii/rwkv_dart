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
  success(0),
  io(1 << 0),
  init(1 << 1),
  eval(1 << 2),
  invalidParameters(1 << 3),
  backend(1 << 4),
  model(1 << 5),
  tokenizer(1 << 6),
  sampler(1 << 7),
  runtime(1 << 8),
  unsupported(1 << 9),
  alloca(1 << 10),
  release(1 << 11);

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

enum GenerationType { text, tts, image }

extension _Ext on ffi.Pointer<ffi.Char> {
  String toDartString() => cast<Utf8>().toDartString();
}

extension _Ext2 on DecodeParam {
  sampler_params toNativeSamplerParam() => Struct.create<sampler_params>()
    ..temperature = temperature
    ..top_k = topK
    ..top_p = topP;

  penalty_params toNativePenaltyParam() => Struct.create<penalty_params>()
    ..presence_penalty = presencePenalty
    ..frequency_penalty = frequencyPenalty
    ..penalty_decay = penaltyDecay;
}

class GenerationConfig {
  final bool addGenerationPrompt;

  final ReasoningEffort reasoningEffort;
  final int completionStopToken;

  final String prompt;

  //
  final String thinkingToken;

  // \x17
  final String? eosToken;

  // \x16
  final String? bosToken;

  final List<int> tokenBanned;

  final bool returnWholeGeneratedResult;

  final bool spaceAfterRole;

  GenerationConfig({
    required this.thinkingToken,
    required this.completionStopToken,
    required this.prompt,
    required this.returnWholeGeneratedResult,
    required this.reasoningEffort,
    this.addGenerationPrompt = false,
    this.tokenBanned = const [],
    this.spaceAfterRole = true,
    this.eosToken,
    this.bosToken,
  });

  factory GenerationConfig.initial() {
    return GenerationConfig(
      thinkingToken: "",
      reasoningEffort: ReasoningEffort.none,
      completionStopToken: 0,
      prompt: "",
      returnWholeGeneratedResult: false,
    );
  }

  GenerationConfig copyWith({
    String? thinkingToken,
    int? completionStopToken,
    String? prompt,
    bool? returnWholeGeneratedResult,
    ReasoningEffort? reasoningEffort,
    bool? addGenerationPrompt,
    List<int>? tokenBanned,
    bool? spaceAfterRole,
    String? eosToken,
    String? bosToken,
  }) {
    return GenerationConfig(
      thinkingToken: thinkingToken ?? this.thinkingToken,
      completionStopToken: completionStopToken ?? this.completionStopToken,
      prompt: prompt ?? this.prompt,
      returnWholeGeneratedResult:
          returnWholeGeneratedResult ?? this.returnWholeGeneratedResult,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      addGenerationPrompt: addGenerationPrompt ?? this.addGenerationPrompt,
      tokenBanned: tokenBanned ?? this.tokenBanned,
      spaceAfterRole: spaceAfterRole ?? this.spaceAfterRole,
      eosToken: eosToken ?? this.eosToken,
      bosToken: bosToken ?? this.bosToken,
    );
  }

  @override
  String toString() {
    return 'GenerationConfig{reasoningEffort: $reasoningEffort, completionStopToken: $completionStopToken, prompt: $prompt, thinkingToken: $thinkingToken, eosToken: $eosToken, bosToken: $bosToken, tokenBanned: $tokenBanned, returnWholeGeneratedResult: $returnWholeGeneratedResult, spaceAfterRole: $spaceAfterRole}, addGenerationPrompt: $addGenerationPrompt';
  }
}

final class _AsyncNativeArguments {
  final List<ffi.Pointer<ffi.Void>> _allocations = [];
  bool _released = false;

  ffi.Pointer<ffi.Char> allocUtf8(String value) {
    final ptr = value.toNativeUtf8(allocator: malloc).cast<ffi.Char>();
    _allocations.add(ptr.cast<ffi.Void>());
    return ptr;
  }

  ffi.Pointer<ffi.Pointer<ffi.Char>> allocCharPointerArray(int length) {
    final actualLength = length == 0 ? 1 : length;
    final ptr = malloc.allocate<ffi.Pointer<ffi.Char>>(
      ffi.sizeOf<ffi.Pointer<ffi.Char>>() * actualLength,
    );
    _allocations.add(ptr.cast<ffi.Void>());
    return ptr;
  }

  void release() {
    if (_released) {
      return;
    }
    for (final ptr in _allocations.reversed) {
      malloc.free(ptr);
    }
    _allocations.clear();
    _released = true;
  }
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
  _AsyncNativeArguments? _activeGenerationArgs;

  GenerationConfig generationParam = GenerationConfig.initial();
  DecodeParam decodeParam = DecodeParam.initial();
  GenerationState generationState = GenerationState.initial();
  final StreamController<GenerationState> _controllerGenerationState =
      StreamController.broadcast();

  RWKVBackend([String? _, String? _]);

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

  @override
  Future init([InitParam? param]) async {
    dynamicLibraryDir = param?.dynamicLibDir ?? '';

    _qnnLibDir = param?.qnnLibDir;
    _rwkv = rwkv_mobile(_loadDynamicLib());

    await setLogLevel(param?.logLevel ?? RWKVLogLevel.error);

    _handle = _rwkv.rwkvmobile_runtime_init();
    if (_handle == ffi.nullptr) {
      throw Exception('Failed to initialize RWKV backend');
    }
    final ptr = malloc.allocate<ffi.Char>(64);
    try {
      final retVal = _rwkv.rwkvmobile_runtime_get_available_backend_names(
        ptr,
        64,
      );
      _tryThrowErrorRetVal(retVal);
      final names = ptr.cast<Utf8>().toDartString();
      logd('ffi initialized, available backend: $names');
    } finally {
      malloc.free(ptr);
    }
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
    if (param.tokenizerPath.isEmpty) {
      throw Exception('Tokenizer path is required');
    }

    if (_modelId != -1) {
      final retVal = _rwkv.rwkvmobile_runtime_release_model(_handle, _modelId);
      _tryThrowErrorRetVal(retVal);
      _modelId = -1;
    }

    String modelPath = param.modelPath;

    final backend = param.backend ?? Backend.fromModelPath(param.modelPath);
    if (backend == null) {
      throw Exception(
        'auto detect backend failed for $modelPath, please specify backend explicitly',
      );
    }

    final arena = Arena();
    try {
      final backendName = backend.name
          .toNativeUtf8(allocator: arena)
          .cast<ffi.Char>();
      final modelPathPtr = modelPath
          .toNativeUtf8(allocator: arena)
          .cast<ffi.Char>();
      final tokenizerPathPtr = param.tokenizerPath
          .toNativeUtf8(allocator: arena)
          .cast<ffi.Char>();

      if (param.backend == Backend.qnn) {
        final qnnLibs = _qnnLibDir;
        if (qnnLibs == null || qnnLibs.isEmpty) {
          throw Exception(
            'qnn libs is required when using qnn backend, set it in InitParam',
          );
        }
        final qnnLibPtr = qnnLibs
            .toNativeUtf8(allocator: arena)
            .cast<ffi.Char>();
        _rwkv.rwkvmobile_runtime_set_qnn_library_path(_handle, qnnLibPtr);
        final qnnHtpPath = '$qnnLibs/libQnnHtp.so'
            .toNativeUtf8(allocator: arena)
            .cast<ffi.Void>();
        _modelId = _rwkv.rwkvmobile_runtime_load_model_with_extra(
          _handle,
          modelPathPtr,
          backendName,
          tokenizerPathPtr,
          qnnHtpPath,
        );
      } else {
        _modelId = _rwkv.rwkvmobile_runtime_load_model(
          _handle,
          modelPathPtr,
          backendName,
          tokenizerPathPtr,
        );
      }
    } finally {
      arena.releaseAll();
    }
    if (_modelId < 0) {
      throw 'Failed to load model, $_modelId';
    }

    final ttsConfig = param.ttsModelConfig;
    if (ttsConfig != null) {
      final arena = Arena();
      try {
        for (final normalizer in ttsConfig.textNormalizers) {
          final retVal = _rwkv.rwkvmobile_runtime_tts_register_text_normalizer(
            _handle,
            normalizer.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
          );
          _tryThrowErrorRetVal(retVal);
        }
        final retVal = _rwkv.rwkvmobile_runtime_sparktts_load_models(
          _handle,
          ttsConfig.wav2vec2ModelPath
              .toNativeUtf8(allocator: arena)
              .cast<ffi.Char>(),
          ttsConfig.biCodecTokenizerPath
              .toNativeUtf8(allocator: arena)
              .cast<ffi.Char>(),
          ttsConfig.biCodecDetokenizerPath
              .toNativeUtf8(allocator: arena)
              .cast<ffi.Char>(),
        );
        _tryThrowErrorRetVal(retVal);
      } finally {
        arena.releaseAll();
      }
      logd('tts model loaded');
    }

    logd(
      'model loaded, id:$_modelId, backend:${backend.name}, path:${param.modelPath}, ${param.tokenizerPath}',
    );
    _applyGenerationConfig(generationParam.copyWith(thinkingToken: "<think>"));
    return _modelId;
  }

  @override
  Future<String> dumpLog() async {
    final log = _rwkv.rwkvmobile_dump_log().toDartString();
    return log;
  }

  @override
  Stream<GenerationResponse> chat(ChatParam param) async* {
    final history = param.messages!.map((e) => e.content).toList();
    final generationConfig = _chatGenerationConfig(param);
    final maxTokens = param.maxTokens ?? decodeParam.maxTokens;
    _AsyncNativeArguments? args;

    final isResume = history.length % 2 == 0;

    if (isResume && !generationConfig.returnWholeGeneratedResult) {
      _generationPosition = history.last.length;
    }

    _lastGenerationAt = DateTime.now().millisecondsSinceEpoch;

    await _checkGenerationState();
    await _applyGenerationConfig(generationConfig);

    bool reasoning;
    bool force;
    switch (param.reasoning ?? generationConfig.reasoningEffort) {
      case ReasoningEffort.none:
        reasoning = false;
        force = false;
        break;
      case ReasoningEffort.mini:
      case ReasoningEffort.low:
      case ReasoningEffort.medium:
        reasoning = true;
        force = false;
        break;
      case ReasoningEffort.high:
      case ReasoningEffort.xhig:
        reasoning = true;
        force = true;
        break;
    }

    try {
      args = _beginGenerationArgs();

      if (reasoning && !isResume) {
        history.add(generationConfig.thinkingToken);
      }

      final numInputs = history.length;
      final inputsPtr = args.allocCharPointerArray(numInputs);
      for (var i = 0; i < history.length; i++) {
        inputsPtr[i] = args.allocUtf8(history[i]);
      }

      final retVal = _rwkv.rwkvmobile_runtime_eval_chat_with_history_async(
        _handle,
        _modelId,
        inputsPtr,
        numInputs,
        maxTokens,
        ffi.nullptr,
        reasoning ? 1 : 0,
        force ? 1 : 0,
        FORCE_LANG_NONE,
        generationConfig.addGenerationPrompt ? 1 : 0,
      );
      _tryThrowErrorRetVal(retVal);

      yield* _pollingGenerationResult(resume: isResume).cast();
    } finally {
      _releaseGenerationArgs(args);
    }
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
  Stream<GenerationResponse> generate(GenerationParam param) async* {
    final prompt = param.prompt;
    final generationConfig = _generateGenerationConfig(param);
    _AsyncNativeArguments? args;
    logd(
      'generate start, '
      'model_id=$_modelId, '
      'prompt_len=${prompt.length}, '
      'max_tokens=${param.maxCompletionTokens ?? decodeParam.maxTokens}, '
      'stop_token=${generationConfig.completionStopToken}',
    );

    _lastGenerationAt = DateTime.now().millisecondsSinceEpoch;
    await _checkGenerationState();
    await _applyGenerationConfig(generationConfig);

    try {
      args = _beginGenerationArgs();
      final retVal = _rwkv.rwkvmobile_runtime_gen_completion_async(
        _handle,
        _modelId,
        args.allocUtf8(prompt),
        param.maxCompletionTokens ?? decodeParam.maxTokens,
        generationConfig.completionStopToken,
        ffi.nullptr,
        1,
      );
      _tryThrowErrorRetVal(retVal);

      if (generationConfig.returnWholeGeneratedResult) {
        _generationPosition = prompt.length;
      }
      yield* _pollingGenerationResult().cast();
    } finally {
      _releaseGenerationArgs(args);
    }
  }

  @override
  Future setImage(String path) async {
    throw Exception('Not implemented');
  }

  @override
  Future setDecodeParam(DecodeParam param) async {
    logd('set decode param: $param');
    decodeParam = param;
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

  Future _applyGenerationConfig(GenerationConfig param) async {
    logd('apply generation config: $param');

    int retVal = 0;
    final arena = Arena();
    try {
      if (param.prompt != generationParam.prompt) {
        // ensure prompt ends with \n, this is a workaround for rwkv-mobile
        final p = param.prompt.endsWith('\n')
            ? param.prompt
            : '${param.prompt}\n';
        logi('set prompt: $p');
        retVal = _rwkv.rwkvmobile_runtime_set_prompt(
          _handle,
          _modelId,
          p.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
        );
        _tryThrowErrorRetVal(retVal);
      }

      if (param.eosToken != generationParam.eosToken) {
        logi('set eos token: ${param.eosToken}');
        retVal = _rwkv.rwkvmobile_runtime_set_eos_token(
          _handle,
          _modelId,
          (param.eosToken ?? '')
              .toNativeUtf8(allocator: arena)
              .cast<ffi.Char>(),
        );
        _tryThrowErrorRetVal(retVal);
      }
      if (param.bosToken != generationParam.bosToken) {
        logi('set bos token: ${param.bosToken}');
        retVal = _rwkv.rwkvmobile_runtime_set_bos_token(
          _handle,
          _modelId,
          (param.bosToken ?? '')
              .toNativeUtf8(allocator: arena)
              .cast<ffi.Char>(),
        );
        _tryThrowErrorRetVal(retVal);
      }

      if (param.tokenBanned != generationParam.tokenBanned) {
        logi('set token banned: ${param.tokenBanned}');
        final ptr = arena.allocate<ffi.Int>(
          param.tokenBanned.isEmpty ? 1 : param.tokenBanned.length,
        );
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

      if (param.thinkingToken != generationParam.thinkingToken) {
        logi('set thinking token: ${param.thinkingToken}');
        retVal = _rwkv.rwkvmobile_runtime_set_thinking_token(
          _handle,
          _modelId,
          param.thinkingToken.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
        );
        _tryThrowErrorRetVal(retVal);
      }

      if (param.spaceAfterRole != generationParam.spaceAfterRole) {
        logi('set space after role: ${param.spaceAfterRole}');
        retVal = _rwkv.rwkvmobile_runtime_set_space_after_roles(
          _handle,
          _modelId,
          param.spaceAfterRole ? 1 : 0,
        );
        _tryThrowErrorRetVal(retVal);
      }
    } finally {
      arena.releaseAll();
    }
    generationParam = param;
  }

  GenerationConfig _generateGenerationConfig(GenerationParam param) {
    return generationParam.copyWith(
      completionStopToken: param.completionStopToken,
      returnWholeGeneratedResult: param.returnWholeGeneratedResult,
      tokenBanned: param.tokenBanned,
      eosToken: param.eosToken,
      bosToken: param.bosToken,
    );
  }

  GenerationConfig _chatGenerationConfig(ChatParam param) {
    final prompt = (param.prompt == null || param.prompt!.trim().isEmpty
        ? ''
        : 'System: ${param.prompt!.trim()}');
    return generationParam.copyWith(
      reasoningEffort: param.reasoning,
      completionStopToken: param.completionStopToken,
      prompt: prompt,
      returnWholeGeneratedResult: param.returnWholeGeneratedResult,
      thinkingToken: param.thinkingToken,
      addGenerationPrompt: param.addGenerationPrompt,
      tokenBanned: param.tokenBanned,
      spaceAfterRole: param.spaceAfterRole,
      eosToken: param.eosToken,
      bosToken: param.bosToken,
    );
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
    try {
      final retVal = _rwkv.rwkvmobile_runtime_release(_handle);
      _tryThrowErrorRetVal(retVal);
      logd('rwkv runtime released!');
    } finally {
      _releaseGenerationArgs();
      _handle = ffi.nullptr;
      _modelId = -1;
    }
  }

  Stream _pollingGenerationResult({
    bool resume = false,
    GenerationType type = GenerationType.text,
  }) async* {
    final generationId = _lastGenerationAt;
    if (!resume) {
      _generationPosition = 0;
      _generatedTTSLen = 0;
    }
    while (true) {
      await Future.delayed(const Duration(milliseconds: 60));
      if (generationId != _lastGenerationAt) {
        throw Exception('stopped due to generationId changed');
      }
      _updateTextGenerationState();
      final event = switch (type) {
        GenerationType.text => _getGenerationTextBuffer(),
        GenerationType.tts => _getGenerateAudioBuffer(),
        GenerationType.image => throw UnimplementedError(),
      };
      final hasData = type == GenerationType.text
          ? event.text != ''
          : event != null;
      if (hasData) {
        yield event;
      }
      if (!generationState.isGenerating) {
        break;
      }
    }
  }

  GenerationResponse _getGenerationTextBuffer() {
    final resp = _rwkv.rwkvmobile_runtime_get_response_buffer_content(
      _handle,
      _modelId,
    );
    try {
      final stopReason = resp.eos_found == 1 ? StopReason.eos : StopReason.none;
      final len = resp.length;
      if (len == 0) {
        return GenerationResponse(
          text: '',
          tokenCount: 0,
          stopReason: stopReason,
        );
      }
      final bytes = resp.content.cast<ffi.Uint8>().asTypedList(len);
      String text = _utf8codec.decode(bytes).trimLeft();

      if (!generationParam.returnWholeGeneratedResult) {
        if (_generationPosition < text.length) {
          final append = text.substring(_generationPosition);
          _generationPosition = text.length;
          text = append;
        } else {
          text = '';
        }
      }
      return GenerationResponse(
        text: text,
        tokenCount: -1,
        stopReason: stopReason,
      );
    } finally {
      _rwkv.rwkvmobile_runtime_free_response_buffer(resp);
    }
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

  Future _checkGenerationState() async {
    if (_rwkv.rwkvmobile_runtime_is_generating(_handle, _modelId) != 0) {
      // throw Exception('LLM is already generating');
      await stopGenerate();
    }
    _updateTextGenerationState();
    if (generationState.isGenerating) {
      throw Exception('LLM is still generating');
    }
    _releaseGenerationArgs();
  }

  _AsyncNativeArguments _beginGenerationArgs() {
    _releaseGenerationArgs();
    final args = _AsyncNativeArguments();
    _activeGenerationArgs = args;
    return args;
  }

  void _releaseGenerationArgs([_AsyncNativeArguments? args]) {
    final target = args ?? _activeGenerationArgs;
    if (target == null) {
      return;
    }
    if (identical(_activeGenerationArgs, target)) {
      _activeGenerationArgs = null;
    }
    target.release();
  }

  void _tryThrowErrorRetVal(int retVal) {
    if (retVal == ErrorFlag.success.code) {
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
    final arena = Arena();
    try {
      final retVal = _rwkv.rwkvmobile_runtime_load_initial_state(
        _handle,
        _modelId,
        path.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
      );
      _tryThrowErrorRetVal(retVal);
    } finally {
      arena.releaseAll();
    }
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
    final arena = Arena();
    final r = _rwkv.rwkvmobile_runtime_run_evaluation(
      _handle,
      _modelId,
      param.source.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
      param.target.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
    );
    final List<double> logits = r.logits_vals.asTypedList(r.count).toList();
    final List<bool> corrects = r.corrects
        .cast<ffi.Int32>()
        .asTypedList(r.count)
        .toList()
        .map((e) => e != 0)
        .toList();
    _rwkv.rwkvmobile_runtime_free_evaluation_results(r);
    arena.releaseAll();
    return RunEvaluationResult(logits: logits, corrects: corrects);
  }

  @override
  Future<String> dumpStateInfo() async {
    final r = _rwkv.rwkvmobile_get_state_cache_info(_handle, _modelId);
    try {
      return r.cast<Utf8>().toDartString();
    } finally {
      _rwkv.rwkvmobile_free_state_cache_info(r);
    }
  }

  @override
  Future setImageId(String id) async {
    final arena = Arena();
    try {
      final retVal = _rwkv.rwkvmobile_runtime_set_image_unique_identifier(
        _handle,
        id.toNativeUtf8(allocator: arena).cast<ffi.Char>(),
      );
      _tryThrowErrorRetVal(retVal);
    } finally {
      arena.releaseAll();
    }
  }

  @override
  Stream<List<double>> textToSpeech(TextToSpeechParam param) async* {
    _AsyncNativeArguments? args;
    _lastGenerationAt = DateTime.now().millisecondsSinceEpoch;
    await _checkGenerationState();
    try {
      args = _beginGenerationArgs();
      final retVal = _rwkv.rwkvmobile_runtime_run_spark_tts_streaming_async(
        _handle,
        _modelId,
        args.allocUtf8(param.text),
        args.allocUtf8(param.inputAudioText ?? ""),
        args.allocUtf8(param.inputAudioPath),
        args.allocUtf8(param.outputAudioPath),
      );
      _tryThrowErrorRetVal(retVal);
      logd(
        'tts streaming started, '
        'text:${param.text}, '
        'audioText:${param.inputAudioText}, '
        'audioPath:${param.inputAudioPath}'
        'output:${param.outputAudioPath}',
      );
      yield* _pollingGenerationResult(type: GenerationType.tts).cast();
    } finally {
      _releaseGenerationArgs(args);
    }
  }
}
