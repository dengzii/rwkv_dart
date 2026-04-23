class WorkerSocketIpcConfig {
  static const hostFlag = '--ipc-host';
  static const portFlag = '--ipc-port';

  final String host;
  final int port;

  const WorkerSocketIpcConfig({required this.host, required this.port});

  List<String> toArgs() => [hostFlag, host, portFlag, '$port'];

  static WorkerSocketIpcConfig fromArgs(List<String> args) {
    String? host;
    int? port;

    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case hostFlag:
          if (i + 1 >= args.length) {
            throw const FormatException('Missing value for --ipc-host');
          }
          host = args[++i];
          break;
        case portFlag:
          if (i + 1 >= args.length) {
            throw const FormatException('Missing value for --ipc-port');
          }
          port = int.tryParse(args[++i]);
          if (port == null) {
            throw const FormatException('Invalid value for --ipc-port');
          }
          break;
      }
    }

    if (host == null || port == null) {
      throw const FormatException(
        'Both --ipc-host and --ipc-port are required for socket IPC',
      );
    }
    return WorkerSocketIpcConfig(host: host, port: port);
  }
}
