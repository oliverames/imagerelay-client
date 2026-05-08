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

## Commands

```bash
# Regenerate Xcode project after any Project.yml change
xcodegen generate

# Build host app (macOS 26 SDK required)
xcodebuild build \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClient \
  -destination 'platform=macOS'

# Run ImageRelayKit unit tests (53 tests)
xcodebuild test \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClient \
  -destination 'platform=macOS'
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
- **Release script**: `scripts/build-developer-id-release.sh` requires a `mkdir -p` of the parent before the `cd` that resolves the artifact path -- fixed in Beta 5. On a clean clone `build/releases/` won't exist; the script now creates it first.

## macOS 26 SDK Gotchas

- `fetchContents` completion handler takes 3 args (dropped the Bool vs. older SDK)
- Settings tabs: use `Tab("Title", systemImage:) { }` -- NOT `.tabItem {}` (creates duplicate tabs)
- Settings window for `LSUIElement` apps needs `NSApp.activate(ignoringOtherApps: true)` to come to front
- `NSFileProviderItemProtocol`: `itemIdentifier`/`parentItemIdentifier` (not `identifier`/`parentIdentifier`)
- **`Settings` scene needs its own `.environment(...)` injection.** SwiftUI scenes (`MenuBarExtra`, `Settings`, etc.) at the App-level are siblings, not nested. An `.environment` on `MenuBarExtra` does not reach `Settings`. Apply `.environment(domainManager)` to every scene whose body reads it. Symptom: `Fatal error: No Observable object of type X found` when opening Settings.
- **Finder sidebar icon Info.plist nesting.** Per Apple's *Setting the Finder Sidebar Icon* doc, `CFBundleSymbolName` for File Provider extensions must live nested at `CFBundleIcons.CFBundlePrimaryIcon.CFBundleSymbolName`, NOT at the top level. A top-level `CFBundleSymbolName` is silently ignored and Finder falls back to the generic folder. The symbol can be a built-in SF Symbol or a custom `.symbolset` in the extension's own asset catalog.
- **Custom SF Symbols require multi-size variants.** Xcode 26's asset compiler rejects a `.symbolset` SVG that only declares `Regular-S`; it errors `Symbol image file ... must have a glyph for Regular weight Medium size`. Include `Regular-S`, `Regular-M`, `Regular-L` (and at least Ultralight-S + Black-S for weight interpolation) using Apple's standard Capline/Baseline guide y-coordinates (S: 625.541/696, M: 1055.54/1126, L: 1485.54/1556). Glyph paths inside should typically extend to ~1.5–1.7× cap height to match system sidebar symbols.

## Image Relay API Notes

- Upload flow: `POST /upload_jobs.json` → `PUT /upload_jobs/{job_id}/files/{upload_file_id}/chunks/{n}` → `POST /upload_jobs/{job_id}/files/{upload_file_id}/complete.json`
- Quick link download: send `asset_id` (not `file_id`) and `disposition: "attachment"`
- Folder listing: `GET /folders.json?parent_id=X` (there is no `/folders/{id}/children.json`)
- Move file: `folder_ids` is array of strings (not int)
- Rate limit responses include `Retry-After` header -- honor it; `APIClient` does this automatically
