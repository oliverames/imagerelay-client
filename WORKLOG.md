# Worklog

The [complete worklog archive](<WORKLOG-2026-10-13.md>) preserves the previous file byte for byte, including dated decisions, failures, test results and unresolved questions. It stays beside this file so its relative links keep their original base. Older `WORKLOG.md` line references refer to that historical record. Entries below describe the source and issue state reviewed on October 13, 2026; they do not establish fresh device, account or release acceptance.

## Continue from here

[README](README.md) describes current Finder behavior, the read-only iOS extension, setup and builds. [API Compatibility](API_COMPATIBILITY.md) records the service contract and [API Coverage](API_COVERAGE.md) maps supported operations. Release procedures remain in [Release Testing](RELEASE_TESTING.md) and [Release Reporting](<Release Reporting.md>).

The source declares 1.4.4 (47). The [October 6 migration review](<docs/Migration Review 2026-10-06.md>) records signed Mac/iOS exports, Mac notarization and a fresh Mac installation. Callback routing, File Provider runtime behavior, iOS delivery and updater acceptance are separate. The October 13 issue review retired [#38](https://github.com/oliverames/imagerelay-client/issues/38) as not planned; it did not establish that those checks passed.

Multi-folder appearances and explicit Add to Folders support are implemented. Removing or moving one membership remains unsupported because the API does not document a safe conditional removal operation. The current README describes that narrower limit; older worklog and issue wording predates the implementation.

## Keep these gaps visible

- [#36](https://github.com/oliverames/imagerelay-client/issues/36) retains the membership gap. Do not remove the global asset as a substitute for removing one membership.
- [#35](https://github.com/oliverames/imagerelay-client/issues/35) retains active notarization-key rotation and verification.
- [#33](https://github.com/oliverames/imagerelay-client/issues/33) retains the Homebrew publishing decision. The tap exists as of October 13, but its Image Relay cask was still absent when reviewed. The local cask and sync script remain in place pending that decision.

The former bundled webhook relay was decommissioned in June. Optional relay support and the OAuth callback Worker still have current callers; neither is obsolete merely because that older relay was removed.

## Find the full record

| Record | Contents |
| --- | --- |
| [October closeouts](<WORKLOG-2026-10-13.md#2026-10-07---github-issue-review-closeout>) | Migration, documentation and dated issue status |
| [1.4.4 release](<WORKLOG-2026-10-13.md#2026-08-26---144-release-build-47>) | Release provenance and verification |
| [Relay retirement](<WORKLOG-2026-10-13.md#2026-06-25---webhook-relay-worker-decommissioned>) | Removed service and retained optional client behavior |
| [Native rebuild](<WORKLOG-2026-10-13.md#2026-04-07----python-removal-sync-gap-implementations-merged-to-main>) | Python retirement and early native implementation history |

The archive preserves an old machine-local memory link that is unavailable in this checkout. Use the maintained API documents above for current behavior.

## Record new work

Add dated outcomes here with source, verification and remaining limits. Keep historical release receipts and failed attempts intact.

### 2026-10-23 - Security and cleanup review

- The macOS `Info.plist` now sets `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`, matching Ping Warden and Skylight Bridge. The release script has signed the whole appcast since October 7 and `publish-release.py` verifies it against the shipped key, so enforcement starts with the next build made from this source. The local `build/releases/1.4.5` app predates the change. The published 1.4.4 feed is unsigned, which is harmless because 1.4.4 does not enforce signing.
- An OAuth callback no longer passes the state check when no sign-in is pending; a missing callback state used to equal the cleared stored state.
- `FinderSelectionReader` no longer traps on an empty Finder selection (`1...0`).
- Removed unused code: the file-move wait helper and its error case, `MoveRequest`, the unused permission-group decoder, the folder-move record writers that only clone-based moves used, and two unused script imports. CI now skips documentation, cask and Worker-only changes.
- Flagged, not changed: Finder's scripting definition has no `com.apple.finder.idle` access group, and the signed 1.4.4 app lacks `com.apple.security.automation.apple-events` and `NSAppleEventsUsageDescription`. Reading the Finder selection therefore probably never succeeds, and Edit Metadata falls back to the file picker. A fix needs an entitlement decision and a signed runtime test.
- Verification: unsigned macOS `xcodebuild build` succeeded; `swift test` in ImageRelayKit passed 243 tests in 25 suites; the release-script unit tests passed. The update path, OAuth sign-in and Finder selection were not exercised at runtime.

<details>
<summary>Historical section links</summary>

These anchors keep older links to this worklog connected to the preserved sections.

<a id="2026-10-07---github-issue-review-closeout"></a>
[2026-10-07 - GitHub Issue Review Closeout](WORKLOG-2026-10-13.md#2026-10-07---github-issue-review-closeout)

<a id="2026-10-07---readme-refresh-closeout"></a>
[2026-10-07 - README Refresh Closeout](WORKLOG-2026-10-13.md#2026-10-07---readme-refresh-closeout)

<a id="2026-10-07---account-migration-closeout"></a>
[2026-10-07 - Account Migration Closeout](WORKLOG-2026-10-13.md#2026-10-07---account-migration-closeout)

<a id="2026-08-26---144-release-build-47"></a>
[2026-08-26 - 1.4.4 release (build 47)](WORKLOG-2026-10-13.md#2026-08-26---144-release-build-47)

<a id="2026-08-25---comprehensive-adversarial-bug-fixing-pass"></a>
[2026-08-25 - Comprehensive adversarial bug-fixing pass](WORKLOG-2026-10-13.md#2026-08-25---comprehensive-adversarial-bug-fixing-pass)

<a id="2026-07-13---public-release-hardening-and-ci-flake-fix"></a>
[2026-07-13 - Public release hardening and CI flake fix](WORKLOG-2026-10-13.md#2026-07-13---public-release-hardening-and-ci-flake-fix)

<a id="2026-06-25---webhook-relay-worker-decommissioned"></a>
[2026-06-25 - Webhook relay worker decommissioned](WORKLOG-2026-10-13.md#2026-06-25---webhook-relay-worker-decommissioned)

<a id="2026-06-22---security-sanitized-aws-key--client-data-from-test-fixture-and-history"></a>
[2026-06-22 - Security: sanitized AWS key + client data from test fixture and history](WORKLOG-2026-10-13.md#2026-06-22---security-sanitized-aws-key--client-data-from-test-fixture-and-history)

<a id="2026-06-11---icon-asset-rename-sync-conflict-audit-follow-up"></a>
[2026-06-11 - Icon asset rename (sync-conflict audit follow-up)](WORKLOG-2026-10-13.md#2026-06-11---icon-asset-rename-sync-conflict-audit-follow-up)

<a id="2026-06-10---post-release-login-fix-oauth-ui-removal-file-type-auto-resolve-webhook-relay"></a>
[2026-06-10 - Post-release: login fix, OAuth UI removal, file-type auto-resolve, webhook relay](WORKLOG-2026-10-13.md#2026-06-10---post-release-login-fix-oauth-ui-removal-file-type-auto-resolve-webhook-relay)

<a id="2026-06-10---143-release"></a>
[2026-06-10 - 1.4.3 release](WORKLOG-2026-10-13.md#2026-06-10---143-release)

<a id="2026-06-10---quick-link-lifecycle-hygiene"></a>
[2026-06-10 - Quick-link lifecycle hygiene](WORKLOG-2026-10-13.md#2026-06-10---quick-link-lifecycle-hygiene)

<a id="2026-06-09---142-rate-limit-hardening-release"></a>
[2026-06-09 - 1.4.2 rate-limit hardening release](WORKLOG-2026-10-13.md#2026-06-09---142-rate-limit-hardening-release)

<a id="2026-06-05---remove-synthetic-live-sync-test-harness"></a>
[2026-06-05 - Remove synthetic live-sync test harness](WORKLOG-2026-10-13.md#2026-06-05---remove-synthetic-live-sync-test-harness)

<a id="2026-06-02---140-stable-public-release"></a>
[2026-06-02 - 1.4.0 stable public release](WORKLOG-2026-10-13.md#2026-06-02---140-stable-public-release)

<a id="2026-06-02---140-beta1-signed-release-and-resilience-closeout"></a>
[2026-06-02 - 1.4.0-beta.1 signed release and resilience closeout](WORKLOG-2026-10-13.md#2026-06-02---140-beta1-signed-release-and-resilience-closeout)

<a id="2026-06-01---140-beta1-keychain-prompt-storm-elimination--premium-marketing-site"></a>
[2026-06-01 - 1.4.0-beta.1 (Keychain Prompt Storm Elimination & Premium Marketing Site)](WORKLOG-2026-10-13.md#2026-06-01---140-beta1-keychain-prompt-storm-elimination--premium-marketing-site)

<a id="2026-05-21---132-sync-attention-release"></a>
[2026-05-21 - 1.3.2 sync attention release](WORKLOG-2026-10-13.md#2026-05-21---132-sync-attention-release)

<a id="2026-05-20---131-sync-reliability-release"></a>
[2026-05-20 - 1.3.1 sync reliability release](WORKLOG-2026-10-13.md#2026-05-20---131-sync-reliability-release)

<a id="2026-05-19---130-stable-release"></a>
[2026-05-19 - 1.3.0 stable release](WORKLOG-2026-10-13.md#2026-05-19---130-stable-release)

<a id="2026-05-18---130-beta3-final-beta"></a>
[2026-05-18 - 1.3.0-beta.3 final beta](WORKLOG-2026-10-13.md#2026-05-18---130-beta3-final-beta)

<a id="2026-05-18---130-beta2-beautify-filenames--finder-right-click-expansion"></a>
[2026-05-18 - 1.3.0-beta.2 (Beautify Filenames + Finder right-click expansion)](WORKLOG-2026-10-13.md#2026-05-18---130-beta2-beautify-filenames--finder-right-click-expansion)

<a id="2026-05-18---130-beta1-the-carry-forward-beta"></a>
[2026-05-18 - 1.3.0-beta.1 (the carry-forward beta)](WORKLOG-2026-10-13.md#2026-05-18---130-beta1-the-carry-forward-beta)

<a id="2026-05-18---121-polish-patch-open-folder-in-image-relay-web"></a>
[2026-05-18 - 1.2.1 polish patch (Open Folder in Image Relay Web)](WORKLOG-2026-10-13.md#2026-05-18---121-polish-patch-open-folder-in-image-relay-web)

<a id="2026-05-17---120-stable-release-shipped"></a>
[2026-05-17 - 1.2.0 stable release shipped](WORKLOG-2026-10-13.md#2026-05-17---120-stable-release-shipped)

<a id="2026-05-15---120-beta4-copy-public-link-beta"></a>
[2026-05-15 - 1.2.0-beta.4 Copy Public Link beta](WORKLOG-2026-10-13.md#2026-05-15---120-beta4-copy-public-link-beta)

<a id="2026-05-15---120-beta3-finder-native-file-provider-beta"></a>
[2026-05-15 - 1.2.0-beta.3 Finder-native File Provider beta](WORKLOG-2026-10-13.md#2026-05-15---120-beta3-finder-native-file-provider-beta)

<a id="2026-05-14---120-beta2-sync-confidence-beta-shipped"></a>
[2026-05-14 - 1.2.0-beta.2 sync confidence beta shipped](WORKLOG-2026-10-13.md#2026-05-14---120-beta2-sync-confidence-beta-shipped)

<a id="2026-05-14---120-beta1-operational-controls-beta-shipped"></a>
[2026-05-14 - 1.2.0-beta.1 operational controls beta shipped](WORKLOG-2026-10-13.md#2026-05-14---120-beta1-operational-controls-beta-shipped)

<a id="2026-05-14---112-resilience-release-shipped"></a>
[2026-05-14 - 1.1.2 resilience release shipped](WORKLOG-2026-10-13.md#2026-05-14---112-resilience-release-shipped)

<a id="2026-05-13---429-storm-incident-multi-stage-autonomous-recovery-21-resilience-issues-filed"></a>
[2026-05-13 - 429 storm incident, multi-stage autonomous recovery, 21 resilience issues filed](WORKLOG-2026-10-13.md#2026-05-13---429-storm-incident-multi-stage-autonomous-recovery-21-resilience-issues-filed)

<a id="2026-05-13---110-stable-release-shipped"></a>
[2026-05-13 - 1.1.0 stable release shipped](WORKLOG-2026-10-13.md#2026-05-13---110-stable-release-shipped)

<a id="2026-05-12---110-stable-release-preparation"></a>
[2026-05-12 - 1.1.0 stable release preparation](WORKLOG-2026-10-13.md#2026-05-12---110-stable-release-preparation)

<a id="2026-05-12---110-beta9-explicit-on-demand-contentpolicy-on-fileprovideritem"></a>
[2026-05-12 - 1.1.0-beta.9: explicit on-demand `contentPolicy` on FileProviderItem](WORKLOG-2026-10-13.md#2026-05-12---110-beta9-explicit-on-demand-contentpolicy-on-fileprovideritem)

<a id="2026-05-12---110-beta8-accept-root-as-root-folder-id"></a>
[2026-05-12 - 1.1.0-beta.8: accept "root" as Root Folder ID](WORKLOG-2026-10-13.md#2026-05-12---110-beta8-accept-root-as-root-folder-id)

<a id="2026-05-12---110-beta7-live-api-reconciliation-4-ship-blockers-fixed"></a>
[2026-05-12 - 1.1.0-beta.7: live-API reconciliation (4 ship blockers fixed)](WORKLOG-2026-10-13.md#2026-05-12---110-beta7-live-api-reconciliation-4-ship-blockers-fixed)

<a id="2026-05-11---110-beta6-api-extensions--sync-data-loss-protection--fileprovider-tests"></a>
[2026-05-11 - 1.1.0-beta.6: API extensions + sync data-loss protection + FileProvider tests](WORKLOG-2026-10-13.md#2026-05-11---110-beta6-api-extensions--sync-data-loss-protection--fileprovider-tests)

<a id="2026-05-11---pagination-correctness-collections-data-loss-fix--ui-services-sweep"></a>
[2026-05-11 - Pagination correctness: Collections data-loss fix + UI services sweep](WORKLOG-2026-10-13.md#2026-05-11---pagination-correctness-collections-data-loss-fix--ui-services-sweep)

<a id="2026-05-11---110-beta5-metadata-polish--library-admin-crud--homebrew"></a>
[2026-05-11 - 1.1.0-beta.5: metadata polish + Library Admin CRUD + Homebrew](WORKLOG-2026-10-13.md#2026-05-11---110-beta5-metadata-polish--library-admin-crud--homebrew)

<a id="2026-05-09---ios-port-scaffold-imagerelayclientios--fileproviderextensionios"></a>
[2026-05-09 - iOS port scaffold: ImageRelayClientiOS + FileProviderExtensioniOS](WORKLOG-2026-10-13.md#2026-05-09---ios-port-scaffold-imagerelayclientios--fileproviderextensionios)

<a id="2026-05-09---110-beta4-live-api-coverage-pass--beta-release-candidate"></a>
[2026-05-09 - 1.1.0-beta.4: live API coverage pass + beta release candidate](WORKLOG-2026-10-13.md#2026-05-09---110-beta4-live-api-coverage-pass--beta-release-candidate)

<a id="2026-05-08---110-beta3-phase-3-collections--phase-4-products--phase-5-webhooks-admin"></a>
[2026-05-08 - 1.1.0-beta.3: Phase 3 (Collections) + Phase 4 (Products) + Phase 5 (Webhooks admin)](WORKLOG-2026-10-13.md#2026-05-08---110-beta3-phase-3-collections--phase-4-products--phase-5-webhooks-admin)

<a id="2026-05-08---110-beta2-phase-1-polish-custom-fields--nsopenpanel-fallback--phase-2-upload-links"></a>
[2026-05-08 - 1.1.0-beta.2: Phase 1 polish (custom fields + NSOpenPanel fallback) + Phase 2 (Upload Links)](WORKLOG-2026-10-13.md#2026-05-08---110-beta2-phase-1-polish-custom-fields--nsopenpanel-fallback--phase-2-upload-links)

<a id="2026-05-08---110-beta1-metadata-editing-with-finder-aware-sheet-phase-1"></a>
[2026-05-08 - 1.1.0-beta.1: metadata editing with Finder-aware sheet (Phase 1)](WORKLOG-2026-10-13.md#2026-05-08---110-beta1-metadata-editing-with-finder-aware-sheet-phase-1)

<a id="2026-05-08---101-public-release-repo-consolidation--liquid-glass-icon"></a>
[2026-05-08 - 1.0.1 public release: repo consolidation + Liquid Glass icon](WORKLOG-2026-10-13.md#2026-05-08---101-public-release-repo-consolidation--liquid-glass-icon)

<a id="2026-05-08---101-release-prep-repo-consolidation--liquid-glass-icon"></a>
[2026-05-08 - 1.0.1 release prep: repo consolidation + Liquid Glass icon](WORKLOG-2026-10-13.md#2026-05-08---101-release-prep-repo-consolidation--liquid-glass-icon)

<a id="2026-05-08---100-public-release"></a>
[2026-05-08 - 1.0.0 public release](WORKLOG-2026-10-13.md#2026-05-08---100-public-release)

<a id="2026-05-07---beta-13-immediate-local-mutation-refresh"></a>
[2026-05-07 - Beta 13: immediate local mutation refresh](WORKLOG-2026-10-13.md#2026-05-07---beta-13-immediate-local-mutation-refresh)

<a id="2026-05-05---beta-12-release-readiness-review-and-testable-beta-pipeline"></a>
[2026-05-05 - Beta 12: release readiness review and testable beta pipeline](WORKLOG-2026-10-13.md#2026-05-05---beta-12-release-readiness-review-and-testable-beta-pipeline)

<a id="2026-05-05---beta-11-two-way-delete-sync-and-stale-file-provider-cache-recovery"></a>
[2026-05-05 - Beta 11: two-way delete sync and stale File Provider cache recovery](WORKLOG-2026-10-13.md#2026-05-05---beta-11-two-way-delete-sync-and-stale-file-provider-cache-recovery)

<a id="2026-05-05---beta-10-settings-crash-on-open"></a>
[2026-05-05 - Beta 10: Settings crash on open](WORKLOG-2026-10-13.md#2026-05-05---beta-10-settings-crash-on-open)

<a id="2026-05-05---beta-9-scale-up-the-sidebar-sf-symbol"></a>
[2026-05-05 - Beta 9: scale up the sidebar SF Symbol](WORKLOG-2026-10-13.md#2026-05-05---beta-9-scale-up-the-sidebar-sf-symbol)

<a id="2026-05-05---beta-8-corrected-sidebar-icon-infoplist-nesting"></a>
[2026-05-05 - Beta 8: corrected sidebar-icon Info.plist nesting](WORKLOG-2026-10-13.md#2026-05-05---beta-8-corrected-sidebar-icon-infoplist-nesting)

<a id="2026-05-05---beta-7-custom-sf-symbol-sidebar-icon-error-message-ux"></a>
[2026-05-05 - Beta 7: custom SF Symbol sidebar icon, error-message UX](WORKLOG-2026-10-13.md#2026-05-05---beta-7-custom-sf-symbol-sidebar-icon-error-message-ux)

<a id="2026-05-04---beta-6-remote-deletion-propagation-sidebar-icon"></a>
[2026-05-04 - Beta 6: remote deletion propagation, sidebar icon](WORKLOG-2026-10-13.md#2026-05-04---beta-6-remote-deletion-propagation-sidebar-icon)

<a id="2026-05-04---beta-5-watchdog-poll-loop-parallel-folder-discovery"></a>
[2026-05-04 - Beta 5: watchdog poll loop, parallel folder discovery](WORKLOG-2026-10-13.md#2026-05-04---beta-5-watchdog-poll-loop-parallel-folder-discovery)

<a id="2026-05-01---simplify-pass-crash-fix-persistent-db-shared-helpers"></a>
[2026-05-01 - Simplify pass: crash fix, persistent DB, shared helpers](WORKLOG-2026-10-13.md#2026-05-01---simplify-pass-crash-fix-persistent-db-shared-helpers)

<a id="2026-04-30---local-beta-wipe-and-repo-purge"></a>
[2026-04-30 - Local beta wipe and repo purge](WORKLOG-2026-10-13.md#2026-04-30---local-beta-wipe-and-repo-purge)

<a id="2026-04-30---developer-id-release-workflow-fixed-for-beta-2"></a>
[2026-04-30 - Developer ID release workflow fixed for Beta 2](WORKLOG-2026-10-13.md#2026-04-30---developer-id-release-workflow-fixed-for-beta-2)

<a id="2026-05-07---beta-14-public-release-hardening"></a>
[2026-05-07 - Beta 14 public-release hardening](WORKLOG-2026-10-13.md#2026-05-07---beta-14-public-release-hardening)

<a id="2026-04-29---beta-continuation-after-100-beta-1"></a>
[2026-04-29 - Beta continuation after 1.0.0 BETA 1](WORKLOG-2026-10-13.md#2026-04-29---beta-continuation-after-100-beta-1)

<a id="2026-04-29---100-beta-1-release"></a>
[2026-04-29 - 1.0.0 BETA 1 release](WORKLOG-2026-10-13.md#2026-04-29---100-beta-1-release)

<a id="2026-04-07----python-removal-sync-gap-implementations-merged-to-main"></a>
[2026-04-07 -- Python removal, sync gap implementations, merged to main](WORKLOG-2026-10-13.md#2026-04-07----python-removal-sync-gap-implementations-merged-to-main)

<a id="2026-04-06----native-macos-rebuild-complete-file-provider-app-with-swiftui"></a>
[2026-04-06 -- Native macOS rebuild: complete File Provider app with SwiftUI](WORKLOG-2026-10-13.md#2026-04-06----native-macos-rebuild-complete-file-provider-app-with-swiftui)

<a id="2026-04-06----selective-folder-sync-recursive-file-fix-gui-folder-picker"></a>
[2026-04-06 -- Selective folder sync, recursive file fix, GUI folder picker](WORKLOG-2026-10-13.md#2026-04-06----selective-folder-sync-recursive-file-fix-gui-folder-picker)

</details>
