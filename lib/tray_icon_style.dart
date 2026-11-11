/// Darstellung des Symbols im Infobereich (Linux/Windows; macOS nutzt immer
/// ein Template-Symbol, das sich der Menüleiste anpasst).
///
/// Gilt nur für dieses Gerät – die Leisten sehen je System anders aus – und
/// wird daher weder synchronisiert noch exportiert.
enum TrayIconStyle {
  /// Weißes Symbol auf farbigem Grund (Standard).
  color('Farbig', ''),

  /// Einfarbig weiß, für dunkle Leisten.
  light('Einfarbig hell', '_light'),

  /// Einfarbig schwarz, für helle Leisten.
  dark('Einfarbig dunkel', '_dark');

  const TrayIconStyle(this.label, this.suffix);
  final String label;

  /// Anhang an den Dateinamen in assets/tray/.
  final String suffix;

  static TrayIconStyle byName(String? name) =>
      values.where((v) => v.name == name).firstOrNull ?? color;
}
