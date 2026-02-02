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

  CompletionBean({
    required this.stream,
    required this.model,
    required this.messages,
    this.streamOptions,
    this.prompt,
    this.reasoningEffort,
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
      prompt: data['prompt'],
      reasoningEffort: data['reasoning_effort']
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
    return data;
  }
}
