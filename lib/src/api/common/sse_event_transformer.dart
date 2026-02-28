import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/logger.dart';

StreamTransformer<Uint8List, GenerationResponse> sseEventTransformer(
  int? batch,
) {
  return StreamTransformer.fromBind((stream) async* {
    await for (final line
        in stream.transform(_utf8Decoder).transform(LineSplitter())) {
      if (line.isEmpty) continue;

      // print(line);

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
            text = delta?['content'] as String? ?? '';
          } else {
            for (final choice in choices) {
              final index = choice['index'] as int;
              final delta = choice['delta']?['content'] ?? '';
              choiceList[index] = delta;
            }
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

StreamTransformer<Uint8List, String> _utf8Decoder =
    StreamTransformer.fromHandlers(
      handleData: (data, sink) {
        sink.add(utf8.decode(data, allowMalformed: true));
      },
    );
