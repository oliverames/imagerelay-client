# Image Relay Webhook Relay Worker

Bridges Image Relay webhook deliveries to the macOS client's change polling
so the app learns about remote changes from pushes instead of re-listing
folders against the rate-limited Image Relay API.

```text
Image Relay ──POST /webhook──▶ Worker (Durable Object queue)
                                   ▲
macOS app ──GET /poll (15s) ───────┘   zero Image Relay API cost
```

## Endpoints

| Endpoint | Method | Auth | Purpose |
|----------|--------|------|---------|
| `/webhook?token=…` | POST | `RELAY_TOKEN` | Image Relay webhook deliveries. Payloads are mapped leniently to `{id, resource, action, folder_id, file_id}`; unparseable bodies still record a bare change event. |
| `/poll?token=…&cursor=…&timeout=…` | GET | `RELAY_TOKEN` | The app's cursor poll (see `ImageRelayClient/WebhookRelayClient.swift`). Returns `{"events": [...], "next_cursor": "…"}`. A poll without a cursor returns no events plus the current tip, so fresh clients never replay the backlog. |
| `/health` | GET | none | Liveness probe. |

Events are kept in a single Durable Object: capped at 500 events and 24
hours. The cursor is a monotonically increasing sequence number.

## Deploy

```bash
cd Cloudflare/imagerelay-webhook-relay
wrangler deploy
# First deploy only: set the shared token (1Password Development vault,
# item "Image Relay Webhook Relay Token")
wrangler secret put RELAY_TOKEN
```

Production URL: `https://imagerelay-webhooks.amesvt.com`

## Wiring

1. **Image Relay subscription** (the only server-side artifact — keep it
   singular and clearly named): list `GET /webhooks.json` first and update
   the existing subscription if present; otherwise create one named
   `Finder client change relay — managed by imagerelay-client (Oliver Ames)`
   pointing at `https://imagerelay-webhooks.amesvt.com/webhook?token=…`.
   Deleting this subscription is part of decommissioning the relay.
2. **App config**: set `webhook_relay_url` in the app group `config.json`
   to `https://imagerelay-webhooks.amesvt.com/poll?token=…`. The host app
   polls it every `webhook_relay_interval_seconds` (default 15s) and the
   File Provider extension drops to a 300s safety poll.

## Verification policy

Never create test files/folders/assets on the live Image Relay account to
verify delivery. Verify with real organic activity only (e.g., one real
metadata edit in the web UI) and watch for the host-app log line
`Webhook relay reported N change event(s)`.
