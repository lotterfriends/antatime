import 'package:antatime/update/update_manifest.dart';
import 'package:antatime/update/update_platform_io.dart';
import 'package:antatime/update/update_service.dart';
import 'package:antatime/widgets/update_tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Server und Installation ohne Netz und ohne Dateien.
class _FakePlatform implements UpdatePlatform {
  _FakePlatform({this.kind = UpdateKind.appimage});

  @override
  final UpdateKind? kind;
  @override
  String? get arch => 'x64';
  @override
  bool get opensInBrowser => kind == UpdateKind.dmg;
  final opened = <Uri>[];
  @override
  Future<void> openInBrowser(Uri url) async => opened.add(url);
  @override
  String? get tempPath => null;

  /// Version, die angeboten wird (`null` = nicht erreichbar).
  String? offered = '1.6.0';
  final requested = <Uri>[];
  final downloaded = <Uri>[];
  String? installed;
  bool quitCalled = false;
  int cleanups = 0;
  Object? installError;

  @override
  Future<Object?> fetchManifest(Uri url) async {
    requested.add(url);
    final version = offered;
    if (version == null) throw UpdateException('Keine Verbindung zum Server');
    final file = kind == UpdateKind.dmg
        ? 'AnTaTime-$version-macos.dmg'
        : 'AnTaTime-$version-x86_64.AppImage';
    if (url.host == 'api.github.com') {
      return {
        'tag_name': 'v$version',
        'assets': [
          {
            'name': file,
            'size': 11 * 1024 * 1024,
            'digest': 'sha256:${'cd' * 32}',
            'browser_download_url':
                'https://github.com/lotterfriends/antatime/releases/download/v$version/$file',
          },
        ],
      };
    }
    return {
      'packages': [
        {
          'kind': kind == UpdateKind.dmg ? 'dmg' : 'appimage',
          'arch': kind == UpdateKind.dmg ? null : 'x64',
          'version': version,
          'file': file,
          'size': 11 * 1024 * 1024,
          'sha256': 'cd' * 32,
        },
      ],
    };
  }

  @override
  Future<String> download(
    UpdatePackage package,
    Uri url, {
    required void Function(double progress) onProgress,
  }) async {
    downloaded.add(url);
    onProgress(0.5);
    onProgress(1);
    return '/tmp/${package.file}';
  }

  @override
  Future<void> install(String path, {Future<void> Function()? quit}) async {
    final e = installError;
    if (e != null) throw e;
    installed = path;
    await quit?.call();
  }

  @override
  Future<void> cleanup() async => cleanups++;
}

