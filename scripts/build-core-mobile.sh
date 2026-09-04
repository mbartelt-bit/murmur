#!/usr/bin/env bash
#
# Build murmur-core for a mobile platform and generate its UniFFI bindings.
#
#   scripts/build-core-mobile.sh ios      [--debug]
#   scripts/build-core-mobile.sh android  [--debug]
#
# Xcode (a pre-build script phase) and Gradle (the `buildRustCore` task) are the
# only callers that matter; running it by hand does exactly the same thing.
# It is idempotent: every run rewrites the same outputs in place.
#
# `--no-default-features` is not optional. The `whisper` feature pulls in cmake +
# whisper.cpp, which we deliberately do not cross-compile for phones; local
# inference stays desktop-only.
set -euo pipefail

# ---------------------------------------------------------------- arguments --

usage() {
  cat <<'USAGE'
Usage: scripts/build-core-mobile.sh <ios|android> [--debug]

  ios       Builds aarch64-apple-ios + aarch64-apple-ios-sim, generates the
            Swift bindings, and packs both static libs into
            apple/Frameworks/MurmurCore.xcframework.

  android   Builds arm64-v8a + x86_64 via cargo-ndk into
            android/app/src/main/jniLibs, and generates the Kotlin bindings
            into android/app/src/main/java/app/murmur/core/.

  --debug   Use the cargo debug profile instead of release (default: release).
  -h        Show this help.

Environment (defaulted if unset, printed on every run):
  JAVA_HOME         Android Studio's bundled JBR
  ANDROID_HOME      $HOME/Library/Android/sdk
  ANDROID_NDK_HOME  $ANDROID_HOME/ndk/27.2.12479018
USAGE
}

PLATFORM=""
PROFILE="release"

while [ $# -gt 0 ]; do
  case "$1" in
    ios|android)  PLATFORM="$1" ;;
    --debug)      PROFILE="debug" ;;
    --release)    PROFILE="release" ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$PLATFORM" ]; then
  echo "error: expected 'ios' or 'android'" >&2
  usage >&2
  exit 2
fi

# `--release` is a flag; the debug profile is cargo's default (no flag). Kept as a
# plain string rather than an array because macOS ships bash 3.2, where expanding
# an empty array trips `set -u`. `--release` has no spaces, so this is safe.
CARGO_PROFILE_FLAG=""
if [ "$PROFILE" = "release" ]; then
  CARGO_PROFILE_FLAG="--release"
fi

# ------------------------------------------------------------------- layout --

# Derive the repo root from this script's own location so the script works from
# any cwd (Xcode runs it from the .xcodeproj dir, Gradle from android/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

TARGET_DIR="$REPO_ROOT/target"
UNIFFI_DIR="$TARGET_DIR/uniffi"

# ------------------------------------------------------------------- toolch --

