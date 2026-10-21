#!/usr/bin/env bash
# Internal TestFlight only. Reuses the authorized certificate and Exerly profile.
# --dry-run creates an unsigned archive; --archive signs without uploading.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---upload}"
[[ "$#" -le 1 && "$MODE" =~ ^--(dry-run|archive|upload)$ ]] || { echo 'Usage: release.sh [--dry-run|--archive|--upload]' >&2; exit 2; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.2.app/Contents/Developer}"
BUILD="${BUILD:-$(date -u +%y%m%d%H%M)}"
[[ "$BUILD" =~ ^[0-9]{10}$ ]] || { echo 'BUILD must be a ten-digit UTC yymmddHHMM timestamp' >&2; exit 2; }
VERSION=1.0
RELEASE_ENVIRONMENT="${EXERLY_RELEASE_ENVIRONMENT:-staging}"
case "$RELEASE_ENVIRONMENT" in
  staging) API_URL=http://100.80.149.7:39110 ;;
  production) API_URL=https://exerly-fitness-93dyl.ondigitalocean.app ;;
  *) echo 'EXERLY_RELEASE_ENVIRONMENT must be staging or production' >&2; exit 2 ;;
esac
OUT="${EXERLY_RELEASE_DIR:-$ROOT/build/release/$BUILD}"
mkdir -p "$OUT"
SDK="$(xcrun --sdk iphoneos --show-sdk-version)"
[[ "${SDK%%.*}" -ge 26 ]] || { echo 'Release requires iOS SDK 26 or later' >&2; exit 2; }

# Never overwrite a previous archive or run two Exerly signing sessions together.
LOCK="$HOME/private_keys/.exerly-release-lock"
if [[ "$MODE" != --dry-run ]]; then
  mkdir "$LOCK" 2>/dev/null || { echo 'An Exerly signing session is already running' >&2; exit 2; }
fi
PRIVATE=''
KEYCHAIN=''
PROFILE_INSTALLED=''
WIDGETS_PROFILE_INSTALLED=''
WATCH_PROFILE_INSTALLED=''
OLD_KEYCHAINS=()
cleanup() {
  result=$?
  trap - EXIT
  if [[ -n "$KEYCHAIN" ]]; then
    security list-keychains -d user -s "${OLD_KEYCHAINS[@]}" || result=1
    security delete-keychain "$KEYCHAIN" >/dev/null || result=1
  fi
  [[ -z "$PROFILE_INSTALLED" ]] || rm -f "$PROFILE_INSTALLED"
  [[ -z "$WIDGETS_PROFILE_INSTALLED" ]] || rm -f "$WIDGETS_PROFILE_INSTALLED"
  [[ -z "$WATCH_PROFILE_INSTALLED" ]] || rm -f "$WATCH_PROFILE_INSTALLED"
  [[ -z "$PRIVATE" ]] || rm -rf "$PRIVATE"
  [[ "$MODE" == --dry-run ]] || rmdir "$LOCK"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ARCHIVE="$OUT/Exerly.xcarchive"
[[ ! -e "$ARCHIVE" ]] || { echo "Archive already exists: $ARCHIVE" >&2; exit 2; }
SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
AUTH=()
if [[ "$MODE" != --dry-run ]]; then
  # Validate the Exerly profile before touching keychains or installed profiles.
  PROFILE="$HOME/private_keys/exerly-distribution/com.exerly.fitness.mobileprovision"
  PROFILE_UUID="$(python3 - "$ROOT/scripts" "$PROFILE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from release_checks import read_profile, validate_profile
p = read_profile(sys.argv[2]); validate_profile(p); print(p['UUID'])
PY
)"
  WIDGETS_PROFILE="$HOME/private_keys/exerly-distribution/com.exerly.fitness.widgets.mobileprovision"
  WIDGETS_PROFILE_UUID="$(python3 - "$ROOT/scripts" "$WIDGETS_PROFILE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from release_checks import read_profile, validate_profile, WIDGETS
p = read_profile(sys.argv[2]); validate_profile(p, WIDGETS); print(p['UUID'])
PY
)"
  WATCH_PROFILE="$HOME/private_keys/exerly-distribution/com.exerly.fitness.watchkitapp.mobileprovision"
  WATCH_PROFILE_UUID="$(python3 - "$ROOT/scripts" "$WATCH_PROFILE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from release_checks import read_profile, validate_profile, WATCH
