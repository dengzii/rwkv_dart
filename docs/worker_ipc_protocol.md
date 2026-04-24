# RWKV Worker IPC 协议

本文档定义“宿主进程”和外部 `worker` 进程之间的 IPC 协议。

如果你要实现一个第三方 worker，只需要满足这份协议：

1. 启动后读取宿主进程传入的 `--ipc-host` 和 `--ipc-port`。
2. 主动连接该 socket。
3. 之后双方仅通过逐行 JSON 消息通信。
4. 宿主进程发送请求，worker 返回单次结果或流式事件。
5. 连接空闲时，宿主进程可能发送 `heartbeat` 保活，worker 需要立即回包。

本文档描述的协议版本可视为 `rwkv_worker_socket_v1`。

协议层命名约定：

- JSON 字段名使用 `snake_case`
- 方法名使用 `snake_case`
- 类型标签 `"$rwkv_type"` 的值使用 `snake_case`
- 本协议不兼容旧版 camelCase / `"$rwkvType"` 序列化格式

## 1. 总体约定

- 传输层：TCP socket，仅本机回环地址。
- 编码：`UTF-8`。
- 分帧：`JSON Lines`，每条消息一行，以 `\n` 结尾。
- 消息方向：
  - 宿主进程 -> worker：请求。
  - worker -> 宿主进程：响应或流事件。
- 并发：允许多个请求并发；通过 `id` 关联请求和响应。
- 日志：worker 的日志请写到 `stderr`，不要写入 socket。
- 无握手：连接建立后即可直接开始发送协议消息。
- 空闲保活：连接长时间空闲时，宿主进程可能发送 `heartbeat`；worker 应尽快返回成功响应。

## 2. Worker 进程启动约定

宿主进程会启动 worker 可执行文件，并附加两个命令行参数：

```text
--ipc-host <host> --ipc-port <port>
```

例如：

```text
third_party_worker --ipc-host 127.0.0.1 --ipc-port 51234
```

worker 启动后应立即主动连接该地址，然后在该 socket 上开始收发协议消息。

要求：

- 只连接一次。
- 建连后立即进入消息循环，无额外握手。
- `release` 请求完成后，应关闭连接并退出进程。

## 3. 通用消息格式

每一行都是一个 JSON 对象：

```json
{
  "id": "1",
  "method": "chat",
  "param": { "...": "..." },
  "error": "",
  "done": false
}
```

字段定义：

- `id: string`
  - 请求唯一标识。
  - worker 响应时必须原样回传。
- `method: string`
  - 方法名。
  - 响应时也保持原样回传。
- `param: any`
  - 请求参数，或响应结果，或流事件载荷。
  - 复杂对象使用本文第 6 节的序列化规则。
- `error: string`
  - 空串表示成功。
  - 非空表示失败。
- `done: bool`
  - 仅流式方法有意义。
  - `false`：当前还是流中事件。
  - `true`：流结束，宿主进程会关闭对应流。

## 4. 请求与响应语义

### 4.1 普通调用

普通方法流程：

1. 宿主进程发送一条请求。
2. worker 执行方法。
3. worker 返回一条同 `id` 的响应。

成功响应示例：

```json
{
  "id": "2",
  "method": "load_model",
  "param": 1,
  "error": "",
  "done": false
}
```

失败响应示例：

```json
{
  "id": "2",
  "method": "load_model",
  "param": null,
  "error": "model file not found",
  "done": false
}
```

### 4.2 流式调用

流式方法包括：

- `chat`
- `generate`
- `generation_state_stream`

worker 对这类方法的响应规则：

1. 每产生一个事件，发送一条同 `id` 的消息，`done=false`。
2. 流结束时，再发送一条同 `id` 的消息，`done=true`。
3. 结束消息的 `param` 建议为 `null`。
4. 如果流中报错，发送一条 `error!= ""` 且 `done=true` 的消息。

流结束示例：

```json
{
  "id": "3",
  "method": "chat",
  "param": null,
  "error": "",
  "done": true
}
```

### 4.3 取消流

宿主进程通过单独方法 `cancel_stream` 取消流。

请求：

```json
{
  "id": "9",
  "method": "cancel_stream",
  "param": "3",
  "error": "",
  "done": false
}
```

含义：

- `param` 是“要取消的流请求 id”。

worker 应：

