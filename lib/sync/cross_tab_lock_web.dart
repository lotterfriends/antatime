import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Mehrere Tabs teilen sich den `localStorage`. Ohne Sperre könnten zwei
/// Tabs gleichzeitig lesen, ändern und speichern – und sich gegenseitig
/// Änderungen überschreiben.
///
/// Web Locks gibt es nur in sicheren Kontexten (HTTPS, localhost). Ohne sie
/// (z. B. Web-App über einfaches HTTP im Heimnetz) bleibt nur die Sperre
/// innerhalb des Tabs – besser als jede Änderung scheitern zu lassen.
Future<T> crossTabLock<T>(String name, Future<T> Function() action) async {
  if (!(web.window.navigator as JSObject).has('locks')) return action();
  late T result;
  Object? error;
  StackTrace? stack;
  JSPromise<JSAny?> granted(JSAny? lock) => (() async {
        try {
          result = await action();
        } catch (e, s) {
          error = e;
          stack = s;
        }
      })()
          .toJS;
  await web.window.navigator.locks.request(name, granted.toJS).toDart;
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return result;
}
