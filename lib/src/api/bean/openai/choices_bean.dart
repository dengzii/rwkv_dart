import 'delta_bean.dart';

@pragma("json_id:18e504b265f8647270317a50e174459e")
class ChoicesBean {
  final dynamic finishReason;
  final int index;
  final dynamic logprobs;
  final String? text;
  final DeltaBean? delta;

  ChoicesBean({
    required this.finishReason,
    required this.index,
    required this.logprobs,
    this.text,
    this.delta,
  });

  factory ChoicesBean.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return ChoicesBean(
      finishReason: json['finish_reason'] ?? null,
      index: json['index'] ?? 0,
      logprobs: json['logprobs'] ?? null,
      delta: json['delta'] != null ? DeltaBean.fromJson(json['delta']) : null,
      text: json['text'],
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['finish_reason'] = finishReason;
    data['index'] = index;
    data['logprobs'] = logprobs;
    data['delta'] = delta?.toJson();
    data['text'] = text;
    return data;
  }

}
