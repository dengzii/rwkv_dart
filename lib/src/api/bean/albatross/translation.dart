@pragma("json_id:translation_001")
class Translation {
  final String detectedSourceLang;
  final String text;

  Translation({
    required this.detectedSourceLang,
    required this.text,
  });

  factory Translation.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return Translation(
      detectedSourceLang: json['detected_source_lang'] ?? '',
      text: json['text'] ?? '',
    );
  }
}
