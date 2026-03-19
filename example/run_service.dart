import 'package:rwkv_dart/rwkv_dart.dart';

void main() async {
  final server = RwkvHttpApiService();
  await server.run(
    host: '0.0.0.0',
    port: 9527,
    accessKey: '',
    modelListPath: './example/models.json',
  );
}
