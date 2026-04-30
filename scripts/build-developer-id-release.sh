#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ImageRelayClient.xcodeproj"
SCHEME="ImageRelayClient"
TEAM_ID="PV3W52NDZ3"
APP_BUNDLE_ID="com.oliverames.imagerelay-client"
APPEX_BUNDLE_ID="com.oliverames.imagerelay-client.fileprovider"
DMG_SIGNING_ID="com.oliverames.imagerelay-client.dmg"
APP_PROFILE_NAME="ImageRelayClient Developer ID"
APPEX_PROFILE_NAME="ImageRelayClient FileProviderExtension Developer ID"

VERSION=""
OUTPUT_DIR=""
SMOKE_INSTALL=0

usage() {
  cat <<'EOF'
Usage: scripts/build-developer-id-release.sh --version <version> [--output-dir <dir>] [--smoke-install]

Build a Developer ID signed ImageRelayClient release outside the repo's iCloud tree,
ensure the required Developer ID provisioning profiles exist, notarize the app and DMG,
and run strict verification checks. Use --smoke-install to replace /Applications/ImageRelayClient.app
with the notarized DMG payload, launch it, and verify the File Provider extension process starts.
EOF
}

while (($# > 0)); do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --smoke-install)
      SMOKE_INSTALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "--version is required" >&2
  usage >&2
  exit 64
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 69
  fi
}

for tool in op python3 xcodegen xcodebuild xcrun hdiutil codesign spctl ditto shasum security pluginkit; do
  require_command "$tool"
done

python3 - <<'PY' >/dev/null
import jwt
PY

sanitize_name() {
  printf '%s' "$1" | tr -c '[:alnum:]._-/' '_'
}

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DEFAULT_OUTPUT_DIR="$ROOT_DIR/build/releases/$VERSION"
ARTIFACT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
ARTIFACT_DIR="$(cd "$(dirname "$ARTIFACT_DIR")" && pwd)/$(basename "$ARTIFACT_DIR")"
mkdir -p "$ARTIFACT_DIR"

STAGE_DIR="$(mktemp -d "/tmp/imagerelay-release.$(sanitize_name "$VERSION").XXXXXX")"
KEY_PATH="$STAGE_DIR/AuthKey.p8"
cleanup() {
  rm -f "$KEY_PATH"
}
trap cleanup EXIT

echo "Fetching App Store Connect key from 1Password..."
op document get --vault Development 'App Store Connect AuthKey (.p8)' --out-file "$KEY_PATH" >/dev/null
ASC_KEY_ID="$(op read 'op://Development/App Store Connect API Key/credential')"
ASC_ISSUER_ID="$(op read 'op://Development/App Store Connect API Key/Issuer ID')"
ASC_PROFILE_INSTALL_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"

echo "Ensuring Developer ID bundle IDs and provisioning profiles exist..."
ASC_KEY_PATH="$KEY_PATH" \
ASC_KEY_ID="$ASC_KEY_ID" \
ASC_ISSUER_ID="$ASC_ISSUER_ID" \
ASC_PROFILE_INSTALL_DIR="$ASC_PROFILE_INSTALL_DIR" \
python3 "$ROOT_DIR/scripts/ensure-developer-id-profiles.py" | tee "$ARTIFACT_DIR/profile-setup.log"

DEVELOPER_ID_APPLICATION_IDENTITY="$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application: .*\('"$TEAM_ID"'\)/ {print $2; exit}')"
if [[ -z "$DEVELOPER_ID_APPLICATION_IDENTITY" ]]; then
  echo "Unable to find a Developer ID Application identity for team $TEAM_ID" >&2
  exit 70
fi

echo "Generating Xcode project..."
(
  cd "$ROOT_DIR"
  xcodegen generate
)

ARCHIVE_PATH="$STAGE_DIR/ImageRelayClient.xcarchive"
DERIVED_DATA_PATH="$STAGE_DIR/DerivedData"
EXPORT_DIR="$STAGE_DIR/export"
EXPORT_OPTIONS_PLIST="$STAGE_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/ImageRelayClient.app"
APP_ZIP_PATH="$ARTIFACT_DIR/ImageRelayClient-$VERSION.app.zip"
DMG_ROOT="$STAGE_DIR/dmgroot"
DMG_PATH="$ARTIFACT_DIR/ImageRelayClient-$VERSION.dmg"
CHECKSUM_PATH="$ARTIFACT_DIR/ImageRelayClient-$VERSION.dmg.sha256"

cat >"$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>provisioningProfiles</key>
  <dict>
    <key>$APP_BUNDLE_ID</key>
    <string>$APP_PROFILE_NAME</string>
    <key>$APPEX_BUNDLE_ID</key>
    <string>$APPEX_PROFILE_NAME</string>
  </dict>
</dict>
</plist>
PLIST

echo "Archiving release build..."
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -archivePath "$ARCHIVE_PATH" | tee "$ARTIFACT_DIR/archive.log"

echo "Exporting Developer ID app..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" | tee "$ARTIFACT_DIR/export.log"

echo "Validating exported app before notarization..."
codesign --verify --deep --strict --verbose=4 "$APP_PATH" 2>&1 | tee "$ARTIFACT_DIR/codesign-exported-app.log"

echo "Notarizing app zip..."
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP_PATH"
xcrun notarytool submit "$APP_ZIP_PATH" \
  --key "$KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait | tee "$ARTIFACT_DIR/notary-app.log"

echo "Stapling app..."
xcrun stapler staple "$APP_PATH" | tee "$ARTIFACT_DIR/stapler-app.log"
xcrun stapler validate "$APP_PATH" | tee "$ARTIFACT_DIR/stapler-app-validate.log"
spctl -a -vv "$APP_PATH" 2>&1 | tee "$ARTIFACT_DIR/spctl-app.log"

echo "Preparing DMG..."
mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/ImageRelayClient.app"
ln -s /Applications "$DMG_ROOT/Applications"
if ! codesign --verify --deep --strict --verbose=4 "$DMG_ROOT/ImageRelayClient.app" >/dev/null 2>&1; then
  xattr -cr "$DMG_ROOT/ImageRelayClient.app"
fi
codesign --verify --deep --strict --verbose=4 "$DMG_ROOT/ImageRelayClient.app" 2>&1 | tee "$ARTIFACT_DIR/codesign-dmgroot-app.log"
hdiutil create -volname 'ImageRelayClient' -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH" | tee "$ARTIFACT_DIR/hdiutil.log"
codesign --sign "$DEVELOPER_ID_APPLICATION_IDENTITY" \
  --timestamp \
  -i "$DMG_SIGNING_ID" \
  "$DMG_PATH" 2>&1 | tee "$ARTIFACT_DIR/codesign-dmg-sign.log"
codesign --verify --strict --verbose=4 "$DMG_PATH" 2>&1 | tee "$ARTIFACT_DIR/codesign-dmg.log"

echo "Notarizing DMG..."
xcrun notarytool submit "$DMG_PATH" \
  --key "$KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait | tee "$ARTIFACT_DIR/notary-dmg.log"

echo "Stapling DMG..."
xcrun stapler staple "$DMG_PATH" | tee "$ARTIFACT_DIR/stapler-dmg.log"
xcrun stapler validate "$DMG_PATH" | tee "$ARTIFACT_DIR/stapler-dmg-validate.log"
spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH" 2>&1 | tee "$ARTIFACT_DIR/spctl-dmg.log"
shasum -a 256 "$DMG_PATH" | tee "$CHECKSUM_PATH"

if [[ "$SMOKE_INSTALL" -eq 1 ]]; then
  echo "Running smoke install from notarized DMG..."
  if pgrep -f '/Applications/ImageRelayClient.app/Contents/MacOS/ImageRelayClient' >/dev/null 2>&1; then
    osascript -e 'tell application id "com.oliverames.imagerelay-client" to quit' >/dev/null 2>&1 || true
    for _ in {1..10}; do
      if ! pgrep -f '/Applications/ImageRelayClient.app/Contents/MacOS/ImageRelayClient' >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi

  BACKUP_ROOT="$HOME/Applications/Codex Backups"
  mkdir -p "$BACKUP_ROOT"
  BACKUP_PATH=""
  MOUNT_OUTPUT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH")"
  MOUNT_POINT="$(printf '%s\n' "$MOUNT_OUTPUT" | awk '/\/Volumes\// {print $NF; exit}')"
  if [[ -e /Applications/ImageRelayClient.app ]]; then
    BACKUP_PATH="$BACKUP_ROOT/ImageRelayClient.app.$VERSION.smoke-$TIMESTAMP"
    mv /Applications/ImageRelayClient.app "$BACKUP_PATH"
  fi
  ditto "$MOUNT_POINT/ImageRelayClient.app" /Applications/ImageRelayClient.app
  hdiutil detach "$MOUNT_POINT" >/dev/null

  APP_PROCESS_PATTERN='/Applications/ImageRelayClient.app/Contents/MacOS/ImageRelayClient'
  APPEX_PROCESS_PATTERN='/Applications/ImageRelayClient.app/Contents/PlugIns/FileProviderExtension.appex/Contents/MacOS/FileProviderExtension'
  LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister'

  codesign --verify --deep --strict --verbose=4 /Applications/ImageRelayClient.app 2>&1 | tee "$ARTIFACT_DIR/codesign-installed-app.log"
  spctl -a -vv /Applications/ImageRelayClient.app 2>&1 | tee "$ARTIFACT_DIR/spctl-installed-app.log"

  wait_for_installed_extension_registration() {
    local pluginkit_output
    for _ in {1..15}; do
      "$LSREGISTER" -f -R -trusted /Applications/ImageRelayClient.app >/dev/null 2>&1 || true
      pluginkit_output="$(pluginkit -mvv -i "$APPEX_BUNDLE_ID" || true)"
      printf '%s\n' "$pluginkit_output" > "$ARTIFACT_DIR/pluginkit-installed-extension.log"
      if grep -q "$APPEX_BUNDLE_ID" <<<"$pluginkit_output"; then
        return 0
      fi
      sleep 1
    done
    return 1
  }

  if ! wait_for_installed_extension_registration; then
    cat "$ARTIFACT_DIR/pluginkit-installed-extension.log"
    echo "Smoke install failed: File Provider extension is not visible to pluginkit." >&2
    exit 1
  fi
  cat "$ARTIFACT_DIR/pluginkit-installed-extension.log"

  wait_for_app_process() {
    for _ in {1..30}; do
      if pgrep -f "$APP_PROCESS_PATTERN" >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
    return 1
  }

  has_file_provider_launch_evidence() {
    if pgrep -f "$APPEX_PROCESS_PATTERN" >/dev/null 2>&1; then
      return 0
    fi
    local fileprovider_log
    fileprovider_log="$(/usr/bin/log show --start "$SMOKE_LOG_START" --style compact \
      --predicate 'process == "fileproviderd"' 2>/dev/null || true)"
    grep -Eq 'com\.oliverames\.imagerelay-client\.fileprovider.*(began providing|fetch-event-stream|new enumerator|done executing|providing)' <<<"$fileprovider_log"
  }

  SMOKE_LOG_START="$(date '+%Y-%m-%d %H:%M:%S')"
  open -a /Applications/ImageRelayClient.app

  if ! wait_for_app_process; then
    echo "Smoke install failed: app process did not launch." >&2
    exit 1
  fi

  for _ in {1..15}; do
    if has_file_provider_launch_evidence; then
      break
    fi
    sleep 1
  done

  if ! has_file_provider_launch_evidence; then
    echo "File Provider extension process was not long-lived after normal launch; exercising clean-domain smoke path..."
    osascript -e 'tell application id "com.oliverames.imagerelay-client" to quit' >/dev/null 2>&1 || true
    for _ in {1..10}; do
      if ! pgrep -f "$APP_PROCESS_PATTERN" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    open -a /Applications/ImageRelayClient.app --args --reset-file-provider-domain
    sleep 5

    DOMAIN_ROOT="$(find "$HOME/Library/CloudStorage" -maxdepth 1 -type d -name 'ImageRelayClient-*' -print -quit 2>/dev/null || true)"
    if [[ -n "$DOMAIN_ROOT" ]]; then
      ls -la "$DOMAIN_ROOT" >/dev/null 2>&1 || true
    fi

    for _ in {1..20}; do
      if has_file_provider_launch_evidence; then
        break
      fi
      sleep 1
    done
  fi

  if ! has_file_provider_launch_evidence; then
    echo "Smoke install failed: File Provider extension did not launch or respond through fileproviderd." >&2
    exit 1
  fi

  if ! pgrep -f "$APP_PROCESS_PATTERN" >/dev/null 2>&1; then
    open -a /Applications/ImageRelayClient.app
    if ! wait_for_app_process; then
      echo "Smoke install failed: app process did not relaunch after File Provider smoke." >&2
      exit 1
    fi
  fi

  /usr/bin/log show --last 5m --style compact \
    --predicate '(process == "ImageRelayClient" OR process == "FileProviderExtension" OR process == "fileproviderd" OR subsystem == "com.oliverames.imagerelay-client" OR subsystem == "com.oliverames.imagerelay-client.fileprovider")' \
    >"$ARTIFACT_DIR/smoke-install.log"

  echo "Smoke install completed."
  if [[ -n "$BACKUP_PATH" ]]; then
    echo "Previous /Applications build backed up to: $BACKUP_PATH"
  fi
fi

cat <<EOF

Release artifacts created successfully.
Artifact directory: $ARTIFACT_DIR
Temporary staging directory: $STAGE_DIR
DMG: $DMG_PATH
EOF
