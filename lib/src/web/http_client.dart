import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:fetch_client/fetch_client.dart';
import 'package:http/http.dart' as http;

HttpClientAdapter createAdapter() => ConversionLayerAdapter(
  FetchClient(
    cache: RequestCache.noCache,
    redirectPolicy: RedirectPolicy.alwaysFollow,
    referrerPolicy: RequestReferrerPolicy.unsafeUrl,
    mode: RequestMode.cors,
  ),
);

class FetchHttpClientAdapter implements HttpClientAdapter {
  final _client = FetchClient(
    redirectPolicy: RedirectPolicy.alwaysFollow,
    referrerPolicy: RequestReferrerPolicy.unsafeUrl,
    mode: RequestMode.cors,
    streamRequests: true,
  );

  @override
  void close({bool force = false}) {
    _client.close();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final client = FetchClient(mode: RequestMode.cors);

    final requestData = await requestStream
        ?.map((data) => utf8.decode(data.toList()))
        .join();

    final request = http.AbortableRequest(options.method, options.uri)
      ..headers.addAll({
        for (final entry in options.headers.entries) entry.key: entry.value,
      })
      ..body = requestData ?? '';

    final response = await client.send(request);
    final stream = response.stream.map(Uint8List.fromList);
    return ResponseBody(
      stream,
      response.statusCode,
      statusMessage: response.reasonPhrase,
      headers: {
        for (final entry in response.headers.entries) entry.key: [entry.value],
      },
    );
  }
}
