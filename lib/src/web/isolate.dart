import 'package:rwkv_dart/rwkv_dart.dart';

class RWKVIsolateProxy implements RWKV {
  RWKVIsolateProxy() {
    throw 'isolate is unsupported in browser, use RWKV.create() instead.';
  }

  @override
  Stream<GenerationResponse> chat(List<String> history) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> clearState() {
    throw UnimplementedError();
  }

  @override
  Future<String> dumpLog() {
    throw UnimplementedError();
  }

  @override
  Future<String> dumpStateInfo() {
    throw UnimplementedError();
  }

  @override
  Stream<GenerationResponse> generate(String prompt) {
    throw UnimplementedError();
  }

  @override
  Stream<GenerationState> generationStateStream() {
    throw UnimplementedError();
  }

  @override
  Future<GenerationState> getGenerationState() {
    throw UnimplementedError();
  }

  @override
  Future<String> getHtpArch() {
    throw UnimplementedError();
  }

  @override
  Future<int> getSeed() {
    throw UnimplementedError();
  }

  @override
  Future<String> getSocName() {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> init([InitParam? param]) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> loadInitialState(String statePath) {
    throw UnimplementedError();
  }

  @override
  Future<int> loadModel(LoadModelParam param) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> release() {
    throw UnimplementedError();
  }

  @override
  Future<RunEvaluationResult> runEvaluation(RunEvaluationParam param) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> setDecodeParam(DecodeParam param) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> setGenerationConfig(GenerationConfig param) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> setImage(String path) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> setImageId(String id) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> setLogLevel(RWKVLogLevel level) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> setSeed(int seed) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> stopGenerate() {
    throw UnimplementedError();
  }

  @override
  Stream<List<double>> textToSpeech(TextToSpeechParam param) {
    throw UnimplementedError();
  }
}
