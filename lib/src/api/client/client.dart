import 'package:dio/dio.dart';
import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/bean/openai/openai_model_bean.dart';
import 'package:rwkv_dart/src/api/client/open_ai.dart';

class LoadedModel {
  final ModelBaseInfo info;
  final RWKV rwkv;

  LoadedModel({required this.info, required this.rwkv});
}

enum ServiceType {
  unknown,
  openai,
  rwkv, //
}

class RwkvServiceClient {
  final String name;
  final String id;
  final String url;
  final Dio _dio = Dio();

  List<LoadedModel> _loadedModels = [];

  ServiceType _serviceType = ServiceType.openai;

  ServiceType get serviceType => _serviceType;

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
    List<ModelBean> models = [];
    final rwkv = await _dio
        .get('/health')
        .then((e) => e.data)
        .timeout(Duration(seconds: 1))
        .catchError((e, s) async => null);

    if (rwkv == 'rwkv') {
      final resp = await _dio.get('/v1/models');
      final list = resp.data['data'] as Iterable? ?? [];
      models = list.map(ModelBean.fromJson).toList();
      _loadedModels = [
        for (final m in models)
          LoadedModel(
            info: ModelBaseInfo(
              name: m.name,
              modelId: m.id,
              instanceId: m.id,
              port: 0,
            ),
            rwkv: OpenAiApiClient(url, apiKey: ''),
          ),
      ];
      _serviceType = ServiceType.rwkv;
    } else {
      final resp = await _dio.get('/v1/models').timeout(Duration(seconds: 2));
      final list = resp.data['data'] as Iterable? ?? [];
      models = list
          .map(OpenaiModelBean.fromJson)
          .map((e) => ModelBean.fromJson({'name': e.id, 'id': e.id}))
          .toList();
      _loadedModels = [
        for (final m in models)
          LoadedModel(
            info: ModelBaseInfo(
              name: m.id,
              modelId: m.id,
              instanceId: m.id,
              port: 0,
            ),
            rwkv: OpenAiApiClient(url, apiKey: ''),
          ),
      ];
      _serviceType = ServiceType.openai;
    }
    return ServiceStatus(
      hostname: '',
      system: '',
      serviceId: url,
      id: id,
      uptime: 0,
      models: models,
      loadedModels: _loadedModels.map((e) => e.info).toList(),
    );
  }

  Future<LoadedModel> create(String modelId) async {
    final m = _loadedModels.where((e) => e.info.modelId == modelId).firstOrNull;
    if (m != null) {
      return m;
    }

    if (serviceType == ServiceType.openai) {
      throw 'not supported';
    }

    final response = await _dio.get(
      '/create',
      queryParameters: {'model_id': modelId},
    );
    final port = response.data['port'] as int;
    final info = ModelBaseInfo.fromJson(response.data['model']);
    final uri = Uri.parse(url).replace(port: port).replace(path: '/');
    return LoadedModel(info: info, rwkv: OpenAiApiClient(uri.toString()));
  }

  Future<List<ModelBean>> getModels() async {
    if (_serviceType == ServiceType.unknown) {
      await status();
    }
    if (_serviceType == ServiceType.openai) {
      final resp = await _dio.get('/v1/models').timeout(Duration(seconds: 2));
      final list = resp.data['data'] as Iterable? ?? [];
      final models = list.map(OpenaiModelBean.fromJson);
      return [
        for (final m in models) ModelBean.fromJson({'name': m.id, 'id': m.id}),
      ];
    }
    if (_serviceType == ServiceType.rwkv) {
      final resp = await _dio.get('/v1/models').timeout(Duration(seconds: 2));
      final list = resp.data as Iterable? ?? [];
      return list.map(ModelBean.fromJson).toList();
    }
    return [];
  }

  Future<List<LoadedModel>> getLoadedModels() async {
    if (_serviceType == ServiceType.unknown) {
      await status();
    }
    return _loadedModels;
  }
}
