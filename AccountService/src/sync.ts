// Sync of non-secret settings (DESIGN.md §5):
//
//   GET  /v1/sync?since=<rev>  → {rev, changes: [item, … ≤ 500], more}
//   POST /v1/sync              {changes: [{collection, id, base_rev?, deleted?, body?}, … ≤ 100]}
//                              → {rev, applied: [{collection, id, rev}], conflicts: [{collection, id, server}]}
//
// An item is {collection, id, rev, updated_ms, deleted, body}. Every collection has an
// allowlist schema (SCHEMAS below): an unknown or malformed field, id or value is refused with
// 400 invalid_item, and the stored body is re-serialised from the validated fields alone, so
// nothing a client adds reaches the database. Secrets have no field to travel in.
//
// Order: every write takes the account's next revision (accounts.sync_rev), in the push's
// single D1 batch, so the last write to reach the server wins whatever the device clocks say.
// Settings are one item per key. A change with `base_rev` is written only while the item is
// still at that revision (0: no such item); otherwise it lands in conflicts[] with the server's
// copy. A change identical to the stored item is not written again and keeps its revision, and
// deleting an item the server never had (or already pruned) writes nothing.
//
// Deletes leave tombstones (deleted, no body). The hourly cron prunes tombstones older than 90
// days, and a push keeps the newest 2,000; either raises accounts.sync_floor to the highest
// pruned revision. A pull whose cursor is below that floor, or past the account's revision,
// answers 410 reset_required: the client pulls again from 0 and merges.
//
// Caps: 16 KB per item, 100 changes and 256 KB per push (413 too_large); per account 2,000
// live items, 1 MB of bodies and each collection's cap (403 quota). The account caps are
// CHECK constraints on counters that triggers keep (migrations/0003_sync.sql), so a push that
// would pass one rolls back whole, even when two devices push at once.
import { openAccountRequest } from "./auth";
import type { Env } from "./env";
import { errorResponse, isRecord, json, readJsonObject } from "./http";

export const MAX_SYNC_BODY_BYTES = 256 * 1024;
export const MAX_CHANGES = 100;
export const MAX_ITEM_BYTES = 16 * 1024;
export const PAGE_SIZE = 500;
export const MAX_TOMBSTONES = 2000;
export const TOMBSTONE_TTL_MS = 90 * 24 * 60 * 60 * 1000;
/** The same numbers as the CHECK constraints in migrations/0003_sync.sql, which enforce them. */
export const MAX_ACCOUNT_ITEMS = 2000;
export const MAX_ACCOUNT_BYTES = 1024 * 1024;
export const COLLECTION_CAPS = { hosts: 200, prompts: 500, settings: 300, agent_prefs: 1000, shares: 500 } as const;

export type Collection = keyof typeof COLLECTION_CAPS;
const COLLECTIONS = Object.keys(COLLECTION_CAPS) as Collection[];

// --- Field checks: each returns the value to store, or INVALID. -------------------------------

const INVALID = Symbol("invalid");
type Check = (value: unknown) => unknown;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const B64URL_16 = /^[A-Za-z0-9_-]{22}$/;
const B64URL_32 = /^[A-Za-z0-9_-]{43}$/;
/** Control characters, which no single-line field holds. */
const CONTROL = /\p{Cc}/u;
/** Control characters other than tab and line breaks, for multi-line text. */
const CONTROL_EXCEPT_LINES = /[^\P{Cc}\t\n\r]/u;

const utf8Length = (text: string): number => new TextEncoder().encode(text).byteLength;

interface TextRule {
  /** Unicode code points, or with `bytes` UTF-8 bytes. */
  max: number;
  bytes?: boolean;
  multiline?: boolean;
  required?: boolean;
  /** Refuses spaces too: host names and the like. */
  noSpace?: boolean;
}

function text(rule: TextRule): Check {
  return (value) => {
    if (typeof value !== "string" || !value.isWellFormed()) return INVALID;
    if ((rule.multiline ? CONTROL_EXCEPT_LINES : CONTROL).test(value)) return INVALID;
    if (rule.noSpace && /\s/u.test(value)) return INVALID;
    if (rule.required && value.length === 0) return INVALID;
    return (rule.bytes ? utf8Length(value) : Array.from(value).length) <= rule.max ? value : INVALID;
  };
}

