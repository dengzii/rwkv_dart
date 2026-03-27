import 'package:logging/logging.dart';
import 'package:rwkv_dart/rwkv_dart.dart';

final _logger = Logger.detached('RWKV');

Logger get logger => _logger;
final _level = {
  Level.ALL: RWKVLogLevel.verbose,
  Level.CONFIG: RWKVLogLevel.info,
  Level.INFO: RWKVLogLevel.debug,
  Level.WARNING: RWKVLogLevel.warning,
  Level.SEVERE: RWKVLogLevel.error,
};

void setLoggerLevel(RWKVLogLevel level) {
  _logger.level = {
    RWKVLogLevel.verbose: Level.ALL,
    RWKVLogLevel.info: Level.INFO,
    RWKVLogLevel.debug: Level.CONFIG,
    RWKVLogLevel.warning: Level.WARNING,
    RWKVLogLevel.error: Level.SEVERE,
  }[level]!;
}

typedef LogCallback = Function(RWKVLogLevel level, String log);

void setLogCallback(LogCallback callback) {
  _logger.clearListeners();
  _logger.onRecord.listen((record) {
    callback(_level[record.level] ?? RWKVLogLevel.debug, record.message);
  });
}

void logv(dynamic msg) {
  if (!_logger.isLoggable(Level.ALL)) {
    return;
  }
  _logger.fine(msg);
}

void logi(dynamic msg) {
  if (!_logger.isLoggable(Level.INFO)) {
    return;
  }
  _logger.config(msg);
}

void logd(dynamic msg) {
  if (!_logger.isLoggable(Level.CONFIG)) {
    return;
  }
  _logger.info(msg);
}

void logw(dynamic msg) {
  if (!_logger.isLoggable(Level.WARNING)) {
    return;
  }
  _logger.warning(msg);
}

void loge(dynamic msg) {
  if (!_logger.isLoggable(Level.SEVERE)) {
    return;
  }
  _logger.severe(msg);
}

void logwtf(dynamic msg) {
  if (!_logger.isLoggable(Level.SHOUT)) {
    return;
  }
  _logger.shout(msg);
}
