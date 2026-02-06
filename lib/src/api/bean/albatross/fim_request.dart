@pragma("json_id:fim_request_001")
class FimRequest {
  final List<String> prefix;
  final List<String> suffix;
  final int? maxTokens;
  final double? temperature;
  final int? topK;
  final double? topP;
  final double? alphaPresence;
  final double? alphaFrequency;
  final double? alphaDecay;
  final List<int>? stopTokens;
  final bool? stream;
  final int? chunkSize;
  final String? password;

  FimRequest({
    required this.prefix,
    required this.suffix,
    this.maxTokens,
    this.temperature,
    this.topK,
    this.topP,
    this.alphaPresence,
    this.alphaFrequency,
    this.alphaDecay,
    this.stopTokens,
    this.stream,
    this.chunkSize,
    this.password,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['prefix'] = prefix;
    data['suffix'] = suffix;
    if (maxTokens != null) data['max_tokens'] = maxTokens;
    if (temperature != null) data['temperature'] = temperature;
    if (topK != null) data['top_k'] = topK;
    if (topP != null) data['top_p'] = topP;
    if (alphaPresence != null) data['alpha_presence'] = alphaPresence;
    if (alphaFrequency != null) data['alpha_frequency'] = alphaFrequency;
    if (alphaDecay != null) data['alpha_decay'] = alphaDecay;
    if (stopTokens != null) data['stop_tokens'] = stopTokens;
    if (stream != null) data['stream'] = stream;
    if (chunkSize != null) data['chunk_size'] = chunkSize;
    if (password != null) data['password'] = password;
    return data;
  }
}