1. 取消该流对应的内部订阅或任务。
2. 返回一条 `cancel_stream` 的普通响应。
3. 响应 `param` 为是否成功找到并取消该流，类型为 `bool`。
4. 该响应应带 `done=true`。

建议：

- 即使流已经自然结束，也应对 `cancel_stream` 返回一个明确结果，而不是静默忽略。
- 如果找不到目标流，返回 `false` 即可，不需要把它当成协议错误。

示例：

```json
{
  "id": "9",
  "method": "cancel_stream",
  "param": true,
  "error": "",
  "done": true
}
```

### 4.4 心跳

宿主进程可能在连接空闲时发送 `heartbeat` 请求，用于确认 worker 进程和 socket 连接仍然可用。

请求：

```json
{
  "id": "10",
  "method": "heartbeat",
  "param": null,
  "error": "",
  "done": false
}
```

worker 应：

1. 立即返回同 `id` 的成功响应。
2. 不要把它转发给模型层，也不要依赖模型当前是否空闲。
3. `param` 返回 `null` 即可。

示例：

```json
{
  "id": "10",
  "method": "heartbeat",
  "param": null,
  "error": "",
  "done": false
}
```

## 5. 方法清单

### 5.1 普通方法

| 方法名 | `param` 类型 | 返回 `param` 类型 | 说明 |
|---|---|---|---|
| `heartbeat` | `null` | `null` | 空闲连接保活，要求快速响应 |
| `init` | `InitParam \| null` | `null` | 初始化运行时 |
| `set_log_level` | `RWKVLogLevel` | `null` | 设置日志级别 |
| `load_model` | `LoadModelParam` | `int` | 加载模型，返回模型 id |
| `clear_state` | `null` | `null` | 清理状态 |
| `release` | `null` | `null` | 释放资源并退出 |
| `dump_log` | `null` | `string` | 导出日志 |
| `load_initial_state` | `string` | `null` | 加载初始状态文件 |
| `set_decode_param` | `DecodeParam` | `null` | 设置解码参数 |
| `get_generation_state` | `null` | `GenerationState` | 获取当前生成状态 |
| `stop_generate` | `null` | `null` | 停止当前生成 |
| `get_seed` | `null` | `int` | 获取随机种子 |
| `set_seed` | `int` | `null` | 设置随机种子 |
| `cancel_stream` | `string` | `bool` | 取消指定流 |

### 5.2 流式方法

| 方法名 | `param` 类型 | 流事件 `param` 类型 | 说明 |
|---|---|---|---|
| `chat` | `ChatParam` | `GenerationResponse` | 聊天生成 |
| `generate` | `GenerationParam` | `GenerationResponse` | 原始 prompt 生成 |
| `generation_state_stream` | `null` | `GenerationState` | 生成状态流 |

## 6. 序列化规则

### 6.1 基础规则

- `null`、`number`、`string`、`bool` 直接原样传输。
- 普通对象使用 JSON object。
- 普通数组如果不需要保留元素运行时类型，可直接用 JSON array。
- 某些对象和枚举需要带类型标签，标签字段固定为：

```json
"$rwkv_type"
```

例如：

```json
{
  "$rwkv_type": "rwkv_log_level",
  "name": "debug"
}
```

### 6.2 枚举类型

#### `RWKVLogLevel`

```json
{ "$rwkv_type": "rwkv_log_level", "name": "verbose|info|debug|warning|error" }
```

#### `Backend`

```json
{ "$rwkv_type": "backend", "name": "ncnn|llama.cpp|web-rwkv|qnn|mnn|mlx|mtp_np7|coreml" }
```

#### `ReasoningEffort`

```json
{ "$rwkv_type": "reasoning_effort", "name": "none|mini|low|medium|high|xhig" }
```

#### `StopReason`

```json
{ "$rwkv_type": "stop_reason", "name": "none|eos|max_tokens|tool_calls|canceled|error|timeout|unknown" }
```

### 6.3 保留元素类型的数组

#### `List<String>`

```json
{ "$rwkv_type": "string_list", "values": ["a", "b"] }
```

#### `List<int>`

```json
{ "$rwkv_type": "int_list", "values": [1, 2] }
```

#### `List<double>`

```json
{ "$rwkv_type": "double_list", "values": [1.0, 2.0] }
```

#### `List<bool>`

```json
{ "$rwkv_type": "bool_list", "values": [true, false] }
```

### 6.4 结构体

#### `InitParam`

