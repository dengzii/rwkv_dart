@pragma("json_id:d4c6da08321d9a4aa40fa9cca0185ef3")
class DeltaBean {
  final String content;

  DeltaBean({
    required this.content,
  });

  factory DeltaBean.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return DeltaBean(
      content: json['content'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['content'] = content;
    return data;
  }

}
