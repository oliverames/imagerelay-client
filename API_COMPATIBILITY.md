# Image Relay API Compatibility

This document compares the documented Image Relay API surface with the parts this client
currently uses or intentionally leaves out.

## Fully Supported

- `GET /folders/{id}/children`
  Used for remote folder discovery and polling-based change detection.
- `GET /folders/root.json`
  Used during init when the sync root is auto-detected.
- `POST /folders/{id}/children`
  Used for local folder creation mirrored upstream.
- `PUT /folders/{id}.json`
  Used for in-place folder renames and folder moves through `parent_id`.
- `DELETE /folders/{id}.json`
  Used for folder deletions mirrored upstream.
- `GET /folders/{id}/files.json`
  Used for recursive remote file polling.
- `DELETE /files/{id}.json`
  Used for remote deletes and rename cleanup.
- `POST /files/{id}/move.json`
  Used when a local file moves to a different tracked parent without a rename.
- `POST /upload_jobs.json`
  Used to create new asset uploads.
- `POST /upload_jobs/{id}/files/{id}/chunks/{chunk_number}`
  Used for chunked new-asset uploads.
- `GET /upload_jobs/{id}.json`
  Used to wait for upload-job completion.
- `POST /files/{id}/versions.json`
  Used to request a version-upload UUID.
- `POST /files/{id}/versions/{uuid}/chunk/{chunk_number}`
  Used for chunked version uploads.
- `POST /files/{id}/versions/{uuid}/complete.json`
  Used to finalize new versions. Passing a new `file_name` here also mirrors
  Finder file renames while preserving the remote file ID.
- `POST /quick_links.json`
  Used to create temporary download links.
- `DELETE /quick_links/{id}.json`
  Used to clean up download links after use.
- Pagination handling
  Supports both top-level `pagination` objects and `Link` header pagination styles.
- Rate limiting
  Enforces the documented `5 requests/second` limit per IP from within this client and
  retries `429`, `502`, and `503` responses with backoff.

## Partially Supported

- Synced files / multi-folder assets
  Remote multi-folder assets are mirrored as one canonical local file plus symlink aliases.
  The client does not create additional remote synced-file memberships through the dedicated
  synced-file API.
- Remote change detection
  Implemented through polling the folder and file listing endpoints. The client records the
  last successful pull and next scheduled pull, but it does not yet integrate webhooks.

## Implemented in 1.1 betas

- File metadata editing
  `GET /files/{id}.json` returns description, keyword list, and any custom file-type fields;
  `PUT /files/{id}.json` updates them. Used by the metadata editor window. Custom file-type
  fields are sent as text values; the server validates per-type and may reject malformed input.
- Upload links
  `GET /upload_links.json` lists existing links, `POST /upload_links.json` creates a new
  link with name/folder/expiry/max-files/password, `DELETE /upload_links/{id}.json` revokes.
  Used by the Upload Links Settings tab.
- Collections
  `GET /collections.json` lists collections, `GET /collections/{id}/items.json` lists members,
  `POST /collections/{id}/items.json` adds files, `DELETE /collections/{id}/items/{file_id}.json`
  removes files. Used by the Collections browser window.
- Products (read-only)
  `GET /products.json` lists products. Used by the Products browser window.
- Webhook administration
  `GET /webhooks.json`, `POST /webhooks.json`, `DELETE /webhooks/{id}.json`. Used by the
  Webhooks admin window. Some accounts require an admin-tier API key for these endpoints;
  the UI surfaces 403 responses with a recovery hint.

## Not Yet Implemented

- Webhook consumption
  The desktop client doesn't subscribe to webhook deliveries yet — that requires a public
  relay (NAT'd desktop can't host a webhook URL directly). Planned: a Cloudflare Worker
  receives Image Relay webhook POSTs, validates an HMAC signature, and pushes events to
  subscribed desktop clients via Server-Sent Events. Tracked as Phase 7 of 1.1.
- OAuth-based auth flows
  The client currently assumes API-key style access through configured credentials.
- File type / template administration
  `GET /file_types.json` and per-template field schemas not yet consumed; the metadata
  editor sends custom fields as text values without per-type validation.
- Keyword administration
  `GET /keywords.json` model is in place but the keyword autocomplete UI hookup ships in
  beta 4.
- User administration
  `GET /users.json` not consumed yet.
- Synced files / multi-folder asset memberships
  See "Partially Supported" below — multi-folder downloads work, but creating new
  multi-folder memberships through the dedicated synced-file API doesn't.
- Upload by URL
- Duplicate file, folder links, and public sharing link management
- Catalog endpoints beyond product list

## Important Edge-Case Decisions

- Finder folder create maps to `POST /folders/{parent_id}/children`, then waits for the
  new folder to appear in `GET /folders/{parent_id}/children` before updating local tracking.
  If confirmation times out, the client attempts to delete the newly-created remote folder
  and reports the operation as failed.
- Finder file create maps to upload jobs, then waits for `GET /folders/{id}/files.json`
  to report the expected size before updating local tracking. If confirmation times out,
  the client attempts to delete the newly-created remote file and reports the operation as
  failed.
- Finder file edits and file renames map to version uploads, then wait for the folder
  listing to report the expected size or filename before updating local tracking.
- Finder file moves map to `POST /files/{id}/move.json`, then wait for the file to
  disappear from the old folder listing and appear in the new folder listing before updating
  local tracking.
- Finder folder renames and moves map to `PUT /folders/{id}.json`, then wait for the
  destination parent listing to report the expected folder ID and name before updating local
  tracking.
- Finder deletes map to the file or folder delete endpoints. File deletes retry while the
  file remains visible; folder deletes wait for the parent listing to drop the folder before
  local subtree cleanup.
- Deleted remote files returned by the listing API are ignored instead of treated as active
  files.
- A transient API failure during daemon sync marks progress as failed, logs the exception,
  schedules a retry, and keeps the daemon alive.
- Friendly error messages are added for common `401`, `403`, `404`, `429`, `502`, and `503`
  cases so the CLI and menu bar do not surface raw API errors without guidance.
- The menu bar and CLI status surface approximate ETA and recent activity from shared SQLite
  state rather than trying to infer live transfer byte throughput.
