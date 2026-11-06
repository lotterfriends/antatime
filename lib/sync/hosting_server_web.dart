import 'package:web/web.dart' as web;

/// Liefert ein AnTaTime-Server die Web-App aus, markiert er die `index.html`
/// mit `<meta name="antatime-sync-url" content="same-origin">`. Dann ist
/// derselbe Server (inkl. Unterpfad aus `<base href>`) der passende
/// Sync-Server. Ohne Markierung (z. B. GitHub Pages) `null`.
String? hostingServerUrl() {
  final meta = web.document.querySelector('meta[name="antatime-sync-url"]');
  if (meta == null) return null;
  final content = meta.getAttribute('content') ?? '';
  if (content.isNotEmpty && content != 'same-origin') return content;
  final base = Uri.parse(web.document.baseURI);
  return '${base.origin}${base.path}';
}
