# rwkv dart

让你方便快速地在各个平台使用 dart 运行 rwkv 模型, 支持通过 ffi 调用多平台支持的 c++
推理后端 [rwkv-mobile](https://github.com/MollySophia/rwkv-mobile/releases), 支持适配 OpenAI API 风格的
模型服务, 支持 rwkv_lightning 服务 API

### Example:

```dart
import 'package:rwkv_dart/rwkv_dart.dart';

void main() async {
  const modelPath = r'';
  const tokenizerPath = r'b_rwkv_vocab_v20230424.txt';
  const dynamicLibraryDir = r"";

  final rwkv = await RWKV.create();
  await rwkv.init(InitParam(dynamicLibDir: dynamicLibraryDir));
  await rwkv.loadModel(
    LoadModelParam(
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      backend: Backend.webRwkv,
    ),
  );
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
  await stream.toList();
}
```
