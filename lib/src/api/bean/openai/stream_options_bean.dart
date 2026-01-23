@pragma("json_id:bbbcb5b7a9b26db8ede27cfcd4d26284")
class StreamOptionsBean {
  final bool includeUsage;

  StreamOptionsBean({
    required this.includeUsage,
  });

  factory StreamOptionsBean.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return StreamOptionsBean(
      includeUsage: json['include_usage'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['include_usage'] = includeUsage;
    return data;
  }

}
