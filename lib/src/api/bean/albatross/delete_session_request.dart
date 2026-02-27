@pragma("json_id:delete_session_request_001")
class DeleteSessionRequest {
  final String sessionId;
  final bool deletePrefix;
  final String? password;

  DeleteSessionRequest({
    required this.sessionId,
    this.deletePrefix = false,
    this.password,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['session_id'] = sessionId;
    data['delete_prefix'] = deletePrefix;
    if (password != null) data['password'] = password;
    return data;
  }
}
