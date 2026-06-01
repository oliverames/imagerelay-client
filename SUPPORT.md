# Support

Use GitHub Issues for bugs, feature requests, and release questions:

https://github.com/oliverames/imagerelay-client/issues

## What To Include

- macOS version
- Image Relay Client version and build number
- Whether the app was installed from the signed DMG
- The folder ID or folder name being tested, without private API keys
- A short description of what changed in Finder and what happened in Image Relay
- A diagnostics export when reporting sync, settings, or File Provider behavior

## Export Diagnostics

Open **Image Relay > Settings > Advanced > Export Diagnostics**.

The export includes app version, macOS version, sanitized configuration, recent activity, unresolved sync failures, webhook relay state, sync progress, File Provider domain status, crash-report summaries, and recent Image Relay logs. API keys and full relay URLs are not exported.

For command-line support, this launch argument writes a diagnostics folder and prints its path:

```sh
open -a "Image Relay" --args --export-diagnostics
```

## Before Filing

- Confirm you are running the latest release from the public release page:
  https://github.com/oliverames/imagerelay-client/releases/latest
- Try **Settings > Advanced > Reset Finder Sync** if the Finder location is missing or stale.
- Use **Check for Updates** from the menu bar item before reporting an issue that may already be fixed.
