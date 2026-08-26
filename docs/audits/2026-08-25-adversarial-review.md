# Adversarial Repo Review — 2026-08-25

Repo-wide bug-fixing pass on `imagerelay-client` at commit `5da9b4b` (post-1.4.3).
Method: four parallel finder agents over Kit core, File Provider extensions,
host apps/services, and cross-file consistency; every finding then went to an
independent skeptic agent whose default stance was refutation. Baseline before
any change: macOS test suite passed (221 kit + 78 extension tests), iOS
simulator build succeeded.

Scorecard: 31 findings confirmed, 3 partially corrected, 1 refuted.
All confirmed findings are either fixed in this pass or explicitly parked with
a reason below.

## Fixed

### ImageRelayKit

| ID | Severity | Finding | Fix |
|----|----------|---------|-----|
| A2 | Major | `getAllPages` broke silently at the 100-page cap; a truncated listing is indeterministic input to deletion detection, so folders >10k children would see items vanish from Finder after two truncated passes | New `APIError.paginationLimitExceeded(path:)`; the client now fails the listing instead of returning a complete-looking partial one. Mapped to `cannotSynchronize` in both extensions' error mappers |
| A1 | Major | OAuth refresh lock: on a 10 s acquisition timeout the process proceeded to refresh *unlocked* and its `defer` deleted whichever process held the lock; concurrent refreshes with rotating refresh tokens revoke the loser's tokens | Track `didAcquireLock`; on timeout re-read config and return without refreshing or touching the lock |
| A3 | Major | `.networkError` was retryable for every HTTP method, so a lost-response timeout could double-fire `POST /upload_jobs.json` and quick-link mints, orphaning server-side artifacts (upload jobs have no expiry backstop) | Transport-level retries now restricted to idempotent methods (`isIdempotentMethod`: GET/HEAD/PUT/DELETE); non-idempotent methods throw immediately. Response-based retries (502/503/429) unchanged |
| C2 | High | iOS sign-out emptied the draft key but `AppConfiguration.save` only deleted the Keychain item under OAuth, so the stored key survived and resurrected itself (and File Provider access) on next launch | `save()` now treats an empty `apiKey` as "no credential" regardless of authMethod. Companion hardening: iOS `ConfigurationStore.load()` preserves the Keychain credential when config.json is unreadable, so a transient read failure can't lead a later save to delete the live key. Test updated from pinning the old preserve-behavior to pining deletion (`emptyAPIKeySaveDeletesKeychainItem`) |
| A4 | Minor | Keychain test-mode detection substring-scanned all of `ProcessInfo.arguments`, including argv[0]; any install path containing "test" silently diverted production secrets into the in-memory store | Removed the argv scan; structured markers remain (`NSClassFromString("XCTest")`, `XCTestConfigurationFilePath`, `XCTestBundlePath`). Both test suites trigger via those markers, verified |
| A5 | Minor | `SyncAnchor.init?(data:)` used aligned `load(as: UInt64.self)` on `Data` whose backing storage has no alignment guarantee (round-trips through SQLite blobs) — undefined behavior | `loadUnaligned(as:)` (Swift 5.7+, platforms are macOS 15/iOS 18) |
| A6 | Minor | Limiter waits swallowed cancellation (`try? Task.sleep` / discarded `checkCancellation`), so cancelled tasks kept polling for up to the 3 h sustained cooldown | `AsyncRateLimiting.acquire()` is now `async throws` and propagates `CancellationError`; both conformers updated; all production call sites already threw; new cancellation unit test added |
| A7 | Minor | `download()` leaked URLSession's temp file on any HTTP failure or move failure | `defer { try? removeItem }` after the download returns (no-op after successful move) |
| A8 | Minor | Cancelling the 429 backoff sleep skipped `endRateLimitWait()`, stranding `rateLimitInFlight` until the next natural reset | Sleep wrapped so the telemetry end runs on cancellation too |
| A10 | Minor | Link-header parser required exactly two `;`-separated segments and returned nil unconditionally on the first malformed `rel="next"`, dropping decorated headers and shadowing valid later elements | Scan all parameters for `rel="next"` (quoted or bare, case-insensitive); keep searching after an unparsable URL |
| A11 | Minor | `ThrottleStateStore.recordRateLimit`/`recordSuccess` did unsynchronized load-modify-save across ~12 instances sharing one file; interleaved writes clobbered failure counts | Single coordinated read-modify-write mirroring `SharedRateLimiter.updateState` |
| A12 | Minor | Force-unwrapped calendar math in `SyncPauseState.deadline(for:)` | Failable chain with a 24 h fallback |
| C8 | Low | Default API base URL duplicated as a literal in three places | New `AppConfiguration.defaultBaseURL`; all three sites use it |
| D7 | Info | Dead public method `SyncDatabase.clearPendingRemoteDeletion(identifier:)`, zero callers incl. tests | Deleted |

