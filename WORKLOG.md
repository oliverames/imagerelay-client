# Worklog

## 2026-05-05 - Beta 12: release readiness review and testable beta pipeline

**What changed**: Completed a release-readiness pass focused on correctness risks found in first-run setup, folder filtering, uploads, and move/conflict paths. General Settings now refreshes File Provider status and bootstraps the domain after saving a valid configuration, so a fresh install does not depend on relaunching before the domain appears. Folder Settings now lists only root-level folders, surfaces save failures, and signals File Provider immediately after selection changes. Zero-byte uploads now send the required empty upload chunk for both new files and versions instead of reporting a completed chunk count without uploading data. File Provider parent resolution now fails loudly when configuration is missing or identifiers are invalid, conflict copy uploads require an explicit default file type, and folder move child operations no longer suppress remote move/delete errors. Added the missing Xcode shared test scheme for `ImageRelayClient`, bumped build number to `12`, regenerated the Xcode project, and updated README build/release commands for the current test suite and Beta 12 release flow.

**Verification**: `xcodebuild test -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` passed 50 tests. `swift test --package-path ImageRelayKit` passed 50 tests. `xcodebuild build -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/imagerelay-client-dd-release-check` passed. `git diff --check` passed. `scripts/build-developer-id-release.sh --version 1.0.0-beta.12 --smoke-install` archived with Developer ID signing, exported, notarized and stapled the app, notarized and stapled the DMG, installed the DMG over `/Applications/Image Relay.app`, passed Gatekeeper validation, and confirmed the File Provider extension is registered via `pluginkit`. DMG SHA-256: `a42d6a75d4619478a745042040520a301d25e3a3edb0c6b50fd9f3825571e962`.

**Decisions made**: Kept the host watchdog and extension polling split intact because previous work intentionally deferred removing the host watchdog until extension polling is proven under sustained live use. Kept live account scope conservative: this pass verified install, signing, notarization, extension registration, and automated unit coverage, but did not create or delete fresh live Image Relay assets.

**Left off at**: Beta 12 artifacts are ready in `build/releases/1.0.0-beta.12` and the installed `/Applications/Image Relay.app` is build `12`.

**Open questions**: Still open: rotate the App Store Connect API key when convenient if it is still considered exposed. Before leaving beta, continue testing rename/move/conflict behavior against the selected `Oliver's Stuff` live folder.

---

## 2026-05-05 - Beta 11: two-way delete sync and stale File Provider cache recovery

**What changed**: Fixed the sync failures found while testing Beta 10 against the live Image Relay account. The File Provider working-set enumerator now walks the full selected subtree under `Oliver's Stuff` instead of only exposing the selected top-level folder, which lets remote additions and deletions propagate through Finder. Local deletes now call the Image Relay delete endpoint, handle already-deleted remote objects idempotently, and clear folder subtrees from the tracking database. Remote deletes now flow through working-set deletion detection and remove the local placeholder. Metadata versions now include parent identity so Finder notices parent/path changes even when Image Relay timestamps do not change. Added a one-time File Provider domain schema migration that clears stale tracked state and re-registers the domain for existing Beta installs, which fixes the stale nested `Image Relay/Oliver's Stuff` cache from Beta 10. The menu now shows overdue remote checks honestly instead of strings like `Next check 7 minutes ago`.

**Verification**: Live testing stayed isolated to `Oliver's Stuff` (`2907644`). Local test file `Codex-Beta11-LocalDelete-20260505-150557.md` uploaded, then a Finder delete removed Image Relay file `206039019`. Remote test file `Codex-Beta11-RemoteDelete-20260505-150836.md` uploaded as Image Relay file `206041798`, then an Image Relay delete removed the local Finder placeholder. `fileproviderctl check -P -a /Users/oliverames/Library/CloudStorage/ImageRelay-ImageRelay` passed. `swift test --package-path ImageRelayKit` passed 48 tests. `xcodebuild build -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` succeeded. The Developer ID DMG was notarized, smoke-installed, accepted by Gatekeeper, and published as GitHub prerelease `v1.0.0-beta.11` with SHA-256 `96bf38c424eaa4128e549073cac6c60263e531abc96423ebf64945ed27206fbd`.

**Decisions made**: Chose a domain schema marker plus tracked-state reset for Beta 11 rather than attempting to migrate stale File Provider cache rows in place. The cache had already exposed wrong parentage to Finder, so a clean re-enumeration is safer and easier to reason about than preserving stale identifiers. Kept testing constrained to the selected top-level `Oliver's Stuff` folder per project policy.

**Left off at**: Beta 11 is committed, tagged, pushed, and published. Installed `/Applications/Image Relay.app` is build `11`, and Finder currently shows only the baseline live file in `Oliver's Stuff`.

**Open questions**: Still open: rotate the App Store Connect API key when convenient if it is still considered exposed. NEW: before leaving beta, do one final polish pass focused on rename/move edge cases, pause/download-disabled behavior, first-launch settings, and Finder refresh behavior immediately after a domain reset.

---

## 2026-05-05 - Beta 10: Settings crash on open

