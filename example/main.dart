import 'package:rwkv_dart/rwkv_dart.dart';

void main() async {
  // .prefab model file path
  const modelPath = r"rwkv7-g1-1.5b-20250429-ctx4096-nf4.prefab";
  // rwkv vocab file path
  const tokenizerPath = r'b_rwkv_vocab_v20230424.txt';
  // rwkv_model.dll directory path
  const dynamicLibraryDir = r"";

  const state = r"";

  final rwkv = await RWKV.create();
  await rwkv.init(InitParam(dynamicLibDir: dynamicLibraryDir));
  await rwkv.loadModel(
    LoadModelParam(modelPath: modelPath, tokenizerPath: tokenizerPath),
  );
  await rwkv.setGenerationConfig(
    GenerationConfig.initial().copyWith(maxTokens: 100, completionStopToken: 0),
  );
  // await rwkv.loadInitialState(state);
  var stream = rwkv.chat(['Who are you?']).asBroadcastStream();
  String resp = "";
  stream.listen(
    (e) {
      resp += e.text;
      print('.');
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
