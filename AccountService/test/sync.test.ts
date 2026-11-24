import { SELF, env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from "vitest";
import { findOrCreateAccount } from "../src/auth";
import { randomB64url } from "../src/bytes";
import { cleanup } from "../src/cleanup";
import { openSession } from "../src/sessions";
import { handlePush, COLLECTION_CAPS, MAX_ACCOUNT_BYTES, MAX_ACCOUNT_ITEMS, MAX_CHANGES, MAX_NOT_AFTER_AHEAD_MS, MAX_TOMBSTONES, PAGE_SIZE, TOMBSTONE_TTL_MS } from "../src/sync";

// Sync against the real Worker and a local D1 in workerd. Accounts and sessions are made
// directly (sign-in has its own tests); two sessions of one account stand for two devices. The
// rate-limit bindings are per-key counters that start at zero in each test (test/setup.ts).

const ORIGIN = "https://accounts.herdrup.app";
const DAY_MS = 24 * 60 * 60 * 1000;

interface Session {
  accountId: string;
  access: string;
}

async function newAccount(): Promise<string> {
  return (await findOrCreateAccount(env.DB, "apple", randomB64url(32), Date.now())).accountId;
}

async function newSession(accountId?: string): Promise<Session> {
  const account = accountId ?? (await newAccount());
  const tokens = await openSession(env.DB, account, "ios", Date.now());
  return { accountId: account, access: tokens.access_token };
}

/** Two devices of one account. */
async function twoDevices(): Promise<[Session, Session]> {
  const first = await newSession();
  return [first, await newSession(first.accountId)];
}

function call(method: string, path: string, session?: Session, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (session !== undefined) headers.Authorization = `Bearer ${session.access}`;
  return SELF.fetch(`${ORIGIN}${path}`, { method, headers, body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body) });
}

async function rejection(response: Response): Promise<Record<string, unknown>> {
  return { status: response.status, ...(await response.json<Record<string, unknown>>()) };
}

interface Item {
  collection: string;
  id: string;
  rev: number;
  updated_ms: number;
  deleted: boolean;
  body: Record<string, unknown> | null;
}

interface PushResult {
  rev: number;
  applied: { collection: string; id: string; rev: number }[];
  conflicts: { collection: string; id: string; server: Item | null }[];
}

interface PullResult {
  rev: number;
  changes: Item[];
  more: boolean;
  cursor?: string;
}

interface ChangeIn {
  collection: string;
  id: string;
  base_rev?: number;
  deleted?: boolean;
  body?: unknown;
}

/** Every sync answer carries D1's time as an integer `now_ms`; the rest is the answer proper. */
function withoutClock<T extends object>(answer: T & { now_ms?: unknown }): T {
  const { now_ms, ...rest } = answer;
  expect(Number.isSafeInteger(now_ms), "now_ms").toBe(true);
  return rest as T;
}

async function push(session: Session, changes: ChangeIn[]): Promise<PushResult> {
  const response = await call("POST", "/v1/sync", session, { changes });
  expect(response.status).toBe(200);
  return withoutClock(await response.json<PushResult>());
}

/** A pull from `since` (a revision), or the continuation `cursor` (a string) of an earlier page. */
async function pull(session: Session, from?: number | string): Promise<PullResult> {
  const query = from === undefined ? "" : typeof from === "number" ? `?since=${from}` : `?cursor=${from}`;
  const response = await call("GET", `/v1/sync${query}`, session);
  expect(response.status).toBe(200);
  return withoutClock(await response.json<PullResult>());
}

/** Every page from `since`, following each page's cursor, as a client catches up. */
async function pullAll(session: Session, since = 0): Promise<{ rev: number; changes: Item[]; pages: number }> {
  const changes: Item[] = [];
  let page = await pull(session, since);
  for (let pages = 1; ; pages++) {
    changes.push(...page.changes);
    if (!page.more) return { rev: page.rev, changes, pages };
    expect(page.cursor).toEqual(expect.any(String));
    page = await pull(session, page.cursor);
  }
}

/** `count` live agent prefs at revisions 1…count of a new account, in 100-change pushes; their ids by revision. */
async function seedLive(session: Session, count: number): Promise<string[]> {
  const hostId = uuid();
  const ids = Array.from({ length: count }, (_, i) => `${hostId}/agent-${i}`);
  for (let start = 0; start < count; start += MAX_CHANGES) {
    await push(session, ids.slice(start, start + MAX_CHANGES).map((id) => ({ collection: "agent_prefs", id, body: { pinned: true } })));
  }
  return ids;
}

/** Ages every tombstone of the account past 90 days and runs the hourly cron, which prunes them. */
async function pruneAllTombstones(accountId: string): Promise<void> {
  await env.DB.prepare("UPDATE sync_items SET updated_ms = ? WHERE account_id = ? AND deleted = 1").bind(Date.now() - 91 * DAY_MS, accountId).run();
  await cleanup(env.DB, Date.now());
}

/** A client's copy after applying `changes` in order: live items by id, deletes dropped. */
function replay(changes: Item[]): Map<string, unknown> {
  const copy = new Map<string, unknown>();
  for (const item of changes) {
    if (item.deleted) copy.delete(item.id);
    else copy.set(item.id, item.body);
  }
  return copy;
}

const host = (fields: Record<string, unknown> = {}) => ({ host: "mac.local", username: "luca", ...fields });
const setting = (id: string, value: unknown): ChangeIn => ({ collection: "settings", id, body: { value } });

async function accountCounters(accountId: string) {
  return env.DB.prepare("SELECT sync_rev, sync_floor, sync_items, sync_bytes, sync_tombstones FROM accounts WHERE id = ?")
    .bind(accountId)
    .first<{ sync_rev: number; sync_floor: number; sync_items: number; sync_bytes: number; sync_tombstones: number }>();
}

/** The counters the triggers keep, recomputed from the rows themselves. */
async function countedFromRows(accountId: string) {
  return env.DB.prepare(
    `SELECT COALESCE(SUM(deleted = 0), 0) AS items, COALESCE(SUM(length(CAST(body AS BLOB))), 0) AS bytes,
            COALESCE(SUM(deleted), 0) AS tombstones, COALESCE(MAX(rev), 0) AS rev
     FROM sync_items WHERE account_id = ?`,
  )
    .bind(accountId)
    .first<{ items: number; bytes: number; tombstones: number; rev: number }>();
}

