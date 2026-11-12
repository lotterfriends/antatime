import 'package:flutter/material.dart';

/// Hand-Cursor über klickbaren Flächen, auch auf dem Desktop.
///
/// Flutter zeigt bei Material-Buttons, Chips, Schaltern usw. außerhalb des
/// Browsers absichtlich den normalen Pfeil (`adaptiveClickable`). Für
/// AnTaTime soll überall dort, wo man klicken kann, die Hand erscheinen.
const clickCursor = WidgetStateMouseCursor.clickable;

/// Ergänzt [theme] um den Hand-Cursor für alle Widgets, die ihn über das
/// Theme einstellen lassen.
ThemeData withClickCursors(ThemeData theme) {
  const style = ButtonStyle(mouseCursor: clickCursor);
  return theme.copyWith(
    textButtonTheme: const TextButtonThemeData(style: style),
    filledButtonTheme: const FilledButtonThemeData(style: style),
    elevatedButtonTheme: const ElevatedButtonThemeData(style: style),
    outlinedButtonTheme: const OutlinedButtonThemeData(style: style),
    iconButtonTheme: const IconButtonThemeData(style: style),
    segmentedButtonTheme: const SegmentedButtonThemeData(style: style),
    floatingActionButtonTheme: theme.floatingActionButtonTheme
        .copyWith(mouseCursor: clickCursor),
    switchTheme: theme.switchTheme.copyWith(mouseCursor: clickCursor),
    checkboxTheme: theme.checkboxTheme.copyWith(mouseCursor: clickCursor),
    radioTheme: theme.radioTheme.copyWith(mouseCursor: clickCursor),
    popupMenuTheme: theme.popupMenuTheme.copyWith(mouseCursor: clickCursor),
  );
}

/// Zeigt über [child] den Hand-Cursor, auch wenn darin liegende Widgets
/// einen anderen Cursor setzen und keinen Parameter dafür anbieten (z. B.
/// [NavigationBar]). Klicks gehen unverändert an [child].
class ClickCursorArea extends StatelessWidget {
  const ClickCursorArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          child,
          // Nicht deckend: Zeiger-Ereignisse erreichen weiterhin [child],
          // der Cursor dieser oberen Ebene hat aber Vorrang.
          const Positioned.fill(
            child: MouseRegion(opaque: false, cursor: SystemMouseCursors.click),
          ),
        ],
      );
}
