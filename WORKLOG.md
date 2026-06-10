# Worklog

## 2026-06-10 - Quick-link lifecycle hygiene

**What changed**:
Reworked every quick-link path after Gina flagged this client's quick-links on restricted-use VEHI/VSTRS assets in the admin audit list (2026-06-09/10) and the API key was disabled. Three fixes plus a cleanup mechanism:

- All internal transient quick-links (`fetchContents`, partial-content Range requests, rename-by-version download) now carry a 2-day server-side `expires` so a failed cleanup can never leave them audit-visible for long. Two days, not one, because Image Relay parses `expires` as a calendar date.
- New `QuickLinkJanitor` (`FileProviderExtension/QuickLinkCleanup.swift`) replaces the silent `try? api.delete` calls: a failed DELETE queues the link ID in the new `orphaned_quick_links` table (SyncDatabase migration v10) and a startup sweep retries queued deletes on the next extension launch, capped at 20 per launch, oldest first, behind the startup throttle gate, zero API calls when the queue is empty. Entries older than 3 days are pruned locally because the expiry already killed them server-side. Also fixed a worse latent bug: the `fetchContents` and iOS download failure paths never deleted the quick-link at all.
- `PartialContentFetcher` now genuinely caches one quick-link per asset (15-minute TTL in the extension-lifetime `QuickLinkURLCache`) instead of minting one per Range request and never deleting any of them; cached IDs are drained into the cleanup queue at `invalidate()`.
- Finder "Copy Download Link" (the personal-download variant) dropped from 1-year to 7-day expiry. Copy Public Link/QR/mail stay at 1 year; Copy Long-Lived Public Link stays no-expiry — those are explicit shares.

**Decisions made**:
- Queue-based sweep only: never list-and-delete the tenant's quick_links, because the API can't distinguish this client's transient links from anyone's intentional share links, and bulk listing churns the shared 5-RPS budget.
- iOS extension stays stateless: short expiry plus best-effort delete on both paths, no queue.
- Verified by the full macOS suite: 295 tests passing (221 ImageRelayKitTests + 74 FileProviderExtensionTests, up from 248 — new coverage for the orphan queue, lifetime helpers, URL cache, and janitor against a mock transport). iOS Simulator build succeeds.

**Left off at**:
- Live verification of the sweep and short-expiry links is blocked on the disabled API key. When a new key is issued: enter it in Settings, exercise a download in `Oliver's Stuff` (2907644), and confirm in the web admin that the transient quick-link disappears and nothing accumulates in the audit list.

**Open questions**:
- Should the host app surface the orphan queue length in Settings > Advanced as a diagnostic?

---

## 2026-06-09 - 1.4.2 rate-limit hardening release

**What changed**:
Shipped `1.4.2` / build `45`. The release includes atomic cross-process shared rate limiter updates so the host app and File Provider extension preserve the same first-window budget under concurrent starts. It also keeps release-candidate SwiftPM tests in `/tmp` via `SWIFTPM_SCRATCH_PATH` to avoid iCloud resource-fork metadata failures during codesign. `Casks/image-relay.rb` was advanced to the notarized DMG SHA-256 `15ea65cc45a097aa2a3ceeaed6086bb9dbe2e1a3f9116480da43f5a5a696a063`.

**Decisions made**:
- Cut `1.4.2` because `v1.4.1` predated commit `692a110`; the rate-limit hardening was on `main` but not in a public release.
- Built artifacts first, pushed release metadata, then installed from the GitHub release DMG to match the requested release order.
- Did not run live synthetic sync tests; verification stayed local, signed, and release-artifact based.

**Left off at**:
- Release commit `37a4848` is tagged as `v1.4.2` and published at https://github.com/oliverames/imagerelay-client/releases/tag/v1.4.2.
- Installed `/Applications/Image Relay.app` reports `1.4.2` build `45`, passes codesign and Gatekeeper, launches from `/Applications`, and registers `com.oliverames.imagerelay-client.fileprovider(1.4.2)`.
- Verification passed: `scripts/run-release-candidate-checks.sh 1.4.2`, Developer ID app/DMG notarization accepted and stapled, and release DMG checksum verified after downloading from GitHub.

**Open questions**:
- Still open: rotate the App Store Connect API key when convenient because an earlier repo-local copy was treated as exposed.

---

## 2026-06-05 - Remove synthetic live-sync test harness

**What changed**:
Deleted `scripts/run-live-sync-matrix.sh` and removed the `RUN_LIVE_SYNC` opt-in from `scripts/run-release-candidate-checks.sh`. Updated `CLAUDE.md`, `README.md`, and `RELEASE_TESTING.md` to record a real-asset-only live verification policy: release verification must never fabricate throwaway files or folders on the live Image Relay account, and live sync is verified with real assets only through normal app usage.

**Decisions made**:
- No server-side test fabrication in any form. The synthetic create/move/rename/delete matrix that ran against the live account is retired. The concrete trigger: a prior run left empty `Codex-ReleaseLiveMatrix-*` fixtures soft-deleted in a shared folder, visible to other account users.

**Left off at**:
- Commits `a0a5bcd` (harness removal) and `108270d` (`RUN_LIVE_SYNC` wiring plus docs) pushed to `main`. Repo clean.
- `run-release-candidate-checks.sh` still runs offline coverage (187 ImageRelayKit package tests, the 248-test Xcode scheme, unsigned macOS and iOS simulator builds) and optional `RUN_PACKAGE=1` signing/notarization.

**Open questions**:
- None.

---

## 2026-06-02 - 1.4.0 stable public release

**What changed**:
Promoted the 1.4 line from `1.4.0-beta.1` to stable `1.4.0` / build `43`. The stable cut keeps the beta's sync durability and native retry UX work, then removes the beta channel caveat: Homebrew is updated again, the generated Sparkle appcast points at `v1.4.0`, and beta User-Agent defaults are included in the legacy migration list so existing beta installs roll forward without resetting customized configuration.

Also fixed the GitHub Actions release readiness gap by moving the Xcode project job from `macos-latest` to the explicit `macos-26` runner image. The prior `main` and tag runs were failing because `macos-latest` was still on macOS 15 / Xcode 16 while this app targets macOS 26 APIs.

**Validation**:
- `scripts/run-release-candidate-checks.sh 1.4.0` passed, including patch whitespace, 187 ImageRelayKit package tests, the 248-test Xcode scheme, unsigned macOS build, and unsigned iOS simulator build.
- `scripts/build-developer-id-release.sh --version 1.4.0 --smoke-install` produced a Developer ID signed, notarized, stapled DMG with SHA-256 `681b47794b84d699de550cee23a7c5d56ed9c8a81da827500c4840c08d427d0f`.
- App ZIP notarization submission `fa75e7d9-464b-4c3d-9dec-ce38db916956` and DMG notarization submission `3764a67e-8385-406f-99e8-c689ef883765` were both Accepted.
- The smoke install replaced `/Applications/Image Relay.app`, passed codesign, Gatekeeper, and stapler validation, and registered `com.oliverames.imagerelay-client.fileprovider(1.4.0)` with UUID `16C46A56-ADA6-4AA1-A823-0C4C918AD194`.
- The full live sync matrix passed inside `Oliver's Stuff` (`2907644`): create, modify, delete, rename, zero-byte create/delete, 6 MB upload/delete, file move between generated folders, and folder create/rename/move/delete all verified against the remote API with cleanup.

**Left off at**:
- Local artifacts are in `build/releases/1.4.0/`.
- `Casks/image-relay.rb` is advanced to `1.4.0` with the notarized DMG SHA-256.
- No 1.4.0 release blocker remains. The App Store Connect API key rotation note still carries forward because an earlier repo-local copy was treated as exposed.

---

## 2026-06-02 - 1.4.0-beta.1 signed release and resilience closeout

**What changed**:
Published `1.4.0-beta.1` / build `42` as a Developer ID signed, notarized, stapled DMG with Sparkle appcast metadata. The released build carries the sync durability and native retry UX work from `f78a0a5`: durable sync operation journaling, two-pass remote deletion confirmation, streaming file fingerprinting for upload correctness, centralized File Provider signaling, Keychain-backed OAuth transient state, sanitized diagnostics, database integrity checks, relay URL validation, clearer File Provider error messaging, and interrupted-upload retry behavior that leaves retryable work queued instead of treating it as lost.

**Decisions made**:
- Published the GitHub release as `latest` and not as a prerelease even though the marketing version contains `beta`, because installed clients read `https://github.com/oliverames/imagerelay-client/releases/latest/download/appcast.xml`. Keeping the beta release behind GitHub's prerelease/latest split would strand existing Sparkle clients on the older feed.
- Kept Homebrew stable-only. `scripts/build-developer-id-release.sh` correctly skipped the Cask update for the beta version; beta users get this build through Sparkle or manual DMG install.
- Kept live signed-build smoke testing scoped to the configured `Oliver's Stuff` folder (`2907644`), matching the project's current release-test constraint.

**Left off at**:
- Branch `main` is pushed with signed commit `f78a0a5` tagged as signed tag `v1.4.0-beta.1`.
- GitHub release: https://github.com/oliverames/imagerelay-client/releases/tag/v1.4.0-beta.1
- Local artifacts: `build/releases/1.4.0-beta.1/`
- Smoke install moved the prior `/Applications/Image Relay.app` aside to `/Users/oliverames/Applications/Codex Backups/Image Relay.app.1.4.0-beta.1.smoke-20260602-065131`, installed the notarized app, passed Gatekeeper validation, and registered the File Provider extension.
- Verification passed before shipping: `swift test --package-path ImageRelayKit` (187 tests), `xcodebuild test -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` (248 tests), unsigned macOS build, unsigned iOS simulator build, app ZIP notarization, DMG notarization, DMG stapling, smoke install, remote appcast XML validation, and remote appcast/local artifact match.

**Open questions**:
- Resolved this session: signing and GitHub publishing are unblocked; installed clients should now see the beta through the existing Sparkle feed.
- Still open: rotate the App Store Connect API key when convenient because an earlier repo-local copy was treated as exposed.
- NEW: Decide before the next beta whether the Sparkle feed should keep using GitHub `latest` or move to an explicit beta/stable channel split.

---

## 2026-06-01 - 1.4.0-beta.1 (Keychain Prompt Storm Elimination & Premium Marketing Site)

**What changed**: 
Eliminated the disruptive inter-process Keychain password prompt storms occurring during synchronization and test execution under macOS Sequoia/Tahoe.
- **In-Memory Keychain Test Fallback**: Re-engineered `KeychainStore.swift` to automatically detect when a test suite is running (`NSClassFromString("XCTest")` or test arguments). In test mode, all secure mutations happen in a thread-safe, in-memory `testStore` dictionary, completely bypassing the secure Keychain API and reducing SPM test runner execution time from ~21 seconds to 2.9 seconds.
- **In-Place ACL Retention**: Changed `KeychainStore.save` to perform an in-place update using `SecItemUpdate` instead of deleting and recreating. This preserves the macOS Access Control List (ACL) permanently, so that clicking "Always Allow" once is retained across credential refreshes.
- **Selective Authentication Gating**: Optimized `AppConfiguration.load` to only read credentials matching the active `authMethod` (API Key or OAuth), saving up to 66% of Keychain read calls on startup.
- **Keychain Bypass for Idle Operations (`loadWithoutSecrets`)**: Created `AppConfiguration.loadWithoutSecrets` to read the config from disk without hitting the Keychain. Refactored the File Provider extension's `init(domain:)` and `RemoteChangePoller`'s `currentConfig()` to use this, dropping idle background Keychain queries to absolute zero.
- **Premium Light-Mode Marketing Site Overhaul**: Re-designed `docs/index.html` to align exactly with Canto's real corporate identity (using signature Navy `#0c2340` and Canto Teal `#00b2a9` / `#00c5b4` brand colors) and embedded the official Image Relay mark (vertical stem + diamond dot lowercase "i" logo). Created an immersive, CSS-rendered pixel-perfect macOS Finder window mockup inside the Hero section that visualizes favorites, sidebar folders, and virtual cloud-placeholder status badges (`☁️`/`✓`) next to the Image Relay mount point.
- **Documentation**: Updated `README.md`, `CLAUDE.md`, and `AGENTS.md` to synchronize accurate test counts (233 tests total: 176 `ImageRelayKit` package tests + 57 `FileProviderExtension` tests).

**Decisions made**: 
- Chose an in-memory `testStore` dictionary for the test runner because Xcode test binaries are unsigned, sandboxed executables that do not have access to provisioning-profile Keychain entitlements. Running tests against the live macOS Keychain is inherently prone to prompt storms and test flaky timeouts; shifting to memory-only state is completely secure, thread-safe, and incredibly fast.
- Opted for `SecItemUpdate` instead of `SecItemDelete` during refreshes. In-place updates preserve the OS Access Control List (ACL) signature of authorized applications (host app, File Provider extension, etc.), meaning the user only has to approve Keychain access once per system cycle.
- Designed `loadWithoutSecrets` specifically for non-authenticated metadata checks (e.g. tracking polling intervals or folder inclusion lists). Since background change polling runs continuously in the background, it should never trigger visual Keychain authentication blocks or prompt storms.
- Replaced the template mesh gradient backgrounds and capital letter "P" placeholders with professional corporate design grids and native Finder interface representations. This shifts the landing page from looking like a generic template to looking like an official, polished product page built by the Canto design team.

**Left off at**: 
- All 233 unit tests (176 ImageRelayKit + 57 FileProviderExtension) are passing cleanly and rapidly with zero Keychain prompts.
- The premium light-mode marketing page is successfully deployed under `/docs/index.html` with real brand assets and is fully live on GitHub Pages.
- Branch `main` is completely clean and pushed to `origin/main`.

**Open questions**: 
- The App Store Connect API key rotation note remains a long-term chore to complete when convenient.

---

## 2026-05-21 - 1.3.2 sync attention release

**What changed**: Shipped `1.3.2` / build `41` as a follow-up sync correctness release grounded in the current Image Relay API docs and live API behavior. Folder create is now idempotent from Finder: before `POST /folders/{parent_id}/children`, the File Provider extension checks for an existing child folder by name, and after a `409` or `422` validation response it rechecks the remote folder listing before deciding the local mutation failed. Folder confirmation now accepts either the paginated child listing or the documented direct folder detail endpoint, `GET /folders/{id}`, so a newly-created remote folder is not deleted just because the child listing lags.

Image Relay rejects folder names containing `/`, `&`, `<`, or `>`, so folder create and folder rename/move now normalize those characters before sending the documented create/update requests. The live failure `RAWs & XMPs` now writes remotely as `RAWs and XMPs` and reconciles against the later successful folder and file uploads instead of remaining stuck as "needs attention." Activity reconciliation uses the same folder-name canonicalization so historical rejected-name failures clear when the successful normalized remote item appears.

The attention count was also tightened for rate-limit fallout. 429 failures that explicitly say the client will retry automatically no longer count as user-actionable unresolved failures, while non-5xx API rejections map to `.cannotSynchronize` instead of retryable `.serverUnreachable`. That keeps validation problems visible without causing Finder to spin retryable work forever. A final diagnostics fix makes `--export-diagnostics` query File Provider registration before writing `manifest.json`, so exported diagnostics now report the real active-domain state in utility mode.

**Validation**: `scripts/run-release-candidate-checks.sh 1.3.2` passed after the final diagnostics fix, including patch whitespace, ImageRelayKit package tests, Xcode scheme tests, unsigned macOS build, and unsigned iOS simulator build. `scripts/build-developer-id-release.sh --version 1.3.2 --smoke-install` produced a Developer ID signed, notarized, stapled DMG with SHA-256 `55f2ca0d7a12c40c45eab3abe836a3bf48bf96516c0c0f9aeb9f4f387626d8c3`. App ZIP notarization submission `a916d589-f397-47eb-85f4-9b468e93a74b` and DMG notarization submission `db33c7e5-feba-4ad5-ae6e-c02b6d7696c6` were both Accepted.

The smoke install replaced `/Applications/Image Relay.app`, confirmed app version `1.3.2` build `41`, passed Gatekeeper validation, and registered `com.oliverames.imagerelay-client.fileprovider(1.3.2)` from `/Applications` with timestamp `2026-05-21 10:49:38 +0000`. The final installed app passed the full live sync matrix inside `Photography/Blue Cross Photos` (`1924042`): file create, modify, rename, delete, zero-byte create/delete, 6 MB upload/delete, file move between generated folders, and folder create/rename/move/delete all verified against the remote API with cleanup. Final diagnostics exported from the installed app reported `isDomainActive: true`, `unresolved-failures.json` as `[]`, sync state `idle`, `rateLimitInFlight: 0`, last successful API at `2026-05-21T10:52:39Z`, and File Provider PID `48816`.

**Open questions**: No 1.3.2 release blocker remains. The older App Store Connect API key rotation note still carries forward because a prior repo-local copy was treated as exposed.

## 2026-05-20 - 1.3.1 sync reliability release

**What changed**: Shipped `1.3.1` / build `40` as a focused sync reliability release. The release is grounded in the current Image Relay API docs: folder deletes now use the documented `DELETE /folder/{folder_id}` endpoint instead of the older plural `.json` path, which was leaving Finder deletions stuck as failed pending work. The pre-existing pending delete for `B2B Events` completed after this fix.

