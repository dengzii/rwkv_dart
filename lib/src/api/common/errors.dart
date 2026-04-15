import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

Future checkError(dynamic error) async {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        throw TimeoutException('Connection timed out');
      case DioExceptionType.sendTimeout:
        throw TimeoutException('Send timed out');
      case DioExceptionType.receiveTimeout:
        throw TimeoutException('Receive timed out');
      case DioExceptionType.badCertificate:
        throw Exception('Bad certificate');
      case DioExceptionType.badResponse:
        final resp = error.response;
        final status = resp?.statusCode;
        if (resp != null && status != null && status >= 400) {
          final body = resp.data;
          String msg =
              "HTTP ${resp.statusCode} ${resp.statusMessage}  ${error.requestOptions.uri}";
          if (body is ResponseBody) {
            final str = await body.stream
                .transform(StreamTransformer.fromBind(utf8.decoder.bind))
                .toList()
                .then((e) => e.join());
            msg += "\nbody: $str";
          }
          throw Exception(msg);
        }

      case DioExceptionType.connectionError:
        throw Exception('Connection error');
      case DioExceptionType.cancel:
      case DioExceptionType.unknown:
    }
  }
}
