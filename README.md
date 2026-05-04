<p align="center">
  <img src="Image Relay Icon.svg" width="80" height="80" alt="Image Relay">
</p>

<h1 align="center">Image Relay Client</h1>

<p align="center">
  <strong>Native macOS File Provider that surfaces your Image Relay DAM directly in Finder</strong>
</p>

<p align="center">
  <code>macOS 26+</code> &bull;
  <code>File Provider API</code> &bull;
  <code>no manual sync</code>
</p>

<p align="center">
  <a href="https://www.buymeacoffee.com/oliverames"><img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=flat-square&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee"></a>
</p>

---

A native macOS app that surfaces an Image Relay DAM account directly in Finder via the File Provider API. Files appear as a native Finder location alongside iCloud Drive -- no manual sync or separate folder to manage.

## Why This Exists

Image Relay has no native macOS client. Getting to assets means opening a browser, navigating the web app, downloading files manually, and keeping track of versions yourself. This client fixes that by mounting your DAM as a proper Finder location through Apple's File Provider API — the same mechanism that powers iCloud Drive — so every app that opens files sees your Image Relay library natively. No separate sync folder, no browser required.

## Architecture

The project has three targets that share state through an App Group container:

```
ImageRelayKit/          Swift Package -- shared library
  APIClient             Async HTTP client (rate limiting, chunked upload, quick links)
  SyncDatabase          GRDB-backed SQLite (tracked items, progress, activity log, pause state)
  AppConfiguration      JSON config stored in the App Group container
  Models                RemoteFolder, RemoteFile, TrackedItem, SyncProgressState, etc.

ImageRelayClient/       macOS menu bar app (SwiftUI, @main)
  DomainManager         Registers / removes the File Provider domain; reads shared DB for status
  MenuBarView           Live status, recent activity, pause controls, Open in Finder
  Settings/             Four-tab settings window (General, Folders, Activity, Advanced)

FileProviderExtension/  NSFileProviderReplicatedExtension
  Extension             Handles all CRUD operations called by the OS
  Enumerator            Lists remote folders and files; drives initial and incremental sync
  RemoteChangePoller    Background actor; signals the enumerator on a configurable interval
  FileProviderItem      Adapts TrackedItem to NSFileProviderItem
```

The OS manages the extension lifecycle. There is no custom daemon.

## How Sync Works

**Downloads** -- When the user opens a file in Finder, the OS calls `fetchContents`. The extension creates a temporary quick link, downloads the file, cleans up the link, and hands the local file back to the system.

**Uploads** -- When the user saves a new file into the Finder location, the OS calls `createItem`. The extension creates an upload job, sends the file in 5 MB chunks, polls for job completion, and stores the resulting asset ID.

**New versions** -- When the user modifies an existing file, the OS calls `modifyItem`. The extension requests a version UUID, uploads the new content in chunks, and finalizes the version.

**Rename / move** -- Folder renames call `PUT /folders/{id}.json`. File moves call `POST /files/{id}/move.json`. File renames are not yet supported by the Image Relay API.

**Remote changes** -- `RemoteChangePoller` wakes on a configurable interval and calls `NSFileProviderManager.signalEnumerator`, which prompts the OS to re-enumerate. The `Enumerator` then fetches the current remote folder and file listings and diffs them against the local database.

**Conflict detection** -- On `modifyItem`, the extension compares the base content version the OS provides against the version in the database. If they differ, the remote version wins and the OS is told to re-fetch.

## Configuration

All settings are stored in the shared App Group container (`group.com.oliverames.imagerelay-client`) as a JSON file alongside the SQLite database. This lets the extension and the menu bar app read the same configuration without XPC.

| Setting | Description |
|---|---|
| API Key | Image Relay API key (Account Settings → API) |
| Root Folder ID | Numeric folder ID to use as the Finder root |
| Default File Type ID | Metadata template applied to all new uploads |
| Sync Upload | Allow local changes to be pushed to Image Relay |
| Sync Download | Allow remote changes to appear in Finder |
| Poll Interval | How often to check for remote changes (seconds) |

## Requirements

- macOS 26 (Tahoe) or later
- An Image Relay account with API access
- Xcode 26 (build from source via `Project.yml` / XcodeGen)

## Building

The Xcode project is generated from `Project.yml` using [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open ImageRelayClient.xcodeproj
```

`ImageRelayKit` is a local Swift Package; Xcode resolves its dependencies (GRDB) automatically.

## Known Limitations

- File renames are not supported -- the Image Relay API does not expose a rename endpoint for files.
- Remote change detection is polling-based -- the API does not expose a webhook or cursor-based push feed.
- Multi-folder (synced file) assets download as a single file; the client does not create additional remote synced-file memberships.

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
