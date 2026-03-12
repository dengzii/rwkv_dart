import 'dart:convert';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/api/bean/openai/completion_bean.dart';
import 'package:shelf/shelf.dart';

class ParsedRequest {
  final ChatParam? chatParam;
  final GenerationParam? genParam;
  final DecodeParam? decodeParam;
  final String? modelId;
  final bool stream;
  final String raw;

  ParsedRequest._({
    required this.raw,
    required this.chatParam,
    required this.genParam,
    required this.decodeParam,
    required this.modelId,
    required this.stream,
  });

  static List<int>? _parseStopSequence(dynamic value) {
    if (value is int) {
      return [value];
    }
    if (value is Iterable) {
      final stops = <int>[];
      for (final item in value) {
        if (item is int) {
          stops.add(item);
        } else {
          return null;
        }
      }
      return stops;
    }
    return null;
  }

  static DecodeParam? _parseDecodeParam(CompletionBean completion) {
    final effectiveMaxTokens =
        completion.maxCompletionTokens ?? completion.maxTokens;
    final hasOverride =
        completion.temperature != null ||
        completion.topK != null ||
        completion.topP != null ||
        completion.presencePenalty != null ||
        completion.frequencyPenalty != null ||
        completion.penaltyDecay != null ||
        effectiveMaxTokens != null;
    if (!hasOverride) {
      return null;
    }
    return DecodeParam.initial().copyWith(
      temperature: completion.temperature,
      topK: completion.topK,
      topP: completion.topP,
      presencePenalty: completion.presencePenalty,
      frequencyPenalty: completion.frequencyPenalty,
      penaltyDecay: completion.penaltyDecay,
      maxTokens: effectiveMaxTokens,
    );
  }

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
    final maxTokens = completion.maxCompletionTokens ?? completion.maxTokens;
    final stopSequence = _parseStopSequence(completion.stop);
    final decodeParam = _parseDecodeParam(completion);

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
        maxTokens: maxTokens,
        maxCompletionTokens: completion.maxCompletionTokens,
        stopSequence: stopSequence,
      );
    } else if (completion.prompt != null) {
      genParam = GenerationParam(
        model: completion.model,
        prompt: completion.prompt!,
        maxTokens: maxTokens,
        maxCompletionTokens: completion.maxCompletionTokens,
        stopSequence: stopSequence,
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
      decodeParam: decodeParam,
      modelId: modelId,
      stream: completion.stream,
    );
  }
}
