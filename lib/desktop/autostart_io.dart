import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win32_registry/win32_registry.dart';

/// Startet AnTaTime bei der Anmeldung am System.
///
/// - Linux: `~/.config/autostart/com.lotterfriends.antatime.desktop`
///   (XDG-Autostart; beim AppImage wird die AppImage-Datei gestartet)
/// - Windows: Eintrag unter `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
/// - macOS (ab 13): Anmeldeobjekt über `SMAppService` (MainFlutterWindow.swift)
///
/// Linux und Windows übergeben [flag], daran erkennt die App den Autostart.
/// macOS kann Anmeldeobjekten keine Argumente mitgeben; dort gilt ein Start
/// kurz nach dem Hochfahren bei aktivem Anmeldeobjekt als Autostart.
class Autostart {
  Autostart._();
  static final instance = Autostart._();

  static const flag = '--autostart';
  static const _appId = 'com.lotterfriends.antatime';
  static const _runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _runValue = 'AnTaTime';
  static const _mac = MethodChannel('antatime/autostart');

  bool get supported => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// Wurde die App gerade automatisch mit dem System gestartet?
  Future<bool> launchedAtStartup(List<String> args) async {
    if (args.contains(flag)) return true;
    if (!Platform.isMacOS) return false;
    try {
      return await _mac.invokeMethod<bool>('launchedAtLogin') ?? false;
    } on Exception catch (e) {
      debugPrint('Autostart: $e');
      return false;
    }
  }

  Future<bool> isEnabled() async {
    try {
      if (Platform.isLinux) return _linuxFile.existsSync();
      if (Platform.isWindows) {
        final key = CURRENT_USER.create(_runKey);
        try {
          return key.getString(_runValue) != null;
        } finally {
          key.close();
        }
      }
      if (Platform.isMacOS) {
        return await _mac.invokeMethod<bool>('isEnabled') ?? false;
      }
    } on Exception catch (e) {
      debugPrint('Autostart: $e');
    }
    return false;
  }

  /// Ist der Autostart eingeschaltet, zeigt aber auf eine andere Programm-
  /// datei (z. B. AppImage verschoben oder umbenannt, App neu installiert),
  /// wird er auf die aktuelle umgestellt – sonst stünde der Schalter auf
  /// „an“, gestartet würde aber nichts. Beim Programmstart aufrufen.
  Future<void> refresh() async {
    try {
      if (Platform.isLinux) {
        final file = _linuxFile;
        if (file.existsSync() && file.readAsStringSync() != _desktopEntry()) {
          await file.writeAsString(_desktopEntry());
        }
      } else if (Platform.isWindows) {
        final key = CURRENT_USER.create(_runKey);
        try {
          final v = key.getString(_runValue);
          if (v != null && v != _windowsCommand) {
            key.setValue(_runValue, RegistryValue.string(_windowsCommand));
          }
        } finally {
          key.close();
        }
      }
    } on Exception catch (e) {
      debugPrint('Autostart: $e');
    }
  }

  String get _windowsCommand => '"${Platform.resolvedExecutable}" $flag';

  /// Wirft eine Exception, wenn das System die Änderung ablehnt.
  Future<void> setEnabled(bool enabled) async {
    if (Platform.isLinux) {
      final file = _linuxFile;
      if (enabled) {
        await file.parent.create(recursive: true);
        await file.writeAsString(_desktopEntry());
      } else if (file.existsSync()) {
        await file.delete();
      }
    } else if (Platform.isWindows) {
      final key = CURRENT_USER.create(_runKey);
      try {
        if (enabled) {
          key.setValue(_runValue, RegistryValue.string(_windowsCommand));
        } else if (key.getString(_runValue) != null) {
          key.removeValue(_runValue);
        }
      } finally {
        key.close();
      }
    } else if (Platform.isMacOS) {
      await _mac.invokeMethod<void>('setEnabled', enabled);
    }
  }

  // --- Linux -----------------------------------------------------------------

  File get _linuxFile {
    final env = Platform.environment;
    final config = env['XDG_CONFIG_HOME']?.isNotEmpty == true
        ? env['XDG_CONFIG_HOME']!
        : '${env['HOME']}/.config';
    return File('$config/autostart/$_appId.desktop');
  }

  /// Beim AppImage zeigt die Programmdatei in ein temporäres Verzeichnis;
  /// gestartet werden muss die AppImage-Datei selbst.
  String get _linuxExecutable {
    final appImage = Platform.environment['APPIMAGE'];
    return appImage != null && appImage.isNotEmpty
        ? appImage
        : Platform.resolvedExecutable;
  }

  String _desktopEntry() => '''
[Desktop Entry]
Type=Application
Name=AnTaTime
Comment=Arbeitszeiterfassung beim Anmelden starten
Exec=${quoteExec(_linuxExecutable)} $flag
Icon=$_appId
Terminal=false
X-GNOME-Autostart-enabled=true
''';

  /// Quoting nach der Desktop-Entry-Spezifikation (Exec-Schlüssel).
  @visibleForTesting
  static String quoteExec(String path) {
    final escaped = path.replaceAllMapped(
        RegExp(r'[\\"`$]'), (m) => '\\${m[0]}');
    // Backslashes werden in Desktop-Dateien zusätzlich als String maskiert;
    // `%` leitet Feldcodes ein (%f, %u …) und muss als `%%` stehen.
    return '"${escaped.replaceAll(r'\', r'\\').replaceAll('%', '%%')}"';
  }
}
