# imagerelay-client

Native Image Relay DAM client. Swift 6, SwiftUI, File Provider API
(`NSFileProviderReplicatedExtension`). Two host apps share one
`ImageRelayKit` Swift package:

- **macOS** (macOS 26+): full bidirectional sync, MenuBarExtra UI, metadata
  editing, admin features. Codename target: `ImageRelayClient`.
- **iOS** (iOS 18+): read-only on-demand browser whose primary purpose is
  surfacing Image Relay folders inside the Files app via a stateless File
  Provider extension. Codename target: `ImageRelayClientiOS`.

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

# Run all unit tests (currently 118 across 19 suites:
# 108 ImageRelayKitTests + 10 FileProviderExtensionTests)
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
- **Release script**: `scripts/build-developer-id-release.sh` requires a `mkdir -p` of the parent before the `cd` that resolves the artifact path -- fixed in Beta 5. On a clean clone `build/releases/` won't exist; the script now creates it first.

## macOS 26 SDK Gotchas

- `fetchContents` completion handler takes 3 args (dropped the Bool vs. older SDK)
- Settings tabs: use `Tab("Title", systemImage:) { }` -- NOT `.tabItem {}` (creates duplicate tabs)
- Settings window for `LSUIElement` apps needs `NSApp.activate(ignoringOtherApps: true)` to come to front
- `NSFileProviderItemProtocol`: `itemIdentifier`/`parentItemIdentifier` (not `identifier`/`parentIdentifier`)
- **`Settings` scene needs its own `.environment(...)` injection.** SwiftUI scenes (`MenuBarExtra`, `Settings`, etc.) at the App-level are siblings, not nested. An `.environment` on `MenuBarExtra` does not reach `Settings`. Apply `.environment(domainManager)` to every scene whose body reads it. Symptom: `Fatal error: No Observable object of type X found` when opening Settings.
- **Finder sidebar icon Info.plist nesting.** Per Apple's *Setting the Finder Sidebar Icon* doc, `CFBundleSymbolName` for File Provider extensions must live nested at `CFBundleIcons.CFBundlePrimaryIcon.CFBundleSymbolName`, NOT at the top level. A top-level `CFBundleSymbolName` is silently ignored and Finder falls back to the generic folder. The symbol can be a built-in SF Symbol or a custom `.symbolset` in the extension's own asset catalog.
- **Custom SF Symbols require multi-size variants.** Xcode 26's asset compiler rejects a `.symbolset` SVG that only declares `Regular-S`; it errors `Symbol image file ... must have a glyph for Regular weight Medium size`. Include `Regular-S`, `Regular-M`, `Regular-L` (and at least Ultralight-S + Black-S for weight interpolation) using Apple's standard Capline/Baseline guide y-coordinates (S: 625.541/696, M: 1055.54/1126, L: 1485.54/1556). Glyph paths inside should typically extend to ~1.5–1.7× cap height to match system sidebar symbols.

## iOS Port Notes

**Cross-platform discipline.** ImageRelayKit is the portability seam: it
imports only `Foundation`, `GRDB`, `Security`, `os.log`. No `AppKit` /
`UIKit` references — those belong in the host apps. Adding a new feature
to the kit means it works on both platforms; adding a new feature to a
host app means it works only there.

**iOS extension is stateless and on-demand.** Unlike the macOS extension,
the iOS extension does NOT use `SyncDatabase` or `RemoteChangePoller`.
Every enumeration calls the API live; every `fetchContents` mints a
fresh quick-link, downloads to a temp file, and deletes the quick-link.
`Enumerator.currentSyncAnchor` returns nil so the system never asks for
incremental changes — this trades efficiency for simplicity, appropriate
for a mobile read-only client.

**iOS read-only by protocol.** `NSFileProviderReplicatedExtension`
requires `createItem`/`modifyItem`/`deleteItem` — they aren't `@optional`.
The iOS implementation provides them as no-ops returning
`NSFileProviderError(.cannotSynchronize)` with a read-only message so Files
doesn't surface upload attempts as authentication failures.

**Service/state files compiled by both targets.** The Codex-authored
`CollectionsService.swift`, `ProductsService.swift`,
`LibraryAdminService.swift` (each containing a service + an
`@Observable` state class) live under `ImageRelayClient/<feature>/`
but are listed as additional `sources:` paths in the iOS target. The
*View* siblings (e.g. `CollectionsBrowserView.swift`) stay macOS-only;
the iOS app provides its own SwiftUI views in
`ImageRelayClientiOS/Library/`.

**Domain identifiers differ.** macOS:
`com.oliverames.imagerelay-client.domain`. iOS:
`com.oliverames.imagerelay-client.ios.domain`. Both use the same App
Group `group.com.oliverames.imagerelay-client` and the same Keychain
access group `PV3W52NDZ3.com.oliverames.imagerelay-client`, so the
`AppConfiguration` JSON + API key shape is identical, but each platform
has its own per-device container and tracks the domain separately.

**iOS `Project.yml` gotchas.** `deploymentTarget` is a dict (`macOS:` +
`iOS:`). The iOS app target's `dependencies:` does NOT include Sparkle.
Bundle IDs are distinct (`*.ios` and `*.ios.fileprovider`) to avoid
provisioning-profile collisions on dev machines. iOS Debug uses
Automatic signing; macOS Release uses Manual `Developer ID Application`.

## Image Relay API Notes

- Upload flow: `POST /upload_jobs.json` → `PUT /upload_jobs/{job_id}/files/{upload_file_id}/chunks/{n}` → `POST /upload_jobs/{job_id}/files/{upload_file_id}/complete.json`
- Quick link download: send `asset_id` (not `file_id`) and `disposition: "attachment"`
- Folder listing: `GET /folders/{id}/children?per_page=100&page=N`; `GET /folders/{id}/children` without pagination currently returns 404
- Move file: `folder_ids` is array of strings (not int)
- Rate limit responses include `Retry-After` header -- honor it; `APIClient` does this automatically
