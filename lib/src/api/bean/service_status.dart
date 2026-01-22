import 'package:rwkv_dart/src/api/bean/model_base_info.dart';

import 'models_bean.dart';

@pragma("json_id:9e6f17a542d22ce20cabb68b91a480ad")
class ServiceStatus {
  final String hostname;
  final String system;
  final String serviceId;
  final String id;
  final num uptime;
  final List<ModelBean> models;
  final List<ModelBaseInfo> loadedModels;

  ServiceStatus({
    required this.hostname,
    required this.system,
    required this.serviceId,
    required this.id,
    required this.uptime,
    required this.models,
    required this.loadedModels,
  });

  factory ServiceStatus.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return ServiceStatus(
      hostname: json['hostname'] ?? '',
      system: json['system'] ?? '',
      serviceId: json['service_id'] ?? '',
      id: json['id'] ?? '',
      uptime: json['uptime'] ?? 0,
      models:
          (json['models'] as Iterable?)
              ?.map((e) => ModelBean.fromJson(e))
              .toList() ??
          [],
      loadedModels:
          (json['loaded_models'] as Iterable?)
              ?.map((e) => ModelBaseInfo.fromJson(e))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['hostname'] = hostname;
    data['system'] = system;
    data['service_id'] = serviceId;
    data['id'] = id;
    data['uptime'] = uptime;
    data['models'] = models.map((e) => e.toJson()).toList();
    data['loaded_models'] = loadedModels.map((e) => e.toJson()).toList();
    return data;
  }
}
