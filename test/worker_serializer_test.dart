import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/worker/serialize.dart';
import 'package:rwkv_dart/src/worker/worker.dart';
import 'package:test/test.dart';

void main() {
  test('round trips chat params', () {
    final param = ChatParam(
      messages: const [ChatMessage(role: 'user', content: 'hello')],
      batch: const [ChatMessage(role: 'assistant', content: 'hi')],
      tools: const [
        ToolDefinition.function(
          function: ToolFunction(
            name: 'lookup',
            description: 'Lookup data',
            parameters: {
              'type': 'object',
              'properties': {
                'query': {'type': 'string'},
              },
            },
            strict: true,
          ),
        ),
      ],
      toolChoice: const ToolChoice.function('lookup'),
      parallelToolCalls: true,
      model: 'model-id',
      reasoning: ReasoningEffort.high,
      additional: const {
        'nested': {
          'values': [1, 2, 3],
        },
      },
      stopSequence: const [0, 1],
      maxTokens: 32,
      maxCompletionTokens: 16,
      prompt: 'system',
      completionStopToken: 2,
      thinkingToken: '<think>',
      eosToken: '</s>',
      bosToken: '<s>',
      tokenBanned: const [3, 4],
      returnWholeGeneratedResult: true,
      addGenerationPrompt: false,
      spaceAfterRole: true,
    );

    final decoded =
        Serializer.deserialize(Serializer.serialize(param)) as ChatParam;

    expect(decoded.messages, hasLength(1));
    expect(decoded.messages!.first.role, 'user');
    expect(decoded.batch, hasLength(1));
    expect(decoded.tools, hasLength(1));
    expect(decoded.toolChoice, isA<ToolChoice>());
    expect(decoded.parallelToolCalls, isTrue);
    expect(decoded.model, 'model-id');
    expect(decoded.reasoning, ReasoningEffort.high);
    expect(decoded.stopSequence, [0, 1]);
    expect(decoded.maxTokens, 32);
    expect(decoded.maxCompletionTokens, 16);
    expect(decoded.prompt, 'system');
    expect(decoded.completionStopToken, 2);
    expect(decoded.thinkingToken, '<think>');
    expect(decoded.eosToken, '</s>');
    expect(decoded.bosToken, '<s>');
    expect(decoded.tokenBanned, [3, 4]);
    expect(decoded.returnWholeGeneratedResult, isTrue);
    expect(decoded.addGenerationPrompt, isFalse);
    expect(decoded.spaceAfterRole, isTrue);
  });

  test('round trips generation response tool calls', () {
    const toolCall = ToolCall(
      index: 0,
      id: 'call-1',
      type: 'function',
      function: ToolCallFunction(name: 'lookup', arguments: '{"query":"rwkv"}'),
    );
    final response = GenerationResponse(
      content: 'content',
      reasoningContent: 'reasoning',
      tokenCount: 3,
      stopReason: StopReason.toolCalls,
      choices: const ['a', 'b'],
      stopReasons: const [StopReason.none, StopReason.eos],
      toolCalls: const [toolCall],
      choiceToolCalls: const [
        [toolCall],
        null,
      ],
    );

    final decoded =
        Serializer.deserialize(Serializer.serialize(response))
            as GenerationResponse;

    expect(decoded.content, 'content');
    expect(decoded.reasoningContent, 'reasoning');
    expect(decoded.tokenCount, 3);
    expect(decoded.stopReason, StopReason.toolCalls);
    expect(decoded.choices, ['a', 'b']);
    expect(decoded.stopReasons, [StopReason.none, StopReason.eos]);
    expect(decoded.toolCalls!.single.function!.name, 'lookup');
    expect(decoded.choiceToolCalls!.first!.single.id, 'call-1');
    expect(decoded.choiceToolCalls![1], isNull);
  });

  test('preserves primitive list runtime types', () {
    final decoded = Serializer.deserialize(
      Serializer.serialize(<double>[1, 2.5]),
    );

    expect(decoded, isA<List<double>>());
    expect(decoded, [1.0, 2.5]);
  });

  test('round trips worker messages', () {
    final message = WorkerMessage.request(
      WorkerMethod.getGenerationState,
      GenerationState.initial(),
    );

    final decoded = WorkerMessage.fromLine(message.toLine());

    expect(decoded.id, message.id);
    expect(decoded.method, WorkerMethod.getGenerationState);
    expect(decoded.param, isA<GenerationState>());
  });

  test('worker ipc sends done when stream ends', () async {
    final input = StreamController<List<int>>();
    final output = _ByteStreamConsumer();
    final ipc = WorkerIPC(
      _FakeRwkv(),
      input: input.stream,
      output: IOSink(output),
    );

    final done = ipc.start();
    final request = WorkerMessage.request(
      WorkerMethod.chat,
      const ChatParam(messages: []),
    );

    input.add(utf8.encode('${request.toLine()}\n'));
    final messages = await _waitForMessages(output, 2);
    await ipc.close();
    await done.timeout(const Duration(seconds: 1));

    expect(messages, hasLength(2));
    expect(messages.first.param, isA<GenerationResponse>());
    expect(messages.last.id, request.id);
    expect(messages.last.done, isTrue);
  });
}

Future<List<WorkerMessage>> _waitForMessages(
  _ByteStreamConsumer output,
  int count,
) async {
  for (var i = 0; i < 100; i++) {
    final messages = const LineSplitter()
        .convert(utf8.decode(output.bytes))
        .map(WorkerMessage.fromLine)
        .toList();
    if (messages.length >= count) {
      return messages;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return const LineSplitter()
      .convert(utf8.decode(output.bytes))
      .map(WorkerMessage.fromLine)
      .toList();
}

class _FakeRwkv implements RWKV {
  @override
  Stream<GenerationResponse> chat(ChatParam param) async* {
    yield GenerationResponse(content: 'chunk');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ByteStreamConsumer implements StreamConsumer<List<int>> {
  final BytesBuilder _builder = BytesBuilder();

  List<int> get bytes => _builder.toBytes();

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _builder.add(chunk);
    }
  }

  @override
  Future<void> close() async {}
}
