import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';

void main(List<String> args) async {
  _configureConsoleEncoding();

  final options = _CliOptions.parse(args);
  if (options.help) {
    _printUsage();
    return;
  }

  if (options.provider != null && options.server) {
    stderr.writeln('Provider mode is only supported for interactive mode.');
    _printUsage();
    exitCode = 64;
    return;
  }

  if (options.provider != null && options.modelId.isEmpty) {
    stderr.writeln(
      'Missing required option: -model-id is required with -provider.',
    );
    _printUsage();
    exitCode = 64;
    return;
  }

  if (options.provider == null &&
      (options.modelPath == null || options.tokenizerPath == null)) {
    stderr.writeln(
      'Missing required option: -model and -vocab are required without -provider.',
    );
    _printUsage();
    exitCode = 64;
    return;
  }

  setRWKVCallback((record) {
    stderr.writeln(
      '${record.time.toIso8601String()} '
      '${record.level.name} '
      '[${record.loggerName}] '
      '${record.message}',
    );
  });

  RWKV? rwkv;
  var serverStarted = false;
  try {
    if (options.provider != null) {
      rwkv = await _createProviderClient(options);
    } else {
      rwkv = RWKV.isolated();
      await _loadModel(rwkv, options);
    }

    if (options.server) {
      serverStarted = true;
      await _runServer(rwkv, options);
    } else {
      await _runInteractive(rwkv, options);
    }
  } finally {
    if (rwkv != null && (!options.server || !serverStarted)) {
      await rwkv.release();
    }
  }
}

Future<void> _loadModel(RWKV rwkv, _CliOptions options) async {
  stderr.writeln('Initializing RWKV...');
  await rwkv.init(
    InitParam(
      dynamicLibDir: options.dynamicLibDir,
      qnnLibDir: options.qnnLibDir,
      logLevel: options.logLevel,
    ),
  );

  stderr.writeln('Loading model: ${options.modelPath}');
  await rwkv.loadModel(
    LoadModelParam(
      modelPath: options.modelPath!,
      tokenizerPath: options.tokenizerPath!,
      backend: options.backend,
    ),
  );
  await rwkv.setDecodeParam(options.decodeParam);
  stderr.writeln('Model loaded.');
}

Future<RWKV> _createProviderClient(_CliOptions options) async {
  stderr.writeln('Connecting provider: ${options.provider}');
  final service = await ModelService.create(
    url: options.provider!,
    accessKey: options.apiKey,
    id: options.modelId,
  );

  if (!service.available) {
    throw StateError('Provider is not available: ${options.provider}');
  }

  final loaded = service.models
      .where(
        (model) =>
            model.info.id == options.modelId ||
            model.info.name == options.modelId,
      )
      .firstOrNull;
  if (loaded == null) {
    final available = service.models.map((model) => model.info.id).join(', ');
    throw StateError(
      'Model id not found: ${options.modelId}'
      '${available.isEmpty ? '' : '. Available models: $available'}',
    );
  }

  await loaded.rwkv.setDecodeParam(options.decodeParam);
  stderr.writeln('Provider connected.');
  stderr.writeln('Model id: ${loaded.info.id}');
  return loaded.rwkv;
}

Future<void> _runServer(RWKV rwkv, _CliOptions options) async {
  final service = RwkvHttpApiService();
  var released = false;

  Future<bool> shutdown() async {
    if (released) {
      return true;
    }
    released = true;
    var graceful = true;
    graceful &= await _shutdownStep(
      'HTTP server shutdown',
      service.shutdown(),
      const Duration(seconds: 3),
    );
    graceful &= await _shutdownStep(
      'Stop generation',
      rwkv.stopGenerate(),
      const Duration(seconds: 3),
    );
    graceful &= await _shutdownStep(
      'RWKV release',
      rwkv.release(),
      const Duration(seconds: 8),
    );
    return graceful;
  }

  try {
    service.updateInstances([
      HttpServiceModelInstance(
        rwkv: rwkv,
        info: ModelBean(
          id: options.modelId,
          name: options.modelName,
          path: options.modelPath!,
          tokenizer: options.tokenizerPath!,
          backend: options.backend?.name ?? '',
          fileSize: _fileSize(options.modelPath!),
          modelSize: 0,
          url: '',
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          groups: const [],
          tags: const [],
        ),
      ),
    ]);

    await service.run(
      host: options.host,
      port: options.port,
      accessKey: options.accessKey,
    );
    stderr.writeln(
      'OpenAI-compatible API server listening on '
      'http://${options.host}:${options.port}',
    );
    stderr.writeln('Model id: ${options.modelId}');

    final stop = Completer<void>();
    StreamSubscription<ProcessSignal>? sigintSub;
    StreamSubscription<ProcessSignal>? sigtermSub;

    Future<void> requestStop(String signal) async {
      if (!stop.isCompleted) {
        stderr.writeln('\nShutting down ($signal)...');
        final graceful = await shutdown();
        stop.complete();
        if (!graceful) {
          stderr.writeln('Shutdown timed out; forcing process exit.');
          exit(0);
        }
      }
    }

    sigintSub = ProcessSignal.sigint.watch().listen((_) {
      requestStop('SIGINT').ignore();
    });
    if (!Platform.isWindows) {
      sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
        requestStop('SIGTERM').ignore();
      });
    }

    try {
      await stop.future;
    } finally {
      await sigintSub.cancel();
      await sigtermSub?.cancel();
    }
  } finally {
    await shutdown();
  }
}

