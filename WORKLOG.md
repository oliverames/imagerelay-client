# Worklog

## 2026-04-30 - Local beta wipe and repo purge

**What changed**: Removed the local `/Applications` beta app, beta backup copies, release export directories, Image Relay-specific app containers, app group data, CloudStorage mount, and the lingering DerivedData File Provider registration from this Mac. Deleted the GitHub prerelease and tag `v1.0.0-beta.1`. Rewrote git history to purge `build/` and `.codex-backups/`, then force-pushed the cleaned `main` branch.

**Decisions made**: Kept the new Developer ID release scripts and worklog trail in the repo, but treated all beta artifacts and repo-local key copies as disposable after explicit approval. Left the 1Password-managed App Store Connect key alone, even though it should still be considered exposed and rotated later.

**Left off at**: The machine is back to a clean slate for ImageRelayClient, with no registered File Provider extension and no installed beta build. The repo is ready for a fresh clean packaging and install verification pass before any future beta release.

**Open questions**: Still open: rotate the App Store Connect API key when convenient. Still open: run a fresh end-to-end Beta 2 smoke packaging and install pass from the cleaned state before creating another release.

---

## 2026-04-30 - Developer ID release workflow fixed for Beta 2

**What changed**: Built and verified a clean Developer ID release path outside the repo's iCloud-synced tree. Added `scripts/ensure-developer-id-profiles.py` to create or reuse the explicit App Store Connect bundle IDs for `com.oliverames.imagerelay-client` and `com.oliverames.imagerelay-client.fileprovider`, create `MAC_APP_DIRECT` Developer ID provisioning profiles for both targets, and install those profiles locally. Added `scripts/build-developer-id-release.sh` to run `xcodegen`, archive to `/tmp`, manually export with the correct Developer ID certificate and profile names, notarize and staple the app zip, create a DMG from the stapled app, notarize and staple the DMG, and run `codesign --verify --deep --strict`, `spctl`, and `stapler validate` checks. The script also supports `--smoke-install`, which replaces `/Applications/ImageRelayClient.app` from the notarized DMG and verifies both the host app process and embedded `FileProviderExtension` process launch.

**Verification**: Manual export using the new `MAC_APP_DIRECT` profiles succeeded from `/tmp`, with both the app and File Provider extension signed by `Developer ID Application: Oliver Ames (PV3W52NDZ3)` and embedding the new explicit Developer ID provisioning profiles rather than the previous Xcode-managed `Mac Team Provisioning Profile: *`. The exported app passed `codesign --verify --deep --strict`. The app zip notarization was accepted and stapled, then the DMG notarization was accepted and stapled. The installed `/Applications/ImageRelayClient.app` now passes `spctl -a -vv` as `Notarized Developer ID`, and launching it starts both `/Applications/ImageRelayClient.app/Contents/MacOS/ImageRelayClient` and `/Applications/ImageRelayClient.app/Contents/PlugIns/FileProviderExtension.appex/Contents/MacOS/FileProviderExtension`. The active config remains restricted to selected folder ID `2907644`, which maps to `Oliver's Stuff`.

**Repo hygiene**: Added `.gitignore` entries for `build/` and `.codex-backups/` so future release artifacts and local backups stay out of source control. The repo-local `build/release-1.0.0-beta.1/AuthKey.p8` copy and related beta artifact trees were deleted after explicit approval, while the 1Password-managed system key remains untouched. The App Store Connect API key should still be treated as exposed and revoked/reissued. Git history was rewritten locally to purge the old committed `build/` and `.codex-backups/` copies from every ref.

## 2026-04-29 - Beta continuation after 1.0.0 BETA 1

**What changed**: Added `BETA_TESTING.md` with the practical tester checklist for first launch, credentials, selected-folder sync, remote discovery, upload, download-on-open, pause/resume, quit/relaunch, domain reset, file operations, bad API key, network failure, and diagnostics export. Fixed the Finder placeholder date bug by parsing Image Relay `updated_on` metadata into `RemoteFile`/`RemoteFolder`, persisting it on `TrackedItem`, migrating the sync database to `v4`, and returning it through `FileProviderItem.contentModificationDate`. Added focused model/database tests for date parsing and persistence. Added Advanced settings "Export Diagnostics", which writes sanitized config, recent activity, sync progress, File Provider domain status, and recent ImageRelayClient subsystem logs to a user-chosen folder without exporting API keys.

**Verification**: `swift test --package-path ImageRelayKit` passes with 44 tests. `xcodebuild build -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` succeeds. `xcodegen generate` was run after adding `DiagnosticsExporter.swift`; `Project.yml` now explicitly keeps the extension version/build fields tied to `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.

**Release DMG smoke result**: Downloaded GitHub prerelease `v1.0.0-beta.1` DMG and verified the SHA-256 digest matched GitHub's asset digest (`e1279673de7ea4894e5615962474d3363906f21320e08218bce81edcdcc4a77d`). `spctl` accepts the DMG and mounted app as notarized Developer ID from Oliver Ames. Installing the released app from the DMG failed to launch: macOS blocked the embedded File Provider extension with AMFI `No matching profile found` for restricted entitlements `com.apple.developer.team-identifier` and `keychain-access-groups`. The released app and appex contain an Xcode-managed `Mac Team Provisioning Profile: *` development profile with provisioned devices even though the binaries are Developer ID signed. Also observed `codesign --deep --strict` failure because `com.apple.FinderInfo` xattrs are present on the embedded appex/bundles. The previous `/Applications/ImageRelayClient.app` was backed up before install and restored after the failed launch; the failed release install was moved to `~/Applications/Codex Backups/ImageRelayClient.app.v1.0.0-beta.1.failed-launch`.

**Left off at**: Live smoke testing against Image Relay did not proceed because the released DMG cannot launch its File Provider extension. No File Provider domain reset was attempted and no Image Relay folder content was touched. When the release packaging is fixed, restrict all live Finder/Image Relay smoke activity to the selected `Oliver's Stuff` folder only.

