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

# Build macOS host (macOS 26 SDK required). CODE_SIGNING_ALLOWED=NO is
# required for plain dev/compile-check builds: the macOS targets use Manual
# "Developer ID Application" signing (since the 1.4.2 release prep) and a
# signed build wants provisioning profiles only the release script sets up.
xcodebuild build \
  -project ImageRelayClient.xcodeproj \
  -scheme ImageRelayClient \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

# Run all unit tests (currently 299:
# 221 ImageRelayKitTests + 78 FileProviderExtensionTests)
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

**Keychain Prompt-Storm Protection Guidelines**:
1. **Testing Bypass**: The `KeychainStore` automatically detects test mode (e.g., `XCTest` loading) and diverts secure storage to a thread-safe, in-memory `testStore` dictionary. Never hit the real macOS Keychain APIs during unit testing to avoid password prompt storms.
2. **Access Control List (ACL) Retention**: When updating a Keychain credential (e.g., OAuth tokens), always perform in-place updates using `SecItemUpdate` instead of deleting and recreating. Recreating items wipes out the user-approved "Always Allow" application signature, triggering a brand-new popup storm.
3. **Selective Credential Reading**: Only query the Keychain for the active `authMethod` credentials (API Key or OAuth tokens), rather than querying both blindly.
4. **Bypass for Idle Operations**: When performing unauthenticated background sync operations (e.g., polling intervals), use `AppConfiguration.loadWithoutSecrets` to read the configuration from disk without hitting the Keychain at all.

## File Provider Patterns

**Swift 6 concurrency in File Provider**: Completion handlers passed into `Task {}` closures must be captured as `nonisolated(unsafe)`:
```swift
nonisolated(unsafe) let completionHandler = completionHandler
Task { completionHandler(...) }
```

**Enumeration vs. changes**: `enumerateItems` does a fresh full load -- never report deletions here. `enumerateChanges` does incremental updates -- this is the only place to call `observer.didDeleteItems(withIdentifiers:)`.

**Deletion detection pattern** in `Enumerator.fetchItems()`: build `remoteIdentifiers` set while processing API results, then diff against `db.children(of: containerIdentifier.rawValue)` at the end.

**Quick-link hygiene** (added 2026-06-10 after a colleague flagged this
client's quick-links on restricted-use assets in the admin audit list; the
API key was disabled over it):
- Quick-links are audit-visible to account admins. Never mint one that can
  outlive its purpose.
- *Transient* links (internal download pipeline: `fetchContents`, partial
  content, rename-by-version) must use
  `QuickLinkLifetime.transientExpiryDateString()` (2 days; calendar-date
  parsing makes 1 day unsafe near midnight) and be deleted via
  `QuickLinkJanitor.deleteTransientQuickLink`, which queues failed deletes
  in the `orphaned_quick_links` table for the startup sweep.
- *User-facing* links (Finder Copy actions): Copy Download Link = 7 days,
  Copy Public Link / QR / mail = 1 year, Copy Long-Lived Public Link = no
  expiry. These are intentional shares and are never auto-deleted or swept.
- The startup sweep (`QuickLinkJanitor.sweep`) only deletes IDs this client
  queued. Do NOT add a list-all-quick_links sweep: it cannot distinguish
  this client's transient links from anyone's intentional share links, and
  it adds bulk API churn against the shared 5-RPS budget.

## Known State

- **API key rotated (2026-06-10)**: the old key was disabled after a
  colleague flagged this client's quick-links on restricted-use assets; a
  replacement was issued the same day and stored in 1Password ("Image Relay
  API Key" in Development). The new key still needs to be entered in the
  installed app's Settings, after which live verification of the quick-link
  lifecycle (transient expiry, janitor sweep) can run.
- **Never fabricate test files on the server**: Release verification must NOT
  create synthetic fixtures (throwaway files/folders) on the live Image Relay
  account. Verify with real assets only, through normal app usage. The old
  synthetic `run-live-sync-matrix.sh` harness was removed for this reason; it
  had stranded soft-deleted `Codex-ReleaseLiveMatrix-*` fixtures in a shared
  folder, which a colleague flagged. Do not reintroduce server-side test
  fabrication in any form.
- **Live testing scope**: When exercising live sync with real assets, keep it
  inside the selected `Test Library` folder (`12345`) unless explicitly
  asked otherwise.
- **Current release**: `1.4.3` / build `46` was published on 2026-06-10
  (release-candidate checks, Developer ID notarization, GitHub release,
  published-DMG SHA verification, smoke install on this Mac). It contains the
  quick-link lifecycle fixes, long-duration rate-limit hardening, the login
  regression fix, and the OAuth UI removal. The last full live sync matrix
  remains the `1.4.0` / build `43` matrix in `Test Library` (`12345`) from
  2026-06-02.
- **Homebrew tap missing**: `scripts/sync-cask-to-tap.sh` targets
  `oliverames/homebrew-tap`, which does not exist on GitHub. The in-repo cask
  is updated, but publishing to a public tap requires creating that repo
  first (user decision).
- **Webhook relay worker decommissioned (2026-06-25)**: the
  `Cloudflare/imagerelay-webhook-relay` worker was deployed at
  `https://imagerelay-webhooks.amesvt.com` on 2026-06-10 but torn down on
  2026-06-25 because it contradicted the standing decision to never
  implement a consumer webhook relay (Phase 7). Teardown deleted the
  custom-domain binding, the Worker script, and the auto-managed DNS AAAA
  record; verified afterward (endpoint HTTP 530, script absent, 0 DNS
  records, binding gone). The Image Relay webhook subscription was never
  created (blocked on the daily API quota), so there was no upstream
  cleanup. Do not redeploy this worker or create an Image Relay webhook
  subscription; change notifications stay poll-based. The 1Password item
  "Image Relay Webhook Relay Token" (former worker secret `RELAY_TOKEN`)
  is now dead and can be deleted after confirmation. The
  `Cloudflare/imagerelay-webhook-relay/` source directory was removed from
  the working tree on 2026-06-25 (retained in git history).
- **Release workflow**: GitHub publishing is unblocked. The release runbook (build via `scripts/build-developer-id-release.sh`, published-release verification, and the live-verification guardrails) lives in the `ames-dev-workflows:imagerelay-release` skill; invoke it for any release-candidate work.
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
fresh short-expiry quick-link, downloads to a temp file, and deletes the
quick-link (on both success and failure paths — being stateless, a failed
delete can't be retried later, so the 2-day expiry is the backstop).
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