Future<bool> _shutdownStep(
  String label,
  Future<dynamic> future,
  Duration timeout,
) async {
  try {
    await future.timeout(timeout);
    return true;
  } catch (e) {
    stderr.writeln('$label failed or timed out: $e');
    return false;
  }
}

Future<void> _runInteractive(RWKV rwkv, _CliOptions options) async {
  var decodeParam = options.decodeParam;
  var reasoning = options.reasoning;
  var isGenerating = false;
  var isStoppingGeneration = false;
  final messages = <ChatMessage>[];
  late final StreamSubscription<ProcessSignal> sigintSub;

  sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (isGenerating) {
      if (isStoppingGeneration) {
        return;
      }
      isStoppingGeneration = true;
      stderr.writeln('\nStopping current chat...');
      _shutdownStep(
        'Stop generation',
        rwkv.stopGenerate(),
        const Duration(seconds: 3),
      ).whenComplete(() {
        isStoppingGeneration = false;
      }).ignore();
      return;
    }

    stderr.writeln('\nExiting...');
    () async {
      await _shutdownStep(
        'RWKV release',
        rwkv.release(),
        const Duration(seconds: 8),
      );
      exit(0);
    }();
  });

  try {
    stdout.writeln('Type /help for commands.');
    while (true) {
      stdout.write('\n> ');
      final line = stdin.readLineSync(encoding: utf8);
      if (line == null) {
        stdout.writeln();
        break;
      }

      final input = line.trim();
      if (input.isEmpty) {
        continue;
      }

      if (input.startsWith('/')) {
        final result = await _handleInteractiveCommand(
          input,
          rwkv,
          messages,
          decodeParam,
          reasoning,
        );
        if (result.quit) {
          break;
        }
        decodeParam = result.decodeParam;
        reasoning = result.reasoning;
        continue;
      }

      messages.add(ChatMessage(role: 'user', content: input));
      final assistant = StringBuffer();
      final stream = rwkv.chat(
        ChatParam(
          messages: List.unmodifiable(messages),
          model: options.chatModelId,
          maxTokens: decodeParam.maxTokens,
          reasoning: reasoning,
        ),
      );

      isGenerating = true;
      try {
        bool reasoning = false;
        await for (final chunk in stream) {
          if (chunk.reasoningContent.isNotEmpty) {
            stderr.write(chunk.reasoningContent);
            reasoning = true;
          }
          if (chunk.content.isNotEmpty) {
            if (reasoning) {
              stdout.writeln();
              stdout.writeln('---------');
              reasoning = false;
            }
            stdout.write(chunk.content);
            assistant.write(chunk.content);
          }
        }
      } finally {
        isGenerating = false;
        stdout.writeln();
        await _printGenerationSpeed(rwkv);
      }

      if (assistant.isNotEmpty) {
        messages.add(
          ChatMessage(role: 'assistant', content: assistant.toString()),
        );
      }
    }
  } finally {
    await sigintSub.cancel();
  }
}

Future<void> _printGenerationSpeed(RWKV rwkv) async {
  try {
    final state = await rwkv.getGenerationState();
    if (state.decodeSpeed <= 0) {
      return;
    }
    stdout.writeln(
      'Speed: prefill ${_formatSpeed(state.prefillSpeed)} tokens/s, '
      'decode ${_formatSpeed(state.decodeSpeed)} tokens/s',
    );
  } catch (error) {
    stderr.writeln('Failed to get generation speed: $error');
  }
}

String _formatSpeed(double speed) {
  if (!speed.isFinite) {
    return speed.toString();
  }
  if (speed >= 100) {
    return speed.toStringAsFixed(1);
  }
  return speed.toStringAsFixed(2);
}

