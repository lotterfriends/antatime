import 'dart:convert';
import 'dart:io';

import 'package:antatime/update/update_manifest.dart';
import 'package:antatime/update/update_platform_io.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _sha256(List<int> bytes) async => [
      for (final b in (await Sha256().hash(bytes)).bytes)
        b.toRadixString(16).padLeft(2, '0'),
    ].join();

void main() {
  test('Art der Linux-Installation', () {
    UpdateKind? kind(String exe, {String? appImage, bool release = true}) =>
        UpdatePlatform.linuxKind(
          env: {'APPIMAGE': ?appImage},
          executable: exe,
          release: release,
        );

    expect(kind('/tmp/.mount_AnTaTiXyz/antatime', appImage: '/home/a/AnTaTime.AppImage'),
        UpdateKind.appimage);
    expect(kind('/opt/antatime/antatime'), UpdateKind.deb);
    expect(kind('/home/a/apps/antatime/antatime'), UpdateKind.tar);
    expect(kind('/home/a/antatime-app/build/linux/x64/release/bundle/antatime'),
        isNull);
    expect(kind('/opt/antatime/antatime', release: false), isNull);
  });

  test('Art der Windows-Installation', () {
    UpdateKind? kind(String exe, {bool uninstaller = false, bool release = true}) =>
        UpdatePlatform.windowsKind(
            executable: exe, release: release, hasUninstaller: uninstaller);

    expect(kind(r'C:\Users\a\AppData\Local\Programs\AnTaTime\antatime.exe', uninstaller: true),
        UpdateKind.exe);
    expect(kind(r'D:\Tools\AnTaTime\antatime.exe'), UpdateKind.zip);
    expect(kind(r'C:\src\antatime-app\build\windows\x64\runner\Release\antatime.exe'),
        isNull);
    expect(kind(r'D:\Tools\AnTaTime\antatime.exe', release: false), isNull);
  });

  test('Windows-Helfer: Pfade wörtlich, auch mit Apostroph und Leerzeichen', () {
    expect(
        UpdatePlatform.windowsInstallerScript(
          pid: 4711,
          setup: r"C:\Users\O'Neil\Temp\AnTaTime-1.6.0-windows-x64-setup.exe",
          executable: r'C:\Program Files\AnTaTime\antatime.exe',
        ),
        'Wait-Process -Id 4711 -Timeout 30 -ErrorAction SilentlyContinue; '
        r"Start-Process -FilePath 'C:\Users\O''Neil\Temp\AnTaTime-1.6.0-windows-x64-setup.exe' "
        "-ArgumentList '/SILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait; "
        r"Start-Process -FilePath 'C:\Program Files\AnTaTime\antatime.exe'");
    final copy = UpdatePlatform.windowsCopyScript(
      pid: 1,
      stage: r'C:\Temp\antatime-update-x\entpackt',
      bundle: r'D:\Tools\AnTaTime',
      executable: r'D:\Tools\AnTaTime\antatime.exe',
    );
    expect(copy, contains(r"Copy-Item -Path 'C:\Temp\antatime-update-x\entpackt\AnTaTime\*' "
        r"-Destination 'D:\Tools\AnTaTime' -Recurse -Force"));
    expect(copy, endsWith(r"Start-Process -FilePath 'D:\Tools\AnTaTime\antatime.exe'; "
        r"Remove-Item -LiteralPath 'C:\Temp\antatime-update-x\entpackt' -Recurse -Force"));
  });

  group('Download', () {
    late HttpServer server;
    late Uri base;
    late List<int> body;
    final platform = UpdatePlatform.forTesting(UpdateKind.deb);
    final files = <String>[];

    setUp(() async {
      body = List.generate(300000, (i) => i % 251);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/updates/latest.json') {
          request.response.write(jsonEncode({'packages': <Object?>[]}));
        } else if (request.uri.path.endsWith('.deb')) {
          request.response.add(body);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      base = Uri.parse('http://127.0.0.1:${server.port}/updates/');
    });

    tearDown(() async {
      await server.close(force: true);
      for (final f in files) {
        if (File(f).existsSync()) File(f).deleteSync();
      }
      files.clear();
    });

    tearDownAll(() {
      final temp = platform.tempPath;
      if (temp != null && Directory(temp).existsSync()) {
        Directory(temp).deleteSync(recursive: true);
      }
    });

    Future<UpdatePackage> package({String? sha256, int? size, String? file}) async =>
        UpdatePackage(
          kind: UpdateKind.deb,
          arch: 'x64',
          version: '1.6.0',
          file: file ?? 'antatime_1.6.0_amd64.deb',
          size: size ?? body.length,
          sha256: sha256 ?? await _sha256(body),
          url: base.resolve(file ?? 'antatime_1.6.0_amd64.deb'),
        );

    test('liest die Paketliste', () async {
      expect(await platform.fetchManifest(base.resolve('latest.json')),
          {'packages': <Object?>[]});
      await expectLater(platform.fetchManifest(base.resolve('fehlt.json')),
          throwsA(isA<UpdateException>()));
    });

    test('lädt, prüft und meldet den Fortschritt', () async {
      final p = await package();
      final progress = <double>[];
      final path = await platform.download(p, base.resolve(p.file),
          onProgress: progress.add);
      files.add(path);
      expect(File(path).readAsBytesSync(), body);
      expect(progress.last, 1.0);
      expect(File('$path.part').existsSync(), isFalse);

      // Eine fertige Datei wird nicht noch einmal geladen.
      await server.close(force: true);
      expect(
          await platform.download(p, base.resolve(p.file), onProgress: (_) {}),
          path);
    });

    test('verwirft Dateien mit falscher Prüfsumme oder Größe', () async {
      for (final p in [
        await package(sha256: 'ab' * 32, file: 'antatime_1.6.1_amd64.deb'),
        await package(size: body.length - 1, file: 'antatime_1.6.2_amd64.deb'),
        await package(size: body.length + 1, file: 'antatime_1.6.3_amd64.deb'),
      ]) {
        await expectLater(
            platform.download(p, base.resolve(p.file), onProgress: (_) {}),
            throwsA(isA<UpdateException>()));
      }
      // Keine halben Dateien zurücklassen.
      expect(Directory(platform.tempPath!).listSync(), isEmpty);
    });

    test('meldet einen nicht erreichbaren Server', () async {
      final p = await package();
      await server.close(force: true);
      await expectLater(
          platform.download(p, base.resolve('anderes.deb'), onProgress: (_) {}),
          throwsA(isA<UpdateException>()));
    });
  });

  group('tar.gz', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('antatime-tar-test-'));
    tearDown(() => root.deleteSync(recursive: true));

    /// Legt ein Programmverzeichnis `Zeit` mit Version 1 an und daneben ein
    /// Archiv mit dem Inhalt [files] (relativ zum Archiv).
    String setup(Map<String, String> files) {
      final bundle = Directory('${root.path}/install/Zeit')..createSync(recursive: true);
      File('${bundle.path}/antatime').writeAsStringSync('v1');
      File('${bundle.path}/alt.so').writeAsStringSync('v1');
      final src = Directory('${root.path}/src')..createSync();
      for (final e in files.entries) {
        File('${src.path}/${e.key}')
          ..createSync(recursive: true)
          ..writeAsStringSync(e.value);
      }
      final tar = '${root.path}/update.tar.gz';
      final r = Process.runSync(
          'tar', ['-C', src.path, '-czf', tar, ...src.listSync().map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return tar;
    }

    List<String> names(String dir) => [
          for (final e in Directory(dir).listSync())
            e.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
        ]..sort();

    test('ersetzt das Programmverzeichnis vollständig', () async {
      final tar = setup({
        'antatime/antatime': 'v2',
        'antatime/lib/neu.so': 'v2',
      });
      final bundle = Directory('${root.path}/install/Zeit');
      await UpdatePlatform.installTar(tar, bundle);
      expect(File('${bundle.path}/antatime').readAsStringSync(), 'v2');
      expect(File('${bundle.path}/lib/neu.so').readAsStringSync(), 'v2');
      expect(File('${bundle.path}/alt.so').existsSync(), isFalse);
      // Keine Reste daneben.
      expect(names('${root.path}/install'), ['Zeit']);
    });

    test('lässt bei unerwartetem Archiv alles, wie es war', () async {
      final tar = setup({'etwas/anderes': 'x'});
      final bundle = Directory('${root.path}/install/Zeit');
      await expectLater(UpdatePlatform.installTar(tar, bundle),
          throwsA(isA<UpdateException>()));
      expect(File('${bundle.path}/antatime').readAsStringSync(), 'v1');
      expect(names('${root.path}/install'), ['Zeit']);
    });
  });
}
