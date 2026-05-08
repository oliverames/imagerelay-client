# Privacy

Image Relay Client is a local macOS sync app. It talks to Image Relay's API and stores the minimum local state needed for Finder sync.

## Credentials

- Your Image Relay API key is stored in the macOS Keychain.
- The API key is not written to `config.json`.
- Diagnostics exports redact credential presence and never include the API key value.

## Local State

The app and File Provider extension share an App Group container for non-secret sync state:

- Selected folder IDs and sync settings
- SQLite tracking data for files, folders, activity, sync progress, pause state, and sync anchors
- Sanitized diagnostics exports when you explicitly create them

## Network Access

The app contacts:

- `https://api.imagerelay.com/api/v2` for folder listings, downloads, uploads, deletes, moves, and version updates
- GitHub Releases for Sparkle update appcasts and DMG downloads
- Temporary Image Relay quick-link URLs when a file is opened from Finder

## Diagnostics

Diagnostics can include:

- App version and build
- macOS version and hardware model
- Sanitized configuration
- Recent sync activity and progress
- File Provider domain status
- Recent Image Relay app logs
- Crash-report summaries for Image Relay components

Diagnostics do not include API keys. Review the exported folder before attaching it to a public issue if folder names, filenames, or local paths are sensitive.
