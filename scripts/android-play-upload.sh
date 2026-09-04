#!/usr/bin/env bash
#
# Build the signed Android App Bundle and upload it to Google Play.
#
#   scripts/android-play-upload.sh                # bundleRelease + internal-testing upload
#   scripts/android-play-upload.sh --no-upload    # just the .aab
#   scripts/android-play-upload.sh --track production --status draft   # a real release, left as a draft
#
# Prerequisites (one-time, Matt's side — see android/README.md "Play"):
#   * a Play Console app for com.murmur.app
#   * android/keystore.properties (gitignored) pointing at the upload keystore
#   * a service-account JSON with Release manager on the app (path via $PLAY_SERVICE_ACCOUNT)
#
# versionCode comes from $MURMUR_VERSION_CODE when set, otherwise the current UTC minute as an
# integer (yyMMddHHmm fits in 31 bits until 2099), so every upload is strictly newer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

UPLOAD=1
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-upload) UPLOAD=0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) PASS+=("$1") ;;
  esac
  shift
done

: "${JAVA_HOME:=/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
: "${MURMUR_VERSION_CODE:=$(date -u +%y%m%d%H%M)}"
export JAVA_HOME ANDROID_HOME MURMUR_VERSION_CODE
. "$HOME/.cargo/env" 2>/dev/null || true

if [ ! -f android/keystore.properties ]; then
  echo "error: android/keystore.properties is missing — copy android/keystore.properties.example and fill in the upload keystore." >&2
  exit 1
fi

echo "== Murmur Android versionCode $MURMUR_VERSION_CODE =="
(cd android && ./gradlew --no-daemon bundleRelease)
AAB="android/app/build/outputs/bundle/release/app-release.aab"
[ -f "$AAB" ] || { echo "error: expected $AAB" >&2; exit 1; }
echo "ok: $AAB"

if [ "$UPLOAD" = 1 ]; then
  node scripts/play-upload.mjs --aab "$AAB" --package com.murmur.app "${PASS[@]+"${PASS[@]}"}"
fi