/** Tombstones at revisions 1…count in `prompts` of a new account, written straight to D1 (through the triggers). */
async function seedTombstones(accountId: string, count: number): Promise<void> {
  await env.DB.prepare(
    `WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?2)
     INSERT INTO sync_items (account_id, collection, item_id, rev, updated_ms, deleted, body)
     SELECT ?1, 'prompts', printf('00000000-0000-4000-8000-%012d', i), i, ?3, 1, NULL FROM n`,
  )
    .bind(accountId, count, Date.now())
    .run();
}

const uuid = () => crypto.randomUUID();

describe("push and pull", () => {
  it("stores items, numbers each write with the account's next revision and pulls them in order", async () => {
    const session = await newSession();
    expect(await pull(session)).toEqual({ rev: 0, changes: [], more: false });
    const [h, p] = [uuid(), uuid()];
    const before = Date.now();
    const pushed = await push(session, [
      { collection: "hosts", id: h, body: host({ nickname: "Studio", port: 22, auth_kind: "key" }) },
      { collection: "prompts", id: p, body: { title: "Review", text: "Review this diff\n\tcarefully", order: 1.5 } },
      setting("terminal.fontSize", 14),
    ]);
    expect(pushed).toEqual({
      rev: 3,
      applied: [
        { collection: "hosts", id: h, rev: 1 },
        { collection: "prompts", id: p, rev: 2 },
        { collection: "settings", id: "terminal.fontSize", rev: 3 },
      ],
      conflicts: [],
    });
    const pulled = await pull(session);
    expect(pulled.rev).toBe(3);
    expect(pulled.more).toBe(false);
    expect(pulled.changes.map((item) => [item.collection, item.id, item.rev, item.deleted])).toEqual([
      ["hosts", h, 1, false],
      ["prompts", p, 2, false],
      ["settings", "terminal.fontSize", 3, false],
    ]);
    expect(pulled.changes[0].body).toEqual({ nickname: "Studio", host: "mac.local", port: 22, username: "luca", auth_kind: "key" });
    expect(pulled.changes[0].updated_ms).toBeGreaterThanOrEqual(before);
    expect((await pull(session, 1)).changes.map((item) => item.rev)).toEqual([2, 3]);
    expect(await pull(session, 3)).toEqual({ rev: 3, changes: [], more: false });
  });

  it("re-serialises each body from its validated fields, in schema order", async () => {
    const session = await newSession();
    const id = uuid();
    await call("POST", "/v1/sync", session, `{"changes":[{"body":{"username":"luca",  "host":"mac.local","nickname":"Mac"},"id":"${id}","collection":"hosts"}]}`);
    const stored = await env.DB.prepare("SELECT body FROM sync_items WHERE account_id = ?").bind(session.accountId).first<{ body: string }>();
    expect(stored?.body).toBe('{"nickname":"Mac","host":"mac.local","username":"luca"}');
  });

  it("lets the last write to reach the server win, whatever order the devices made them in", async () => {
    const [phone, mac] = await twoDevices();
    const id = uuid();
    await push(phone, [{ collection: "hosts", id, body: host({ nickname: "First" }) }]);
    await push(mac, [{ collection: "hosts", id, body: host({ nickname: "Second" }) }]);
    const late = await push(phone, [{ collection: "hosts", id, body: host({ nickname: "Third" }) }]);
    expect(late.applied).toEqual([{ collection: "hosts", id, rev: 3 }]);
    const { changes } = await pull(mac, 0);
    expect(changes).toHaveLength(1);
    expect(changes[0]).toMatchObject({ rev: 3, body: { nickname: "Third" } });
    // A device that saw rev 2 learns only the newest copy.
    expect((await pull(mac, 2)).changes.map((item) => item.body?.nickname)).toEqual(["Third"]);
  });

  it("keeps the revision of a write that changes nothing", async () => {
    const session = await newSession();
    await push(session, [setting("ui.fontScale", 1.2)]);
    expect(await push(session, [setting("ui.fontScale", 1.2)])).toEqual({
      rev: 1,
      applied: [{ collection: "settings", id: "ui.fontScale", rev: 1 }],
      conflicts: [],
    });
  });

  it("keeps settings one item per key, so two devices changing different settings never clobber each other", async () => {
    const [phone, mac] = await twoDevices();
    await push(phone, [setting("terminal.fontSize", 15)]);
    await push(mac, [setting("notify.gram", false)]);
    await push(phone, [setting("notify.finishes", true)]);
    const values = Object.fromEntries((await pull(phone)).changes.map((item) => [item.id, item.body?.value]));
    expect(values).toEqual({ "terminal.fontSize": 15, "notify.gram": false, "notify.finishes": true });
  });

  it("keeps each account's items apart", async () => {
    const [alice, bob] = [await newSession(), await newSession()];
    await push(alice, [setting("terminal.fontSize", 18)]);
    expect(await pull(bob)).toEqual({ rev: 0, changes: [], more: false });
  });

  it("pages through 500 items at a time", async () => {
    const session = await newSession();
    const hostId = uuid();
    for (let batch = 0; batch < 6; batch++) {
      await push(
        session,
        Array.from({ length: MAX_CHANGES }, (_, i) => ({ collection: "agent_prefs", id: `${hostId}/agent-${batch * MAX_CHANGES + i}`, body: { pinned: true } })),
      );
    }
    const first = await pull(session, 0);
    expect(first.changes).toHaveLength(PAGE_SIZE);
    expect(first).toMatchObject({ rev: PAGE_SIZE, more: true, cursor: `${PAGE_SIZE}.600` });
    const second = await pull(session, first.cursor);
    expect(second.changes.map((item) => item.rev)).toEqual(Array.from({ length: 100 }, (_, i) => PAGE_SIZE + 1 + i));
    expect(second).toEqual({ rev: 600, changes: expect.any(Array), more: false });
  });
});

