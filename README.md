# rwkv dart

让你方便快速地在各个平台使用 dart 运行 rwkv 模型，基本无第三方依赖.

### 准备工作

- 请在 [这里](https://github.com/MollySophia/rwkv-mobile/releases) 提前下载好所需平台的动态库文件.
- 如果你是在纯 dart 中使用, 请在初始化的时候指定 `dynamicLibDir` 参数, 传入对应平台动态库所在的目录路径.
- 如果你想在 `flutter` 中使用, 下载你需要的对应平台的动态库, 并放置到你的 `flutter` 项目中对应平台动态库的目录.
- 在 huggingface 等平台下载你想使用的推理后端对应的 [模型文件](https://huggingface.co/mollysama/rwkv-mobile-models)
  和 [词表文件](https://huggingface.co/mollysama/rwkv-mobile-models/tree/main/tokenizer)

### 使用 QNN 后端

1. 使用qnn后端需要准备额外的 .so，在 [这里下载](https://github.com/dengzii/rwkv_dart/releases/download/1.0.0/qnn.zip)

2. 在加载模型时需要将qnn共享库所在的 *目录路径* 传入`LoadModelParam`的`qnnLibDir`参数.

3. 在 AndroidManifest.xml 的 application 标签下添加以下声明:
```xml
    <uses-native-library
        android:name="libneuronusdk_adapter.mtk.so"
        android:required="false" />
    <uses-native-library
        android:name="libapuwareutils.mtk.so"
        android:required="false" />
    <uses-native-library
        android:name="libapuwareutils_v2.mtk.so"
        android:required="false" />
    <uses-native-library
        android:name="libcdsprpc.so"
        android:required="false" />
```

### Example:

```dart
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
  await rwkv.loadModel(
    LoadModelParam(
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      backend: Backend.webRwkv,
    ),
  );
  await rwkv.setGenerateConfig(GenerateConfig.initial());
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
```