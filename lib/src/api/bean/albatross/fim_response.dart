import 'fim_choice.dart';

@pragma("json_id:fim_response_001")
class FimResponse {
  final String id;
  final String object;
  final String model;
  final List<FimChoice> choices;

  FimResponse({
    required this.id,
    required this.object,
    required this.model,
    required this.choices,
  });

  factory FimResponse.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return FimResponse(
      id: json['id'] ?? '',
      object: json['object'] ?? '',
      model: json['model'] ?? '',
      choices:
          (json['choices'] as Iterable?)
              ?.map((e) => FimChoice.fromJson(e))
              .toList() ??
          [],
    );
  }
}
