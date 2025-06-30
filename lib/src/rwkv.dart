import 'dart:ffi';

import 'package:rwkv_flutter/src/runtime.dart';
import 'package:rwkv_flutter/src/rwkv_mobile_ffi.dart';

import 'isolate.dart';

enum RWKVLogLevel { debug, info, warning, error }

enum Backend {
  /// Currently we use it on Android, Windows and Linux
  /// This is suitable for running small puzzle models on various platforms
  /// Not really optimal for larger chat models
  ncnn,

  /// Supports Android, Windows, Linux and macOS (iOS maybe in the future. not used for now)
  llamacpp,

  /// Currently only support iOS and macOS
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

class InitRuntimeParam {
  final String modelPath;
  final String tokenizerPath;
  final Backend backend;

  InitRuntimeParam({
    required this.modelPath,
    required this.tokenizerPath,
    required this.backend,
  });
}

class PenaltyParam {
  final double presencePenalty;
  final double frequencyPenalty;
  final double penaltyDecay;

  const PenaltyParam({
    required this.presencePenalty,
    required this.frequencyPenalty,
    required this.penaltyDecay,
  });

  toFfiParam() => Struct.create<penalty_params>()
    ..presence_penalty = presencePenalty
    ..frequency_penalty = frequencyPenalty
    ..presence_penalty = penaltyDecay;
}

class SamplerParam {
  final double temperature;
  final int topK;
  final double topP;

  SamplerParam({
    required this.temperature,
    required this.topK,
    required this.topP,
  });

  toFfiParam() => Struct.create<sampler_params>()
    ..temperature = temperature
    ..top_k = topK
    ..top_p = topP;
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
  final String thinkingToken;
  final String prompt;

  GenerationParam({
    required this.maxTokens,
    required this.thinkingToken,
    required this.chatReasoning,
    required this.completionStopToken,
    required this.prompt,
  });

  factory GenerationParam.initial() {
    return GenerationParam(
      maxTokens: 2000,
      thinkingToken: thinkingTokenNone,
      chatReasoning: false,
      completionStopToken: 0,
      prompt: GenerationParam.promptThinking,
    );
  }

  GenerationParam copyWith({
    int? maxTokens,
    bool? chatReasoning,
    String? thinkingToken,
    int? completionStopToken,
    String? prompt,
  }) {
    return GenerationParam(
      maxTokens: maxTokens ?? this.maxTokens,
      thinkingToken: thinkingToken ?? this.thinkingToken,
      chatReasoning: chatReasoning ?? this.chatReasoning,
      completionStopToken: completionStopToken ?? this.completionStopToken,
      prompt: prompt ?? this.prompt,
    );
  }
}

class TextGenerationState {
  final bool isGenerating;
  final double prefillProgress;
  final double prefillSpeed;
  final double decodeSpeed;

  TextGenerationState({
    required this.isGenerating,
    required this.prefillProgress,
    required this.prefillSpeed,
    required this.decodeSpeed,
  });

  factory TextGenerationState.initial() {
    return TextGenerationState(
      isGenerating: false,
      prefillProgress: 0,
      prefillSpeed: 0,
      decodeSpeed: 0,
    );
  }

  TextGenerationState copyWith({
    bool? isGenerating,
    double? prefillProgress,
    double? prefillSpeed,
    double? decodeSpeed,
  }) {
    return TextGenerationState(
      isGenerating: isGenerating ?? this.isGenerating,
      prefillProgress: prefillProgress ?? this.prefillProgress,
      prefillSpeed: prefillSpeed ?? this.prefillSpeed,
      decodeSpeed: decodeSpeed ?? this.decodeSpeed,
    );
  }
}

abstract class RWKV {
  factory RWKV.create({String dynamicLibraryDir = ''}) =>
      RWKVRuntime(dynamicLibraryDir: dynamicLibraryDir);

  factory RWKV.isolated() => RWKVIsolateProxy();

  Future init();

  Future initRuntime(InitRuntimeParam param);

  Future setSamplerParam(SamplerParam param);

  Future setPenaltyParam(PenaltyParam param);

  Stream<String> completion(String prompt);

  Stream<String> chat(List<String> history);

  Future setGenerationParam(GenerationParam param);

  Future setImage(String path);

  Future setAudio(String path);

  Future clearState();

  Future stop();
}
