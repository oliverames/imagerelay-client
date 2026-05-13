# ImageRelayClient Release Testing Checklist

Use this checklist with a signed release build from GitHub Releases, not a local Debug build. Record the app version, macOS version, Image Relay account, selected folder IDs, and whether the File Provider domain had to be reset.

## First Launch

- Open the downloaded DMG and verify macOS allows the app to launch without Gatekeeper warnings beyond the standard first-open confirmation.
- Drag Image Relay to Applications.
- Launch Image Relay from Applications.
- Confirm the menu bar icon appears.
- Open the menu bar item and confirm Settings opens.
- Confirm Check for Updates is present in the menu bar item.
- Confirm the Advanced tab shows Reset Finder Sync and Export Diagnostics.

## Credential Entry

- Open Settings > General.
- Enter a valid Image Relay API key.
- Choose the remote root folder and default file type if prompted.
- Close and reopen Settings.
- Confirm the saved settings persist.
- Confirm the API key is not visible in exported diagnostics.

## Folder Selection

- Open Settings > Folders.
- Select only the intended test folder, for example Oliver's Stuff.
- Close and reopen Settings.
- Confirm only the selected folder remains checked.
- Trigger Sync Now from the menu bar.

## Remote-To-Local Discovery

- Open the Image Relay File Provider root in Finder.
- Confirm the selected folder appears.
- Confirm unselected root folders do not appear.
- Open the selected folder and confirm remote folders and files appear as placeholders.
- Confirm remote file dates match Image Relay metadata and do not show Dec 31, 1969.

## Download On Open

- Pick a remote placeholder file that is not already downloaded.
- Open it from Finder.
- Confirm the file downloads and opens in the expected app.
- Confirm the menu bar activity records a download.
- Quit and relaunch ImageRelay Client, then confirm the downloaded file remains accessible.

## Local-To-Remote Upload

- In Finder, create or copy a small test file into the selected synced folder.
- Confirm the menu bar activity records an upload.
- Confirm the file appears in Image Relay in the expected folder.
- Repeat with an empty text file and confirm it appears remotely as 0 bytes.
- Rename or remove the test file in Image Relay after testing if it is only a probe.

## Pause And Resume

- Use the menu bar pause control.
- While paused, add a local test file and confirm it does not upload immediately.
- Resume syncing.
- Confirm the queued local change uploads.
- Confirm the sync status returns to idle or shows the next remote poll time.

## Quit And Relaunch

- Quit ImageRelay Client from the menu bar.
- Relaunch it from Applications.
- Confirm the menu bar icon returns.
- Confirm Settings still shows the saved configuration.
- Confirm the File Provider root remains visible in Finder.
- Confirm Sync Now still signals the provider.

## Domain Reset

- Use Settings > Advanced > Reset Finder Sync only when Finder state looks stale or the root is missing.
- Confirm the app removes and re-adds the File Provider domain through the signed reset path.
- Confirm the File Provider root reappears in Finder.
- Confirm the selected-folder filter is still respected after reset.

## Delete, Rename, And Move Behavior

- Delete a small local test file in Finder and confirm it is removed from Image Relay.
- Rename a local folder and confirm the folder rename reaches Image Relay.
- Rename a local file and confirm the new filename reaches Image Relay while the file remains downloadable.
- Move a local file between synced folders and confirm Image Relay reflects the move.
- Move a local folder between synced folders and confirm Image Relay reflects the move without changing the remote folder ID.

## Bad API Key

- Replace the API key with an invalid value.
- Trigger Sync Now.
- Confirm the app reports a clear credential error and does not crash.
- Restore the valid key.
- Trigger Sync Now and confirm normal syncing resumes.

## Network Failure

- Disconnect networking or block access to `api.imagerelay.com`.
- Trigger Sync Now.
- Confirm the app reports a network or server-reachable error and does not crash.
- Restore networking.
- Trigger Sync Now and confirm the error clears after a successful poll.

## Export Diagnostics

- Open Settings > Advanced.
- Click Export Diagnostics and choose a local folder.
- Confirm the exported folder contains `manifest.json`, `system.json`, `config.json`, `activity.json`, `sync-progress.json`, `domain-status.json`, `crash-reports.txt`, and `logs.txt`.
- Confirm `config.json` contains only sanitized configuration and never includes the API key value.

## Collections (1.1)

- Open the menu bar item, choose Collections.
- Confirm the existing collections list loads.
- Click New Collection, enter a clearly-test name like `[TEST] release`, confirm it appears.
- Select an asset from the Files browser, drag or use the action menu to add it to the test collection. Confirm it appears in the collection's file list.
- Confirm there is no "Remove" / minus-circle button next to individual items (removal is not supported by the v2 API — verified 2026-05-12).
- Delete the test collection. Confirm it disappears from the list immediately and from the web UI on refresh.

## Library Admin (1.1)

- Open Library Admin from Settings.
- Confirm the File Types, Keyword Sets, Users, Folder Links, Quick Links, Permission Groups, and Invited Users sections all populate without "Not found" errors.
- Confirm Permission Groups loads (hits `/permissions.json`, NOT `/permission_groups.json`).
- In Users, type a substring like a colleague's last name into the search box. Confirm the list filters server-side via `?q=`. Empty search returns all users.
- Create a `[TEST]` keyword set. Add a `[TEST]` keyword. Rename the keyword. Delete the keyword. Delete the keyword set. Confirm each step round-trips against the web UI.
- Create a folder link on a known-safe folder, copy the URL, delete the folder link. Confirm the URL stops working after the delete propagates.
- Skip Invited User Create and User Permission-Group Update during smoke tests — both produce side effects (real invitation emails, real permission changes) on real users.

## Release Automation

- Run `scripts/run-release-candidate-checks.sh 1.1.1` on a macOS 26 machine with Xcode 26.
- Run `scripts/run-release-candidate-checks.sh` as the current-release shorthand; it defaults to 1.1.1.
- For live account coverage, run `RUN_LIVE_SYNC=1 scripts/run-release-candidate-checks.sh 1.1.1`.
- For packaging coverage, run `RUN_PACKAGE=1 scripts/run-release-candidate-checks.sh 1.1.1`.
- Confirm the release artifact folder includes the notarized DMG, SHA-256 file, and `appcast.xml`.