describe("base_rev", () => {
  it("applies an edit made from the current revision and returns a conflict with the server copy otherwise", async () => {
    const [phone, mac] = await twoDevices();
    const id = uuid();
    const created = await push(phone, [{ collection: "hosts", id, base_rev: 0, body: host({ nickname: "Mac" }) }]);
    expect(created.applied).toEqual([{ collection: "hosts", id, rev: 1 }]);
    // Both editors opened the host at rev 1; the Mac saves first.
    expect((await push(mac, [{ collection: "hosts", id, base_rev: 1, body: host({ nickname: "Mac mini" }) }])).applied).toEqual([
      { collection: "hosts", id, rev: 2 },
    ]);
    const stale = await push(phone, [{ collection: "hosts", id, base_rev: 1, body: host({ nickname: "Office" }) }]);
    expect(stale.applied).toEqual([]);
    expect(stale.rev).toBe(2);
    expect(stale.conflicts).toEqual([
      { collection: "hosts", id, server: expect.objectContaining({ rev: 2, deleted: false, body: { nickname: "Mac mini", host: "mac.local", username: "luca" } }) },
    ]);
    // The rest of the push still applies, and a background push (no base_rev) still wins.
    const mixed = await push(phone, [
      { collection: "hosts", id, base_rev: 1, body: host({ nickname: "Office" }) },
      setting("chat.fontSize", 17),
    ]);
    expect(mixed.conflicts.map((conflict) => conflict.id)).toEqual([id]);
    expect(mixed.applied).toEqual([{ collection: "settings", id: "chat.fontSize", rev: 3 }]);
    expect((await push(phone, [{ collection: "hosts", id, body: host({ nickname: "Office" }) }])).applied).toEqual([{ collection: "hosts", id, rev: 4 }]);
  });

  it("treats base_rev 0 as 'create only' and reports a delete made since", async () => {
    const [phone, mac] = await twoDevices();
    const id = uuid();
    await push(phone, [{ collection: "prompts", id, body: { text: "one" } }]);
    expect((await push(mac, [{ collection: "prompts", id, base_rev: 0, body: { text: "two" } }])).conflicts).toEqual([
      { collection: "prompts", id, server: expect.objectContaining({ rev: 1, body: { text: "one" } }) },
    ]);
    await push(mac, [{ collection: "prompts", id, deleted: true }]);
    expect((await push(phone, [{ collection: "prompts", id, base_rev: 1, body: { text: "edited" } }])).conflicts).toEqual([
      { collection: "prompts", id, server: expect.objectContaining({ rev: 2, deleted: true, body: null }) },
    ]);
  });

  it("reports a stale edit of an item the server never had, with no server copy", async () => {
    const session = await newSession();
    const id = uuid();
    expect(await push(session, [{ collection: "prompts", id, base_rev: 5, body: { text: "x" } }])).toEqual({
      rev: 0,
      applied: [],
      conflicts: [{ collection: "prompts", id, server: null }],
    });
  });
});

