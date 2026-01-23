@pragma("json_id:d45e6696de7e46b8e8f7db863767321d")
class ModelBean {
  final String path;
  final int fileSize;
  final String name;
  final String backend;
  final String id;
  final num modelSize;
  final String url;
  final num updatedAt;
  final List<String> groups;
  final List<String> tags;
  final String tokenizer;

  ModelBean({
    required this.path,
    required this.fileSize,
    required this.name,
    required this.backend,
    required this.id,
    required this.modelSize,
    required this.url,
    required this.updatedAt,
    required this.groups,
    required this.tags,
    required this.tokenizer,
  });

  factory ModelBean.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return ModelBean(
      path: json['path'] ?? '',
      fileSize: json['fileSize'] ?? 0,
      name: json['name'] ?? '',
      backend: json['backend'] ?? '',
      id: json['id'] ?? '',
      modelSize: json['modelSize'] ?? 0,
      url: json['url'] ?? '',
      updatedAt: json['updatedAt'] ?? 0,
      groups: (json['groups'] as Iterable?)?.map((e) => e as String).toList() ??
          [],
      tags: (json['tags'] as Iterable?)?.map((e) => e as String).toList() ?? [],
      tokenizer: json['tokenizer'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['path'] = path;
    data['fileSize'] = fileSize;
    data['name'] = name;
    data['backend'] = backend;
    data['id'] = id;
    data['modelSize'] = modelSize;
    data['url'] = url;
    data['updatedAt'] = updatedAt;
    data['groups'] = groups;
    data['tags'] = tags;
    data['tokenizer'] = tokenizer;
    return data;
  }

}
