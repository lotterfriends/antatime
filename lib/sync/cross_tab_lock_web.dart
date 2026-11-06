import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Mehrere Tabs teilen sich den `localStorage`. Ohne Sperre könnten zwei
/// Tabs gleichzeitig lesen, ändern und speichern – und sich gegenseitig
/// Änderungen überschreiben.
Future<T> crossTabLock<T>(String name, Future<T> Function() action) async {
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