describe("schemas (allowlist)", () => {
  const refused = async (change: unknown) => rejection(await call("POST", "/v1/sync", await newSession(), { changes: [change] }));

  it("refuses any field outside a collection's allowlist, so no secret has a field to travel in", async () => {
    const cases: [ChangeIn, string][] = [
      [{ collection: "hosts", id: uuid(), body: host({ password: "hunter2" }) }, "password"],
      [{ collection: "hosts", id: uuid(), body: host({ private_key: "-----BEGIN OPENSSH PRIVATE KEY-----" }) }, "private_key"],
      [{ collection: "hosts", id: uuid(), body: host({ host_key_pin: "SHA256:abc" }) }, "host_key_pin"],
      [{ collection: "prompts", id: uuid(), body: { text: "x", transcript: "…" } }, "transcript"],
      [{ collection: "settings", id: "terminal.fontSize", body: { value: 12, extra: 1 } }, "extra"],
      [{ collection: "agent_prefs", id: `${uuid()}/claude`, body: { pinned: true, color: "red" } }, "color"],
      [
        {
          collection: "shares",
          id: `${"h".repeat(22)}/${"g".repeat(22)}`,
          body: { relay: "https://guest.herdrup.app", host_id: "h".repeat(22), node_pub: "n".repeat(43), guest_id: "g".repeat(22), secret: "s".repeat(43) },
        },
        "secret",
      ],
    ];
    for (const [change, field] of cases) expect(await refused(change)).toEqual({ status: 400, error: "invalid_item", index: 0, field });
  });

  it("refuses unknown keys on a change and on the push", async () => {
    expect(await refused({ ...setting("ui.fontScale", 1), updated_ms: 1 })).toEqual({ status: 400, error: "invalid_item", index: 0, field: "updated_ms" });
    const session = await newSession();
    expect(await rejection(await call("POST", "/v1/sync", session, { changes: [setting("ui.fontScale", 1)], device: "x" }))).toEqual({
      status: 400,
      error: "bad_request",
    });
  });

  it("syncs only allowlisted settings keys, each with its own type and range", async () => {
    for (const [id, value] of [
      ["ui.sidebarWidth", 320],
      ["hasSeenGesturesHelp", true],
      ["gram.setupCardDismissed", true],
      ["previews.javascript", false],
      ["notify.", true],
      ["constructor", 1],
    ] as const) {
      expect(await refused(setting(id, value))).toEqual({ status: 400, error: "invalid_item", index: 0, field: "id" });
    }
    for (const [id, value] of [
      ["terminal.fontSize", "12"],
      ["terminal.fontSize", 500],
      ["ui.fontScale", null],
      ["ui.theme", "neon"],
      ["notify.gram", "yes"],
      ["guest.ownerName", "x".repeat(65)],
      ["guest.ownerName", "a\u0000b"],
    ] as const) {
      expect(await refused(setting(id, value))).toEqual({ status: 400, error: "invalid_item", index: 0, field: "value" });
    }
    expect(await refused({ collection: "settings", id: "ui.theme", body: {} })).toEqual({ status: 400, error: "invalid_item", index: 0, field: "value" });
    const session = await newSession();
    const ok = await push(session, [
      setting("ui.theme", "dark"),
      setting("notify.needsInput", false),
      setting("guest.ownerName", "Luca"),
      setting("guest.terminal.fontSize", 13),
    ]);
    expect(ok.applied).toHaveLength(4);
  });

  it("checks ids, required fields and value ranges per collection", async () => {
    const shareId = `${"h".repeat(22)}/${"g".repeat(22)}`;
    const share = { relay: "https://guest.herdrup.app", host_id: "h".repeat(22), node_pub: "n".repeat(43), guest_id: "g".repeat(22) };
    const cases: [unknown, string][] = [
      [{ collection: "notes", id: uuid(), body: {} }, "collection"],
      [{ collection: "hosts", id: "not-a-uuid", body: host() }, "id"],
      [{ collection: "hosts", id: uuid().toUpperCase(), body: host() }, "id"],
      [{ collection: "hosts", id: uuid(), body: { host: "mac.local" } }, "username"],
      [{ collection: "hosts", id: uuid(), body: host({ port: 0 }) }, "port"],
      [{ collection: "hosts", id: uuid(), body: host({ port: 22.5 }) }, "port"],
      [{ collection: "hosts", id: uuid(), body: host({ host: "a b" }) }, "host"],
      [{ collection: "hosts", id: uuid(), body: host({ host: "h".repeat(254) }) }, "host"],
      [{ collection: "hosts", id: uuid(), body: host({ auth_kind: "agent" }) }, "auth_kind"],
      [{ collection: "hosts", id: uuid(), body: host({ nickname: "n".repeat(65) }) }, "nickname"],
      [{ collection: "hosts", id: uuid(), body: host({ label: "a\nb" }) }, "label"],
      [{ collection: "hosts", id: uuid(), body: [] }, "body"],
      [{ collection: "hosts", id: uuid() }, "body"],
      [{ collection: "prompts", id: uuid(), body: { text: "" } }, "text"],
      [{ collection: "prompts", id: uuid(), body: { text: "é".repeat(4097) } }, "text"],
      [{ collection: "prompts", id: uuid(), body: { text: "x", order: "1" } }, "order"],
      [{ collection: "prompts", id: uuid(), body: { text: "\ud800" } }, "text"],
      [{ collection: "agent_prefs", id: uuid(), body: { pinned: true } }, "id"],
      [{ collection: "agent_prefs", id: `${uuid()}/`, body: { pinned: true } }, "id"],
      [{ collection: "agent_prefs", id: `${uuid()}/claude`, body: { hidden: 1 } }, "hidden"],
      [{ collection: "shares", id: "h".repeat(22), body: share }, "id"],
      [{ collection: "shares", id: shareId, body: { ...share, host_id: "x".repeat(22) } }, "host_id"],
      [{ collection: "shares", id: shareId, body: { ...share, guest_id: "x".repeat(22) } }, "guest_id"],
      [{ collection: "shares", id: shareId, body: { ...share, node_pub: "short" } }, "node_pub"],
      [{ collection: "shares", id: shareId, body: { ...share, relay: "https://guest.herdrup.app/i/abcdefghijklmnop0123456789abcdef" } }, "relay"],
      [{ collection: "shares", id: shareId, body: { ...share, relay: "https://guest.herdrup.app/i#payload" } }, "relay"],
      [{ collection: "shares", id: shareId, body: { ...share, relay: "https://user:pw@guest.herdrup.app" } }, "relay"],
      [{ collection: "shares", id: shareId, body: { ...share, relay: "https://user@guest.herdrup.app" } }, "relay"],
      [{ collection: "shares", id: shareId, body: { ...share, relay: "https://guest.herdrup.app/%69/abcdefghijklmnop" } }, "relay"],
      [{ collection: "shares", id: shareId, body: { ...share, relay: "https://guest.herdrup.app/%zz" } }, "relay"],
      [{ collection: "shares", id: shareId, body: { ...share, relay: "herdrup://guest-invite" } }, "relay"],
      [{ collection: "shares", id: shareId, body: { ...share, share_gram: "true" } }, "share_gram"],
      [{ collection: "hosts", id: uuid(), base_rev: -1, body: host() }, "base_rev"],
      [{ collection: "hosts", id: uuid(), base_rev: "1", body: host() }, "base_rev"],
      [{ collection: "hosts", id: uuid(), deleted: "yes" }, "deleted"],
      [{ collection: "hosts", id: uuid(), deleted: true, body: host() }, "body"],
      ["hosts", "change"],
    ];
    for (const [change, field] of cases) expect({ change, ...(await refused(change)) }).toEqual({ change, status: 400, error: "invalid_item", index: 0, field });
    const session = await newSession();
    expect(
      (
        await push(session, [
          { collection: "shares", id: shareId, body: { ...share, agent_name: "claude", owner_name: "Jerry", machine_label: "Studio", share_gram: true } },
          { collection: "prompts", id: uuid(), body: { text: "é".repeat(4096) } },
          { collection: "hosts", id: uuid(), body: host({ host: "[fe80::1]:2222", port: 65535, auth_kind: "password" }) },
        ])
      ).applied,
    ).toHaveLength(3);
  });

  it("stores a relay URL in its canonical form only, so dot segments can't carry an invite path in", async () => {
    const session = await newSession();
    const shareWith = (relay: string): ChangeIn => {
      const [hostId, guestId] = [randomB64url(16), randomB64url(16)];
      return { collection: "shares", id: `${hostId}/${guestId}`, body: { relay, host_id: hostId, node_pub: "n".repeat(43), guest_id: guestId } };
    };
    const cases: [string, string][] = [
      ["https://guest.herdrup.app/i/abcdefghijklmnop0123456789abcdef/../..", "https://guest.herdrup.app"],
      ["https://guest.herdrup.app/relay/./i/x/../..", "https://guest.herdrup.app/relay"],
      ["https://relay.example/@team", "https://relay.example/@team"],
      ["https://Guest.Herdrup.App:443/relay/", "https://guest.herdrup.app/relay"],
      ["http://localhost:8787", "http://localhost:8787"],
    ];
    const changes = cases.map(([relay]) => shareWith(relay));
    expect((await push(session, changes)).applied).toHaveLength(cases.length);
    const stored = new Map((await pull(session)).changes.map((item) => [item.id, item.body?.relay]));
    expect(changes.map((change) => stored.get(change.id))).toEqual(cases.map(([, canonical]) => canonical));
  });

  it("refuses the whole push when one change is invalid, and says which", async () => {
    const session = await newSession();
    const response = await call("POST", "/v1/sync", session, { changes: [setting("ui.fontScale", 1.1), { collection: "hosts", id: uuid(), body: host({ password: "x" }) }] });
    expect(await rejection(response)).toEqual({ status: 400, error: "invalid_item", index: 1, field: "password" });
    expect(await pull(session)).toEqual({ rev: 0, changes: [], more: false });
  });

  it("refuses the same item twice in one push", async () => {
    const session = await newSession();
    const response = await call("POST", "/v1/sync", session, { changes: [setting("ui.fontScale", 1), setting("ui.fontScale", 1.1)] });
    expect(await rejection(response)).toEqual({ status: 400, error: "invalid_item", index: 1, field: "id" });
  });

  it("refuses malformed pushes and pulls", async () => {
    const session = await newSession();
    for (const body of ["not json", "[]", { changes: [] }, { changes: {} }, {}]) {
      expect(await rejection(await call("POST", "/v1/sync", session, body))).toEqual({ status: 400, error: "bad_request" });
    }
    for (const query of [
      "?since=-1",
      "?since=abc",
      "?since=01",
      "?since=1.5",
      "?since=1&since=2",
      "?since=1&x=1",
      "?since=1234567890123456",
      "?cursor=5",
      "?cursor=5.x",
      "?cursor=5.5.5",
      "?cursor=5.5&since=5",
      "?cursor=5.5&cursor=5.5",
    ]) {
      expect(await rejection(await call("GET", `/v1/sync${query}`, session))).toEqual({ status: 400, error: "bad_request" });
    }
  });
});

