@pragma("json_id:0698e221b02cfaabfa7aebb96c879546")
class MessageBean {
  final String role;
  final String content;

  MessageBean({
    required this.role,
    required this.content,
  });

  factory MessageBean.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return MessageBean(
      role: json['role'] ?? '',
      content: json['content'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['role'] = role;
    data['content'] = content;
    return data;
  }

}
