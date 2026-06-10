/**
 * Image Relay webhook relay.
 *
 * Bridges Image Relay webhook deliveries to the macOS client's cursor-based
 * change polling (ImageRelayClient/WebhookRelayClient.swift):
 *
 *   POST /webhook?token=…   Image Relay webhook deliveries land here.
 *   GET  /poll?token=…&cursor=…&timeout=…
 *                           The app polls for events after `cursor`.
 *                           Response: { "events": [...], "next_cursor": "…" }
 *   GET  /health            Unauthenticated liveness probe.
 *
 * Auth: every data endpoint requires the RELAY_TOKEN secret as a `token`
 * query parameter (the app embeds it in webhook_relay_url, which appends its
 * own cursor/timeout params). A first poll without a cursor returns no
 * events and the current tip as next_cursor — new clients never replay the
 * backlog.
 *
 * Storage: one Durable Object instance holds a monotonically increasing
 * sequence and the most recent events (capped by count and age). Image Relay
 * delivery payloads are mapped leniently to the shape the app decodes:
 * { id, resource, action, folder_id, file_id }.
 */

// Minimal ambient declarations for the Workers runtime — this project keeps
// workers dependency-free (no @cloudflare/workers-types package), matching
// imagerelay-oauth-callback. Wrangler's bundler strips types at deploy.
type DurableObjectId = unknown;
interface DurableObjectStub {
  fetch(request: Request): Promise<Response>;
}
interface DurableObjectNamespace {
  idFromName(name: string): DurableObjectId;
  get(id: DurableObjectId): DurableObjectStub;
}
interface DurableObjectListOptions {
  start?: string;
  prefix?: string;
  limit?: number;
}
interface DurableObjectStorage {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
  delete(keys: string[]): Promise<number>;
  list<T>(options?: DurableObjectListOptions): Promise<Map<string, T>>;
}
interface DurableObjectState {
  storage: DurableObjectStorage;
}
interface ExportedHandler<E> {
  fetch(request: Request, env: E): Promise<Response>;
}

export interface Env {
  RELAY: DurableObjectNamespace;
  RELAY_TOKEN: string;
}

const MAX_EVENTS = 500;
const MAX_EVENT_AGE_MS = 24 * 60 * 60 * 1000;
const SEQ_KEY = "seq";
const EVENT_KEY_PREFIX = "evt:";
const SEQ_PAD = 12;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return json({ ok: true });
    }

    if (url.pathname !== "/webhook" && url.pathname !== "/poll") {
      return new Response("Not Found", { status: 404, headers: noStore() });
    }

    if (!(await tokenMatches(url.searchParams.get("token"), env.RELAY_TOKEN))) {
      return new Response("Unauthorized", { status: 401, headers: noStore() });
    }

    if (url.pathname === "/webhook" && request.method !== "POST") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "POST", ...noStore() },
      });
    }
    if (url.pathname === "/poll" && request.method !== "GET") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "GET", ...noStore() },
      });
    }

    // Single relay instance: one user, one queue, strong consistency.
    const id = env.RELAY.idFromName("default");
    return env.RELAY.get(id).fetch(request);
  },
} satisfies ExportedHandler<Env>;

type RelayEvent = {
  id: string;
  resource: string | null;
  action: string | null;
  folder_id: number | null;
  file_id: number | null;
};

type StoredEvent = RelayEvent & { received_at: number };

export class WebhookRelay {
  private readonly storage: DurableObjectStorage;

