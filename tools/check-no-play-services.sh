#!/usr/bin/env bash
# Verify that the anh-nha build has zero Google Play Services dependencies.
# F-Droid compliance + FR-9 + NFR-5. Exits non-zero on any match.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "Checking pubspec.yaml + build.gradle.kts for Google Play Services / Firebase / Crashlytics..."

PATTERNS='firebase|crashlytics|play-services|com\.google\.android\.gms|com\.google\.firebase'

if grep -rEi "$PATTERNS" pubspec.yaml pubspec.lock android/ --exclude-dir=build --exclude-dir=.gradle; then
  echo "ERROR: Found Google Play Services / Firebase dependency — F-Droid compliance broken."
  exit 1
fi

echo "OK: no Google Play Services / Firebase / Crashlytics dependencies found."