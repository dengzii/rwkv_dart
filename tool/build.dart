import 'dart:io';

const _apps = <BuildApp>[
  BuildApp(name: 'cli', entrypoint: 'bin/cli.dart'),
  BuildApp(name: 'worker', entrypoint: 'bin/worker.dart'),
];

const _targets = <BuildTarget>[
  BuildTarget(os: 'windows', arch: 'x64'),
  BuildTarget(os: 'windows', arch: 'arm64'),
  BuildTarget(os: 'linux', arch: 'x64'),
  BuildTarget(os: 'linux', arch: 'arm64'),
  BuildTarget(os: 'macos', arch: 'x64'),
  BuildTarget(os: 'macos', arch: 'arm64'),
];

Future<void> main(List<String> args) async {
  try {
    final options = BuildOptions.parse(args);
    if (options.help) {
      _printUsage();
      return;
    }
    if (options.listTargets) {
      _printTargets();
      return;
    }

    final failures = <String>[];
    final skipped = <String>[];
    for (final target in options.targets) {
      for (final app in options.apps) {
        final result = await _compile(app, target, options.output);
        switch (result.status) {
          case BuildStatus.success:
            break;
          case BuildStatus.skipped:
            skipped.add('${app.name}:${target.name}');
          case BuildStatus.failed:
            failures.add('${app.name}:${target.name}');
        }
      }
    }

    if (skipped.isNotEmpty) {
      stdout.writeln('Skipped unsupported targets: ${skipped.join(', ')}');
    }

    if (failures.isNotEmpty) {
      stderr.writeln('Build failed: ${failures.join(', ')}');
      exitCode = 1;
      return;
    }

    stdout.writeln('Build complete: ${options.output}');
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    _printUsage();
    exitCode = 64;
  }
}

Future<BuildResult> _compile(
  BuildApp app,
  BuildTarget target,
  String outputRoot,
) async {
  final targetDir = Directory(_join([outputRoot, target.name]));
  await targetDir.create(recursive: true);

  final output = _join([
    targetDir.path,
    target.os == 'windows' ? '${app.name}.exe' : app.name,
  ]);

  final args = <String>[
    'compile',
    'exe',
    '--target-os=${target.os}',
    '--target-arch=${target.arch}',
    '-o',
    output,
    app.entrypoint,
  ];

  stdout.writeln('Building ${app.name} for ${target.name}...');
  final result = await Process.run(Platform.resolvedExecutable, args);
  final stdoutText = result.stdout.toString();
  final stderrText = result.stderr.toString();
  final outputText = '$stdoutText\n$stderrText';

  if (result.exitCode != 0 && _isUnsupportedTarget(outputText)) {
    stdout.writeln(
      'Skipped ${app.name} for ${target.name}: unsupported by this Dart SDK.',
    );
    return const BuildResult(BuildStatus.skipped);
  }

  stdout.write(stdoutText);
  stderr.write(stderrText);
  return BuildResult(
    result.exitCode == 0 ? BuildStatus.success : BuildStatus.failed,
  );
}

String _join(List<String> parts) {
  return parts.where((part) => part.isNotEmpty).join(Platform.pathSeparator);
}

bool _isUnsupportedTarget(String output) {
  return output.contains('Unsupported target platform');
}

void _printUsage() {
  stdout.writeln('''
Build rwkv_dart command line executables.

Usage:
  dart run tool/build.dart [options]

Options:
  --targets <list>   Comma-separated targets. Default: all desktop targets.
                     Example: --targets windows-x64,linux-x64
  --apps <list>      Comma-separated apps: cli, worker. Default: all.
                     Example: --apps cli
  --output <dir>     Output directory. Default: build/bin
  --list-targets     Print supported targets.
  -h, --help         Print this help.

Outputs:
  build/bin/<target>/cli[.exe]
  build/bin/<target>/worker[.exe]
''');
}

void _printTargets() {
  stdout.writeln(_targets.map((target) => target.name).join('\n'));
}

class BuildOptions {
  final bool help;
  final bool listTargets;
  final List<BuildTarget> targets;
  final List<BuildApp> apps;
  final String output;

  const BuildOptions({
    required this.help,
    required this.listTargets,
    required this.targets,
    required this.apps,
    required this.output,
  });

  factory BuildOptions.parse(List<String> args) {
    var help = false;
    var listTargets = false;
    var targets = _targets;
    var apps = _apps;
    var output = 'build/bin';

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      switch (arg) {
        case '-h':
        case '--help':
          help = true;
        case '--list-targets':
          listTargets = true;
        case '--targets':
          targets = _parseTargets(_readValue(args, ++i, arg));
        case '--apps':
          apps = _parseApps(_readValue(args, ++i, arg));
        case '--output':
        case '-o':
          output = _readValue(args, ++i, arg);
        default:
          if (arg.startsWith('--targets=')) {
            targets = _parseTargets(arg.substring('--targets='.length));
          } else if (arg.startsWith('--apps=')) {
            apps = _parseApps(arg.substring('--apps='.length));
          } else if (arg.startsWith('--output=')) {
            output = arg.substring('--output='.length);
          } else {
            throw FormatException('Unknown option: $arg');
          }
      }
    }

    return BuildOptions(
      help: help,
      listTargets: listTargets,
      targets: targets,
      apps: apps,
      output: output,
    );
  }
}

String _readValue(List<String> args, int index, String option) {
  if (index >= args.length || args[index].startsWith('-')) {
    throw FormatException('Missing value for $option');
  }
  return args[index];
}

List<BuildTarget> _parseTargets(String value) {
  final requested = _splitList(value);
  if (requested.contains('all')) {
    return _targets;
  }

  return requested.map((name) {
    final target = _targets.where((target) => target.name == name).firstOrNull;
    if (target == null) {
      throw FormatException('Unknown target: $name');
    }
    return target;
  }).toList();
}

List<BuildApp> _parseApps(String value) {
  final requested = _splitList(value);
  if (requested.contains('all')) {
    return _apps;
  }

  return requested.map((name) {
    final app = _apps.where((app) => app.name == name).firstOrNull;
    if (app == null) {
      throw FormatException('Unknown app: $name');
    }
    return app;
  }).toList();
}

List<String> _splitList(String value) {
  final values = value
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  if (values.isEmpty) {
    throw const FormatException('Expected a non-empty comma-separated list');
  }
  return values;
}

class BuildApp {
  final String name;
  final String entrypoint;

  const BuildApp({required this.name, required this.entrypoint});
}

class BuildTarget {
  final String os;
  final String arch;

  const BuildTarget({required this.os, required this.arch});

  String get name => '$os-$arch';
}

enum BuildStatus { success, failed, skipped }

class BuildResult {
  final BuildStatus status;

  const BuildResult(this.status);
}
