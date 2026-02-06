import 'chat_choice.dart';

@pragma("json_id:chat_response_001")
class ChatResponse {
  final String id;
  final String object;
  final String model;
  final List<ChatChoice> choices;
  final int? sessionIndex;

  ChatResponse({
    required this.id,
    required this.object,
    required this.model,
    required this.choices,
    this.sessionIndex,
  });

  factory ChatResponse.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return ChatResponse(
      id: json['id'] ?? '',
      object: json['object'] ?? '',
      model: json['model'] ?? '',
      choices:
          (json['choices'] as Iterable?)
              ?.map((e) => ChatChoice.fromJson(e))
              .toList() ??
          [],
      sessionIndex: json['session_index'],
    );
  }
}