# Xcode and Gradle both run with a stripped PATH that usually lacks ~/.cargo/bin.
if ! command -v cargo >/dev/null 2>&1 && [ -f "$HOME/.cargo/env" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi
command -v cargo >/dev/null 2>&1 || {
  echo "error: cargo not found on PATH (install Rust: https://rustup.rs)" >&2
  exit 1
}

# Best-effort: only rustup can answer this, and cargo can be installed without it.
require_target() {
  command -v rustup >/dev/null 2>&1 || return 0
  rustup target list --installed | grep -qx "$1" || {
    echo "error: Rust target '$1' is not installed. Run: rustup target add $1" >&2
    exit 1
  }
}

# --------------------------------------------------------------------- env ----

: "${JAVA_HOME:=/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
: "${ANDROID_NDK_HOME:=$ANDROID_HOME/ndk/27.2.12479018}"
export JAVA_HOME ANDROID_HOME ANDROID_NDK_HOME

echo "== build-core-mobile ($PLATFORM, $PROFILE) =="
echo "  REPO_ROOT        = $REPO_ROOT"
echo "  JAVA_HOME        = $JAVA_HOME"
echo "  ANDROID_HOME     = $ANDROID_HOME"
echo "  ANDROID_NDK_HOME = $ANDROID_NDK_HOME"
echo

# UniFFI's `--library` mode reads the exported metadata straight out of a built
# cdylib, so the *cross-compiled* iOS .dylib / Android .so works fine here and we
# never need a second host build. (Verified against uniffi 0.32 on Xcode 26.6.)
bindgen() {
  local library="$1" language="$2" out_dir="$3"
  [ -f "$library" ] || { echo "error: expected $library to exist" >&2; exit 1; }
  # --no-format: uniffi shells out to ktlint/swiftformat when they happen to be on
  # PATH, so the generated file would differ machine to machine. Skip it.
  cargo run --quiet -p murmur-core --features cli --bin uniffi-bindgen -- \
    generate --library "$library" --language "$language" --no-format --out-dir "$out_dir"
}

# --------------------------------------------------------------------- ios ----

build_ios() {
  local device_triple="aarch64-apple-ios"
  local sim_triple="aarch64-apple-ios-sim"
  require_target "$device_triple"
  require_target "$sim_triple"
  command -v xcodebuild >/dev/null 2>&1 || {
    echo "error: xcodebuild not found. Install Xcode and run: xcode-select --install" >&2
    exit 1
  }

  local triple
  for triple in "$device_triple" "$sim_triple"; do
    echo "--> cargo build --target $triple"
    # shellcheck disable=SC2086  # intentional: empty $CARGO_PROFILE_FLAG adds no arg
    cargo build -p murmur-core $CARGO_PROFILE_FLAG --no-default-features --target "$triple"
  done

  local swift_out="$UNIFFI_DIR/swift"
  local headers="$UNIFFI_DIR/ios-headers"
  echo "--> uniffi-bindgen (swift)"
  rm -rf "$swift_out" "$headers"
  bindgen "$TARGET_DIR/$device_triple/$PROFILE/libmurmur_core.dylib" swift "$swift_out"

  # Clang wants the modulemap named module.modulemap inside the headers dir the
  # xcframework carries; uniffi names it after the FFI module.
  mkdir -p "$headers"
  cp "$swift_out/MurmurCoreFFI.h" "$headers/MurmurCoreFFI.h"
  cp "$swift_out/MurmurCoreFFI.modulemap" "$headers/module.modulemap"

  # The Swift package that wraps this lives in apple/ (Task 3); we only drop the
  # generated file into its gitignored Generated/ directory.
  local generated="$REPO_ROOT/apple/MurmurShared/Sources/MurmurCore/Generated"
  mkdir -p "$generated"
  cp "$swift_out/MurmurCore.swift" "$generated/MurmurCore.swift"

  local xcframework="$REPO_ROOT/apple/Frameworks/MurmurCore.xcframework"
  echo "--> xcodebuild -create-xcframework"
  rm -rf "$xcframework"
  mkdir -p "$(dirname "$xcframework")"
  xcodebuild -create-xcframework \
    -library "$TARGET_DIR/$device_triple/$PROFILE/libmurmur_core.a" -headers "$headers" \
    -library "$TARGET_DIR/$sim_triple/$PROFILE/libmurmur_core.a"    -headers "$headers" \
    -output "$xcframework" >/dev/null

  echo
  echo "ok: $xcframework"
  echo "ok: $generated/MurmurCore.swift"
}

# ----------------------------------------------------------------- android ----

build_android() {
  require_target aarch64-linux-android
  require_target x86_64-linux-android
  command -v cargo-ndk >/dev/null 2>&1 || {
    echo "error: cargo-ndk not found. Run: cargo install cargo-ndk" >&2
    exit 1
  }
  [ -d "$ANDROID_NDK_HOME" ] || {
    echo "error: ANDROID_NDK_HOME='$ANDROID_NDK_HOME' does not exist." >&2
    echo "       Install NDK 27.2.12479018 via Android Studio's SDK Manager," >&2
    echo "       or export ANDROID_NDK_HOME to the NDK you have." >&2
    exit 1
  }

  local jni_libs="$REPO_ROOT/android/app/src/main/jniLibs"
  local kotlin_out="$REPO_ROOT/android/app/src/main/java"
  mkdir -p "$jni_libs" "$kotlin_out"

  # -P 28 matches the app's minSdk, so we never link against APIs older than the
  # oldest device we ship to (cargo-ndk would otherwise default to API 21).
  echo "--> cargo ndk build (arm64-v8a, x86_64)"
  # shellcheck disable=SC2086  # intentional: empty $CARGO_PROFILE_FLAG adds no arg
  cargo ndk -t arm64-v8a -t x86_64 -P 28 -o "$jni_libs" \
    build -p murmur-core $CARGO_PROFILE_FLAG --no-default-features

  echo "--> uniffi-bindgen (kotlin)"
  bindgen "$TARGET_DIR/aarch64-linux-android/$PROFILE/libmurmur_core.so" kotlin "$kotlin_out"

  echo
  echo "ok: $jni_libs/{arm64-v8a,x86_64}/libmurmur_core.so"
  echo "ok: $kotlin_out/app/murmur/core/murmur_core.kt"
}

case "$PLATFORM" in
  ios)     build_ios ;;
  android) build_android ;;
esac
