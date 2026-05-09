#!/usr/bin/env bash

set -euo pipefail

BASE_URL="${IMAGE_RELAY_BASE_URL:-https://api.imagerelay.com/api/v2}"
REMOTE_FOLDER_ID="${IMAGE_RELAY_TEST_FOLDER_ID:-2907644}"
SYNC_FOLDER_PATH="${IMAGE_RELAY_TEST_FOLDER_PATH:-}"
TIMEOUT_SECONDS="${IMAGE_RELAY_TEST_TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${IMAGE_RELAY_TEST_POLL_SECONDS:-5}"
RUN_LARGE_FILE="${IMAGE_RELAY_TEST_LARGE_FILE:-1}"
APP_BUNDLE_ID="com.oliverames.imagerelay-client"

if [[ -z "$SYNC_FOLDER_PATH" ]]; then
  SYNC_FOLDER_PATH="$HOME/Library/CloudStorage/ImageRelay-ImageRelay/Oliver's Stuff"
fi

usage() {
  cat <<'EOF'
Usage: scripts/run-live-sync-matrix.sh [--folder-id <id>] [--folder-path <path>] [--timeout <seconds>] [--skip-large]

Runs a live, destructive sync smoke test using uniquely named temporary files.
Defaults are scoped to Oliver's Stuff (folder 2907644). The script verifies:
  - local file create uploads remotely
  - local file modify updates remote size
  - local file rename updates the remote filename
  - local file move updates the remote parent folder
  - local file delete removes the remote file
  - zero-byte file create/delete
  - 6 MB file create/delete, unless --skip-large is passed
  - local folder create, rename, and move update remote folders

Set IMAGE_RELAY_API_KEY to avoid reading the API key from 1Password.
EOF
}

while (($# > 0)); do
  case "$1" in
    --folder-id)
      REMOTE_FOLDER_ID="${2:-}"
      shift 2
      ;;
    --folder-path)
      SYNC_FOLDER_PATH="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --skip-large)
      RUN_LARGE_FILE=0
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

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 69
  fi
}

for tool in python3 op open osascript pgrep; do
  require_command "$tool"
done

if [[ -z "${IMAGE_RELAY_API_KEY:-}" ]]; then
  IMAGE_RELAY_API_KEY="$(op read 'op://Development/Image Relay API Key/credential')"
fi
export IMAGE_RELAY_API_KEY BASE_URL REMOTE_FOLDER_ID

if [[ ! -d "$SYNC_FOLDER_PATH" ]]; then
  echo "Sync folder does not exist: $SYNC_FOLDER_PATH" >&2
  exit 66
fi

TMP_DIR="$(mktemp -d /tmp/imagerelay-live-matrix.XXXXXX)"
API_HELPER="$TMP_DIR/api.py"
PREFIX="Codex-ReleaseLiveMatrix-$(date +%Y%m%d-%H%M%S)-$$"
CREATED_NAMES=()
CREATED_FOLDER_NAMES=()
LOCAL_PATHS=()
LOCAL_DIRS=()

cleanup() {
  set +e
  for local_path in "${LOCAL_PATHS[@]:-}"; do
    [[ -e "$local_path" ]] && rm -f "$local_path"
  done
  for local_dir in "${LOCAL_DIRS[@]:-}"; do
    [[ -e "$local_dir" ]] && rm -rf "$local_dir"
  done
  for name in "${CREATED_NAMES[@]:-}"; do
    python3 "$API_HELPER" delete-name "$name" >/dev/null 2>&1 || true
  done
  for name in "${CREATED_FOLDER_NAMES[@]:-}"; do
    python3 "$API_HELPER" delete-folder-name "$REMOTE_FOLDER_ID" "$name" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > "$API_HELPER" <<'PY'
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = os.environ["BASE_URL"].rstrip("/")
API_KEY = os.environ["IMAGE_RELAY_API_KEY"]
FOLDER_ID = os.environ["REMOTE_FOLDER_ID"]

try:
    import certifi
    SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())
except Exception:
    SSL_CONTEXT = ssl.create_default_context()


def request(method, path, body=None):
    data = None
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Accept": "application/json",
        "User-Agent": "ImageRelayClientLiveMatrix/1.0",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(f"{BASE_URL}{path}", data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30, context=SSL_CONTEXT) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise SystemExit(f"{method} {path} failed with HTTP {error.code}: {detail}")
    return json.loads(raw.decode("utf-8")) if raw else None


