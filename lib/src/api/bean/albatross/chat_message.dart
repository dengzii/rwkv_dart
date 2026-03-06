@pragma("json_id:chat_message_001")
class ChatMessageBean {
  final String role;
  final String content;

  ChatMessageBean({
    required this.role,
    required this.content,
  });

  factory ChatMessageBean.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return ChatMessageBean(
      role: json['role'] ?? '',
      content: json['content'] ?? '',
    );
  }
}
