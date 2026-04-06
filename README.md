# ImageRelay Client

`ImageRelay Client` is a macOS-friendly desktop sync MVP for Image Relay.

This project intentionally reuses selected infrastructure ideas from Maestral:

- platform-aware app dirs
- INI-backed config management
- ordered / platform-specific file watching
- a lightweight SQLite wrapper / ORM
- a long-running daemon shell with launch-agent autostart
- a native macOS menu bar shell
- a sync core rewritten around the documented Image Relay API

It does not try to masquerade as a finished Dropbox-style Finder client yet. The goal of
this first pass is a solid CLI + daemon foundation with real upload, download, folder
sync, and state tracking.

## Current Capabilities

- Sync a configured local root with a configured Image Relay root folder
- Poll remote folders and files, then mirror them locally
- Watch the local filesystem and push creates / updates / deletes upstream
- Upload new assets using Image Relay upload jobs
- Upload new versions for changed files
- Download files through temporary quick links
- Persist remote-to-local mappings in SQLite
- Run in the foreground or as a background daemon
- Start on login with a launchd agent
- Run as a native macOS menu bar app with live status, recent activity, ETA, pause / resume controls, and login-item controls
- Respect `sync_upload` and `sync_download` direction flags
- Publish the last remote pull time and next scheduled remote pull into shared state
- Pause syncing for 30 minutes, 1 hour, until tomorrow at 9 AM local time, or indefinitely
- Select specific folders to sync via CLI (`folders list/select/show/clear`) or a native macOS folder picker dialog in the menu bar app

## Current Assumptions

- You provide an API key with enough permissions to read, create, update, move, and
  delete folders / files.
- You configure a single `remote_root_folder_id` to act as the sync root.
- You configure a global `default_file_type_id` for new uploads.
- Remote assets in multiple folders are mirrored with one downloaded file plus symlink
  aliases for the additional locations.

## Known Limitations

- Remote change detection is polling-based because the published docs do not expose a
  Dropbox-style cursor + longpoll sync feed.
- File rename operations are modeled as "upload new asset, then delete old asset"
  because the documented API does not expose a dedicated file rename endpoint.
- Folder moves across different parents are not implemented yet.
- Alias paths for multi-folder assets are managed as symlinks and are treated as
  download-managed, not upload-managed.
- Conflict handling is intentionally conservative: local conflicting content is backed up
  before the remote version is applied.

## Install

```bash
cd "/Users/oliverames/Desktop/ImageRelay Client"
python3 -m venv .venv
source .venv/bin/activate
pip install .
```

If you want to run directly from the source tree during development, prefix module
commands with `PYTHONPATH=src`, for example:

```bash
PYTHONPATH=src .venv/bin/python -m imagerelay_client simulate demo
```

## Configure

You can either pass the API key during init or set `IMAGERELAY_API_KEY` in your shell.

```bash
imagerelay-client init \
  --api-key "YOUR_API_KEY" \
  --local-root "~/Image Relay" \
  --remote-root-folder-id 123 \
  --default-file-type-id 456
```

Useful follow-ups:

```bash
imagerelay-client config show
imagerelay-client config set poll_interval_seconds 15
imagerelay-client sync once
imagerelay-client sync pause --for 1h
imagerelay-client sync resume
imagerelay-client daemon start
imagerelay-client daemon status
imagerelay-client autostart enable
imagerelay-client gui
imagerelay-client simulate demo
```

## Commands

- `imagerelay-client init`
- `imagerelay-client config show`
- `imagerelay-client config set KEY VALUE`
- `imagerelay-client sync once`
- `imagerelay-client sync status [--json-output]`
- `imagerelay-client sync pause [--for 30m|1h|tomorrow|indefinite]`
- `imagerelay-client sync resume`
- `imagerelay-client daemon run`
- `imagerelay-client daemon start`
- `imagerelay-client daemon stop`
- `imagerelay-client daemon status`
- `imagerelay-client autostart enable|disable|status`
- `imagerelay-client gui`
- `imagerelay-client simulate server`
- `imagerelay-client simulate demo`
- `imagerelay-client-gui`

## Data Locations

On macOS the client stores its data in:

- Config: `~/Library/Application Support/imagerelay-client/client.ini`
- State DB: `~/Library/Application Support/imagerelay-client/state.db`
- Rate-limit DB: `~/Library/Application Support/imagerelay-client/rate_limit.db`
- Runtime files: `~/Library/Application Support/imagerelay-client/client.pid` and `client.lock`
- Logs: `~/Library/Logs/imagerelay-client/client.log`

For isolated testing or parallel sandboxes, set `IMAGERELAY_CLIENT_HOME` to redirect
all config, runtime, database, and log files into a separate root directory.

## Local API Simulator

For manual testing, you can run a local Image Relay-compatible simulator:

```bash
imagerelay-client simulate server
```

That starts a mock API on `127.0.0.1:8765` by default, seeds sample folders and files,
and prints an `imagerelay-client init` command that points the client at the simulator.

If you want a one-shot end-to-end demo instead, run:

```bash
imagerelay-client simulate demo
```

That command starts the mock API, initializes the client in an isolated temp home,
proves download / upload / versioning / synced-file aliasing / deletion flows, and
leaves the temp workspace behind for inspection unless you pass `--cleanup`.

When the daemon is running, the menu bar app shows:

- whether the client is idle, syncing, or failed
- whether syncing is paused and when it will resume
- which phase is active
- approximate ETA for the current pass when enough progress is known
- the current file or folder being processed
- the last remote pull time and next scheduled auto-pull
- recent uploaded / downloaded / removed items

## End-To-End Proof

The test suite includes an end-to-end integration run against a local mock Image Relay
server. It exercises:

- initial remote download through a throttled quick link (`429` + `Retry-After`)
- synced multi-folder asset handling through a canonical download plus symlink alias
- daemon startup and shutdown
- local folder / file creation
- local file moves and folder renames mirrored upstream
- upload jobs for new assets
- version uploads for modified files
- remote folder / file creation and deletion
- download-only and upload-only modes
- timed and indefinite sync pause / resume behavior
- local file deletion mirrored upstream

For a documented support matrix against the Image Relay API, see [API_COMPATIBILITY.md](API_COMPATIBILITY.md).

Run it with:

```bash
python -m unittest discover -s tests -v
```

## User-Agent

Image Relay requires a `User-Agent` header. The default config uses a placeholder user
agent; you should update it to something that includes your real project URL or contact
email before using the client heavily.

## Credits

This project vendors and adapts a few infrastructure modules from Maestral, which is
MIT licensed. Maestral in turn vendors part of its config backend from Spyder under MIT.
The ImageRelay-specific API client and sync logic remain custom to this project.
