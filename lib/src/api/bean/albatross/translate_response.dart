import 'translation.dart';

@pragma("json_id:translate_response_001")
class TranslateResponse {
  final List<Translation> translations;

  TranslateResponse({
    required this.translations,
  });

  factory TranslateResponse.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return TranslateResponse(
      translations:
          (json['translations'] as Iterable?)
              ?.map((e) => Translation.fromJson(e))
              .toList() ??
          [],
    );
  }
}
