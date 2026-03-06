import 'package:dio/dio.dart';
import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/client/open_ai.dart';
import 'package:rwkv_dart/src/logger.dart';

class LoadedModel {
  final String ownedBy;
  final ModelBean info;
  final RWKV rwkv;

  const LoadedModel({
    required this.info,
    required this.rwkv,
    required this.ownedBy,
  });
}

enum ServiceType {
  unknown,
  openai,
  rwkv, //
  albatross,
}

class ModelService {
  final String id;
  final Dio _dio = Dio();
  final String _accessKey;
  List<LoadedModel> _models = [];
  ServiceType _serviceType = ServiceType.unknown;
  bool _available = false;

  bool get available => _available;

  List<LoadedModel> get models => _models.toList();

  ServiceType get serviceType => _serviceType;

  String get url => _dio.options.baseUrl;

  static Map<String, ModelService> _cache = {};

  ModelService._({required this.id, required String url, String accessKey = ''})
    : _accessKey = accessKey {
    _dio.options.baseUrl = url;
    if (accessKey.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $accessKey';
    }
  }

  static Future<ModelService> create({
    required String url,
    String accessKey = '',
    String id = '',
  }) async {
    final uid = '$url:$id:$accessKey';

    ModelService service;
    if (_cache.containsKey(uid)) {
      service = _cache[uid]!;
    } else {
      service = ModelService._(id: id, url: url, accessKey: accessKey);
    }
    try {
      await service.refresh();
      if (!_cache.containsKey(uid)) {
        logd('model service created: $url, ${service.models.length} model(s)');
      }
    } catch (_) {
      logw('model service is not available: $url');
    }
    _cache[uid] = service;

    return service;
  }

  Future refresh() async {
    try {
      _available = false;
      await _refresh();
      _available = true;
    } catch (e) {
      rethrow;
    }
  }

  Future _refresh() async {
    List<LoadedModel> m = [];
    final resp = await _dio.get('/v1/models').timeout(Duration(seconds: 2));
    final list = resp.data['data'] as Iterable? ?? [];
    final url = _dio.options.baseUrl;

    for (final data in list) {
      final ownedBy = data['owned_by'] ?? '';
      RWKV rwkv;
      bool albatross = false;
      if ({'rwkv_lightning', "albatross"}.contains(ownedBy)) {
        rwkv = AlbatrossClient(url, password: _accessKey);
        albatross = true;
        _serviceType = ServiceType.albatross;
      } else {
        rwkv = OpenAiApiClient(url, apiKey: _accessKey);
        _serviceType = ServiceType.openai;
      }
      final info = ModelBean.fromJson({
        'name': data['id'],
        'id': data['id'],
        'fileSize': data['file_size'],
        'modelSize': data['model_size'],
        'backend': albatross ? 'albatross' : null,
        'tokenizer': data['tokenizer'],
        'tags': data['tags'],
        'groups': data['groups'],
        'updatedAt': data['updated_at'],
      });
      final model = LoadedModel(info: info, ownedBy: ownedBy, rwkv: rwkv);
      m.add(model);
    }
    _models = m;
  }
}
