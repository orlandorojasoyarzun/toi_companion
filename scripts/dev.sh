#!/bin/bash
# Build + reset TCC + restart toi_companion.
#
# Run from the app/ directory:
#   bash ../scripts/dev.sh
#
# The `tccutil reset ListenEvent` is needed because every rebuild produces
# a new cdhash, which invalidates the Input Monitoring grant. If the
# permission is not re-granted, the CGEvent tap installs but receives
# no events (silent failure). If `tccutil` alone isn't enough, manually
# toggle toi_companion in System Settings → Privacy & Security → Input
# Monitoring and re-run this script.

set -e

cd "$(dirname "$0")/../app"

echo "→ xcodebuild"
xcodebuild -scheme ToiCompanion -configuration Debug -derivedDataPath ./build build > /dev/null

echo "→ tccutil reset ListenEvent"
tccutil reset ListenEvent com.salem.toicompanion 2>/dev/null || true

echo "→ restart app"
pkill -x ToiCompanion 2>/dev/null || true
sleep 0.5
open -g ./build/Build/Products/Debug/ToiCompanion.app

echo "✓ done"
