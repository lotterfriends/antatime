import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'update_manifest.dart';

/// Lädt Updates herunter und installiert sie.
///
/// Quelle ist ein GitHub-Release oder ein AnTaTime-Server (siehe
/// UpdateService); geprüft wird immer mit Größe und SHA-256 aus der Liste.
///
/// - Android: Die APK landet im Cache der App und wird dem
///   Paketinstaller des Systems übergeben (AppUpdate.kt); der fragt nach.
/// - Linux, AppImage: Die neue Datei ersetzt die alte, danach Neustart.
/// - Linux, .deb: Installation über `pkexec` (das System fragt nach dem
///   Passwort), danach Neustart.
/// - Linux, tar.gz: Das entpackte Verzeichnis ersetzt das alte, danach
///   Neustart.
/// - Windows, Installer: Ein PowerShell-Helfer wartet auf das Ende der App,
///   führt das Setup still aus und startet die App wieder.
/// - Windows, Zip (portabel): Der Helfer kopiert die entpackten Dateien
///   über die alten und startet die App wieder.
/// - macOS: Die App läuft in der Sandbox und kann sich nicht selbst
///   ersetzen; der Browser lädt das Disk-Image, eingespielt wird von Hand.
class UpdatePlatform {
  UpdatePlatform._() : kind = _detectKind();

  /// Mit fester Paketart, unabhängig von der tatsächlichen Installation.
  @visibleForTesting
  UpdatePlatform.forTesting(this.kind);

  static final instance = UpdatePlatform._();

  /// Android: AppUpdate.kt, macOS: MainFlutterWindow.swift
  static const _native = MethodChannel('antatime/update');

  /// Installationsverzeichnis des .deb (scripts/build_linux.sh).
  static const _debPrefix = '/opt/antatime/';

  static const _timeout = Duration(seconds: 20);

  /// Ohne neue Daten gilt ein Download nach dieser Zeit als hängengeblieben.
  static const _stallTimeout = Duration(seconds: 60);

  /// Paketart dieser Installation; `null` = kann sich nicht selbst
  /// aktualisieren (andere Plattform, Entwicklungs-Build).
  final UpdateKind? kind;

  static UpdateKind? _detectKind() => Platform.isAndroid
      ? UpdateKind.apk
      : Platform.isLinux
          ? linuxKind(
              env: Platform.environment,
              executable: Platform.resolvedExecutable,
              release: kReleaseMode,
            )
          : Platform.isWindows
              ? windowsKind(
                  executable: Platform.resolvedExecutable,
                  release: kReleaseMode,
                  hasUninstaller: File(
                          '${File(Platform.resolvedExecutable).parent.path}'
                          '\\$_uninstaller')
                      .existsSync(),
                )
              : Platform.isMacOS &&
                      kReleaseMode &&
                      !Platform.resolvedExecutable.contains('/build/macos/')
                  ? UpdateKind.dmg
                  : null;

  /// APK und macOS-App enthalten alle Architekturen.
  String? get arch => Platform.isLinux
      ? (Abi.current() == Abi.linuxArm64 ? 'arm64' : 'x64')
      : Platform.isWindows
          ? 'x64'
          : null;

  /// Statt [download] und [install]: Der Browser lädt das Paket, der
  /// Benutzer spielt es selbst ein (macOS).
  bool get opensInBrowser => kind == UpdateKind.dmg;

  Future<void> openInBrowser(Uri url) => _guard(() async {
        final ok = await _native.invokeMethod<bool>('open', url.toString());
        if (ok != true) {
          throw UpdateException('Der Browser ließ sich nicht öffnen');
        }
      });

  /// Legt Inno Setup neben die installierte App (windows/installer).
  static const _uninstaller = 'unins000.exe';

