abstract class McpTransport {
  Stream<Map<String, dynamic>> get messages;

  Stream<String> get stderrLines;

  Future<void> start();

  Future<void> send(Map<String, dynamic> message);

  Future<void> close();
}
