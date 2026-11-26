import 'package:antatime/update/update_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

final _base = Uri.parse('https://antatime.de/updates/');

Map<String, Object?> _entry({
  String kind = 'apk',
  String? arch,
  String version = '1.6.0',
  String? file,
  Object? size = 1000,
  String? sha256,
}) =>
    {
      'platform': kind == 'apk' ? 'android' : 'linux',
      'kind': kind,
      'arch': arch,
      'version': version,
      'file': file ?? 'antatime-$version.$kind',
      'size': size,
      'sha256': sha256 ?? 'ab' * 32,
    };

List<UpdatePackage> _server(List<Object?> entries) =>
    packagesFromServer({'packages': entries}, _base);

/// Anhang eines GitHub-Releases, wie die API ihn liefert (gekürzt).
Map<String, Object?> _asset(
  String name, {
  Object? size = 1000,
  Object? digest = 'sha256:'
      'f875cff4a4de6609ed00c00cb2d044cad00e7f609a870dffe7ff222231d974f2',
  String? url,
}) =>
    {
      'name': name,
      'size': size,
      'digest': digest,
      'content_type': 'application/octet-stream',
      'browser_download_url': url ??
          'https://github.com/lotterfriends/antatime/releases/download/v1.6.0/$name',
    };

void main() {
  test('Versionen werden zahlenweise verglichen', () {
    expect(compareVersions('1.10.0', '1.9.3'), 1);
    expect(compareVersions('1.5.1', '1.5.1'), 0);
    expect(compareVersions('1.5', '1.5.1'), -1);
    expect(compareVersions('2.0', '2.0.0'), 0);
    // Build-Nummer aus der pubspec.yaml zählt nicht.
    expect(compareVersions('1.5.1+8', '1.5.1'), 0);
  });

  test('Pakete werden am Dateinamen erkannt', () {
    expect(parseUpdateFile('antatime-1.5.1.apk'),
        (kind: UpdateKind.apk, arch: null, version: '1.5.1'));
    expect(parseUpdateFile('AnTaTime-1.5.1-x86_64.AppImage'),
        (kind: UpdateKind.appimage, arch: 'x64', version: '1.5.1'));
    expect(parseUpdateFile('AnTaTime-1.5.1-aarch64.AppImage')?.arch, 'arm64');
    expect(parseUpdateFile('antatime_1.5.1_amd64.deb'),
        (kind: UpdateKind.deb, arch: 'x64', version: '1.5.1'));
    expect(parseUpdateFile('antatime-1.10.0-linux-arm64.tar.gz'),
        (kind: UpdateKind.tar, arch: 'arm64', version: '1.10.0'));
    expect(parseUpdateFile('AnTaTime-1.5.1-windows-x64-setup.exe'),
        (kind: UpdateKind.exe, arch: 'x64', version: '1.5.1'));
    expect(parseUpdateFile('antatime-1.5.1-windows-x64.zip')?.kind,
        UpdateKind.zip);
    expect(parseUpdateFile('AnTaTime-1.5.1-macos.dmg'),
        (kind: UpdateKind.dmg, arch: null, version: '1.5.1'));
    for (final other in [
      'AnTaTime-1.5.1-macos.zip',
      'antatime-web-1.5.1.zip',
      'antatime-1.5.1-unsigned.ipa',
      'antatime-1.5.1.apk.sha256',
      'x-antatime-1.5.1.apk',
    ]) {
      expect(parseUpdateFile(other), isNull, reason: other);
    }
  });

  group('GitHub-Release', () {
    test('liefert die bekannten Anhänge mit Größe, Prüfsumme und Adresse', () {
      final packages = packagesFromGitHub({
        'tag_name': 'v1.6.0',
        'assets': [
          _asset('antatime-1.6.0.apk', size: 59143036),
          _asset('AnTaTime-1.6.0-x86_64.AppImage'),
          _asset('antatime_1.6.0_amd64.deb'),
          _asset('antatime-1.6.0-linux-x64.tar.gz'),
          _asset('AnTaTime-1.6.0-windows-x64-setup.exe'),
          _asset('antatime-1.6.0-windows-x64.zip'),
          _asset('AnTaTime-1.6.0-macos.dmg'),
          _asset('AnTaTime-1.6.0-macos.zip'),
          _asset('antatime-web-1.6.0.zip'),
          _asset('antatime-1.6.0-unsigned.ipa'),
        ],
      });
      expect(packages.map((p) => p.kind), UpdateKind.values);
      final apk = packages.first;
      expect(apk.version, '1.6.0');
      expect(apk.size, 59143036);
      expect(apk.sha256,
          'f875cff4a4de6609ed00c00cb2d044cad00e7f609a870dffe7ff222231d974f2');
      expect(apk.url.toString(),
          'https://github.com/lotterfriends/antatime/releases/download/v1.6.0/antatime-1.6.0.apk');

      expect(
          pickUpdate(packages,
                  kind: UpdateKind.deb, arch: 'x64', current: '1.5.1')
              ?.file,
          'antatime_1.6.0_amd64.deb');
      expect(
          pickUpdate(packages,
              kind: UpdateKind.deb, arch: 'arm64', current: '1.5.1'),
          isNull);
      expect(
          pickUpdate(packages,
              kind: UpdateKind.apk, arch: null, current: '1.6.0'),
          isNull);
    });

    test('verwirft Anhänge ohne Prüfsumme oder von anderswo', () {
      for (final bad in [
        _asset('antatime-1.6.0.apk', digest: null),
        _asset('antatime-1.6.0.apk', digest: 'sha512:${'ab' * 64}'),
        _asset('antatime-1.6.0.apk', digest: 'sha256:kurz'),
        _asset('antatime-1.6.0.apk', size: 0),
        _asset('antatime-1.6.0.apk', url: 'https://example.org/antatime-1.6.0.apk'),
        _asset('antatime-1.6.0.apk',
            url: 'http://github.com/lotterfriends/antatime/releases/download/v1.6.0/antatime-1.6.0.apk'),
        'kein Objekt',
      ]) {
        expect(packagesFromGitHub({'assets': [bad]}), isEmpty, reason: '$bad');
      }
      for (final release in [null, 'x', <Object?>[], {'message': 'Not Found'}]) {
        expect(packagesFromGitHub(release), isEmpty);
      }
    });

    test('Adresse des neuesten Releases', () {
      expect(gitHubLatestReleaseUri('lotterfriends/antatime').toString(),
          'https://api.github.com/repos/lotterfriends/antatime/releases/latest');
      expect(gitHubLatestReleaseUri(''), isNull);
      expect(gitHubLatestReleaseUri('nur-name'), isNull);
      expect(gitHubLatestReleaseUri('a/b/../../c'), isNull);
      expect(gitHubLatestReleaseUri('a/b?x=1'), isNull);
    });
  });

  group('Eigener Server', () {
    test('nimmt das neuere Paket der eigenen Art und Architektur', () {
      final packages = _server([
        _entry(),
        _entry(kind: 'deb', arch: 'x64', version: '1.7.0'),
        _entry(kind: 'deb', arch: 'arm64', version: '1.8.0'),
        _entry(kind: 'appimage', arch: 'x64', version: '1.9.0'),
      ]);
      final apk =
          pickUpdate(packages, kind: UpdateKind.apk, arch: null, current: '1.5.1');
      expect(apk?.version, '1.6.0');
      expect(apk?.url.toString(), 'https://antatime.de/updates/antatime-1.6.0.apk');
      expect(
          pickUpdate(packages,
                  kind: UpdateKind.deb, arch: 'x64', current: '1.5.1')
              ?.version,
          '1.7.0');
      expect(
          pickUpdate(packages,
              kind: UpdateKind.tar, arch: 'x64', current: '1.5.1'),
          isNull);
    });

    test('nichts bei gleicher oder älterer Version', () {
      final packages = _server([_entry(version: '1.5.1')]);
      expect(
          pickUpdate(packages,
              kind: UpdateKind.apk, arch: null, current: '1.5.1'),
          isNull);
      expect(
          pickUpdate(packages,
              kind: UpdateKind.apk, arch: null, current: '1.6.0'),
          isNull);
    });

    test('verwirft unbrauchbare Einträge', () {
      for (final bad in [
        _entry(file: '../../etc/passwd'),
        _entry(file: 'https://example.org/boese.apk'),
        _entry(file: 'unter/ordner.apk'),
        _entry(sha256: 'kurz'),
        _entry(sha256: 'AB' * 32),
        _entry(size: 0),
        _entry(size: '1000'),
        _entry(version: 'neueste'),
        _entry(kind: 'msi'),
        'kein Objekt',
      ]) {
        expect(_server([bad]), isEmpty, reason: '$bad');
      }
      for (final manifest in [null, 'x', <Object?>[], {'packages': 'x'}]) {
        expect(packagesFromServer(manifest, _base), isEmpty);
      }
    });

    test('Adresse des Update-Verzeichnisses', () {
      expect(updateBaseUri('antatime.de').toString(),
          'https://antatime.de/updates/');
      expect(updateBaseUri(' https://example.org/antatime/ ').toString(),
          'https://example.org/antatime/updates/');
      expect(updateBaseUri('https://example.org/zeit/sync').toString(),
          'https://example.org/zeit/updates/');
      expect(updateBaseUri('http://localhost:8080').toString(),
          'http://localhost:8080/updates/');
      // Unverschlüsselt nur vom eigenen Rechner.
      expect(updateBaseUri('http://example.org'), isNull);
      expect(updateBaseUri('ftp://example.org'), isNull);
      expect(updateBaseUri(''), isNull);
    });
  });

  test('Paket übersteht Speichern und Laden', () {
    final p = _server([_entry(kind: 'deb', arch: 'x64')]).single;
    final again = UpdatePackage.fromJson(p.toJson())!;
    expect(again.kind, UpdateKind.deb);
    expect(again.arch, 'x64');
    expect(again.file, p.file);
    expect(again.size, 1000);
    expect(again.sha256, p.sha256);
    expect(again.url, p.url);
    // Gemerkte Pakete mit unsicherer Adresse zählen nicht.
    expect(
        UpdatePackage.fromJson({...p.toJson(), 'url': 'http://example.org/x.deb'}),
        isNull);
    expect(UpdatePackage.fromJson({...p.toJson()}..remove('url')), isNull);
  });
}