```json
{
  "$rwkv_type": "init_param",
  "dynamic_lib_dir": "string|null",
  "log_level": { "$rwkv_type": "rwkv_log_level", "name": "debug" },
  "qnn_lib_dir": "string|null",
  "extra": { "...": "..." }
}
```

#### `TTSModelConfig`

```json
{
  "$rwkv_type": "tts_model_config",
  "text_normalizers": ["zh", "en"],
  "wav2vec2_model_path": "string",
  "bi_codec_tokenizer_path": "string",
  "bi_codec_detokenizer_path": "string"
}
```

#### `LoadModelParam`

```json
{
  "$rwkv_type": "load_model_param",
  "model_path": "string",
  "tokenizer_path": "string",
  "backend": { "$rwkv_type": "backend", "name": "qnn" },
  "tts_model_config": { "$rwkv_type": "tts_model_config", "...": "..." }
}
```

`backend`、`tts_model_config` 可为 `null`。

#### `DecodeParam`

```json
{
  "$rwkv_type": "decode_param",
  "temperature": 1.0,
  "top_k": 20,
  "top_p": 0.5,
  "presence_penalty": 0.5,
  "frequency_penalty": 0.5,
  "penalty_decay": 0.996,
  "max_tokens": 2000
}
```

#### `GenerationParam`

```json
{
  "$rwkv_type": "generation_param",
  "prompt": "string",
  "model": "string|null",
  "max_completion_tokens": 256,
  "reasoning": "raw string|null",
  "stop_sequence": { "$rwkv_type": "int_list", "values": [0, 1] },
  "additional": { "...": "..." },
  "completion_stop_token": 0,
  "eos_token": "string|null",
  "bos_token": "string|null",
  "token_banned": { "$rwkv_type": "int_list", "values": [3, 4] },
  "return_whole_generated_result": true
}
```

注意：`GenerationParam.reasoning` 这里是普通字符串，不是 `ReasoningEffort`。

#### `ChatMessage`

```json
{
  "$rwkv_type": "chat_message",
  "role": "system|user|assistant|tool|...",
  "content": "string",
  "tool_call_id": "string|null",
  "tool_calls": [ { "$rwkv_type": "tool_call", "...": "..." } ]
}
```

#### `ChatParam`

```json
{
  "$rwkv_type": "chat_param",
  "messages": [ { "$rwkv_type": "chat_message", "...": "..." } ],
  "batch": [ { "$rwkv_type": "chat_message", "...": "..." } ],
  "tools": [ { "$rwkv_type": "tool_definition", "...": "..." } ],
  "tool_choice": { "$rwkv_type": "tool_choice", "...": "..." },
  "parallel_tool_calls": true,
  "model": "string|null",
  "max_completion_tokens": 256,
  "max_tokens": 512,
  "reasoning": { "$rwkv_type": "reasoning_effort", "name": "high" },
  "stop_sequence": { "$rwkv_type": "int_list", "values": [0, 1] },
  "additional": { "...": "..." },
  "prompt": "string|null",
  "completion_stop_token": 2,
  "thinking_token": "<think>",
  "eos_token": "</s>",
  "bos_token": "<s>",
  "token_banned": { "$rwkv_type": "int_list", "values": [3, 4] },
  "return_whole_generated_result": true,
  "add_generation_prompt": false,
  "space_after_role": true
}
```

#### `GenerationResponse`

```json
{
  "$rwkv_type": "generation_response",
  "content": "string",
  "reasoning_content": "string",
  "token_count": 12,
  "stop_reason": { "$rwkv_type": "stop_reason", "name": "none" },
  "choices": { "$rwkv_type": "string_list", "values": ["a", "b"] },
  "stop_reasons": [
    { "$rwkv_type": "stop_reason", "name": "none" },
    { "$rwkv_type": "stop_reason", "name": "eos" }
  ],
  "tool_calls": [ { "$rwkv_type": "tool_call", "...": "..." } ],
  "choice_tool_calls": [
    [ { "$rwkv_type": "tool_call", "...": "..." } ],
    null
  ]
}
```

#### `GenerationState`

```json
{
  "$rwkv_type": "generation_state",
  "is_generating": true,
  "prefill_progress": 0.5,
  "prefill_speed": 123.4,
  "decode_speed": 45.6,
  "timestamp": 1710000000000
}
```

### 6.5 Tool Call 相关结构

#### `ToolFunction`