def files(folder_id=FOLDER_ID):
    items = []
    for page in range(1, 11):
        query = urllib.parse.urlencode({"recursive": "false", "per_page": "100", "page": str(page)})
        response = request("GET", f"/folders/{folder_id}/files.json?{query}") or []
        if isinstance(response, dict):
            page_items = response.get("files") or []
        else:
            page_items = response
        items.extend(page_items)
        if len(page_items) < 100:
            break
    return items


def folders(parent_id):
    items = []
    for page in range(1, 11):
        query = urllib.parse.urlencode({"per_page": "100", "page": str(page)})
        response = request("GET", f"/folders/{parent_id}/children?{query}") or []
        if isinstance(response, dict):
            page_items = response.get("folders") or []
        else:
            page_items = response
        items.extend(page_items)
        if len(page_items) < 100:
            break
    return items


def find_name(name, folder_id=FOLDER_ID):
    for item in files(folder_id):
        item_name = item.get("filename") or item.get("name")
        if item_name == name and not item.get("deleted", False):
            return item
    return None


def find_folder(parent_id, name):
    for item in folders(parent_id):
        if item.get("name") == name and not item.get("deleted", False):
            return item
    return None


command = sys.argv[1]
if command == "find-name":
    item = find_name(sys.argv[2])
    print(json.dumps(item or {}))
    sys.exit(0 if item else 1)
if command == "assert-size":
    item = find_name(sys.argv[2])
    expected = int(sys.argv[3])
    if item and int(item.get("file_size") or item.get("size") or 0) == expected:
        print(json.dumps(item))
        sys.exit(0)
    sys.exit(1)
if command == "assert-size-in-folder":
    item = find_name(sys.argv[3], sys.argv[2])
    expected = int(sys.argv[4])
    if item and int(item.get("file_size") or item.get("size") or 0) == expected:
        print(json.dumps(item))
        sys.exit(0)
    sys.exit(1)
if command == "assert-absent":
    sys.exit(0 if find_name(sys.argv[2]) is None else 1)
if command == "assert-absent-in-folder":
    sys.exit(0 if find_name(sys.argv[3], sys.argv[2]) is None else 1)
if command == "delete-name":
    deleted = 0
    for item in files():
        item_name = item.get("filename") or item.get("name")
        if item_name == sys.argv[2] and not item.get("deleted", False):
            request("DELETE", f"/files/{item['id']}.json")
            deleted += 1
    print(deleted)
    sys.exit(0)
if command == "folder-id":
    item = find_folder(sys.argv[2], sys.argv[3])
    if item:
        print(item["id"])
        sys.exit(0)
    sys.exit(1)
if command == "assert-folder-absent":
    sys.exit(0 if find_folder(sys.argv[2], sys.argv[3]) is None else 1)
if command == "delete-folder-name":
    deleted = 0
    item = find_folder(sys.argv[2], sys.argv[3])
    if item:
        request("DELETE", f"/folders/{item['id']}.json")
        deleted += 1
    print(deleted)
    sys.exit(0)

raise SystemExit(f"Unknown command: {command}")
PY

wait_for_size() {
  local name="$1"
  local size="$2"
  local elapsed=0
  while ((elapsed <= TIMEOUT_SECONDS)); do
    if python3 "$API_HELPER" assert-size "$name" "$size" >/dev/null 2>&1; then
      echo "Verified remote file: $name ($size bytes)"
      return 0
    fi
    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
  done
  echo "Timed out waiting for remote file $name to reach $size bytes." >&2
  return 1
}

wait_for_size_in_folder() {
  local folder_id="$1"
  local name="$2"
  local size="$3"
  local elapsed=0
  while ((elapsed <= TIMEOUT_SECONDS)); do
    if python3 "$API_HELPER" assert-size-in-folder "$folder_id" "$name" "$size" >/dev/null 2>&1; then
      echo "Verified remote file in folder $folder_id: $name ($size bytes)"
      return 0
    fi
    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
  done
  echo "Timed out waiting for remote file $name in folder $folder_id to reach $size bytes." >&2
  return 1
}