Future<_CommandResult> _handleInteractiveCommand(
  String input,
  RWKV rwkv,
  List<ChatMessage> messages,
  DecodeParam decodeParam,
  ReasoningEffort reasoning,
) async {
  final parts = input.split(RegExp(r'\s+'));
  final command = parts.first.toLowerCase();
  final value = parts.length > 1 ? parts.sublist(1).join(' ') : '';

  switch (command) {
    case '/quit':
    case '/exit':
      return _CommandResult.quit(decodeParam, reasoning);
    case '/help':
      _printInteractiveHelp();
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/clear':
      messages.clear();
      await rwkv.clearState();
      stdout.writeln('Context cleared.');
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/history':
      _printHistory(messages);
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/stop':
      await rwkv.stopGenerate();
      stdout.writeln('Stop signal sent.');
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/reasoning-mode':
    case '/reasoning':
      final next = ReasoningEffort.fromName(value);
      if (next == null) {
        stdout.writeln('Usage: /reasoning-mode none|mini|low|medium|high|xhig');
        return _CommandResult.keepGoing(decodeParam, reasoning);
      }
      stdout.writeln('Reasoning mode: ${next.name}');
      return _CommandResult.keepGoing(decodeParam, next);
    case '/max-length':
    case '/max-tokens':
      final next = _parseInt(value);
      if (next == null || next <= 0) {
        stdout.writeln('Usage: /max-length <positive-int>');
        return _CommandResult.keepGoing(decodeParam, reasoning);
      }
      decodeParam = decodeParam.copyWith(maxTokens: next);
      await rwkv.setDecodeParam(decodeParam);
      stdout.writeln('Max tokens: $next');
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/temperature':
      final next = _parseDouble(value);
      if (next == null) {
        stdout.writeln('Usage: /temperature <number>');
        return _CommandResult.keepGoing(decodeParam, reasoning);
      }
      decodeParam = decodeParam.copyWith(temperature: next);
      await rwkv.setDecodeParam(decodeParam);
      stdout.writeln('Temperature: $next');
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/top-p':
      final next = _parseDouble(value);
      if (next == null) {
        stdout.writeln('Usage: /top-p <number>');
        return _CommandResult.keepGoing(decodeParam, reasoning);
      }
      decodeParam = decodeParam.copyWith(topP: next);
      await rwkv.setDecodeParam(decodeParam);
      stdout.writeln('Top-p: $next');
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/top-k':
      final next = _parseInt(value);
      if (next == null || next < 0) {
        stdout.writeln('Usage: /top-k <non-negative-int>');
        return _CommandResult.keepGoing(decodeParam, reasoning);
      }
      decodeParam = decodeParam.copyWith(topK: next);
      await rwkv.setDecodeParam(decodeParam);
      stdout.writeln('Top-k: $next');
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/penalty':
    case '/repetition-penalty':
      final next = _parseDouble(value);
      if (next == null) {
        stdout.writeln('Usage: /penalty <number>');
        return _CommandResult.keepGoing(decodeParam, reasoning);
      }
      decodeParam = decodeParam.copyWith(
        presencePenalty: next,
        frequencyPenalty: next,
      );
      await rwkv.setDecodeParam(decodeParam);
      stdout.writeln('Presence/frequency penalty: $next');
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/presence-penalty':
      final next = _parseDouble(value);
      if (next == null) {
        stdout.writeln('Usage: /presence-penalty <number>');
        return _CommandResult.keepGoing(decodeParam, reasoning);
      }
      decodeParam = decodeParam.copyWith(presencePenalty: next);
      await rwkv.setDecodeParam(decodeParam);
      stdout.writeln('Presence penalty: $next');
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/frequency-penalty':
      final next = _parseDouble(value);
      if (next == null) {
        stdout.writeln('Usage: /frequency-penalty <number>');
        return _CommandResult.keepGoing(decodeParam, reasoning);
      }
      decodeParam = decodeParam.copyWith(frequencyPenalty: next);
      await rwkv.setDecodeParam(decodeParam);
      stdout.writeln('Frequency penalty: $next');
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/penalty-decay':
      final next = _parseDouble(value);
      if (next == null) {
        stdout.writeln('Usage: /penalty-decay <number>');
        return _CommandResult.keepGoing(decodeParam, reasoning);
      }
      decodeParam = decodeParam.copyWith(penaltyDecay: next);
      await rwkv.setDecodeParam(decodeParam);
      stdout.writeln('Penalty decay: $next');
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/seed':
      final next = _parseInt(value);
      if (next == null) {
        stdout.writeln('Usage: /seed <int>');
        return _CommandResult.keepGoing(decodeParam, reasoning);
      }
      await rwkv.setSeed(next);
      stdout.writeln('Seed: $next');
      return _CommandResult.keepGoing(decodeParam, reasoning);
    case '/state':
      stdout.writeln(await rwkv.dumpStateInfo());
      return _CommandResult.keepGoing(decodeParam, reasoning);
    default:
      stdout.writeln('Unknown command: $command. Type /help for commands.');
      return _CommandResult.keepGoing(decodeParam, reasoning);
  }
}

