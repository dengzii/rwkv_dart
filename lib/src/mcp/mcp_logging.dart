import 'package:rwkv_dart/src/logger.dart';

enum McpLogVerbosity { off, basic, debug, trace }

McpLogVerbosity _mcpLogVerbosity = McpLogVerbosity.debug;

McpLogVerbosity get mcpLogVerbosity => _mcpLogVerbosity;

void setMcpLogVerbosity(McpLogVerbosity verbosity) {
  _mcpLogVerbosity = verbosity;
}

McpLogVerbosity parseMcpLogVerbosity(
  String? raw, {
  McpLogVerbosity fallback = McpLogVerbosity.debug,
}) {
  switch (raw?.trim().toLowerCase()) {
    case 'off':
      return McpLogVerbosity.off;
    case 'basic':
      return McpLogVerbosity.basic;
    case 'debug':
      return McpLogVerbosity.debug;
    case 'trace':
    case 'verbose':
      return McpLogVerbosity.trace;
    case null:
    case '':
      return fallback;
    default:
      return fallback;
  }
}

bool _isEnabled(McpLogVerbosity threshold) {
  return _mcpLogVerbosity != McpLogVerbosity.off &&
      _mcpLogVerbosity.index >= threshold.index;
}

void mcpLogBasic(dynamic msg) {
  if (_isEnabled(McpLogVerbosity.basic)) {
    logi(msg);
  }
}

void mcpLogDebug(dynamic msg) {
  logd(msg);
}

void mcpLogTrace(dynamic msg) {
  if (_isEnabled(McpLogVerbosity.trace)) {
    logv(msg);
  }
}

void mcpLogWarning(dynamic msg) {
  logw(msg);
}

void mcpLogError(dynamic msg) {
  loge(msg);
}
