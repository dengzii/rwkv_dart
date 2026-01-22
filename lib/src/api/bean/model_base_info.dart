class ModelBaseInfo {
  final String name;
  final String modelId;
  final String instanceId;
  final int port;

  ModelBaseInfo({
    required this.name,
    required this.modelId,
    required this.instanceId,
    required this.port,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['name'] = name;
    data['model_id'] = modelId;
    data['instance_id'] = instanceId;
    data['port'] = port;
    return data;
  }

  static ModelBaseInfo fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return ModelBaseInfo(
      name: json['name'] ?? '',
      modelId: json['model_id'] ?? '',
      instanceId: json['instance_id'] ?? '',
      port: json['port'] ?? 0,
    );
  }
}
