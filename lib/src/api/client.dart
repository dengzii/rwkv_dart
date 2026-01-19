import 'package:dio/dio.dart';
import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/model_base_info.dart';
import 'package:rwkv_dart/src/api/service_status.dart';

class LoadedModel {
  final ModelBaseInfo info;
  final RWKV rwkv;

  LoadedModel({required this.info, required this.rwkv});
}

class RwkvServiceClient {
  final String name;
  final String id;
  final String url;
  final Dio _dio = Dio();

  RwkvServiceClient({
    required this.name,
    required this.id,
    required this.url,
    String accessKey = '',
  }) {
    _dio.options.baseUrl = url;
    _dio.options.headers['X-Access-Key'] = accessKey;
  }

  Future<ServiceStatus> status() async {
    final response = await _dio.get('/status');
    return ServiceStatus.fromJson(response.data);
  }

  Future<LoadedModel> create(String modelId) async {
    final response = await _dio.get(
      '/create',
      queryParameters: {'model_id': modelId},
    );
    final port = response.data['port'] as int;
    final info = ModelBaseInfo.fromJson(response.data['model']);
    final uri = Uri.parse(url).replace(port: port).replace(path: '/');
    return LoadedModel(info: info, rwkv: RwkvApiClient(uri.toString()));
  }

  Future<LoadedModel> connect(String instanceId) async {
    final response = await _dio.get(
      '/connect',
      queryParameters: {'instanceId': instanceId},
    );
    final port = response.data['port'] as int;
    final info = ModelBaseInfo.fromJson(response.data['model']);
    final uri = Uri.parse(url).replace(port: port).replace(path: '/');
    return LoadedModel(info: info, rwkv: RwkvApiClient(uri.toString()));
  }
}

class RwkvApiClient implements RWKV {
  final String url;

  RwkvApiClient(this.url);

  @override
  Stream<GenerationResponse> chat(List<String> history) async* {
    yield GenerationResponse(
      text: 'Hello1',
      tokenCount: 1,
      stopReason: StopReason.eos,
    );
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
  Stream<GenerationState> generationStateStream() async* {
    //
  }

  @override
  Future<GenerationState> getGenerationState() async {
    return GenerationState.initial();
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
  Future<dynamic> init([InitParam? param]) async {
    //
  }

  @override
  Future<dynamic> loadInitialState(String statePath) {
    throw UnimplementedError();
  }

  @override
  Future<int> loadModel(LoadModelParam param) async {
    return 0;
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
  Future<dynamic> setDecodeParam(DecodeParam param) async {}

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