  /// Woran die Art der Windows-Installation erkannt wird.
  @visibleForTesting
  static UpdateKind? windowsKind({
    required String executable,
    required bool release,
    required bool hasUninstaller,
  }) {
    if (!release || executable.contains(r'\build\windows\')) return null;
    return hasUninstaller ? UpdateKind.exe : UpdateKind.zip;
  }

  /// Woran die Art der Linux-Installation erkannt wird.
  @visibleForTesting
  static UpdateKind? linuxKind({
    required Map<String, String> env,
    required String executable,
    required bool release,
  }) {
    if (!release) return null;
    if (env['APPIMAGE']?.isNotEmpty == true) return UpdateKind.appimage;
    if (executable.startsWith(_debPrefix)) return UpdateKind.deb;
    // Direkt aus dem Build-Verzeichnis gestartet: nichts überschreiben.
    if (executable.contains('/build/linux/')) return null;
    return UpdateKind.tar;
  }

  /// Liest die Paketliste (GitHub-Release oder `latest.json` eines
  /// AnTaTime-Servers); wirft [UpdateException], wenn das nicht gelingt.
  Future<Object?> fetchManifest(Uri url) => _guard(() async {
        final client = HttpClient()..connectionTimeout = _timeout;
        try {
          final request = await client.getUrl(url).timeout(_timeout);
          if (url.host == 'api.github.com') {
            request.headers
              ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
              ..set('X-GitHub-Api-Version', '2022-11-28');
          }
          final response = await request.close().timeout(_timeout);
          if (response.statusCode == HttpStatus.notFound) {
            await response.drain<void>();
            throw UpdateException('Dort werden keine Updates angeboten');
          }
          // GitHub ohne Anmeldung: 60 Abfragen pro Stunde und Anschluss.
          if (response.statusCode == HttpStatus.forbidden ||
              response.statusCode == HttpStatus.tooManyRequests) {
            await response.drain<void>();
            throw UpdateException(
                'Zu viele Abfragen von diesem Anschluss – bitte später erneut suchen');
          }
          if (response.statusCode != HttpStatus.ok) {
            await response.drain<void>();
            throw UpdateException(
                'Der Server antwortet mit Fehler ${response.statusCode}');
          }
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response.timeout(_timeout)) {
            bytes.add(chunk);
            // Ein Release mit langen Notizen kann einige 100 kB haben.
            if (bytes.length > 4 * 1024 * 1024) {
              throw UpdateException('Unerwartete Antwort des Servers');
            }
          }
          try {
            return jsonDecode(utf8.decode(bytes.takeBytes()));
          } on FormatException {
            throw UpdateException('Unerwartete Antwort des Servers');
          }
        } finally {
          client.close(force: true);
        }
      });

  /// Lädt [package] von [url] und prüft Größe und SHA-256. Liefert den Pfad
  /// der fertigen Datei; eine bereits vollständig geladene wird
  /// wiederverwendet.
  Future<String> download(
    UpdatePackage package,
    Uri url, {
    required void Function(double progress) onProgress,
  }) =>
      _guard(() async {
        final target = File(await _target(package));
        if (await target.exists() &&
            await target.length() == package.size &&
            await _sha256Of(target.openRead()) == package.sha256) {
          return target.path;
        }
        await target.parent.create(recursive: true);
        final part = File('${target.path}.part');
        final client = HttpClient()..connectionTimeout = _timeout;
        IOSink? out;
        try {
          final request = await client.getUrl(url).timeout(_timeout);
          final response = await request.close().timeout(_timeout);
          if (response.statusCode != HttpStatus.ok) {
            await response.drain<void>();
            throw UpdateException(
                'Download fehlgeschlagen (Fehler ${response.statusCode})');
          }
          out = part.openWrite();
          final hash = Sha256().newHashSink();
          var received = 0;
          var shown = -1;
          await for (final chunk in response.timeout(_stallTimeout)) {
            received += chunk.length;
            if (received > package.size) break;
            hash.add(chunk);
            out.add(chunk);
            // Nicht schneller schreiben lassen, als die Platte mitkommt.
            await out.flush();
            final percent = received * 100 ~/ package.size;
            if (percent != shown) {
              shown = percent;
              onProgress(received / package.size);
            }
          }
          await out.close();
          out = null;
          hash.close();
          final sha256 = _hex((await hash.hash()).bytes);
          if (received != package.size || sha256 != package.sha256) {
            throw UpdateException(
                'Die heruntergeladene Datei ist beschädigt – bitte erneut versuchen');
          }
          await part.rename(target.path);
          return target.path;
        } catch (_) {
          await out?.close().catchError((Object _) {});
          if (await part.exists()) await part.delete();
          rethrow;
        } finally {
          client.close(force: true);
        }
      });

  /// Installiert die mit [download] geladene Datei. Unter Linux endet die
  /// App danach über [quit] und startet neu.
  Future<void> install(String path, {Future<void> Function()? quit}) =>
      _guard(() async {
        switch (kind) {
          case UpdateKind.apk:
            await _native.invokeMethod<void>('install', path);
          case UpdateKind.appimage:
            final target = Platform.environment['APPIMAGE']!;
            await _run('chmod', ['755', path]);
            // Ersetzt die Datei in einem Schritt; die laufende App behält
            // die alte geöffnet.
            await File(path).rename(target);
            await _restart(target, quit);
          case UpdateKind.deb:
            await _installDeb(path);
            await _restart(Platform.resolvedExecutable, quit);
          case UpdateKind.tar:
            await installTar(path, File(Platform.resolvedExecutable).parent);
            await _restart(Platform.resolvedExecutable, quit);
          case UpdateKind.exe:
            await _runAfterExit(
              windowsInstallerScript(
                pid: pid,
                setup: path,
                executable: Platform.resolvedExecutable,
              ),
              quit,
            );
          case UpdateKind.zip:
            final stage = await _unpackZip(path);
            await _runAfterExit(
              windowsCopyScript(
                pid: pid,
                stage: stage,
                bundle: File(Platform.resolvedExecutable).parent.path,
                executable: Platform.resolvedExecutable,
              ),
              quit,
            );
          case UpdateKind.dmg || null:
            throw UpdateException(
                'Diese Installation kann sich nicht selbst aktualisieren');
        }
      });

  /// Räumt Reste früherer Updates weg (beim Programmstart).
  Future<void> cleanup() async {
    try {
      switch (kind) {
        case UpdateKind.apk:
          final dir = Directory(await _androidDir());
          if (await dir.exists()) await dir.delete(recursive: true);
        case UpdateKind.appimage:
          final base = '${Platform.environment['APPIMAGE']}.update';
          for (final f in [File(base), File('$base.part')]) {
            if (await f.exists()) await f.delete();
          }
        case UpdateKind.deb || UpdateKind.exe || UpdateKind.zip:
          await _deleteMatching(Directory.systemTemp, _tempPrefix);
        case UpdateKind.tar:
          await _deleteMatching(Directory.systemTemp, _tempPrefix);
          final bundle = File(Platform.resolvedExecutable).parent;
          final name = bundle.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
          await _deleteMatching(bundle.parent, '$name$_oldSuffix');
          await _deleteMatching(bundle.parent, _stagePrefix);
        case UpdateKind.dmg || null:
      }
    } on Exception catch (e) {
      debugPrint('Update: Aufräumen fehlgeschlagen: $e');
    }
  }

  // --- Ablage ----------------------------------------------------------------

  static const _tempPrefix = 'antatime-update-';
  static const _stagePrefix = '.antatime-update-';
  static const _oldSuffix = '.alt-';

  Directory? _temp;

  /// Verzeichnis der Downloads für .deb und tar.gz, sobald es angelegt ist.
  @visibleForTesting
  String? get tempPath => _temp?.path;

  Future<String> _androidDir() async =>
      (await _native.invokeMethod<String>('dir'))!;

  Future<String> _target(UpdatePackage package) async {
    switch (kind) {
      case UpdateKind.apk:
        return '${await _androidDir()}/${package.file}';
      case UpdateKind.appimage:
        // Neben der AppImage-Datei, damit das Ersetzen ein Umbenennen im
        // selben Dateisystem bleibt.
        return '${Platform.environment['APPIMAGE']}.update';
      case UpdateKind.deb || UpdateKind.tar || UpdateKind.exe || UpdateKind.zip:
        // Nur für diesen Benutzer zugänglich (Linux: mkdtemp, Windows:
        // %TEMP% des Benutzers), niemand sonst kann die Datei vor der
        // Installation austauschen.
        final dir = _temp ??= await Directory.systemTemp.createTemp(_tempPrefix);
        return '${dir.path}${Platform.pathSeparator}${package.file}';
      case UpdateKind.dmg || null:
        throw UpdateException(
            'Diese Installation kann sich nicht selbst aktualisieren');
    }
  }

  static Future<void> _deleteMatching(Directory dir, String prefix) async {
    await for (final entry in dir.list(followLinks: false)) {
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (!name.startsWith(prefix)) continue;
      try {
        await entry.delete(recursive: true);
      } on FileSystemException {
        // z. B. das Verzeichnis eines anderen Benutzers in /tmp
      }
    }
  }

  // --- Linux -----------------------------------------------------------------

  Future<void> _installDeb(String path) async {
    // apt löst auch neue Abhängigkeiten auf; ohne apt bleibt dpkg.
    final command = File('/usr/bin/apt-get').existsSync()
        ? ['env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', path]
        : ['dpkg', '-i', path];
    final ProcessResult result;
    try {
      result = await Process.run('pkexec', command);
    } on ProcessException {
      throw UpdateException('Für die Installation fehlt „pkexec“. Das Paket '
          'liegt unter $path und lässt sich mit „sudo apt install $path“ '
          'installieren.');
    }
    // 126: Dialog geschlossen, 127: Anmeldung fehlgeschlagen.
    if (result.exitCode == 126 || result.exitCode == 127) {
      throw UpdateException('Installation abgebrochen');
    }
    if (result.exitCode != 0) {
      throw UpdateException(
          'Installation fehlgeschlagen: ${_lastLine(result.stderr)}');
    }
  }

  /// Ersetzt das Programmverzeichnis [bundle] durch den Inhalt des Archivs
  /// [path]. Schlägt etwas fehl, bleibt das alte Verzeichnis bestehen.
  @visibleForTesting
  static Future<void> installTar(String path, Directory bundle) async {
    final stage = Directory('${bundle.parent.path}/$_stagePrefix$pid');
    final old = Directory('${bundle.path}$_oldSuffix$pid');
    try {
      if (await stage.exists()) await stage.delete(recursive: true);
      await stage.create();
    } on FileSystemException {
      throw UpdateException('Keine Schreibrechte in ${bundle.parent.path} – '
          'bitte die neue Version von Hand entpacken');
    }
    try {
      await _run('tar', ['-xzf', path, '-C', stage.path]);
      // Aufbau des Archivs: antatime/antatime (scripts/build_linux.sh)
      final fresh = Directory('${stage.path}/antatime');
      if (!await File('${fresh.path}/antatime').exists()) {
        throw UpdateException('Das Update-Paket hat einen unerwarteten Aufbau');
      }
      await bundle.rename(old.path);
      try {
        await fresh.rename(bundle.path);
      } catch (_) {
        await old.rename(bundle.path);
        rethrow;
      }
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
    // Die laufende App hat ihre Dateien bereits geladen.
    try {
      await old.delete(recursive: true);
    } on FileSystemException {
      // Räumt [cleanup] beim nächsten Start weg.
    }
  }

  /// Startet [executable], sobald dieser Prozess beendet ist – vorher
  /// würde der neue Start nur das Fenster der laufenden App nach vorn holen
  /// (eine Instanz, siehe linux/runner/my_application.cc).
  Future<void> _restart(String executable, Future<void> Function()? quit) async {
    // Die Umgebung des alten AppImage soll das neue nicht verwirren.
    final env = Map.of(Platform.environment)
      ..removeWhere((k, _) => const {'APPIMAGE', 'APPDIR', 'ARGV0', 'OWD'}.contains(k));
    await Process.start(
      '/bin/sh',
      [
        '-c',
        r'i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 150 ]; do '
            r'sleep 0.2; i=$((i+1)); done; exec "$0"',
        executable,
        '$pid',
      ],
      environment: env,
      includeParentEnvironment: false,
      mode: ProcessStartMode.detached,
    );
    await _quit(quit);
  }

  static Future<void> _quit(Future<void> Function()? quit) async {
    // Falls das geordnete Beenden hängt.
    Timer(const Duration(seconds: 5), () => exit(0));
    if (quit != null) {
      await quit();
    } else {
      exit(0);
    }
  }

  // --- Windows ---------------------------------------------------------------

  /// Zeichenkette für PowerShell (einfache Anführungszeichen, wörtlich).
  static String _ps(String s) => "'${s.replaceAll("'", "''")}'";

  /// Wartet auf das Ende der App, führt das Setup still aus (Inno Setup:
  /// gleiche Art wie die vorhandene Installation, bei „für alle Benutzer“
  /// mit Rückfrage des Systems) und startet die App wieder – auch wenn das
  /// Setup abgebrochen wurde, dann eben die alte.
  @visibleForTesting
  static String windowsInstallerScript({
    required int pid,
    required String setup,
    required String executable,
  }) =>
      'Wait-Process -Id $pid -Timeout 30 -ErrorAction SilentlyContinue; '
      'Start-Process -FilePath ${_ps(setup)} -ArgumentList '
      "'/SILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait; "
      'Start-Process -FilePath ${_ps(executable)}';

  /// Wartet auf das Ende der App (vorher sind ihre Dateien gesperrt),
  /// kopiert die entpackte Version darüber und startet sie.
  @visibleForTesting
  static String windowsCopyScript({
    required int pid,
    required String stage,
    required String bundle,
    required String executable,
  }) =>
      'Wait-Process -Id $pid -Timeout 30 -ErrorAction SilentlyContinue; '
      'Copy-Item -Path ${_ps('$stage\\AnTaTime\\*')} '
      '-Destination ${_ps(bundle)} -Recurse -Force; '
      'Start-Process -FilePath ${_ps(executable)}; '
      'Remove-Item -LiteralPath ${_ps(stage)} -Recurse -Force';

  /// Entpackt das Zip neben den Download und liefert das Verzeichnis, in
  /// dem danach `AnTaTime\antatime.exe` liegt (scripts/build_windows.sh).
  Future<String> _unpackZip(String path) async {
    final bundle = File(Platform.resolvedExecutable).parent;
    try {
      final probe = File('${bundle.path}\\.antatime-update-test');
      await probe.writeAsString('');
      await probe.delete();
    } on FileSystemException {
      throw UpdateException('Keine Schreibrechte in ${bundle.path} – '
          'bitte die neue Version von Hand entpacken');
    }
    final stage = Directory('${File(path).parent.path}\\entpackt');
    if (await stage.exists()) await stage.delete(recursive: true);
    await _run('powershell.exe', [
      ..._psArgs,
      'Expand-Archive -LiteralPath ${_ps(path)} '
          '-DestinationPath ${_ps(stage.path)} -Force',
    ]);
    if (!await File('${stage.path}\\AnTaTime\\antatime.exe').exists()) {
      throw UpdateException('Das Update-Paket hat einen unerwarteten Aufbau');
    }
    return stage.path;
  }

  static const _psArgs = [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
  ];

  /// Startet [script] losgelöst in PowerShell und beendet die App.
  Future<void> _runAfterExit(
      String script, Future<void> Function()? quit) async {
    await Process.start(
      'powershell.exe',
      ['-WindowStyle', 'Hidden', ..._psArgs, script],
      mode: ProcessStartMode.detached,
    );
    await _quit(quit);
  }

  static Future<void> _run(String executable, List<String> args) async {
    final result = await Process.run(executable, args);
    if (result.exitCode != 0) {
      throw UpdateException(
          '$executable fehlgeschlagen: ${_lastLine(result.stderr)}');
    }
  }

  static String _lastLine(Object? output) {
    final lines = '$output'.trim().split('\n');
    return lines.isEmpty || lines.last.isEmpty ? 'unbekannter Fehler' : lines.last;
  }

  // --- Helfer ----------------------------------------------------------------

  static Future<String> _sha256Of(Stream<List<int>> data) async {
    final hash = Sha256().newHashSink();
    await for (final chunk in data) {
      hash.add(chunk);
    }
    hash.close();
    return _hex((await hash.hash()).bytes);
  }

  static String _hex(List<int> bytes) =>
      [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

  /// Übersetzt Netz- und Dateifehler in Meldungen für die Anzeige.
  static Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      throw UpdateException('Der Server antwortet nicht');
    } on SocketException {
      throw UpdateException('Keine Verbindung zum Server');
    } on TlsException {
      throw UpdateException('Keine sichere Verbindung zum Server');
    } on HttpException {
      throw UpdateException('Die Verbindung wurde unterbrochen');
    } on FileSystemException catch (e) {
      throw UpdateException('Datei nicht schreibbar: ${e.path ?? e.message}');
    } on ProcessException catch (e) {
      throw UpdateException('${e.executable} lässt sich nicht starten');
    } on PlatformException catch (e) {
      throw UpdateException(e.message ?? 'Installation fehlgeschlagen');
    }
  }
}
