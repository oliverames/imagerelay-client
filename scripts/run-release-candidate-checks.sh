#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-1.1.1}"
RUN_LIVE_SYNC="${RUN_LIVE_SYNC:-0}"
RUN_PACKAGE="${RUN_PACKAGE:-0}"
XCODE_CLONED_SOURCE_PACKAGES_DIR="${XCODE_CLONED_SOURCE_PACKAGES_DIR:-}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 69
  fi
}

for tool in git swift xcodegen xcodebuild; do
  require_command "$tool"
done

cd "$ROOT_DIR"

XCODE_PACKAGE_ARGS=()
if [[ -n "$XCODE_CLONED_SOURCE_PACKAGES_DIR" ]]; then
  XCODE_PACKAGE_ARGS=(
    -clonedSourcePackagesDirPath "$XCODE_CLONED_SOURCE_PACKAGES_DIR"
    -disableAutomaticPackageResolution
  )
fi

echo "Checking patch whitespace..."
git diff --check

echo "Running ImageRelayKit package tests..."
swift test --package-path ImageRelayKit

echo "Regenerating Xcode project..."
xcodegen generate

echo "Running Xcode scheme tests..."
xcodebuild test \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClient \
  -destination 'platform=macOS' \
  "${XCODE_PACKAGE_ARGS[@]}"

echo "Running unsigned app build..."
xcodebuild build \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClient \
  -destination 'platform=macOS' \
  "${XCODE_PACKAGE_ARGS[@]}" \
  CODE_SIGNING_ALLOWED=NO

echo "Running unsigned iOS simulator build..."
xcodebuild build \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClientiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17e' \
  "${XCODE_PACKAGE_ARGS[@]}" \
  CODE_SIGNING_ALLOWED=NO

if [[ "$RUN_LIVE_SYNC" == "1" ]]; then
  echo "Running live sync matrix..."
  scripts/run-live-sync-matrix.sh
fi

if [[ "$RUN_PACKAGE" == "1" ]]; then
  echo "Building signed notarized release..."
  scripts/build-developer-id-release.sh --version "$VERSION" --smoke-install
fi

echo "Release candidate checks passed."