void main() {
  late _FakePlatform platform;
  var now = DateTime(2026, 11, 26, 9);

  /// Ohne [url] ist GitHub die Quelle.
  UpdateService service({String url = '', String version = '1.5.1'}) =>
      UpdateService(
        platform: platform,
        serverUrl: url,
        repo: 'lotterfriends/antatime',
        installedVersion: () async => version,
        now: () => now,
      );

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    platform = _FakePlatform();
    now = DateTime(2026, 11, 26, 9);
  });

  test('nur bei passender Installation und brauchbarer Quelle', () {
    expect(service().supported, isTrue);
    expect(service().serverHost, 'GitHub');
    expect(service(url: 'antatime.de').supported, isTrue);
    expect(service(url: 'antatime.de').serverHost, 'antatime.de');
    // Ein unbrauchbarer eigener Server fällt nicht still auf GitHub zurück.
    expect(service(url: 'http://example.org').supported, isFalse);
    expect(
        UpdateService(platform: platform, serverUrl: '', repo: 'kaputt')
            .supported,
        isFalse);
    platform = _FakePlatform(kind: null);
    expect(service().supported, isFalse);
  });

  test('findet ein Update, lädt und installiert es', () async {
    final s = service();
    var quit = false;
    s.quit = () async => quit = true;
    expect(await s.check(), isTrue);
    expect(platform.requested.single.toString(),
        'https://api.github.com/repos/lotterfriends/antatime/releases/latest');
    expect(s.available?.version, '1.6.0');
    expect(s.lastCheck, now);

    final seen = <UpdateStatus>[];
    s.addListener(() => seen.add(s.status));
    await s.install();
    expect(platform.downloaded.single.toString(),
        'https://github.com/lotterfriends/antatime/releases/download/v1.6.0/AnTaTime-1.6.0-x86_64.AppImage');
    expect(platform.installed, '/tmp/AnTaTime-1.6.0-x86_64.AppImage');
    expect(quit, isTrue);
    expect(seen, containsAllInOrder(
        [UpdateStatus.downloading, UpdateStatus.installing, UpdateStatus.idle]));
    expect(s.error, isNull);
  });

  test('macOS: der Browser lädt das Disk-Image', () async {
    platform = _FakePlatform(kind: UpdateKind.dmg);
    final s = service();
    await s.check();
    expect(s.available?.version, '1.6.0');
    await s.install();
    expect(platform.opened.single.toString(),
        'https://github.com/lotterfriends/antatime/releases/download/v1.6.0/AnTaTime-1.6.0-macos.dmg');
    expect(platform.downloaded, isEmpty);
    expect(platform.installed, isNull);
    expect(s.status, UpdateStatus.idle);
  });

  test('eigener Server statt GitHub', () async {
    final s = service(url: 'antatime.de');
    expect(await s.check(), isTrue);
    expect(platform.requested.single.toString(),
        'https://antatime.de/updates/latest.json');
    await s.install();
    expect(platform.downloaded.single.toString(),
        'https://antatime.de/updates/AnTaTime-1.6.0-x86_64.AppImage');
  });

  test('kein Update bei aktueller Version', () async {
    final s = service(version: '1.6.0');
    expect(await s.check(), isTrue);
    expect(s.available, isNull);
    await s.install();
    expect(platform.downloaded, isEmpty);
  });

  test('Fehler werden angezeigt und beim nächsten Versuch gelöscht', () async {
    final s = service();
    platform.offered = null;
    expect(await s.check(), isFalse);
    expect(s.error, 'Keine Verbindung zum Server');
    expect(s.lastCheck, isNull);

    platform.offered = '1.6.0';
    expect(await s.check(), isTrue);
    expect(s.error, isNull);

    platform.installError = UpdateException('Installation abgebrochen');
    await s.install();
    expect(s.error, 'Installation abgebrochen');
    expect(s.status, UpdateStatus.idle);
    // Das Update bleibt angeboten.
    expect(s.available?.version, '1.6.0');
  });

  test('merkt sich das gefundene Update über den Neustart', () async {
    final first = service();
    await first.check();
    await first.setAuto(false);

    final again = service();
    await again.start();
    again.dispose();
    expect(again.available?.version, '1.6.0');
    expect(again.lastCheck, now);
    expect(again.auto, isFalse);
    expect(again.currentVersion, '1.5.1');
    // Die geladene Datei wird noch gebraucht.
    expect(platform.cleanups, 0);

    // Nach der Installation ist es erledigt, Reste werden weggeräumt.
    final updated = service(version: '1.6.0');
    await updated.start();
    updated.dispose();
    expect(updated.available, isNull);
    expect(platform.cleanups, 1);
    expect(platform.requested, hasLength(1));
  });

  testWidgets('sucht von selbst, aber höchstens alle zwölf Stunden',
      (tester) async {
    // Ohne runAsync: Die Timer sollen an der Testuhr hängen.
    final s = service();
    await s.start();
    expect(platform.requested, isEmpty);
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    expect(platform.requested, hasLength(1));
    expect(s.available?.version, '1.6.0');

    now = now.add(const Duration(hours: 5));
    await tester.pump(const Duration(hours: 5));
    expect(platform.requested, hasLength(1));

    now = now.add(const Duration(hours: 8));
    await tester.pump(const Duration(hours: 1));
    await tester.pump();
    expect(platform.requested, hasLength(2));

    await s.setAuto(false);
    now = now.add(const Duration(days: 2));
    await tester.pump(const Duration(hours: 2));
    expect(platform.requested, hasLength(2));
    s.dispose();
  });

  testWidgets('Einstellungen: suchen, anbieten, installieren', (tester) async {
    await tester.runAsync(() => initializeDateFormatting('de_DE'));
    final s = service();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: UpdateTiles(service: s)),
    ));
    expect(find.text('Nach Updates suchen'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Nach Updates suchen'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('Version 1.6.0 ist verfügbar'), findsOneWidget);
    expect(find.textContaining('11,0 MB'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Installieren'));
    await tester.pumpAndSettle();
    expect(find.text('AnTaTime 1.6.0 installieren?'), findsOneWidget);
    expect(find.textContaining('startet AnTaTime neu'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Installieren').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(platform.installed, isNotNull);
  });

  testWidgets('Einstellungen: meldet, wenn alles aktuell ist', (tester) async {
    await tester.runAsync(() => initializeDateFormatting('de_DE'));
    final s = service(version: '1.6.0');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: UpdateTiles(service: s)),
    ));
    await tester.runAsync(() async {
      await tester.tap(find.text('Nach Updates suchen'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('AnTaTime ist auf dem neuesten Stand'), findsOneWidget);
    expect(find.textContaining('aktuell (geprüft am 26. Nov'), findsOneWidget);
  });
}