describe("tombstones", () => {
  it("leaves a tombstone for a delete, so other devices learn of it", async () => {
    const [phone, mac] = await twoDevices();
    const id = uuid();
    await push(phone, [{ collection: "prompts", id, body: { text: "bye" } }]);
    expect(await push(mac, [{ collection: "prompts", id, deleted: true }])).toEqual({ rev: 2, applied: [{ collection: "prompts", id, rev: 2 }], conflicts: [] });
    const { changes } = await pull(phone, 1);
    expect(changes).toEqual([{ collection: "prompts", id, rev: 2, updated_ms: expect.any(Number), deleted: true, body: null }]);
    // Deleting again changes nothing, and the item can come back.
    expect((await push(phone, [{ collection: "prompts", id, deleted: true }])).applied).toEqual([{ collection: "prompts", id, rev: 2 }]);
    expect((await push(phone, [{ collection: "prompts", id, body: { text: "back" } }])).applied).toEqual([{ collection: "prompts", id, rev: 3 }]);
  });

  it("writes nothing for deleting an item the server never had", async () => {
    const session = await newSession();
    const id = uuid();
    expect(await push(session, [{ collection: "hosts", id, deleted: true }])).toEqual({ rev: 0, applied: [{ collection: "hosts", id, rev: 0 }], conflicts: [] });
    expect(await pull(session)).toEqual({ rev: 0, changes: [], more: false });
  });

  it("keeps the counters the caps use equal to the rows", async () => {
    const session = await newSession();
    const ids = Array.from({ length: 5 }, uuid);
    await push(session, ids.map((id, i) => ({ collection: "prompts", id, body: { text: `prompt ${i} — ✓` } })));
    await push(session, [{ collection: "prompts", id: ids[0], body: { text: "longer text now" } }, { collection: "prompts", id: ids[1], deleted: true }]);
    await push(session, [{ collection: "prompts", id: ids[2], deleted: true }, { collection: "prompts", id: ids[1], body: { text: "revived" } }]);
    const counters = await accountCounters(session.accountId);
    const rows = await countedFromRows(session.accountId);
    expect(counters).toMatchObject({ sync_items: rows?.items, sync_bytes: rows?.bytes, sync_tombstones: rows?.tombstones, sync_rev: rows?.rev });
    expect(counters).toMatchObject({ sync_items: 4, sync_tombstones: 1 });
    const usage = await env.DB.prepare("SELECT items FROM sync_usage WHERE account_id = ? AND collection = 'prompts'").bind(session.accountId).first<{ items: number }>();
    expect(usage?.items).toBe(4);
  });

  it("prunes tombstones older than 90 days in the hourly cron, and nothing else", async () => {
    const session = await newSession();
    const [old, recent, live] = [uuid(), uuid(), uuid()];
    await push(session, [
      { collection: "prompts", id: old, body: { text: "old" } },
      { collection: "prompts", id: recent, body: { text: "recent" } },
      { collection: "prompts", id: live, body: { text: "live" } },
    ]);
    await push(session, [{ collection: "prompts", id: old, deleted: true }]);
    await push(session, [{ collection: "prompts", id: recent, deleted: true }]);
    const now = Date.now();
    // The first tombstone (rev 4) is 91 days old; the second (rev 5) 89 days; the live item older than both.
    await env.DB.prepare("UPDATE sync_items SET updated_ms = ? WHERE account_id = ? AND item_id = ?").bind(now - 91 * DAY_MS, session.accountId, old).run();
    await env.DB.prepare("UPDATE sync_items SET updated_ms = ? WHERE account_id = ? AND item_id = ?").bind(now - 89 * DAY_MS, session.accountId, recent).run();
    await env.DB.prepare("UPDATE sync_items SET updated_ms = ? WHERE account_id = ? AND item_id = ?").bind(now - 400 * DAY_MS, session.accountId, live).run();
    await cleanup(env.DB, now);
    expect((await pull(session)).changes.map((item) => [item.id, item.rev, item.deleted])).toEqual([
      [live, 3, false],
      [recent, 5, true],
    ]);
    expect(await accountCounters(session.accountId)).toMatchObject({ sync_rev: 5, sync_floor: 4, sync_items: 1, sync_tombstones: 1 });
    expect(TOMBSTONE_TTL_MS).toBe(90 * DAY_MS);
  });

  it(`keeps the newest ${MAX_TOMBSTONES} tombstones per account`, async () => {
    const session = await newSession();
    await seedTombstones(session.accountId, MAX_TOMBSTONES);
    expect(await accountCounters(session.accountId)).toMatchObject({ sync_rev: MAX_TOMBSTONES, sync_tombstones: MAX_TOMBSTONES, sync_floor: 0 });
    // Two more deletes: the two oldest tombstones go and the floor rises to the newer of them.
    const ids = [uuid(), uuid()];
    await push(session, ids.map((id) => ({ collection: "hosts", id, body: host() })));
    await push(session, ids.map((id) => ({ collection: "hosts", id, deleted: true })));
    expect(await accountCounters(session.accountId)).toMatchObject({ sync_rev: MAX_TOMBSTONES + 4, sync_tombstones: MAX_TOMBSTONES, sync_floor: 2 });
    const oldest = await env.DB.prepare("SELECT MIN(rev) AS rev FROM sync_items WHERE account_id = ?").bind(session.accountId).first<{ rev: number }>();
    expect(oldest?.rev).toBe(3);
  });
});