### File Provider extensions

| ID | Severity | Finding | Fix |
|----|----------|---------|-----|
| B1 | Medium | macOS `fetchContents` left the partial download in tmp when the download failed after minting the quick link | Remove temp file before rethrowing (quick-link cleanup already present) |
| B2 | Medium | Same leak in iOS `fetchContents` | Same fix |
| I1 | Low | macOS `fetchPartialContents` leaked its sparse temp file when `writePartialContent` threw | Same fix |
| B7 | Low | Poller was constructed inside a detached task that assigned `self?.poller`; `invalidate()` racing that assignment read nil and left the poller running; `invalidate()` also never cleared the property | Construct + publish synchronously, start inside the task; invalidate stops and nils |

### Host apps

| ID | Severity | Finding | Fix |
|----|----------|---------|-----|
| C1 | High | Multi-select metadata save crashed deterministically: `Dictionary(uniqueKeysWithValues:)` traps whenever two selected files share a custom-field definition — the normal multi-select case | `Dictionary(_:uniquingKeysWith:)`, honoring the existing last-write-wins comment |
| C3 | Medium | Menu bar polling materialized up to 1,000 pending-deletion rows twice per second just to count them on the main thread | New SQL-count `SyncDatabase.pendingRemoteDeletionCount()` modeled on `openSyncOperationCount()` |
| C5 | Medium | A failed webhook delete flipped a fully loaded admin window into the full-screen "Couldn't load webhooks" error | Delete failures set `actionError` and render as a dismissible banner above the still-visible list; full-window error reserved for genuinely empty lists |
| C6 | Medium | Collection remove-item recreated the collection server-side name-only but locally re-injected the old description, so the UI lied about state the server no longer had | Return the collection as the server sees it; alert copy now states description/cover loss and ID breakage for both public and non-public collections |
| C7 | Low | Unrecognized create-response envelopes in Webhooks/UploadLinks threw "not configured", sending users hunting for a settings problem that didn't exist | Added `unexpectedResponse` to both ServiceError enums and used it for envelope misses, matching Collections/LibraryAdmin |
| C9 | Low | `DomainManager.updateConfiguration` swallowed save errors, letting the menu claim "Sync Stopped"/"Reconnected" while disk state said otherwise after relaunch | Returns success; callers surface the error via `lastError` and skip the optimistic UI flip |
| C10 | Low | iOS Collections tab spun forever on a successfully loaded empty list | Loaded-and-empty renders `ContentUnavailableView`, mirroring Products |
| C12 | Low | Dead nil-return branch in `CollectionsState.removeItem` would have wiped the collection from local sidebar state if ever reached | `removeItem` returns non-optional; branch removed |
| C4 | Medium | Webhook relay loop performed two full Keychain-hitting config loads per iteration (refreshStatus + its own load); remote watchdog did the same | `refreshStatus()` returns the freshly loaded config (@discardableResult); both loops consume it — one load per iteration instead of two. Full elimination needs an `isConfigured`-without-secrets API (parked, below) |

### Docs / consistency