class _CommandResult {
  final bool quit;
  final DecodeParam decodeParam;
  final ReasoningEffort reasoning;

  _CommandResult({
    required this.quit,
    required this.decodeParam,
    required this.reasoning,
  });

  factory _CommandResult.keepGoing(
    DecodeParam decodeParam,
    ReasoningEffort reasoning,
  ) {
    return _CommandResult(
      quit: false,
      decodeParam: decodeParam,
      reasoning: reasoning,
    );
  }

  factory _CommandResult.quit(
    DecodeParam decodeParam,
    ReasoningEffort reasoning,
  ) {
    return _CommandResult(
      quit: true,
      decodeParam: decodeParam,
      reasoning: reasoning,
    );
  }
}

class _CliOptions {
  final bool help;
  final bool server;
  final String? provider;
  final String? modelPath;
  final String? tokenizerPath;
  final String? dynamicLibDir;
  final String? qnnLibDir;
  final Backend? backend;
  final String host;
  final int port;
  final String accessKey;
  final String apiKey;
  final String modelId;
  final String modelName;
  final RWKVLogLevel logLevel;
  final DecodeParam decodeParam;
  final ReasoningEffort reasoning;

  const _CliOptions({
    required this.help,
    required this.server,
    required this.provider,
    required this.modelPath,
    required this.tokenizerPath,
    required this.dynamicLibDir,
    required this.qnnLibDir,
    required this.backend,
    required this.host,
    required this.port,
    required this.accessKey,
    required this.apiKey,
    required this.modelId,
    required this.modelName,
    required this.logLevel,
    required this.decodeParam,
    required this.reasoning,
  });

  factory _CliOptions.parse(List<String> args) {
    final parsed = _parseArgs(args);
    final baseDecode = DecodeParam.initial();
    final provider = parsed.value('provider');
    final modelPath = parsed.value('model');
    final modelName =
        parsed.value('name') ?? _fileNameWithoutExtension(modelPath);
    final explicitModelId = parsed.value('model-id') ?? parsed.value('id');
    final backendName = parsed.value('backend');

    return _CliOptions(
      help: parsed.flag('help') || parsed.flag('h'),
      server: parsed.flag('server'),
      provider: provider,
      modelPath: modelPath,
      tokenizerPath: parsed.value('vocab') ?? parsed.value('tokenizer'),
      dynamicLibDir: parsed.value('lib') ?? parsed.value('dynamic-lib-dir'),
      qnnLibDir: parsed.value('qnn-lib-dir'),
      backend: backendName == null ? null : Backend.fromString(backendName),
      host: parsed.value('host') ?? '0.0.0.0',
      port: _parseInt(parsed.value('port') ?? '') ?? 8000,
      accessKey: parsed.value('key') ?? parsed.value('access-key') ?? '',
      apiKey:
          parsed.value('api-key') ??
          parsed.value('key') ??
          parsed.value('access-key') ??
          '',
      modelId: provider == null
          ? explicitModelId ?? modelName
          : explicitModelId ?? '',
      modelName: modelName,
      logLevel:
          RWKVLogLevel.values
              .where((e) => e.name == (parsed.value('log-level') ?? 'debug'))
              .firstOrNull ??
          RWKVLogLevel.debug,
      reasoning:
          ReasoningEffort.fromName(parsed.value('reasoning') ?? 'none') ??
          ReasoningEffort.none,
      decodeParam: baseDecode.copyWith(
        temperature:
            _parseDouble(parsed.value('temperature') ?? '') ??
            baseDecode.temperature,
        topK: _parseInt(parsed.value('top-k') ?? '') ?? baseDecode.topK,
        topP: _parseDouble(parsed.value('top-p') ?? '') ?? baseDecode.topP,
        presencePenalty:
            _parseDouble(parsed.value('presence-penalty') ?? '') ??
            _parseDouble(parsed.value('penalty') ?? '') ??
            baseDecode.presencePenalty,
        frequencyPenalty:
            _parseDouble(parsed.value('frequency-penalty') ?? '') ??
            _parseDouble(parsed.value('penalty') ?? '') ??
            baseDecode.frequencyPenalty,
        penaltyDecay:
            _parseDouble(parsed.value('penalty-decay') ?? '') ??
            baseDecode.penaltyDecay,
        maxTokens:
            _parseInt(parsed.value('max-length') ?? '') ??
            _parseInt(parsed.value('max-tokens') ?? '') ??
            baseDecode.maxTokens,
      ),
    );
  }