describe("full reset", () => {
  it("answers 410 reset_required to a cursor that may have missed a pruned delete; a pull from 0 restores the state", async () => {
    const [phone, mac] = await twoDevices();
    const [gone, kept] = [uuid(), uuid()];
    await push(phone, [
      { collection: "hosts", id: gone, body: host({ nickname: "Old box" }) },
      { collection: "hosts", id: kept, body: host({ nickname: "Studio" }) },
    ]);
    const macCursor = (await pull(mac)).rev; // 2: the Mac then goes offline.
    await push(phone, [{ collection: "hosts", id: gone, deleted: true }]); // rev 3
    await push(phone, [setting("terminal.fontSize", 16)]); // rev 4
    await env.DB.prepare("UPDATE sync_items SET updated_ms = ? WHERE account_id = ? AND deleted = 1").bind(Date.now() - 91 * DAY_MS, phone.accountId).run();
    await cleanup(env.DB, Date.now());

    expect(await rejection(await call("GET", `/v1/sync?since=${macCursor}`, mac))).toEqual({ status: 410, error: "reset_required" });
    // The full pull no longer lists the deleted host: the Mac drops what the server doesn't list.
    const full = await pullAll(mac, 0);
    expect(full.rev).toBe(4);
    expect(full.changes.map((item) => item.id).sort()).toEqual([kept, "terminal.fontSize"].sort());
    // Cursors at or past the pruned revision still catch up normally.
    expect((await pull(phone, 3)).changes.map((item) => item.rev)).toEqual([4]);
    expect((await pull(mac, full.rev)).changes).toEqual([]);
  });

  it("completes a full pull past a floor that was there before it began; a stale incremental cursor still gets 410", async () => {
    const session = await newSession();
    await seedLive(session, 600); // revs 1–600
    const gone = uuid();
    await push(session, [{ collection: "prompts", id: gone, body: { text: "bye" } }]); // rev 601
    await push(session, [{ collection: "prompts", id: gone, deleted: true }]); // rev 602
    await pruneAllTombstones(session.accountId);
    expect(await accountCounters(session.accountId)).toMatchObject({ sync_rev: 602, sync_floor: 602 });

    const full = await pullAll(session, 0);
    expect(full.pages).toBe(2);
    expect(full.rev).toBe(602);
    expect(full.changes).toHaveLength(600);
    expect(full.changes.every((item) => !item.deleted)).toBe(true);
    // An incremental cursor that stopped at 500 may have missed the pruned delete.
    expect(await rejection(await call("GET", "/v1/sync?since=500", session))).toEqual({ status: 410, error: "reset_required" });
    expect(await rejection(await call("GET", "/v1/sync?cursor=500.500", session))).toEqual({ status: 410, error: "reset_required" });
    expect(await pull(session, full.rev)).toEqual({ rev: 602, changes: [], more: false });
  });

  it("stops a full pull when a prune during it could hide a delete of an item already sent", async () => {
    const session = await newSession();
    const ids = await seedLive(session, 600);
    const first = await pull(session, 0);
    expect(first.cursor).toBe("500.600");
    // An item on the first page is deleted (rev 601), and its tombstone pruned before the client goes on.
    await push(session, [{ collection: "agent_prefs", id: ids[0], deleted: true }]);
    await pruneAllTombstones(session.accountId);
    expect(await rejection(await call("GET", `/v1/sync?cursor=${first.cursor}`, session))).toEqual({ status: 410, error: "reset_required" });
    // Starting over gives the right state.
    const again = await pullAll(session, 0);
    expect(again.changes).toHaveLength(599);
    expect(again.changes.map((item) => item.id)).not.toContain(ids[0]);
  });

  it("goes on with a full pull when a prune during it only drops tombstones from before it began", async () => {
    const session = await newSession();
    await seedLive(session, 600);
    const gone = uuid();
    await push(session, [{ collection: "prompts", id: gone, body: { text: "bye" } }]); // rev 601
    await push(session, [{ collection: "prompts", id: gone, deleted: true }]); // rev 602, not yet pruned
    const first = await pull(session, 0);
    expect(first.cursor).toBe("500.602");
    await pruneAllTombstones(session.accountId);
    const rest = await pull(session, first.cursor);
    expect(rest).toMatchObject({ rev: 602, more: false });
    // The client never lists `gone`, so a resetting client drops its own copy of it.
    const copy = replay([...first.changes, ...rest.changes]);
    expect(copy.size).toBe(600);
    expect(copy.has(gone)).toBe(false);
  });

  it("delivers writes that land during a full pull, so the client ends with the server's state", async () => {
    const [phone, mac] = await twoDevices();
    const ids = await seedLive(phone, 600);
    const first = await pull(mac, 0);
    const added = uuid();
    await push(phone, [{ collection: "agent_prefs", id: ids[0], body: { pinned: false, order: 2 } }]); // rev 601
    await push(phone, [{ collection: "prompts", id: added, body: { text: "new" } }]); // rev 602
    await push(phone, [{ collection: "agent_prefs", id: ids[1], deleted: true }]); // rev 603
    const rest = await pull(mac, first.cursor);
    expect(rest.more).toBe(false);
    expect(rest.rev).toBe(603);
    expect(rest.changes.map((item) => item.rev)).toEqual([...Array.from({ length: 100 }, (_, i) => 501 + i), 601, 602, 603]);
    const copy = replay([...first.changes, ...rest.changes]);
    const server = replay((await pullAll(phone, 0)).changes);
    expect(copy).toEqual(server);
    expect(copy.get(ids[0])).toEqual({ pinned: false, order: 2 });
    expect(copy.has(ids[1])).toBe(false);
    expect(copy.has(added)).toBe(true);
  });

  it("answers 410 reset_required to a cursor past the account's revision (another history)", async () => {
    const session = await newSession();
    await push(session, [setting("ui.fontScale", 1)]);
    expect(await rejection(await call("GET", "/v1/sync?since=2", session))).toEqual({ status: 410, error: "reset_required" });
    expect(await rejection(await call("GET", "/v1/sync?cursor=1.2", session))).toEqual({ status: 410, error: "reset_required" });
    expect((await pull(session, 1)).changes).toEqual([]);
  });
});

