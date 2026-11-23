import 'package:antatime/desktop/autostart_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Exec-Zeile der Linux-Autostart-Datei', () {
    expect(Autostart.quoteExec('/opt/AnTaTime/antatime'),
        '"/opt/AnTaTime/antatime"');
    // Leerzeichen und Sonderzeichen in Anführungszeichen, `%` als `%%`.
    expect(Autostart.quoteExec('/home/u/100% Apps/AnTaTime.AppImage'),
        '"/home/u/100%% Apps/AnTaTime.AppImage"');
    expect(Autostart.quoteExec(r'/a"b$c`d'), r'"/a\\"b\\$c\\`d"');
  });
}