  String? get chatModelId => provider == null ? null : modelId;
}

class _ParsedArgs {
  final Map<String, String?> values;

  _ParsedArgs(this.values);

  bool flag(String key) {
    if (!values.containsKey(key)) {
      return false;
    }
    final value = values[key]?.toLowerCase();
    return value == null || value == 'true' || value == '1' || value == 'yes';
  }

  String? value(String key) => values[key];
}

_ParsedArgs _parseArgs(List<String> args) {
  final values = <String, String?>{};
  for (var i = 0; i < args.length; i++) {
    final raw = args[i];
    if (!raw.startsWith('-')) {
      continue;
    }

    final normalized = raw.replaceFirst(RegExp(r'^-+'), '');
    final eq = normalized.indexOf('=');
    if (eq >= 0) {
      values[normalized.substring(0, eq)] = normalized.substring(eq + 1);
      continue;
    }

    final next = i + 1 < args.length ? args[i + 1] : null;
    if (next != null && !next.startsWith('-')) {
      values[normalized] = next;
      i++;
    } else {
      values[normalized] = null;
    }
  }
  return _ParsedArgs(values);
}

void _printUsage() {
  stdout.writeln('''
RWKV CLI

Usage:
  rwkv_cli -model <model> -vocab <tokenizer> [options]
  rwkv_cli -provider <url> -model-id <model-id> [-api-key <key>] [options]
  rwkv_cli -server -model <model> -vocab <tokenizer> [options]

Required:
  Local interactive/server:
    -model <path>            Model file path
    -vocab <path>            Tokenizer/vocab file path

  Provider interactive:
    -provider <url>          Provider base URL
    -model-id <model-id>     Provider model id

Modes:
  -interactive               Start interactive mode (default)
  -server                    Start OpenAI-compatible API server

Provider options:
  -api-key <key>             Provider API key

Server options:
  -host <host>               Default: 0.0.0.0
  -port <port>               Default: 8000
  -key <key>                 Access key
  -id <model-id>             Model id exposed by /v1/models
  -name <model-name>         Model display name

Runtime options:
  -lib <dir>                 Dynamic library directory
  -qnn-lib-dir <dir>         QNN library directory
  -backend <name>            Backend name, e.g. ncnn, llama.cpp, qnn
  -log-level <level>         verbose, info, debug, warning, error

Decode options:
  -max-length <n>
  -temperature <n>
  -top-p <n>
  -top-k <n>
  -penalty <n>
  -presence-penalty <n>
  -frequency-penalty <n>
  -penalty-decay <n>
  -reasoning <mode>          none, mini, low, medium, high, xhig
''');
}

void _printInteractiveHelp() {
  stdout.writeln('''
Commands:
  /help
  /quit, /exit
  /clear
  /history
  /stop
  /reasoning-mode none|mini|low|medium|high|xhig
  /max-length <n>
  /temperature <n>
  /top-p <n>
  /top-k <n>
  /penalty <n>
  /presence-penalty <n>
  /frequency-penalty <n>
  /penalty-decay <n>
  /seed <n>
  /state
''');
}

void _printHistory(List<ChatMessage> messages) {
  if (messages.isEmpty) {
    stdout.writeln('History is empty.');
    return;
  }

  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    stdout.writeln(
      '${i + 1}. ${message.role}: ${_previewMessage(message.content)}',
    );
  }
}

String _previewMessage(String content) {
  final escaped = content
      .replaceAll('\r\n', r'\n')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\n');
  final runes = escaped.runes.toList();
  if (runes.length <= 100) {
    return escaped;
  }
  final start = String.fromCharCodes(runes.take(50));
  final end = String.fromCharCodes(runes.skip(runes.length - 50));
  return '$start ... $end';
}

int? _parseInt(String value) => int.tryParse(value.trim());

double? _parseDouble(String value) => double.tryParse(value.trim());

void _configureConsoleEncoding() {
  stdout.encoding = utf8;
  stderr.encoding = utf8;
}

int _fileSize(String path) {
  final file = File(path);
  return file.existsSync() ? file.lengthSync() : 0;
}

String _fileNameWithoutExtension(String? path) {
  if (path == null || path.trim().isEmpty) {
    return 'rwkv';
  }
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}
