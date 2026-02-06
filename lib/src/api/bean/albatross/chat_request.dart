import '../openai/messages_bean.dart';

@pragma("json_id:chat_request_001")
class ChatRequest {
  final List<String>? contents;
  final List<MessageBean>? messages;
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
  final bool? padZero;
  final bool? enableThink;
  final String? sessionId;
  final int? nextContentIdx;
  final int? sessionIndex;
  final String? password;

  ChatRequest({
    this.contents,
    this.messages,
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
    this.padZero,
    this.enableThink,
    this.sessionId,
    this.nextContentIdx,
    this.sessionIndex,
    this.password,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    if (contents != null) data['contents'] = contents;
    if (messages != null) data['messages'] = messages!.map((e) => e.toJson()).toList();
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
    if (padZero != null) data['pad_zero'] = padZero;
    if (enableThink != null) data['enable_think'] = enableThink;
    if (sessionId != null) data['session_id'] = sessionId;
    if (nextContentIdx != null) data['next_content_idx'] = nextContentIdx;
    if (sessionIndex != null) data['session_index'] = sessionIndex;
    if (password != null) data['password'] = password;
    return data;
  }
}
