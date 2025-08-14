import 'package:rwkv_dart/rwkv_dart.dart';

void main() async {
  // .prefab model file path
  const modelPath = r'';
  // rwkv vocab file path
  const tokenizerPath = r'b_rwkv_vocab_v20230424.txt';
  // rwkv_model.dll directory path
  const dynamicLibraryDir = r"";

  final rwkv = await RWKV.create();
  await rwkv.init(InitParam(dynamicLibDir: dynamicLibraryDir));
  await rwkv.initBackend(
    InitBackendParam(
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      backend: Backend.webRwkv,
    ),
  );
  await rwkv.setGenerationParam(GenerationParam.initial());
  var stream = rwkv.chat(['Who are you?']).asBroadcastStream();
  String resp = "";
  stream.listen(
    (e) {
      resp += e;
      print(e);
    },
    onDone: () {
      print('generation done');
      print(resp);
    },
    onError: (e) {
      print('generation error: $e');
    },
  );
}
