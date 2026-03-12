import 'messages_bean.dart';
import 'stream_options_bean.dart';

@pragma("json_id:28d97dbbd8296b967d2725374e62b3ab")
class CompletionBean {
  final bool stream;
  final String model;
  final List<MessageBean> messages;
  final StreamOptionsBean? streamOptions;
  final String? prompt;
  final String? reasoningEffort;
  final int? maxTokens;
  final int? maxCompletionTokens;
  final double? temperature;
  final int? topK;
  final double? topP;
  final double? presencePenalty;
  final double? frequencyPenalty;
  final double? penaltyDecay;
  final dynamic stop;

  CompletionBean({
    required this.stream,
    required this.model,
    required this.messages,
    this.streamOptions,
    this.prompt,
    this.reasoningEffort,
    this.maxTokens,
    this.maxCompletionTokens,
    this.temperature,
    this.topK,
    this.topP,
    this.presencePenalty,
    this.frequencyPenalty,
    this.penaltyDecay,
    this.stop,
  });

  factory CompletionBean.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return CompletionBean(
      stream: json['stream'] ?? false,
      model: json['model'] ?? '',
      messages:
          (json['messages'] as Iterable?)
              ?.map((e) => MessageBean.fromJson(e))
              .toList() ??
          [],
      streamOptions: json['stream_options'] != null
          ? StreamOptionsBean.fromJson(json['stream_options'])
          : null,
      prompt: json['prompt'] as String?,
      reasoningEffort: json['reasoning_effort'] as String?,
      maxTokens: json['max_tokens'] as int?,
      maxCompletionTokens: json['max_completion_tokens'] as int?,
      temperature: (json['temperature'] as num?)?.toDouble(),
      topK: json['top_k'] as int?,
      topP: (json['top_p'] as num?)?.toDouble(),
      presencePenalty: (json['presence_penalty'] as num?)?.toDouble(),
      frequencyPenalty: (json['frequency_penalty'] as num?)?.toDouble(),
      penaltyDecay: (json['penalty_decay'] as num?)?.toDouble(),
      stop: json['stop'],
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['stream'] = stream;
    data['model'] = model;
    data['messages'] = messages.map((e) => e.toJson()).toList();
    data['stream_options'] = streamOptions?.toJson();
    data['prompt'] = prompt;
    data['reasoning_effort'] = reasoningEffort;
    data['max_tokens'] = maxTokens;
    data['max_completion_tokens'] = maxCompletionTokens;
    data['temperature'] = temperature;
    data['top_k'] = topK;
    data['top_p'] = topP;
    data['presence_penalty'] = presencePenalty;
    data['frequency_penalty'] = frequencyPenalty;
    data['penalty_decay'] = penaltyDecay;
    data['stop'] = stop;
    return data;
  }
}
