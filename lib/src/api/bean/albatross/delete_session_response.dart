@pragma("json_id:delete_session_response_001")
class DeleteSessionResponse {
  final String status;
  final String message;

  DeleteSessionResponse({
    required this.status,
    required this.message,
  });

  factory DeleteSessionResponse.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return DeleteSessionResponse(
      status: json['status'] ?? '',
      message: json['message'] ?? '',
    );
  }
}
