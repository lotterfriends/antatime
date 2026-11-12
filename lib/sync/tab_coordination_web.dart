import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Nur ein Tab pro Browser hält die Verbindung zum Server: Jeder weitere Tab
/// würde sonst eine eigene Verbindung öffnen, dieselben Änderungen erneut
/// senden und gegen die Verbindungs-Limits pro Adresse zählen.
///
/// Liefert eine Funktion zum Freigeben, sobald dieser Tab an der Reihe ist.
/// Wird der Tab geschlossen, übernimmt automatisch der nächste.
FutureOr<void Function()> acquireSyncLeadership(String name) {
  // Web Locks gibt es nur in sicheren Kontexten (HTTPS, localhost).
  if (!(web.window.navigator as JSObject).has('locks')) return _noop;
  final acquired = Completer<void Function()>();
  final release = Completer<void>();
  void releaseLock() {
    if (!release.isCompleted) release.complete();
  }

  JSPromise<JSAny?> granted(JSAny? lock) {
    if (!acquired.isCompleted) acquired.complete(releaseLock);
    return release.future.toJS;
  }

  try {
    unawaited(web.window.navigator.locks
        .request(name, granted.toJS)
        .toDart
        .then<JSAny?>((v) => v, onError: (Object _) {
      if (!acquired.isCompleted) acquired.complete(_noop);
      return null;
    }));
  } catch (_) {
    return _noop;
  }
  return acquired.future;
}

/// Ein anderer Tab hat gespeichert (`localStorage`).
Stream<void> otherTabChanges() =>
    web.EventStreamProviders.storageEvent.forTarget(web.window).map((_) {});

void _noop() {}