```json
{
  "$rwkv_type": "tool_function",
  "name": "lookup",
  "description": "string|null",
  "parameters": { "...": "JSON Schema" },
  "strict": true
}
```

#### `ToolDefinition`

```json
{
  "$rwkv_type": "tool_definition",
  "type": "function",
  "function": { "$rwkv_type": "tool_function", "...": "..." }
}
```

#### `ToolChoice`

```json
{ "$rwkv_type": "tool_choice", "mode": "none|auto|required", "function_name": null }
```

或者：

```json
{ "$rwkv_type": "tool_choice", "mode": null, "function_name": "lookup" }
```

#### `ToolCallFunction`

```json
{
  "$rwkv_type": "tool_call_function",
  "name": "lookup",
  "arguments": "{\"query\":\"rwkv\"}"
}
```

#### `ToolCall`

```json
{
  "$rwkv_type": "tool_call",
  "index": 0,
  "id": "call-1",
  "type": "function",
  "function": { "$rwkv_type": "tool_call_function", "...": "..." }
}
```

## 7. 错误处理

- 任何请求处理失败时，worker 应返回同 `id` 的错误消息。
- `error` 填可读字符串即可，宿主进程会将它当作错误文本处理。
- 如果是流式方法出错，建议返回：
  - `error` 非空
  - `done=true`
  - `param=null`
- 如果收到未知 `method`，应返回错误，例如：

```json
{
  "id": "15",
  "method": "unknown_method",
  "param": null,
  "error": "Unknown worker method: unknown_method",
  "done": false
}
```

## 8. 第三方最小实现要求

第三方 worker 至少需要做到：

1. 解析 `--ipc-host`、`--ipc-port`。
2. 主动连接宿主进程提供的 socket。
3. 按行读取 UTF-8 JSON。
4. 维护请求 `id` 到任务的映射。
5. 实现第 5 节中的方法，至少实现你们接入场景实际会调用的子集。
6. 对 `heartbeat` 做快速回包，不要阻塞在模型推理逻辑上。
7. 对流式方法发送中间事件和最终 `done=true`。
8. 支持 `cancel_stream`。
9. `release` 后关闭 socket 并退出进程。

## 9. 最小交互示例

### 9.1 初始化

宿主进程发送：

```json
{"id":"1","method":"init","param":{"$rwkv_type":"init_param","dynamic_lib_dir":"","log_level":{"$rwkv_type":"rwkv_log_level","name":"debug"},"qnn_lib_dir":null,"extra":{}},"error":"","done":false}
```

worker 返回：

```json
{"id":"1","method":"init","param":null,"error":"","done":false}
```

### 9.2 聊天流

宿主进程发送：

```json
{"id":"2","method":"chat","param":{"$rwkv_type":"chat_param","messages":[{"$rwkv_type":"chat_message","role":"user","content":"你好","tool_call_id":null,"tool_calls":null}],"batch":null,"tools":null,"tool_choice":null,"parallel_tool_calls":null,"model":null,"max_completion_tokens":null,"max_tokens":128,"reasoning":null,"stop_sequence":null,"additional":null,"prompt":null,"completion_stop_token":null,"thinking_token":null,"eos_token":null,"bos_token":null,"token_banned":null,"return_whole_generated_result":null,"add_generation_prompt":null,"space_after_role":null},"error":"","done":false}
```

worker 连续返回：

```json
{"id":"2","method":"chat","param":{"$rwkv_type":"generation_response","content":"你","reasoning_content":"","token_count":1,"stop_reason":{"$rwkv_type":"stop_reason","name":"none"},"choices":null,"stop_reasons":null,"tool_calls":null,"choice_tool_calls":null},"error":"","done":false}
{"id":"2","method":"chat","param":{"$rwkv_type":"generation_response","content":"好","reasoning_content":"","token_count":2,"stop_reason":{"$rwkv_type":"stop_reason","name":"none"},"choices":null,"stop_reasons":null,"tool_calls":null,"choice_tool_calls":null},"error":"","done":false}
{"id":"2","method":"chat","param":null,"error":"","done":true}
```

## 10. 兼容性建议

- 新增方法时，优先保持现有字段兼容，不要改动既有字段名。
- 新增复杂类型时，继续沿用 `"$rwkv_type"` 标签机制。
- 如果第三方只实现部分方法，需确保宿主进程不会调用未实现的方法，否则会收到运行时错误。
