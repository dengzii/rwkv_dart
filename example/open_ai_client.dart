import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/client/open_ai.dart';

void main() async {
  final cli = OpenAiApiClient('BASE_URL', apiKey: 'API_KEY');

  await cli.init();

  final st = cli.chat(
    ChatParam.openAi(
      model: 'Qwen/Qwen3-8B',
      reasoning: ReasoningEffort.high,
      messages: [ChatMessage(role: 'user', content: '世界上最重要的事情是什么')],
      maxTokens: 1000,
    ),
  );

  await for (final r in st) {
    if (r.reasoningContent.isNotEmpty) {
      stderr.write(r.reasoningContent);
    } else {
      stdout.write(r.content);
    }
  }
}
