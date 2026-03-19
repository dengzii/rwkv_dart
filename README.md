# rwkv_dart

`rwkv_dart` 是一个面向 Dart / Flutter 的 RWKV SDK，提供统一的 LLM 抽象。

它既可以直接加载本地 RWKV 模型做推理，也可以把 OpenAI 兼容接口、Albatross 服务、MCP 工具调用能力统一到同一套
`RWKV` / `LLM` API 上。

底层本地推理基于 FFI 对接 [rwkv-mobile](https://github.com/MollySophia/rwkv-mobile/releases)。

## 特性

- 支持本地 RWKV 推理，统一使用 `RWKV.create()` 或 `RWKV.isolated()`
- 支持 OpenAI 兼容服务接入，统一使用 `RWKV.network()`
- 支持 Albatross 服务接入，统一使用 `RWKV.albatross()`
- 支持流式输出，`chat()` / `generate()` 返回 `Stream<GenerationResponse>`
- 支持 tool call 数据结构，兼容函数调用场景
- 支持 MCP 客户端、MCP Hub、MCP Chat Runner
- 支持启动一个简单的 OpenAI 兼容 HTTP 服务 `RwkvHttpApiService`
- 提供统一解码参数、生成状态、停止生成等能力

## 安装

```bash
dart pub add rwkv_dart
```

或在 `pubspec.yaml` 中添加：

```yaml
dependencies:
  rwkv_dart: ^1.1.2
```

## 注意

- 本地推理需要准备动态库、模型文件和 tokenizer 文件。
- 动态库通常来自 `rwkv-mobile` 的发布产物，在纯 dart 使用时 `InitParam.dynamicLibDir` 需要指向对应目录，在
  flutter 请拷贝到平台相应目录。
- 不同后端支持的平台不同，例如 `web-rwkv` 不适用于 Android，具体以后端能力为准。
- 使用完本地实例后，建议调用 `release()` 释放资源。 如果需要隔离推理任务、避免阻塞主线程，可以优先使用
  `RWKV.isolated()`。

## 快速使用

### 1. 本地模型推理

```dart
import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';

Future<void> main() async {
  const modelPath = r'./model.gguf';
  const tokenizerPath = r'./b_rwkv_vocab_v20230424.txt';
  const dynamicLibraryDir = r'';

  final rwkv = RWKV.create();

  try {
    await rwkv.init(InitParam(dynamicLibDir: dynamicLibraryDir));
    await rwkv.loadModel(
      LoadModelParam(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
      ),
    );

    await rwkv.setDecodeParam(
      DecodeParam.initial().copyWith(
        temperature: 0.8,
        topP: 0.7,
        maxTokens: 512,
      ),
    );

    final stream = rwkv.chat(
      ChatParam(
        messages: const [
          ChatMessage(role: 'user', content: '请简单介绍一下 RWKV。'),
        ],
        maxTokens: 512,
      ),
    );

    await for (final chunk in stream) {
      stdout.write(chunk.text);
    }
  } finally {
    await rwkv.release();
  }
}
```

### 2. 连接 OpenAI 兼容服务

```dart
import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';

Future<void> main() async {
  final llm = RWKV.network(
    'BASE_URL',
    'YOUR_API_KEY',
  );

  await llm.init();

  final stream = llm.chat(
    ChatParam.openAi(
      model: 'Qwen/Qwen3-8B',
      messages: const [
        ChatMessage(role: 'user', content: '用一句话介绍你自己。'),
      ],
      reasoning: ReasoningEffort.high,
      maxTokens: 256,
    ),
  );

  await for (final chunk in stream) {
    stdout.write(chunk.text);
  }
}
```

## 进阶能力

### 启动 OpenAI 兼容服务

```dart
import 'package:rwkv_dart/rwkv_dart.dart';

Future<void> main() async {
  final server = RwkvHttpApiService();
  await server.run(
    host: '0.0.0.0',
    port: 9527,
    modelListPath: './example/models.json',
  );
}
```

