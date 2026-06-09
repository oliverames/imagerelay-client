# Image Relay API Coverage Audit

Reviewed against the official Image Relay API documentation on 2026-06-01:

- API overview: https://image-relay-api.readme.io/reference/welcome-page
- Pagination: https://image-relay-api.readme.io/reference/pagination
- Full endpoint index: https://image-relay-api.readme.io/llms.txt

The low-level `APIClient` can call any JSON REST endpoint through `get`, `post`,
`put`, `delete`, `upload`, and `uploadChunked`. `ImageRelayAPI` adds typed
coverage for API areas that are not yet full app workflows. The table below
distinguishes typed client coverage from UI exposure where that matters.

## Foundations

| Area | Coverage | Notes |
| --- | --- | --- |
| Authentication | Covered | API key and OAuth credentials are supported through `AuthCredential`, `APIClient`, and `OAuthClient`. |
| Required User-Agent | Covered | Every `APIClient` request sets `User-Agent`; current defaults migrate old app versions in `AppConfiguration`. |
| Pagination | Covered | `getAllPages` supports body pagination objects, Link headers, wrapped arrays, page-size heuristics, and infinite-loop protection. |
| Rate limit | Covered | Shared host + File Provider limiter enforces the documented 5 requests/second/IP budget. 429 and 502/503 retry paths back off. |
| CDN / quick-link downloads | Covered | Presigned quick-link and thumbnail URLs bypass the API limiter intentionally because they do not hit the Image Relay API bucket. |

## DAM API

| Official area | App coverage | Notes |
| --- | --- | --- |
| Files: list and get | Covered | Finder enumeration and metadata editor use `/folders/{id}/files.json` and `/files/{id}.json`. |
| Upload file from URL | Typed | `ImageRelayAPI.uploadFileFromURL` covers `POST /files`. Not exposed in Finder; Finder uploads still use chunked upload jobs from local file data. |
| File metadata terms | Covered | Metadata editor updates `/files/{id}.json`; `ImageRelayAPI.updateFileTerms` also covers the dedicated `/files/{file_id}/terms` endpoint. |
| File tags | Covered | Metadata editor updates keyword strings through file metadata; `ImageRelayAPI.updateFileTags` also covers the dedicated `/files/{file_id}/tags` add/remove endpoint. |
| Delete file | Covered | File Provider delete uses `/files/{id}.json`. |
| Move file | Covered | File Provider move uses `/files/{id}/move.json` with string folder IDs. |
| Synced file | Typed | `ImageRelayAPI.createSyncedFile` covers the documented endpoint. Not exposed in UI. |
| Duplicate file | Typed | `ImageRelayAPI.duplicateFile` uses the documented `/files/{file_id}/dupicate` spelling. Verify live before exposing because the docs contain this typo. |
| Update asset thumbnail | Typed | `ImageRelayAPI.updateAssetThumbnail` covers binary thumbnail upload with `filename` query support. Not exposed in UI. |
| Update version | Covered | Finder rename/modify completes new versions through documented chunked version endpoints. |
| Folders: list/get/root/create/update/delete | Covered | Finder enumeration, folder creation, rename/move, and delete cover these workflows. |
| File upload jobs | Covered | `POST /upload_jobs.json`, chunk upload, job status checks, and final asset confirmation are implemented. |
| Collections | Covered | List, detail via item list, create, update membership, delete, and Finder add-to-collection actions are implemented. |
| Folder links | Covered | List, create, delete, and single get are typed. |
| Quick links | Covered | List, create, delete, one-shot download links, and single get are typed. |
| Upload links | Covered | List, create, delete, cache, and single get are typed. |
| File types | Covered | List, create, update, delete, and single get are typed. |
| Invited users | Covered | List, create, delete, and single get are typed. |
| Keyword sets / keywords | Covered | List, create, update keyword, delete, keyword-set get, and keyword get are typed. Keyword-set rename is not exposed in UI. |
| Permission groups | Covered | List and single get are typed. |
| Users | Covered | Current user, list, single get, search, create/invite, delete, and permission-group update are implemented. |
| User quick links | Typed | `ImageRelayAPI.userQuickLinks` covers `/users/{id}/quick_links`. Not shown in UI. |
| Create SSO user | Typed | `ImageRelayAPI.createSSOUser` covers `/users/sso_user` and sends the documented `role_id` request key. Not exposed because this affects identity provisioning. |
| Webhooks | Covered | List, supported actions, create, delete, single get, update state, and optional relay consumption are implemented. |

## Products API

The product directory UI currently remains read-only. The typed client now
covers the official Products API surface, with destructive actions kept out of
the visible app workflow until they are live-verified against the account.

| Official area | App coverage | Notes |
| --- | --- | --- |
| Products | Typed | List, get, create, update, and delete are typed. UI remains read-only. Product mutations use the documented `product_category_id`, `dimension1_*`, and `product_custom_attributes` body keys. |
| Product variants | Typed | List, get, create, PATCH update, and delete are typed. Variant mutations use the documented `variant_dimension_options` and `product_custom_attributes` body keys. |
| Channel template mappings | Typed | List by channel template ID is typed. |
| Catalogs and catalog products | Typed | Catalog list, get, create, update, delete, and catalog products are typed. |
| Templates | Typed | List, get, create, and update are typed. |
| Custom attributes | Typed | List, get, create, and update are typed. |
| Categories | Typed | List and get are typed. |
| Dimensions and options | Typed | Dimension list, get, create, update, and add-option are typed. |

## Rate-Limit Policy

Official documentation allows up to 5 requests/second from the same IP address
and asks clients to slow down on `429 Too Many Requests` and `502` heavy-load
responses.

Current policy:

- Use one app-group shared token bucket for the host app and File Provider
  extension at 5 requests/second.
- Keep user-configurable file operation concurrency for local workflows, but
  send every Image Relay API request through the shared limiter.
- Do not count CDN/S3 quick-link downloads or short-lived thumbnail URLs against
  the API bucket.
- On 429, coordinate backoff through the shared limiter so both processes slow
  down together.
- Recover in staged phases after 429s. One incidental 429 reduces throughput but
  does not force single-probe mode; repeated 429s converge to one in-flight
  cross-process recovery probe.
- Honor `Retry-After` when present. When missing, use a defensive cooldown so
  the client does not immediately re-trigger account-level throttling.

## Recommended Backlog

1. Live-verify typed-but-unexposed write paths before adding UI: product writes,
   SSO user creation, synced files, duplicate files, and thumbnail updates.
2. Decide which typed admin endpoints should become visible workflows versus
   staying as service coverage for future automation.
3. Keep product mutation payloads conservative until real account responses
   confirm required fields, validation rules, and the documented malformed
   variant/catalog paths for this workspace.
4. Re-check documented typo paths, especially `/files/{file_id}/dupicate`, before
   making user-facing actions depend on them.
