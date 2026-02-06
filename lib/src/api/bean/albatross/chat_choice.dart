import 'chat_message.dart';

@pragma("json_id:chat_choice_001")
class ChatChoice {
  final int index;
  final ChatMessage message;
  final String? finishReason;

  ChatChoice({
    required this.index,
    required this.message,
    this.finishReason,
  });

  factory ChatChoice.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return ChatChoice(
      index: json['index'] ?? 0,
      message: ChatMessage.fromJson(json['message'] ?? {}),
      finishReason: json['finish_reason'],
    );
  }
}
