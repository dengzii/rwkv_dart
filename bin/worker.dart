import 'dart:async';
import 'dart:io';

import 'package:rwkv_dart/rwkv_dart.dart';
import 'package:rwkv_dart/src/worker/ipc.dart';
import 'package:rwkv_dart/src/worker/worker.dart';

Future<void> main(List<String> args) async {
  await runZoned(
    () async {
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

      final socketConfig = WorkerSocketIpcConfig.fromArgs(args);

      stderr.writeln('[rwkv-worker] starting pid=$pid args=${args.join(' ')}');
      stderr.writeln(
        '[rwkv-worker] connecting ipc socket '
        '${socketConfig.host}:${socketConfig.port}',
      );
      final socket = await Socket.connect(socketConfig.host, socketConfig.port);

      final rwkv = RWKV.create();
      final ipc = WorkerIPC(
        Worker(rwkv),
        input: socket.cast<List<int>>(),
        output: socket,
      );
      try {
        stderr.writeln('[rwkv-worker] ipc ready via socket');
        await ipc.start();
        stderr.writeln('[rwkv-worker] ipc stopped');
      } catch (e, s) {
        stderr.writeln('[rwkv-worker] fatal error: $e');
        stderr.writeln(s);
        rethrow;
      } finally {
        await socket.close();
        stderr.writeln('[rwkv-worker] exiting');
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        stderr.writeln('[rwkv-worker][print] $line');
      },
    ),
  );
}
