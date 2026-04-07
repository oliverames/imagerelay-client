# imagerelay-client

Native macOS sync client for Image Relay DAM. Swift 6, SwiftUI, File Provider API (NSFileProviderReplicatedExtension). macOS 26 exclusive.

## Project Structure

```
ImageRelayClient.xcodeproj   # XcodeGen-generated; tracked in git
Project.yml                  # XcodeGen source of truth
ImageRelayKit/               # Local Swift package (shared library)
FileProviderExtension/       # NSFileProviderReplicatedExtension
ImageRelayClient/            # Host app (MenuBarExtra + Settings)
```

Run `xcodegen generate` to regenerate the xcodeproj from `Project.yml`.

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

**Folder filtering semantics**: `AppConfiguration.selectedFolderIDs` empty = all folders sync. Filtering applied client-side at the root enumerator only. Children of selected folders always enumerate normally.

## File Provider Patterns

**Swift 6 concurrency in File Provider**: Completion handlers passed into `Task {}` closures must be captured as `nonisolated(unsafe)`:
```swift
nonisolated(unsafe) let completionHandler = completionHandler
Task { completionHandler(...) }
```

**Enumeration vs. changes**: `enumerateItems` does a fresh full load -- never report deletions here. `enumerateChanges` does incremental updates -- this is the only place to call `observer.didDeleteItems(withIdentifiers:)`.

**Deletion detection pattern** in `Enumerator.fetchItems()`: build `remoteIdentifiers` set while processing API results, then diff against `db.children(of: containerIdentifier.rawValue)` at the end.

## macOS 26 SDK Gotchas

- `fetchContents` completion handler takes 3 args (dropped the Bool vs. older SDK)
- Settings tabs: use `Tab("Title", systemImage:) { }` -- NOT `.tabItem {}` (creates duplicate tabs)
- Settings window for `LSUIElement` apps needs `NSApp.activate(ignoringOtherApps: true)` to come to front
- `NSFileProviderItemProtocol`: `itemIdentifier`/`parentItemIdentifier` (not `identifier`/`parentIdentifier`)

## Image Relay API Notes

- Upload flow: `POST /upload_jobs.json` → `PUT /upload_jobs/{job_id}/files/{upload_file_id}/chunks/{n}` → `POST /upload_jobs/{job_id}/files/{upload_file_id}/complete.json`
- Quick link download: send `asset_id` (not `file_id`) and `disposition: "attachment"`
- Folder listing: `GET /folders.json?parent_id=X` (there is no `/folders/{id}/children.json`)
- Move file: `folder_ids` is array of strings (not int)
- Rate limit responses include `Retry-After` header -- honor it; `APIClient` does this automatically
