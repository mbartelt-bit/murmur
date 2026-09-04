#!/usr/bin/env bash
#
# Archive Murmur for iOS and upload it to App Store Connect (TestFlight).
#
#   scripts/ios-testflight.sh              # archive + upload
#   scripts/ios-testflight.sh --no-upload  # archive + export the .ipa only
#
# Prerequisites (one-time, all on Matt's side — see apple/README.md "TestFlight"):
#   * an App Store Connect app record for com.murmur.app under team X9PU63GUAN
#   * the Apple Distribution certificate for that team in the login keychain
#   * the App Store Connect API key .p8 at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#   * ASC_KEY_ID and ASC_ISSUER_ID exported (or present in ~/arkhe-native-release-tools/asc.mjs,
#     which this script reads as a fallback — it never prints either value)
#
# Every run bumps CFBundleVersion for the app AND both extensions to the current UTC minute
# (yyyyMMddHHmm) so App Store Connect never sees a duplicate build number; the marketing
# version (CFBundleShortVersionString) is left alone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

UPLOAD=1
for arg in "$@"; do
  case "$arg" in
    --no-upload) UPLOAD=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

TEAM_ID="X9PU63GUAN"
PROJECT="apple/Murmur.xcodeproj"
SCHEME="Murmur"
OUT="$REPO_ROOT/target/ios"
ARCHIVE="$OUT/Murmur.xcarchive"
EXPORT="$OUT/export"
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"

# ---------------------------------------------------------------- credentials --
# Only needed for the upload; the values are used, never echoed.
if [ "$UPLOAD" = 1 ]; then
  ASC_TOOLS="$HOME/arkhe-native-release-tools/asc.mjs"
  : "${ASC_KEY_ID:=$( [ -f "$ASC_TOOLS" ] && sed -nE 's/.*AuthKey_([A-Z0-9]+)\.p8.*/\1/p' "$ASC_TOOLS" | head -1 || true)}"
  : "${ASC_ISSUER_ID:=$( [ -f "$ASC_TOOLS" ] && grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$ASC_TOOLS" | head -1 || true)}"
  ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ] || [ ! -f "$ASC_KEY_PATH" ]; then
    echo "error: App Store Connect API credentials not found." >&2
    echo "       export ASC_KEY_ID and ASC_ISSUER_ID, and put the .p8 at $HOME/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8" >&2
    exit 1
  fi
fi

# Keep xcodebuild's firehose readable without hiding failures: xcbeautify if installed,
# otherwise only the lines that matter. `|| true` keeps grep's "no match" from tripping
# pipefail; xcodebuild's own exit status still propagates through the pipe.
xcbeautify_or_tail() {
  if command -v xcbeautify >/dev/null 2>&1; then xcbeautify; else grep -E "error:|warning: |BUILD |EXPORT |ARCHIVE |Upload|Uploaded|Processing" || true; fi
}

# ------------------------------------------------------------- rust core first --
. "$HOME/.cargo/env" 2>/dev/null || true
scripts/build-core-mobile.sh ios

# --------------------------------------------------------------- build number --
# The three Info.plists must agree or App Store Connect rejects the upload.
for plist in apple/Murmur/Info.plist apple/MurmurKeyboard/Info.plist apple/MurmurControls/Info.plist; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$plist"
done
MARKETING="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' apple/Murmur/Info.plist)"
echo "== Murmur $MARKETING ($BUILD_NUMBER) =="

# -------------------------------------------------------------------- archive --
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$OUT"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  archive | xcbeautify_or_tail

# --------------------------------------------------------------------- export --
# destination=upload sends the build straight to App Store Connect from xcodebuild
# (the modern replacement for `altool --upload-app`). --no-upload writes the .ipa instead.
EXPORT_PLIST="$OUT/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$([ "$UPLOAD" = 1 ] && echo upload || echo export)</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

if [ "$UPLOAD" = 1 ]; then
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_PLIST" -exportPath "$EXPORT" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" | xcbeautify_or_tail
  echo
  echo "ok: uploaded Murmur $MARKETING ($BUILD_NUMBER) to App Store Connect — processing takes a few minutes, then it appears under TestFlight."
else
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_PLIST" -exportPath "$EXPORT" \
    -allowProvisioningUpdates | xcbeautify_or_tail
  echo
  echo "ok: $EXPORT/Murmur.ipa"
fi

# Leave the working tree as it was: the build number is a per-upload value, not a commit.
git checkout -- apple/Murmur/Info.plist apple/MurmurKeyboard/Info.plist apple/MurmurControls/Info.plist 2>/dev/null || true
