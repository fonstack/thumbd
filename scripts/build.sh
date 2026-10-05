#!/usr/bin/env bash
# Builds thumbd in release mode and signs it. The last line of output is the binary path.
#
#   ./scripts/build.sh            SwiftPM (swift build -c release)
#   ./scripts/build.sh --swiftc   plain swiftc, module by module, without running Package.swift
#                                 (for Macs where a policy like Santa blocks the manifest
#                                 binary that SwiftPM compiles and runs)
#
# Signing is configured with environment variables; see scripts/lib.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

if [[ "${1:-}" == "--swiftc" ]]; then
  OUT=.build/swiftc-release
  rm -rf "$OUT" && mkdir -p "$OUT"
  build_modules "$OUT" -O "${MODULES[@]}"
  swiftc -O -swift-version 5 -module-name thumbd -I "$OUT" -L "$OUT" \
    $(printf -- '-l%s ' "${MODULES[@]}") \
    -framework IOKit -framework CoreGraphics -framework Carbon \
    -o "$OUT/thumbd" Sources/thumbd/*.swift
  BIN="$OUT/thumbd"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/thumbd"
fi

resolve_identity
codesign --force --sign "$IDENTITY" --identifier "$SIGNING_ID" "$BIN"
codesign --display --verbose=2 "$BIN" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)=' >&2
codesign --display --requirements - "$BIN" 2>&1 | sed -n 's/^#* *designated => /designated requirement: /p' >&2
echo "$BIN"
