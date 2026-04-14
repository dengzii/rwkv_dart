import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';

void main() async {
  // .prefab model file path
  const modelPath = r"rwkv7-g1-1.5b-20250429-ctx4096-nf4.prefab";
  // rwkv vocab file path
  const tokenizerPath = r'b_rwkv_vocab_v20230424.txt';
  // rwkv_model.dll directory path
  const dynamicLibraryDir = r"";

  final rwkv = RWKV.create();
  await rwkv.init(InitParam(dynamicLibDir: dynamicLibraryDir));
  await rwkv.loadModel(
    LoadModelParam(modelPath: modelPath, tokenizerPath: tokenizerPath),
  );

  var stream = rwkv
      .chat(
        ChatParam(
          maxTokens: 2000,
          reasoning: ReasoningEffort.xhig,
          messages: [
            ChatMessage(
              role: 'user',
              content: 'What is the most important thing in the world?',
            ),
          ],
        ),
      )
      .asBroadcastStream();
  String resp = "";
  stream.listen(
    (e) {
      if (e.reasoningContent.isNotEmpty) {
        stderr.write(e.reasoningContent);
      } else {
        stdout.write(e.content);
      }
    },
    onDone: () {
      print('done');
      print(resp);
    },
    onError: (e) {
      print('error: $e');
    },
  );
  await stream.toList();
}
