import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Meldet Wechsel der Netzwerkverbindung (WLAN ↔ Mobilfunk, offline ↔
/// online). Danach ist eine bestehende WebSocket-Verbindung oft tot, ohne
/// dass es jemand merkt.
Stream<void> platformNetworkChanges() => Connectivity()
    .onConnectivityChanged
    .distinct(listEquals)
    .map((_) {});