wait_for_absent() {
  local name="$1"
  local elapsed=0
  while ((elapsed <= TIMEOUT_SECONDS)); do
    if python3 "$API_HELPER" assert-absent "$name" >/dev/null 2>&1; then
      echo "Verified remote deletion: $name"
      return 0
    fi
    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
  done
  echo "Timed out waiting for remote deletion of $name." >&2
  return 1
}

wait_for_absent_in_folder() {
  local folder_id="$1"
  local name="$2"
  local elapsed=0
  while ((elapsed <= TIMEOUT_SECONDS)); do
    if python3 "$API_HELPER" assert-absent-in-folder "$folder_id" "$name" >/dev/null 2>&1; then
      echo "Verified remote deletion in folder $folder_id: $name"
      return 0
    fi
    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
  done
  echo "Timed out waiting for remote deletion of $name in folder $folder_id." >&2
  return 1
}

wait_for_folder() {
  local parent_id="$1"
  local name="$2"
  local elapsed=0
  local result_file="$TMP_DIR/folder-id.txt"
  while ((elapsed <= TIMEOUT_SECONDS)); do
    if python3 "$API_HELPER" folder-id "$parent_id" "$name" >"$result_file" 2>/dev/null; then
      cat "$result_file"
      return 0
    fi
    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
  done
  echo "Timed out waiting for remote folder $name under folder $parent_id." >&2
  return 1
}

wait_for_folder_absent() {
  local parent_id="$1"
  local name="$2"
  local elapsed=0
  while ((elapsed <= TIMEOUT_SECONDS)); do
    if python3 "$API_HELPER" assert-folder-absent "$parent_id" "$name" >/dev/null 2>&1; then
      echo "Verified remote folder absent under $parent_id: $name"
      return 0
    fi
    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
  done
  echo "Timed out waiting for remote folder $name under folder $parent_id to disappear." >&2
  return 1
}

ensure_app_running() {
  if ! pgrep -f "/Applications/Image Relay.app/Contents/MacOS/Image Relay" >/dev/null 2>&1; then
    open -b "$APP_BUNDLE_ID"
    sleep 3
  fi
}

write_file() {
  local name="$1"
  local contents="$2"
  local path="$SYNC_FOLDER_PATH/$name"
  printf '%s' "$contents" > "$path"
  LOCAL_PATHS+=("$path")
  CREATED_NAMES+=("$name")
}

remove_file_and_wait() {
  local name="$1"
  local path="$SYNC_FOLDER_PATH/$name"
  for attempt in 1 2 3; do
    [[ ! -e "$path" ]] && break
    osascript - "$path" <<'OSA' >/dev/null
on run argv
  set targetFile to POSIX file (item 1 of argv)
  tell application "Finder" to delete targetFile
end run
OSA
    sleep 2
  done
  if [[ -e "$path" ]]; then
    echo "Finder did not remove local file: $path" >&2
    return 1
  fi
  wait_for_absent "$name"
}

ensure_app_running

echo "Running live sync matrix in: $SYNC_FOLDER_PATH"
echo "Remote folder ID: $REMOTE_FOLDER_ID"

small_name="$PREFIX-create-modify-delete.txt"
write_file "$small_name" "release-create"
small_path="$SYNC_FOLDER_PATH/$small_name"
wait_for_size "$small_name" 14
printf 'release-create-modified' > "$small_path"
wait_for_size "$small_name" 23
remove_file_and_wait "$small_name"

rename_old_name="$PREFIX-rename-old.txt"
rename_new_name="$PREFIX-rename-new.txt"
write_file "$rename_old_name" "release-rename"
rename_old_path="$SYNC_FOLDER_PATH/$rename_old_name"
rename_new_path="$SYNC_FOLDER_PATH/$rename_new_name"
wait_for_size "$rename_old_name" 14
mv "$rename_old_path" "$rename_new_path"
LOCAL_PATHS+=("$rename_new_path")
CREATED_NAMES+=("$rename_new_name")
wait_for_absent "$rename_old_name"
wait_for_size "$rename_new_name" 14
remove_file_and_wait "$rename_new_name"

zero_name="$PREFIX-zero-byte.txt"
zero_path="$SYNC_FOLDER_PATH/$zero_name"
: > "$zero_path"
LOCAL_PATHS+=("$zero_path")
CREATED_NAMES+=("$zero_name")
wait_for_size "$zero_name" 0
remove_file_and_wait "$zero_name"

