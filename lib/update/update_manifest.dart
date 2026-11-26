/// Paketarten, über die sich die App selbst aktualisieren kann.
enum UpdateKind { apk, appimage, deb, tar, exe, zip, dmg }

/// Ein Paket, das als Update angeboten wird.
class UpdatePackage {
  const UpdatePackage({
    required this.kind,
    required this.arch,
    required this.version,
    required this.file,
    required this.size,
    required this.sha256,
    required this.url,
  });

  final UpdateKind kind;

  /// `x64`, `arm64` oder `null` = für alle Architekturen.
  final String? arch;
  final String version;
  final String file;
  final int size;

  /// Hexadezimal, klein geschrieben.
  final String sha256;

  /// Adresse des Downloads.
  final Uri url;

  static final _version = RegExp(r'^\d+(\.\d+){1,3}$');
  static final _file = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');

  /// Liest ein gemerktes Paket ([toJson]) oder – mit [base] – einen Eintrag
  /// aus der Liste eines AnTaTime-Servers, dessen Dateien neben der Liste
  /// liegen. `null`, wenn der Eintrag unbekannt oder unvollständig ist.
  static UpdatePackage? fromJson(Object? json, {Uri? base}) {
    if (json is! Map) return null;
    final kind = UpdateKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    final arch = json['arch'];
    final version = json['version'];
    final file = json['file'];
    final size = json['size'];
    final sha256 = json['sha256'];
    final rawUrl = json['url'];
    if (kind == null ||
        (arch != null && arch is! String) ||
        version is! String ||
        !_version.hasMatch(version) ||
        // Nur ein Dateiname – kein Pfad und keine fremde Adresse.
        file is! String ||
        !_file.hasMatch(file) ||
        size is! int ||
        size <= 0 ||
        sha256 is! String ||
        !_sha256.hasMatch(sha256)) {
      return null;
    }
    final url = base != null
        ? base.resolve(file)
        : rawUrl is String
            ? Uri.tryParse(rawUrl)
            : null;
    if (url == null || !isTrustedUpdateUrl(url)) return null;
    return UpdatePackage(
      kind: kind,
      arch: arch as String?,
      version: version,
      file: file,
      size: size,
      sha256: sha256,
      url: url,
    );
  }

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'arch': arch,
        'version': version,
        'file': file,
        'size': size,
        'sha256': sha256,
        'url': url.toString(),
      };
}

/// Updates sind ausführbarer Code, daher nur über HTTPS; unverschlüsselt
/// nur vom eigenen Rechner (Entwicklung).
bool isTrustedUpdateUrl(Uri url) {
  const local = {'localhost', '127.0.0.1', '::1', '10.0.2.2'};
  return url.host.isNotEmpty &&
      (url.scheme == 'https' ||
          (url.scheme == 'http' && local.contains(url.host)));
}

/// Dateinamen der Pakete, wie die Build-Skripte (`scripts/build_*.sh`) sie
/// vergeben und GitHub Actions sie an ein Release hängt.
final _fileNames = <(RegExp, UpdateKind)>[
  (RegExp(r'^antatime-(\d+(?:\.\d+){1,3})\.apk$'), UpdateKind.apk),
  (
    RegExp(r'^AnTaTime-(\d+(?:\.\d+){1,3})-(x86_64|aarch64)\.AppImage$'),
    UpdateKind.appimage
  ),
  (RegExp(r'^antatime_(\d+(?:\.\d+){1,3})_(amd64|arm64)\.deb$'), UpdateKind.deb),
  (
    RegExp(r'^antatime-(\d+(?:\.\d+){1,3})-linux-(x64|arm64)\.tar\.gz$'),
    UpdateKind.tar
  ),
  (
    RegExp(r'^AnTaTime-(\d+(?:\.\d+){1,3})-windows-(x64)-setup\.exe$'),
    UpdateKind.exe
  ),
  (RegExp(r'^antatime-(\d+(?:\.\d+){1,3})-windows-(x64)\.zip$'), UpdateKind.zip),
  (RegExp(r'^AnTaTime-(\d+(?:\.\d+){1,3})-macos\.dmg$'), UpdateKind.dmg),
];

