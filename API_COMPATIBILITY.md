# Image Relay API Compatibility

This document compares the documented Image Relay API surface with the parts this client
currently uses or intentionally leaves out.

## Fully Supported

- `GET /folders/{id}/children`
  Used for remote folder discovery and polling-based change detection.
- `GET /folders/{id}`
  Used as a direct confirmation fallback when child-folder listings lag after create,
  rename, or move operations.
- `GET /folders/root.json`
  Used during init when the sync root is auto-detected.
- `POST /folders/{id}/children`
  Used for local folder creation mirrored upstream.
- `PUT /folders/{id}.json`
  Used for in-place folder renames and folder moves through `parent_id`.
- `DELETE /folder/{id}`
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
  Implemented through polling the folder and file listing endpoints, with optional webhook
  relay polling in the host app for faster Finder refresh. The relay remains optional because
  a desktop app cannot reliably receive direct public webhook POSTs behind NAT.

## Additional Implemented Surfaces

- File metadata editing
  `GET /files/{id}.json` returns description, keyword list, and any custom file-type fields;
  `PUT /files/{id}.json` updates them. Used by the metadata editor window. Custom file-type
  fields are sent as text values; the server validates per-type and may reject malformed input.
- Upload links
  `GET /upload_links.json` lists existing links, `POST /upload_links.json` creates a new
  link with purpose/folder/expiry/max-files/password, `DELETE /upload_links/{id}.json`
  revokes. The model decodes the live `uid` and `upload_link_url` aliases. Used by the
  Upload Links Settings tab.
- Collections
  `GET /collections.json` lists collections, `POST /collections.json` creates one,
  `DELETE /collections/{id}.json` deletes it, `GET /collections/{id}/files.json` lists
  members, and `PUT /collections/{id}.json` appends to membership with comma-separated
  `asset_ids`. The PUT endpoint uses **delta-add** semantics on the live v2 API:
  IDs in the body are appended, IDs already present become no-ops, and omitted IDs are
  NOT removed. Used by the Collections browser window.
- Products (read-only)
  `GET /products.json` lists products when the account has product-catalog API access. Used by
  the Products browser window, with a specific entitlement message for 401/403 product responses.
- Webhook administration
  `GET /webhooks.json`, `GET /webhooks/supported.json`, `POST /webhooks.json`,
  `DELETE /webhooks/{id}.json`. The create body uses the live `resource`/`action` contract.
  Used by the Webhooks admin window. Some accounts require an admin-tier API key for these
  endpoints; the UI surfaces permission responses with a recovery hint.
- API directory (read-only)
  `GET /file_types.json`, `GET /keyword_sets.json`, `GET /keyword_sets/{id}/keywords.json`,
  `GET /users/me`, `GET /users.json`, `GET /folder_links.json`, `GET /quick_links.json`,
  `GET /permissions.json`, `GET /invited_users.json`, and `GET /webhooks/supported.json` are
  available from the API Directory window. Section-level errors are isolated so one
  permission-gated endpoint does not hide the rest of the directory. Permission groups live
  at `/permissions.json` (NOT `/permission_groups.json`, which 404s on the live API).

- Library administration writes
  `POST /keyword_sets.json` + `DELETE`, `POST /keyword_sets/{id}/keywords.json` + `PUT`
  (rename) + `DELETE`, `POST /folder_links.json` + `DELETE`, `POST /invited_users.json` +
  `DELETE`, `POST /users.json` (invite), `DELETE /users/{id}.json`, and
  `PUT /users/{id}/permission_group.json`. Used by the Library Admin window.

- User search
  `GET /users/search.json?q={query}`. The live v2 API filters with `?q=` only; the
  documented `?first_name=`, `?last_name=`, and `?email=` parameters are silently ignored
  and return the full user list.
- OAuth-based auth flows
  Settings supports an Image Relay Developer-app OAuth flow with tenant, client ID, client
  secret, redirect URI, browser authorization, callback handling, token exchange, coordinated
  refresh, and Keychain-backed token storage. API keys remain the simpler default path.
- Webhook relay consumption
  Settings > Advanced accepts an HTTPS relay URL. The host app polls that relay for Image
  Relay webhook cursors, records the cursor in the shared database, and signals File Provider
  enumerators when events arrive. The File Provider extension keeps a slower safety poll.

## Not Yet Implemented

- Collection item removal
  The Image Relay v2 API has no working endpoint for removing an individual file from a
  collection. Probed paths (`DELETE /collections/{id}/files/{file_id}.json`,
  `DELETE /collections/{id}/files.json`, `PATCH`/`PUT` variants) all return 404, and
  `PUT /collections/{id}.json` is delta-add (omitting IDs does NOT drop them). Users must
  remove items from the web app, or delete and recreate the collection. Tracked as a
  request to Image Relay support.
- Synced files / multi-folder asset memberships
  See "Partially Supported" below — multi-folder downloads work, but creating new
  multi-folder memberships through the dedicated synced-file API doesn't.
- Upload by URL
- Duplicate file and public sharing link write management
- Catalog endpoints beyond product list

## Important Edge-Case Decisions

- Finder folder create maps to `POST /folders/{parent_id}/children`. Before creating, and
  again after a 409/422 create response, the client checks `GET /folders/{parent_id}/children`
  for an existing same-name folder so File Provider retries attach to the already-created
  remote folder instead of looping forever. Confirmation accepts either the child listing or
  direct `GET /folders/{id}` detail before updating local tracking. Folder create and update
  names are normalized before sending to Image Relay because the live folder API rejects
  `/`, `&`, `<`, and `>` in folder names. For example, a local `RAWs & XMPs` folder is written
  remotely as `RAWs and XMPs` and treated as the same folder during confirmation.
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