if [[ "$RUN_LARGE_FILE" -eq 1 ]]; then
  large_name="$PREFIX-large-6mb.bin"
  large_path="$SYNC_FOLDER_PATH/$large_name"
  dd if=/dev/urandom of="$large_path" bs=1048576 count=6 status=none
  LOCAL_PATHS+=("$large_path")
  CREATED_NAMES+=("$large_name")
  wait_for_size "$large_name" 6291456
  remove_file_and_wait "$large_name"
else
  echo "Skipping large-file upload check."
fi

source_folder="$PREFIX-source"
destination_folder="$PREFIX-destination"
folder_to_rename="$PREFIX-folder-old"
folder_renamed="$PREFIX-folder-new"
folder_to_move="$PREFIX-folder-to-move"

mkdir "$SYNC_FOLDER_PATH/$source_folder" "$SYNC_FOLDER_PATH/$destination_folder" "$SYNC_FOLDER_PATH/$folder_to_rename"
LOCAL_DIRS+=("$SYNC_FOLDER_PATH/$source_folder" "$SYNC_FOLDER_PATH/$destination_folder" "$SYNC_FOLDER_PATH/$folder_to_rename")
CREATED_FOLDER_NAMES+=("$source_folder" "$destination_folder" "$folder_to_rename" "$folder_renamed")

source_folder_id="$(wait_for_folder "$REMOTE_FOLDER_ID" "$source_folder")"
destination_folder_id="$(wait_for_folder "$REMOTE_FOLDER_ID" "$destination_folder")"
rename_folder_id="$(wait_for_folder "$REMOTE_FOLDER_ID" "$folder_to_rename")"

mv "$SYNC_FOLDER_PATH/$folder_to_rename" "$SYNC_FOLDER_PATH/$folder_renamed"
LOCAL_DIRS+=("$SYNC_FOLDER_PATH/$folder_renamed")
renamed_folder_id="$(wait_for_folder "$REMOTE_FOLDER_ID" "$folder_renamed")"
wait_for_folder_absent "$REMOTE_FOLDER_ID" "$folder_to_rename"
if [[ "$rename_folder_id" != "$renamed_folder_id" ]]; then
  echo "Folder rename changed the remote folder ID ($rename_folder_id -> $renamed_folder_id)." >&2
  exit 1
fi

move_file_name="$PREFIX-move-between-folders.txt"
move_file_source_path="$SYNC_FOLDER_PATH/$source_folder/$move_file_name"
move_file_destination_path="$SYNC_FOLDER_PATH/$destination_folder/$move_file_name"
printf 'release-file-move' > "$move_file_source_path"
LOCAL_PATHS+=("$move_file_source_path" "$move_file_destination_path")
CREATED_NAMES+=("$move_file_name")
wait_for_size_in_folder "$source_folder_id" "$move_file_name" 17
mv "$move_file_source_path" "$move_file_destination_path"
wait_for_absent_in_folder "$source_folder_id" "$move_file_name"
wait_for_size_in_folder "$destination_folder_id" "$move_file_name" 17
osascript - "$move_file_destination_path" <<'OSA' >/dev/null
on run argv
  set targetFile to POSIX file (item 1 of argv)
  tell application "Finder" to delete targetFile
end run
OSA
wait_for_absent_in_folder "$destination_folder_id" "$move_file_name"

mkdir "$SYNC_FOLDER_PATH/$source_folder/$folder_to_move"
LOCAL_DIRS+=("$SYNC_FOLDER_PATH/$source_folder/$folder_to_move" "$SYNC_FOLDER_PATH/$destination_folder/$folder_to_move")
CREATED_FOLDER_NAMES+=("$folder_to_move")
move_folder_id="$(wait_for_folder "$source_folder_id" "$folder_to_move")"
mv "$SYNC_FOLDER_PATH/$source_folder/$folder_to_move" "$SYNC_FOLDER_PATH/$destination_folder/$folder_to_move"
moved_folder_id="$(wait_for_folder "$destination_folder_id" "$folder_to_move")"
wait_for_folder_absent "$source_folder_id" "$folder_to_move"
if [[ "$move_folder_id" != "$moved_folder_id" ]]; then
  echo "Folder move changed the remote folder ID ($move_folder_id -> $moved_folder_id)." >&2
  exit 1
fi

echo "Live sync matrix passed."
