@pragma("json_id:chat_message_001")
class ChatMessage {
  final String role;
  final String content;

  ChatMessage({
    required this.role,
    required this.content,
  });

  factory ChatMessage.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return ChatMessage(
      role: json['role'] ?? '',
      content: json['content'] ?? '',
    );
  }
}
