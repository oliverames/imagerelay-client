# Image Relay Migration Review

Author: Oliver Ames
Date: October 6, 2026

Image Relay's fresh Mac/iOS source migration is prepared. Four app identifiers are registered. The iOS store record **Image Relay Client** is created and verified as `6819812564`, using `com.amesconsulting.imagerelay.ios`, SKU `imagerelay-ios-amesconsulting`, and English (U.S.). Shared-group access is approved, and the new group is registered. All four associations and profiles are verified. Both platforms have verified signed exports, version 1.4.4 (47).

## Prepared Boundaries

The app identifiers use `com.amesconsulting.imagerelay`, `.fileprovider`, `.ios`, and `.ios.fileprovider`. All four sources declare the registered group `group.com.amesconsulting.imagerelay`. Mac and iOS retain separate shared Keychain groups under team `84M4ZF255G`, and the classic credential service uses the new base identifier.

Both File Provider domains are new. The Mac domain manager and metadata editor agree on `com.amesconsulting.imagerelay.domain`. The iOS controller uses `com.amesconsulting.imagerelay.ios.domain`. Extension action and decoration identifiers match their generated metadata.

The existing callback scheme, callback endpoint, user-agent policy, logging labels, update-signing key and updater feed remain unchanged. Their preservation avoids an incidental service cutover during build preparation. Side-by-side callback routing remains unverified.

## Verified Preparation

- Regenerated the Xcode project and four entitlement files from the project specification.
- Static checks passed for all four group and Keychain declarations, both extension document-group fields and all three domain consumers.
- Release-script Bash syntax and shellcheck passed. The profile helper passed Python syntax checks. Neither release helper ran.
- Oliver waived further app test suites on October 6. Earlier proposed fixture-only guard edits were removed from the migration scope. No native Image Relay tests ran.

## Remaining Gates

Oliver explicitly approved group registration, all four app/extension associations and their profiles. Group `group.com.amesconsulting.imagerelay` is registered as `MJQ63K87AQ`. All four new app identifiers are assigned only to this group. Two Mac Developer ID and two iOS App Store profiles were decoded, verified, installed and stored in 1Password. The Mac profiles also include Apple's standard active-team wildcard, while the app entitlement files request only the named shared group.

The user-authorized dependency retry succeeded on October 6. The exact pinned GRDB.swift 6.29.3 revision was fetched without changing dependency pins or saved network settings. Earlier failed downloads are resolved.

The universal Mac Release archive and Developer ID export succeeded. The task's archive command explicitly applies the active team and manual signing to dependency resource bundles. The repository's existing full release wrapper was not executed. The iOS archive and App Store export also succeeded.

All four iOS app/extension checks across archive and IPA passed strict signatures, exact active certificate, assigned profiles, shared group and permitted entitlements. The IPA SHA-256 is `0b11b9ac398d039b28521a63943642e3468e0072d0683a675a4c826a995063ef`.

All seven code objects in the Mac export passed strict signatures in both architectures, using the exact active Developer ID certificate, hardened runtime and secure timestamps. App, File Provider, App Group, shared Keychain, document group and embedded profiles match the migration. The archive retains four ad hoc Sparkle helpers. Export re-signs them correctly, so distribution must use the verified export. Its bundle manifest SHA-256 is `456aced78dd94d23954a968aba9c47cd9351281b4ad677a7aea917735717ab4c`.

Further app test suites remain outside this migration task at Oliver's direction. Mac notarization was explicitly approved and submitted on October 6 as `4a725c94-e9e7-4624-be2b-1a4fd7ee40f3`. Apple validation is in progress.

Later runtime acceptance must deliberately select installation and callback routing, updater delivery and a synthetic test account/library. Existing domains, placeholders, pending uploads and remote files remain untouched. The release wrapper's smoke-install and domain-reset paths were not run.

Remaining work is tracked in [issue 38](https://github.com/oliverames/imagerelay-client/issues/38). The existing credential-rotation [issue 35](https://github.com/oliverames/imagerelay-client/issues/35) stays open until the active credential path is verified end to end. No app was installed or launched, and no live File Provider domain or Photos data was accessed.
