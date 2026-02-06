@pragma("json_id:error_response_001")
class ErrorResponse {
  final String error;

  ErrorResponse({
    required this.error,
  });

  factory ErrorResponse.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return ErrorResponse(
      error: json['error'] ?? '',
    );
  }
}
