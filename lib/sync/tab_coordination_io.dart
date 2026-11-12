import 'dart:async';

/// Nativ gibt es nur einen Prozess: Er synchronisiert immer selbst.
FutureOr<void Function()> acquireSyncLeadership(String name) => _noop;

/// Nativ ändert kein anderer Tab die Daten.
Stream<void> otherTabChanges() => const Stream.empty();

void _noop() {}
