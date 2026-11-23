/// Im Browser gibt es keinen Autostart.
class Autostart {
  Autostart._();
  static final instance = Autostart._();

  bool get supported => false;

  Future<bool> launchedAtStartup(List<String> args) async => false;

  Future<bool> isEnabled() async => false;

  Future<void> setEnabled(bool enabled) async {}

  Future<void> refresh() async {}
}
