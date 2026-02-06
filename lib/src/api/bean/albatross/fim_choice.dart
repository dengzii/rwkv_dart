import 'fim_message.dart';

@pragma("json_id:fim_choice_001")
class FimChoice {
  final int index;
  final FimMessage message;
  final String? finishReason;

  FimChoice({
    required this.index,
    required this.message,
    this.finishReason,
  });

  factory FimChoice.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return FimChoice(
      index: json['index'] ?? 0,
      message: FimMessage.fromJson(json['message'] ?? {}),
      finishReason: json['finish_reason'],
    );
  }
}
