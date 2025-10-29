import 'package:logging/logging.dart';

final _logger = Logger('RWKV');

bool _loggerInitialized = false;

void _listenToLogs() {
  if (_loggerInitialized) {
    return;
  }

  _loggerInitialized = true;
  Logger.root.onRecord.listen((record) {
    final time =
        '${record.time.hour}:${record.time.minute}:${record.time.second}';
    print('$time\tRWKV/${record.level.name}: ${record.message}');
  });
}

void setLogLevel(Level level) {
  Logger.root.level = level;
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
