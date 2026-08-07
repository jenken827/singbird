import 'package:path_provider/path_provider.dart';

late final String dataDir;

Future<void> initDataDir() async {
  final dir = await getApplicationSupportDirectory();
  dataDir = dir.path;
}
