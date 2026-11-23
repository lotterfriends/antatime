import 'package:antatime/app_state.dart';
import 'package:antatime/main.dart';
import 'package:antatime/repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('App startet, Start/Pause und alle Seiten rendern',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    late AppState state;
    await tester.runAsync(() async {
      await initializeDateFormatting('de_DE');
      final repo = Repository();
      final data = await repo.load();
      state = AppState(repo, data);
    });

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: const AnTaTimeApp(),
    ));
    await tester.pump();

    expect(find.text('AnTaTime'), findsWidgets);
    expect(find.text('Stundenkonto'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    // Bildschirmleser: der Knopf ist beschriftet.
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Arbeitszeit starten'), findsOneWidget);
    semantics.dispose();

    await tester.runAsync(() => state.toggle());
    await tester.pump();
    expect(state.isRunning, isTrue);
    expect(find.text('Pause'), findsOneWidget);

    await tester.runAsync(() => state.toggle());
    await tester.pump();
    expect(state.isRunning, isFalse);
    expect(state.data.sessions, hasLength(1));

    for (final tab in ['Verlauf', 'Abwesend', 'Einstellungen', 'Heute']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
    }

    // Nacherfassen-Dialog öffnen.
    await tester.tap(find.byTooltip('Arbeitszeit nacherfassen'));
    await tester.pumpAndSettle();
    expect(find.text('Arbeitszeit nacherfassen'), findsWidgets);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();

    state.dispose();
  });
}
