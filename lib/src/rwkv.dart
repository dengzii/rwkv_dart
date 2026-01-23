import 'backend.dart'
    if (dart.library.io) 'package:rwkv_dart/src/backend.dart'
    if (dart.library.html) 'package:rwkv_dart/src/web/backend.dart';
import 'isolate.dart'
    if (dart.library.io) 'package:rwkv_dart/src/isolate.dart'
    if (dart.library.html) 'package:rwkv_dart/src/web/isolate.dart';

enum RWKVLogLevel { verbose, info, debug, warning, error }

class RuntimeError {
  final int code;
  final String message;

  RuntimeError({required this.code, required this.message});
}

abstract class RWKV {
  /// Create a RWKV ffi instance.
  factory RWKV.create() => RWKVBackend();

  /// Access RWKV via network
  factory RWKV.network(String baseUrl) => RWKVBackend(baseUrl);

  /// Create a RWKV instance run in the isolate.
  factory RWKV.isolated() => RWKVIsolateProxy();

  /// Initialize the RWKV ffi instance.
  ///
  /// This method should be called before any other methods.
  Future init([InitParam? param]);

  Future setLogLevel(RWKVLogLevel level);

  /// Load and initialize the model, return the model id.
  Future<int> loadModel(LoadModelParam param);

  Future setDecodeParam(DecodeParam param);

  Future loadInitialState(String statePath);

  Future<String> getSocName();

  Future<String> getHtpArch();

  Future<String> dumpLog();

  /// Generate text from prompt.
  /// The generated text will be streamed,
  /// stream will be closed when generation is done.
  Stream<GenerationResponse> generate(GenerationParam param);

  Stream<GenerationResponse> chat(ChatParam param);

  Future<GenerationState> getGenerationState();

  Stream<GenerationState> generationStateStream();

  Future setGenerationConfig(GenerationConfig param);

  Future<RunEvaluationResult> runEvaluation(RunEvaluationParam param);

  Future<String> dumpStateInfo();

  Future setImage(String path);

  Future setImageId(String id);

  /// wav audio data stream
  Stream<List<double>> textToSpeech(TextToSpeechParam param);

  /// Clear the backend runtime state.
  Future clearState();

  Future stopGenerate();

  Future<int> getSeed();

  Future setSeed(int seed);

  /// Release all resources, the instance should not be used after this.
  Future release();
}

enum StopReason {
  none,
  eos,
  maxTokens,
  // canceled by user
  canceled,
  error,
  timeout,
}

enum Backend {
  /// Android, Windows and Linux
  ncnn('ncnn', fileExtensions: const ['bin']),
  llamacpp('llama.cpp', fileExtensions: ['gguf', 'ggml']),

  /// Unsupported on Android
  webRwkv('web-rwkv', fileExtensions: const ['st', 'prefab']),
  qnn('qnn', fileExtensions: const ['rmpack', 'bin']),
  mnn('mnn', fileExtensions: const ['mnn']),
  mlx('mlx', fileExtensions: const ['zip']),
  mtp_np7('mtp_np7', fileExtensions: const ['rmpack']),
  coreml('coreml', fileExtensions: const ['zip']);

  final String name;
  final List<String> fileExtensions;

  const Backend(this.name, {this.fileExtensions = const []});

  static late final _name2backend = {
    for (final backend in Backend.values) backend.name: backend,
  };

  static Backend fromString(String value) =>
      _name2backend[value.toLowerCase()]!;

  static Backend? fromModelPath(String modelPath) {
    final ext = modelPath.split('.').last.toLowerCase();
    return Backend.values
        .where(
          (backend) => backend.fileExtensions.any((element) => element == ext),
        )
        .firstOrNull;
  }
}

/// Param for init rwkv dart sdk
class InitParam {
  final String? dynamicLibDir;
  final RWKVLogLevel logLevel;

  // if using qnn, this is required
  final String? qnnLibDir;

  InitParam({
    this.dynamicLibDir,
    this.logLevel = RWKVLogLevel.debug,
    this.qnnLibDir,
  });
}

class TTSModelConfig {
  final List<String> textNormalizers;
  final String wav2vec2ModelPath;
  final String biCodecTokenizerPath;
  final String biCodecDetokenizerPath;

  TTSModelConfig({
    required this.textNormalizers,
    required this.wav2vec2ModelPath,
    required this.biCodecTokenizerPath,
    required this.biCodecDetokenizerPath,
  });
}

/// Param load rwkv model
class LoadModelParam {
  final String modelPath;
  final String tokenizerPath;
  final Backend? backend;

  final TTSModelConfig? ttsModelConfig;

