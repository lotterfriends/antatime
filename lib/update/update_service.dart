import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'update_manifest.dart';
import 'update_platform.dart';

enum UpdateStatus { idle, checking, downloading, installing }

/// Updates ohne App-Store (Android-APK, Linux, Windows, macOS): sucht nach
/// einer neueren Version, lädt sie herunter und installiert sie (macOS:
/// lässt sie nur vom Browser herunterladen).
///
/// Quelle sind die Releases des Projekts auf GitHub ([defaultRepo], die
/// Pakete hängt GitHub Actions an jedes Release). Mit
/// `--dart-define=UPDATE_URL=…` fragt die App stattdessen einen
/// AnTaTime-Server (`UPDATES_DIR`). Beides steht beim Build fest – ein in der
/// App eingetragener Sync-Server wird bewusst nicht gefragt: Dem muss man
/// dank Verschlüsselung nicht trauen, ein Update ist aber ausführbarer Code.
class UpdateService extends ChangeNotifier {
  UpdateService({
    UpdatePlatform? platform,
    String serverUrl = _updateUrl,
    String repo = defaultRepo,
    Future<String> Function()? installedVersion,
    DateTime Function()? now,
  })  : _platform = platform ?? UpdatePlatform.instance,
        _base = updateBaseUri(serverUrl),
        _listUrl = serverUrl.trim().isNotEmpty
            ? updateBaseUri(serverUrl)?.resolve('latest.json')
            : gitHubLatestReleaseUri(repo),
        _installedVersion = installedVersion ??
            (() async => (await PackageInfo.fromPlatform()).version),
        _now = now ?? DateTime.now;

  static final instance = UpdateService();

  /// Eigener Server statt GitHub, z. B. `--dart-define=UPDATE_URL=antatime.de`.
  static const _updateUrl = String.fromEnvironment('UPDATE_URL');

  /// GitHub-Repository, dessen Releases die Updates sind; für einen Fork
  /// `--dart-define=UPDATE_REPO=besitzer/name`.
  static const defaultRepo = String.fromEnvironment('UPDATE_REPO',
      defaultValue: 'lotterfriends/antatime');

  /// Frühestens nach dieser Zeit wird von selbst erneut gesucht. Die App
  /// läuft oft tagelang (Infobereich) oder startet häufig im Hintergrund
  /// (Android-Sync) – beides soll nicht ständig nachfragen (GitHub erlaubt
  /// ohne Anmeldung 60 Abfragen pro Stunde und Anschluss).
  static const autoInterval = Duration(hours: 12);
  static const _startDelay = Duration(seconds: 10);

  static const _kAuto = 'updateAuto';
  static const _kLastCheck = 'updateLastCheck';
  static const _kAvailable = 'updateAvailable';

  final UpdatePlatform _platform;
  /// Verzeichnis `/updates/` eines eigenen Servers; `null` = GitHub.
  final Uri? _base;

  /// Adresse der Paketliste bzw. des neuesten Releases.
  final Uri? _listUrl;
  final Future<String> Function() _installedVersion;
  final DateTime Function() _now;
  final _prefs = SharedPreferencesAsync();

  /// Beendet die App geordnet (Desktop: Infobereich abbauen), siehe main.dart.
  Future<void> Function()? quit;

  bool get supported => _listUrl != null && _platform.kind != null;

  UpdateKind? get kind => _platform.kind;
  /// Wo gesucht wird, für die Anzeige.
  String get serverHost => _base?.host ?? 'GitHub';

  UpdateStatus status = UpdateStatus.idle;
  String? currentVersion;

  /// Neuere Version (auch aus der letzten Suche gemerkt).
  UpdatePackage? available;
  DateTime? lastCheck;
  bool auto = true;

  /// Fortschritt des Downloads (0–1).
  double progress = 0;
  String? error;

  bool get busy => status != UpdateStatus.idle;

