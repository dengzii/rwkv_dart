@pragma("json_id:translate_request_001")
class TranslateRequest {
  final String sourceLang;
  final String targetLang;
  final List<String> textList;
  final String? password;

  TranslateRequest({
    this.sourceLang = 'auto',
    required this.targetLang,
    required this.textList,
    this.password,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['source_lang'] = sourceLang;
    data['target_lang'] = targetLang;
    data['text_list'] = textList;
    if (password != null) data['password'] = password;
    return data;
  }
}