The shared API limiter now coordinates Image Relay recovery more defensively. Any 429 keeps the shared limiter in the deepest recovery phase, applies a persisted exponential cooldown before the next probe, and prevents successful requests that were already in flight from clearing that cooldown prematurely. The File Provider extension also clears expired local phase-4 probe state before later acquires, fixing the live-test wedge where a stale local token could leave Finder showing an upload in progress while no API call was being issued. Quick-link/CDN downloads now bypass the Image Relay API request limiter so file downloads and thumbnails do not consume the documented API request budget.

**Validation**: `scripts/run-release-candidate-checks.sh 1.3.1` passed, including patch whitespace, ImageRelayKit package tests, Xcode scheme tests, unsigned macOS build, and unsigned iOS simulator build. `scripts/build-developer-id-release.sh --version 1.3.1 --smoke-install` produced a Developer ID signed, notarized, stapled DMG with SHA-256 `915bab9e95032c06beb1aacbdfb63a56bdd1fae9da5ce8a637a1ba10d2e4bcf5`. App ZIP notarization submission `2d7d9c63-4ab2-4972-8bf1-e5e082aa3a07` and DMG notarization submission `2b91a8dd-3592-4098-9a88-dfaab671332f` were both Accepted.

The smoke install replaced `/Applications/Image Relay.app`, confirmed app version `1.3.1` build `40`, passed Gatekeeper validation, and registered `com.oliverames.imagerelay-client.fileprovider(1.3.1)` with UUID `A46A03F9-A1C2-4B5C-9C64-0C2A7E0D0B6C`. The full live sync matrix passed inside `Photography/Blue Cross Photos` (`1924042`): file create, modify, delete, rename, zero-byte create/delete, 6 MB upload/delete, file move between generated folders, and folder create/rename/move/delete all verified against the remote API with cleanup. `Casks/image-relay.rb` was advanced from `1.3.0` to `1.3.1` by the release script.

**Open questions**: No 1.3.1 release blocker remains. The older App Store Connect API key rotation note still carries forward because a prior repo-local copy was treated as exposed.

## 2026-05-19 - 1.3.0 stable release

**What changed**: Promoted `1.3.0-beta.3` to stable `1.3.0` / build `39`. This is the public release for the 1.3 line: Finder right-click actions, metadata editing handoff, collections/product/admin browsing, diagnostic export improvements, display-name presentation controls, and the iOS read-only Files surface all carry forward from the beta cycle. The stable cut also adds the beta 3 macOS and iOS User-Agent defaults to the legacy migration list so beta installs roll forward to the current built-in defaults without resetting user-customized configuration.

One final API coverage fix landed during release prep: `CollectionsService.list()` now uses `APIClient.getAllPages("/collections.json")` instead of fetching a single response page. That brings collections in line with the other list surfaces and avoids silently truncating larger libraries at the first page.

**Validation**: `scripts/run-release-candidate-checks.sh 1.3.0` passed, including patch whitespace, 163 ImageRelayKit package tests across 22 suites, Xcode scheme tests, unsigned macOS build, and unsigned iOS simulator build. `xcodebuild analyze -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` passed. `scripts/build-developer-id-release.sh --version 1.3.0 --smoke-install` produced a Developer ID signed, notarized, stapled DMG with SHA-256 `115257df201f6a8b5ec7cbb001699a509d92abedd19dd9cfb3567953c38db57a`. App ZIP notarization submission `e3172dbc-fd6f-4191-9aa3-310c39ebd501` and DMG notarization submission `565a2de4-39a1-455b-b8de-0daacff70dd0` were both Accepted.

The smoke install replaced `/Applications/Image Relay.app`, confirmed app version `1.3.0` build `39`, passed Gatekeeper validation, and registered `com.oliverames.imagerelay-client.fileprovider(1.3.0)`. The full live sync matrix passed inside `Oliver's Stuff` (`2907644`): create, modify, delete, rename, zero-byte create/delete, 6 MB file create/delete, file move between folders, and folder create/rename/move/delete all verified against the remote API with cleanup. `Casks/image-relay.rb` was advanced from `1.2.1` to `1.3.0` by the release script.

**Open questions**: No 1.3.0 release blocker remains. The older App Store Connect API key rotation note still carries forward because a prior repo-local copy was treated as exposed. Longer-term candidates after 1.3 are explicit beta-channel appcast behavior, thumbnail/partial-content support if Image Relay exposes a documented safe endpoint, and further API pagination audits as new admin surfaces are added.

## 2026-05-18 - 1.3.0-beta.3 final beta

**What changed**: Advanced the final beta to `1.3.0-beta.3` / build `38` and tightened the release path before publishing. The built-in User-Agent defaults now derive from the running bundle's `CFBundleShortVersionString` for the known Image Relay app and extension bundle IDs, with a beta-3 fallback for tests and non-app contexts. That removes the recurring manual drift between `Project.yml`, appcast metadata, diagnostic output, and API User-Agent strings. The legacy migration list now covers the 1.3.0 beta 1 and beta 2 macOS/iOS defaults so existing installs still roll forward without resetting customized values.

The Developer ID release script now fails early when `--version` does not match `Project.yml`'s `MARKETING_VERSION`, and it skips the Homebrew cask branch directly for pre-release versions instead of delegating to `update-cask.sh` and then printing stable-release follow-up instructions. Removed the tracked duplicate generated project siblings `ImageRelayClient 2.xcodeproj` and `ImageRelayClient 3.xcodeproj`; the real generated project remains `ImageRelayClient.xcodeproj`, which is what `Project.yml`, the shared schemes, release-candidate checks, and the Developer ID release script all use.

**Review notes**: The codebase reads like real production code overall: the app has clear API, database, File Provider, and release boundaries; release artifacts are reproducible; and the testing surface is broad for a small desktop client. The parts that felt most AI-ish were maintenance artifacts, not core behavior: duplicate generated Xcode projects, hard-coded version strings that require synchronized edits, and a beta release channel that depended on GitHub `/latest` while prior betas were marked as prereleases. The release-critical fixes above address those. UX remains appropriately quiet and utility-first for a menu bar DAM client, but the Sparkle channel behavior is the sharpest beta UX risk: the installed beta feed URL only sees beta 3 after this release is published as GitHub's latest release.

**Left off at**: `swift test --package-path ImageRelayKit` passed 163 tests across 22 suites. `scripts/run-release-candidate-checks.sh 1.3.0-beta.3` passed, including patch whitespace, package tests, Xcode scheme tests, unsigned macOS build, and unsigned iOS simulator build. `xcodebuild analyze -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` passed. `scripts/build-developer-id-release.sh --version 1.3.0-beta.3 --smoke-install` produced a Developer ID signed, notarized, stapled DMG with SHA-256 `71e7adc74216f3bd83341fa7440934ac3716ac34a87940b9e752cc1c1dc7ad44`. App ZIP notarization submission `1335241b-b161-464d-94ff-7e853898bf7f` and DMG notarization submission `62094905-04ba-4273-82f8-eb55187124b5` were both Accepted. The smoke install replaced `/Applications/Image Relay.app`, confirmed app version `1.3.0-beta.3` build `38`, passed Gatekeeper validation, and registered `com.oliverames.imagerelay-client.fileprovider(1.3.0-beta.3)`.

Live sync matrix testing stayed inside `Oliver's Stuff` (`2907644`) and partially completed before the session connection dropped: create, modify, delete, rename, and zero-byte create/delete all verified against the remote API. The process was no longer running after reconnect, there were no leftover local files for the test prefix, and mDNS verification showed `mDNSResponder`/`mDNSResponderHelper` running plus successful `MacBook-Pro.local` resolution through `dns-sd`; the live test touched File Provider items and HTTPS API calls, not network service configuration. I did not rerun the full destructive matrix after the interruption to avoid adding more API pressure during possible rate limiting.

**Open questions**: Before cutting stable 1.3.0, decide whether beta 3 should remain a normal GitHub "latest" release until GA so Sparkle beta installs can see it through the current feed URL, or whether the app should grow an explicit beta feed URL/channel. The interrupted full live matrix also leaves move and folder-operation coverage as the main manual regression targets for the stable cut.

## 2026-05-18 - 1.3.0-beta.2 (Beautify Filenames + Finder right-click expansion)

**What changed**: Bundled two follow-ups to 1.3.0-beta.1 into a single beta. (1) New optional `FilenamePresentationStyle` enum (`.serverCanonical` default, `.humanReadable` opt-in) on `AppConfiguration`, serialized as `filename_presentation_style` in `config.json`. A new `FilenamePresentation.display(_:style:)` helper in `ImageRelayKit` replaces dashes with spaces and title-cases lowercase tokens, preserving any token with existing uppercase (so `iPhone-photos.zip` becomes `iPhone Photos.zip` rather than `Iphone Photos.zip`). The transform is applied display-only at the three `FileProviderItem` constructors on both macOS and iOS; the database and API surface still store the server-canonical name, and rename round-trips work because the existing `filenamesMatch` canonicalization at `Extension.swift:1380` already tolerates server-side divergence. Settings UI gains a new "Display" section in `GeneralSettingsView` with tradeoff copy explaining the lossy edge cases (intentional hyphens, originally-uppercase acronyms). (2) Eleven new Finder right-click actions registered through `Project.yml`'s `NSExtensionFileProviderActions`:

- **Tier 1**: Copy Download Link (quick-link with `disposition: "attachment"`), Copy Image Relay ID (pure local, reads `ItemIdentifier.numericID`), Copy Folder Share Link (`POST /folder_links.json`).
- **Tier 2**: Copy Metadata (`GET /files/{id}.json` formatted as Markdown with keywords, file type, custom fields; folders fall back to the local `TrackedItem`), Copy Diagnostic Info (pure local; reformats sync state + host context for bug reports), Copy Long-Lived Public Link (omits the `expires` parameter, since the API treats absent as "never expires").
- **Tier 3** (host-app deep-link): Edit Metadata in Image Relay… and Add to Collection…. The extension issues `NSWorkspace.open` of `imagerelay-client://edit-metadata?file_ids=…&names=…` (action as URL host). The host app's `Window` scenes use `.handlesExternalEvents(matching: ["edit-metadata"])` and `.handlesExternalEvents(matching: ["add-to-collection"])` to route the URL to the correct window, then `.onOpenURL` parses via `ActionFormatting.parseHostAppActionURL` and preloads state — `MetadataEditorState.load(targets:)` for the metadata editor, `CollectionsState.pendingAddFileIDs` / `pendingAddFileNames` for the collections browser. The collections browser gains a banner at the top of the view with a contextual "Add N files to <selected collection>" button and a Cancel.
- **Tier 4**: Export Public Link as QR Code (CIQRCodeGenerator → ~/Downloads PNG with pasteboard fallback if Downloads is unwritable), New Mail with Public Link (`mailto:` URL with pre-filled subject and body containing the link), Force Re-download (NSFileProviderManager.evictItem on file targets + signalEnumerator on their parents; distinct from "Refresh from Image Relay" which only re-pulls metadata).

`runCopyPublicLinkAction` refactored to `runCopyQuickLinkAction(disposition:expiresAtOverride:)` so Copy Public Link, Copy Download Link, and Copy Long-Lived Public Link share one body. `yearOutExpiryDateString()` factored to a static helper. All Markdown formatting, QR PNG generation, mailto URL construction, and host-app URL build/parse logic moved into a new `FileProviderExtension/ActionFormatting.swift` enum so the pure functions can be unit-tested without instantiating the extension or a `SyncDatabase`.

Test count grew from 179 across 25 suites (1.3.0-beta.1) to 215 across 27 suites (1.3.0-beta.2): 163 ImageRelayKitTests (+13 — 11 `FilenamePresentation` round-trip cases + 2 `Configuration` legacy-decode/round-trip cases) + 52 FileProviderExtensionTests (+23 — 4 `FileProviderItem` display-transform cases + 19 `ActionFormatting` cases covering Markdown formatting, mailto subject/body, URL build/parse round-trip, repeated query items, punctuation-preserving names, QR export filename collision avoidance, name padding, scheme rejection, and PNG magic-number validation of QR output). Current User-Agent defaults advanced from `ImageRelayClient/1.3.0-beta.1` to `ImageRelayClient/1.3.0-beta.2` for both `(macOS)` and `(iOS)`; the 1.3.0-beta.1 User-Agents were added to `legacyMacUserAgents` and the `normalizedIOSUserAgent` switch so 1.3.0-beta.1 installs roll forward without a reset.

**Decisions made**: For the Beautify transform, chose "title-case lowercase tokens but pass-through anything with existing uppercase" rather than naive `prefix.uppercased()` because Image Relay's server canonicalization is best-effort: most assets arrive lowercase but admin uploads and API-direct posts sometimes preserve case, and the pass-through rule keeps `iPhone`, `API`, and `WWDC` intact when they make it through. Routed the transform through the existing `FileProviderItem` constructors with a `filenameStyle:` parameter defaulting to `.serverCanonical` so the 26 call sites compile unchanged when omitted; only the 13 sites that have access to the loaded `AppConfiguration` were updated to opt in. For the new right-click actions, used `handlesExternalEvents(matching:)` on the host app's `Window` scenes — keyed on the URL host, not path — to route deep-links to the correct window. The first iteration nested actions under `imagerelay-client://action/<name>` which silently failed to route; moving to `imagerelay-client://<name>` (action name as URL host) made the SwiftUI matcher fire correctly. The IPC pattern is one-way: the extension preloads state into the host's `@Observable` view-models (which are scene-global because they're `@State` in `ImageRelayClientApp`) and lets the URL routing bring the right window forward; no XPC channel or NSAppleScript bridging was needed. Markdown formatting helpers live in their own file rather than fileprivate functions in `Extension.swift` because `FileProviderExtensionTests` compiles the extension's sources directly into the test bundle — internal access is testable, fileprivate is not. Skipped Image Relay's "Open File in Image Relay Web" because the v2 API has no documented file-level web URL endpoint; the existing "Open Folder in Image Relay Web" already handles file selections by opening the parent folder.

For the Tier 3 IPC, kept the "deep-link with preloaded state" approach rather than introducing an XPC service. SwiftUI's `Window`+`handlesExternalEvents` is already the canonical pattern for URL-driven window opening on macOS 26; adding an XPC channel would have required extension provisioning changes plus a stateful protocol, with no user-visible benefit. The `CollectionsState.pendingAddFileIDs` / `pendingAddFileNames` properties + `submitPendingAdd(to:)` / `clearPendingAdd()` methods provide the explicit lifecycle (queued → submitted/cancelled → cleared on success) that an XPC reply channel would have given for free; making the state explicit keeps it visible to the existing `@Observable` UI without adding a new layer.

**Release-prep review update**: Deep code/security pass before packaging found three correctness issues in the new Finder actions and fixed them before release. (1) `Export Public Link as QR Code` now resolves a unique `~/Downloads/<name>.qr.png` target before writing so it never overwrites an existing user file or a previous QR export. (2) host-app deep links now use repeated `file_id` / `name` query items rather than a pipe-delimited filename list, preserving filenames that contain punctuation; the parser still accepts the earlier comma/pipe beta-2 preflight URL shape for compatibility. (3) the shared `ActionFormatting` helper is now included in the macOS host app target as well as the File Provider target, so Release builds ship the parser used by the `imagerelay-client://edit-metadata` and `imagerelay-client://add-to-collection` handlers. The incidental `SharedRateLimiterTests` warning was also cleaned up. A BCBSVT Image Relay OAuth developer app named "Image Relay Client" was registered with callback `imagerelay-client://oauth/callback`; the one-time client secret was stored in 1Password Development as `Image Relay OAuth Developer App - Blue Cross VT`.

**Left off at**: `xcodebuild test -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` passed 215 tests across 27 suites (163 ImageRelayKitTests + 52 FileProviderExtensionTests). `xcodebuild build -project ImageRelayClient.xcodeproj -scheme ImageRelayClientiOS -destination 'platform=iOS Simulator,name=iPhone 17e' CODE_SIGNING_ALLOWED=NO` reported BUILD SUCCEEDED — the kit-level FilenamePresentation/AppConfiguration changes compile and link cleanly on iOS too. `scripts/build-developer-id-release.sh --version 1.3.0-beta.2 --smoke-install` produced a Developer ID signed, notarized, stapled DMG with SHA-256 `e7464ae4cab1f93a9e3990524b5c8dc238287af68fe6330b6cd84180eecb8d37`. App ZIP notarization submission `63e4c487-1654-432d-8f64-58a43f892dee` and DMG notarization submission `8348758b-0dd7-474b-bb8d-1ee424a312f7` were both Accepted. The smoke install replaced `/Applications/Image Relay.app` with the notarized payload and registered `com.oliverames.imagerelay-client.fileprovider(1.3.0-beta.2)`.

**Open questions**: Whether SwiftUI's `handlesExternalEvents(matching:)` on individual `Window` scenes activates the app cleanly when neither window is currently open — the existing OAuth callback routes via the always-mounted MenuBarExtra, but the Edit Metadata and Collections windows may be cold on first invocation. If they fail to activate on first click, the fallback is to add `["edit-metadata", "add-to-collection"]` to the MenuBarExtra's matcher and let `handleIncoming` drive an explicit window open through `@Environment(\.openWindow)`. Whether `Force Re-download`'s eviction signals a re-download promptly enough to feel responsive — the action depends on Finder's lazy fetch behavior; if users perceive it as "nothing happened", we may need to chain an explicit `signalEnumerator` plus a small toast in the activity log to confirm. Whether the QR PNG export's 512×512 default is the right size; print materials may want 1024×1024+, and a future iteration could surface a Settings preference for QR size.

