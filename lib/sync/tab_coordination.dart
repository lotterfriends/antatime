// Abstimmung zwischen mehreren Tabs derselben Web-App (im Browser per Web
// Locks und `storage`-Events; nativ gibt es nur einen Prozess und damit
// nichts abzustimmen).
export 'tab_coordination_io.dart'
    if (dart.library.js_interop) 'tab_coordination_web.dart';
