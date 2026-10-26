# Privacy

Image Relay Client is a local macOS sync app. It talks to Image Relay's API and stores the minimum local state needed for Finder sync. Apart from optional crash reports, described below, it sends nothing to the developer.

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
- Sentry (`*.ingest.us.sentry.io`) for crash and error reports, unless you turn them off

## Crash and Error Reports

Release builds of the macOS app and its File Provider extension send crash reports and unexpected sync error codes to the developer through [Sentry](https://sentry.io), so crashes can be found and fixed. Reporting is on by default. Turn it off in Settings > Advanced > Privacy > Share Crash Reports; the setting covers the app and the extension. Builds made from source have reporting off unless the developer adds the Sentry key at build time.

A report contains:

- For a crash: the exception type, and each thread's stack of function names and code addresses, with file paths reduced to a file name or a location inside the app or macOS.
- For an unexpected sync error: a fixed description such as "Unexpected sync error", the error's domain and number, and an HTTP status code when Image Relay returned one. Error messages are never sent, because they can name a file or folder. At most one report of each kind is sent an hour, and none for offline, cancelled, or permission-denied requests.
- The app version and build, the macOS version, and the Mac's model, architecture, and memory and storage sizes.

A report never contains your API key or OAuth tokens; your Image Relay account or library name; asset, file, folder, or collection names; metadata, keywords, or links; file paths in the synced folder or anywhere else; your Mac's name or your account name; your location, time zone, or language; or your IP address. Sentry sends no usage analytics, sessions, performance traces, screenshots, or network requests, and the Sentry project discards IP addresses and user and location data on arrival.

Reports are cleaned twice before they leave your Mac: the app keeps only the allowlisted fields above, then removes anything in the remaining text that looks like a quoted name, an email address, a web address, a file path, an identifier, or a token.

## Diagnostics

Diagnostics exports are created only when you ask for one, and stay on your Mac until you share them. They are separate from the crash reports above. Diagnostics can include:

- App version and build
- macOS version and hardware model
- Sanitized configuration
- Recent sync activity and progress
- File Provider domain status
- Recent Image Relay app logs
- Crash-report summaries for Image Relay components, read from the Mac's local crash logs

Diagnostics do not include API keys. Review the exported folder before attaching it to a public issue if folder names, filenames, or local paths are sensitive.
