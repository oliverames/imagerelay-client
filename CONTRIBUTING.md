# Contributing

Bug reports, focused fixes, and documentation improvements are welcome. Please open an issue before starting a large feature or architectural change so the scope can be agreed on first.

## Development setup

1. Install macOS 26, Xcode 26, and XcodeGen.
2. Run `xcodegen generate` from the repository root.
3. Run `xcodebuild test -project ImageRelayClient.xcodeproj -scheme ImageRelayClient -destination 'platform=macOS'`.

Crash reporting is off in local builds: `Config/Diagnostics.xcconfig` keeps the Sentry DSN empty in Git. `scripts/configure-diagnostics.py` writes the ignored `Config/Diagnostics.local.xcconfig` from 1Password without printing the value. A Debug build then reports only when launched with `-ImageRelayCrashReports YES`, and `-ImageRelaySentryTest message` (or `error`, `crash`) sends a fixed check and exits before the File Provider domain or the library is touched. `scripts/configure-diagnostics.py --remove` turns it off again.

Use a test Image Relay account and non-sensitive fixtures. Do not submit API keys, access tokens, account-specific folder IDs, customer assets, or diagnostics bundles that have not been reviewed for sensitive data.

## Pull requests

- Keep each pull request focused on one change.
- Add or update tests for behavior changes.
- Run the macOS scheme tests before submitting.
- Describe any manual testing, File Provider behavior, or platform limitation that reviewers should know about.
- Preserve existing accessibility labels and keyboard behavior when changing the interface.

By contributing, you agree that your contribution is licensed under the repository's MIT License.
