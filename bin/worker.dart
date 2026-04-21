import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/worker/worker.dart';

Future<void> main(List<String> args) async {
  setRWKVCallback((record) {
    stderr.writeln(
      '[rwkv-worker] '
      '${record.time.toIso8601String()} '
      '${record.level.name} '
      '[${record.loggerName}] '
      '${record.message}',
    );
    if (record.error != null) {
      stderr.writeln(record.error);
    }
    if (record.stackTrace != null) {
      stderr.writeln(record.stackTrace);
    }
  });

  stderr.writeln('[rwkv-worker] starting pid=$pid args=${args.join(' ')}');
  final rwkv = RWKV.create();
  final ipc = WorkerIPC(Worker(rwkv));
  try {
    stderr.writeln('[rwkv-worker] ipc ready');
    await ipc.start();
    stderr.writeln('[rwkv-worker] ipc stopped');
  } catch (e, s) {
    stderr.writeln('[rwkv-worker] fatal error: $e');
    stderr.writeln(s);
    rethrow;
  } finally {
    stderr.writeln('[rwkv-worker] exiting');
  }
}
