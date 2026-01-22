@pragma("json_id:76fd188f99347022ef3fda8e2680bbbb")
class OpenaiModelBean {
  final String ownedBy;
  final String id;
  final String object;

  OpenaiModelBean({
    required this.ownedBy,
    required this.id,
    required this.object,
  });

  factory OpenaiModelBean.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return OpenaiModelBean(
      ownedBy: json['owned_by'] ?? '',
      id: json['id'] ?? '',
      object: json['object'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['owned_by'] = ownedBy;
    data['id'] = id;
    data['object'] = object;
    return data;
  }

}