**Open questions**: Need a source-controlled release/export workflow that produces Developer ID signed/notarized DMGs without embedding development provisioning profiles or FinderInfo xattrs.

---

## 2026-04-29 - 1.0.0 BETA 1 release

**What changed**: Finished the native macOS ImageRelayClient beta and published GitHub prerelease `v1.0.0-beta.1`. Added the Icon Composer source asset under `ImageRelayIcon.icon`, generated a standard `AppIcon.appiconset` so macOS emits `AppIcon.icns`, moved the host app to marketing version `1.0.0`, and made the File Provider extension inherit the shared version/build values. Added a hidden `--reset-file-provider-domain` maintenance launch argument and a visible Advanced settings "Reset Finder Sync" button so the signed host app can remove/re-add the local File Provider domain.

**Decisions made**: Kept the Icon Composer `.icon` package bundled as source material, but generated a normal macOS app icon set because the `.icon` package alone compiled into `Assets.car` without producing `CFBundleIconFile`/`AppIcon.icns`. Kept the upload completion path simple: trust the final chunk response when it includes `finished` and `asset_id`, with one immediate upload-job fallback fetch if that response is incomplete.

**Left off at**: Released DMG is at GitHub release `v1.0.0-beta.1`, attached with checksum. Local File Provider domain was reset and verified against the live Image Relay account. Oliver's Stuff now shows remote-only files plus the local two-way upload in Finder. Local untracked `build/` and `.codex-backups/20260429/` remain intentionally outside git.

**Open questions**: Still open: delete temporary local notarization key copy at `build/release-1.0.0-beta.1/AuthKey.p8` after explicit confirmation. Still open: dates in Finder currently show Dec 31, 1969 for remote placeholder files because item date metadata is not yet mapped to a useful Finder date.

---

## 2026-04-07 -- Python removal, sync gap implementations, merged to main

**What changed**: Removed all Python implementation; project is now Swift-only. Merged `feature/native-macos-rebuild` into main and force-pushed after scrubbing 226MB GRDB pack file from git history with `git-filter-repo`. Implemented all remaining sync feature gaps:

- **Remote deletion propagation**: `Enumerator.fetchItems()` now diffs remote identifier set against `db.children(of:)` and returns deleted identifiers. Only `enumerateChanges` reports deletions to the File Provider; `enumerateItems` ignores them (correct per Apple API contract).
- **Folder filtering (UI)**: `FoldersSettingsView` replaced pin toggles with sync toggles backed by `AppConfiguration.selectedFolderIDs`. Empty selection = all folders sync. UI shows "X of Y selected" when a subset is chosen.
- **Conflict copy preservation**: When content version mismatch is detected in `modifyItem`, local edits are uploaded to Image Relay as a new asset with a conflict name (`filename (conflict copy YYYY-MM-DD HH:MM:SS).ext`) before re-fetching the canonical remote version. Both copies appear in Finder on next enumeration.
- **Folder move emulation**: Folder renames-with-parent-change are emulated via create-new → move-children → delete-original sequence, since the Image Relay API has no direct folder-move endpoint.
- **Progress tracking (totalSteps)**: Added `beginOperation()` helper that increments `totalSteps` on each sync op, reset when transitioning idle→syncing. Progress bar now shows live "X of Y" rather than indeterminate.
- **Retry-After honoring**: `APIClient.executeRaw` now inspects `lastError` for `.rateLimited(retryAfter:)` and uses the server-specified delay (capped at `maxRetryDelay`) instead of exponential backoff.
- **`TrackedItem.isPinned` removed**: Folder selection moved entirely to `AppConfiguration.selectedFolderIDs`. DB v3 migration drops the column.

**Decisions made**:
- **Conflict copy lives in IR, not just local**: Uploading the conflict copy to Image Relay as a new file rather than saving it locally means both versions appear in Finder naturally and the user can decide what to keep. Neither version is silently discarded.
- **Folder filtering is visibility, not availability**: Unselected folders don't appear in Finder but their API data is still fetched; they're filtered client-side at the root enumerator. This avoids a gap where child folders could accidentally inherit an unselected parent.
- **Folder move emulation is non-atomic**: Move-via-recreate is inherently lossy if the process is interrupted mid-sequence. Accepted this limitation -- atomic folder move would require IR API support.
- **`selectedFolderIDs` semantics**: Empty array = all sync. Toggling on a subset fills the set with all folder IDs minus the deselected ones; toggling all back on reverts to empty. Stored in `config.json`, not the DB.

**Left off at**:
- Still open: Never tested with real Image Relay credentials. No actual sync run against the live account; API key, domain registration, and enumeration all untested end-to-end.
- Still open: `move_file` API -- unknown whether `folder_ids` still expects an array of strings in v2.
- Conflict copy upload uses a full new upload job (not a file version). The conflict file lands in the same folder as the original but has no relationship to the original in IR. User must manually delete it after resolving.
- `beginOperation()` increments `totalSteps` but `completedSteps` increment happens in `incrementProgress()` -- verify these stay in sync if an operation errors partway through.

**Open questions**:
- Will the File Provider extension correctly load the app group container when launched outside of Xcode?
- The macOS 26 `MenuBarExtra .window` style renders with system menu chrome -- is there a way to override for a more custom look?

---

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
