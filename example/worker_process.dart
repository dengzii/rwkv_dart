import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';

Future<void> main(List<String> args) async {
  final executable = Platform.isWindows ? r'./worker.exe' : './worker';

  // .prefab model file path
  const modelPath = r'rwkv7-g1a-0.4b-20250905-ctx4096-int8.prefab';
  // rwkv vocab file path
  const tokenizerPath = r'b_rwkv_vocab_v20230424.txt';
  // rwkv_model.dll directory path
  const dynamicLibraryDir = r'';

  final rwkv = RWKVProcess(executable);
  try {
    await rwkv.init(InitParam(dynamicLibDir: dynamicLibraryDir));
    await rwkv.loadModel(
      LoadModelParam(modelPath: modelPath, tokenizerPath: tokenizerPath),
    );
    await rwkv.setDecodeParam(
      DecodeParam.initial().copyWith(
        temperature: 0.8,
        topP: 0.7,
        maxTokens: 1000,
      ),
    );

    final stream = rwkv.chat(
      const ChatParam(
        maxTokens: 1000,
        reasoning: ReasoningEffort.xhig,
        messages: [
          ChatMessage(
            role: 'user',
            content: 'What is the most important thing in the world?',
          ),
        ],
      ),
    );

    await for (final response in stream) {
      if (response.reasoningContent.isNotEmpty) {
        stderr.write(response.reasoningContent);
      } else {
        stdout.write(response.content);
      }
    }
    stdout.writeln();
  } finally {
    await rwkv.release();
  }
}
