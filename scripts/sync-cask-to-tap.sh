#!/usr/bin/env bash
# Push Casks/image-relay.rb to the public Homebrew tap so `brew tap oliverames/tap`
# users get the new version. The tap repo lives at https://github.com/oliverames/homebrew-tap
# and contains a single Casks/ directory.
#
# Usage:
#   scripts/sync-cask-to-tap.sh [--tap-dir <path>] [--remote oliverames/homebrew-tap]
#
# By default the script:
#   1. Clones (or refreshes) the tap into a scratch path under /tmp
#   2. Copies the current Casks/image-relay.rb on top of the tap's copy
#   3. Commits with a "Update image-relay to <version>" message
#   4. Pushes to origin/main
#
# Skips the push if the tap copy is already byte-identical to ours.
#
# Requires: gh CLI authenticated (for clone via SSH or HTTPS-with-token).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK_PATH="$ROOT_DIR/Casks/image-relay.rb"
TAP_REMOTE="oliverames/homebrew-tap"
TAP_DIR=""

while (($# > 0)); do
  case "$1" in
    --tap-dir) TAP_DIR="${2:-}"; shift 2 ;;
    --remote)  TAP_REMOTE="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/sync-cask-to-tap.sh [--tap-dir <path>] [--remote oliverames/homebrew-tap]

Pushes the current Casks/image-relay.rb to the configured Homebrew tap repo.
EOF
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [[ ! -f "$CASK_PATH" ]]; then
  echo "ERROR: Cask file missing at $CASK_PATH" >&2
  exit 66
fi

CASK_VERSION="$(grep -E '^  version ' "$CASK_PATH" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [[ -z "$CASK_VERSION" ]]; then
  echo "ERROR: Couldn't parse version from $CASK_PATH" >&2
  exit 65
fi

if [[ -z "$TAP_DIR" ]]; then
  TAP_DIR="$(mktemp -d "/tmp/imagerelay-cask-sync.XXXXXX")"
  trap 'rm -rf "$TAP_DIR"' EXIT
  echo "Cloning $TAP_REMOTE into $TAP_DIR"
  git clone --depth 1 "https://github.com/$TAP_REMOTE.git" "$TAP_DIR"
else
  if [[ ! -d "$TAP_DIR/.git" ]]; then
    echo "ERROR: $TAP_DIR is not a git checkout" >&2
    exit 66
  fi
  git -C "$TAP_DIR" fetch origin
  git -C "$TAP_DIR" checkout main
  git -C "$TAP_DIR" pull --ff-only
fi

mkdir -p "$TAP_DIR/Casks"
DEST="$TAP_DIR/Casks/image-relay.rb"

if [[ -f "$DEST" ]] && cmp -s "$CASK_PATH" "$DEST"; then
  echo "Tap already up to date (version $CASK_VERSION). Nothing to push."
  exit 0
fi

cp "$CASK_PATH" "$DEST"
git -C "$TAP_DIR" add Casks/image-relay.rb
git -C "$TAP_DIR" commit -m "Update image-relay to $CASK_VERSION"
git -C "$TAP_DIR" push origin main

echo "Pushed image-relay $CASK_VERSION to $TAP_REMOTE"
