import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/logger.dart';

StreamTransformer<Uint8List, GenerationResponse> sseEventTransformerV1(
  int? batch, {
  bool fixThinkStartTag = false,
}) {
  return StreamTransformer.fromBind((stream) async* {
    final lines = stream
        .transform(StreamTransformer.fromBind(utf8.decoder.bind))
        .transform(LineSplitter());

    bool insertThinkEndTag = false;
    bool insertThinkStartTag = true;
    bool completed = false;
    bool thinkStartTagFixed = !fixThinkStartTag;

    String resolveContent(Map? delta) {
      if (delta == null) return '';

      final reasoning = delta['reasoning_content'];
      final content = delta['content'];

      if (reasoning == null && content == null) {
        return '';
      }

      String result = reasoning ?? content;
      if (reasoning != null && insertThinkStartTag) {
        insertThinkEndTag = true;
        insertThinkStartTag = false;
        result = '<think>$reasoning';
      }

      if (content != null && insertThinkEndTag) {
        result = '</think>$content';
        insertThinkEndTag = false;
      }

      if (fixThinkStartTag && !thinkStartTagFixed && result.startsWith('>')) {
        result = "<think$result";
        logw('Fixing think start tag');
      }
      thinkStartTagFixed = true;

      return result;
    }

    StopReason resolveStopReason(dynamic finishReason) {
      return switch (finishReason) {
        'stop' => StopReason.eos,
        'length' => StopReason.maxTokens,
        'tool_calls' => StopReason.toolCalls,
        'cancelled' || 'canceled' => StopReason.canceled,
        'error' => StopReason.error,
        'timeout' => StopReason.timeout,
        _ => StopReason.none,
      };
    }

    List<ToolCall> resolveToolCalls(Map? delta) {
      final raw = delta?['tool_calls'];
      if (raw is! Iterable) {
        return const [];
      }
      return raw.map((e) => ToolCall.fromJson(e)).toList();
    }

    GenerationResponse? parseEvent(String event, String data) {
      final choiceList = List<String>.filled(batch ?? 1, '');

      if (event == 'PING' || data == '[PING]') {
        logd('[PING]');
        return null;
      }

      if (event == 'ERROR' || data == '[ERROR]') {
        return GenerationResponse(
          text: '',
          choices: choiceList,
          tokenCount: -1,
          stopReason: StopReason.error,
        );
      }

      if (data == '[DONE]') {
        if (completed) {
          return null;
        }
        return GenerationResponse(
          text: '',
          choices: choiceList,
          tokenCount: -1,
          stopReason: StopReason.eos,
        );
      }

      if (data.trim().isEmpty) {
        return null;
      }

      try {
        final map = jsonDecode(data.trim()) as Map<String, dynamic>;
        final isCompletion = map['object'] == 'text_completion';
        final choices = map['choices'] as List<dynamic>? ?? [];
        if (choices.isEmpty) {
          return null;
        }

        if (batch == 1 || batch == null) {
          final choice = choices.first as Map<String, dynamic>;
          final stopReason = resolveStopReason(choice['finish_reason']);
          final delta = choice['delta'] as Map<String, dynamic>?;
          final toolCalls = isCompletion
              ? const <ToolCall>[]
              : resolveToolCalls(delta);
          final text = isCompletion
              ? (choice['text'] ?? '') as String
              : resolveContent(delta);

          if (text.isEmpty &&
              toolCalls.isEmpty &&
              stopReason == StopReason.none) {
            return null;
          }

          return GenerationResponse(
            text: text,
            tokenCount: -1,
            choices: choiceList,
            stopReason: stopReason,
            toolCalls: toolCalls.isEmpty ? null : toolCalls,
          );
        }

        final stopReasons = List<StopReason>.filled(batch, StopReason.none);
        final choiceToolCalls = List<List<ToolCall>?>.filled(batch, null);
        for (final choice in choices.cast<Map<String, dynamic>>()) {
          final index = choice['index'] as int;
          stopReasons[index] = resolveStopReason(choice['finish_reason']);
          if (isCompletion) {
            choiceList[index] = (choice['text'] ?? '') as String;
          } else {
            final delta = choice['delta'] as Map<String, dynamic>?;
            choiceList[index] = resolveContent(delta);
            final toolCalls = resolveToolCalls(delta);
            if (toolCalls.isNotEmpty) {
              choiceToolCalls[index] = toolCalls;
            }
          }
        }

        final hasText = choiceList.any((e) => e.isNotEmpty);
        final hasStop = stopReasons.any((e) => e != StopReason.none);
        final hasToolCalls = choiceToolCalls.any(
          (e) => e != null && e.isNotEmpty,
        );
        if (!hasText && !hasStop && !hasToolCalls) {
          return null;
        }

        return GenerationResponse(
          text: '',
          tokenCount: -1,
          choices: choiceList,
          stopReasons: stopReasons,
          choiceToolCalls: hasToolCalls ? choiceToolCalls : null,
          stopReason: stopReasons.firstWhere(
            (e) => e != StopReason.none,
            orElse: () => StopReason.none,
          ),
        );
      } catch (e) {
        logw('Failed to parse SSE data: $e');
        return null;
      }
    }

    Future<void> flushEvent(
      String? event,
      List<String> dataLines,
      void Function(GenerationResponse response) emit,
    ) async {
      if (event == null && dataLines.isEmpty) {
        return;
      }
      final response = parseEvent(event ?? '', dataLines.join('\n'));
      if (response == null) {
        return;
      }
      if (response.stopReason != StopReason.none ||
          (response.stopReasons?.any((e) => e != StopReason.none) ?? false)) {
        completed = true;
      }
      emit(response);
    }

    String? currentEvent;
    final currentData = <String>[];

    await for (final line in lines) {
      if (line.isEmpty) {
        GenerationResponse? pending;
        await flushEvent(currentEvent, currentData, (response) {
          pending = response;
        });
        currentEvent = null;
        currentData.clear();
        if (pending != null) {
          yield pending!;
        }
        continue;
      }

      if (line.startsWith(':')) {
        continue;
      }
      logv(line);

      final index = line.indexOf(':');
      if (index != -1) {
        final field = line.substring(0, index).trim();
        final value = line.substring(index + 1).trimLeft();
        switch (field) {
          case 'event':
            currentEvent = value;
            break;
          case 'data':
            currentData.add(value);
            break;
          default:
            logw('Unexpected SSE field: $field');
        }
      } else {
        logw('Unexpected SSE line: $line');
      }
    }

    GenerationResponse? pending;
    await flushEvent(currentEvent, currentData, (response) {
      pending = response;
    });
    if (pending != null) {
      yield pending!;
    }
  });
}
