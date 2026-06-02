<p align="center">
  <img src="Image Relay Icon.svg" width="80" height="80" alt="Image Relay">
</p>

<h1 align="center">Image Relay Client</h1>

<p align="center">
  <strong>Native macOS File Provider that surfaces your Image Relay DAM directly in Finder</strong>
</p>

<p align="center">
  <code>macOS 26+</code> &bull;
  <code>Swift 6</code> &bull;
  <code>File Provider API</code> &bull;
  <code>no browser required</code>
</p>

<p align="center">
  <a href="https://github.com/oliverames/imagerelay-client/releases/latest">
    <img src="https://img.shields.io/github/v/release/oliverames/imagerelay-client?include_prereleases&style=flat-square&color=f5a542&label=release" alt="Latest release">
  </a>
  <img src="https://img.shields.io/badge/status-1.4.0--beta.1-f5a542?style=flat-square" alt="1.4.0-beta.1">
  <img src="https://img.shields.io/badge/platform-macOS%2026-f5a542?style=flat-square&logo=apple&logoColor=white" alt="macOS 26">
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=flat-square&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee">
  </a>
</p>

---

### 🌐 Live Marketing Page
Explore the features, visual workflow, and architecture of the client on our premium, Apple/Linear-style dark-mode marketing site: **[oliverames.github.io/imagerelay-client](https://oliverames.github.io/imagerelay-client/)** (hosted via GitHub Pages).

---

A native macOS app that mounts your Image Relay DAM as a first-class Finder location. Files appear as dataless placeholders — open one and it downloads on demand; save a file into the Finder location and it uploads automatically. No browser, no manual sync, no separate folder to manage.

> **1.4 beta**: `1.4.0-beta.1` is packaged, notarized, and published through the in-app Sparkle feed and the [latest GitHub release](https://github.com/oliverames/imagerelay-client/releases/latest). This beta focuses on smoother setup, clearer sync issue recovery, interrupted-upload retry behavior, Keychain prompt-storm prevention, and better release automation. Homebrew remains stable-only at `1.3.2` until the 1.4 line is promoted to stable.

## Why This Exists

Image Relay has no native macOS desktop client. Getting to assets means opening a browser, navigating the web app, downloading files by hand, and keeping track of versions yourself. Every design tool, script, and app that needs those assets has to work around that gap.

This client fixes that by mounting your DAM through Apple's [File Provider API](https://developer.apple.com/documentation/fileprovider) — the same mechanism that powers iCloud Drive — so every app on the Mac sees your Image Relay library as a native Finder location. Drag a file into Figma, open a video in QuickTime, attach a campaign asset to an email — without opening a browser.

## Download

**macOS 26 (Tahoe) required.** The app uses File Provider APIs introduced in macOS 26.

### Install with Homebrew (recommended)

```sh
brew tap oliverames/tap
brew install --cask image-relay
```

`brew upgrade --cask image-relay` pulls every new stable release. Beta builds ride the in-app Sparkle update channel and are not exposed through Homebrew.

### Manual DMG install

1. Download the latest `ImageRelayClient-*.dmg` asset from the [latest release](https://github.com/oliverames/imagerelay-client/releases/latest)
2. Open the DMG and drag **Image Relay** to Applications
3. Launch Image Relay — the menu bar icon appears
4. Open Settings → General and enter your API key. Leave Root Folder ID blank, use `root`, or enter a numeric folder ID.

**Finding your API key**: Image Relay web app → Account Settings → API.

**Finding a folder ID**: leave the field blank or enter `root` to mount the account root. To mount one folder instead, navigate to that folder in the Image Relay web app; the numeric ID appears in the URL (`/folders/2907644`).

## Features

- **Finder-native** — files and folders appear as a real Finder location alongside iCloud Drive
- **Download on open** — files are dataless placeholders until you touch them; only what you open is fetched
- **Upload on save** — drop a file into the Finder location and it uploads automatically in 5 MB chunks
- **Selective sync** — choose which top-level folders appear in Finder; unselected folders stay invisible
- **Guided setup** - load folder and file-type choices from the account instead of copying raw IDs from the web app
- **Conflict preservation** — if a file changes remotely while you're editing locally, your version is uploaded as a conflict copy and the remote version takes the canonical slot; nothing is silently discarded
- **Pause controls** — pause sync for 30 minutes, 1 hour, until tomorrow, or indefinitely from the menu bar; pause also stops the remote poller
- **Stop / reconnect** — Stop Sync Completely disconnects the File Provider domain from the menu bar; Reconnect Sync brings it back
- **Live status with ETA** — menu bar shows sync state, batch progress, time remaining, throughput, recent activity, and rate-limit waits
- **Sync issue recovery** - Settings > Issues groups unresolved sync failures with retry and copy-report actions
- **Bulk retry** — Retry N Failed Uploads in the menu bar re-queues every failed item in one click
- **Webhook relay support** - optional relay polling wakes Finder quickly from Image Relay webhook events while preserving the slower safety poll
- **OAuth Security** — connect via classic API key or an Image Relay Developer-app OAuth flow featuring process-safe coordinated refresh and anti-prompt Keychain caching
- **Update checks** — Sparkle-backed Check for Updates action from the menu bar
- **Diagnostics export** - export a sanitized bundle (config, app/system info, activity log, domain status, crash-report summary, recent logs) from Settings > Advanced for support or debugging
- **Domain reset** - Settings > Advanced > Reset Finder Sync removes and re-registers the File Provider domain without losing configuration
- **Metadata editing** - edit descriptions, keywords, and custom text fields for the selected Finder item without opening the web app
- **Copy Public Link** - right-click a tracked file in Finder and choose Copy Public Link to mint an Image Relay quick link with inline disposition and paste-ready URL on the clipboard
- **Open Folder in Image Relay Web** - right-click any tracked item and jump straight to the folder's page in your Image Relay web app; works on folders directly and on files by revealing the containing folder
- **Upload links** - create, inspect, copy, and revoke Image Relay upload links from Settings
- **Library tools** - browse Collections, Products, Webhooks, file types, keywords, users, folder links, quick links, permission groups, and invited users from native windows

## How Sync Works

**Downloads** -- When you open a file in Finder, the OS delegates to the extension. It creates a temporary quick link, downloads the file, and hands the local copy back so it opens in the expected app with no manual steps.

**Uploads** -- When you save a new file into the synced Finder location, the extension creates an upload job, sends the file in 5 MB chunks, polls for job completion, and stores the resulting asset ID. Image Relay does not return upload file IDs for zero-byte create jobs, so empty files are created as a one-byte placeholder and immediately replaced with a zero-byte version.

**New versions** -- When you modify an existing file, File Provider calls the extension with the local copy. The extension requests a version UUID from Image Relay, uploads the new content in chunks, finalizes the version, and immediately signals affected enumerators so Finder refreshes without waiting for the next remote poll.

**Rename / move** -- Folder renames and folder moves use `PUT /folders/{id}.json`. File moves use `POST /files/{id}/move.json`. File renames preserve the remote file ID by completing a new version with the new `file_name`.

**Remote changes** -- A background poller wakes on a configurable interval and signals the OS to re-enumerate. The enumerator fetches the current selected subtree, diffs it against the local database, and surfaces additions, changes, and deletions to Finder. The host app also signals enumerators every 5 minutes as a quiet watchdog after system sleep or extension restarts.

**Conflict detection** -- On every modify, the extension compares the content version the OS provides against the version in the local database. If they differ, the local edit is uploaded as a conflict copy and the remote version is fetched.

**Coordinated OAuth Refresh** -- Sandboxed File Provider extensions and the host app share the same credentials container. To prevent token invalidation races (which occur if multiple processes refresh an expired token concurrently), the library implements an atomic lock-file protocol (`config.json.lock`) inside the shared App Group. Only one process performs the API refresh exchange, while other processes await completion and read the new token.

**Keychain Prompt-Storm Protection** -- Sandboxed extensions query the secure Keychain under strict OS sandbox restrictions. Frequent secure queries during rapid parallel sync operations can flood the user with macOS password prompt storms. The client utilizes a thread-safe `CredentialCache` that monitors the modification date of `config.json` on disk; if the file timestamp has not changed and the in-memory token is valid, it skips redundant Keychain queries entirely.

## Configuration

Settings are stored as JSON in a shared App Group container, readable by both the menu bar app and the File Provider extension without XPC.

| Setting | Description | Default |
|---|---|---|
| API Key | Image Relay API key - Account Settings > API | - |
| Root Folder ID | Blank/`root` mounts the account root; a numeric ID mounts one folder as Finder root | account root |
| Default File Type ID | Metadata template applied to new uploads (optional) | none |
| Sync Upload | Push local changes to Image Relay | on |
| Sync Download | Pull remote changes into Finder | on |
| Poll Interval | Seconds between remote change checks | 60 |
| Webhook Relay URL | Optional relay endpoint that returns Image Relay webhook event cursors | none |
| Webhook Relay Interval | Seconds between host-side relay checks | 15 |

### Maintenance Flags

Two hidden launch arguments are available for troubleshooting:

```sh
# Re-register the File Provider domain from the command line
open -a "Image Relay" --args --reset-file-provider-domain

# Export a sanitized diagnostics bundle and print the generated path
open -a "Image Relay" --args --export-diagnostics
```

`--export-diagnostics` writes `manifest.json`, `system.json`, `config.json` (API key redacted), `activity.json`, `sync-progress.json`, `unresolved-failures.json`, `webhook-relay.json`, `domain-status.json`, `crash-reports.txt`, and `logs.txt` to the app sandbox temporary directory, then exits. The Settings UI still lets you choose a destination folder through the standard security-scoped folder picker.

## Architecture & Cross-Platform Design

The codebase supports both macOS (full bidirectional sync) and iOS (read-only stateless on-demand file browsing).

### App Group & Sandbox Sharing

Targets share configuration and state via a secure App Group container (`group.com.oliverames.imagerelay-client`):

```
ImageRelayKit/          Swift Package — shared library (macOS 15+ / iOS 18+)
  APIClient             Async HTTP client (rate limiting, chunked upload, quick links)
  SyncDatabase          GRDB-backed SQLite (tracked items, progress, activity log, pause state)
  AppConfiguration      JSON config in the App Group container with process-safe locking
  CredentialCache       Thread-safe, date-monitored in-memory token cache to prevent Keychain prompt storms
  Models                RemoteFolder, RemoteFile, TrackedItem, SyncProgressState, etc.

ImageRelayClient/       macOS Menu Bar Host App (SwiftUI, LSUIElement)
  DomainManager         Registers/removes the File Provider domain; remote sync signaling
  MenuBarView           Live status, recent activity, pause controls, Open in Finder
  Settings/             General, Folders, Activity, Advanced tabs (macOS 26 native Tab structure)

FileProviderExtension/  macOS File Provider Extension (NSFileProviderReplicatedExtension)
  Extension             All CRUD operations delegated by macOS
  Enumerator            Concurrent folder discovery; drives initial and incremental sync
  RemoteChangePoller    Background actor; signals enumerators on a configurable interval
  FileProviderItem      Adapts TrackedItem to NSFileProviderItem

ImageRelayClientiOS/    iOS Host App (TabView: Files, Library, Settings)
  FilesView             Browse mounted folders directly
  LibraryAdminView      Manage collections, products, and webhooks on-the-go

FileProviderExtensioniOS/ iOS File Provider Extension (Stateless & Read-Only)
  Extension             On-demand stateless browser extension surfacing folders inside the Files App
                        Mints temporary quick links, downloads to temp files, and deletes quick-links
```

The OS manages extension lifecycles dynamically. There are no custom background daemons.

## Building from Source

**Requirements**: macOS 26, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/oliverames/imagerelay-client.git
cd imagerelay-client
xcodegen generate
open ImageRelayClient.xcodeproj
```

`ImageRelayKit` is a local Swift Package; Xcode resolves GRDB and Sparkle automatically.

```sh
# Run the unit test suite (233 tests across 27 suites:
# 176 ImageRelayKitTests + 57 FileProviderExtensionTests)
xcodebuild test \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClient \
  -destination 'platform=macOS'

# SwiftPM-only fallback for ImageRelayKit (kit-level tests only)
swift test --package-path ImageRelayKit

# Run the release-candidate validation set for Project.yml's MARKETING_VERSION
scripts/run-release-candidate-checks.sh

# Optional live account smoke matrix, scoped to Oliver's Stuff by default
RUN_LIVE_SYNC=1 scripts/run-release-candidate-checks.sh

# Build a Developer ID signed, notarized release DMG
scripts/build-developer-id-release.sh --version 1.4.0-beta.1 --smoke-install
```

## Known Limitations

- **Remote change detection** still keeps a safety poll. For faster remote updates, configure a webhook relay endpoint in Settings > Advanced. The relay should receive Image Relay webhook POSTs, expose a long-poll `GET` endpoint, and return JSON shaped like `{"events":[{"id":"evt_123","resource":"file","action":"update"}],"next_cursor":"evt_123"}`.
- **Multi-folder assets** download as a single file; the client does not create additional remote synced-file memberships for new uploads.
- **File rename cost** can be higher than a metadata-only rename. Image Relay exposes file names through version completion, so a Finder rename uploads the current bytes as a new version while preserving the remote file ID.

## Contributing & Issues

Bug reports and feature requests are welcome via [GitHub Issues](https://github.com/oliverames/imagerelay-client/issues). Please include a diagnostics export when reporting sync behavior; see [Support](SUPPORT.md), [Privacy](PRIVACY.md), and the [release testing checklist](RELEASE_TESTING.md) for what is collected and redacted.

---

<p align="center">
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=for-the-badge&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee">
  </a>
</p>

<p align="center">
  <sub>
    Built by <a href="https://ames.consulting">Oliver Ames</a> in Vermont
    &bull; <a href="https://github.com/oliverames">GitHub</a>
    &bull; <a href="https://linkedin.com/in/oliverames">LinkedIn</a>
    &bull; <a href="https://bsky.app/profile/oliverames.bsky.social">Bluesky</a>
  </sub>
</p>
