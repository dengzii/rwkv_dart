import 'dart:ffi';

import 'package:rwkv_dart/src/backend.dart';
import 'package:rwkv_dart/src/rwkv_mobile_ffi.dart';

import 'isolate.dart';

enum RWKVLogLevel { debug, info, warning, error }

enum Backend {
  /// Currently we use it on Android, Windows and Linux
  /// This is suitable for running small puzzle models on various platforms
  /// Not really optimal for larger chat models
  ncnn,

  /// Supports Android, Windows, Linux and macOS (iOS maybe in the future. not used for now)
  llamacpp,

  /// Unsupported on Android
  webRwkv,

  /// Qualcomm Neural Network
  qnn,

  /// dummy mnn backend string
  mnn,

  /// Apple CoreML
  coreml;

  String get asArgument => switch (this) {
    Backend.ncnn => 'ncnn',
    Backend.webRwkv => 'web-rwkv',
    Backend.llamacpp => 'llama.cpp',
    Backend.qnn => 'qnn',
    Backend.mnn => 'mnn',
    Backend.coreml => 'coreml',
  };

  static Backend fromString(String value) {
    final toLower = value.toLowerCase();
    if (toLower.contains('ncnn')) return Backend.ncnn;
    if (toLower.contains('web') && toLower.contains('rwkv'))
      return Backend.webRwkv;
    if (toLower.contains('llama')) return Backend.llamacpp;
    if (toLower.contains('qnn')) return Backend.qnn;
    if (toLower.contains('mnn')) return Backend.mnn;
    if (toLower.contains('coreml')) return Backend.coreml;
    throw Exception('Unknown backend: $value');
  }
}

/// Param for init rwkv dart sdk
class InitParam {
  final String? dynamicLibDir;
  final RWKVLogLevel logLevel;

  InitParam({this.dynamicLibDir, this.logLevel = RWKVLogLevel.debug});
}

/// Param load rwkv model
class LoadModelParam {
  final String modelPath;
  final String tokenizerPath;
  final Backend backend;

  // if using qnn, this is required
  final String? qnnLibDir;

  LoadModelParam({
    required this.modelPath,
    required this.tokenizerPath,
    required this.backend,
    this.qnnLibDir,
  });
}

class DecodeParam {
  /// 0.0~3.0
  final double temperature;

  /// 0~128
  final int topK;

  /// 0.0~1.0
  final double topP;

  /// 0.0 ~ 2.0
  final double presencePenalty;

  /// 0.0 ~ 2.0
  final double frequencyPenalty;

  /// 0.990 ~ 0.999
  final double penaltyDecay;

  DecodeParam({
    required this.temperature,
    required this.topK,
    required this.topP,
    required this.presencePenalty,
    required this.frequencyPenalty,
    required this.penaltyDecay,
  });

  factory DecodeParam.initial() {
    return DecodeParam(
      temperature: 1.0,
      topK: 1,
      topP: 0.5,
      presencePenalty: 0.5,
      frequencyPenalty: 0.5,
      penaltyDecay: 0.996,
    );
  }

  toNativeSamplerParam() => Struct.create<sampler_params>()
    ..temperature = temperature
    ..top_k = topK
    ..top_p = topP;

  toNativePenaltyParam() => Struct.create<penalty_params>()
    ..presence_penalty = presencePenalty
    ..frequency_penalty = frequencyPenalty
    ..penalty_decay = penaltyDecay;

  DecodeParam copyWith({
    double? temperature,
    int? topK,
    double? topP,
    double? presencePenalty,
    double? frequencyPenalty,
    double? penaltyDecay,
  }) {
    return DecodeParam(
      temperature: temperature ?? this.temperature,
      topK: topK ?? this.topK,
      topP: topP ?? this.topP,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
      penaltyDecay: penaltyDecay ?? this.penaltyDecay,
    );
  }
}

class GenerationParam {
  static const promptThinking = "<EOD>";

  static const promptNoThinkingEN = """<EOD>User: hi

Assistant: Hi. I am your assistant and I will provide expert full response in full details. Please feel free to ask any question and I will always answer it.

""";

  static const promptNoThinkingCN = """<EOD>User: 你好

Assistant: 你好，我是你的助手，我会提供专家级的完整回答。请随时提问，我会一直回答。

""";

  static const thinkingTokenNone = "";
  static const thinkingTokenLight = r"<think>\n</think>";
  static const thinkingTokenFree = r"<think>";
  static const thinkingTokenZh = r"<think>嗯";