**What changed**: Clicking Settings… in the menu bar trapped with `Fatal error: No Observable object of type DomainManager found. A View.environmentObject(_:) for DomainManager may be missing as an ancestor of this view.` Cause: `App.swift` injected `domainManager` only into the `MenuBarExtra` scene, not the `Settings` scene. As soon as any Settings tab read `@Environment(DomainManager.self)` (`AdvancedSettingsView`, `GeneralSettingsView`, etc.) the lookup failed and SwiftUI traps. SwiftUI scenes don't share environment values — each scene at the App level needs its own `.environment` modifier. Added `.environment(domainManager)` to the `Settings { TabView { … } }` block.

**Verification**: `xcodebuild build` clean. Beta 10 release pipeline ran clean: app + DMG notarization Accepted, stapled, `spctl` Notarized Developer ID, smoke install, File Provider extension registered. The Keychain still holds a valid API key (verified via `security` and a direct `curl` against `/folders/2907644.json` returns 200), but the existing entry's access group may not match the current build's signing — Settings → General re-save will overwrite with the correct group.

**Decisions made**: Did not attempt to migrate the Keychain entry programmatically. The `KeychainStore.save` call from Settings → General will replace the entry with one written by the current code-signed binary, which is the cleanest recovery path. If this proves recurrent across rebuilds we should look at whether `kSecAttrAccessGroup` should be omitted on read so any entry under the team prefix is acceptable.

**Left off at**: Beta 10 shipped locally. User re-enters API key in Settings → General to restore sync. All commits 0d44fc9..HEAD push to origin and Beta 10 publishes as `v1.0.0-beta.10` on GitHub.

**Open questions**: None carried.

---

## 2026-05-05 - Beta 9: scale up the sidebar SF Symbol

