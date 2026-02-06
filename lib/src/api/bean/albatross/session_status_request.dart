@pragma("json_id:session_status_request_001")
class SessionStatusRequest {
  final String? password;

  SessionStatusRequest({this.password});

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    if (password != null) data['password'] = password;
    return data;
  }
}
