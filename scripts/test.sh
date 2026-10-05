#!/usr/bin/env bash
# Builds and runs the unit tests: gesture state machine, shortcut parsing and config
# decoding. They don't touch the mouse.
#
#   ./scripts/test.sh            SwiftPM (swift run thumbd-tests)
#   ./scripts/test.sh --swiftc   plain swiftc, like build.sh --swiftc; the test binary is signed
#                                the same way, so it also runs on Santa-managed Macs
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

if [[ "${1:-}" == "--swiftc" ]]; then
  OUT=.build/swiftc-tests
  TESTED=(Gestures Actions Config)
  rm -rf "$OUT" && mkdir -p "$OUT"
  build_modules "$OUT" -Onone "${TESTED[@]}"
  swiftc -Onone -swift-version 5 -module-name thumbd_tests -I "$OUT" -L "$OUT" \
    $(printf -- '-l%s ' "${TESTED[@]}") -framework CoreGraphics -framework Carbon \
    -o "$OUT/thumbd-tests" Tests/thumbd-tests/*.swift
  resolve_identity
  codesign --force --sign "$IDENTITY" --identifier "$SIGNING_ID-tests" "$OUT/thumbd-tests"
  "$OUT/thumbd-tests"
else
  swift run thumbd-tests
fi
