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
    LoadModelParam(
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      backend: Backend.webRwkv,
    ),
  );
  await rwkv.setGenerationParam(GenerationParam.initial());
  // await rwkv.loadInitialState(state);
  var stream = rwkv.chat(['Who are you?']).asBroadcastStream();
  String resp = "";
  stream.listen(
    (e) {
      resp += e;
      print('.');
    },
    onDone: () {
      print('generation done');
      print(resp);
    },
    onError: (e) {
      print('generation error: $e');
    },
  );
  await stream.last;
}
