import '../openai/messages_bean.dart';

@pragma("json_id:chat_request_001")
class ChatRequest {
  final String? model;
  final List<String>? contents;
  final List<String>? prefix;
  final List<String>? suffix;
  final List<MessageBean>? messages;
  final int? maxTokens;
  final double? temperature;
  final int? topK;
  final double? topP;
  final double? noise;
  final double? alphaPresence;
  final double? alphaFrequency;
  final double? alphaDecay;
  final List<int>? stopTokens;
  final bool? stream;
  final int? chunkSize;
  final bool? padZero;
  final bool? enableThink;
  final String? sessionId;
  final int? dialogueIdx;
  final String? password;

  ChatRequest({
    this.model,
    this.contents,
    this.prefix,
    this.suffix,
    this.messages,
    this.maxTokens,
    this.temperature,
    this.topK,
    this.topP,
    this.noise,
    this.alphaPresence,
    this.alphaFrequency,
    this.alphaDecay,
    this.stopTokens,
    this.stream,
    this.chunkSize,
    this.padZero,
    this.enableThink,
    this.sessionId,
    this.dialogueIdx,
    this.password,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    if (model != null) data['model'] = model;
    if (contents != null) data['contents'] = contents;
    if (prefix != null) data['prefix'] = prefix;
    if (suffix != null) data['suffix'] = suffix;
    if (messages != null) data['messages'] = messages!.map((e) => e.toJson()).toList();
    if (maxTokens != null) data['max_tokens'] = maxTokens;
    if (temperature != null) data['temperature'] = temperature;
    if (topK != null) data['top_k'] = topK;
    if (topP != null) data['top_p'] = topP;
    if (noise != null) data['noise'] = noise;
    if (alphaPresence != null) data['alpha_presence'] = alphaPresence;
    if (alphaFrequency != null) data['alpha_frequency'] = alphaFrequency;
    if (alphaDecay != null) data['alpha_decay'] = alphaDecay;
    if (stopTokens != null) data['stop_tokens'] = stopTokens;
    if (stream != null) data['stream'] = stream;
    if (chunkSize != null) data['chunk_size'] = chunkSize;
    if (padZero != null) data['pad_zero'] = padZero;
    if (enableThink != null) data['enable_think'] = enableThink;
    if (sessionId != null) data['session_id'] = sessionId;
    if (dialogueIdx != null) data['dialogue_idx'] = dialogueIdx;
    if (password != null) data['password'] = password;
    return data;
  }
}