describe("caps", () => {
  it(`allows ${MAX_CHANGES} changes and 256 KB per push, and answers 413 too_large past either`, async () => {
    const session = await newSession();
    const hostId = uuid();
    const prefs = (n: number) => Array.from({ length: n }, (_, i) => ({ collection: "agent_prefs", id: `${hostId}/a${i}`, body: { hidden: true } }));
    expect((await push(session, prefs(MAX_CHANGES))).applied).toHaveLength(MAX_CHANGES);
    expect(await rejection(await call("POST", "/v1/sync", session, { changes: prefs(MAX_CHANGES + 1) }))).toEqual({ status: 413, error: "too_large" });
    const big = Array.from({ length: 40 }, () => ({ collection: "prompts", id: uuid(), body: { text: "x".repeat(8000) } }));
    expect(await rejection(await call("POST", "/v1/sync", session, { changes: big }))).toEqual({ status: 413, error: "too_large" });
  });

  it("answers 413 too_large for an item past 16 KB once serialised", async () => {
    const session = await newSession();
    // 8 KB of text that JSON escapes to two bytes a character.
    const response = await call("POST", "/v1/sync", session, { changes: [{ collection: "prompts", id: uuid(), body: { text: "\\".repeat(8192) } }] });
    expect(await rejection(response)).toEqual({ status: 413, error: "too_large" });
    expect((await push(session, [{ collection: "prompts", id: uuid(), body: { text: "\\".repeat(8000) } }])).applied).toHaveLength(1);
  });

  it(`caps each collection (hosts: ${COLLECTION_CAPS.hosts}) with 403 quota, rolling the whole push back; deletes in the same push make room`, async () => {
    const session = await newSession();
    const ids = Array.from({ length: COLLECTION_CAPS.hosts }, uuid);
    await push(session, ids.slice(0, 100).map((id) => ({ collection: "hosts", id, body: host() })));
    await push(session, ids.slice(100).map((id) => ({ collection: "hosts", id, body: host() })));
    const extra = uuid();
    const over = await call("POST", "/v1/sync", session, { changes: [setting("ui.fontScale", 1.3), { collection: "hosts", id: extra, body: host() }] });
    expect(await rejection(over)).toEqual({ status: 403, error: "quota" });
    expect((await pull(session, 200)).changes).toEqual([]);
    // Other collections have their own room.
    expect((await push(session, [setting("ui.fontScale", 1.3)])).applied).toHaveLength(1);
    // The new host goes in once a delete makes room, whatever order the push lists them in.
    const swap = await push(session, [{ collection: "hosts", id: extra, body: host() }, { collection: "hosts", id: ids[0], deleted: true }]);
    expect(swap.applied.map((change) => change.id)).toEqual([extra, ids[0]]);
    expect(swap.applied[1].rev).toBeLessThan(swap.applied[0].rev);
  });

  it(`caps an account at ${MAX_ACCOUNT_ITEMS} live items and 1 MB with 403 quota`, async () => {
    const session = await newSession();
    await push(session, [setting("ui.fontScale", 1)]);
    // The counter stands in for 1,998 more items already stored.
    await env.DB.prepare("UPDATE accounts SET sync_items = sync_items + ? WHERE id = ?").bind(MAX_ACCOUNT_ITEMS - 2, session.accountId).run();
    expect((await push(session, [setting("ui.theme", "dark")])).applied).toHaveLength(1);
    expect(await rejection(await call("POST", "/v1/sync", session, { changes: [setting("chat.fontSize", 16)] }))).toEqual({ status: 403, error: "quota" });
    // A replacement of an existing item adds no item.
    expect((await push(session, [setting("ui.theme", "light")])).applied).toHaveLength(1);

    // Back to the two real items; the byte counter stands in for nearly 1 MB already stored.
    await env.DB.prepare("UPDATE accounts SET sync_items = 2, sync_bytes = ? WHERE id = ?").bind(MAX_ACCOUNT_BYTES - 100, session.accountId).run();
    expect(await rejection(await call("POST", "/v1/sync", session, { changes: [{ collection: "prompts", id: uuid(), body: { text: "x".repeat(200) } }] }))).toEqual({
      status: 403,
      error: "quota",
    });
    expect((await push(session, [{ collection: "prompts", id: uuid(), body: { text: "x".repeat(20) } }])).applied).toHaveLength(1);
  });

  it("allows 30 pushes per account a minute; pulls keep working", async () => {
    const session = await newSession();
    for (let i = 0; i < 30; i++) await push(session, [setting("terminal.fontSize", 10 + i)]);
    expect(await rejection(await call("POST", "/v1/sync", session, { changes: [setting("terminal.fontSize", 9)] }))).toEqual({ status: 429, error: "rate_limited" });
    expect((await pull(session)).rev).toBe(30);
  });
});

