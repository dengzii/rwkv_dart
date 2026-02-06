@pragma("json_id:delete_session_request_001")
class DeleteSessionRequest {
  final String sessionId;
  final String? password;

  DeleteSessionRequest({
    required this.sessionId,
    this.password,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['session_id'] = sessionId;
    if (password != null) data['password'] = password;
    return data;
  }
}