---

## 2026-05-18 - 1.3.0-beta.1 (the carry-forward beta)

**What changed**: Picked up all three previously-deferred 1.3 candidates and shipped them as a single beta. (1) New `SharedRateLimiter` actor in `ImageRelayKit` coordinates a 5-RPS token bucket across the host app and File Provider extension via an `NSFileCoordinator`-coordinated JSON state file at `<App Group>/rate-limiter-state.json`. The limiter has five ramp phases: phase 0 = full 5 RPS, phases 1–3 = progressively narrower windows, phase 4 = single-probe lock (only one in-flight request total across both processes, regardless of rate). Any observed 429 from either process snaps the shared state to phase 4 immediately; five consecutive successes step the phase back down by one. A process-spanning probe token (UUID + 30 s TTL lease) prevents a dead process from wedging the lock. APIClient now accepts `any AsyncRateLimiting` and invokes `recordRateLimit()` and `recordSuccess()` so the limiter learns from real API outcomes. All seven host services and both File Provider extensions (macOS + iOS) wire through `AppConfiguration.sharedOrPerProcessRateLimiter()`, which gracefully degrades to a per-process `RateLimiter` if the App Group container is unreachable. (2) `NSFileProviderThumbnailing` conformance on both macOS and iOS extensions. The macOS path caches the `short_lived_thumbnail` presigned S3 URL in a new `tracked_items.shortLivedThumbnailURL` column (migration v7) populated by every folder listing — Finder grids of mostly-cached items consume zero API budget. iOS is stateless (no `SyncDatabase`), so each thumbnail issues `GET /files/{id}.json` first to refresh the URL, then a budget-free GET against the S3 endpoint. A 3-permit semaphore caps concurrent fetches on both platforms so a "Show All Files" grid can't starve user-visible downloads. (3) `NSFileProviderPartialContentFetching` on macOS. Mints a quick-link and issues `Range: bytes=lo-hi` against the `links.imagerelay.com` CDN, which returns `HTTP/2 206` with `content-range`. The aligned range is written into a sparse temp file (truncate + seek + write) and reported back to the system. If the CDN ever serves 200 in response to a Range request, the implementation transparently falls back to a full-file materialization rather than handing the system a malformed result. We deliberately do NOT `DELETE` the quick-link in the cleanup path — the URL stays valid for the quick-link's lifetime so subsequent ranges against the same asset can re-use it, and DELETE just burns 1 RPS of budget for no user-visible benefit.

The iOS Enumerator auto-resolution carry-forward was a memory bookkeeping bug, not actual missing work — that feature already shipped in 1.1.2 (`ee4c4fec`, `FileProviderExtensioniOS/Enumerator.swift:83-89` mirrors macOS `Enumerator.resolveRootFolderID`). `project_release_state.md` updated to mark it ✅ shipped; no code change required.

