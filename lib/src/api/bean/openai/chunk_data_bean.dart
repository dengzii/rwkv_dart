import 'choices_bean.dart';

@pragma("json_id:90df0217387f2040f5c1b654c7ce7157")
class ChunkDataBean {
  final int created;
  final String model;
  final String id;
  final String systemFingerprint;
  final String object;
  final List<ChoicesBean> choices;

  ChunkDataBean({
    required this.created,
    required this.model,
    required this.id,
    required this.systemFingerprint,
    required this.object,
    required this.choices,
  });

  factory ChunkDataBean.fromJson(dynamic json) {
    return ChunkDataBean(
      created: json['created'] ?? 0,
      model: json['model'] ?? '',
      id: json['id'] ?? '',
      systemFingerprint: json['system_fingerprint'] ?? '',
      object: json['object'] ?? '',
      choices: (json['choices'] as Iterable?)?.map((e) =>
          ChoicesBean.fromJson(e)).toList() ?? [],
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['created'] = created;
    data['model'] = model;
    data['id'] = id;
    data['system_fingerprint'] = systemFingerprint;
    data['object'] = object;
    data['choices'] = choices.map((e) => e.toJson()).toList();
    return data;
  }

}
