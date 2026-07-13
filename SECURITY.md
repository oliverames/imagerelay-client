# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository. Do not open a public issue for a suspected vulnerability or include API keys, OAuth credentials, access tokens, account-specific folder IDs, customer assets, or unredacted diagnostics in an issue.

Include the affected version, a concise reproduction, the security impact, and any suggested remediation. You should receive an acknowledgment within seven days.

## Supported versions

Security fixes are applied to the latest stable release. Users should update through the in-app updater or install the latest signed release from GitHub.

## Credential handling

The client stores credentials in the macOS Keychain. Diagnostics exports are designed to redact credentials, but reporters should still inspect an export before sharing it.