  Timer? _timer;
  bool _started = false;

  /// Beim Programmstart: Einstellungen laden, Reste wegräumen und – falls
  /// eingeschaltet – von Zeit zu Zeit nach Updates suchen.
  Future<void> start() async {
    if (!supported || _started) return;
    _started = true;
    try {
      currentVersion = await _installedVersion();
      auto = await _prefs.getBool(_kAuto) ?? true;
      final at = await _prefs.getInt(_kLastCheck);
      lastCheck = at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
      final cached = await _prefs.getString(_kAvailable);
      if (cached != null) {
        available = pickUpdate(
          [?UpdatePackage.fromJson(jsonDecode(cached))],
          kind: _platform.kind!,
          arch: _platform.arch,
          current: currentVersion!,
        );
        // Inzwischen installiert (oder unlesbar): vergessen.
        if (available == null) await _prefs.remove(_kAvailable);
      }
    } on Exception catch (e) {
      debugPrint('Update: $e');
    }
    // Die geladene Datei der eben installierten Version wird nicht mehr
    // gebraucht.
    if (available == null) await _platform.cleanup();
    notifyListeners();
    _timer = Timer(_startDelay, _autoCheck);
  }

  void _autoCheck() {
    _timer = Timer(const Duration(hours: 1), _autoCheck);
    final last = lastCheck;
    if (!auto || busy) return;
    if (last != null && _now().difference(last).abs() < autoInterval) return;
    unawaited(check());
  }

  Future<void> setAuto(bool value) async {
    auto = value;
    notifyListeners();
    await _prefs.setBool(_kAuto, value);
  }

  /// Sucht nach einer neueren Version. Liefert `true`, wenn die
  /// Abfrage gelang (ob es ein Update gibt, steht in [available]).
  Future<bool> check() async {
    final listUrl = _listUrl;
    final base = _base;
    final kind = _platform.kind;
    if (listUrl == null || kind == null || busy) return false;
    status = UpdateStatus.checking;
    error = null;
    notifyListeners();
    try {
      final current = currentVersion ??= await _installedVersion();
      final list = await _platform.fetchManifest(listUrl);
      available = pickUpdate(
        base != null ? packagesFromServer(list, base) : packagesFromGitHub(list),
        kind: kind,
        arch: _platform.arch,
        current: current,
      );
      lastCheck = _now();
      await _prefs.setInt(_kLastCheck, lastCheck!.millisecondsSinceEpoch);
      final found = available;
      if (found == null) {
        await _prefs.remove(_kAvailable);
      } else {
        await _prefs.setString(_kAvailable, jsonEncode(found.toJson()));
      }
      return true;
    } on UpdateException catch (e) {
      error = e.message;
      return false;
    } on Exception catch (e) {
      debugPrint('Update: $e');
      error = 'Die Suche nach Updates ist fehlgeschlagen';
      return false;
    } finally {
      status = UpdateStatus.idle;
      notifyListeners();
    }
  }

  /// Lädt die gefundene Version und installiert sie. Unter Android übergibt
  /// das an den Paketinstaller des Systems, unter Linux und Windows startet
  /// die App neu, unter macOS lädt der Browser das Disk-Image.
  Future<void> install() async {
    final package = available;
    if (package == null || busy) return;
    status = UpdateStatus.downloading;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      if (_platform.opensInBrowser) {
        await _platform.openInBrowser(package.url);
        return;
      }
      final path = await _platform.download(
        package,
        package.url,
        onProgress: (p) {
          progress = p;
          notifyListeners();
        },
      );
      status = UpdateStatus.installing;
      notifyListeners();
      await _platform.install(path, quit: quit);
    } on UpdateException catch (e) {
      error = e.message;
    } on Exception catch (e) {
      debugPrint('Update: $e');
      error = 'Das Update konnte nicht installiert werden';
    } finally {
      status = UpdateStatus.idle;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
