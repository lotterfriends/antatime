import 'package:antatime/app_state.dart';
import 'package:antatime/main.dart';
import 'package:antatime/models.dart';
import 'package:antatime/repository.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('Jahresansicht: Zeitraum mit der Maus markieren und eintragen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 560));
    late AppState state;
    await tester.runAsync(() async {
      await initializeDateFormatting('de_DE');
      final repo = Repository();
      final data = await repo.load();
      state = AppState(repo, data);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: state, child: const AnTaTimeApp()),
    );
    await tester.pump();

    await tester.tap(find.text('Abwesend').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Jahresansicht'));
    await tester.pumpAndSettle();

    final now = DateTime.now();
    final year = now.year;
    final month = DateFormat.MMMM('de_DE').format(now);
    final mm = now.month.toString().padLeft(2, '0');
    expect(find.text('$year'), findsOneWidget);

    // Beim Öffnen ist der aktuelle Monat ins Bild gescrollt.
    final view = tester.getRect(find.byType(SingleChildScrollView).last);
    final card = tester.getRect(
      find.ancestor(of: find.text(month), matching: find.byType(Card)),
    );
    expect(card.top, greaterThanOrEqualTo(view.top));
    expect(card.bottom, lessThanOrEqualTo(view.bottom));

    // Im aktuellen Monat vom 5. bis zum 9. ziehen.
    Finder dayIn(String month, String day) => find.descendant(
      of: find.ancestor(of: find.text(month), matching: find.byType(Card)),
      matching: find.text(day),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(dayIn(month, '5')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(tester.getCenter(dayIn(month, '7')));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(dayIn(month, '9')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Abwesenheit eintragen'), findsOneWidget);
    expect(find.text('Zeitraum'), findsOneWidget);
    expect(find.textContaining('05.$mm.$year – 09.$mm.$year'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Speichern'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(state.data.absences, hasLength(1));
    final a = state.data.absences.single;
    expect(a.type, AbsenceType.vacation);
    expect(a.from, DateTime(year, now.month, 5));
    expect(a.to, DateTime(year, now.month, 9));

    // Klick auf einen Tag der Abwesenheit öffnet sie zum Bearbeiten.
    final click = await tester.startGesture(
      tester.getCenter(dayIn(month, '7')),
      kind: PointerDeviceKind.mouse,
    );
    await click.up();
    await tester.pumpAndSettle();
    expect(find.text('Abwesenheit bearbeiten'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();

    // Klick auf „Urlaub“ in der Legende listet die Tage nach Monat.
    final workdays = [
      for (var d = 5; d <= 9; d++)
        if (DateTime(year, now.month, d).weekday <= 5) d,
    ];
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.tap(find.textContaining('Urlaub: '));
    await tester.pumpAndSettle();
    expect(find.text('Urlaub $year'), findsOneWidget);
    expect(find.text('$month (${workdays.length})'), findsOneWidget);
    await tester.tap(find.text('Kopieren'));
    await tester.pumpAndSettle();
    expect(find.text('Kopiert'), findsOneWidget);
    expect(copied, contains('$month (${workdays.length})'));
    // Aufeinanderfolgende Tage (Wochenende dazwischen) als ein Zeitraum.
    final range =
        '0${workdays.first}.$mm.$year – 0${workdays.last}.$mm.$year '
        '(${workdays.length} Tage)';
    expect(find.text(range), findsOneWidget);
    expect(copied, contains(range));
    await tester.tap(find.byTooltip('Schließen'));
    await tester.pumpAndSettle();

    // Beim Jahreswechsel beginnt die Ansicht beim Januar.
    await tester.tap(find.byTooltip('Nächstes Jahr'));
    await tester.pumpAndSettle();
    expect(find.text('${year + 1}'), findsOneWidget);
    final jan = tester.getRect(
      find.ancestor(of: find.text('Januar'), matching: find.byType(Card)),
    );
    final view2 = tester.getRect(find.byType(SingleChildScrollView).last);
    expect(jan.top, greaterThanOrEqualTo(view2.top));
    expect(jan.top, lessThan(view2.top + 20));

    state.dispose();
  });
}