  final int maxTokens;
  final bool chatReasoning;

  final int completionStopToken;

  // apply to the start of the prompt
  final String prompt;

  //
  final String thinkingToken;

  // \x17
  final String? eosToken;

  // \x16
  final String? bosToken;

  final List<int> tokenBanned;

  // return whole generated result or only new tokens
  final bool returnWholeGeneratedResult;

  final String userRole;
  final String assistantRole;

  GenerationParam({
    required this.maxTokens,
    required this.thinkingToken,
    required this.chatReasoning,
    required this.completionStopToken,
    required this.prompt,
    required this.returnWholeGeneratedResult,
    this.tokenBanned = const [],
    this.assistantRole = "Assistant",
    this.userRole = "User",
    this.eosToken,
    this.bosToken,
  });

  factory GenerationParam.initial() {
    return GenerationParam(
      maxTokens: 2000,
      thinkingToken: thinkingTokenNone,
      chatReasoning: false,
      completionStopToken: 0,
      prompt: GenerationParam.promptThinking,
      returnWholeGeneratedResult: false,
    );
  }

  GenerationParam copyWith({
    int? maxTokens,
    bool? chatReasoning,
    String? thinkingToken,
    int? completionStopToken,
    String? prompt,
    bool? returnWholeGeneratedResult,
  }) {
    return GenerationParam(
      maxTokens: maxTokens ?? this.maxTokens,
      thinkingToken: thinkingToken ?? this.thinkingToken,
      chatReasoning: chatReasoning ?? this.chatReasoning,
      completionStopToken: completionStopToken ?? this.completionStopToken,
      prompt: prompt ?? this.prompt,
      returnWholeGeneratedResult:
          returnWholeGeneratedResult ?? this.returnWholeGeneratedResult,
    );
  }
}

class TextGenerationState {
  final bool isGenerating;
  final double prefillProgress;
  final double prefillSpeed;
  final double decodeSpeed;
  final int timestamp;

  TextGenerationState({
    required this.isGenerating,
    required this.prefillProgress,
    required this.prefillSpeed,
    required this.decodeSpeed,
    required this.timestamp,
  });

  factory TextGenerationState.initial() {
    return TextGenerationState(
      isGenerating: false,
      prefillProgress: 0,
      prefillSpeed: 0,
      decodeSpeed: 0,
      timestamp: 0,
    );
  }

  TextGenerationState copyWith({
    bool? isGenerating,
    double? prefillProgress,
    double? prefillSpeed,
    double? decodeSpeed,
    int? timestamp,
  }) {
    return TextGenerationState(
      isGenerating: isGenerating ?? this.isGenerating,
      prefillProgress: prefillProgress ?? this.prefillProgress,
      prefillSpeed: prefillSpeed ?? this.prefillSpeed,
      decodeSpeed: decodeSpeed ?? this.decodeSpeed,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  bool equals(Object? other) {
    if (other is TextGenerationState) {
      return isGenerating == other.isGenerating &&
          prefillProgress == other.prefillProgress &&
          prefillSpeed == other.prefillSpeed &&
          decodeSpeed == other.decodeSpeed;
    }
    return false;
  }

  @override
  String toString() {
    return 'TextGenerationState(isGenerating: $isGenerating, prefillProgress: $prefillProgress, prefillSpeed: $prefillSpeed, decodeSpeed: $decodeSpeed, timestamp: $timestamp)';
  }
}

abstract class RWKV {
  /// Create a RWKV ffi instance.
  factory RWKV.create() => RWKVBackend();

  /// Create a RWKV instance run in the isolate.
  factory RWKV.isolated() => RWKVIsolateProxy();

  /// Initialize the RWKV ffi instance.
  ///
  /// This method should be called before any other methods.
  Future init([InitParam? param]);

  /// Load and initialize the model, return the model id.
  Future<int> loadModel(LoadModelParam param);

  Future setDecodeParam(DecodeParam param);

  Future loadInitialState(String statePath);

  Future clearInitialState();

  Future<String> getSocName();

  Future<String> getHtpArch();

  Future<String> dumpLog();

  Stream<String> completion(String prompt);

  Stream<String> chat(List<String> history);

  Future<TextGenerationState> getGenerationState();

  Stream<TextGenerationState> generationStateChangeStream();

  Future setGenerationParam(GenerationParam param);

  Future setImage(String path);

  Future setAudio(String path);

  /// Clear the backend runtime state.
  Future clearState();

  Future stopGeneration();

  Future release();
}