p = read_profile(sys.argv[2]); validate_profile(p, WATCH); print(p['UUID'])
PY
)"
  CERT_DIR="$HOME/private_keys/eternalmonitor-distribution"
  PRIVATE="$(mktemp -d "${TMPDIR:-/tmp}/exerly-release.XXXXXX")"
  chmod 700 "$PRIVATE"
  while IFS= read -r chain; do OLD_KEYCHAINS+=("$chain"); done < <(security list-keychains -d user | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//')
  KEYCHAIN_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  KEYCHAIN="$PRIVATE/distribution.keychain-db"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security set-keychain-settings -lut 7200 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security import "$CERT_DIR/distribution.p12" -P "$(tr -d '\n' < "$CERT_DIR/p12-password.txt")" -A -t cert -f pkcs12 -k "$KEYCHAIN" >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" "${OLD_KEYCHAINS[@]}"
  PROFILE_DEST="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
  mkdir -p "$(dirname "$PROFILE_DEST")"
  if [[ ! -e "$PROFILE_DEST" ]]; then
    cp "$PROFILE" "$PROFILE_DEST"
    PROFILE_INSTALLED="$PROFILE_DEST"
  else
    cmp -s "$PROFILE" "$PROFILE_DEST" || { echo 'Installed profile differs; refusing to overwrite it' >&2; exit 2; }
  fi
  WIDGETS_PROFILE_DEST="$(dirname "$PROFILE_DEST")/$WIDGETS_PROFILE_UUID.mobileprovision"
  if [[ ! -e "$WIDGETS_PROFILE_DEST" ]]; then
    cp "$WIDGETS_PROFILE" "$WIDGETS_PROFILE_DEST"
    WIDGETS_PROFILE_INSTALLED="$WIDGETS_PROFILE_DEST"
  else
    cmp -s "$WIDGETS_PROFILE" "$WIDGETS_PROFILE_DEST" || { echo 'Installed widgets profile differs; refusing to overwrite it' >&2; exit 2; }
  fi
  WATCH_PROFILE_DEST="$(dirname "$PROFILE_DEST")/$WATCH_PROFILE_UUID.mobileprovision"
  if [[ ! -e "$WATCH_PROFILE_DEST" ]]; then
    cp "$WATCH_PROFILE" "$WATCH_PROFILE_DEST"
    WATCH_PROFILE_INSTALLED="$WATCH_PROFILE_DEST"
  else
    cmp -s "$WATCH_PROFILE" "$WATCH_PROFILE_DEST" || { echo 'Installed watch profile differs; refusing to overwrite it' >&2; exit 2; }
  fi
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual 'CODE_SIGN_IDENTITY=Apple Distribution' DEVELOPMENT_TEAM=9X79V37Q89
    "EXERLY_PROVISIONING_PROFILE=$PROFILE_UUID" "EXERLY_WIDGETS_PROVISIONING_PROFILE=$WIDGETS_PROFILE_UUID"
    "EXERLY_WATCH_PROVISIONING_PROFILE=$WATCH_PROFILE_UUID" "OTHER_CODE_SIGN_FLAGS=--keychain $KEYCHAIN")
  python3 - "$OUT/exportOptions.plist" "$PROFILE_UUID" "$WIDGETS_PROFILE_UUID" "$WATCH_PROFILE_UUID" <<'PY'
import pathlib, plistlib, sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
  'method': 'app-store-connect', 'destination': 'export', 'teamID': '9X79V37Q89',
  'signingStyle': 'manual', 'signingCertificate': 'Apple Distribution',
  'provisioningProfiles': {'com.exerly.fitness': sys.argv[2], 'com.exerly.fitness.widgets': sys.argv[3],
                           'com.exerly.fitness.watchkitapp': sys.argv[4]},
  'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True,
  'testFlightInternalTestingOnly': True,
}))
PY
fi

# Apple rejects App Intent phrases containing Apple product names. Each phrase
# names the app, so its line matches applicationName.
if rg -n -i '(IntentDescription|LocalizedStringResource|shortTitle|phrases|applicationName).*\b(apple|iphone|ipad|ipod|siri|ios|macos|mac|watchos|airpods|homepod|vision ?pro|health)\b' "$ROOT/Exerly" "$ROOT/Shared" "$ROOT/ExerlyWidgets" "$ROOT/ExerlyWatch" --glob '*.swift'; then
  echo 'Remove Apple product names from App Intent titles and phrases' >&2
  exit 2
fi
echo "Archiving Exerly $VERSION ($BUILD), $MODE"
xcodebuild -project "$ROOT/Exerly.xcodeproj" -scheme Exerly -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath "$OUT/DerivedData" \
  "CURRENT_PROJECT_VERSION=$BUILD" "MARKETING_VERSION=$VERSION" \
  "EXERLY_API_BASE_URL=$API_URL" "EXERLY_BUILD_ENVIRONMENT=$RELEASE_ENVIRONMENT" \
  "${SIGN_ARGS[@]}" archive > "$OUT/archive.log" 2>&1 || {
    tail -35 "$OUT/archive.log"; exit 1;
  }
CHECK_ARGS=()
[[ "$RELEASE_ENVIRONMENT" != staging ]] || CHECK_ARGS+=(--internal-staging)
[[ "$MODE" != --dry-run ]] || CHECK_ARGS+=(--unsigned)
python3 "$ROOT/scripts/release_checks.py" "$ARCHIVE" --version "$VERSION" --build "$BUILD" ${CHECK_ARGS[@]+"${CHECK_ARGS[@]}"}
if [[ "$MODE" == --dry-run ]]; then
  echo "Unsigned archive: $ARCHIVE"
  exit 0
fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/exportOptions.plist" \
  -exportPath "$OUT/export" > "$OUT/export.log" 2>&1 || { tail -35 "$OUT/export.log"; exit 1; }
[[ "$MODE" != --archive ]] || { echo "Signed archive and IPA: $OUT"; exit 0; }

# App records must already exist. The API cannot create them.
node "$ROOT/scripts/asc.mjs" status > "$OUT/asc-before-upload.json"
ISSUER="$(tr -d '[:space:]' < "$HOME/private_keys/asc-issuer-id.txt")"
API_PRIVATE_KEYS_DIR="$HOME/private_keys" xcrun altool --upload-app --type ios \
  --file "$OUT/export/Exerly.ipa" --apiKey 4Z7KFJ8DWZ --apiIssuer "$ISSUER" > "$OUT/upload.log" 2>&1 || {
    tail -30 "$OUT/upload.log"; exit 1;
  }
echo "Uploaded Exerly $VERSION ($BUILD). Processing and internal assignment are separate checks."
echo "Check: node $ROOT/scripts/asc.mjs status"
echo "After processing: node $ROOT/scripts/asc.mjs internal $BUILD"
