import 'package:rwkv_dart/rwkv_dart.dart';

class RWKVIsolateProxy implements RWKV {
  RWKVIsolateProxy(RWKVFactory factory) {
    throw 'isolate is unsupported in browser, use RWKV.create() instead.';
  }

  @override
  Stream<GenerationResponse> chat(ChatParam param) {
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
  Stream<GenerationResponse> generate(GenerationParam param) {
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
  Future<int> getSeed() {
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
  Future<dynamic> setDecodeParam(DecodeParam param) {
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

}
