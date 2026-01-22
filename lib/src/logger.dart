import 'package:logging/logging.dart';
import 'package:rwkv_dart/rwkv_dart.dart';

final _logger = Logger('RWKV');

bool _loggerInitialized = false;

final _level = {
  Level.ALL: RWKVLogLevel.verbose,
  Level.CONFIG: RWKVLogLevel.info,
  Level.INFO: RWKVLogLevel.debug,
  Level.WARNING: RWKVLogLevel.warning,
  Level.SEVERE: RWKVLogLevel.error,
};

typedef LogCallback = Function(RWKVLogLevel level, String log);

void _listenToLogs() {
  if (_loggerInitialized) {
    return;
  }

  _loggerInitialized = true;
  Logger.root.level = Level.ALL;
  Logger.root.clearListeners();
  Logger.root.onRecord.listen((record) {
    final time =
        '${record.time.hour}:${record.time.minute}:${record.time.second}';
    print('$time\tRWKV/${record.level.name}: ${record.message}');
  });
}

void setLogCallback(LogCallback callback) {
  Logger.root.clearListeners();
  Logger.root.onRecord.listen((record) {
    callback(_level[record.level] ?? RWKVLogLevel.debug, record.message);
  });
}

void logv(dynamic msg) {
  _listenToLogs();
  _logger.fine(msg);
}

void logi(dynamic msg) {
  _listenToLogs();
  _logger.config(msg);
}

void logd(dynamic msg) {
  _listenToLogs();
  _logger.info(msg);
}

void logw(dynamic msg) {
  _listenToLogs();
  _logger.warning(msg);
}

void loge(dynamic msg) {
  _listenToLogs();
  _logger.severe(msg);
}

void logwtf(dynamic msg) {
  _listenToLogs();
  _logger.shout(msg);
}
