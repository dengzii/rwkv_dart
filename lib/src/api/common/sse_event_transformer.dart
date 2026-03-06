import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/logger.dart';

StreamTransformer<Uint8List, GenerationResponse> sseEventTransformer(
  int? batch,
) {
  return StreamTransformer.fromBind((stream) async* {
    final lines = stream
        .transform(StreamTransformer.fromBind(utf8.decoder.bind))
        .transform(LineSplitter());

    bool insertThinkEndTag = false;
    bool insertThinkStartTag = true;

    String _resolveContent(Map? delta) {
      if (delta == null) return '';

      /// DeepSeek style
      final reasoning = delta['reasoning_content'];
      final content = delta['content'];

      if (reasoning == null && content == null) {
        logw('bad sse event, no content or reasoning');
        return '';
      }

      String result = reasoning != null ? reasoning : content;
      if (reasoning != null && insertThinkStartTag) {
        insertThinkEndTag = true;
        insertThinkStartTag = false;
        result = '<think>${reasoning}';
      }

      if (content != null && insertThinkEndTag) {
        result = '</think>${content}';
        insertThinkEndTag = false;
      }

      return result;
    }

    await for (final line in lines) {
      if (line.isEmpty) continue;

      logv(line);

      String event = '';
      String data = '';

      final index = line.indexOf(': ');
      if (index != -1) {
        event = line.substring(0, index).trim();
        data = line.substring(index + 2).trim();
      } else {
        logw('Unexpected SSE line: $line');
        continue;
      }

      if (event != 'data') continue;

      List<String> choiceList = List.filled(batch ?? 1, '');

      if (data == '[DONE]') {
        yield GenerationResponse(
          text: '',
          choices: choiceList,
          tokenCount: -1,
          stopReason: StopReason.eos,
        );
        break;
      }

      if (data == '[PING]') {
        logd('[PING]');
        continue;
      }

      if (data == '[ERROR]') {
        yield GenerationResponse(
          text: '',
          choices: choiceList,
          tokenCount: -1,
          stopReason: StopReason.error,
        );
        break;
      }

      if (data.trim().isEmpty) continue;

      try {
        final map = jsonDecode(data.trim()) as Map<String, dynamic>;
        final choices = map['choices'] as List<dynamic>?;
        if (choices != null) {
          String text = '';
          if (batch == 1 || batch == null) {
            final choice = choices.first as Map<String, dynamic>;
            final delta = choice['delta'] as Map<String, dynamic>?;
            text = _resolveContent(delta);
          } else {
            for (final choice in choices) {
              final index = choice['index'] as int;
              final delta = choice['delta']?['content'] ?? '';
              choiceList[index] = delta;
            }
          }

          /// Avoid emit empty content
          if (text.isEmpty && (batch == 1 || batch == null)) {
            continue;
          }

          yield GenerationResponse(
            text: text,
            tokenCount: -1,
            choices: choiceList,
            stopReason: StopReason.none,
          );
        }
      } catch (e) {
        logw('Failed to parse SSE data: $e');
      }
    }
  });
}
