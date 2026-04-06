# Worklog

## 2026-04-06 -- Native macOS rebuild: complete File Provider app with SwiftUI

**What changed**: Built a complete native macOS rebuild of the Python sync client on `feature/native-macos-rebuild` branch (in `.worktrees/native-rebuild`). 17-task plan executed via subagent-driven development, then all 13 feature gaps from the Python version filled in:

- **ImageRelayKit** (Swift package, 30 unit tests passing): async/await `APIClient` with rate limiting + retry, GRDB-backed `SyncDatabase`, `RemoteFolder`/`RemoteFile`/`QuickLink`/`UploadJob` models, `ItemIdentifier` (folder-{id}/file-{id}), `AppConfiguration` with shared app group JSON, `SyncAnchor`, `ConflictResolver`, `SyncPauseState`, `SyncProgressState`.
- **FileProviderExtension**: full `NSFileProviderReplicatedExtension` impl - `Enumerator`, `FileProviderItem`, on-demand download via quick links, chunked uploads (5MB chunks), version uploads, folder/file create/rename/move/delete, `RemoteChangePoller` honoring sync direction flags and pause state, `.DS_Store` filtering, conflict detection via version mismatch.
- **ImageRelayClient host app**: `MenuBarExtra` with custom `MenuRowButtonStyle` (hover state), live status header (pulse animation when syncing), progress bar, recent activity, pause submenu (30m/1h/tomorrow/indefinite/resume), Settings window with 4 tabs (General/Folders/Activity/Advanced), `DomainManager` polling shared DB every 2s, `SMAppService` login item.
- **Project**: XcodeGen-generated Xcode project, both targets code-signed with team `PV3W52NDZ3`, app group `group.com.oliverames.imagerelay-client`, built and runs on macOS 26.4.

**Decisions made**:
- **macOS 26 SDK API changes discovered the hard way**: `fetchContents` lost its `Bool` parameter; `NSFileProviderItemProtocol` uses `itemIdentifier`/`parentItemIdentifier` (not `identifier`/`parentIdentifier`); `swift-tools-version` must be `6.2` for `.macOS(.v26)`; `.tabItem {}` modifier on `Settings { TabView { } }` creates duplicate tabs - must use the new `Tab("Title", systemImage:) { }` API.
- **Swift 6 strict concurrency in File Provider**: Completion handlers passed to `Task { }` closures need `nonisolated(unsafe) let completionHandler = completionHandler` because they're not `Sendable`. Class-level state captured in `Task` closures requires `@unchecked Sendable` on the class.
- **`.menuBarExtraStyle(.window)` doesn't auto-style**: Plain `Button` views inside still render as menu items. Built a custom `MenuRowButtonStyle` with `.onHover` for proper hover feedback.
- **Dropped multi-folder symlink aliases**: The Python app creates a canonical local file plus symlinks for files appearing in multiple folders. The File Provider model handles this naturally because the system enumerates per-folder; the same file ID just appears in multiple parent containers without symlinks.
- **`AppConfiguration.save` must create parent directory**: First-run on a fresh app group container can fail with "config.json doesn't exist" because the container directory itself isn't created until first write.
- **Skipped pushing to GitHub**: First scaffolding commit accidentally bundled `ImageRelayKit/.build/` (later removed in a follow-up commit) leaving a 226MB pack file in history. Push rejected by GitHub's 100MB file limit. Branch lives only locally for now; `git filter-repo` would be needed to scrub history before pushing.

**Left off at**:
- App is built, code-signed, and running. Menu bar popover and Settings window both render. Configuration save error is fixed.
- **Not yet verified by user after final fixes**: hover state on menu bar rows, duplicate tabs gone in Settings (need to use Tab API rebuild), Settings window comes to front when opened from menu.
- **Never tested with real Image Relay credentials**: API key not yet entered, File Provider domain not yet registered with the system, no actual sync run against the real Image Relay account.
- **`.build` history pollution**: Need to scrub the 226MB pack file from `feature/native-macos-rebuild` before this branch can be pushed to GitHub. Easiest path: install `git-filter-repo` and rewrite history to drop `ImageRelayKit/.build/` from all commits.

**Open questions**:
- Will the File Provider extension correctly load the app group container when launched outside of Xcode? The container path may differ between Debug builds and the user's actual home.
- The macOS 26 `MenuBarExtra .window` style still renders with system menu chrome (gray translucent background) - is there a way to override this for a more custom look like Tailscale/Bartender, or is this the intended Tahoe styling?
- The Image Relay `move_file` API expects `folder_ids` as an array of strings - is this still correct for v2, or has it changed since the Python client was last updated?

---

## 2026-04-06 -- Selective folder sync, recursive file fix, GUI folder picker

**What changed**: Added selective folder sync feature across all layers (config, sync engine, CLI, GUI). Users can now choose which folders to sync via `folders list/select/show/clear` CLI commands or a native macOS dialog in the menu bar app (Settings > Select Folders to Sync...). The sync engine filters both downloads and uploads to only include selected folders and their descendants.

Fixed a critical bug where `recursive=True` on `list_files()` never actually worked. Python's `bool` serialized as `"True"` (capital T) but the Image Relay API expects lowercase `"true"`. This meant the sync client was never fetching files from subfolders.

Added subfolder discovery: `list_folders()` only returns top-level folders, so subfolders are now discovered from file `folder_ids` and their metadata fetched individually via `get_folder()`. Changed the sync root from 1923998 (Brand Documents and Resources) to 1909821 (account root) to enable cross-folder selection.

When folders are selected, files are fetched from each selected folder directly instead of scanning the entire account root, which is much faster.

**Decisions made**:
- Include-list approach (not exclude-list) for folder selection. Empty list = sync all (backwards compatible).
- Ancestor folders are included in the allowed set for directory structure creation but NOT in upload prefixes, preventing accidental uploads to ancestor-only directories.
- The `.pth` editable install is broken with Python 3.14 (spaces in iCloud path). Using `PYTHONPATH` as workaround for now.
- Folder picker uses NSAlert with accessory scroll view (checkboxes) rather than a standalone NSWindow, matching the existing About dialog pattern.

**Left off at**:
- Sync is actively downloading Photography folder content (~35 files downloaded, hundreds more to go). First sync is slow due to 411+ subfolder metadata fetches; subsequent syncs will be fast.
- The folder picker loads slowly for large accounts because it fetches all files to discover subfolders. Could optimize by caching folder metadata in the database.
- Duplicate log lines appear (each log entry is doubled). Likely a dual-handler issue in logging_utils.py.
- The Python dock icon appears when running the GUI. Needs `LSUIElement` in an app bundle or `LSBackgroundOnly` to suppress.

**Open questions**:
- Should subfolder metadata be cached in the database to avoid re-fetching on every sync pass?
- Should the file fetching strategy change to fetch from each top-level subfolder individually (parallel) rather than from root?
- The editable install (.pth file) doesn't work with Python 3.14 on an iCloud path with spaces. Is this a Python bug or setuptools issue?

---