describe("routing, auth, logs and deletion", () => {
  let logSpy: MockInstance<typeof console.log>;

  beforeEach(() => {
    logSpy = vi.spyOn(console, "log");
  });

  afterEach(() => {
    logSpy.mockRestore();
  });

  it("needs a session and takes only GET and POST", async () => {
    expect(await rejection(await call("GET", "/v1/sync"))).toEqual({ status: 401, error: "invalid_token" });
    expect(await rejection(await call("POST", "/v1/sync", undefined, { changes: [setting("ui.fontScale", 1)] }))).toEqual({ status: 401, error: "invalid_token" });
    const response = await call("PUT", "/v1/sync", await newSession());
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("GET, POST");
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("answers 500 not_configured without SYNC_WRITE_LIMIT", async () => {
    const session = await newSession();
    // The Worker reads its bindings from this env object (test/setup.ts); declared non-optional there.
    const bindings = env as unknown as Record<string, RateLimit | undefined>;
    const limiter = bindings.SYNC_WRITE_LIMIT;
    bindings.SYNC_WRITE_LIMIT = undefined;
    try {
      expect(await rejection(await call("POST", "/v1/sync", session, { changes: [setting("ui.fontScale", 1)] }))).toEqual({ status: 500, error: "not_configured" });
    } finally {
      bindings.SYNC_WRITE_LIMIT = limiter;
    }
  });

  it("never logs ids, item ids or bodies", async () => {
    const session = await newSession();
    const id = uuid();
    for (let i = 0; i < 31; i++) await call("POST", "/v1/sync", session, { changes: [{ collection: "hosts", id, body: host({ nickname: `secret-nick-${i}` }) }] });
    const lines = logSpy.mock.calls.map((args) => String(args[0]));
    expect(lines).toContain(JSON.stringify({ endpoint: "/v1/sync", outcome: "rate_limited" }));
    for (const line of lines) {
      expect(Object.keys(JSON.parse(line)).sort()).toEqual(["endpoint", "outcome"]);
      for (const secret of [session.accountId, id, "secret-nick", "mac.local"]) expect(line).not.toContain(secret);
    }
  });

  it("deletes an account's sync rows with the account", async () => {
    const session = await newSession();
    await push(session, [setting("ui.fontScale", 1), { collection: "prompts", id: uuid(), body: { text: "x" } }]);
    await env.DB.prepare("DELETE FROM accounts WHERE id = ?").bind(session.accountId).run();
    for (const table of ["sync_items", "sync_usage"]) {
      const left = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE account_id = ?`).bind(session.accountId).first<{ n: number }>();
      expect(left?.n).toBe(0);
    }
  });
});

describe("server time and the push deadline", () => {
  /** D1's own clock, the one the Worker reads inside its batches. */
  const d1Now = async () => (await env.DB.prepare("SELECT CAST(round(unixepoch('subsec') * 1000) AS INTEGER) AS t").first<{ t: number }>())!.t;

  /** Everything a push can change for the account: its items, revision, floor and counters. */
  const snapshot = async (accountId: string) =>
    env.DB.batch([
      env.DB.prepare("SELECT collection, item_id, rev, updated_ms, deleted, body FROM sync_items WHERE account_id = ? ORDER BY collection, item_id").bind(accountId),
      env.DB.prepare("SELECT sync_rev, sync_floor, sync_tombstones FROM accounts WHERE id = ?").bind(accountId),
      env.DB.prepare("SELECT * FROM sync_usage WHERE account_id = ? ORDER BY collection").bind(accountId),
    ]).then((results) => results.map((result) => result.results));

  /** Two items at revisions 1 and 2, and a push that deletes one, edits the other and adds a third. */
  async function seeded() {
    const session = await newSession();
    const prompt = uuid();
    await push(session, [setting("ui.fontScale", 1), { collection: "prompts", id: prompt, body: { text: "kept" } }]);
    const changes: ChangeIn[] = [
      { collection: "prompts", id: prompt, deleted: true },
      setting("ui.fontScale", 2),
      { collection: "prompts", id: uuid(), body: { text: "late" } },
    ];
    return { session, changes, before: await snapshot(session.accountId) };
  }

  it("answers a pull with D1's time read before its rows, never after a later write", async () => {
    const session = await newSession();
    await push(session, [setting("ui.fontScale", 1)]);
    const before = await d1Now();
    const page = await (await call("GET", "/v1/sync?since=0", session)).json<PullResult & { now_ms: number }>();
    const after = await d1Now();
    expect(Number.isSafeInteger(page.now_ms)).toBe(true);
    expect(page.now_ms).toBeGreaterThanOrEqual(before);
    expect(page.now_ms).toBeLessThanOrEqual(after);
    expect(page.changes.map((item) => item.id)).toEqual(["ui.fontScale"]);

    // A write after the pull is read at a D1 time no earlier than the pull's now_ms, and the next
    // pull, later still, shows it.
    const write = await (await call("POST", "/v1/sync", session, { changes: [setting("ui.fontScale", 2)] })).json<PushResult & { now_ms: number }>();
    expect(write.now_ms).toBeGreaterThanOrEqual(page.now_ms);
    const next = await (await call("GET", `/v1/sync?since=${page.rev}`, session)).json<PullResult & { now_ms: number }>();
    expect(next.now_ms).toBeGreaterThanOrEqual(write.now_ms);
    expect(next.changes.map((item) => item.body)).toEqual([{ value: 2 }]);
  });

  it("refuses a push whose not_after has passed, whole, and changes nothing", async () => {
    const { session, changes, before } = await seeded();
    const late = await call("POST", "/v1/sync", session, { changes, not_after: (await d1Now()) - 1 });
    expect(await rejection(late)).toEqual({ status: 409, error: "expired" });
    expect(await snapshot(session.accountId)).toEqual(before);
  });

  it("lands a push before its not_after, with now_ms at or before it", async () => {
    const { session, changes } = await seeded();
    const notAfter = (await d1Now()) + 2 * 60 * 1000;
    const response = await call("POST", "/v1/sync", session, { changes, not_after: notAfter });
    expect(response.status).toBe(200);
    const answer = await response.json<PushResult & { now_ms: number }>();
    expect(answer).toEqual({ rev: 5, applied: expect.any(Array), conflicts: [], now_ms: expect.any(Number) });
    expect(answer.applied).toHaveLength(3);
    expect(answer.now_ms).toBeLessThanOrEqual(notAfter);
  });

  it("treats a push without not_after as before, and adds now_ms", async () => {
    const { session, changes } = await seeded();
    const before = await d1Now();
    const answer = await (await call("POST", "/v1/sync", session, { changes })).json<PushResult & { now_ms: number }>();
    expect(answer).toEqual({ rev: 5, applied: expect.any(Array), conflicts: [], now_ms: expect.any(Number) });
    expect(answer.now_ms).toBeGreaterThanOrEqual(before);
    expect((await pull(session, 2)).changes.map((item) => item.rev)).toEqual([3, 4, 5]);
  });

  it("refuses a late write at the write, whatever the Worker's clock said on arrival", async () => {
    // The Worker admitted this push a minute before its deadline; D1's clock at the write is past
    // it, as for a request held in flight. The batch rolls back whole.
    const { session, changes, before } = await seeded();
    const notAfter = (await d1Now()) - 1;
    const request = new Request(`${ORIGIN}/v1/sync`, {
      method: "POST",
      headers: { "content-type": "application/json", Authorization: `Bearer ${session.access}` },
      body: JSON.stringify({ changes, not_after: notAfter }),
    });
    expect(await rejection(await handlePush(request, env, notAfter - 60 * 1000))).toEqual({ status: 409, error: "expired" });
    expect(await snapshot(session.accountId)).toEqual(before);
  });

  it("refuses a not_after that isn't a millisecond time in range", async () => {
    const session = await newSession();
    const tooFar = Date.now() + MAX_NOT_AFTER_AHEAD_MS + 60 * 60 * 1000;
    for (const notAfter of ["1", -1, 1.5, null, true, tooFar, 2 ** 53]) {
      const response = await call("POST", "/v1/sync", session, { changes: [setting("ui.fontScale", 1)], not_after: notAfter });
      expect(await rejection(response), String(notAfter)).toEqual({ status: 400, error: "bad_request" });
    }
    expect((await pull(session, 0)).changes).toEqual([]);
  });
});
