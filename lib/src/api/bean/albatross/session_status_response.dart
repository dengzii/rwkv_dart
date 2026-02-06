import 'session_info.dart';

@pragma("json_id:session_status_response_001")
class SessionStatusResponse {
  final String status;
  final int totalSessions;
  final int l1CacheCount;
  final int l2CacheCount;
  final int databaseCount;
  final List<SessionInfo> sessions;

  SessionStatusResponse({
    required this.status,
    required this.totalSessions,
    required this.l1CacheCount,
    required this.l2CacheCount,
    required this.databaseCount,
    required this.sessions,
  });

  factory SessionStatusResponse.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return SessionStatusResponse(
      status: json['status'] ?? '',
      totalSessions: json['total_sessions'] ?? 0,
      l1CacheCount: json['l1_cache_count'] ?? 0,
      l2CacheCount: json['l2_cache_count'] ?? 0,
      databaseCount: json['database_count'] ?? 0,
      sessions:
          (json['sessions'] as Iterable?)
              ?.map((e) => SessionInfo.fromJson(e))
              .toList() ??
          [],
    );
  }
}