const _archNames = {
  'x86_64': 'x64',
  'amd64': 'x64',
  'x64': 'x64',
  'aarch64': 'arm64',
  'arm64': 'arm64',
};

/// Erkennt ein Paket am Dateinamen; `null` für alles andere.
({UpdateKind kind, String? arch, String version})? parseUpdateFile(String name) {
  for (final (re, kind) in _fileNames) {
    final m = re.firstMatch(name);
    if (m == null) continue;
    return (
      kind: kind,
      arch: m.groupCount >= 2 ? _archNames[m.group(2)] : null,
      version: m.group(1)!,
    );
  }
  return null;
}

/// Pakete aus der Liste eines AnTaTime-Servers (`/updates/latest.json`,
/// liegt unter [base] neben den Dateien).
List<UpdatePackage> packagesFromServer(Object? manifest, Uri base) {
  final list = manifest is Map ? manifest['packages'] : null;
  if (list is! List) return const [];
  return [
    for (final entry in list) ?UpdatePackage.fromJson(entry, base: base),
  ];
}

/// Pakete aus einem GitHub-Release (Antwort von
/// `GET /repos/<repo>/releases/latest`): die Anhänge mit bekanntem Namen.
/// Größe und SHA-256 nennt GitHub selbst (`digest`).
List<UpdatePackage> packagesFromGitHub(Object? release) {
  final assets = release is Map ? release['assets'] : null;
  if (assets is! List) return const [];
  final packages = <UpdatePackage>[];
  for (final asset in assets) {
    if (asset is! Map) continue;
    final name = asset['name'];
    final digest = asset['digest'];
    final info = name is String ? parseUpdateFile(name) : null;
    if (info == null || digest is! String || !digest.startsWith('sha256:')) {
      continue;
    }
    final package = UpdatePackage.fromJson({
      'kind': info.kind.name,
      'arch': info.arch,
      'version': info.version,
      'file': name,
      'size': asset['size'],
      'sha256': digest.substring(7),
      'url': asset['browser_download_url'],
    });
    // Nur Downloads von GitHub selbst.
    if (package != null && package.url.host == 'github.com') {
      packages.add(package);
    }
  }
  return packages;
}

/// Vergleicht Versionen wie `1.10.0` und `1.9.3` zahlenweise.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
        for (final p in v.split('+').first.split('.')) int.tryParse(p) ?? 0,
      ];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// Sucht unter [packages] das Paket für diese Installation. `null`, wenn es
/// keines gibt oder es nicht neuer als [current] ist.
UpdatePackage? pickUpdate(
  Iterable<UpdatePackage> packages, {
  required UpdateKind kind,
  required String? arch,
  required String current,
}) {
  UpdatePackage? best;
  for (final p in packages) {
    if (p.kind != kind) continue;
    if (p.arch != null && p.arch != arch) continue;
    if (compareVersions(p.version, current) <= 0) continue;
    if (best == null || compareVersions(p.version, best.version) > 0) best = p;
  }
  return best;
}

/// Adresse des Verzeichnisses `/updates/` auf dem Server [url] (wie beim
/// Sync: `antatime.de`, `https://example.org/antatime`).
/// `null`, wenn die Adresse nicht taugt (siehe [isTrustedUpdateUrl]).
Uri? updateBaseUri(String url) {
  var s = url.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null) return null;
  if (!isTrustedUpdateUrl(u)) return null;
  var path = u.path.replaceAll(RegExp(r'/+$'), '');
  if (path.endsWith('/sync')) path = path.substring(0, path.length - 5);
  return Uri(
    scheme: u.scheme,
    host: u.host,
    port: u.hasPort ? u.port : null,
    path: '$path/updates/',
  );
}

/// Fehler mit einer Meldung für die Anzeige.
class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Adresse, unter der GitHub das neueste Release von [repo]
/// (`besitzer/name`) beschreibt; `null`, wenn [repo] nicht so aussieht.
/// Entwürfe und Vorabversionen zählen dort nicht.
Uri? gitHubLatestReleaseUri(String repo) {
  final r = repo.trim();
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$').hasMatch(r)) {
    return null;
  }
  return Uri.parse('https://api.github.com/repos/$r/releases/latest');
}
