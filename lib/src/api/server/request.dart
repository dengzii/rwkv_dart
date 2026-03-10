import 'dart:convert';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/bean/openai/completion_bean.dart';
import 'package:shelf/shelf.dart';

class ParsedRequest {
  final ChatParam? chatParam;
  final GenerationParam? genParam;
  final String? modelId;
  final bool stream;
  final String raw;

  ParsedRequest._({
    required this.raw,
    required this.chatParam,
    required this.genParam,
    required this.modelId,
    required this.stream,
  });

  static Future<ParsedRequest> parse(Request req) async {
    final body = await req.readAsString();

    if (body.isEmpty) {
      throw "body is empty";
    }

    ChatParam? chatParam;
    GenerationParam? genParam;
    String? modelId;

    final json = jsonDecode(body);
    final completion = CompletionBean.fromJson(json);

    if (completion.messages.isNotEmpty) {
      final ms = completion.messages.toList();
      final system = ms.where((e) => e.role == 'system').firstOrNull;
      if (system != null) {
        ms.remove(system);
      }
      final reasoning = completion.reasoningEffort == null
          ? null
          : ReasoningEffort.values
                .where((e) => e.name == completion.reasoningEffort)
                .firstOrNull;
      final cm = ms
          .map((e) => ChatMessage(role: e.role, content: e.content))
          .toList();
      chatParam = ChatParam(
        model: completion.model,
        systemPrompt: system?.content,
        reasoning: reasoning,
        messages: cm,
      );
    } else if (completion.prompt != null) {
      genParam = GenerationParam(
        model: completion.model,
        prompt: completion.prompt!,
      );
    }
    if (chatParam == null && genParam == null) {
      throw 'invalid request';
    }
    modelId = completion.model;
    if (modelId.isEmpty) {
      throw 'invalid request';
    }
    return ParsedRequest._(
      raw: body,
      chatParam: chatParam,
      genParam: genParam,
      modelId: modelId,
      stream: completion.stream,
    );
  }
}
