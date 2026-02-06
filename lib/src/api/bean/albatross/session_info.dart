@pragma("json_id:session_info_001")
class SessionInfo {
  final String sessionId;
  final String cacheLevel;
  final String lastUpdated;
  final double timestamp;

  SessionInfo({
    required this.sessionId,
    required this.cacheLevel,
    required this.lastUpdated,
    required this.timestamp,
  });

  factory SessionInfo.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return SessionInfo(
      sessionId: json['session_id'] ?? '',
      cacheLevel: json['cache_level'] ?? '',
      lastUpdated: json['last_updated'] ?? '',
      timestamp: (json['timestamp'] ?? 0).toDouble(),
    );
  }
}