  LoadModelParam({
    required this.modelPath,
    required this.tokenizerPath,
    this.backend,
    this.ttsModelConfig,
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

  final int maxTokens;

  DecodeParam({
    required this.temperature,
    required this.topK,
    required this.topP,
    required this.presencePenalty,
    required this.frequencyPenalty,
    required this.penaltyDecay,
    required this.maxTokens,
  });

  factory DecodeParam.initial() {
    return DecodeParam(
      temperature: 1.0,
      topK: 20,
      topP: 0.5,
      presencePenalty: 0.5,
      frequencyPenalty: 0.5,
      penaltyDecay: 0.996,
      maxTokens: 1000,
    );
  }

  DecodeParam copyWith({
    double? temperature,
    int? topK,
    double? topP,
    double? presencePenalty,
    double? frequencyPenalty,
    double? penaltyDecay,
    int? maxTokens,
  }) {
    return DecodeParam(
      temperature: temperature ?? this.temperature,
      topK: topK ?? this.topK,
      topP: topP ?? this.topP,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
      penaltyDecay: penaltyDecay ?? this.penaltyDecay,
      maxTokens: maxTokens ?? this.maxTokens,
    );
  }

  @override
  String toString() {
    return 'DecodeParam{temperature: $temperature, topK: $topK, topP: $topP, presencePenalty: $presencePenalty, frequencyPenalty: $frequencyPenalty, penaltyDecay: $penaltyDecay}';
  }
}

class GenerationConfig {
  static const thinkingTokenNone = "";
  static const thinkingTokenFree = r"<think>";

  final bool chatReasoning;
  final bool forceReasoning;
  final bool addGenerationPrompt;

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

  final bool spaceAfterRole;

  GenerationConfig({
    required this.thinkingToken,
    required this.chatReasoning,
    required this.completionStopToken,
    required this.prompt,
    required this.returnWholeGeneratedResult,
    this.forceReasoning = false,
    this.addGenerationPrompt = false,
    this.tokenBanned = const [],
    this.spaceAfterRole = true,
    this.assistantRole = "Assistant",
    this.userRole = "User",
    this.eosToken,
    this.bosToken,
  });

  factory GenerationConfig.initial() {
    return GenerationConfig(
      thinkingToken: thinkingTokenNone,
      chatReasoning: false,
      completionStopToken: 0,
      prompt: "",
      returnWholeGeneratedResult: false,
    );
  }

  GenerationConfig copyWith({
    int? maxTokens,
    bool? chatReasoning,
    String? thinkingToken,
    int? completionStopToken,
    String? prompt,
    bool? returnWholeGeneratedResult,
  }) {
    return GenerationConfig(
      thinkingToken: thinkingToken ?? this.thinkingToken,
      chatReasoning: chatReasoning ?? this.chatReasoning,
      completionStopToken: completionStopToken ?? this.completionStopToken,
      prompt: prompt ?? this.prompt,
      returnWholeGeneratedResult:
          returnWholeGeneratedResult ?? this.returnWholeGeneratedResult,
    );
  }

  @override
  String toString() {
    return 'GenerateConfig{chatReasoning: $chatReasoning, thinkingToken: $thinkingToken, completionStopToken: $completionStopToken, prompt: $prompt, returnWholeGeneratedResult: $returnWholeGeneratedResult}';
  }
}

class GenerationState {
  final bool isGenerating;
  final double prefillProgress;
  final double prefillSpeed;
  final double decodeSpeed;
  final int timestamp;

  GenerationState({
    required this.isGenerating,
    required this.prefillProgress,
    required this.prefillSpeed,
    required this.decodeSpeed,
    required this.timestamp,
  });

  factory GenerationState.initial() {
    return GenerationState(
      isGenerating: false,
      prefillProgress: 0,
      prefillSpeed: 0,
      decodeSpeed: 0,
      timestamp: 0,
    );
  }

  GenerationState copyWith({
    bool? isGenerating,
    double? prefillProgress,
    double? prefillSpeed,
    double? decodeSpeed,
    int? timestamp,
  }) {
    return GenerationState(
      isGenerating: isGenerating ?? this.isGenerating,
      prefillProgress: prefillProgress ?? this.prefillProgress,
      prefillSpeed: prefillSpeed ?? this.prefillSpeed,
      decodeSpeed: decodeSpeed ?? this.decodeSpeed,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  bool equals(Object? other) {
    if (other is GenerationState) {
      return isGenerating == other.isGenerating &&
          prefillProgress == other.prefillProgress &&
          prefillSpeed == other.prefillSpeed &&
          decodeSpeed == other.decodeSpeed;
    }
    return false;
  }

  @override
  String toString() {
    return 'GenerationState(isGenerating: $isGenerating, prefillProgress: $prefillProgress, prefillSpeed: $prefillSpeed, decodeSpeed: $decodeSpeed, timestamp: $timestamp)';
  }
}

class RunEvaluationParam {
  final String source;
  final String target;

  RunEvaluationParam({required this.source, required this.target});
}

class RunEvaluationResult {
  final List<bool> corrects;
  final List<double> logits;

  RunEvaluationResult({required this.corrects, required this.logits});
}

class TextToSpeechParam {
  final String text;
  final String outputAudioPath;
  final String inputAudioPath;
  final String? inputAudioText;

  TextToSpeechParam({
    required this.text,
    required this.outputAudioPath,
    required this.inputAudioPath,
    this.inputAudioText,
  });
}

class GenerationResponse {
  final String text;
  final int tokenCount;
  final StopReason stopReason;
  final List<String>? choices;
  final List<StopReason>? stopReasons;

  GenerationResponse({
    required this.text,
    this.tokenCount = -1,
    this.stopReason = StopReason.none,
    this.choices,
    this.stopReasons,
  });
}

class GenerationParam {
  final String prompt;

  final String? model;
  final int? maxTokens;
  final int? maxCompletionTokens;
  final String? reasoning;
  final List<int>? stopSequence;
  final Map<String, dynamic>? additional;

  GenerationParam({
    required this.prompt,
    this.model,
    this.maxTokens,
    this.maxCompletionTokens,
    this.reasoning,
    this.stopSequence,
    this.additional,
  });
}

class ChatParam {
  final List<String> messages;
  final List<String>? batch;

  final String? model;
  final int? maxCompletionTokens;
  final int? maxTokens;
  final String? reasoning;
  final List<int>? stopSequence;
  final Map<String, dynamic>? additional;
  final String? system;

  ChatParam({
    required this.messages,
    this.batch,
    this.model,
    this.reasoning,
    this.additional,
    this.stopSequence,
    this.maxTokens,
    this.maxCompletionTokens,
    this.system,
  });
}