function number(min: number, max: number, integer = false): Check {
  return (value) =>
    typeof value === "number" && Number.isFinite(value) && value >= min && value <= max && (!integer || Number.isInteger(value)) ? value : INVALID;
}

const ORDER = number(-Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER);
const bool: Check = (value) => (typeof value === "boolean" ? value : INVALID);
const oneOf =
  (...allowed: string[]): Check =>
  (value) =>
    typeof value === "string" && allowed.includes(value) ? value : INVALID;
const pattern =
  (re: RegExp): Check =>
  (value) =>
    typeof value === "string" && re.test(value) ? value : INVALID;

/**
 * A relay's base URL: http(s), no credentials, query or fragment, and no `/i` path segment,
 * so neither an invite link (whose secret rides in its path or fragment) nor anything else
 * secret fits in it.
 */
const relayUrl: Check = (value) => {
  if (typeof value !== "string" || value.length > 256 || /[\s?#@\\]/.test(value)) return INVALID;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return INVALID;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return INVALID;
  return url.pathname.split("/").includes("i") ? INVALID : value;
};

// --- Schemas -----------------------------------------------------------------------------------

interface Field {
  check: Check;
  required?: boolean;
}

interface Schema {
  /** The item ids this collection takes. */
  id: (id: string) => boolean;
  /** The allowlist, in the order the stored body lists them. */
  fields: Record<string, Field>;
  /** Checks across fields, after each passed its own; the name of the field at fault, or null. */
  cross?: (id: string, body: Record<string, unknown>) => string | null;
}

/** Synced settings: these keys only, each with its type and range. Device-shaped keys stay local. */
export const SETTINGS: Record<string, Check> = {
  "terminal.fontSize": number(6, 72),
  "guest.terminal.fontSize": number(6, 72),
  "chat.fontSize": number(6, 72),
  "ui.fontScale": number(0.5, 3),
  "ui.theme": oneOf("system", "light", "dark"),
  "guest.ownerName": text({ max: 64 }),
};
/** Notification switches: `notify.<name>`, each a boolean. */
const NOTIFY_KEY = /^notify\.[a-z][A-Za-z0-9]{0,47}$/;

const settingCheck = (key: string): Check | undefined => (Object.hasOwn(SETTINGS, key) ? SETTINGS[key] : NOTIFY_KEY.test(key) ? bool : undefined);

/** `<host item id>/<agent key>`: the host's UUID, then 1–128 code points without control characters. */
const AGENT_KEY = text({ max: 128, required: true });
function agentPrefId(id: string): boolean {
  const slash = id.indexOf("/");
  if (slash < 0 || !UUID.test(id.slice(0, slash))) return false;
  return AGENT_KEY(id.slice(slash + 1)) !== INVALID;
}

const shareIdParts = (id: string): [string, string] | null => {
  const parts = id.split("/");
  return parts.length === 2 && B64URL_16.test(parts[0]) && B64URL_16.test(parts[1]) ? [parts[0], parts[1]] : null;
};

export const SCHEMAS: Record<Collection, Schema> = {
  hosts: {
    id: (id) => UUID.test(id),
    fields: {
      nickname: { check: text({ max: 64 }) },
      host: { check: text({ max: 253, required: true, noSpace: true }), required: true },
      port: { check: number(1, 65535, true) },
      username: { check: text({ max: 64, required: true }), required: true },
      auth_kind: { check: oneOf("key", "password") },
      label: { check: text({ max: 64 }) },
    },
  },
  prompts: {
    id: (id) => UUID.test(id),
    fields: {
      title: { check: text({ max: 128 }) },
      text: { check: text({ max: 8192, bytes: true, multiline: true, required: true }), required: true },
      order: { check: ORDER },
    },
  },
  settings: {
    id: (id) => settingCheck(id) !== undefined,
    fields: { value: { check: (value) => value, required: true } },
    cross: (id, body) => (settingCheck(id)?.(body.value) === INVALID ? "value" : null),
  },
  agent_prefs: {
    id: agentPrefId,
    fields: {
      pinned: { check: bool },
      hidden: { check: bool },
      order: { check: ORDER },
    },
  },
  shares: {
    id: (id) => shareIdParts(id) !== null,
    fields: {
      relay: { check: relayUrl, required: true },
      host_id: { check: pattern(B64URL_16), required: true },
      node_pub: { check: pattern(B64URL_32), required: true },
      guest_id: { check: pattern(B64URL_16), required: true },
      agent_name: { check: text({ max: 128 }) },
      owner_name: { check: text({ max: 64 }) },
      machine_label: { check: text({ max: 128 }) },
      share_gram: { check: bool },
    },
    cross: (id, body) => {
      const [hostId, guestId] = shareIdParts(id) ?? ["", ""];
      return body.host_id !== hostId ? "host_id" : body.guest_id !== guestId ? "guest_id" : null;
    },
  },
};

// --- Changes -----------------------------------------------------------------------------------

export interface Change {
  collection: Collection;
  id: string;
  /** null: write whatever the item's revision. */
  baseRev: number | null;
  deleted: boolean;
  /** The re-serialised body; null for a delete. */
  body: string | null;
}

const CHANGE_KEYS: Record<string, true> = { collection: true, id: true, base_rev: true, deleted: true, body: true };
/** Revisions and cursors: non-negative integers D1 holds exactly. */
const isRev = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;

/** A body's JSON from its validated fields, in schema order, or the name of the field at fault. */
export function serialiseBody(collection: Collection, id: string, body: unknown): string | { field: string } {
  if (!isRecord(body)) return { field: "body" };
  const schema = SCHEMAS[collection];
  for (const key of Object.keys(body)) if (!Object.hasOwn(schema.fields, key)) return { field: key };
  const clean: Record<string, unknown> = {};
  for (const [name, field] of Object.entries(schema.fields)) {
    if (!Object.hasOwn(body, name)) {
      if (field.required) return { field: name };
      continue;
    }
    const value = field.check(body[name]);
    if (value === INVALID) return { field: name };
    clean[name] = value;
  }
  const fault = schema.cross?.(id, clean) ?? null;
  return fault === null ? JSON.stringify(clean) : { field: fault };
}

type ParsedChange = { change: Change } | { field: string } | { tooLarge: true };

export function parseChange(value: unknown): ParsedChange {
  if (!isRecord(value)) return { field: "change" };
  for (const key of Object.keys(value)) if (!Object.hasOwn(CHANGE_KEYS, key)) return { field: key };
  const { collection, id, base_rev, deleted = false, body } = value;
  if (typeof collection !== "string" || !(COLLECTIONS as string[]).includes(collection)) return { field: "collection" };
  const schema = SCHEMAS[collection as Collection];
  if (typeof id !== "string" || !schema.id(id)) return { field: "id" };
  if (base_rev !== undefined && !isRev(base_rev)) return { field: "base_rev" };
  if (typeof deleted !== "boolean") return { field: "deleted" };
  const change = { collection: collection as Collection, id, baseRev: isRev(base_rev) ? base_rev : null, deleted };
  if (deleted) return body === undefined || body === null ? { change: { ...change, body: null } } : { field: "body" };
  const serialised = serialiseBody(change.collection, id, body);
  if (typeof serialised !== "string") return serialised;
  return utf8Length(serialised) > MAX_ITEM_BYTES ? { tooLarge: true } : { change: { ...change, body: serialised } };
}

// --- Rows and items ------------------------------------------------------------------------------

interface ItemRow {
  collection: Collection;
  item_id: string;
  rev: number;
  updated_ms: number;
  deleted: number;
  body: string | null;
}

const ITEM_COLUMNS = "collection, item_id, rev, updated_ms, deleted, body";

const itemJson = (row: ItemRow) => ({
  collection: row.collection,
  id: row.item_id,
  rev: row.rev,
  updated_ms: row.updated_ms,
  deleted: row.deleted === 1,
  body: row.body === null ? null : (JSON.parse(row.body) as unknown),
});

const itemKey = (collection: string, id: string) => `${collection}\n${id}`;

// --- Endpoints -----------------------------------------------------------------------------------

export async function handlePull(request: Request, env: Env, nowMs: number): Promise<Response> {
  const principal = await openAccountRequest(request, env, "/v1/sync", nowMs);
  if (principal instanceof Response) return principal;
  const query = new URL(request.url).searchParams;
  const since = query.get("since") ?? "0";
  if ([...query.keys()].some((key) => key !== "since") || query.getAll("since").length > 1 || !/^(0|[1-9][0-9]{0,14})$/.test(since)) {
    return errorResponse(400, "bad_request");
  }
  const cursor = Number(since);
  // One batch is one transaction: the account's revision and the page agree.
  const [account, page] = await env.DB.batch<Record<string, unknown>>([
    env.DB.prepare("SELECT sync_rev, sync_floor FROM accounts WHERE id = ?").bind(principal.accountId),
    env.DB.prepare(`SELECT ${ITEM_COLUMNS} FROM sync_items WHERE account_id = ? AND rev > ? ORDER BY rev LIMIT ?`).bind(
      principal.accountId,
      cursor,
      PAGE_SIZE + 1,
    ),
  ]);
  const state = account.results[0] as { sync_rev: number; sync_floor: number } | undefined;
  if (state === undefined) return errorResponse(401, "invalid_token", { "WWW-Authenticate": "Bearer" });
  // A cursor below the floor may have missed a pruned delete; one past the account's revision
  // comes from another history (a restored database, an account deleted and made again).
  if (cursor > state.sync_rev || (cursor > 0 && cursor < state.sync_floor)) return errorResponse(410, "reset_required");
  const rows = page.results as unknown as ItemRow[];
  const more = rows.length > PAGE_SIZE;
  const changes = rows.slice(0, PAGE_SIZE);
  return json(200, { rev: more ? changes[changes.length - 1].rev : state.sync_rev, changes: changes.map(itemJson), more });
}

/**
 * The upsert of one change at the account's next revision, unless `base_rev` no longer matches,
 * nothing changes, or it deletes an item the server doesn't hold.
 */
const UPSERT = `INSERT INTO sync_items (account_id, collection, item_id, rev, updated_ms, deleted, body)
SELECT id, ?2, ?3, sync_rev + 1, ?4, ?5, ?6 FROM accounts
WHERE id = ?1
  AND (?7 IS NULL OR ?7 = COALESCE((SELECT rev FROM sync_items WHERE account_id = ?1 AND collection = ?2 AND item_id = ?3), 0))
  AND (?5 = 0 OR EXISTS (SELECT 1 FROM sync_items WHERE account_id = ?1 AND collection = ?2 AND item_id = ?3))
ON CONFLICT (account_id, collection, item_id) DO UPDATE SET
  rev = excluded.rev, updated_ms = excluded.updated_ms, deleted = excluded.deleted, body = excluded.body
WHERE sync_items.deleted <> excluded.deleted OR sync_items.body IS NOT excluded.body`;

/** Past MAX_TOMBSTONES, the floor rises to the newest tombstone that doesn't fit ... */
const RAISE_FLOOR = `UPDATE accounts SET sync_floor = max(sync_floor, COALESCE(
  (SELECT rev FROM sync_items WHERE account_id = ?1 AND deleted = 1 ORDER BY rev DESC LIMIT 1 OFFSET ?2), sync_floor))
WHERE id = ?1 AND sync_tombstones > ?2`;
/** ... and every tombstone at or below the floor goes. */
const TRIM_TOMBSTONES = "DELETE FROM sync_items WHERE account_id = ?1 AND deleted = 1 AND rev <= (SELECT sync_floor FROM accounts WHERE id = ?1)";

export async function handlePush(request: Request, env: Env, nowMs: number): Promise<Response> {
  const principal = await openAccountRequest(request, env, "/v1/sync", nowMs, "SYNC_WRITE_LIMIT");
  if (principal instanceof Response) return principal;
  const body = await readJsonObject(request, MAX_SYNC_BODY_BYTES);
  if (body instanceof Response) return body;
  const { changes: raw } = body;
  if (Object.keys(body).some((key) => key !== "changes") || !Array.isArray(raw) || raw.length === 0) return errorResponse(400, "bad_request");
  if (raw.length > MAX_CHANGES) return errorResponse(413, "too_large");

  const changes: Change[] = [];
  const seen = new Set<string>();
  for (const [index, value] of raw.entries()) {
    const parsed = parseChange(value);
    if ("tooLarge" in parsed) return errorResponse(413, "too_large");
    if ("field" in parsed) return json(400, { error: "invalid_item", index, field: parsed.field });
    const key = itemKey(parsed.change.collection, parsed.change.id);
    if (seen.has(key)) return json(400, { error: "invalid_item", index, field: "id" });
    seen.add(key);
    changes.push(parsed.change);
  }

  // Deletes first, so a push that removes some items and adds others fits the caps whatever
  // order the client listed them in. The items are distinct, so their order means nothing else.
  const ordered = [...changes.filter((change) => change.deleted), ...changes.filter((change) => !change.deleted)];
  const db = env.DB;
  const id = principal.accountId;
  let results: D1Result<Record<string, unknown>>[];
  try {
    results = await db.batch<Record<string, unknown>>([
      ...ordered.map((change) =>
        db.prepare(UPSERT).bind(id, change.collection, change.id, nowMs, change.deleted ? 1 : 0, change.body, change.baseRev),
      ),
      db.prepare(RAISE_FLOOR).bind(id, MAX_TOMBSTONES),
      db.prepare(TRIM_TOMBSTONES).bind(id),
      db.prepare("SELECT sync_rev FROM accounts WHERE id = ?").bind(id),
      db
        .prepare(
          `SELECT ${ITEM_COLUMNS} FROM sync_items WHERE account_id = ?1
           AND (collection, item_id) IN (SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]') FROM json_each(?2))`,
        )
        .bind(id, JSON.stringify(changes.map((change) => [change.collection, change.id]))),
    ]);
  } catch (error) {
    // A cap's CHECK constraint failed (migrations/0003_sync.sql): the batch rolled back whole.
    // D1 puts SQLite's message in the error's message, or in its cause.
    const message = error instanceof Error ? `${error.message} ${error.cause instanceof Error ? error.cause.message : ""}` : "";
    if (/CHECK constraint failed: sync_quota_/.test(message)) return errorResponse(403, "quota");
    throw error;
  }
  const account = results[results.length - 2].results[0] as { sync_rev: number } | undefined;
  if (account === undefined) return errorResponse(401, "invalid_token", { "WWW-Authenticate": "Bearer" });
  const stored = new Map((results[results.length - 1].results as unknown as ItemRow[]).map((row) => [itemKey(row.collection, row.item_id), row]));

  // Each change is applied when the server now holds what it asked for (a missing item counts
  // as deleted): written by this push, or already so. Otherwise its base_rev was stale.
  const applied = [];
  const conflicts = [];
  for (const change of changes) {
    const row = stored.get(itemKey(change.collection, change.id));
    if ((row === undefined ? true : row.deleted === 1) === change.deleted && (row?.body ?? null) === change.body) {
      applied.push({ collection: change.collection, id: change.id, rev: row?.rev ?? 0 });
    } else {
      conflicts.push({ collection: change.collection, id: change.id, server: row === undefined ? null : itemJson(row) });
    }
  }
  return json(200, { rev: account.sync_rev, applied, conflicts });
}

/** The hourly cron's part: tombstones past 90 days go, and each account's floor rises past them. */
export function pruneTombstones(db: D1Database, nowMs: number): D1PreparedStatement[] {
  const cutoff = nowMs - TOMBSTONE_TTL_MS;
  return [
    db
      .prepare(
        `UPDATE accounts SET sync_floor = max(sync_floor,
           (SELECT MAX(rev) FROM sync_items WHERE account_id = accounts.id AND deleted = 1 AND updated_ms <= ?1))
         WHERE id IN (SELECT account_id FROM sync_items WHERE deleted = 1 AND updated_ms <= ?1)`,
      )
      .bind(cutoff),
    db.prepare("DELETE FROM sync_items WHERE deleted = 1 AND updated_ms <= ?1").bind(cutoff),
  ];
}
