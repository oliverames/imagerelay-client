# Image Relay API Compatibility

This document compares the documented Image Relay API surface with the parts this client
currently uses or intentionally leaves out.

## Fully Supported

- `GET /folders.json`
  Used for remote folder discovery and polling-based change detection.
- `GET /folders/root.json`
  Used during init when the sync root is auto-detected.
- `POST /folders.json`
  Used for local folder creation mirrored upstream.
- `PUT /folders/{id}.json`
  Used for in-place folder renames under the same remote parent.
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
  Used to finalize new versions.
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
- Folder moves
  Renames within the same parent are supported. Moving a folder to a different remote parent
  is still not implemented because this codebase only relies on the documented update-folder
  path.

## Not Yet Implemented

- Webhooks
  The API supports webhooks, but this desktop client does not register or consume them yet.
- OAuth-based auth flows
  The client currently assumes API-key style access through configured credentials.
- Metadata editing, tag editing, and file-type/template management beyond a single default
  `file_type_id`
- Upload by URL
- Duplicate file, folder links, upload links, and public sharing link management
- User, collection, catalog, product, keyword, and webhook administration endpoints

## Important Edge-Case Decisions

- Deleted remote files returned by the listing API are ignored instead of treated as active
  files.
- A transient API failure during daemon sync marks progress as failed, logs the exception,
  schedules a retry, and keeps the daemon alive.
- Friendly error messages are added for common `401`, `403`, `404`, `429`, `502`, and `503`
  cases so the CLI and menu bar do not surface raw API errors without guidance.
- The menu bar and CLI status surface approximate ETA and recent activity from shared SQLite
  state rather than trying to infer live transfer byte throughput.