| ID | Finding | Fix |
|----|---------|-----|
| D1 | CLAUDE.md/GEMINI.md claimed both platforms share one Keychain access group; code, Project.yml, and AGENTS.md say iOS uses `...-client.ios`. An agent following CLAUDE.md would write iOS Keychain code against the wrong group | Both mirrors corrected to match AGENTS.md and `KeychainStore.sharedAccessGroup` |
| D2 | CLAUDE.md said the dead 1Password relay-token item awaited deletion; GEMINI.md recorded it deleted 2026-06-25 (live check agrees with GEMINI) | CLAUDE.md updated to "was deleted 2026-06-25" |
| D3 | All three mirrors said "4 targets"; Project.yml defines five | Corrected ×3 |
| D4 | AGENTS.md build command lacked the `CODE_SIGNING_ALLOWED=NO` requirement documented in the other mirrors | Command block aligned |
| D5 | Shared-container snippet showed the unprefixed app group; shipped constant is team-prefixed | Snippets now show the real constant form ×3; App Group bullet likewise |
| D6 | README architecture diagram named nonexistent iOS views (`FilesView`) and omitted the Upload Links and Issues settings tabs | Diagram lists actual iOS sources; tabs corrected |
| B5 | Seven macOS completion-handler sites used the private `UncheckedBox` wrapper rather than the documented `nonisolated(unsafe)` capture — convention drift, zero behavioral difference (verified equivalent). Migrating would churn 19 sites/signatures for no behavioral gain | Documented `UncheckedBox` in all three mirrors as the accepted alternative pattern |
| D8 | Untracked gitignored `.wrangler` residue of the decommissioned webhook worker lingered locally | Moved to Trash |

## Second pass (same day)

Follow-up improvements after the main pass shipped, each research-backed:

1. **A9 implemented — OAuth credentials moved out of the URI.** RFC 6749
   §2.3.1 ([rfc-editor.org/rfc/rfc6749](https://www.rfc-editor.org/rfc/rfc6749#section-2.3.1))
   states token-endpoint client credentials "can only be transmitted in the
   request-body and MUST NOT be included in the request URI"; the old
   query-string form violated this directly. Originally parked pending live
   verification, then un-parked because the OAuth UI is behind
   `ENABLE_OAUTH_CONFIG_UI` (no default-build exposure) and the pinned tests
   are in-repo. `OAuthClient.tokenRequest` now sends a deterministic,
   percent-encoded (RFC 3986 unreserved set) form body; the refresh test pins
   body placement and an empty URL query. A manual OAuth sign-in smoke test is
   still recommended at the next release-candidate run.
2. **A3 refined — chunk uploads keep transport retries.** Self-review found
   chunk uploads travel as POST (`upload(data:to:)`), so blanket method gating
   would have stripped their resilience against mid-upload connection drops.
   Chunks and thumbnails overwrite by path (same bytes, same target), so they
   now opt back in via `transportRetriesAllowed`; job/link/folder creation
   POSTs remain fail-fast. New tests pin GET-retry / POST-fail-fast /
   chunk-retry behavior.
3. **Regression locks added** for pass-one fixes: decorated/unquoted/shadowed
   Link-header parsing (PaginationTests ×3), `pendingRemoteDeletionCount`
   parity with row listings (SyncDatabaseTests), concurrent cross-instance
   throttle-store increments surviving exactly (ThrottleStateStoreTests).

Verification after the second pass: 230 ImageRelayKit tests + 78 File Provider
extension tests pass on macOS; iOS simulator build succeeds.

## Deferred items — resolution (same day, third wave)

1. **A9** — implemented in the second pass (see above).
2. **B3 / incidental — deletion gate**: now time-based. Confirmation requires
   two misses AND 60s of elapsed evidence (`Enumerator.deletionEvidenceConfirmed`,
   `deletionConfirmationAge` injectable), and `SyncDatabase` resets a pending
   row whose last miss is older than 24h (fresh count + fresh first-seen), so
   neither same-window passes nor unrelated later misses can compound into a
   false deletion. Three new tests cover both halves plus the reset.
3. **C11 latent Settings OAuth downgrade**: fixed. With `ENABLE_OAUTH_CONFIG_UI`
   off, save-on-disappear now leaves a stored live-OAuth configuration's
   credential fields untouched instead of persisting the forced `.apiKey` view
   state over it; non-credential settings still save.
4. **CredentialCache lock span**: evaluated and intentionally kept. The wide
   lock is the single-flight that prevents Keychain prompt storms (a documented
   hard rule) and prevents an in-flight load from publishing past
   `invalidate()`. Rationale documented in-code.
5. **iOS per-operation `loadAndRefresh`**: fixed with `ConfigRefreshThrottle`.
   All three iOS call sites now refresh only when 60s elapsed or config.json's
   mtime moved, eliminating per-download Keychain reads and near-expiry OAuth
   lock-file serialization while keeping settings changes immediate and the
   extension stateless across restarts.
6. **Live OAuth sign-in smoke test**: still open, blocked on a human. No local
   app-group config exists on this machine to learn the tenant, and the check
   that matters is a real interactive sign-in. Recommended once, at the next
   release-candidate run.
7. **B6 Trash-deletes-remote UX**: resolved by owner decision 2026-08-25 --
   keep current behavior (Finder delete = immediate permanent server delete).
   Documented in all three instruction mirrors so future reviews do not
   re-flag it.

## Refuted by skeptics

- **B4 — `GET /folders/{id}` without `.json`**: flagged as a probable wrong path silently swallowed by `try?`. Refuted: WORKLOG.md and API_COMPATIBILITY.md document the bare detail endpoint as deliberate, and its failure mode degrades gracefully to child-listing polling. No change.

## Parked (judgment calls outside this pass's authority)

1. **A9 — OAuth secrets travel in URL query strings** (`client_secret`, `code`, `refresh_token` on token/refresh requests). RFC 6749 §2.3.1 expects credentials in an `application/x-www-form-urlencoded` body. Not changed here because it alters the wire format against a third-party server this repo deliberately does not live-test outside `Test Library`; tests also pin the query shape (ConfigurationTests.swift:701). Recommended follow-up: switch to form body + update pinned tests, then verify once against the live account.
2. **B3 / incidental — deletion gate relies on miss *count*, not elapsed time**: two back-to-back enumerations seconds apart can confirm a deletion the two-pass gate exists to ride out. Fixing properly means time-based confirmation (e.g., `firstSeenAt` age floor), which changes sync semantics and several tests. Related: pending-deletion rows never expire, so two unrelated transient misses weeks apart can confirm. Worth a dedicated design pass.
3. **B6 — Finder "Move to Trash" permanently deletes the remote asset** (⌘-delete routes to the server DELETE; nothing lands in any Trash). Code comments show intent, but destructive-by-default UX deserves an explicit product decision: soft-delete confirmation, or mapping trash to a "Removed" folder.
4. **C11 (latent)** — closing macOS Settings force-persists `authMethod = .apiKey`; only reachable if an external OAuth callback completes while Settings is open (OAuth UI is feature-flagged off). Fold into the next OAuth work.
5. **Incidental** — `CredentialCache` holds one NSLock across stat + JSON decode + Keychain reads; contention risk, not correctness.
6. **Incidental** — iOS extension calls `loadAndRefresh` per fetchContents; near-expiry OAuth bursts serialize on the lock file. Acceptable for the stateless design; revisit if OAuth tenants report slow downloads.

## Verification

- `xcodebuild test -scheme ImageRelayClient -destination 'platform=macOS'`: **passed** — 222 kit tests (25 suites) + 78 FileProviderExtensionTests (9 suites). Net +1 test (limiter cancellation).
- `xcodebuild build -scheme ImageRelayClientiOS -destination 'platform=iOS Simulator,name=iPhone 17e'`: **succeeded**.
- One existing test intentionally re-contracted (empty-key save behavior) rather than relaxed.