**What changed**: Beta 8 successfully showed the IR mark in the Finder sidebar but it rendered visibly smaller than the surrounding system icons (iCloud's cloud, Source's diamond, S3's cylinder, etc.). Cause: the original symbol paths were scaled to exactly the cap height (70.46 template units, 0.268× source), while typical system sidebar SF Symbols extend roughly 1.5–1.8× cap height. Bumped the inner path transform from `scale(0.268)` to `scale(0.45)` (≈118 template units, 1.68× cap height) and recentered the glyph on the cap-baseline midline so it extends symmetrically above the capline and below the baseline. Recomputed translation x for each weight margin (Ultralight 105.17, Regular 110.89, Black 120.5) so the glyph stays horizontally centered in each region.

**Verification**: `xcodebuild build` clean. Beta 9 release pipeline: app + DMG notarization Accepted, stapled, `spctl` Notarized Developer ID, smoke install, File Provider extension registered. `killall Finder` invoked after install to flush the icon cache.

**Decisions made**: Picked 0.45× rather than 0.5× to leave a small margin around the glyph at sidebar render size — overshooting risks the mark feeling cramped against the row's edges. The Apple template's cap height (70.459 units) is fixed by Apple and shouldn't move; the right way to make a symbol "bigger" is to scale the paths inside each weight-size group, not adjust the guide lines.

**Left off at**: Beta 9 shipped locally. Awaiting visual confirmation that the resized glyph feels at home with the other Locations icons.

**Open questions**: None carried.

---

## 2026-05-05 - Beta 8: corrected sidebar-icon Info.plist nesting

**What changed**: Beta 7 shipped with `CFBundleSymbolName: ImageRelayMark` as a top-level key in the File Provider extension's Info.plist. Finder still rendered the generic folder icon. Per Apple's [Setting the Finder Sidebar Icon](https://developer.apple.com/documentation/fileprovider/setting-the-finder-sidebar-icon) doc, the symbol name has to be nested two levels deep — `CFBundleIcons` → `CFBundlePrimaryIcon` → `CFBundleSymbolName`. The custom symbol in `Assets.car` was correct all along; macOS just couldn't find the pointer to it. Beta 8 fixes the nesting.

**Verification**: `xcodegen generate` then `PlistBuddy -c "Print :CFBundleIcons"` confirms the regenerated plist now reads `CFBundlePrimaryIcon { CFBundleSymbolName = ImageRelayMark }`. Beta 8 release pipeline ran clean: Developer ID export, app + DMG notarization Accepted, stapled, `spctl` Notarized Developer ID, smoke install over `/Applications/Image Relay.app`, File Provider extension registered via `pluginkit`.

**Decisions made**: Bumped to Beta 8 (rather than rebuild Beta 7 in place) to keep clear version provenance — Beta 7 binaries already exist locally with a different SHA, and overwriting would erase the trail of what was tried. The custom SF Symbol's own structure (Capline/Baseline guides, three weight variants, Regular-S/M/L size variants) was unchanged from Beta 7.

**Left off at**: Beta 8 shipped locally. Sidebar icon needs visual verification in Finder (may require `killall Finder` to clear the icon cache).

**Open questions**: None carried.

---

## 2026-05-05 - Beta 7: custom SF Symbol sidebar icon, error-message UX

**What changed**: Two follow-ups to the Beta 6 release.

(1) Replaced the Beta 6 `SidebarIcon.imageset` (which Finder did not honor for File Provider sidebars) with a real custom SF Symbol, `ImageRelayMark.symbolset`, built from `Image Relay Icon.svg`. Modeled after Apple's reference template (`/Applications/SF Symbols.app/Contents/Resources/badge.checkmark.svg`): viewBox 3300×2200, three Capline/Baseline pairs (S/M/L) with cap height 70.46, weight margins per Apple's defaults. Symbols group contains `Regular-S/M/L` and `Ultralight-S`/`Black-S` so the system can interpolate the missing weights — Xcode 26's asset compiler explicitly rejected a Regular-S-only template with `must have a glyph for Regular weight Medium size`. The IR mark paths are scaled 0.268× and translated so the bounding box runs from cap top to baseline. Replaced `CFBundleIconName: SidebarIcon` with `CFBundleSymbolName: ImageRelayMark` in the extension's Info.plist.

(2) `APIError` now conforms to `LocalizedError`, returning its existing `userMessage` getter as `errorDescription`. Without that conformance, `error.localizedDescription` was rendering as `"The operation couldn't be completed. (ImageRelayKit.APIError error 0.)"` — a fallback message NSError synthesizes for plain `Error` enums, with `0` being the index of the first case (`notAuthenticated`). The Sync Error in the menu bar dropdown now shows the friendly text (e.g. "Your API key is invalid or expired. Check Settings > General.") so a user can act on it without having to read code.

**Verification**: `xcodebuild build` succeeded after the Regular-M/L glyph variants were added; first attempt with Regular-S only failed with the "Regular weight Medium size" error. Beta 7 release pipeline ran clean: Developer ID export, app zip notarization, app stapling, DMG creation, DMG notarization, DMG stapling, `spctl` Notarized Developer ID verification, smoke install over `/Applications/Image Relay.app`, File Provider extension registration confirmed via `pluginkit`. Old smoke-install backups under `~/Applications/Codex Backups/` removed at the user's request.

**Decisions made**: Stuck with the template (monochrome) icon style rather than fall back to a full-color appiconset. The extra work (building a valid SF Symbol from scratch, including margin guides and three weight variants) is the price of the iCloud Drive-style template look that the user asked for. Used Apple's exact y-coordinates for Capline/Baseline guides (625.541/696/1055.54/1126/1485.54/1556) and standard margin x-coordinates so the symbol behaves like a system symbol if the system tries to align margins across variants.

**Left off at**: Beta 7 shipped locally via `--smoke-install`. Sidebar icon and error-message UX both need real-world verification (open Finder, check sidebar; trigger an auth error to confirm friendly message). Push of `0d44fc9..HEAD` to origin/main and GitHub release publish are next when the user is ready.

**Open questions**: None carried.

---

## 2026-05-04 - Beta 6: remote deletion propagation, sidebar icon

**What changed**: Two fixes ahead of the Beta 6 build.

(1) Fixed remote deletions not propagating to local Finder. The bug had two interacting causes. First, `Enumerator.fetchItems()` was calling `db.deleteItem(identifier)` inline during deletion detection, which ran on both the `enumerateItems` and `enumerateChanges` paths. Because `enumerateItems` discards the `deletedIdentifiers` return value (per the documented contract — only `enumerateChanges` may report deletions), a Finder background refresh would silently strip the deleted row from the DB before the poller's `enumerateChanges` could see it, so File Provider was never told to remove the file locally. The fix: keep `fetchItems()` purely diagnostic for deletions, and move the `db.deleteItem` call into the `enumerateChanges` block immediately after `observer.didDeleteItems(withIdentifiers:)`. Second, `RemoteChangePoller.folderIDsToSignal()` short-circuited to `config.selectedFolderIDs` when folder filtering was active, signaling only the top-level selected folders and never their subfolders. With the live test config restricted to `Oliver's Stuff` (folder 2907644), files deleted inside any subfolder of that selection were invisible to the poller. The fix: always use `db.folders().map(\.remoteID)`, which returns every folder the extension has ever discovered regardless of selection.

(2) Added a custom Finder sidebar icon. The File Provider extension previously had `CFBundleSymbolName: cloud` but no asset catalog, so Finder fell back to a generic folder icon in the Locations sidebar. Created `FileProviderExtension/Assets.xcassets/SidebarIcon.imageset/` containing the existing `MenuBarIcon.svg` with `template-rendering-intent: template` and `preserves-vector-representation: true`, then replaced `CFBundleSymbolName` with `CFBundleIconName: SidebarIcon` in the extension's Info.plist. The sidebar now shows the brand mark template-tinted by the system, matching the visual pattern of iCloud Drive's cloud.

**Verification**: `xcodebuild build -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` succeeded with no new warnings after the changes. `xcodegen generate` was run after Project.yml edits so the regenerated `Info.plist` and `project.pbxproj` are committed alongside the source changes.

**Decisions made**: Chose the imageset + `CFBundleIconName` route (template, monochrome) over an `.appiconset` with full-color PNGs. The user explicitly asked for the menu-bar icon style — system-tinted like iCloud Drive — rather than a Google Drive-style branded color icon. The existing menu-bar SVG is already designed as a template at this scale, so it works directly without additional rasterization. If macOS does not pick up an imageset via `CFBundleIconName` for the File Provider sidebar, fallback would be an `.appiconset` referencing the existing `icon_*.png` files from the host app and `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in the extension's build settings.

**Left off at**: Beta 6 prep complete, ready for `scripts/build-developer-id-release.sh --version 1.0.0-beta.6 --smoke-install`.

**Open questions**: None carried.

---

## 2026-05-04 - Beta 5: watchdog poll loop, parallel folder discovery

**What changed**: Two pre-release fixes ahead of the Beta 5 build.

(1) Converted `DomainManager.remotePollLoop` from a variable-interval duplicate of the extension's `RemoteChangePoller` into a fixed 5-minute watchdog. The old loop ran at `pollIntervalSeconds` (same as the extension), causing enumerators to be signaled twice as often as configured and writing duplicate DB timestamps. The new watchdog fires every 5 minutes, only signals enumerators, and stays silent on failure — DB state and failure tracking remain owned by `RemoteChangePoller` with its consecutive-failure threshold logic.

(2) Parallelized `Enumerator.discoverFoldersUnder` using a wave-based `withThrowingTaskGroup`. The previous implementation fetched each folder sequentially (one `GET /folders/{id}.json` at a time). The new version collects all pending folder IDs into a `Set<Int>`, fires all fetches concurrently in a wave, then queues any newly discovered parent IDs into the next wave. `APIClient`'s 5 req/s token-bucket rate limiter naturally gates throughput, so no explicit concurrency bound is needed. Most accounts will finish in a single wave since the initial recursive file listing yields the full folder ID set.

**Verification**: `xcodebuild build -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` succeeded with no new warnings. `swift test --package-path ImageRelayKit` ran 45/45 tests passing across 9 suites. `scripts/build-developer-id-release.sh --version 1.0.0 --smoke-install` succeeded: archived, notarized (accepted), stapled, `spctl` accepted, File Provider extension validated via `pluginkit`, smoke install passed. Beta 5 published to GitHub as `v1.0.0-beta.5` with DMG SHA-256 `308cd28f8448e884fed521d431dc78bfb558cd4dea5b651e25eac94c22541098`.

**Decisions made**: Watchdog is hardcoded at 5 minutes and not user-configurable. The extension's `RemoteChangePoller` is the real poll mechanism; the watchdog is an implementation-detail safety net, not a setting. App Store Connect API key previously flagged as potentially exposed was confirmed to never have been leaked — removed from open items and stale CLAUDE.md note updated.

**Also this session**: Fixed a release script bug (`mkdir -p` before `cd` for the artifact directory -- failed on clean clone where `build/releases/` didn't exist). Rewrote `README.md` as a proper public-facing product page: added Download section, Features list, GitHub release badge, beta status badge, expanded config table with defaults, maintenance CLI flags (`--reset-file-provider-domain`, `--export-diagnostics`), Contributing section. Screenshots deferred -- requires running app pointed at a real account.

**Left off at**: Beta 5 shipped. Next step when ready: take screenshots of the menu bar, Finder sidebar, and Settings window for the README.

**Open questions**: None carried.

---

## 2026-05-01 - Simplify pass: crash fix, persistent DB, shared helpers

**What changed**: Major /simplify refactor sweep across the host app, File Provider extension, and ImageRelayKit. Headline fix: the "Open in Finder" menu action was crashing the host app silently (no crash dialog, no `.ips` report). Root cause was a Swift 6 main-actor isolation violation in the Objective-C completion handler for `NSFileProviderManager.getUserVisibleURL`, which fatal-errored without going through the normal crash reporter. Rewrote `DomainManager.openInFinder()` to use `async/await` inside `Task { @MainActor in }` so the entire flow stays on the main actor, and removed the misleading `startAccessingSecurityScopedResource()` calls that don't apply to File Provider URLs.

Other changes: replaced `DomainManager.openDatabase()` (which opened a fresh GRDB pool on every call, hit ~30 times per minute by the menu bar polling timer) with a persistent `SyncDatabase?` cached on first use. Fixed a real GRDB ordering bug in `SyncDatabase.recentActivity` where two chained `.order()` calls were silently dropping the `timestamp DESC` ordering (`.order()` replaces rather than composes in GRDB). Fixed the `--reset-file-provider-domain` race in `App.swift` where two `DomainManager` instances were both auto-bootstrapping. Consolidated 5 sites of `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` boilerplate behind `AppConfiguration.containerURL()`. Hoisted the duplicated `mapToFileProviderError` switch out of `Extension.swift` and `Enumerator.swift` into a new `FileProviderExtension/APIErrorMapping.swift` exposing `Error.asFileProviderError`. Added `async let` parallelism for `childFolders` + files in `Enumerator.fetchItems`. Replaced stringly-typed pause choices (`"30m"`, `"1h"`, `"tomorrow"`, `"indefinite"`) with a `PauseDuration` enum. Added `TrackedItem.makeFolder/makeFile` factories that collapse 9-field positional constructions in the discovery paths. Replaced hand-rolled JSON in `recordFolderMoveInProgress` with a `FolderMovePayload: Codable, Sendable, CustomStringConvertible` struct (wire format kept compatible via `.secondsSince1970`). Hoisted `RelativeDateTimeFormatter` and `DateFormatter` allocations to static lazy properties in `MenuBarView` and `DiagnosticsExporter`. Cleaned up 9 timestamped `.codex-backups/` directories from a previous Codex session per the user's CLAUDE.md convention.

**Verification**: `xcodebuild build -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` succeeded with no new warnings. `swift test --package-path ImageRelayKit` ran 45/45 tests passing across 9 suites. `xcodegen generate` was run after adding `APIErrorMapping.swift` so the new file is registered in `project.pbxproj`. No live-credential test was performed.

**Decisions made**: Held back three reviewer-flagged items deliberately. (1) Removing `DomainManager.remotePollLoop` (which duplicates `RemoteChangePoller.pollLoop` in the extension) is deferred until after the first live-credential smoke test confirms the extension's poller fires reliably under macOS 26 File Provider scheduling — until then, both poll loops have only been compiling, not running. (2) Parallelizing `discoverFoldersUnder` (currently 1 recursive file scan + N sequential per-folder GETs) is deferred until real folder-count timing data is available; the simplest fix is a `TaskGroup` with bounded concurrency, but the better fix may be a BFS walk via `parent_id`. (3) Phase string constants are skipped permanently — the "Idle"/"Downloading"/etc. strings are display-only with low divergence risk. The `TrackedItem` factories were scoped to discovery paths only; create/modify paths in `Extension.swift` use synthetic version strings that don't fit a "remote object → tracked item" factory.

**Left off at**: Beta 2 release artifacts still need a fresh end-to-end smoke packaging and install pass from the cleaned state before any future beta release (carried from 2026-04-30). The App Store Connect API key still needs rotation when convenient (carried from 2026-04-30). The `openInFinder` async/await rewrite needs validation against a real registered File Provider domain — the path was crash-only-tested previously. The persistent DB connection refactor changes the lifecycle of `SyncDatabase` for the host app; if anything observes pool pragmas or expects fresh connections, it would surface during the live-credential test.

**Open questions**: Still open: rotate App Store Connect API key (carried). Still open: Beta 2 smoke packaging pass (carried). NEW: should the host-side `remotePollLoop` be removed entirely once we confirm the extension's poller fires under real load, or kept as a watchdog with a much longer interval (say 5 min)? NEW: does the Image Relay API support batched folder fetch, or is BFS via `parent_id` the only path to fix the `discoverFoldersUnder` N+1?

---

## 2026-04-30 - Local beta wipe and repo purge

**What changed**: Removed the local `/Applications` beta app, beta backup copies, release export directories, Image Relay-specific app containers, app group data, CloudStorage mount, and the lingering DerivedData File Provider registration from this Mac. Deleted the GitHub prerelease and tag `v1.0.0-beta.1`. Rewrote git history to purge `build/` and `.codex-backups/`, then force-pushed the cleaned `main` branch.

**Decisions made**: Kept the new Developer ID release scripts and worklog trail in the repo, but treated all beta artifacts and repo-local key copies as disposable after explicit approval. Left the 1Password-managed App Store Connect key alone, even though it should still be considered exposed and rotated later.

**Left off at**: The machine is back to a clean slate for ImageRelayClient, with no registered File Provider extension and no installed beta build. The repo is ready for a fresh clean packaging and install verification pass before any future beta release.

**Open questions**: Still open: rotate the App Store Connect API key when convenient. Still open: run a fresh end-to-end Beta 2 smoke packaging and install pass from the cleaned state before creating another release.

---

## 2026-04-30 - Developer ID release workflow fixed for Beta 2

**What changed**: Built and verified a clean Developer ID release path outside the repo's iCloud-synced tree. Added `scripts/ensure-developer-id-profiles.py` to create or reuse the explicit App Store Connect bundle IDs for `com.oliverames.imagerelay-client` and `com.oliverames.imagerelay-client.fileprovider`, create `MAC_APP_DIRECT` Developer ID provisioning profiles for both targets, and install those profiles locally. Added `scripts/build-developer-id-release.sh` to run `xcodegen`, archive to `/tmp`, manually export with the correct Developer ID certificate and profile names, notarize and staple the app zip, create a DMG from the stapled app, notarize and staple the DMG, and run `codesign --verify --deep --strict`, `spctl`, and `stapler validate` checks. The script also supports `--smoke-install`, which replaces `/Applications/ImageRelayClient.app` from the notarized DMG and verifies both the host app process and embedded `FileProviderExtension` process launch.

**Verification**: Manual export using the new `MAC_APP_DIRECT` profiles succeeded from `/tmp`, with both the app and File Provider extension signed by `Developer ID Application: Oliver Ames (PV3W52NDZ3)` and embedding the new explicit Developer ID provisioning profiles rather than the previous Xcode-managed `Mac Team Provisioning Profile: *`. The exported app passed `codesign --verify --deep --strict`. The app zip notarization was accepted and stapled, then the DMG notarization was accepted and stapled. The installed `/Applications/ImageRelayClient.app` now passes `spctl -a -vv` as `Notarized Developer ID`, and launching it starts both `/Applications/ImageRelayClient.app/Contents/MacOS/ImageRelayClient` and `/Applications/ImageRelayClient.app/Contents/PlugIns/FileProviderExtension.appex/Contents/MacOS/FileProviderExtension`. The active config remains restricted to selected folder ID `2907644`, which maps to `Oliver's Stuff`.

**Repo hygiene**: Added `.gitignore` entries for `build/` and `.codex-backups/` so future release artifacts and local backups stay out of source control. The repo-local `build/release-1.0.0-beta.1/AuthKey.p8` copy and related beta artifact trees were deleted after explicit approval, while the 1Password-managed system key remains untouched. The App Store Connect API key should still be treated as exposed and revoked/reissued. Git history was rewritten locally to purge the old committed `build/` and `.codex-backups/` copies from every ref.

## 2026-04-29 - Beta continuation after 1.0.0 BETA 1

**What changed**: Added `BETA_TESTING.md` with the practical tester checklist for first launch, credentials, selected-folder sync, remote discovery, upload, download-on-open, pause/resume, quit/relaunch, domain reset, file operations, bad API key, network failure, and diagnostics export. Fixed the Finder placeholder date bug by parsing Image Relay `updated_on` metadata into `RemoteFile`/`RemoteFolder`, persisting it on `TrackedItem`, migrating the sync database to `v4`, and returning it through `FileProviderItem.contentModificationDate`. Added focused model/database tests for date parsing and persistence. Added Advanced settings "Export Diagnostics", which writes sanitized config, recent activity, sync progress, File Provider domain status, and recent ImageRelayClient subsystem logs to a user-chosen folder without exporting API keys.

**Verification**: `swift test --package-path ImageRelayKit` passes with 44 tests. `xcodebuild build -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` succeeds. `xcodegen generate` was run after adding `DiagnosticsExporter.swift`; `Project.yml` now explicitly keeps the extension version/build fields tied to `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.

**Release DMG smoke result**: Downloaded GitHub prerelease `v1.0.0-beta.1` DMG and verified the SHA-256 digest matched GitHub's asset digest (`e1279673de7ea4894e5615962474d3363906f21320e08218bce81edcdcc4a77d`). `spctl` accepts the DMG and mounted app as notarized Developer ID from Oliver Ames. Installing the released app from the DMG failed to launch: macOS blocked the embedded File Provider extension with AMFI `No matching profile found` for restricted entitlements `com.apple.developer.team-identifier` and `keychain-access-groups`. The released app and appex contain an Xcode-managed `Mac Team Provisioning Profile: *` development profile with provisioned devices even though the binaries are Developer ID signed. Also observed `codesign --deep --strict` failure because `com.apple.FinderInfo` xattrs are present on the embedded appex/bundles. The previous `/Applications/ImageRelayClient.app` was backed up before install and restored after the failed launch; the failed release install was moved to `~/Applications/Codex Backups/ImageRelayClient.app.v1.0.0-beta.1.failed-launch`.

**Left off at**: Live smoke testing against Image Relay did not proceed because the released DMG cannot launch its File Provider extension. No File Provider domain reset was attempted and no Image Relay folder content was touched. When the release packaging is fixed, restrict all live Finder/Image Relay smoke activity to the selected `Oliver's Stuff` folder only.

**Open questions**: Need a source-controlled release/export workflow that produces Developer ID signed/notarized DMGs without embedding development provisioning profiles or FinderInfo xattrs.

---

## 2026-04-29 - 1.0.0 BETA 1 release

**What changed**: Finished the native macOS ImageRelayClient beta and published GitHub prerelease `v1.0.0-beta.1`. Added the Icon Composer source asset under `ImageRelayIcon.icon`, generated a standard `AppIcon.appiconset` so macOS emits `AppIcon.icns`, moved the host app to marketing version `1.0.0`, and made the File Provider extension inherit the shared version/build values. Added a hidden `--reset-file-provider-domain` maintenance launch argument and a visible Advanced settings "Reset Finder Sync" button so the signed host app can remove/re-add the local File Provider domain.

**Decisions made**: Kept the Icon Composer `.icon` package bundled as source material, but generated a normal macOS app icon set because the `.icon` package alone compiled into `Assets.car` without producing `CFBundleIconFile`/`AppIcon.icns`. Kept the upload completion path simple: trust the final chunk response when it includes `finished` and `asset_id`, with one immediate upload-job fallback fetch if that response is incomplete.

**Left off at**: Released DMG is at GitHub release `v1.0.0-beta.1`, attached with checksum. Local File Provider domain was reset and verified against the live Image Relay account. Oliver's Stuff now shows remote-only files plus the local two-way upload in Finder. Local untracked `build/` and `.codex-backups/20260429/` remain intentionally outside git.

**Open questions**: Still open: delete temporary local notarization key copy at `build/release-1.0.0-beta.1/AuthKey.p8` after explicit confirmation. Still open: dates in Finder currently show Dec 31, 1969 for remote placeholder files because item date metadata is not yet mapped to a useful Finder date.

---

## 2026-04-07 -- Python removal, sync gap implementations, merged to main

**What changed**: Removed all Python implementation; project is now Swift-only. Merged `feature/native-macos-rebuild` into main and force-pushed after scrubbing 226MB GRDB pack file from git history with `git-filter-repo`. Implemented all remaining sync feature gaps:

- **Remote deletion propagation**: `Enumerator.fetchItems()` now diffs remote identifier set against `db.children(of:)` and returns deleted identifiers. Only `enumerateChanges` reports deletions to the File Provider; `enumerateItems` ignores them (correct per Apple API contract).
- **Folder filtering (UI)**: `FoldersSettingsView` replaced pin toggles with sync toggles backed by `AppConfiguration.selectedFolderIDs`. Empty selection = all folders sync. UI shows "X of Y selected" when a subset is chosen.
- **Conflict copy preservation**: When content version mismatch is detected in `modifyItem`, local edits are uploaded to Image Relay as a new asset with a conflict name (`filename (conflict copy YYYY-MM-DD HH:MM:SS).ext`) before re-fetching the canonical remote version. Both copies appear in Finder on next enumeration.
- **Folder move emulation**: Folder renames-with-parent-change are emulated via create-new → move-children → delete-original sequence, since the Image Relay API has no direct folder-move endpoint.
- **Progress tracking (totalSteps)**: Added `beginOperation()` helper that increments `totalSteps` on each sync op, reset when transitioning idle→syncing. Progress bar now shows live "X of Y" rather than indeterminate.
- **Retry-After honoring**: `APIClient.executeRaw` now inspects `lastError` for `.rateLimited(retryAfter:)` and uses the server-specified delay (capped at `maxRetryDelay`) instead of exponential backoff.
- **`TrackedItem.isPinned` removed**: Folder selection moved entirely to `AppConfiguration.selectedFolderIDs`. DB v3 migration drops the column.

**Decisions made**:
- **Conflict copy lives in IR, not just local**: Uploading the conflict copy to Image Relay as a new file rather than saving it locally means both versions appear in Finder naturally and the user can decide what to keep. Neither version is silently discarded.
- **Folder filtering is visibility, not availability**: Unselected folders don't appear in Finder but their API data is still fetched; they're filtered client-side at the root enumerator. This avoids a gap where child folders could accidentally inherit an unselected parent.
- **Folder move emulation is non-atomic**: Move-via-recreate is inherently lossy if the process is interrupted mid-sequence. Accepted this limitation -- atomic folder move would require IR API support.
- **`selectedFolderIDs` semantics**: Empty array = all sync. Toggling on a subset fills the set with all folder IDs minus the deselected ones; toggling all back on reverts to empty. Stored in `config.json`, not the DB.

**Left off at**:
- Still open: Never tested with real Image Relay credentials. No actual sync run against the live account; API key, domain registration, and enumeration all untested end-to-end.
- Still open: `move_file` API -- unknown whether `folder_ids` still expects an array of strings in v2.
- Conflict copy upload uses a full new upload job (not a file version). The conflict file lands in the same folder as the original but has no relationship to the original in IR. User must manually delete it after resolving.
- `beginOperation()` increments `totalSteps` but `completedSteps` increment happens in `incrementProgress()` -- verify these stay in sync if an operation errors partway through.

**Open questions**:
- Will the File Provider extension correctly load the app group container when launched outside of Xcode?
- The macOS 26 `MenuBarExtra .window` style renders with system menu chrome -- is there a way to override for a more custom look?

---

## 2026-04-06 -- Native macOS rebuild: complete File Provider app with SwiftUI

**What changed**: Built a complete native macOS rebuild of the Python sync client on `feature/native-macos-rebuild` branch (in `.worktrees/native-rebuild`). 17-task plan executed via subagent-driven development, then all 13 feature gaps from the Python version filled in:

- **ImageRelayKit** (Swift package, 30 unit tests passing): async/await `APIClient` with rate limiting + retry, GRDB-backed `SyncDatabase`, `RemoteFolder`/`RemoteFile`/`QuickLink`/`UploadJob` models, `ItemIdentifier` (folder-{id}/file-{id}), `AppConfiguration` with shared app group JSON, `SyncAnchor`, `ConflictResolver`, `SyncPauseState`, `SyncProgressState`.
- **FileProviderExtension**: full `NSFileProviderReplicatedExtension` impl - `Enumerator`, `FileProviderItem`, on-demand download via quick links, chunked uploads (5MB chunks), version uploads, folder/file create/rename/move/delete, `RemoteChangePoller` honoring sync direction flags and pause state, `.DS_Store` filtering, conflict detection via version mismatch.
- **ImageRelayClient host app**: `MenuBarExtra` with custom `MenuRowButtonStyle` (hover state), live status header (pulse animation when syncing), progress bar, recent activity, pause submenu (30m/1h/tomorrow/indefinite/resume), Settings window with 4 tabs (General/Folders/Activity/Advanced), `DomainManager` polling shared DB every 2s, `SMAppService` login item.
- **Project**: XcodeGen-generated Xcode project, both targets code-signed with team `PV3W52NDZ3`, app group `group.com.oliverames.imagerelay-client`, built and runs on macOS 26.4.

**Decisions made**:
- **macOS 26 SDK API changes discovered the hard way**: `fetchContents` lost its `Bool` parameter; `NSFileProviderItemProtocol` uses `itemIdentifier`/`parentItemIdentifier` (not `identifier`/`parentIdentifier`); `swift-tools-version` must be `6.2` for `.macOS(.v26)`; `.tabItem {}` modifier on `Settings { TabView { } }` creates duplicate tabs - must use the new `Tab("Title", systemImage:) { }` API.
- **Swift 6 strict concurrency in File Provider**: Completion handlers passed to `Task { }` closures need `nonisolated(unsafe) let completionHandler = completionHandler` because they're not `Sendable`. Class-level state captured in `Task` closures requires `@unchecked Sendable` on the class.
- **`.menuBarExtraStyle(.window)` doesn't auto-style**: Plain `Button` views inside still render as menu items. Built a custom `MenuRowButtonStyle` with `.onHover` for proper hover feedback.
- **Dropped multi-folder symlink aliases**: The Python app creates a canonical local file plus symlinks for files appearing in multiple folders. The File Provider model handles this naturally because the system enumerates per-folder; the same file ID just appears in multiple parent containers without symlinks.
- **`AppConfiguration.save` must create parent directory**: First-run on a fresh app group container can fail with "config.json doesn't exist" because the container directory itself isn't created until first write.
- **Skipped pushing to GitHub**: First scaffolding commit accidentally bundled `ImageRelayKit/.build/` (later removed in a follow-up commit) leaving a 226MB pack file in history. Push rejected by GitHub's 100MB file limit. Branch lives only locally for now; `git filter-repo` would be needed to scrub history before pushing.

**Left off at**:
- App is built, code-signed, and running. Menu bar popover and Settings window both render. Configuration save error is fixed.
- **Not yet verified by user after final fixes**: hover state on menu bar rows, duplicate tabs gone in Settings (need to use Tab API rebuild), Settings window comes to front when opened from menu.
- **Never tested with real Image Relay credentials**: API key not yet entered, File Provider domain not yet registered with the system, no actual sync run against the real Image Relay account.
- **`.build` history pollution**: Need to scrub the 226MB pack file from `feature/native-macos-rebuild` before this branch can be pushed to GitHub. Easiest path: install `git-filter-repo` and rewrite history to drop `ImageRelayKit/.build/` from all commits.

**Open questions**:
- Will the File Provider extension correctly load the app group container when launched outside of Xcode? The container path may differ between Debug builds and the user's actual home.
- The macOS 26 `MenuBarExtra .window` style still renders with system menu chrome (gray translucent background) - is there a way to override this for a more custom look like Tailscale/Bartender, or is this the intended Tahoe styling?
- The Image Relay `move_file` API expects `folder_ids` as an array of strings - is this still correct for v2, or has it changed since the Python client was last updated?

---

## 2026-04-06 -- Selective folder sync, recursive file fix, GUI folder picker

**What changed**: Added selective folder sync feature across all layers (config, sync engine, CLI, GUI). Users can now choose which folders to sync via `folders list/select/show/clear` CLI commands or a native macOS dialog in the menu bar app (Settings > Select Folders to Sync...). The sync engine filters both downloads and uploads to only include selected folders and their descendants.

Fixed a critical bug where `recursive=True` on `list_files()` never actually worked. Python's `bool` serialized as `"True"` (capital T) but the Image Relay API expects lowercase `"true"`. This meant the sync client was never fetching files from subfolders.

Added subfolder discovery: `list_folders()` only returns top-level folders, so subfolders are now discovered from file `folder_ids` and their metadata fetched individually via `get_folder()`. Changed the sync root from 1923998 (Brand Documents and Resources) to 1909821 (account root) to enable cross-folder selection.

When folders are selected, files are fetched from each selected folder directly instead of scanning the entire account root, which is much faster.

**Decisions made**:
- Include-list approach (not exclude-list) for folder selection. Empty list = sync all (backwards compatible).
- Ancestor folders are included in the allowed set for directory structure creation but NOT in upload prefixes, preventing accidental uploads to ancestor-only directories.
- The `.pth` editable install is broken with Python 3.14 (spaces in iCloud path). Using `PYTHONPATH` as workaround for now.
- Folder picker uses NSAlert with accessory scroll view (checkboxes) rather than a standalone NSWindow, matching the existing About dialog pattern.

**Left off at**:
- Sync is actively downloading Photography folder content (~35 files downloaded, hundreds more to go). First sync is slow due to 411+ subfolder metadata fetches; subsequent syncs will be fast.
- The folder picker loads slowly for large accounts because it fetches all files to discover subfolders. Could optimize by caching folder metadata in the database.
- Duplicate log lines appear (each log entry is doubled). Likely a dual-handler issue in logging_utils.py.
- The Python dock icon appears when running the GUI. Needs `LSUIElement` in an app bundle or `LSBackgroundOnly` to suppress.

**Open questions**:
- Should subfolder metadata be cached in the database to avoid re-fetching on every sync pass?
- Should the file fetching strategy change to fetch from each top-level subfolder individually (parallel) rather than from root?
- The editable install (.pth file) doesn't work with Python 3.14 on an iCloud path with spaces. Is this a Python bug or setuptools issue?

---
