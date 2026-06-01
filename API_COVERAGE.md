# Image Relay API Coverage Audit

Reviewed against the official Image Relay API documentation on 2026-06-01:

- API overview: https://image-relay-api.readme.io/reference/welcome-page
- Pagination: https://image-relay-api.readme.io/reference/pagination
- Full endpoint index: https://image-relay-api.readme.io/llms.txt

The low-level `APIClient` can call any JSON REST endpoint through `get`, `post`,
`put`, `delete`, `upload`, and `uploadChunked`. The table below tracks typed
models and app workflows, which is the meaningful coverage level for this app.

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
| Upload file from URL | Gap | Not exposed. Finder uploads use chunked upload jobs from local file data. |
| File metadata terms | Partial | Metadata editor updates `/files/{id}.json`. The documented `/files/{file_id}/terms` endpoint is not typed separately. |
| File tags | Partial | Metadata editor updates keyword strings through file metadata. The documented `/files/{file_id}/tags` add/remove endpoint is not typed separately. |
| Delete file | Covered | File Provider delete uses `/files/{id}.json`. |
| Move file | Covered | File Provider move uses `/files/{id}/move.json` with string folder IDs. |
| Synced file | Gap | Not exposed. Useful future action if users need one asset membership in multiple folders. |
| Duplicate file | Gap | Not exposed. The docs currently spell the path as `/files/{file_id}/dupicate`; verify live before implementing. |
| Update asset thumbnail | Gap | Not exposed. |
| Update version | Covered | Finder rename/modify completes new versions through documented chunked version endpoints. |
| Folders: list/get/root/create/update/delete | Covered | Finder enumeration, folder creation, rename/move, and delete cover these workflows. |
| File upload jobs | Covered | `POST /upload_jobs.json`, chunk upload, job status checks, and final asset confirmation are implemented. |
| Collections | Covered | List, detail via item list, create, update membership, delete, and Finder add-to-collection actions are implemented. |
| Folder links | Covered | List, create, and delete are implemented. Single get is not typed because the app does not need it. |
| Quick links | Covered | List, create, delete, and one-shot download links are implemented. Single get is not typed because the app does not need it. |
| Upload links | Covered | List, create, delete, and cache are implemented. Single get is not typed because the app does not need it. |
| File types | Covered | List, create, update, and delete are implemented. Single get is not typed because the app does not need it. |
| Invited users | Covered | List, create, and delete are implemented. Single get is not typed because the app does not need it. |
| Keyword sets / keywords | Covered | List, create, update keyword, and delete are implemented. Keyword-set rename is not exposed in UI. |
| Permission groups | Covered | List is implemented. Single get is not typed because the app does not need it. |
| Users | Covered | Current user, list, single get, search, create/invite, delete, and permission-group update are implemented. |
| User quick links | Gap | `/users/{id}/quick_links.json` is not typed or shown. |
| Create SSO user | Gap | Not exposed. Needs account-specific validation before adding because this affects identity provisioning. |
| Webhooks | Covered | List, supported actions, create, delete, and optional relay consumption are implemented. Update webhook state is not exposed. |

## Products API

The product directory currently gives read-only product list coverage. The
official Products API is much larger than the app surface today.

| Official area | App coverage | Notes |
| --- | --- | --- |
| Products | Partial | Product list and model decoding are implemented. Get/create/update/delete are not typed. |
| Product variants | Gap | Not typed. |
| Channel template mappings | Gap | Not typed. |
| Catalogs and catalog products | Gap | Not typed. |
| Templates | Gap | Not typed. |
| Custom attributes | Gap | Not typed. |
| Categories | Gap | Not typed. |
| Dimensions and options | Gap | Not typed. |

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

1. Add typed Products API support in this order: product detail, variants,
   catalogs, templates/custom attributes, dimensions/categories.
2. Add explicit file term/tag endpoints if live testing shows `/files/{id}.json`
   no longer covers all editable metadata cases.
3. Add webhook update-state support so users can enable/disable existing hooks
   without deleting them.
4. Verify `upload-file-from-url`, synced-file, duplicate-file, and thumbnail
   update paths live before exposing Finder or admin actions; several documented
   paths have typos or shapes that should not be trusted blindly.
