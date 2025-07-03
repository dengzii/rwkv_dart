import 'package:rwkv_flutter/src/logger.dart';
import 'package:rwkv_flutter/src/rwkv.dart';
import 'package:test/test.dart';

const modelPath =
    r'C:\Users\dengz\Documents\rwkv7-g1-1.5b-20250429-ctx4096-nf4.prefab';
const tokenizerPath =
    r'D:\dev\RWKV_APP\assets\config\chat\b_rwkv_vocab_v20230424.txt';

const dynamicLibraryDir = r"D:\dev\rwkv_mobile_flutter\windows\";

void main() async {
  test('test_text_generation', () async {
    // final rwkv = await RWKV.create(dynamicLibraryDir: dynamicLibraryDir);
    final rwkv = await RWKV.isolated();

    // init ffi
    await rwkv.init();
    // init runtime, load model
    await rwkv.initRuntime(
      InitRuntimeParam(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        backend: Backend.webRwkv,
      ),
    );
    // set generation param
    await rwkv.setGenerationParam(GenerationParam.initial());

    final stream = rwkv.chat(['你好，我是小明，很高兴认识你。']).asBroadcastStream();
    // final stream = rwkv.completion("Hello, my name is").asBroadcastStream();
    stream.listen(
      (e) {
        print(e);
      },
      onDone: () {
        logDebug('done');
      },
      onError: (e) {
        logError(e);
      },
    );

    await stream.last;
  });
}
