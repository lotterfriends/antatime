import 'update_manifest.dart';

/// Im Browser ist jedes Neuladen das Update.
class UpdatePlatform {
  UpdatePlatform._();
  static final instance = UpdatePlatform._();

  UpdateKind? get kind => null;
  String? get arch => null;
  bool get opensInBrowser => false;

  Future<void> openInBrowser(Uri url) async {}

  Future<Object?> fetchManifest(Uri url) async => null;

  Future<String> download(
    UpdatePackage package,
    Uri url, {
    required void Function(double progress) onProgress,
  }) =>
      throw UnsupportedError('Updates gibt es im Browser nicht');

  Future<void> install(String path, {Future<void> Function()? quit}) async {}

  Future<void> cleanup() async {}
}
