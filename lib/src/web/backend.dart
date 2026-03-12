import 'package:rwkv_dart/src/api/client/open_ai.dart';

class RWKVBackend extends OpenAiApiClient {
  RWKVBackend([String? url, String? apiKey])
    : super(url ?? '', apiKey: apiKey ?? '') {
    if (url == null || url.isEmpty) {
      throw UnsupportedError(
        'RWKV.create() is unsupported in browser, use RWKV.network() instead.',
      );
    }
  }
}
