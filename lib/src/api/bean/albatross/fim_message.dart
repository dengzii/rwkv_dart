@pragma("json_id:fim_message_001")
class FimMessage {
  final String role;
  final String content;

  FimMessage({
    required this.role,
    required this.content,
  });

  factory FimMessage.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return FimMessage(
      role: json['role'] ?? '',
      content: json['content'] ?? '',
    );
  }
}
