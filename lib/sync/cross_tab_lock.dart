// Sperre über alle Tabs/Fenster der App hinweg (im Browser per Web Locks
// API, nativ gibt es nur einen Prozess und damit nichts zu tun).
export 'cross_tab_lock_io.dart'
    if (dart.library.js_interop) 'cross_tab_lock_web.dart';
