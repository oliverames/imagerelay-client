#!/usr/bin/env bash
# Update Casks/image-relay.rb with a new version + SHA-256 after a Developer ID
# release builds and notarizes successfully.
#
# Usage:
#   scripts/update-cask.sh --version 1.1.0 --dmg path/to/ImageRelayClient-1.1.0.dmg
#   scripts/update-cask.sh --version 1.1.0 --sha-file path/to/ImageRelayClient-1.1.0.dmg.sha256
#
# The script refuses to bump to a pre-release version (anything containing "-beta"
# or "-rc") so the Cask always tracks the latest stable. Pre-releases ride the
# Sparkle appcast instead.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK_PATH="$ROOT_DIR/Casks/image-relay.rb"

VERSION=""
DMG_PATH=""
SHA_FILE=""

usage() {
  cat <<'EOF'
Usage:
  scripts/update-cask.sh --version <version> --dmg <path>
  scripts/update-cask.sh --version <version> --sha-file <path>

Updates Casks/image-relay.rb in place. Refuses pre-release versions (-beta, -rc).
EOF
}

while (($# > 0)); do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --dmg)     DMG_PATH="${2:-}"; shift 2 ;;
    --sha-file) SHA_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "ERROR: --version is required" >&2
  usage >&2
  exit 64
fi

if [[ "$VERSION" == *-beta* || "$VERSION" == *-rc* || "$VERSION" == *-alpha* ]]; then
  echo "Skipping Cask update for pre-release version: $VERSION" >&2
  echo "(Pre-releases are distributed via Sparkle appcast, not Homebrew.)" >&2
  exit 0
fi

if [[ -n "$DMG_PATH" ]]; then
  if [[ ! -f "$DMG_PATH" ]]; then
    echo "ERROR: DMG not found at $DMG_PATH" >&2
    exit 66
  fi
  SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
elif [[ -n "$SHA_FILE" ]]; then
  if [[ ! -f "$SHA_FILE" ]]; then
    echo "ERROR: SHA file not found at $SHA_FILE" >&2
    exit 66
  fi
  SHA256="$(awk '{print $1}' "$SHA_FILE")"
else
  echo "ERROR: --dmg or --sha-file is required" >&2
  usage >&2
  exit 64
fi

if [[ ! "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "ERROR: Computed SHA-256 doesn't look right: $SHA256" >&2
  exit 65
fi

if [[ ! -f "$CASK_PATH" ]]; then
  echo "ERROR: Cask file missing at $CASK_PATH" >&2
  exit 66
fi

# Replace version and sha256 lines. Using a Python rewrite is safer than sed-in-place
# across macOS / Linux quirks and keeps the rest of the cask formatting identical.
python3 - "$CASK_PATH" "$VERSION" "$SHA256" <<'PY'
import pathlib
import re
import sys

cask_path, version, sha256 = sys.argv[1:4]
text = pathlib.Path(cask_path).read_text()

new_text, version_count = re.subn(
    r'(  version )"[^"]*"',
    f'\\1"{version}"',
    text,
    count=1,
)
new_text, sha_count = re.subn(
    r'(  sha256 )"[^"]*"',
    f'\\1"{sha256}"',
    new_text,
    count=1,
)

if version_count != 1 or sha_count != 1:
    raise SystemExit(
        f"Expected one version + one sha256 line; replaced version={version_count}, sha256={sha_count}"
    )

pathlib.Path(cask_path).write_text(new_text)
print(f"Updated cask to version={version} sha256={sha256}")
PY
