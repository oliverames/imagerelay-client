# imagerelay-client

Native Image Relay DAM client. Swift 6, SwiftUI, File Provider API
(`NSFileProviderReplicatedExtension`). Two host apps share one
`ImageRelayKit` package:

- **macOS** (macOS 26+): full bidirectional sync, MenuBarExtra UI,
  metadata editing, admin features. Target: `ImageRelayClient`.
- **iOS** (iOS 18+): read-only on-demand browser whose primary purpose
  is surfacing Image Relay folders inside the Files app via a stateless
  File Provider extension. Target: `ImageRelayClientiOS`.

## Project Structure

```
ImageRelayClient.xcodeproj    # XcodeGen-generated; tracked in git
Project.yml                   # XcodeGen source of truth (4 targets)
ImageRelayKit/                # Local Swift package (macOS 15 + iOS 18)
FileProviderExtension/        # macOS NSFileProviderReplicatedExtension
ImageRelayClient/             # macOS host (MenuBarExtra + Settings + admin)
FileProviderExtensioniOS/     # iOS NSFileProviderReplicatedExtension (read-only)
ImageRelayClientiOS/          # iOS host (TabView: Files / Library / Settings)
```

## Commands

```bash
# Regenerate Xcode project after any Project.yml change
xcodegen generate

# Build macOS host (macOS 26 SDK required)
xcodebuild build \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClient \
  -destination 'platform=macOS'

# Run ImageRelayKit unit tests (currently 90 across 16 suites)
xcodebuild test \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClient \
  -destination 'platform=macOS'

# Build iOS host + extension for a Simulator
xcodebuild build \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClientiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17e'
```

## Key Constants

- App Group: `group.com.oliverames.imagerelay-client`
- Bundle prefix: `com.oliverames.imagerelay-client`
- Team ID: `PV3W52NDZ3`
- Shared container path: `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client")`

## Architecture Notes

**ImageRelayKit** is the single source of truth for all shared types:
- `APIClient` (actor) -- rate-limited HTTP client with chunked upload support
- `SyncDatabase` (class, GRDB) -- SQLite for tracked items, activity log, progress, sync anchor
- `AppConfiguration` (struct, Codable) -- saved as `config.json` in the app group container
- `TrackedItem` -- GRDB record for folders/files tracked in Finder

**Config JSON backward compatibility**: `AppConfiguration` uses `decodeIfPresent` with defaults throughout its `init(from:)`. When adding new fields, always use `decodeIfPresent` -- never plain `decode` -- so existing `config.json` files load without error.

**`AppConfiguration.save` must create the parent directory**: On first launch the app group container directory does not exist. Call `FileManager.default.createDirectory(at:withIntermediateDirectories:)` before writing `config.json`, or the write throws "file not found".

**Folder filtering semantics**: `AppConfiguration.selectedFolderIDs` empty = all folders sync. Filtering applied client-side at the root enumerator only. Children of selected folders always enumerate normally.

## File Provider Patterns

**Swift 6 concurrency in File Provider**: Completion handlers passed into `Task {}` closures must be captured as `nonisolated(unsafe)`:
```swift
nonisolated(unsafe) let completionHandler = completionHandler
Task { completionHandler(...) }
```

**Enumeration vs. changes**: `enumerateItems` does a fresh full load -- never report deletions here. `enumerateChanges` does incremental updates -- this is the only place to call `observer.didDeleteItems(withIdentifiers:)`.

**Deletion detection pattern** in `Enumerator.fetchItems()`: build `remoteIdentifiers` set while processing API results, then diff against `db.children(of: containerIdentifier.rawValue)` at the end.

## Known State

- **Live testing scope**: Signed Developer ID builds have been smoke-tested against the live Image Relay account only inside the selected `Oliver's Stuff` folder (`2907644`). Keep future release testing constrained to that folder unless explicitly asked otherwise.
- **Release workflow**: GitHub publishing is unblocked. Use `scripts/build-developer-id-release.sh --version <version> --smoke-install` for Developer ID signed, notarized DMGs and installed-app smoke verification.
- **Open release risk**: The App Store Connect API key used for notarization should still be rotated when convenient because an earlier repo-local copy was treated as exposed.

## macOS 26 SDK Gotchas

- `fetchContents` completion handler takes 3 args (dropped the Bool vs. older SDK)
- Settings tabs: use `Tab("Title", systemImage:) { }` -- NOT `.tabItem {}` (creates duplicate tabs)
- Settings window for `LSUIElement` apps needs `NSApp.activate(ignoringOtherApps: true)` to come to front
- `NSFileProviderItemProtocol`: `itemIdentifier`/`parentItemIdentifier` (not `identifier`/`parentIdentifier`)

## iOS Port Notes

**Cross-platform discipline.** ImageRelayKit imports only `Foundation`,
`GRDB`, `Security`, `os.log` — no AppKit/UIKit. Adding a feature there
makes it work on both platforms; adding to a host app keeps it on that
platform only.

**iOS extension is stateless and on-demand.** No `SyncDatabase`, no
`RemoteChangePoller`, no upload paths. Every enumeration calls the API
live; every `fetchContents` mints a fresh quick-link, downloads to a
temp file, and deletes the quick-link. `Enumerator.currentSyncAnchor`
returns nil so the system never asks for incremental changes.

**iOS read-only by protocol.** `NSFileProviderReplicatedExtension`
requires `createItem`/`modifyItem`/`deleteItem` — they aren't
`@optional`. The iOS implementation provides them as no-ops returning
`NSFileProviderError(.cannotSynchronize)` with a read-only message.

**Service/state files compiled by both targets.** `CollectionsService`,
`ProductsService`, `LibraryAdminService` (each containing a service +
an `@Observable` state class) live under `ImageRelayClient/<feature>/`
but are listed as additional `sources:` paths in the iOS target. Views
remain platform-specific.

**Distinct keychain access groups per platform.** The iOS bundle IDs
include `.ios`, so the iOS targets use
`PV3W52NDZ3.com.oliverames.imagerelay-client.ios` as the keychain
access group (a valid prefix of both iOS bundle IDs). macOS keeps
`PV3W52NDZ3.com.oliverames.imagerelay-client`.
`KeychainStore.sharedAccessGroup` is platform-conditionalized so the
public API "just works."

**App Group reused across platforms.** Both platforms declare
`group.com.oliverames.imagerelay-client`. Per-device sandbox containers
are independent, so iOS state and macOS state never interfere.

## Image Relay API Notes

- Upload flow: `POST /upload_jobs.json` → `PUT /upload_jobs/{job_id}/files/{upload_file_id}/chunks/{n}` → `POST /upload_jobs/{job_id}/files/{upload_file_id}/complete.json`
- Quick link download: send `asset_id` (not `file_id`) and `disposition: "attachment"`
- Folder listing: `GET /folders/{id}/children?per_page=100&page=N`; `GET /folders/{id}/children` without pagination currently returns 404
- Create folder: `POST /folders/{parent_id}/children` with `{ "name": "..." }`
- Rename or move folder: `PUT /folders/{id}.json` with `name` and optional `parent_id`
- Rename file: complete a new version with the new `file_name`; direct `/files/{id}.json` rename endpoints returned 404 in live API probing
- Move file: `folder_ids` is array of strings (not int)
- Rate limit responses include `Retry-After` header -- honor it; `APIClient` does this automatically
