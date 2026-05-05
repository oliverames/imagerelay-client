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
  <img src="https://img.shields.io/badge/status-beta-f5a542?style=flat-square" alt="Beta">
  <img src="https://img.shields.io/badge/platform-macOS%2026-f5a542?style=flat-square&logo=apple&logoColor=white" alt="macOS 26">
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=flat-square&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee">
  </a>
</p>

---

A native macOS app that mounts your Image Relay DAM as a first-class Finder location. Files appear as dataless placeholders — open one and it downloads on demand; save a file into the Finder location and it uploads automatically. No browser, no manual sync, no separate folder to manage.

> **Beta**: Image Relay Client is currently in public beta on macOS 26 (Tahoe). Core sync, upload, download, and conflict handling are working; see [Known Limitations](#known-limitations) for what isn't.

## Why This Exists

Image Relay has no native macOS desktop client. Getting to assets means opening a browser, navigating the web app, downloading files by hand, and keeping track of versions yourself. Every design tool, script, and app that needs those assets has to work around that gap.

This client fixes that by mounting your DAM through Apple's [File Provider API](https://developer.apple.com/documentation/fileprovider) — the same mechanism that powers iCloud Drive — so every app on the Mac sees your Image Relay library as a native Finder location. Drag a file into Figma, open a video in QuickTime, attach a campaign asset to an email — without opening a browser.

## Download

**macOS 26 (Tahoe) required.** The app uses File Provider APIs introduced in macOS 26.

1. Download the latest `ImageRelayClient-*.dmg` asset from the [latest release](https://github.com/oliverames/imagerelay-client/releases/latest)
2. Open the DMG and drag **Image Relay** to Applications
3. Launch Image Relay — the menu bar icon appears
4. Open Settings → General and enter your API key and root folder ID

**Finding your API key**: Image Relay web app → Account Settings → API.

**Finding your root folder ID**: navigate to the folder you want as your Finder root in the Image Relay web app; the numeric ID appears in the URL (`/folders/2907644`).

## Features

- **Finder-native** — files and folders appear as a real Finder location alongside iCloud Drive
- **Download on open** — files are dataless placeholders until you touch them; only what you open is fetched
- **Upload on save** — drop a file into the Finder location and it uploads automatically in 5 MB chunks
- **Selective sync** — choose which top-level folders appear in Finder; unselected folders stay invisible
- **Conflict preservation** — if a file changes remotely while you're editing locally, your version is uploaded as a conflict copy and the remote version takes the canonical slot; nothing is silently discarded
- **Pause controls** — pause sync for 30 minutes, 1 hour, until tomorrow, or indefinitely from the menu bar
- **Live status** — menu bar shows sync state, recent activity, and the next scheduled remote check
- **Diagnostics export** — export a sanitized bundle (config, activity log, domain status, recent logs) from Settings → Advanced for support or debugging
- **Domain reset** — Settings → Advanced → Reset Finder Sync removes and re-registers the File Provider domain without losing configuration

## How Sync Works

**Downloads** -- When you open a file in Finder, the OS delegates to the extension. It creates a temporary quick link, downloads the file, and hands the local copy back so it opens in the expected app with no manual steps.

**Uploads** -- When you save a new file into the synced Finder location, the extension creates an upload job, sends the file in 5 MB chunks, polls for job completion, and stores the resulting asset ID.

**New versions** -- When you modify an existing file, the extension requests a version UUID from Image Relay, uploads the new content in chunks, and finalizes the version.

**Rename / move** -- Folder renames use `PUT /folders/{id}.json`. File moves use `POST /files/{id}/move.json`. File renames are not supported by the Image Relay API.

**Remote changes** -- A background poller wakes on a configurable interval and signals the OS to re-enumerate. The enumerator fetches the current selected subtree, diffs it against the local database, and surfaces additions, changes, and deletions to Finder. The host app can also signal enumerators on the configured interval as a safety net after system sleep or extension restarts.

**Conflict detection** -- On every modify, the extension compares the content version the OS provides against the version in the local database. If they differ, the local edit is uploaded as a conflict copy and the remote version is fetched.

## Configuration

Settings are stored as JSON in a shared App Group container, readable by both the menu bar app and the File Provider extension without XPC.

| Setting | Description | Default |
|---|---|---|
| API Key | Image Relay API key — Account Settings → API | — |
| Root Folder ID | Numeric ID of the folder to mount as the Finder root | — |
| Default File Type ID | Metadata template applied to new uploads (optional) | none |
| Sync Upload | Push local changes to Image Relay | on |
| Sync Download | Pull remote changes into Finder | on |
| Poll Interval | Seconds between remote change checks | 60 |

### Maintenance Flags

Two hidden launch arguments are available for troubleshooting:

```sh
# Re-register the File Provider domain from the command line
open -a "Image Relay" --args --reset-file-provider-domain

# Export a sanitized diagnostics bundle to ~/Desktop/ir-diagnostics
open -a "Image Relay" --args --export-diagnostics ~/Desktop/ir-diagnostics
```

`--export-diagnostics` writes `manifest.json`, `config.json` (API key redacted), `activity.json`, `sync-progress.json`, `domain-status.json`, and `logs.txt` to the specified directory, then exits.

## Architecture

Three targets share state through an App Group container (`group.com.oliverames.imagerelay-client`):

```
ImageRelayKit/          Swift Package — shared library
  APIClient             Async HTTP client (rate limiting, chunked upload, quick links)
  SyncDatabase          GRDB-backed SQLite (tracked items, progress, activity log, pause state)
  AppConfiguration      JSON config in the App Group container
  Models                RemoteFolder, RemoteFile, TrackedItem, SyncProgressState, etc.

ImageRelayClient/       Menu bar app (SwiftUI, LSUIElement)
  DomainManager         Registers/removes the File Provider domain; remote sync signaling
  MenuBarView           Live status, recent activity, pause controls, Open in Finder
  Settings/             General, Folders, Activity, Advanced

FileProviderExtension/  NSFileProviderReplicatedExtension
  Extension             All CRUD operations delegated by the OS
  Enumerator            Concurrent folder discovery; drives initial and incremental sync
  RemoteChangePoller    Background actor; signals enumerators on a configurable interval
  FileProviderItem      Adapts TrackedItem to NSFileProviderItem
```

The OS manages the extension lifecycle. There is no custom daemon.

## Building from Source

**Requirements**: macOS 26, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/oliverames/imagerelay-client.git
cd imagerelay-client
xcodegen generate
open ImageRelayClient.xcodeproj
```

`ImageRelayKit` is a local Swift Package; Xcode resolves GRDB automatically.

```sh
# Run the unit test suite (48 tests across 9 suites)
swift test --package-path ImageRelayKit

# Build a Developer ID signed, notarized release DMG
scripts/build-developer-id-release.sh --version 1.0.0-beta.11 --smoke-install
```

## Known Limitations

- **File renames** are not supported — the Image Relay API does not expose a rename endpoint for files.
- **Remote change detection** is polling-based — the API does not expose a webhook or cursor-based push feed.
- **Multi-folder assets** download as a single file; the client does not create additional remote synced-file memberships for new uploads.

## Contributing & Issues

Bug reports and feature requests are welcome via [GitHub Issues](https://github.com/oliverames/imagerelay-client/issues). If you're testing the beta, the [`BETA_TESTING.md`](BETA_TESTING.md) checklist covers the full set of scenarios worth verifying against a real Image Relay account.

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
