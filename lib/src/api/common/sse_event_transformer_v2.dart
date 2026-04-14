import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/logger.dart';

class _ResponsesToolCallState {
  final int index;
  final String? itemId;
  String? callId;
  String? name;
  String arguments;

  _ResponsesToolCallState({required this.index, required this.itemId})
    : arguments = '';
}

StreamTransformer<Uint8List, GenerationResponse> sseEventTransformerV2(
  int? batch, {
  bool fixThinkStartTag = false,
}) {
  return StreamTransformer.fromBind((stream) async* {
    final lines = stream
        .transform(StreamTransformer.fromBind(utf8.decoder.bind))
        .transform(LineSplitter());

    bool completed = false;
    final responsesToolCalls = <String, _ResponsesToolCallState>{};
    var nextResponsesToolIndex = 0;

    String resolveResponsesTextDelta(String text) {
      if (text.isEmpty) {
        return '';
      }

      if (text.startsWith('</think>')) {
        return text.substring('</think>'.length);
      }

      return text;
    }

    String resolveResponsesReasoningDelta(String reasoning) {
      if (reasoning.isEmpty) {
        return '';
      }

      if (fixThinkStartTag && reasoning.startsWith('>')) {
        logw('Fixing think start tag');
        return reasoning.substring(1);
      }

      return reasoning;
    }

    int? asInt(dynamic value) {
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      return int.tryParse(value?.toString() ?? '');
    }

    String suffixDelta(String previous, String current) {
      if (current.isEmpty) {
        return '';
      }
      if (previous.isEmpty || current.startsWith(previous)) {
        return current.substring(previous.length);
      }
      return current;
    }

    _ResponsesToolCallState getResponsesToolCallState({
      String? itemId,
      int? outputIndex,
    }) {
      final key = itemId ?? 'output:$outputIndex';
      return responsesToolCalls.putIfAbsent(key, () {
        final index = outputIndex ?? nextResponsesToolIndex++;
        if (outputIndex != null && outputIndex >= nextResponsesToolIndex) {
          nextResponsesToolIndex = outputIndex + 1;
        }
        return _ResponsesToolCallState(index: index, itemId: itemId);
      });
    }

    ToolCall toResponsesToolCall(
      _ResponsesToolCallState state, {
      String argumentsDelta = '',
    }) {
      return ToolCall(
        index: state.index,
        id: state.callId ?? state.itemId,
        type: 'function',
        function: ToolCallFunction(name: state.name, arguments: argumentsDelta),
      );
    }

    StopReason resolveResponsesIncompleteReason(Map<String, dynamic> map) {
      final response = map['response'] as Map<String, dynamic>?;
      final details = response?['incomplete_details'] as Map<String, dynamic>?;
      final reason = details?['reason']?.toString();
      return StopReason.resolve(reason);
    }

    GenerationResponse? parseEvent(String event, String data) {
      final choiceList = List<String>.filled(batch ?? 1, '');

      if (event == 'PING' || data == '[PING]') {
        logd('[PING]');
        return null;
      }

      if (event == 'ERROR' || data == '[ERROR]') {
        return GenerationResponse(
          content: '',
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
          content: '',
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
        final type = (map['type'] ?? event).toString();

        switch (type) {
          case 'response.output_text.delta':
            final text = resolveResponsesTextDelta(
              map['delta']?.toString() ?? '',
            );
            if (text.isEmpty) {
              return null;
            }
            return GenerationResponse(
              content: text,
              reasoningContent: '',
              choices: choiceList,
              tokenCount: -1,
            );
          case 'response.reasoning_text.delta':
          case 'response.reasoning.delta':
          case 'response.reasoning_summary_text.delta':
            final text = resolveResponsesReasoningDelta(
              map['delta']?.toString() ?? '',
            );
            if (text.isEmpty) {
              return null;
            }
            return GenerationResponse(
              content: '',
              reasoningContent: text,
              choices: choiceList,
              tokenCount: -1,
            );
          case 'response.function_call_arguments.delta':
            final state = getResponsesToolCallState(
              itemId: map['item_id']?.toString(),
              outputIndex: asInt(map['output_index']),
            );
            state.callId ??= map['call_id']?.toString();
            state.name ??= map['name']?.toString();
            final delta = map['delta']?.toString() ?? '';
            if (delta.isEmpty) {
              return null;
            }
            state.arguments = '${state.arguments}$delta';
            return GenerationResponse(
              content: '',
              choices: choiceList,
              tokenCount: -1,
              toolCalls: [toResponsesToolCall(state, argumentsDelta: delta)],
            );
          case 'response.output_item.added':
          case 'response.output_item.done':
            final item = map['item'] as Map<String, dynamic>?;
            if (item == null || item['type'] != 'function_call') {
              return null;
            }

            final state = getResponsesToolCallState(
              itemId: item['id']?.toString(),
              outputIndex: asInt(map['output_index']),
            );
            final previousCallId = state.callId;
            final previousName = state.name;
            final previousArguments = state.arguments;

            state.callId = item['call_id']?.toString() ?? state.callId;
            state.name = item['name']?.toString() ?? state.name;
            final arguments = item['arguments']?.toString() ?? state.arguments;
            final argumentsDelta = suffixDelta(previousArguments, arguments);
            state.arguments = arguments;

            final metadataChanged =
                state.callId != previousCallId || state.name != previousName;
            if (!metadataChanged && argumentsDelta.isEmpty) {
              return null;
            }

            return GenerationResponse(
              content: '',
              choices: choiceList,
              tokenCount: -1,
              toolCalls: [
                toResponsesToolCall(state, argumentsDelta: argumentsDelta),
              ],
            );
          case 'response.completed':
            if (completed) {
              return null;
            }
            return GenerationResponse(
              content: '',
              choices: choiceList,
              tokenCount: -1,
              stopReason: StopReason.eos,
            );
          case 'response.incomplete':
            return GenerationResponse(
              content: '',
              choices: choiceList,
              tokenCount: -1,
              stopReason: resolveResponsesIncompleteReason(map),
            );
          case 'response.failed':
          case 'error':
            return GenerationResponse(
              content: '',
              choices: choiceList,
              tokenCount: -1,
              stopReason: StopReason.error,
            );
          case 'response.cancelled':
          case 'response.canceled':
            return GenerationResponse(
              content: '',
              choices: choiceList,
              tokenCount: -1,
              stopReason: StopReason.canceled,
            );
          default:
            return null;
        }
      } catch (e) {
        logw('Failed to parse Responses SSE data: $e');
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