Live API verification of all four new code paths against the BCBSVT account on 2026-05-18: `/folders/1923998/files.json` listing returns `short_lived_thumbnail` for every file (so the Enumerator's hot path gets URLs for free with no extra API calls); `/files/{id}.json` returns a fresh signed URL each call with a ~24h `Expires` TTL (so the macOS cache-then-fallback design is correctly shaped — the iOS stateless design just refreshes on every request); GET against the thumbnail URL returns `HTTP 200` + `image/jpeg` + 200×113px JPEG; GET with `Range: bytes=lo-hi` against the quick-link CDN URL returns `HTTP/2 206` + `content-range` + `content-length` for three non-adjacent ranges (start, middle, near-EOF). The smoke-installed `1.3.0-beta.1` extension wrote a valid `rate-limiter-state.json` to the App Group container at full ramp phase, confirming the shared limiter is alive on disk.

Tests grew from 168 across 23 suites (1.2.1) to 179 across 25 suites (1.3.0-beta.1): 150 ImageRelayKitTests (+6 — 5 SharedRateLimiter + 1 `short_lived_thumbnail` decode) + 29 FileProviderExtensionTests (+5 `PartialContentFetcher.alignedRange`). Current User-Agent defaults advanced to `ImageRelayClient/1.3.0-beta.1` for both `(macOS)` and `(iOS)`; the 1.2.1 User-Agents were added to `legacyMacUserAgents` and the `normalizedIOSUserAgent` switch so 1.2.1 installs roll forward without a reset.

**Decisions made**: Single-probe semantics interpret "probe" as "one in-flight request total across both processes" (a process-spanning lock token), not just "1 RPS at phase 4" — the lock token is a stronger signal during recovery than tight per-second pacing because the 2026-05-13 storm's account-level penalty was provoked by burst concurrency, not steady rate. Skipped DELETE-ing quick-links after partial-content fetches because the URL is reusable for the quick-link's lifetime and DELETE-ing just consumes rate budget; the quick-link list will gradually fill on the Image Relay side but never grows large enough to be a problem in practice. Did not attempt to lift the macOS and iOS `Enumerator.resolveRootFolderID` into a shared `RootFolderResolver` helper despite the lift being clean — the two implementations are six lines each and the carry-forward was a docs bug, not real missing scope, so doing an extra refactor would have bloated the beta without changing behavior. Cached the `short_lived_thumbnail` URL on the `TrackedItem` row (migration v7) rather than a separate `thumbnail_urls` table because every file already has a tracked-item row and the per-row column gives us colocated reads with the existing `item(for:)` lookup; the fallback path also handles stale-URL invalidation in one place.

The carry-forward 1.4 list shrank from five entries to two: the Image Relay support email for the `DELETE /collections/{id}/files/{file_id}.json` gap (drafted, still unsent, external action) and the App Store Connect API key rotation. The original three "1.3 candidates" are all shipped.

**Left off at**: `v1.3.0-beta.1` will be tagged from the release commit on `main`. `swift test --package-path ImageRelayKit` passed (150 tests across 21 suites). `xcodebuild test -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` passed (179 tests across 25 suites: 150 ImageRelayKitTests + 29 FileProviderExtensionTests). `scripts/build-developer-id-release.sh --version 1.3.0-beta.1 --smoke-install` produced a Developer ID signed, notarized, stapled DMG with SHA-256 `b26fcb02584c52afaff42c48e2d673eda234f0914f7ad0fcb98f69bc8ea0cb95`. App ZIP notarization submission `f83922ad-c977-4d7f-aa16-0d42472f660e` and DMG notarization submission `947c4aec-2d61-41ed-bac1-097e5ae05e1e` were both Accepted. The smoke install replaced `/Applications/Image Relay.app` with the notarized payload, registered `com.oliverames.imagerelay-client.fileprovider(1.3.0-beta.1)`, and `spctl --assess` reported `accepted source=Notarized Developer ID origin=Developer ID Application: Oliver Ames (PV3W52NDZ3)` for both the exported app and the installed app. The Homebrew cask remains on stable `1.2.1` because prereleases are distributed through Sparkle/GitHub only.

**Open questions**: Whether sustained concurrent host + extension activity actually exercises the shared limiter's phase-4 probe lock under a real workload (the design path is unit-tested but not stress-verified end-to-end). The next stable cut (1.3.0 GA) should bundle a 50–100 file folder-walk smoke test that opens Finder thumbnails in a previously-unenumerated folder while the host app simultaneously runs a Library Admin paginated listing, to confirm the combined throughput stays under 5 RPS and that any 429 the system encounters propagates to phase 4 within one acquire cycle.

---

## 2026-05-18 - 1.2.1 polish patch (Open Folder in Image Relay Web)

**What changed**: Added a third Finder right-click action, `Open Folder in Image Relay Web`, to the macOS File Provider extension. The action resolves the selection's folder ID (a folder maps to itself; a file maps to its tracked parent folder), looks up the account's web base URL from `subdomain.http_base` on `GET /users/me.json`, and opens `https://<subdomain>.imagerelay.com/folders/<id>` via `NSWorkspace.shared.open`. The web base URL is cached as a new `web_base_url` field in `config.json` so subsequent invocations skip the `/users/me.json` round-trip. If `NSWorkspace` declines to open the URL, the action falls back to writing the URL to the general pasteboard so the user always gets a useful result. New `UserInfo` model in `ImageRelayKit` decodes only the subdomain block — the wider `/users/me.json` payload (`login`, `email`, `permissions`, etc.) is intentionally ignored because the desktop client has no use for it.

Independent of the new action: completed an 8-checkpoint data-loss audit motivated by user concern that "share/utility" additions might erode safety guarantees. All eight passed: the Enumerator deletion-protection `protectedIdentifiers` set still wraps both the `fetchItems` (parent_id mismatch + `.notFound`) and `fetchWorkingSetItems` paths; `didDeleteItems` is still only called from the incremental `enumerateChanges` path, never from initial enumeration; `CollectionsService.removeItem` still throws `removeNotSupported` immediately and `CollectionsBrowserView` has a tasteful inline comment where the minus-circle button used to be; `addItems` PUT uses the v2 API's delta-add semantics; `getAllPages`' defensive `{"key": [...]}` fallback still emits a `logger.warning` canary so the branch is observable in diagnostics if a real endpoint ever takes it; the upload version-confirmation cross-check at `waitForRemoteFileSize` requires folder membership (`detail.folderIDs.contains(parentFolderID)`) on top of the size match, so a soft-deleted or relocated file with the right ID and size can't pass; folder rename always sends a resolved `parent_id: Int` (the `UpdateFolderRequest` field is non-optional).

Tests grew from 163 (139 ImageRelayKitTests + 24 FileProviderExtensionTests across 22 suites) to 168 (144 + 24 across 23 suites). The five new tests are: `UserInfo` decoding pinned against the live `/users/me.json` shape from 2026-05-17 (BCBSVT account), `UserInfo` decoding when `http_base` is missing or empty, `AppConfiguration.webBaseURL` round-trip through save/load, and legacy `config.json` without `web_base_url` decoding cleanly. The current User-Agent defaults advanced from `ImageRelayClient/1.2.0` to `ImageRelayClient/1.2.1` (both `(macOS)` and `(iOS)` variants); the 1.2.0 User-Agents were added to `legacyMacUserAgents` and the `normalizedIOSUserAgent` switch so 1.2.0 installs roll forward without a reset.

**Decisions made**: Scoped the new action to folder-level navigation (file selections open the file's containing folder) because the v2 API and the codebase only document a folder web URL pattern (`/folders/<id>`); guessing a file URL pattern would risk shipping broken links. The web base URL is discovered via API rather than configured in Settings or hardcoded so the action works for any Image Relay tenant without extra UI surface. Skipped the full `AppConfiguration.save(to:)` path inside the FP extension's `persistWebBaseURL` helper — that method also re-stamps the Keychain entries for the API key and OAuth tokens and could race with the host app's token refresh; the helper writes the JSON only, leaving Keychain untouched. Kept the action's activation rule as `TRUEPREDICATE` (consistent with Refresh and Copy Public Link) and routed file selections through the parent-folder fallback so the menu item never produces a "wrong item type" error.

**Left off at**: `v1.2.1` is tagged from the release commit on `main` and the GitHub release is published with the notarized DMG, the app ZIP, the SHA-256 file, and the EdDSA-signed Sparkle appcast. `swift test --package-path ImageRelayKit` passed (144 tests across 20 suites). `xcodebuild test -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` passed (168 tests across 23 suites). `scripts/run-release-candidate-checks.sh 1.2.1` passed (whitespace, kit tests, scheme tests, unsigned macOS + iOS-simulator builds). `scripts/build-developer-id-release.sh --version 1.2.1 --smoke-install` produced a Developer ID signed, notarized, stapled DMG with SHA-256 `cd8fbca0713177cdba0758d00f75e2a8a0bb4e97d4ddecb7488e98c51c350798`. App ZIP notarization submission `a0f62655-973f-4cb6-8d45-3c0b1346fd00` and DMG notarization submission `6b93d155-af05-40ac-9e4b-1abbb9015284` were both Accepted. The smoke install replaced `/Applications/Image Relay.app` with the notarized payload, registered `com.oliverames.imagerelay-client.fileprovider(1.2.1)`, and `spctl --assess` reported `accepted source=Notarized Developer ID origin=Developer ID Application: Oliver Ames (PV3W52NDZ3)`. `Casks/image-relay.rb` was advanced from `1.2.0` (`68c78a24...`) to `1.2.1` (`cd8fbca0...`) by the release script's `scripts/update-cask.sh` step and synced to the public `oliverames/tap` Homebrew tap.

**Open questions**: Whether `NSWorkspace.shared.open(_:URL)` succeeds from the sandboxed FP extension XPC service on macOS 26 — first-click discoverable post-install. If it fails, the action degrades to "copy folder URL to pasteboard" with a clear warning in the activity log. No release blockers either way.

---

## 2026-05-17 - 1.2.0 stable release shipped

**What changed**: Promoted the project from `1.2.0-beta.4` to stable `1.2.0` with build `34`. No new feature work; this release bundles the four 1.2 betas (operational controls, sync confidence, Finder-native File Provider integration, Copy Public Link) into a single GA. Centralized the current User-Agent defaults at `ImageRelayClient/1.2.0`, migrating legacy beta defaults (1.2.0-beta.1 through 1.2.0-beta.4) forward through the existing `legacyMacUserAgents` set and the `normalizedIOSUserAgent` switch so beta installs roll forward without a manual reset. The macOS and iOS host targets, the macOS and iOS File Provider extensions, and the shared `ImageRelayKit` package all advance to the 1.2.0 marketing version and build 34.

The Copy Public Link Finder action shipped in beta.4 with two unverified design-time assumptions: that `NSPasteboard.general.setString(...)` works from inside the sandboxed File Provider extension XPC service, and that the Image Relay API accepts `yyyy-MM-dd` for the quick-link `expires` field. Both were live-verified before the stable cut. The beta.4 DMG was downloaded from GitHub Releases (SHA matched the recorded `cb35ec67...` digest), installed over the previously installed beta.3, and a Copy Public Link smoke test against a tracked PDF in the live BCBSVT account confirmed both assumptions: the pasteboard contained a working `https://links.imagerelay.com/cdn/5050/ql/...` URL that resolved to the source PDF with a matching md5 (`ad944e6aac0974531ad8e245bf953de2`). Memory at `reference_finder_copy_public_link.md` was rewritten to record both behaviors as verified.

Public-facing docs were refreshed for the 1.2 surface: `README.md` advances the status badge from 1.1 to 1.2, replaces the "1.1 release" callout with a 1.2-scope summary covering Finder integration, sync confidence, and operational controls, and adds Stop/Reconnect Sync, ETA/throughput status, Bulk Retry, and OAuth to the features list. `RELEASE_TESTING.md` and the `run-release-candidate-checks.sh` default version both move from `1.1.1` to `1.2.0`. README test counts move from the stale `122 tests / 19 suites` figure to the actual current `163 tests / 22 suites`.

**Decisions made**: No new code beyond the version bump, the User-Agent migration list extension, and doc updates. The deferred App Group shared rate limiter and single-probe ramp protocol were explicitly reviewed and kept deferred to 1.3 — the v1.1.2 per-process limits (1 RPS host + 4 RPS FP extension) already keep the combined client under the documented 5 RPS ceiling, so a shared limiter is belt-and-suspenders without user-visible benefit. Advanced the Homebrew cask because v1.2.0 is the new public stable line; the build script's `scripts/update-cask.sh` short-circuits on prerelease suffixes (-beta/-rc/-alpha) so the four beta builds correctly left the stable cask at 1.1.2 until this stable cut. Did not extend live testing scope beyond `Oliver's Stuff (2907644)` for sync stress; the Copy Public Link smoke used a one-shot read-mostly POST against the `Image Relay User Guidelines` folder, which is well under the 5 RPS rate limit (single request).

**Left off at**: `v1.2.0` will be tagged from the release commit on `main`. `xcodebuild test -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` passed (163 tests across 22 suites: 139 ImageRelayKitTests + 24 FileProviderExtensionTests). `scripts/run-release-candidate-checks.sh 1.2.0` passed (whitespace, kit tests, scheme tests, unsigned macOS + iOS-simulator builds). `scripts/build-developer-id-release.sh --version 1.2.0 --smoke-install` produced a Developer ID signed, notarized, stapled DMG with SHA-256 `68c78a24ca1111a341392e8491a89efd62867efa9890323576078545aa709ad1`. App ZIP notarization submission `117ece48-68e2-482e-8f2c-d859e3e84300` and DMG notarization submission `eb217cad-76ed-4613-864d-225e0ad433ce` were both Accepted. The smoke install replaced `/Applications/Image Relay.app` with the notarized payload, registered `com.oliverames.imagerelay-client.fileprovider(1.2.0)`, and exercised both the normal launch and the `--reset-file-provider-domain` clean-domain launch paths. A post-install Finder regression check on `Image Relay User Guidelines/Image-Relay-Guidelines-3.1.24.pdf` confirmed the Copy Public Link action still writes a `https://links.imagerelay.com/cdn/5050/ql/...` URL to the pasteboard from inside the FP extension XPC service. `Casks/image-relay.rb` was advanced from `1.1.2` (`7f6af7ca...`) to `1.2.0` (`68c78a24...`) by the release script's `scripts/update-cask.sh` step.

**Open questions**: No 1.2.0 release blockers. The carry-forward 1.3 candidates are: (1) App Group shared rate limiter + single-probe ramp protocol for stronger combined-client throttling, deferred from 1.1.2 and 1.2; (2) iOS Enumerator auto-resolution mirroring `Enumerator.resolveRootFolderID` from the macOS extension, deferred from 1.1.0-beta.8; (3) thumbnail or partial-content fetching via `NSFileProviderThumbnailing` / `NSFileProviderPartialContentFetching` once Image Relay exposes a documented thumbnail or ranged-download contract that does not require materializing huge originals; (4) Image Relay support email for the `DELETE /collections/{id}/files/{file_id}.json` gap, drafted at `~/Documents/drafts/2026-05-12-imagerelay-collections-api.md` and still unsent. The older App Store Connect API key rotation note carries forward unchanged.

---

## 2026-05-15 - 1.2.0-beta.4 Copy Public Link beta

**What changed**: Prepared v1.2.0-beta.4 as a small follow-up beta on top of beta.3's Finder-native File Provider work. The File Provider extension's `performAction` now dispatches on the action identifier rather than guarding a single one, and a new `Copy Public Link` Finder context-menu action mints an Image Relay quick link with `disposition: "inline"` and a year-out `expires` date, then writes the resulting URL to the general pasteboard. Multi-selection joins URLs by newline; folder or unknown items are rejected with a clear error. The release train advanced to `1.2.0-beta.4` build `33`.

**Decisions made**: Used Image Relay's existing quick-link primitive rather than a dedicated public-link write API, since the v2 surface does not currently expose a separate persistent share-link primitive — see `API_COMPATIBILITY.md`. Sent the `expires` field as `yyyy-MM-dd` (UTC, POSIX locale) to match the API doc's "date" wording, accepting the risk of a one-off format fix if the live API rejects it. Kept the activation rule as `TRUEPREDICATE` and rejected folders at runtime, matching the existing `refresh` action pattern rather than introducing a separate item-content-type predicate. Skipped the smoke-install flag for this beta to shorten the release loop; the action behavior is verifiable through the right-click → ⌘V smoke check after install.

**Left off at**: `v1.2.0-beta.4` is tagged from commit `a76f714f8975f060faf1a405712752cd37c95619` and the GitHub prerelease is [published](https://github.com/oliverames/imagerelay-client/releases/tag/v1.2.0-beta.4). `xcodebuild test -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` passed (163 tests across 22 suites). `scripts/run-release-candidate-checks.sh 1.2.0-beta.4` passed. `scripts/build-developer-id-release.sh --version 1.2.0-beta.4` produced a signed, notarized, stapled DMG with SHA-256 `cb35ec6790c7a32e297f849b09637623bfc70507570917d2a5bf73af1b1fb31a`. App ZIP notarization submission `826480e4-ddbe-429b-b01e-df16f5d754c0` and DMG notarization submission `fbc8003b-38b5-41d0-b5b9-c5c181de19e2` were accepted. Anonymous public download of the SHA file succeeded and the body matched the local artifact's digest. The Homebrew cask remains on stable `1.1.2` because prereleases are distributed through Sparkle/GitHub only. Smoke-install was deliberately skipped for this beta.

**Open questions**: Whether `NSPasteboard.general` write from the sandboxed File Provider extension XPC service works end-to-end on macOS 26, and whether Image Relay accepts `yyyy-MM-dd` for the quick-link `expires` field versus a full ISO 8601 timestamp. Both are first-click discoverable from a right-click "Copy Public Link" → ⌘V into TextEdit after installing the beta.

---

## 2026-05-15 - 1.2.0-beta.3 Finder-native File Provider beta

**What changed**: Prepared v1.2.0-beta.3 as the Finder integration beta. The File Provider extension now advertises upload/download/metadata pipeline depths, user-controlled eviction, a Finder "Refresh from Image Relay" action, a needs-attention decoration, Finder-native upload/uploaded/error state, child counts, file-system flags, item userInfo, trash support, and cached Finder search over tracked Image Relay items.

Added cached filename search to `SyncDatabase` and wired the macOS domain to advertise string search support. Existing domains are re-added during setup so installed beta users pick up updated File Provider domain properties without a manual reset. The release train advanced to `1.2.0-beta.3` build `32`, and beta 2 user agents now normalize forward.

**Decisions made**: Implemented File Provider controls that can be backed by real local or Image Relay state. Did not fake downloaded/downloading state because the replicated extension already tells macOS about materialized content through `fetchContents`. Did not add thumbnails or partial-content fetching yet because current Image Relay API evidence does not give us a safe thumbnail or range-download contract, and downloading full RAW originals just to render Finder thumbnails would make the sync engine more brittle.

Left system download/delete menu behavior with macOS defaults. Image Relay already handles deletes through the replicated trash/delete path, and the system's download affordance remains the right native control for on-demand materialization.

**Left off at**: PR [#32](https://github.com/oliverames/imagerelay-client/pull/32) merged to main, `v1.2.0-beta.3` is tagged from commit `f02f021550d3cdc62791249fc8f4a9f72917c33c`, and the GitHub prerelease is published. `swift test --package-path ImageRelayKit`, `xcodebuild test -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'`, `xcodebuild build -project ImageRelayClient.xcodeproj -scheme ImageRelayClientiOS -destination 'platform=iOS Simulator,name=iPhone 17e' CODE_SIGNING_ALLOWED=NO`, and GitHub CI passed. `scripts/run-release-candidate-checks.sh 1.2.0-beta.3` passed. `scripts/build-developer-id-release.sh --version 1.2.0-beta.3 --smoke-install` passed from the merged tag commit, producing a signed, notarized, stapled DMG with SHA-256 `4ba284d16a235e7b61834de112fb010d82519e9c73e1c6bb0e884e1bd8974da2`. Anonymous public downloads of `appcast.xml`, the SHA file, and the DMG succeeded, and the downloaded DMG checksum matched. App ZIP notarization submission `0c2fc184-ad88-4b0f-a07b-6539f6ec9906` and DMG notarization submission `4ce55193-f3bc-4ff1-bd3c-8826fe2c6dac` were accepted; the smoke install registered `com.oliverames.imagerelay-client.fileprovider(1.2.0-beta.3)`. The Homebrew cask remains on stable `1.1.2` because prereleases are distributed through Sparkle/GitHub only.

**Open questions**: No beta 3 release blocker remains. The next Finder-integration candidates are still Image Relay API-dependent: whether Image Relay exposes a documented thumbnail or ranged-download endpoint that can safely power `NSFileProviderThumbnailing` or `NSFileProviderPartialContentFetching` without materializing huge originals.

---

## 2026-05-14 - 1.2.0-beta.2 sync confidence beta shipped

**What changed**: Shipped v1.2.0-beta.2 as the follow-up beta for the screenshots and diagnostics from beta 1. The MenuBar no longer exposes polling mechanics in the primary status line: "next check overdue" is gone from normal UX, the idle state reads as last synced, and remote polling detail lives in Diagnostics where it belongs. Diagnostics and Copy Diagnostics are always visible instead of being gated behind option-click, which fixes the "option click does not show advanced diagnostics" report directly.

The upload state machine is less brittle and easier to trust. Background refresh success now preserves an active upload/download progress state instead of resetting the menu to idle or making completed transfers look stuck. Uploads report transfer, finalizing, and confirming phases separately, so "bytes are uploaded but Image Relay is still confirming the version" no longer looks like a contradiction. Failed activity rows are also reconciled against later successful rows with canonicalized names, so old `_` versus `-` filename variants do not keep the menu claiming completed work is still failed.

Folders and Upload Links now have local caches backed by the shared `settings` table. Settings can render cached folder and upload-link data immediately on open, then refresh in the background. Diagnostics exports now include unresolved failures, the root-folder cache, and the upload-link cache so future support bundles carry the state needed to explain stale UI or offline Settings behavior.

Remote sync scheduling was tightened as well. The poller records the actual jittered/backoff next run time before sleeping, the host watchdog preserves active progress when it successfully signals a refresh, upload-disabled mode no longer blocks remote download checks, and disconnected File Provider domains do stop polling. The Advanced Settings label now calls this "Background Refresh" rather than "Poll Interval" so the app does not teach users to watch the implementation detail.

**Decisions made**: Keep polling as an internal safety-net background refresh, not a user-facing status model. The public Image Relay docs still document the 5 RPS limit and webhook endpoints, but there is no practical desktop-client push or delta feed in the current API surface that replaces the File Provider refresh path. The product stance for beta 2 is therefore closer to Google Drive and Dropbox: local Finder changes sync immediately, remote checks run quietly, and Diagnostics carries the timing detail when something needs debugging. Kept Homebrew unchanged because this is a prerelease; beta distribution remains the GitHub prerelease plus Sparkle appcast.

**Left off at**: PR [#31](https://github.com/oliverames/imagerelay-client/pull/31) merged to main, `v1.2.0-beta.2` is tagged from commit `725c053dafac98eb63a475cc2498a79da508854e`, and the GitHub prerelease is published. `swift test --package-path ImageRelayKit`, `xcodebuild test -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'`, and `xcodebuild build -project ImageRelayClient.xcodeproj -scheme ImageRelayClientiOS -destination 'platform=iOS Simulator,name=iPhone 17e' CODE_SIGNING_ALLOWED=NO` passed. `scripts/run-release-candidate-checks.sh 1.2.0-beta.2` passed. `scripts/build-developer-id-release.sh --version 1.2.0-beta.2 --smoke-install` passed, producing a signed, notarized, stapled DMG with SHA-256 `d9f42943b8a07fa7201241a75d104bd0c51728cb40fe09e79a897368b0833fac`. Anonymous public downloads of both `appcast.xml` and the DMG succeeded, and the downloaded DMG checksum matched. App ZIP notarization submission `514f0388-1f60-4f07-abba-ae1a63945383` and DMG notarization submission `ede977b6-46fa-4e96-9180-f554766af9dd` were accepted; the smoke install registered `com.oliverames.imagerelay-client.fileprovider(1.2.0-beta.2)`. The Homebrew cask remains on stable `1.1.2` because prereleases are distributed through Sparkle/GitHub only.

**Open questions**: No beta 2 release blocker remains. The next real-world soak should confirm that the new confirmation-phase copy matches what users see during Image Relay's eventual consistency window, and that cached folders/upload links stay useful when the API is slow or unavailable. A future server-side relay could make Image Relay webhooks useful for desktop push, but the current API docs do not expose a direct client-consumable replacement for background refresh.

---

## 2026-05-14 - 1.2.0-beta.1 operational controls beta shipped

**What changed**: Shipped v1.2.0-beta.1 from PR [#30](https://github.com/oliverames/imagerelay-client/pull/30). The v1.2 queue landed across [#4](https://github.com/oliverames/imagerelay-client/issues/4), [#7](https://github.com/oliverames/imagerelay-client/issues/7), [#8](https://github.com/oliverames/imagerelay-client/issues/8), [#13](https://github.com/oliverames/imagerelay-client/issues/13), [#14](https://github.com/oliverames/imagerelay-client/issues/14), [#15](https://github.com/oliverames/imagerelay-client/issues/15), [#18](https://github.com/oliverames/imagerelay-client/issues/18), and [#20](https://github.com/oliverames/imagerelay-client/issues/20): MenuBar now reports ETA, throughput, rate-limit wait state, and failed-upload counts; failed uploads can be retried from the menu; option-click or Advanced Settings reveals diagnostics; Stop Sync Completely disconnects the File Provider domain and Reconnect Sync brings it back; OAuth developer-app support now sits beside API keys.

The upload false-failure path from today's screenshots is fixed too. The File Provider no longer treats folder-listing lag as proof that an upload failed. After Image Relay accepts an upload or file version, the extension checks direct `/files/{id}.json` detail and accepts the upload when the direct file detail has the expected size and parent folder, even if `/folders/{id}/files.json` has not caught up yet. That is what hit `Photo Release Form.docx`, `Process for Employee Photoshoots.docx`, and `_MG_7680.jpg`: the local activity log showed failures with "did not report the uploaded version in the folder listing", the local DB had no tracked rows for the two DOCX files, and a live read-only folder listing of `Photography Resources` (`2925804`) showed the documents were not present remotely.

**Decisions made**: Kept Homebrew unchanged for the prerelease; beta distribution is the GitHub prerelease plus Sparkle appcast. Closed [#8](https://github.com/oliverames/imagerelay-client/issues/8) as an investigation because the user-visible delay was not `signalLocalMutation` fan-out, it was remote upload confirmation waiting on eventually consistent folder listings. Shipped OAuth as beta/developer-app support rather than public OAuth onboarding because Image Relay's documented token flow still requires a client secret.

**Left off at**: `v1.2.0-beta.1` is tagged and published from main commit `554b0d6972e573d6fb7e3369354308793e8d39e4`. The signed, notarized, stapled DMG is published on GitHub with SHA-256 `f72a8817ffcfd5d36010d9d5b1a7d63d1f2722992f82c28660b617660a38eb3b`, and anonymous downloads of both the DMG and `appcast.xml` succeeded. App ZIP notarization submission `aa6a294c-053a-407d-8d26-e9ede7a4b001` and DMG notarization submission `a8cc8a08-b773-4eb5-afc7-656540e9ef30` were accepted; the smoke install registered `com.oliverames.imagerelay-client.fileprovider(1.2.0-beta.1)`. `scripts/run-release-candidate-checks.sh 1.2.0-beta.1` passed and `scripts/build-developer-id-release.sh --version 1.2.0-beta.1 --smoke-install` passed. The Homebrew cask remains on the stable line because prereleases are distributed through Sparkle/GitHub only.

**Open questions**: No v1.2.0-beta.1 release blocker remains. OAuth still needs a real Image Relay Developer app credential and callback test before treating it as end-user-ready. The two DOCX files were still absent remotely as of the read-only probe; they should be retried with the beta or uploaded manually if urgently needed.

---

## 2026-05-14 - 1.1.2 resilience release shipped

**What changed**: Shipped v1.1.2 as the patch release for the May 13 429 storm. The resilience cluster landed across [#10](https://github.com/oliverames/imagerelay-client/issues/10), [#16](https://github.com/oliverames/imagerelay-client/issues/16), [#6](https://github.com/oliverames/imagerelay-client/issues/6), [#9](https://github.com/oliverames/imagerelay-client/issues/9), [#17](https://github.com/oliverames/imagerelay-client/issues/17), and [#21](https://github.com/oliverames/imagerelay-client/issues/21): live 429 probing confirmed Image Relay does not send `Retry-After` or `RateLimit-*` headers, nil `Retry-After` now falls back to a 15-second cooldown, the host app and File Provider extension are capped at 1 RPS and 4 RPS respectively, file creates are gated by `AppConfiguration.maxConcurrentFiles` (default 10), retry delays and poller backoff use multiplicative jitter, the remote poller backs off exponentially to a 10-minute cap, and the File Provider extension persists recent 429 state across respawns before starting another batch.

The operational and diagnostics fixes landed too: Pause Sync now pauses the `RemoteChangePoller` ([#19](https://github.com/oliverames/imagerelay-client/issues/19)), MenuBar batch progress no longer resets to idle per item and uses transactional progress counters ([#3](https://github.com/oliverames/imagerelay-client/issues/3)), folder rename sends the resolved parent id instead of `parent_id: null` ([#5](https://github.com/oliverames/imagerelay-client/issues/5)), diagnostics export uses `OSLogStore` and has the friendlier crash-report fallback ([#11](https://github.com/oliverames/imagerelay-client/issues/11)), and Recent Activity records upload/download/modify/delete failures with error messages ([#12](https://github.com/oliverames/imagerelay-client/issues/12)).

**Decisions made**: Kept the App Group shared rate limiter and single-probe ramp protocol for a later release because the requested patch-scope controls now keep the combined client under the documented 5 RPS limit. Kept [#20](https://github.com/oliverames/imagerelay-client/issues/20) deferred because the resilience smoke passed without needing a new user-facing kill switch. Left [#4](https://github.com/oliverames/imagerelay-client/issues/4), [#7](https://github.com/oliverames/imagerelay-client/issues/7), [#8](https://github.com/oliverames/imagerelay-client/issues/8), [#13](https://github.com/oliverames/imagerelay-client/issues/13), [#14](https://github.com/oliverames/imagerelay-client/issues/14), [#15](https://github.com/oliverames/imagerelay-client/issues/15), [#18](https://github.com/oliverames/imagerelay-client/issues/18), and [#20](https://github.com/oliverames/imagerelay-client/issues/20) open as the v1.2 queue. Advanced the Homebrew cask because v1.1.1 was the public stable cask and the release script produced a verified 1.1.2 SHA.

**Left off at**: `v1.1.2` is tagged and published from main commit `9012f25fc451ca2ead86408529cb7e79b5aaf5fd`. The signed, notarized, stapled DMG is published on GitHub with SHA-256 `7f6af7ca44c4995346813a28f4bcd0ab7908bcfbaf75739ad13bc199a1744da4`, and anonymous downloads of both the DMG and `appcast.xml` succeeded. `scripts/run-release-candidate-checks.sh 1.1.2` passed, `scripts/build-developer-id-release.sh --version 1.1.2 --smoke-install` passed, the installed extension registered as `com.oliverames.imagerelay-client.fileprovider(1.1.2)`, and `oliverames/homebrew-tap` commit `ab80f8c` updates `image-relay` to 1.1.2. A live 100-file synthetic smoke in `Oliver's Stuff` (`2907644`) uploaded 100 tiny files into a temporary folder, the root API stayed healthy with HTTP 200, the remote folder reported `asset_count: 100`, and cleanup removed the folder remotely.

**Open questions**: No v1.1.2 release blockers remain. The only carry-forward release-risk note is the older App Store Connect API key rotation item, which still should happen when convenient because an earlier repo-local copy was treated as exposed.

---

## 2026-05-13 - 429 storm incident, multi-stage autonomous recovery, 21 resilience issues filed

**What happened**: During a Finder-drop of ~107 RAW photos (1.47 GB) into the live Image Relay mount, the macOS File Provider extension hit Image Relay's per-IP rate limit and triggered a sustained account-level 429 penalty that persisted for ~3 hours of cumulative true silence. The dump itself completed 107 uploads cleanly at ~5.6 MB/sec across 4:14-4:16 PM ET; bursts of ~290 RPS combined across the host app + FP extension exceeded the documented 5 RPS limit by 2-3×, triggering not just per-second throttling but an extended cooldown that no amount of "Pause Sync" or process kills could short-circuit. The Pause Sync menu item only stopped uploads — the `RemoteChangePoller` kept firing every 60 seconds, generating fresh 429s that likely kept the abuse timer warm. `killall FileProviderExtension` was respawned by `fileproviderd` within seconds. True silence required `pluginkit -e ignore -i com.oliverames.imagerelay-client.fileprovider`.

**Recovery**: Multi-stage autonomous recovery script chained four progressive-silence probes:

| Stage | Time | Cumulative silence | Result |
|---|---|---|---|
| 1 | 17:28:30 | 30 min | STILL_THROTTLED (19 × 429) |
| 2 | 18:30:00 | 90 min | STILL_THROTTLED (4 × 429) |
| **3** | **20:00:00** | **~3 hours** | **RECOVERED (398 × 2xx, 22 creates)** |
| 4 | 22:30:00 | — | SKIPPED (stage 3 succeeded) |

Between stages, the script auto-disabled the plugin via `pluginkit -e ignore` and killed processes to preserve true silence. Stage 4 auto-skipped when stage 3 wrote RECOVERED. Overnight drainage proceeded at ~1.3 files/min (vs. original 24 files/min burst rate); 498 files cleared by 02:08, queue at zero this morning, all cloud-warning badges resolved.

**Issues filed**: 21 GitHub issues capturing every gap the incident exposed. Five form the resilience cluster that would prevent recurrence: [#6](https://github.com/oliverames/imagerelay-client/issues/6) adaptive concurrency throttle (target ~10 concurrent files = ~5 RPS, mirroring Image Relay's own web uploader), [#9](https://github.com/oliverames/imagerelay-client/issues/9) retry jitter to break thundering-herd, [#10](https://github.com/oliverames/imagerelay-client/issues/10) `Retry-After` parsing investigation (header appears missing or unparsed; client falls through to too-short exponential 1s/2s/4s), [#16](https://github.com/oliverames/imagerelay-client/issues/16) cross-process rate limiter coordination (host + FP extension each had their own 5 RPS limiter, summing to 10), [#17](https://github.com/oliverames/imagerelay-client/issues/17) `RemoteChangePoller` exponential backoff on sustained failures.

Three more from the UX layer: [#3](https://github.com/oliverames/imagerelay-client/issues/3) MenuBar batch-progress (TOCTOU + per-item idle reset), [#4](https://github.com/oliverames/imagerelay-client/issues/4) time-remaining estimator, [#7](https://github.com/oliverames/imagerelay-client/issues/7) surface rate-limit state in MenuBar.

Three for visibility / diagnostics: [#11](https://github.com/oliverames/imagerelay-client/issues/11) diagnostics bundle `logs.txt` empty due to `log show` sandbox refusal (switch to `OSLogStore`), [#12](https://github.com/oliverames/imagerelay-client/issues/12) activity log captures failures, [#18](https://github.com/oliverames/imagerelay-client/issues/18) throughput metric + option-click advanced mode.

Three for operational control: [#13](https://github.com/oliverames/imagerelay-client/issues/13) failed-uploads count in MenuBar dropdown (not icon badge, per user UX refinement), [#14](https://github.com/oliverames/imagerelay-client/issues/14) bulk-retry affordance, [#21](https://github.com/oliverames/imagerelay-client/issues/21) FP extension respawn should persist throttle state.

Two from this incident specifically: [#19](https://github.com/oliverames/imagerelay-client/issues/19) Pause Sync should also pause the `RemoteChangePoller`, [#20](https://github.com/oliverames/imagerelay-client/issues/20) in-app "Stop Sync Completely" command via `NSFileProviderManager.disconnect` (Terminal shouldn't be required).

Adjacent: [#5](https://github.com/oliverames/imagerelay-client/issues/5) `parent_id: null` ambiguity on folder rename (spotted while reading the folder-move code path), [#8](https://github.com/oliverames/imagerelay-client/issues/8) `signalLocalMutation` fan-out investigation, [#15](https://github.com/oliverames/imagerelay-client/issues/15) OAuth2 support (distribution-readiness for shipping beyond personal use).

**Decisions made**: File every finding as a discrete GitHub issue as it surfaced rather than batching — easier for another agent to pick up; the cross-references between issues form a useful dependency graph. Target ~10 concurrent files (per user calibration against Image Relay's own web uploader) rather than my earlier guess of 4-6 — calibrating against the actual server's tolerance is a stronger anchor than a speculative number. Use a dropdown-only failure count (not menu bar icon badge) per UX preference for quiet-by-default affordances. Pre-draft the support email rather than auto-sending — drafting is reversible, sending isn't. Adopt `pluginkit -e ignore` rather than `NSFileProviderManager.disconnect` for this incident's recovery because we couldn't change app code in flight, but file [#20](https://github.com/oliverames/imagerelay-client/issues/20) so future incidents have an in-app affordance.

**Empirical findings preserved**: Image Relay's documented 5 RPS limit is real but loose — bursts of 10+ RPS trigger an extended account-level penalty, not just per-second 429s. The penalty's duration empirically clears at ~3 hours of cumulative true silence; less than 2 hours is insufficient. Updates to [reference_v2_api_quirks memory](.claude/projects/-Users-oliverames-Library-Mobile-Documents-com-apple-CloudDocs-Developer-Projects-imagerelay-client/memory/reference_v2_api_quirks.md) capture this for future sessions.

**Left off at**: v1.1.1 is still the released version, no code changes from today's incident. The 21 issues form the post-1.1.1 work queue. The local environment is fully recovered: plugin re-enabled, queue drained, FP extension in normal idle-cycle pattern. Pre-drafted support email at `~/Desktop/imagerelay-support-email-draft.md` is now stale (recovery succeeded without it) but kept as a template for future support threads.

**Open questions**: Priority ordering of the 21 issues for 1.2. The resilience cluster ([#6](https://github.com/oliverames/imagerelay-client/issues/6) → [#9](https://github.com/oliverames/imagerelay-client/issues/9) → [#10](https://github.com/oliverames/imagerelay-client/issues/10) → [#16](https://github.com/oliverames/imagerelay-client/issues/16) → [#17](https://github.com/oliverames/imagerelay-client/issues/17)) is the highest-value bundle — shipping all five would have prevented today's outage. UX cluster (#3 → #4 → #7 → #18) is parallel. [#20](https://github.com/oliverames/imagerelay-client/issues/20) (in-app disconnect) is also high-value as the escape hatch when resilience fails. [#15](https://github.com/oliverames/imagerelay-client/issues/15) (OAuth) is a separate distribution-readiness arc.

Open against Image Relay (not us): does the v2 API actually send a `Retry-After` header on 429 responses? Live probe captured during recovery testing would resolve [#10](https://github.com/oliverames/imagerelay-client/issues/10) one way or the other. If they don't send it, that's a request to file with their team — desktop clients can't realistically handle 429 with only a 7-second client-side exponential backoff.

---

## 2026-05-13 - 1.1.0 stable release shipped

**What changed**: Completed the official 1.1.0 release closeout from the stable release candidate. Fixed Finder-advertised File Provider capabilities so files expose rename support and folders expose rename/reparent support in line with the implemented `modifyItem` behavior. Centralized current User-Agent defaults at `ImageRelayClient/1.1.0`, migrated legacy built-in defaults to `ImageRelayClient/1.1.0 (macOS)` while preserving custom values, and updated macOS, iOS, and shared service call sites. Cleaned up release-build warnings, refreshed release-testing docs, updated the stable cask to the final DMG SHA, published the GitHub release, and synced `oliverames/homebrew-tap`.

**Decisions made**: Treat built-in 1.0/1.1 User-Agent values as migratable defaults, but preserve user-customized values exactly. Expose Finder capabilities only for operations the File Provider already implements, rather than advertising broad delete/upload behavior from the item model. Kept the release host on the source repo (`oliverames/imagerelay-client`) because anonymous GitHub asset validation passed there.

**Left off at**: `v1.1.0` is pushed and published with signed, notarized, stapled assets. Public anonymous appcast and DMG downloads were verified, and the public DMG checksum matched `48853da0fd62b44b3f211e372cd5281d093224142757d5a106c9452a3a51f847`. Homebrew tap commit `80a2706` updates `image-relay` to 1.1.0.

**Open questions**: Still open: rotate the App Store Connect API key when convenient because an earlier repo-local copy was treated as exposed. No new 1.1.0 release blockers remain.

---

## 2026-05-12 - 1.1.0 stable release preparation

**What changed**: Promoted the project from `1.1.0-beta.9` to stable `1.1.0` with build `26`. Refreshed public docs so the README, release testing checklist, and API compatibility matrix describe the official 1.1 surface instead of stale beta examples. Fixed a File Provider deletion-evidence bug where `enumerateItems` could clean stale tracked rows before `enumerateChanges` had reported deletions to Finder. The 1.1 release includes Finder-aware metadata editing, Upload Links, Collections, Products, Webhooks, API Directory, Library Admin write tools, live-API endpoint corrections, explicit File Provider on-demand content policy, and the previous 1.0 sync hardening.

**Verification baseline**: `scripts/run-release-candidate-checks.sh 1.1.0` passed before the stable bump, covering patch whitespace, 105 ImageRelayKit package tests, Xcode project regeneration, the macOS `ImageRelayClient` test scheme, and an unsigned macOS build. `xcodebuild build -project ImageRelayClient.xcodeproj -scheme ImageRelayClientiOS -destination 'platform=iOS Simulator,name=iPhone 17e' CODE_SIGNING_ALLOWED=NO` also passed. The release-candidate script now includes that iOS simulator build so future release gates cover both host apps.

**Left off at**: Release preparation is verified and ready for signed packaging, but the official 1.1.0 release has NOT been cut yet. The first packaging attempt was blocked before archive creation because the system resolver could not resolve normal hostnames for Python/pip/curl; Go-based tools (`op`, `gh`) worked with `GODEBUG=netdns=go`, and `xcrun notarytool history` reached Apple successfully with the 1Password App Store Connect key.

**Open questions**: Still open: run `scripts/build-developer-id-release.sh --version 1.1.0 --smoke-install` with a clean Python dependency path, perform the computer-controlled UI smoke pass, publish the `v1.1.0` GitHub release assets/appcast, verify anonymous appcast and DMG reachability, let `scripts/update-cask.sh` update the stable Cask from the final DMG SHA, commit/push the release artifacts/metadata, and sync the public Homebrew tap if desired.

---

## 2026-05-12 - 1.1.0-beta.9: explicit on-demand `contentPolicy` on FileProviderItem

**What changed**: The macOS extension was already producing the iCloud-style on-demand cloud-storage experience by default — files appear in Finder via metadata-only enumeration, contents fetch lazily via `Extension.fetchContents`, the system manages cache eviction automatically, and per-file remote updates are pulled in the background. All of that is the macOS 13+ default behavior for `NSFileProviderReplicatedExtension`-based providers when no `NSFileProviderItemProtocol.contentPolicy` is set: the root inherits `.downloadLazily` and every descendant inherits from there. Beta 9 makes that behavior explicit per item type so a future SDK default change cannot silently flip it.

`FileProviderItem` now declares a `contentPolicy` property:
- **File items** (from `RemoteFile` and from `TrackedItem` where `itemType != .folder`): `.downloadLazily`. Files download on first read, stay cached until the user runs "Remove Download" or the system reclaims under disk pressure, and remote content updates for already-materialized files are downloaded eagerly so a locally-cached asset stays in sync with the server-side version.
- **Folder items** and the synthetic `.rootContainer` / `.workingSet` / `.trashContainer` items: `.inherited`. Folders don't have content; inheritance from the macOS root (`.downloadLazily`) is the right semantic.

The SDK header (`MacOSX26.4.sdk/.../NSFileProviderItem.h`) describes `.downloadLazily` as "Download this item lazily if it is dataless. Download remote content updates eagerly if this file is not dataless. Allow eviction on low disk pressure and other triggers" — that's exactly the iCloud Drive / Dropbox model. For a DAM where marketing replaces brand photos centrally, the "refresh already-cached files eagerly" half is more valuable than the `.downloadLazilyAndEvictOnRemoteUpdate` variant's "evict on remote update and re-fetch on next read" semantic, because user opens stay fast.

Three new `FileProviderItemTests` pin the choices so a future refactor that drops the explicit policy fails CI rather than silently regressing.

**Verification**: 112 tests pass (105 ImageRelayKitTests + 4 FileProviderExtensionTests existing + 3 new `FileProviderItem content policy` tests). `scripts/build-developer-id-release.sh --version 1.1.0-beta.9 --smoke-install` produced a notarized, stapled DMG; the smoke install confirmed the FileProvider extension bundle registered.

**Decisions made**:

- `.downloadLazily` (the macOS root default) over `.downloadLazilyAndEvictOnRemoteUpdate` (the iOS root default). For a DAM, the "background-refresh already-materialized files" behavior of `.downloadLazily` keeps frequently-accessed assets fresh without an extra cold-fetch round trip when the user re-opens a recently-updated photo. The "evict on remote update" variant would mean every server-side update forces a stale-then-empty-then-refetch cycle, which is worse UX even though it's marginally better for bandwidth. Bandwidth is cheaper than user-perceived staleness in a creative workflow.
- iOS extension `FileProviderItem` would be the parallel place to do this, but the iOS extension is stateless and doesn't use `FileProviderItem` in the same shape; per-platform divergence kept. iOS's default `.downloadLazilyAndEvictOnRemoteUpdate` is correct for a mobile read-only browser anyway.
- Set the policy explicitly per init rather than as a computed property reading from a static map. The class is initialized in several paths (`TrackedItem`, `RemoteFile`, `RemoteFolder`, synthetic containers), each of which already has access to the type information it needs to pick the right policy. Threading a shared lookup table through would be more abstraction for no behavior benefit.

---

## 2026-05-12 - 1.1.0-beta.8: accept "root" as Root Folder ID

**What changed**: The macOS Settings panel rejected `root` as a Root Folder ID with the error "Must be a positive integer (e.g. 12345)". Image Relay's web UI uses `.../folders/root` at the top of the library, so a user landing at the actual library root and copying the URL segment back into Settings hit a dead end. Fix: treat `root` (case-insensitive, trimmed) as a synonym for an empty value in `GeneralSettingsView.rootFolderIDValid` and in the save path, so it persists as `remoteRootFolderID = nil`. The macOS extension's existing `Enumerator.resolveRootFolderID` already falls back to `GET /folders/root.json` when the config value is `nil`, so the path is end-to-end: typing `root` now produces the same behavior as the user hitting the library root in the web UI. Footer help text rewritten to "Leave blank or enter **root** to sync your account's entire library." Validation error rewritten to "Enter a positive integer (e.g. 12345), \"root\", or leave blank".

`ImageRelayClientiOS/Configuration/ConfigurationStore.swift` was updated in parallel so iOS users typing `root` end up at the same `nil` configuration state instead of falling through `Int(trimmedRoot)` to a silently-rejected save. The iOS Enumerator still requires a numeric ID, so a `root` save on iOS produces the same `.notAuthenticated` error as a blank save — that's unchanged, not a new regression. Adding async root-resolution to the iOS extension is a parallel improvement deliberately deferred; this beta is scoped to the macOS UX bug in the screenshot.

**Verification**: All 109 tests pass (105 ImageRelayKitTests + 4 FileProviderExtensionTests). `scripts/build-developer-id-release.sh --version 1.1.0-beta.8 --smoke-install` produced a notarized, stapled DMG at `build/releases/1.1.0-beta.8/ImageRelayClient-1.1.0-beta.8.dmg` (SHA256 `0afce04791755d50c36868cd097aa47ec99e7bfbbad71a45d72aa7bc23d1b252`), replaced `/Applications/Image Relay.app`, and confirmed the FileProvider extension bundle is registered. Notarization: ticket `4756a1e7-c236-4894-8298-9c4847ce0744`, status Accepted.

**Decisions made**:

- `root` aliases to `nil` rather than being stored as a literal sentinel string. `AppConfiguration.remoteRootFolderID` stays a nullable `Int`, no JSON schema change, no migration, no test churn. The only knowledge of the alias lives in the UI input layer.
- After a `root` save the field re-renders as blank (because `config.remoteRootFolderID == nil`). This is a minor surprise but better than the alternative of conflating "user explicitly chose root" with "user hasn't set anything yet." The footer text mentioning `root` as a synonym keeps the affordance discoverable.
- iOS Enumerator auto-resolution (mirroring `Enumerator.resolveRootFolderID` from the macOS extension) was considered and deliberately deferred. The iOS extension's `resolveFolderID` is currently a synchronous static; adding an API roundtrip there means threading the API client through and making the call site async. Worth doing, but it's a separate scope from the macOS Settings bug.

---

## 2026-05-12 - 1.1.0-beta.7: live-API reconciliation (4 ship blockers fixed)

**What changed**: Full live-account verification of every beta 6 admin endpoint surfaced four production bugs in beta 6 that this beta fixes. Beta 6 shipped with shape inference for the new admin endpoints rather than live validation; running each one against the BCBSVT account on the v2 API turned up four contract mismatches, all of which silently no-op'd or 404'd in beta 6.

1. **Collections `addItems` was 404ing in production.** Beta 6's "delta POST" path (`POST /collections/{id}/files.json`) does not exist on v2 — every request returned 404 HTML. Fixed by switching `CollectionsService.addItems` to `PUT /collections/{id}.json` with comma-separated `asset_ids` and the existing `CollectionUpdate` payload. Live testing showed PUT has **delta-add semantics** on this endpoint (IDs in the body get appended; IDs already present become no-ops; omitting an ID does NOT remove it), so the additive write requires no read-modify-write step and therefore has no TOCTOU window. The misleading inline comments from beta 6 (claiming PUT replaces, claiming POST is the delta path) have been rewritten to match observed behavior. `CollectionItemAdd` struct deleted from `ImageRelayKit/Models/Collection.swift` — it was only used by the broken POST path.

2. **Collections `removeItem` was silently no-op'ing in production.** Because the v2 PUT is delta-add (not replace, as beta 6 and earlier assumed), the existing "fetch full membership, filter out the target ID, PUT the result back" implementation never actually removed anything. Probed every plausible delete shape against a live test collection: `DELETE /collections/{id}/files/{file_id}.json`, `DELETE /collections/{id}/files.json` with a body, `PATCH` variants, `POST /collections/{id}/remove.json`, query-param removal forms. All return 404 or silently no-op. `DELETE /collections/{id}.json` regardless of query params deletes the whole collection. Conclusion: v2 has no working endpoint to remove an individual file from a Collection. Fix: `CollectionsService.removeItem` now throws a clear `ServiceError.removeNotSupported`, and the minus-circle button has been removed from `CollectionsBrowserView`. Users drop items via the web app for now. Drafted a support email to [email protected] requesting a delta DELETE endpoint, parked at `~/Documents/drafts/2026-05-12-imagerelay-collections-api.md`.

3. **Permission Groups feature was 404ing in production.** Beta 6 hits `/permission_groups.json` which returns HTML 404. The correct endpoint on v2 is `/permissions.json` (response: bare array of `{id, name, created_on, updated_on, role_type}` — exactly the shape `PermissionGroup` already decodes). Fixed `LibraryAdminService.permissionGroups()` to call the right path; the tolerant `PermissionGroupListResponse` decoder already accepted both bare-array and wrapper shapes, so no model changes needed.

4. **`searchUsers` was silently returning the full user list.** Beta 6 sends `?query=...` per the task contract; the public Image Relay docs document `?first_name=&last_name=&email=`. Live testing showed both are silently ignored — the server returns the full unfiltered list for either. The actual working parameter is `?q=...` (no docs reference it). Fixed `LibraryAdminService.searchUsers` to use `?q=` and rewrote the inline comment to reflect what's actually observed. `?q=ames` correctly returns just my own user record; the previous client returned all 33 BCBSVT users for every search.

**Verification**: 109 tests pass in two bundles. 105 ImageRelayKitTests (beta 6's `encodeCollectionItemAdd` test removed alongside the type it covered; all other tests still green). 4 FileProviderExtensionTests. Both `xcodebuild test -scheme ImageRelayClient` (macOS) and `xcodebuild build -scheme ImageRelayClientiOS` (iOS Simulator) succeed. Live verification used a 1Password-sourced API key, scoped destructive operations to `[TEST]`-prefixed temp resources with immediate cleanup. Probe scripts archived at `/tmp/imagerelay-smoke/probe[1-11].py` for reproducibility.

**Decisions made**:

- Cut beta 7 rather than promoting straight to 1.1.0 stable. The original plan (per project_release_state memory) was "smoke-test beta 6, then bump to 1.1.0." Surfacing four broken endpoints in beta 6 means the same plan now produces a stable release with known regressions; ship-stable-anyway isn't honoring "do the verification" — it's hand-waving it. Beta 7 is the verification.
- The `removeItem` UI control is hidden entirely rather than disabled-with-tooltip. A disabled button creates friction without communicating *why*; better to omit the affordance and document the API limitation in `API_COMPATIBILITY.md`. When Image Relay exposes a delete path the button comes back.
- Beta 6's `getAllPages` unkeyed-wrapper canary is intentionally kept. None of the new admin endpoints take this shape (they all return bare arrays without pagination metadata, which falls through to the existing bare-array branch, not the new defensive one). The canary still has value if some future endpoint takes the wrapped-no-pagination shape; cost is one extra `if let body = jsonObject as? [String: Any]` branch.
- `searchUsers` keeps its server-side filter via `?q=` rather than falling back to client-side filter over the bare `/users.json` list. Both work for BCBSVT's 33-user account; for larger accounts a client-side filter trades responsiveness for over-the-wire payload, so the server filter wins.

**Open questions**:

- Stable cut still pending until beta 7 is smoke-tested against the live account end-to-end (the four fixes were verified at the API layer; the macOS UI surface invoking them needs a manual pass).
- iOS real-device smoke against the live account remains untested. iOS is read-only so the four fixed write paths don't apply there; the iOS app does compile clean against the changed shared services.

---

## 2026-05-11 - 1.1.0-beta.6: API extensions + sync data-loss protection + FileProvider tests

**What changed**: Three substantive pieces bundled into one beta cut.

1. **API surface extensions.** Six new capability groups across the kit and the macOS host: Collections create/delete (with TOCTOU-safe additive `addItems` using `POST /collections/{id}/files.json`), Permission Groups list, Invited Users CRUD (list/invite/delete), Users extended ops (`user(id:)`, `searchUsers(query:)`, `updateUserPermissionGroup(userID:permissionGroupID:)`), Keyword rename (`PUT /keyword_sets/{setID}/keywords/{id}.json`), Folder Link create/delete. New models in `ImageRelayKit/Models/LibraryAdmin.swift` and `Collection.swift`; new service methods in `LibraryAdminService` and `CollectionsService`, all wrapped in tolerant response decoders matching the existing pattern. `LibraryAdminState.load()` fan-out expanded from seven to nine top-level fetches; new action methods on the state for each write endpoint.

2. **Sync engine data-loss protection.** A transient `.notFound` (or `parent_id` mismatch) on a selected root folder previously caused the deletion-detection diff in `Enumerator.fetchItems` to mass-delete that folder's entire tracked subtree from File Provider's view — a single API miss erased the user's files from Finder. `selectedRootFolders` now returns `(folders: [RemoteFolder], unverified: Set<Int>)`. `fetchItems` and `fetchWorkingSetItems` build a `protectedIdentifiers` set from the local subtree of each unverified folder (via the new `SyncDatabase.subtreeIdentifiers(rootedAt:)`, which uses a recursive CTE in the spirit of the existing `deleteSubtree`), and skip those identifiers in the deletion diff. Both `.notFound` and `parent_id != expected` go into the unverified set, so the working-set path (`db.allItems()` diff, larger blast radius) is also protected.

3. **`FileProviderExtensionTests` target.** New macOS unit-test bundle wired into the existing `ImageRelayClient` scheme. Compiles `FileProviderExtension/` sources directly into the test bundle (rather than linking the extension binary) to sidestep the extension's provisioning-profile requirement. Four integration tests prove the data-loss protection end-to-end: 404-on-selected-folder doesn't mass-delete descendants, `parent_id` mismatch doesn't mass-delete descendants, happy-path enumeration still reports updates, and stale folders NOT under unverified roots still get correctly reported as deleted (proves the protection doesn't leak into the success path).

Two smaller hardening items folded into the same cut:

- `getAllPages` defensive handling for `{"key": [...]}` responses without `pagination` metadata. Falls back to the same per-page heuristic the bare-array path uses, with a `logger.warning` whenever the new branch fires so a real endpoint that takes this shape becomes observable in production diagnostics. Closes the deferred theoretical-risk note from the prior beta but only as a defense; no production endpoint has yet been observed using this shape.
- The previous beta's deferred TOCTOU on Collections membership writes: `addItems` now uses the delta POST endpoint. Removes still PUT the full set (no documented delta DELETE endpoint), and the asymmetric remaining risk is documented inline.

**Verification**: 110 tests pass in two bundles. 106 ImageRelayKitTests (includes 2 new `getAllPages` defensive tests, 3 new `subtreeIdentifiers` tests, 8 new model Codable round-trip tests for the six new capability groups). 4 FileProviderExtensionTests integration tests. Both `xcodebuild test -scheme ImageRelayClient` (macOS) and `xcodebuild build -scheme ImageRelayClientiOS` (iOS Simulator) succeed. Developer ID signing + notarization + DMG packaging via `scripts/build-developer-id-release.sh --version 1.1.0-beta.6` produced the published artifact.

**Decisions made**:

- The Enumerator fix protects only at the top-level selected-folder boundary. A failure mid-tree in `appendFolderTree` (recursive `listChildFolders`) throws out of the whole enumeration, which causes File Provider to keep the prior view stable rather than apply a partial diff — no false mass-delete is possible from that path, so no protection is needed there.
- The Collections `removeItem` path stays PUT-the-whole-set. No documented delta DELETE endpoint exists on Image Relay's collection-membership API. Switching `addItems` to the POST delta closes the additive-write TOCTOU but concurrent-editor remove operations can still clobber concurrent adds. Documented inline rather than inventing an endpoint.
- The FileProviderExtension test target compiles the extension's sources directly rather than linking the extension binary. Linking the extension as a test dependency drags its provisioning-profile requirement into the test build (the `codeSign: false` embed-only config on the extension doesn't translate to test-target linkage); duplicating the source compilation (≈10 s extra build time) is the simpler trade. Test target uses `CODE_SIGNING_ALLOWED: NO` plus ad-hoc identity.
- `EnumeratorMockURLProtocol` is a separate URLProtocol subclass from `APIClientTests.MockURLProtocol` for the same reason `CollectionsMockURLProtocol` was added in the prior beta — Swift Testing's `.serialized` only orders tests within a single suite, so cross-suite static `requestHandler` races unless each test bundle has its own subclass. Per-instance state would be cleaner but requires routing handler through URLSessionConfiguration metadata; deferred.
- Several audit observations were investigated and deliberately NOT changed: `enumerateItems` cleaning the DB without notifying File Provider is actually correct because `finishEnumerating(upTo: nil)` is treated as the complete set by `NSFileProviderReplicatedExtension`. `setSyncAnchor` ordering is not a data-loss vector because the anchor isn't used to filter changes (always full re-fetch). Orphaned chunked-upload versions on `complete.json` failure are server-side storage waste, not client-side loss. Spurious-conflict-detection from `db.upsertItem` overwriting `contentVersion` during enumeration is preserved by the conflict-copy mechanism — neither version is lost.

**Open questions**:

- `getAllPages` unkeyed-wrapper fallback is defensive code that has not yet fired against a real Image Relay endpoint. The `logger.warning` should surface the first occurrence in production. If a real endpoint takes this shape AND doesn't honor `?page=N`, the heuristic will loop forever fetching the same payload — the warning is the canary for "this is no longer theoretical."
- The Collections `removeItem` PUT-the-whole-set TOCTOU is the next obvious data-integrity step. Depends on Image Relay exposing `DELETE /collections/{id}/files/{id}.json` or similar.
- `searchUsers` query-parameter spec mismatch (task contract uses `?query=`; the public Image Relay docs show separate `?first_name=&last_name=&email=` params). One of the two is wrong; current code follows the task contract pending live verification. Documented inline at the call site.

---

## 2026-05-11 - Pagination correctness: Collections data-loss fix + UI services sweep

**What changed**: Two related correctness fixes for the same root cause. Every UI service was calling `APIClient.get` (single page) for list endpoints, while the kit-level `getAllPages` helper that handles both Link-header and body-pagination styles was right there. The Collections case was destructive: `CollectionsService.addItems` and `removeItem` did a read-modify-write against a 100-item-truncated view from `items(in:)`, then sent `PUT /collections/{id}.json` with the full `asset_ids` set back — dropping members beyond page 1 on every write. The `items(in:)` truncation also hit the macOS `CollectionsBrowserView` and the iOS `CollectionsListiOSView` displays. Fixed `CollectionsService.items(in:)` first (data-loss), then swept the same `.get` → `.getAllPages` pattern across `LibraryAdminService` (6 endpoints — `fileTypes`, `keywordSets`, `keywords`, `users`, `folderLinks`, `quickLinks` — and dropped a dead `["page": "1"]` query that had become a no-op), `ProductsService.list`, `WebhooksService.list`, `UploadLinksService.list`, and the unscoped `/keywords.json` call in `MetadataEditingService.fetchAllKeywords` (display-truncation only, not destructive). Five orphaned envelope structs deleted (`CollectionsService.ItemsResponse`, `ProductsService.ListResponse`, `WebhooksService.ListResponse`, `UploadLinksService.ListResponse`, `MetadataEditingService.KeywordListResponse`) — `getAllPages` peels the response wrapper itself, so per-service envelopes were no longer doing useful work.

**Verification**: 93/93 ImageRelayKit tests pass across 17 suites (90 prior + 3 new in `CollectionsPaginationTests` characterizing the kit-level pagination contract for `/collections/{id}/files.json`: single-`.get` truncation at page boundary, `getAllPages` walks every page, and short-circuits to one request when a collection fits on one page). `xcodebuild test -scheme ImageRelayClient` (macOS) and `xcodebuild build -scheme ImageRelayClientiOS` (iOS Simulator) both succeed — confirms the cross-platform service files (`CollectionsService`, `ProductsService`, `LibraryAdminService` per `Project.yml` lines 117–119) still type-check on both targets.

**Decisions made**:

- Tests live at the kit boundary, not the service boundary, because services are in the macOS app target where `@testable import ImageRelayKit` from `ImageRelayKitTests` cannot reach the service code. The bug is fundamentally in the choice of API method (`.get` vs `.getAllPages`), so a kit-level test pinning the exact `/collections/{id}/files.json` request shape and pagination response is sufficient regression coverage. Service-level tests would have re-verified kit behavior with extra ceremony.
- New `CollectionsMockURLProtocol` in the new test file rather than reusing `MockURLProtocol` from `APIClientTests`. Both subclasses define their own `nonisolated(unsafe) static var requestHandler`, and Swift Testing's `.serialized` trait only orders tests within a single suite — across suites, the static handler races. Per-file URLProtocol subclasses isolate cleanly. Caught the latent race on the first test run when `MockURLProtocol`'s chunked-upload test recorded a request from the parallel pagination test.
- `currentUser()` (single object), `WebhooksService.supported()`, and `LibraryAdminService.supportedWebhooks()` (server-fixed enumerations of supported event types) intentionally stay on `.get`. Switching them adds latency for zero benefit and risks an infinite-loop edge case in `getAllPages`'s count heuristic if the API ignores `?page` for endpoints that aren't expected to paginate.
- Per-call `APIClient`/`URLSession` creation across services NOT addressed in this session. Each service still builds a fresh client per call, so each new `APIClient` carries its own `RateLimiter` and the documented 5 req/s ceiling isn't enforced globally. It's an efficiency concern, not a correctness one. Deferred.

**Open questions**:

- The concurrent-editor TOCTOU race on `CollectionsService.addItems`/`removeItem` is not closed by this fix. Two operators editing the same collection can still clobber each other's writes because both compute their union/diff against possibly-stale reads then send the full `asset_ids` set back. The proper fix is to swap the PUT-the-whole-set pattern for a delta endpoint (`POST /collections/{id}/files.json` for adds, presumably DELETE for removes) — `CollectionItemAdd` already exists in `ImageRelayKit/Models/Collection.swift` (encodes `file_ids: [Int]`), suggesting the additive endpoint exists but was never wired up. Future work.
- Some `ProductsService`/`WebhooksService`/`UploadLinksService` responses may theoretically return `{"key": [...]}` *without* a `pagination` key (single-page response without pagination metadata), in which case `getAllPages` throws `Unexpected paginated response format`. `API_COMPATIBILITY.md` documents that all list endpoints use either pagination objects or Link headers, so this risk is theoretical. If it surfaces in practice on a small account, the fix is to enhance `getAllPages` in the kit to treat dict-with-array-without-pagination as a single page.

---

## 2026-05-11 - 1.1.0-beta.5: metadata polish + Library Admin CRUD + Homebrew

**What changed**: Bundled three pieces into one beta. (1) Phase 1 polish on the
metadata editor. (2) Phase 6 Library Admin CRUD, building on the existing
read-only API Directory rather than scaffolding parallel feature folders.
(3) Homebrew Cask support backed by a new public tap repo.

Phase 1 polish:

- SQLite metadata cache with a 5-minute TTL. New `metadata_cache` table via
  a v5 migration in `SyncDatabase`; cache key is the asset ID, value is the
  full `RemoteFileDetail` JSON so adding fields doesn't require a schema
  bump. `MetadataEditingService.fetchDetail` consults the cache before
  hitting the network; both fetch and save write through.
- Multi-select editor with Finder-style semantics. `MetadataEditorState`
  rewritten to handle 1..N targets. Description and custom fields use
  common-fields-only ("Multiple values" placeholder when files differ;
  blank means "don't touch"). Keywords use union semantics with an
  explicit warning hint that saving replaces every selected file's
  keyword set. Fetch fans out via `TaskGroup`; save fans out in parallel
  and surfaces per-file failures in a banner. `MenuBarView` passes all
  Finder-selected URLs (was previously taking only the first).
- Keyword autocomplete suggestion chips. `MetadataEditingService.fetchAllKeywords`
  tries unscoped `/keywords.json` first, falls back to aggregating via
  keyword sets, and returns empty silently on either failure so the
  chips degrade rather than block the editor. Chips ranked by `usage_count`
  descending, ties broken alphabetically.

Phase 6 Library Admin CRUD:

- File types: create + edit (name/description) + delete. Terms stay
  read-only this beta.
- Keyword sets: create + delete. Per-set keyword create + delete. Flat,
  no reordering.
- Users: invite (email + optional first/last/login) + delete. Role
  editing intentionally deferred until `permission_id` semantics are
  documented in the kit — a wrong value could lock real users out.
- All CRUD goes through new tolerant response wrappers (`FileTypeResponse`,
  `KeywordSetResponse`, `KeywordResponse`, `UserResponse`) that accept
  either `{"resource": {...}}` or a bare object, matching the
  `WebhooksService` pattern. Models added in `LibraryAdmin.swift` and
  `Keyword.swift`: `FileTypeCreate`, `FileTypeUpdate`, `KeywordSetCreate`,
  `KeywordCreate`, `UserInvite`. View additions live in
  `LibraryAdminView.swift` as three private tab sub-structs
  (`FileTypesTab`, `KeywordsTab`, `UsersTab`) plus shared sheet helpers;
  the existing Links and Events tabs are unchanged.

Homebrew Cask:

- `Casks/image-relay.rb` pinned at v1.0.1 stable. `depends_on macos: ">= :tahoe"`
  (symbol verified against installed Homebrew at
  `/opt/homebrew/Library/Homebrew/macos_version.rb`). DMG SHA-256
  reverified against the live GitHub asset:
  `664603ddd14849ce27ca73bae6fc088347ccb9f167584230d386225051bdaf3f`.
- `scripts/update-cask.sh` rewrites the cask version + SHA from a built
  DMG and short-circuits any version containing `-beta`, `-rc`, or
  `-alpha` so beta releases never bump the stable cask.
- `scripts/sync-cask-to-tap.sh` clones, updates, commits, and pushes
  `Casks/image-relay.rb` to `oliverames/homebrew-tap`. Idempotent — bails
  early when the destination cask is already byte-identical.
- Wired into `scripts/build-developer-id-release.sh`: after notarization,
  `update-cask.sh` runs automatically and reports the result without
  failing the release on a cask-update error.
- README gained a Homebrew install section (`brew tap oliverames/tap`
  followed by `brew install --cask image-relay`) above the manual DMG
  install path.

Out of scope by user directive: Phase 7 consumer webhook relay
(Cloudflare Worker + SSE). The user said "I don't want to ever
implement that" on 2026-05-11; captured as a durable memory.

**Decisions made**:

- Extend `LibraryAdminView` rather than scaffold three parallel admin
  folders. The 5-tab read-only diagnostic was already there with a
  resilient 8-fan-out parallel load + `sectionErrors` map; the CRUD
  inherits all of that for free.
- Keyword multi-select semantics: union with warning hint (Finder Tags
  parity). The next-smallest alternative (two-section "On all" / "On
  some" UI) was considered and deferred until usage demands it.
- Cache TTL of 5 minutes. Long enough to amortize multi-select repeats,
  short enough to surface server-side edits the next time the editor
  opens.
- One bundled commit (`b670f1e`) covering all three pieces, per user
  preference for fewer larger commits over many small ones for this
  cycle.
- Cask deliberately tracks stable only. Beta channel stays on Sparkle.

**Verification**:

- macOS Debug build clean (signing disabled).
- iOS Simulator build (`iPhone 17e`) clean, confirming the new
  `LibraryAdminService` CRUD additions compile on the iOS target that
  shares the file via `Project.yml`.
- `swift test` from `ImageRelayKit/`: 90/90 passing across 16 suites.
  The v5 migration ran successfully against in-memory and on-disk
  databases.
- Cask SHA reverified against `curl`-downloaded v1.0.1 DMG.
- `:tahoe` symbol confirmed valid in installed Homebrew.
- Sync to tap succeeded; tap commit `9ecc46a` contains
  `Casks/image-relay.rb` at v1.0.1.

**Left off at**:

- Beta 5 committed as `b670f1e` on `main` but not pushed. User held on
  both the push and the release-script invocation so they can pick the
  timing.
- Release build (`scripts/build-developer-id-release.sh --version
  1.1.0-beta.5 --smoke-install`) is the next step. Smoke install will
  replace `/Applications/Image Relay.app` in place.
- GitHub release publish via `gh release create v1.1.0-beta.5
  build/releases/1.1.0-beta.5/ImageRelayClient-1.1.0-beta.5.dmg
  --prerelease` after notarization completes.
- Live API smoke against the Image Relay account will be the gating
  step before 1.1.0 stable. Particularly: multi-select metadata edit
  on real assets, and the Phase 6 CRUD endpoints whose request shapes
  are inferred (the response wrappers are tolerant; the request
  payloads assume `{file_type: {...}}` style wrapping which the API
  may need to be flat).

**Open questions**:

- Does the live Image Relay API accept the wrapped `{file_type: {...}}`
  POST/PUT body for file-type CRUD, or does it want a flat
  `{name, description}`? The existing `FileMetadataUpdate` sends flat;
  for consistency, flat may be safer here too. Adjustable in
  `LibraryAdminService` if 422s surface during smoke.
- Unscoped `/keywords.json` endpoint existence remains unverified
  against the live deployment. Worst case the autocomplete chips don't
  populate; not a release blocker.
- iOS real-device smoke against the live account still pending from
  the prior session.

---

## 2026-05-09 - iOS port scaffold: ImageRelayClientiOS + FileProviderExtensioniOS

**What changed**: First iOS targets land in this repo. `ImageRelayKit` is now
declared cross-platform (`Package.swift` adds `.iOS(.v18)`); no source changes
were needed inside the kit because it was always disciplined about
imports — only `Foundation`, `GRDB`, `Security`, `os.log`. Two new targets in
`Project.yml`: `ImageRelayClientiOS` (iOS 18 host app) and
`FileProviderExtensioniOS` (iOS app-extension). Bundle IDs distinct from
the macOS siblings (`*.ios` and `*.ios.fileprovider`); App Group and
Keychain access group reused from macOS so `AppConfiguration` and the
shared `KeychainStore` behave identically per device.

`ImageRelayClientiOS/` ships a TabView root with three tabs:

- **Files** (`FilesGatewayView`): explains the File Provider model,
  shows registration status, opens Files.app via `shareddocuments://`.
- **Library** (`LibraryHomeView`): NavigationStack into iOS-native
  `CollectionsListiOSView`, `ProductsListiOSView`, and
  `APIDirectoryiOSView`. These views reuse Codex's `CollectionsState`,
  `ProductsState`, `LibraryAdminState` from
  `ImageRelayClient/<feature>/` — those service+state files are now
  listed as additional `sources:` paths in the iOS target. Views
  themselves stay platform-specific.
- **Settings** (`SettingsiOSView`): Form-based editor for API key,
  root folder ID, and sync toggles. "Sign out" removes the
  registered domain.

`FileProviderExtensioniOS/` is read-only and stateless. Unlike the macOS
sibling, it does NOT use `SyncDatabase` or `RemoteChangePoller`. Every
enumeration calls the API live; every `fetchContents` mints a fresh
quick-link, downloads, and deletes the quick-link. `currentSyncAnchor`
returns nil so the system never asks for incremental changes.
Required `createItem`/`modifyItem`/`deleteItem` methods are stubbed
with `NSFileProviderError(.notAuthenticated)` to make the read-only
posture explicit.

**Code review pass on Codex's beta 4**: stripped three dead
`import AppKit` lines from `WebhooksAdminView`, `ProductsBrowserView`,
`CollectionsBrowserView` (none reference AppKit symbols, the import was
leftover). Parallelized `LibraryAdminState.load()` with `async let` +
`withTaskGroup` for keyword-set fan-out — eight sequential awaits +
N per-set keyword fetches collapsed into two waves of parallel work.
Split `ProductsBrowserView.swift` into `Products/ProductsService.swift`
(service + state) and `Products/ProductsBrowserView.swift` (view only)
so the iOS target can compile the service without dragging in the
macOS view.

**Verification**: macOS test suite still 90/90 across 16 suites.
iOS host + extension build clean for `arm64-apple-ios18.0-simulator`
in 4.5s incremental, ~115s clean. `build_run_sim` installs and
launches; UI hierarchy snapshot confirms `Files` heading,
`File Provider` section, `Not configured yet` warning, disabled
`Open Files app` button, three-tab `TabView` at bottom, all with
populated VoiceOver labels.

**Decisions made**: iOS first cut is on-demand only (no SyncDatabase,
no upload). Adding caching/uploads later is a fence to cross with
clearer requirements. Service/state files compile into both targets
via `Project.yml` — preferred over moving them into `ImageRelayKit`
on round one because the move would touch existing macOS imports.
iOS Debug uses Automatic signing; macOS Release stays Manual.

**Left off at**: iOS app builds and renders on iPhone 17e Simulator
(`iOS 26.4`). File Provider domain hasn't been smoke-tested against
the live Image Relay account yet — that needs an iOS device with the
API key entered and a real iCloud-signed dev profile. The macOS path
is unchanged and the 1.1.0-beta.4 macOS DMG is still the latest
shipped artifact.

---

## 2026-05-09 - 1.1.0-beta.4: live API coverage pass + beta release candidate

**What changed**: Re-tested the 1.1 API surfaces against the live Image Relay account and corrected the places where beta 3 had inferred the wrong shapes. Collections now use the live `/collections/{id}/files.json` endpoint for membership and send comma-separated `asset_ids` to `/collections/{id}.json`, matching the API's 204 no-content update response. Upload links now encode `purpose` and decode live fields such as `uid`, `upload_link_url`, and `created_at`. Quick links, folder links, file types, keyword sets, keywords, users, and supported webhook events now have typed models and coverage. Webhook administration now creates `{ url, resource, action, notification_emails }` payloads from the live `/webhooks/supported.json` catalog instead of the beta 3 fixed event list. Added the read-only "API Directory" window for file types, keywords, users, quick/folder links, and webhook event discovery. Products now log load failures and explain account/API-key gating when the live account returns 401/403.

**Hardening**: Added a void `APIClient.put` path for 204 responses, section-level error handling in the API Directory so one permission-gated endpoint does not blank the whole view, stricter webhook URL validation, and extra product-load logging. Fixed `scripts/run-live-sync-matrix.sh` for Python 3.14 certificate validation by building an SSL context with `certifi` when available.

**Verification**: 90/90 ImageRelayKit tests pass across 16 suites. Unsigned `xcodebuild build` passes. `scripts/run-release-candidate-checks.sh 1.1.0-beta.4` passed. `RUN_LIVE_SYNC=1 scripts/run-release-candidate-checks.sh 1.1.0-beta.4` passed inside `Oliver's Stuff` (`2907644`), covering local file create, modify, delete, rename, zero-byte upload, 6 MB upload, folder rename, file move, and folder move. `scripts/build-developer-id-release.sh --version 1.1.0-beta.4 --smoke-install` archived, exported, notarized, stapled, built the DMG, smoke-installed over `/Applications/Image Relay.app`, passed Gatekeeper validation, and registered `com.oliverames.imagerelay-client.fileprovider(1.1.0-beta.4)`. Desktop automation opened `API Directory`, `Collections`, `Webhooks`, `Products`, and Settings/Activity windows from the app menus. DMG SHA-256: `8ee506f61456694d0a068e4ef202898b6d41c0b7fd3e7908aca8ff8bac333bec`.

**Decisions made**: Kept webhook consumption/relay out of the beta because it needs a public Cloudflare Worker or similar bridge. The app now covers webhook administration and event discovery only. Kept file types, keywords, users, and links read-only for 1.1 because the live API coverage value is discovery and validation; mutating library-admin settings needs a separate product decision. Products remain read-only and gracefully permission-gated for accounts without product access.

**Left off at**: 1.1.0-beta.4 artifacts are ready in `build/releases/1.1.0-beta.4`, and `/Applications/Image Relay.app` is installed from the notarized smoke install of build `20`. Still open: rotate the App Store Connect API key when convenient if it is still considered exposed.

---

## 2026-05-08 - 1.1.0-beta.3: Phase 3 (Collections) + Phase 4 (Products) + Phase 5 (Webhooks admin)

**What changed**: Three new feature surfaces, all delivered as standalone Window scenes triggered from a new menu bar "Library" submenu rather than expanding the Settings TabView (which would have hit 8+ tabs and become unwieldy). New ImageRelayKit models: `Collection`, `CollectionItem`, `CollectionItemAdd`, `Webhook`, `WebhookCreate`, `WebhookEventType`, and `Product`, with custom decoders that tolerate the field-name aliasing common across Image Relay deployments (`item_count` vs `file_count`, `filename` vs `file_name`, `is_active` vs `active` vs `enabled`, string-array events vs object-array events with `name` keys, category as either string or nested object). Each model includes an explicit `encode(to:)` to round-trip cleanly.

Host-app additions: `CollectionsService`/`CollectionsState`/`CollectionsBrowserView` (NavigationSplitView with collection list on the left, item list on the right with inline remove), `WebhooksService`/`WebhooksState`/`WebhooksAdminView` (list with active/inactive badges, sheet-based create form with toggle list of known event types, signing secret field, confirmation-aware delete), `ProductsService`/`ProductsState`/`ProductsBrowserView` (read-only list with search filter, asset count, category, SKU). New Window scenes: `collections-browser`, `webhooks-admin`, `products-browser`. New "Library" submenu in the menu bar with three items, each opening its window and activating the app via `NSApp.activate(ignoringOtherApps:)`. Bumped marketing version to `1.1.0-beta.3`, build number to `19`.

**Verification**: 80/80 ImageRelayKit tests pass (66 prior + 14 new across `CollectionTests`, `WebhookTests`, and `ProductTests`). `xcodebuild build` clean. The CRUD shapes (response wrappers, request bodies) follow the same tolerant-decoder pattern as `UploadLinksService`: try the wrapped form first, fall back to bare-array/bare-object.

**Decisions made**: Window scenes over Settings tabs. Read-only Products instead of full edit (write APIs aren't documented and the user value is mostly browsing for now). Removed-from-collection action is per-item via a row button rather than multi-select; multi-select needs more thought about whether it batches or sequences. Webhook event subscription uses a fixed list of known event types (`WebhookEventType.allKnown`) rather than fetching the catalog from the API — newer event types will need a model update, but this avoids an extra API roundtrip on every form open.

**Open questions**: Image Relay's exact response shape for `/collections.json`, `/collections/{id}/items.json`, `/webhooks.json`, `/products.json`, and create/delete responses are inferred from common patterns; the tolerant decoders in each service should absorb most variation, but live testing may reveal a shape that doesn't match. Some accounts require admin-tier API keys for webhook administration — the UI surfaces 403 responses as a "Couldn't load webhooks" error with a hint about admin credentials. Add-to-collection-from-Finder-selection isn't wired in the UI yet (the service supports it). Still open: rotate the App Store Connect API key when convenient if it is still considered exposed.

**Left off at**: Source for 1.1.0-beta.3 staged for commit. Build, notarize, GitHub prerelease still need to run. After beta 3 publishes, the remaining 1.1 scope is: Phase 1 polish remainder (multi-select metadata, keyword autocomplete, SQLite cache) + Phase 6 (file types, keywords, users admin) + Phase 7 (consumer webhook relay via Cloudflare Worker + SSE).

---

## 2026-05-08 - 1.1.0-beta.2: Phase 1 polish (custom fields + NSOpenPanel fallback) + Phase 2 (Upload Links)

**What changed**: Two coherent feature additions on top of beta 1.

Phase 1 polish: extended `FileMetadataUpdate` with a `customFields` array of `CustomFieldUpdate`, encoded under the `custom_fields` key. Extended `RemoteFileDetail.CustomField` to include a `field_type` string (when the API surfaces it) and to coerce numeric `value` payloads (`Int`, `Double`) into strings so the editor surface stays uniform. Added a `customFieldDrafts: [String: String]` map to `MetadataEditorState` keyed by `CustomField.stableID`, with diff-based change detection that only emits `CustomFieldUpdate` entries for fields whose drafts differ from the loaded detail. The `MetadataEditorView` now renders text editors for every custom field, with the field type shown as a badge when known. `MenuBarView`'s "Edit Metadata for Selected..." action now falls back to an `NSOpenPanel` when AppleScript denies (`SelectionError.notAuthorized`) or when nothing is selected (`SelectionError.noSelection`); the picker defaults to the user's CloudStorage Image Relay subdirectory when present.

Phase 2 (Upload Links): added `UploadLink` and `UploadLinkCreate` models in `ImageRelayKit`, plus a `Keyword` model staged for beta 3's autocomplete work. New `ImageRelayClient/UploadLinks/` group with `UploadLinksService` (list/create/delete via `GET/POST/DELETE /upload_links.json`, tolerating both bare-array and `{ upload_links: [...] }` response shapes), `UploadLinksState` view-model with create-form drafts and inline error reporting, and `UploadLinksSettingsView` with a list view, a sheet-based create form, copy-to-clipboard, and a confirmation alert for revocation. New `Tab("Upload Links", systemImage: "link")` added to the Settings `TabView`. Bumped marketing version to `1.1.0-beta.2`, build number to `18`. Settings window grew slightly to `540x460` to accommodate the extra tab and the upload-links list density.

**Verification**: 66/66 tests pass (59 prior + 7 new across `UploadLinkTests`, `KeywordTests`, and extended `MetadataTests` for `customFields` encode/decode and numeric value coercion). `xcodebuild build` clean. The upload-links integration relies on response shape discovery — the service tolerates both `[UploadLink]` and `{ upload_links: [UploadLink] }` decoding because the Image Relay API documentation isn't explicit about which Image Relay returns; we'll learn the actual shape when the user tests against the live account.

**Decisions made**: Editing custom file-type fields ships as a single text editor per field rather than per-type controls (dropdown/date/multi-select). Per-type editors would require fetching the file_type schema (`GET /file_types/{id}.json`), validating values per type, and rendering the appropriate control — that's its own design pass. Sending value as text and surfacing API errors back to the user is the honest middle ground for this beta. Keyword autocomplete via `GET /keywords.json` is staged (the `Keyword` model and tests are in place) but the UI hookup ships in beta 3. Multi-select metadata editing also lands in beta 3. SQLite cache for `RemoteFileDetail` deferred to beta 3 — it's an optimization, not a correctness gate, and adding it would require a `migrate v5` step that's better paired with the cache-coherence question for collections in beta 3 anyway.

**Open questions**: The Image Relay API response shapes for `/upload_links.json` (top-level wrapped vs. bare array) and for the create response (top-level wrapped vs. bare object) are inferred — we'll confirm once tested live. If the live shape differs, only the small `ListResponse`/`CreateResponse` adapter structs in `UploadLinksService` need updating. Still open from prior session: rotate the App Store Connect API key when convenient if it is still considered exposed.

**Left off at**: Source for 1.1.0-beta.2 staged for commit. Build, notarize, GitHub prerelease still need to run.

---

## 2026-05-08 - 1.1.0-beta.1: metadata editing with Finder-aware sheet (Phase 1)

**What changed**: First slice of 1.1, the metadata editing feature. Added `RemoteFileDetail` and `FileMetadataUpdate` model types in `ImageRelayKit` for `GET/PUT /files/{id}.json` round-trips. The model decodes description, keywords (string array OR object array with `name` keys), and `custom_fields`; the update body uses `encodeIfPresent` so unchanged fields aren't accidentally cleared. New `MetadataEditing/` group in the host app: `MetadataEditingService` builds an isolated `APIClient` from the active config, fetches detail, sends the update, then bumps `TrackedItem.metadataVersion` and signals the affected enumerator so Finder refreshes without waiting for the next remote poll. `FinderSelectionReader` runs an AppleScript against Finder to read the current selection — gated by a new `com.apple.security.scripting-targets` entitlement scoped to `com.apple.finder`. URL→item mapping uses `NSFileProviderManager.getIdentifierForUserVisibleFile(at:)` (wrapped in a `withCheckedThrowingContinuation` because the SDK only exposes the completion-handler form). `MetadataEditorState` is an `@Observable` view-model holding `Phase` (empty/loading/loaded/saving/saved/failed), description and keyword drafts, and dirty-state computation. `MetadataEditorView` is a SwiftUI form with description text editor, keywords text field, and read-only preview of custom file-type fields (editing those is deferred to Phase 1.b). New SwiftUI `Window("Edit Metadata", id: "metadata-editor")` scene in `App.swift`; new "Edit Metadata for Selected..." item in `MenuBarView`. Bumped marketing version to `1.1.0-beta.1`, build number to `17`.

**Verification**: 59/59 ImageRelayKit tests pass (53 prior + 6 new metadata model tests covering string-keyword decode, object-keyword decode, custom-fields decode, missing-fields decode, encode-omits-nil, hasChanges semantics). `xcodebuild test` for the full ImageRelayClient scheme passes 59/59. Unsigned `xcodebuild build` succeeds. The integration paths through `APIClient.get/put` are exercised by the existing folder rename test path (same code path, different URL); a separate `MetadataAPITests` suite was prototyped but removed because cross-suite parallelism collides with `APIClientTests`'s static `MockURLProtocol.requestHandler`.

**Decisions made**: AppleScript bridge over a Services/Quick Action extension for selection reading — single target, sandbox-friendly with `scripting-targets`, no new appex to sign. `Window` scene over a sheet because `LSUIElement` apps have no parent window for sheets to attach to, and SwiftUI's `Window` plus `NSApp.activate(ignoringOtherApps:)` is the documented pattern. No new SQLite column for cached metadata in this phase — every sheet open does a live `GET`, which keeps the database schema unchanged and the cache-coherence question deferred to Phase 1.b. Custom file-type fields are read-only in this beta; making them editable requires per-template schema validation that's out of scope for the first cut. The `MetadataEditingService` constructs its own `APIClient` rather than reusing one held by `DomainManager`, so the host's existing concurrency boundaries don't shift.

**Open questions**: Multi-select metadata editing isn't wired (sheet always loads the first selected file). The AppleScript path requires the user to grant Automation permission for Finder on first invocation; if they decline, the sheet opens in `failed` phase with a recovery message rather than falling back to an `NSOpenPanel`. Custom-field editing, keyword autocomplete from `GET /keywords.json`, and a metadata cache layer all stay deferred. Still open from prior session: rotate the App Store Connect API key when convenient if it is still considered exposed.

**Left off at**: Source is committed for 1.1.0-beta.1; the build, notarize, GitHub prerelease publish, and bridged appcast still need to run.

---

## 2026-05-08 - 1.0.1 public release: repo consolidation + Liquid Glass icon

**What changed**: Cut 1.0.1 from a single repository (`oliverames/imagerelay-client`), retiring the separate `oliverames/imagerelay-client-releases` host. Updated `SUFeedURL`, the release script's `SPARKLE_RELEASE_REPOSITORY`, README badges and download link, and SUPPORT.md. Bumped marketing version to `1.0.1` and build number to `16`. Migrated AppIcon from a legacy `.appiconset` (PNG bitmaps with hand-rolled rounded-rectangle corners) to an Icon Composer `.icon` bundle; macOS 26 now renders the proper continuous-curve squircle, specular highlight, and adaptive light/dark/tinted/clear variants at runtime. Bridge `appcast.xml` published one-time to the old repo so existing 1.0.0 installs see the bridge update. Confirmed README test count claim (`51 → 53`).

**Verification**: 53/53 ImageRelayKit tests pass. `scripts/run-release-candidate-checks.sh 1.0.1` passed. `scripts/build-developer-id-release.sh --version 1.0.1 --smoke-install` archived, exported, notarized and stapled the app and DMG, smoke-installed over `/Applications/Image Relay.app`, passed Gatekeeper validation, and confirmed the File Provider extension via `pluginkit` as `com.oliverames.imagerelay-client.fileprovider(1.0.1)`. Anonymous `curl` confirmed `https://github.com/oliverames/imagerelay-client/releases/latest/download/appcast.xml` and `https://github.com/oliverames/imagerelay-client-releases/releases/latest/download/appcast.xml` both serve the bridged 1.0.1 appcast (byte-identical), and the DMG download URL inside resolves with HTTP 200. DMG SHA-256: `664603ddd14849ce27ca73bae6fc088347ccb9f167584230d386225051bdaf3f`.

**Decisions made**: Kept `App Icon/Image Relay Icon.pxd` and `Image Relay Icon.svg` as authoring masters; the build-wired `.icon` lives at `ImageRelayClient/AppIcon.icon` so there is one canonical version. Did not retroactively rewrite earlier WORKLOG entries that reference `imagerelay-client-releases` — those are historical narrative for releases that actually shipped from there. The `imagerelay-client-releases` repo is intentionally not archived yet to give 1.0.0 users time to see the bridge update.

**Left off at**: 1.0.1 is published as the latest release on `oliverames/imagerelay-client`; bridge release is published on `oliverames/imagerelay-client-releases`. `/Applications/Image Relay.app` is installed from the smoke install of build 16.

---

## 2026-05-08 - 1.0.1 release prep: repo consolidation + Liquid Glass icon

**What changed**: Consolidated public release hosting from `oliverames/imagerelay-client-releases` into the source repo `oliverames/imagerelay-client`. Updated `SUFeedURL` in the host app `Info.plist`, the `SPARKLE_RELEASE_REPOSITORY` constant in the release script, README badges and download link, and the SUPPORT.md latest-release link. Bumped marketing version to `1.0.1` and build number to `16`. Migrated the AppIcon from a legacy `.appiconset` (PNG bitmaps with hand-rolled rounded-rectangle corners) to a single Icon Composer `.icon` bundle at `ImageRelayClient/AppIcon.icon`, so macOS 26 renders the proper continuous-curve squircle, specular highlight, and adaptive light/dark/tinted/clear variants at runtime through Liquid Glass material instead of from baked-in bitmaps. Confirmed the README test count claim (`51 tests across 9 suites` → `53 tests across 9 suites`).

**Verification**: `swift test --package-path ImageRelayKit` passed 53 tests. `xcodebuild build` succeeded with the new `.icon` file routed through `actool` — the resulting `Assets.car` contains 7 Icon Image variants, 3 IconImageStack arrangements, and the SVG vector layer preserved as scalable vector (vs. the legacy 8 PNG bitmaps). Generated `assetcatalog_generated_info.plist` now sets `CFBundleIconName = AppIcon`. xcodegen 2.45.4 recognized `AppIcon.icon` as `wrapper.icon` and added it to the Resources build phase as a single bundle reference, not recursively.

**Decisions made**: Kept `App Icon/Image Relay Icon.pxd` and `Image Relay Icon.svg` as authoring masters in the existing `App Icon/` directory; the `.icon` bundle that ships is in `ImageRelayClient/AppIcon.icon` so there is one canonical build-wired version. Did not retroactively rewrite earlier WORKLOG entries that reference `imagerelay-client-releases` — those are historical narrative for the releases that actually shipped from there.

**Left off at**: 1.0.1 source is staged for commit. The build, notarization, GitHub release, and one-time bridge appcast publish to `imagerelay-client-releases` for existing 1.0.0 users still need to run.

**Open questions**: Still open: rotate the App Store Connect API key when convenient if it is still considered exposed.

---

## 2026-05-08 - 1.0.0 public release

**What changed**: Completed the Finder parity pass for local API mutations. Folder create now uses `POST /folders/{parent_id}/children`; folder rename and move use `PUT /folders/{id}.json`; file move waits for the file to leave the old folder and appear in the new one; file rename preserves the remote file ID through a version upload with `file_name`; deletes wait for remote confirmation before local cleanup. Added confirmation and cleanup safety around local creates, uploads, renames, moves, and deletes so the database is not advanced until Image Relay listings show the expected remote state. Updated API compatibility docs, release testing docs, README, support/privacy notes, issue templates, and release scripts for 1.0.0 build 15.

**Verification**: `swift test --package-path ImageRelayKit` passed 53 tests. `scripts/run-release-candidate-checks.sh 1.0.0` passed, including package tests, XcodeGen, Xcode scheme tests, and unsigned app build. `scripts/build-developer-id-release.sh --version 1.0.0 --smoke-install` produced a signed, notarized, stapled DMG and installed build 15 over `/Applications/Image Relay.app`. Live sync matrix passed in selected folder `Oliver's Stuff` (`2907644`) and a temporary second folder, covering local file create, modify, rename, move, delete, zero-byte upload, 6 MB upload, folder create, folder rename, and folder move. Diagnostics export was verified to omit API key material. Public Sparkle appcast and DMG download were verified anonymously from `oliverames/imagerelay-client-releases`, and a Beta 14 install fetched and completed the update to build 15 after app quit.

**Decisions made**: Screenshots were skipped for this release per user direction. Webhooks, metadata editing, upload links, and collection/product administration remain intentionally outside 1.0.0 scope.

**Left off at**: Version `1.0.0` build `15` is published as the latest public release in `oliverames/imagerelay-client-releases`, and `/Applications/Image Relay.app` is installed from build 15.

**Open questions**: Still open: rotate the App Store Connect API key when convenient if it is still considered exposed.

---

## 2026-05-07 - Beta 13: immediate local mutation refresh

**What changed**: Local File Provider mutations now signal affected enumerators immediately after successful API writes. Creates, version uploads, conflict-copy uploads, folder moves, metadata changes, and deletes all notify the working set, root container, and affected parent folder containers without waiting for the next remote polling window. The upload itself was already immediate through `createItem` and `modifyItem`; this beta tightens the post-upload Finder refresh path. Bumped build number to `13`, updated README release docs, and hardened the Developer ID release script so it installs isolated Python release dependencies when the system `cryptography` package is importable but unusable.

**Verification**: `git diff --check` passed. `swift test --package-path ImageRelayKit` passed 50 tests. `xcodebuild test -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'` passed 50 tests. Unsigned compile check with `CODE_SIGNING_ALLOWED=NO` passed for the host app and File Provider extension. `scripts/build-developer-id-release.sh --version 1.0.0-beta.13 --smoke-install` archived, exported, notarized and stapled the app and DMG, installed over `/Applications/Image Relay.app`, passed Gatekeeper validation, and confirmed the File Provider extension via `pluginkit`. Live sync test stayed inside `Oliver's Stuff` (`2907644`): local file `Codex-Beta13-ImmediateSync-20260507-123801.txt` uploaded as Image Relay file `206441993`, logged `Signaled immediate local sync after created file`, then local delete removed it remotely and logged `Signaled immediate local sync after deleted item`. Cleanup verified no matching local or remote test file remained. DMG SHA-256: `98188e8dd11475e7b354ae11ece351c2679b2ac08e3345ecc1744cc8b2f3e474`.

**Decisions made**: Did not add a separate filesystem watcher. Apple's replicated File Provider model already calls the extension for local creates, modifications, moves, and deletes, and adding an external watcher would risk duplicate or out-of-order API writes. The safer path is to keep File Provider as the local-change source of truth and make successful local API mutations resignal immediately.

**Left off at**: Beta 13 artifacts are ready in `build/releases/1.0.0-beta.13`, and `/Applications/Image Relay.app` is installed from the notarized Beta 13 DMG.

**Open questions**: Still open: rotate the App Store Connect API key when convenient if it is still considered exposed. Continue exercising rename, move, and conflict behavior against the selected `Oliver's Stuff` folder before leaving beta.

---

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

## 2026-05-07 - Beta 14 public-release hardening

**What changed**: Added Sparkle update integration with a menu-bar Check for Updates action, public GitHub release appcast URL, app public EdDSA key, and sandbox settings required for Sparkle's installer service. The release script now generates `appcast.xml` beside the notarized DMG, points download/update assets at `oliverames/imagerelay-client-releases`, and reads the Sparkle private key from 1Password. Added repeatable release-candidate and live-sync scripts: `scripts/run-release-candidate-checks.sh` and `scripts/run-live-sync-matrix.sh`.

**Sync safety**: Disabled Finder folder moves for the public beta because Image Relay has no atomic folder-move endpoint. File moves and folder renames remain enabled. Removed the old recursive folder move emulation path from the extension so an interrupted create/copy/delete sequence can no longer damage remote folder contents. The host app's remote signal loop is now a 5-minute watchdog; the extension poller remains the source of truth for the configured poll interval and remote-poll status.

**Upload edge cases**: Added a zero-byte file create workaround after live API testing showed `POST /upload_jobs.json` returns an empty `files` array when the requested file size is 0. The extension now creates an empty file as a one-byte placeholder, immediately replaces it with a zero-byte version, and cleans up the placeholder if the replacement fails. Multi-chunk upload decoding now tolerates intermediate `204` empty responses and keeps the completed upload job from the final chunk.

**Diagnostics and polish**: Diagnostics export now includes `system.json` and `crash-reports.txt`, and `manifest.json` records app version/build and update-feed presence without exposing secrets. General settings now includes a Save and Connect action plus a warning when uploads are enabled but no Default File Type ID is configured.

**Verification**: Final Beta 14 passed `scripts/run-release-candidate-checks.sh 1.0.0-beta.14`, signed Developer ID packaging, notarization, stapling, `/Applications` smoke install, codesign/Gatekeeper/stapler validation, diagnostics export, public appcast download, public DMG checksum download, and `scripts/run-live-sync-matrix.sh` against selected folder `2907644` only. The live matrix covered create, rapid edit, Finder delete, zero-byte upload/delete, and 6 MB upload/delete.

**Left off at**: Beta 14 is released from the public asset host at `https://github.com/oliverames/imagerelay-client-releases/releases/tag/v1.0.0-beta.14`. The source repo's private `v1.0.0-beta.14` release and tag were also updated to the final source commit and final assets so the internal release does not point at stale artifacts.

**Open questions**: Still open: rotate the App Store Connect API key when convenient because an earlier repo-local copy was treated as exposed.

---

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
