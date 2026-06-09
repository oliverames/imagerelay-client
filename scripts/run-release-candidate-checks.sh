#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_PACKAGE="${RUN_PACKAGE:-0}"
XCODE_CLONED_SOURCE_PACKAGES_DIR="${XCODE_CLONED_SOURCE_PACKAGES_DIR:-}"
SWIFTPM_SCRATCH_PATH="${SWIFTPM_SCRATCH_PATH:-/tmp/imagerelay-client-swiftpm-rc}"

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

PROJECT_MARKETING_VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' Project.yml)"
if [[ -z "$PROJECT_MARKETING_VERSION" ]]; then
  echo "Project.yml MARKETING_VERSION could not be read." >&2
  exit 65
fi
VERSION="${1:-$PROJECT_MARKETING_VERSION}"

XCODE_PACKAGE_ARGS=()
if [[ -n "$XCODE_CLONED_SOURCE_PACKAGES_DIR" ]]; then
  XCODE_PACKAGE_ARGS=(
    -clonedSourcePackagesDirPath "$XCODE_CLONED_SOURCE_PACKAGES_DIR"
    -disableAutomaticPackageResolution
  )
fi

run_xcodebuild() {
  if ((${#XCODE_PACKAGE_ARGS[@]} > 0)); then
    xcodebuild "$@" "${XCODE_PACKAGE_ARGS[@]}"
  else
    xcodebuild "$@"
  fi
}

echo "Checking patch whitespace..."
git diff --check

echo "Running ImageRelayKit package tests..."
swift test --package-path ImageRelayKit --scratch-path "$SWIFTPM_SCRATCH_PATH"

echo "Regenerating Xcode project..."
xcodegen generate

echo "Running Xcode scheme tests..."
run_xcodebuild test \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClient \
  -destination 'platform=macOS'

echo "Running unsigned app build..."
run_xcodebuild build \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClient \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

echo "Running unsigned iOS simulator build..."
run_xcodebuild build \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClientiOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

if [[ "$RUN_PACKAGE" == "1" ]]; then
  echo "Building signed notarized release..."
  scripts/build-developer-id-release.sh --version "$VERSION" --smoke-install
fi

echo "Release candidate checks passed."
