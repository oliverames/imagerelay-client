# ImageRelay Client: Native macOS Rebuild

**Date:** 2026-04-06
**Status:** Approved

## Summary

Rebuild the existing Python-based ImageRelay sync client as a native macOS app using Swift, SwiftUI, and the File Provider API. The app appears as a cloud storage location in Finder's sidebar, supports on-demand file download with optional folder pinning, and targets macOS Tahoe (26) exclusively.

## Goals

- Native Finder integration via File Provider (cloud storage location in sidebar, on-demand download)
- App Store-quality polish with Liquid Glass styling on macOS 26
- Bidirectional sync: folders, files, uploads, downloads, versioning, selective folder sync
- Hybrid materialization: files are on-demand (dataless) by default; users can pin folders for offline access
- Menu bar utility app with rich SwiftUI Settings window (General, Folders, Activity, Advanced)
- Personal use with API key auth, but polished enough for non-technical users

## Non-Goals (v1)

- OAuth or other auth flows (API key only)
- Metadata, tag, or keyword editing (stay in web UI)
- Webhooks (polling only, same as current app)
- Multi-account support
- iOS / iPadOS
- Collections, catalogs, products, templates

## Architecture

### Approach: Monorepo with Shared Swift Package

One Xcode project (generated via XcodeGen) with three targets plus a local Swift package:

```
ImageRelayClient/
├── Project.yml                    # XcodeGen project spec
├── ImageRelayClient/              # Host app target
│   ├── App.swift                  # @main, MenuBarExtra
│   ├── Settings/                  # SwiftUI Settings tabs
│   │   ├── GeneralSettingsView.swift
│   │   ├── FoldersSettingsView.swift
│   │   ├── ActivitySettingsView.swift
│   │   └── AdvancedSettingsView.swift
│   └── Resources/
│       └── Assets.xcassets
├── FileProviderExtension/         # File Provider extension target
│   ├── Extension.swift            # NSFileProviderReplicatedExtension
│   ├── Enumerator.swift           # NSFileProviderEnumerator
│   ├── FileProviderItem.swift     # NSFileProviderItemProtocol
│   └── Info.plist
├── ImageRelayKit/                 # Local Swift Package
│   ├── Package.swift
│   └── Sources/ImageRelayKit/
│       ├── API/
│       │   ├── APIClient.swift        # URLSession-based, async/await
│       │   ├── APIError.swift
│       │   ├── RateLimiter.swift       # 5 req/s token bucket
│       │   └── Endpoints.swift         # Typed endpoint definitions
│       ├── Models/
│       │   ├── RemoteFolder.swift
│       │   ├── RemoteFile.swift
│       │   ├── QuickLink.swift
│       │   ├── UploadJob.swift
│       │   └── SyncAnchor.swift
│       ├── Sync/
│       │   ├── SyncState.swift         # State machine
│       │   └── ConflictResolver.swift  # Conservative: keep both
│       └── Storage/
│           ├── SyncDatabase.swift      # GRDB-backed SQLite
│           └── Configuration.swift     # Shared config store
└── Tests/
    ├── ImageRelayKitTests/
    └── FileProviderExtensionTests/
```

### Shared State

Both the host app and extension access data through an **App Group container** (`group.com.oliverames.imagerelay-client`):

- **SQLite database** (via GRDB): remote-to-local item mappings, sync anchors for change enumeration, pin state, activity log
- **Configuration**: API key, remote root folder ID, default file type ID, poll interval, sync direction flags

### File Provider Extension

**Type:** Replicated (`NSFileProviderReplicatedExtension` + `NSFileProviderEnumerating`)

**Protocols adopted:**
- `NSFileProviderReplicatedExtension` — core lifecycle (item CRUD, content fetch/push)
- `NSFileProviderEnumerating` — enumerate items from Image Relay folders
- `NSFileProviderThumbnailing` — generate thumbnails for image assets in Finder
- `NSFileProviderItemDecorating` — sync status badges on items

**Item identifiers:** Map directly to Image Relay IDs using a string prefix scheme:
- `folder-{id}` for folders (e.g., `folder-123`)
- `file-{id}` for files (e.g., `file-456`)
- `NSFileProviderItemIdentifier.rootContainer` maps to the configured `remote_root_folder_id`

**Key operations:**

| Finder Action | Extension Method | Image Relay API |
|---|---|---|
| Browse folder | `enumerateItems()` | `GET /folders/{id}/files.json`, `GET /folders.json` |
| Open file | `fetchContents(for:)` | `POST /quick_links.json` + download + `DELETE /quick_links/{id}.json` |
| Save file | `modifyItem()` | `POST /files/{id}/versions.json` + chunk upload + complete |
| Create file | `createItem()` | `POST /upload_jobs.json` + chunk upload |
| Delete file | `deleteItem()` | `DELETE /files/{id}.json` |
| Create folder | `createItem()` | `POST /folders.json` |
| Rename folder | `modifyItem()` | `PUT /folders/{id}.json` |
| Delete folder | `deleteItem()` | `DELETE /folders/{id}.json` |
| Move file | `modifyItem()` | `POST /files/{id}/move.json` |

