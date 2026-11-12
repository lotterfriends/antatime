import 'package:antatime/click_cursor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Klickbare Flächen zeigen auch auf dem Desktop die Hand',
      (tester) async {
    var tab = 0;
    await tester.pumpWidget(MaterialApp(
      theme: withClickCursors(ThemeData()),
      home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
          body: ListView(children: [
            TextButton(onPressed: () {}, child: const Text('Text')),
            FilledButton(onPressed: () {}, child: const Text('Filled')),
            IconButton(
                onPressed: () {}, icon: const Icon(Icons.add), tooltip: 'Icon'),
            const TextButton(onPressed: null, child: Text('Aus')),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Eins')),
                ButtonSegment(value: 2, label: Text('Zwei')),
              ],
              selected: const {1},
              onSelectionChanged: (_) {},
            ),
            Switch(key: const Key('switch'), value: true, onChanged: (_) {}),
            FilterChip(
                mouseCursor: clickCursor,
                label: const Text('Chip'),
                onSelected: (_) {}),
          ]),
          floatingActionButton: FloatingActionButton.extended(
              onPressed: () {}, label: const Text('FAB')),
          bottomNavigationBar: ClickCursorArea(
            child: NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.timer), label: 'A'),
                NavigationDestination(icon: Icon(Icons.settings), label: 'B'),
              ],
            ),
          ),
        ),
      ),
    ));

    final mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    await mouse.addPointer(location: Offset.zero);
    Future<MouseCursor?> cursorOver(Finder f) async {
      await mouse.moveTo(tester.getCenter(f));
      await tester.pump();
      return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
    }

    for (final f in [
      find.text('Text'),
      find.text('Filled'),
      find.byTooltip('Icon'),
      find.text('Zwei'),
      find.byKey(const Key('switch')),
      find.text('Chip'),
      find.text('FAB'),
      find.text('B'),
    ]) {
      expect(await cursorOver(f), SystemMouseCursors.click, reason: '$f');
    }
    // Deaktivierte Buttons bleiben beim Pfeil.
    expect(await cursorOver(find.text('Aus')), SystemMouseCursors.basic);

    // Die Cursor-Ebene über der Navigationsleiste lässt Klicks durch.
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(tab, 1);
  });
}