  constructor(state: DurableObjectState) {
    this.storage = state.storage;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/webhook") {
      return this.ingest(request);
    }
    return this.poll(url);
  }

  private async ingest(request: Request): Promise<Response> {
    let payload: unknown = null;
    try {
      payload = await request.json();
    } catch {
      // Non-JSON delivery still counts as "something changed" — store a
      // bare event so the app re-enumerates rather than missing a change.
    }

    const event = extractEvent(payload);
    const seq = ((await this.storage.get<number>(SEQ_KEY)) ?? 0) + 1;
    const stored: StoredEvent = { ...event, received_at: Date.now() };
    await this.storage.put(SEQ_KEY, seq);
    await this.storage.put(eventKey(seq), stored);
    await this.prune(seq);

    return json({ ok: true, seq });
  }

  private async poll(url: URL): Promise<Response> {
    const tip = (await this.storage.get<number>(SEQ_KEY)) ?? 0;
    const cursor = parseCursor(url.searchParams.get("cursor"));

    // No cursor (fresh client) — hand back the tip without replaying the
    // backlog. The app stores next_cursor and sees only future events.
    if (cursor === null) {
      return json({ events: [], next_cursor: String(tip) });
    }

    const events: RelayEvent[] = [];
    if (cursor < tip) {
      const listed = await this.storage.list<StoredEvent>({
        start: eventKey(cursor + 1),
        prefix: EVENT_KEY_PREFIX,
        limit: 100,
      });
      for (const value of listed.values()) {
        const { received_at: _receivedAt, ...event } = value;
        events.push(event);
      }
    }

    // Cursors can outrun storage after pruning; tip is always authoritative.
    const nextCursor = Math.max(tip, cursor);
    return json({ events, next_cursor: String(nextCursor) });
  }

  private async prune(tip: number): Promise<void> {
    const oldestAllowedSeq = tip - MAX_EVENTS;
    const oldestAllowedTime = Date.now() - MAX_EVENT_AGE_MS;
    const listed = await this.storage.list<StoredEvent>({
      prefix: EVENT_KEY_PREFIX,
      limit: 200,
    });
    const staleKeys: string[] = [];
    for (const [key, value] of listed) {
      const seq = Number(key.slice(EVENT_KEY_PREFIX.length));
      if (seq <= oldestAllowedSeq || value.received_at < oldestAllowedTime) {
        staleKeys.push(key);
      }
    }
    if (staleKeys.length > 0) {
      await this.storage.delete(staleKeys);
    }
  }
}

function extractEvent(payload: unknown): RelayEvent {
  const root = isRecord(payload) ? payload : {};
  // Image Relay delivery shapes vary; look at the top level first, then one
  // level down under common envelope keys.
  const candidates: Record<string, unknown>[] = [root];
  for (const key of ["event", "data", "payload", "webhook"]) {
    const nested = root[key];
    if (isRecord(nested)) {
      candidates.push(nested);
    }
  }

  const pickString = (keys: string[]): string | null => {
    for (const candidate of candidates) {
      for (const key of keys) {
        const value = candidate[key];
        if (typeof value === "string" && value.length > 0) {
          return value;
        }
      }
    }
    return null;
  };
  const pickNumber = (keys: string[]): number | null => {
    for (const candidate of candidates) {
      for (const key of keys) {
        const value = candidate[key];
        if (typeof value === "number" && Number.isFinite(value)) {
          return value;
        }
        if (typeof value === "string" && /^\d+$/.test(value)) {
          return Number(value);
        }
      }
    }
    return null;
  };

  return {
    id: pickString(["id", "uid", "delivery_id", "event_id"]) ?? crypto.randomUUID(),
    resource: pickString(["resource", "resource_type", "type"]),
    action: pickString(["action", "event", "name"]),
    folder_id: pickNumber(["folder_id", "folderId", "parent_folder_id"]),
    file_id: pickNumber(["file_id", "fileId", "asset_id", "assetId"]),
  };
}

function eventKey(seq: number): string {
  return EVENT_KEY_PREFIX + String(seq).padStart(SEQ_PAD, "0");
}

function parseCursor(raw: string | null): number | null {
  if (raw === null || raw === "" || !/^\d+$/.test(raw)) {
    return null;
  }
  return Number(raw);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/// Compares SHA-256 digests so the comparison time doesn't depend on how
/// much of the token prefix matches.
async function tokenMatches(provided: string | null, expected: string | undefined): Promise<boolean> {
  if (!provided || !expected) {
    return false;
  }
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const left = new Uint8Array(a);
  const right = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < left.length; i++) {
    diff |= left[i] ^ right[i];
  }
  return diff === 0;
}

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json", ...noStore() },
  });
}

function noStore(): Record<string, string> {
  return {
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
  };
}