**Remote change detection:**
- A background `Task` polls the Image Relay API on a configurable interval (default 60s)
- On detecting changes, calls `NSFileProviderManager.signalEnumerator(for:)` to trigger re-enumeration
- The extension tracks a sync anchor per enumerated container for incremental updates

**Materialization strategy (hybrid):**
- Files start as **dataless placeholders** (cloud icon in Finder)
- Opening a file triggers `fetchContents(for:)` which downloads on demand
- Users can pin folders via the Settings > Folders tab; pinning is tracked in the shared database as a per-folder flag
- When a folder is pinned, the extension proactively calls `NSFileProviderManager.requestDownloadForItem(withIdentifier:)` for all children, materializing them eagerly
- Pinned folders have all contents kept in sync; new remote files in pinned folders are auto-downloaded

### ImageRelayKit (Shared Swift Package)

**APIClient:**
- Async/await on URLSession
- Rate limiter: token bucket, 5 requests/second (matching Image Relay's documented limit)
- Retry logic: exponential backoff on 429, 502, 503 with max 3 retries, max 30s delay
- Pagination: handles both `pagination` JSON objects and `Link` header styles
- User-Agent header configurable

**Models:**
- Swift structs with `Codable` conformance, equivalent to the current Python dataclasses
- `RemoteFolder`, `RemoteFile`, `QuickLink`, `UploadJob`, `SyncAnchor`

**SyncDatabase (GRDB):**
- Item table: maps `NSFileProviderItemIdentifier` to Image Relay IDs, tracks content version, metadata version, pin state
- Activity log table: recent sync events with timestamps for the Activity settings tab
- Sync anchor table: per-container enumeration state for incremental change detection
- Located in the app group container

**Configuration:**
- Stored as a plist or JSON in the app group container
- Fields: `apiKey`, `remoteRootFolderID`, `defaultFileTypeID`, `pollIntervalSeconds`, `syncUpload`, `syncDownload`, `userAgent`

### Host App

**App type:** Menu bar utility (no Dock icon, no main window)

**Menu bar (`MenuBarExtra`):**
- SF Symbol icon with sync status animation
- Popover showing: current state (idle/syncing/paused/error), current file being processed, last sync time, next poll time
- Quick actions: Pause/Resume, Open in Finder, Open Settings

**Settings window (`Settings` scene with `TabView`):**

| Tab | Contents |
|---|---|
| General | API key (secure field), remote root folder, default file type ID, login item toggle (`SMAppService`) |
| Folders | Tree view of Image Relay folders with sync/pin toggles per folder |
| Activity | Scrollable list of recent sync events (file name, action, timestamp, status icon) |
| Advanced | Poll interval slider, upload/download direction toggles, conflict behavior picker |

**Styling:** Liquid Glass on macOS 26 for the Settings window and menu bar popover.

**Communication with extension:**
- `NSFileProviderManager` for signaling sync, getting domain status, managing the domain lifecycle
- Shared SQLite database for activity log and folder pin state
- Shared configuration file for settings changes (extension reads on next cycle)

### Sync Flow

1. **Enumeration**: System calls `enumerateItems()` — extension queries Image Relay API via `ImageRelayKit.APIClient`, returns `NSFileProviderItem` objects
2. **On-demand download**: User opens file in Finder — system calls `fetchContents(for:)` — extension creates quick link, downloads content, cleans up quick link, returns file URL to system
3. **Upload (new)**: User creates file in Finder — system calls `createItem()` — extension creates upload job, uploads chunks, waits for completion
4. **Upload (modified)**: User saves file — system calls `modifyItem()` — extension creates version upload, uploads chunks, completes version
5. **Delete**: User deletes in Finder — system calls `deleteItem()` — extension calls delete API
6. **Remote polling**: Background task polls API on interval — detects changes — signals enumerator — system re-enumerates and applies changes
7. **Conflict resolution**: Conservative strategy — when local and remote both changed, keep both copies (remote version applied, local version renamed with conflict marker)

### Error Handling

- API errors surface as `NSFileProviderError` codes so Finder shows appropriate UI
- Rate limit (429): retry with backoff, same as current app
- Auth errors (401/403): surface in menu bar status and Settings
- Network errors: mark items as pending, retry on next cycle
- Friendly error descriptions matching the current Python app's `user_messages.py`

### Dependencies

- **GRDB** (Swift Package Manager) — SQLite wrapper for the shared database
- **No other third-party dependencies** — URLSession for networking, SwiftUI for UI, native File Provider framework

### Testing Strategy

- **ImageRelayKitTests**: Unit tests for API client (with URLProtocol mocking), models, database operations, rate limiter, configuration
- **FileProviderExtensionTests**: Use Apple's `NSFileProviderTesting*` protocols for testing enumeration, content fetch, creation, modification, deletion
- **Manual testing**: `com.apple.developer.fileprovider.testing-mode` entitlement for development builds

### Data Migration

The new app does not migrate state from the Python app. Users configure the new app from scratch (API key, root folder). The File Provider manages its own file store independently of any previously synced local folder.

### Entitlements

- `com.apple.security.app-sandbox` — required for App Store
- `com.apple.security.network.client` — outbound API calls
- `com.apple.security.application-groups` — shared container access
- `com.apple.developer.fileprovider.testing-mode` — development only
