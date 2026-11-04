#!/usr/bin/env bash
# Statische Analyse und Unit-Tests.
source "$(dirname "$0")/common.sh"
flutter_prepare
"$FLUTTER" analyze
"$FLUTTER" test
