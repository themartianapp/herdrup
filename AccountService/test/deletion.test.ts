import { SELF, env } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, inject, it, vi, type MockInstance } from "vitest";
import { appleSigner, clientSecret } from "../src/apple";
import { b64url, fromB64url, randomB64url, utf8 } from "../src/bytes";
import { ACCOUNT_TABLES } from "../src/deletion";
import {
  APPLE_REVOKE_URL,
  APPLE_TOKEN_URL,
  appleRest,
  fakeProviders,
  defaultAppleResponse,
  resetAppleRest,
  signIdToken,
  type AppleCall,
  type Providers,
} from "./providers";

// Account deletion and Apple's server-to-server notifications, against the real Worker and a
// local D1 in workerd. Accounts are made by real sign-ins with the test providers' keys
// (test/providers.ts), which also stand in for Apple's /auth/token and /auth/revoke and record
// every call. The Sign in with Apple key is a P-256 key generated here; no real key is read.

const ORIGIN = "https://accounts.herdrup.app";
const APPLE_APP = "com.jerryfane.herdr";
const APPLE_WEB = "com.jerryfane.herdr.signin";
const GOOGLE_IOS = "test-ios.apps.googleusercontent.com";
const KEY_ID = "TESTKEY123";
const TEAM_ID = "FXQ5Z9HHY6";

let keys: Providers;
let siwaPublicKey: CryptoKey;
let siwaPem: string;
let ipCounter = 0;
const freshIp = () => `2001:db8:4::${(++ipCounter).toString(16)}`;
const freshSub = () => `001234.${crypto.randomUUID().replace(/-/g, "")}.0420`;
const nowSeconds = () => Math.floor(Date.now() / 1000);

beforeAll(async () => {
  keys = await fakeProviders();
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  siwaPublicKey = pair.publicKey;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const base64 = btoa(String.fromCharCode(...der));
  // The .p8 file Apple hands out: PKCS8 PEM, 64-character lines.
  siwaPem = `-----BEGIN PRIVATE KEY-----\n${base64.match(/.{1,64}/g)?.join("\n")}\n-----END PRIVATE KEY-----\n`;
});

beforeEach(() => {
  resetAppleRest();
  env.APPLE_SIWA_P8 = siwaPem;
  env.APPLE_KEY_ID = KEY_ID;
});

function post(path: string, body: unknown, access?: string, ip = freshIp()): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json", "CF-Connecting-IP": ip };
  if (access !== undefined) headers.Authorization = `Bearer ${access}`;
  return SELF.fetch(`${ORIGIN}${path}`, { method: "POST", headers, body: typeof body === "string" ? body : JSON.stringify(body) });
}

function get(path: string, access: string): Promise<Response> {
  return SELF.fetch(`${ORIGIN}${path}`, { headers: { Authorization: `Bearer ${access}` } });
}

async function rejection(response: Response): Promise<Record<string, unknown>> {
  return { status: response.status, ...(await response.json<Record<string, unknown>>()) };
}

async function newNonce(): Promise<string> {
  const response = await post("/v1/auth/nonce", {});
  expect(response.status).toBe(200);
  return (await response.json<{ nonce: string }>()).nonce;
}

type Provider = "apple" | "google";

interface Identity {
  provider: Provider;
  sub: string;
  aud: string;
}

const appleUser = (aud = APPLE_APP): Identity => ({ provider: "apple", sub: freshSub(), aud });
const googleUser = (): Identity => ({ provider: "google", sub: `1${Date.now()}${++ipCounter}`, aud: GOOGLE_IOS });

/** A fresh ID token for `who`, with a nonce from this Worker. */
async function freshToken(who: Identity): Promise<{ id_token: string; nonce: string }> {
  const nonce = await newNonce();
  const iss = who.provider === "apple" ? "https://appleid.apple.com" : "https://accounts.google.com";
  const id_token = await signIdToken(keys[who.provider], { iss, aud: who.aud, sub: who.sub, nonce, iat: nowSeconds(), exp: nowSeconds() + 600 });
  return { id_token, nonce };
}

interface Session {
  accountId: string;
  access: string;
  refresh: string;
}

async function signIn(who: Identity): Promise<Session> {
  const response = await post(`/v1/auth/${who.provider}`, { ...(await freshToken(who)), platform: "ios" });
  expect(response.status).toBe(200);
  const body = await response.json<{ account_id: string; access_token: string; refresh_token: string }>();
  return { accountId: body.account_id, access: body.access_token, refresh: body.refresh_token };
}

/** POST /v1/account/delete for `session`, confirmed by a fresh sign-in as `who`. */
async function deleteAccount(session: Session, who: Identity, extra: Record<string, unknown> = {}): Promise<Response> {
  return post("/v1/account/delete", { provider: who.provider, ...(await freshToken(who)), ...extra }, session.access);
}

async function accountExists(accountId: string): Promise<boolean> {
  return (await env.DB.prepare("SELECT 1 FROM accounts WHERE id = ?").bind(accountId).first()) !== null;
}

const decodePart = (part: string) => JSON.parse(new TextDecoder().decode(fromB64url(part)!)) as Record<string, unknown>;

/** Gives the account every kind of row there is: a second session with a device and a challenge, spent refresh tokens, sync items. */
async function populate(who: Identity): Promise<{ first: Session; second: Session }> {
  const first = await signIn(who);
  const second = await signIn(who);
  expect(second.accountId).toBe(first.accountId);
  const deviceId = randomB64url(16);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO devices (id, account_id, device_pub, name, platform, created_ms) VALUES (?, ?, ?, 'Phone', 'ios', ?)").bind(
      deviceId,
      first.accountId,
      randomB64url(32),
      Date.now(),
    ),
    env.DB.prepare("UPDATE sessions SET device_id = ? WHERE id = ?").bind(deviceId, second.access.split(".")[1]),
    // A desktop web sign-in waiting for its handoff (test/web.test.ts runs the real flow).
    env.DB.prepare(
      "INSERT INTO handoffs (code_hash, account_id, handoff_challenge, platform, created, display_hint, exp_ms) VALUES (?, ?, ?, 'macos', 0, NULL, ?)",
    ).bind(randomB64url(32), first.accountId, randomB64url(32), Date.now() + 120_000),
  ]);
  expect((await post("/v1/devices/challenge", {}, first.access)).status).toBe(200);
  const refreshed = await post("/v1/auth/refresh", { refresh_token: first.refresh });
  expect(refreshed.status).toBe(200);
  first.access = (await refreshed.json<{ access_token: string }>()).access_token;
  const sync = await post(
    "/v1/sync",
    {
      changes: [
        { collection: "settings", id: "ui.fontScale", body: { value: 1.2 } },
        { collection: "prompts", id: crypto.randomUUID(), body: { text: "hello" } },
        { collection: "hosts", id: crypto.randomUUID(), deleted: true },
      ],
    },
    second.access,
  );
  expect(sync.status).toBe(200);
  return { first, second };
}

// --- The schema, read from the migrations ---------------------------------------------------

/** Every table the migrations create, by name, from their own SQL. */
function migrationTables(): string[] {
  const names = inject("migrations")
    .flatMap((migration) => migration.queries)
    .flatMap((query) => [...query.matchAll(/CREATE TABLE (?:IF NOT EXISTS )?["`]?(\w+)/gi)].map((match) => match[1]));
  return [...new Set(names)].sort();
}

async function columns(table: string): Promise<string[]> {
  return (await env.DB.prepare(`PRAGMA table_info("${table}")`).all<{ name: string }>()).results.map((row) => row.name);
}

/**
 * Tables without an account_id column, and how deletion covers each. A new table must either
 * carry account_id (then it belongs in ACCOUNT_TABLES) or be listed here with its reason.
 */
const NOT_KEYED_BY_ACCOUNT: Record<string, string> = {
  accounts: "the account row itself, by id",
  spent_refresh_tokens: "keyed by session_id; deleted with the account's sessions",
  used_nonces: "SHA-256 of spent nonces and their expiry: nothing that names an account",
  web_flows: "a sign-in still in progress: no account yet, gone at its callback or after 10 minutes",
};

describe("deletion covers every table", () => {
  it("lists in ACCOUNT_TABLES exactly the tables with an account_id column, and every other table is accounted for", async () => {
    const tables = migrationTables();
    expect(tables).toContain("sync_items");
    const keyed: string[] = [];
    for (const table of tables) {
      if ((await columns(table)).includes("account_id")) keyed.push(table);
      else expect(NOT_KEYED_BY_ACCOUNT, `table ${table} has no account_id: decide how deletion covers it`).toHaveProperty(table);
    }
    expect(keyed.sort()).toEqual([...ACCOUNT_TABLES].sort());
    // The live schema has no table the migrations' SQL didn't name.
    const live = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name <> 'd1_migrations'",
    ).all<{ name: string }>();
    expect(live.results.map((row) => row.name).sort()).toEqual(tables);
  });

  it("leaves no row of the account in any table, and another account untouched", async () => {
    const who = appleUser();
    const { first, second } = await populate(who);
    const bystander = await populate(googleUser());
    const sessionIds = [first.access.split(".")[1], second.access.split(".")[1]];

    const count = async (accountId: string, ids: string[]) => {
      const counts: Record<string, number> = {};
      for (const table of migrationTables()) {
        const cols = await columns(table);
        const [sql, bound] = cols.includes("account_id")
          ? [`SELECT COUNT(*) AS n FROM ${table} WHERE account_id = ?`, accountId]
          : table === "accounts"
            ? ["SELECT COUNT(*) AS n FROM accounts WHERE id = ?", accountId]
            : cols.includes("session_id")
              ? [`SELECT COUNT(*) AS n FROM ${table} WHERE session_id IN (SELECT value FROM json_each(?))`, JSON.stringify(ids)]
              : [null, null];
        if (sql !== null) counts[table] = (await env.DB.prepare(sql).bind(bound).first<{ n: number }>())?.n ?? -1;
      }
      return counts;
    };
    const before = await count(first.accountId, sessionIds);
    // populate() put rows in every table that can hold the account's.
    for (const [table, n] of Object.entries(before)) expect(n, table).toBeGreaterThan(0);
    const bystanderBefore = await count(bystander.first.accountId, [bystander.first.access.split(".")[1], bystander.second.access.split(".")[1]]);

    const response = await deleteAccount(first, who, { authorization_code: "c0de.0.test" });
    expect(await response.json()).toEqual({ deleted: true, manual_revoke: false });

    const after = await count(first.accountId, sessionIds);
    for (const [table, n] of Object.entries(after)) expect(n, table).toBe(0);
    expect(await count(bystander.first.accountId, [bystander.first.access.split(".")[1], bystander.second.access.split(".")[1]])).toEqual(bystanderBefore);
  });
});

describe("POST /v1/account/delete", () => {
  it("ends every session and every device's statements at once", async () => {
    const who = appleUser();
    const { first, second } = await populate(who);
    const slot = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    env.STATEMENT_KEY_A = btoa(String.fromCharCode(...new Uint8Array((await crypto.subtle.exportKey("pkcs8", slot.privateKey)) as ArrayBuffer)));
    const statements = () => post("/v1/statements", { hosts: [randomB64url(16)] }, second.access);
    expect((await statements()).status).toBe(200);
    expect((await get("/v1/account", second.access)).status).toBe(200);

    expect((await deleteAccount(first, who)).status).toBe(200);
    expect(await rejection(await statements())).toEqual({ status: 401, error: "invalid_token" });
    for (const session of [first, second]) {
      expect(await rejection(await get("/v1/account", session.access))).toEqual({ status: 401, error: "invalid_token" });
      expect(await rejection(await get("/v1/sync", session.access))).toEqual({ status: 401, error: "invalid_token" });
    }
    expect(await rejection(await post("/v1/auth/refresh", { refresh_token: second.refresh }))).toEqual({ status: 401, error: "invalid_token" });
    // Signing in again makes a new, empty account.
    const again = await signIn(who);
    expect(again.accountId).not.toBe(first.accountId);
    env.STATEMENT_KEY_A = undefined;
  });

  it("wins or loses cleanly against another session's sync: no row survives the deletion", async () => {
    const who = appleUser();
    const { first, second } = await populate(who);
    // A full pull is half way when the account goes: its next page is refused.
    for (let i = 0; i < 6; i++) {
      const hostId = crypto.randomUUID();
      const changes = Array.from({ length: 100 }, (_, n) => ({ collection: "agent_prefs", id: `${hostId}/a${n}`, body: { pinned: true } }));
      expect((await post("/v1/sync", { changes }, second.access)).status).toBe(200);
    }
    const page = await (await get("/v1/sync?since=0", second.access)).json<{ more: boolean; cursor: string }>();
    expect(page.more).toBe(true);

    // Pushes racing the deletion: each is one batch, before the deletion or refused after it.
    const push = (n: number) =>
      post("/v1/sync", { changes: [{ collection: "prompts", id: crypto.randomUUID(), body: { text: `racing ${n}` } }] }, second.access);
    const [deleted, ...pushes] = await Promise.all([deleteAccount(first, who), push(1), push(2), push(3)]);
    expect(deleted.status).toBe(200);
    for (const response of pushes) expect([200, 401]).toContain(response.status);
    expect(await rejection(await push(4))).toEqual({ status: 401, error: "invalid_token" });
    expect(await rejection(await get(`/v1/sync?cursor=${page.cursor}`, second.access))).toEqual({ status: 401, error: "invalid_token" });
    for (const table of ["sync_items", "sync_usage", "sessions", "devices", "identities"]) {
      const left = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE account_id = ?`).bind(first.accountId).first<{ n: number }>();
      expect(left?.n, table).toBe(0);
    }
    expect(await accountExists(first.accountId)).toBe(false);
  });

  it("deletes a Google account without calling Apple", async () => {
    const who = googleUser();
    const session = await signIn(who);
    expect(await (await deleteAccount(session, who)).json()).toEqual({ deleted: true, manual_revoke: false });
    expect(appleRest.calls).toEqual([]);
    expect(await accountExists(session.accountId)).toBe(false);
  });

  it("needs a fresh sign-in as an identity of the session's own account", async () => {
    const who = appleUser();
    const session = await signIn(who);
    const other = appleUser();
    await signIn(other);
    expect(await rejection(await deleteAccount(session, other))).toEqual({ status: 403, error: "wrong_account" });
    // An identity nobody signed in with yet.
    expect(await rejection(await deleteAccount(session, appleUser()))).toEqual({ status: 403, error: "wrong_account" });
    expect(await rejection(await deleteAccount(session, googleUser()))).toEqual({ status: 403, error: "wrong_account" });
    expect(await accountExists(session.accountId)).toBe(true);
    expect(appleRest.calls).toEqual([]);
  });

  it("refuses a bad or reused proof, and bad bodies, before deleting anything", async () => {
    const who = appleUser();
    const session = await signIn(who);
    const proof = await freshToken(who);
    const strangerToken = await signIdToken(keys.stranger, { iss: "https://appleid.apple.com", aud: APPLE_APP, sub: who.sub, nonce: proof.nonce, iat: nowSeconds(), exp: nowSeconds() + 600 });
    expect(await rejection(await post("/v1/account/delete", { provider: "apple", id_token: strangerToken, nonce: proof.nonce }, session.access))).toEqual({
      status: 401,
      error: "token_invalid",
      reason: "unknown_kid",
    });
    expect(await rejection(await post("/v1/account/delete", { provider: "apple", ...proof, nonce: await newNonce() }, session.access))).toEqual({
      status: 401,
      error: "token_invalid",
      reason: "nonce_mismatch",
    });
    for (const body of [
      {},
      { provider: "github", ...proof },
      { provider: "apple", id_token: proof.id_token },
      { provider: "google", ...proof, authorization_code: "code" },
      { provider: "apple", ...proof, authorization_code: 42 },
      { provider: "apple", ...proof, authorization_code: "has space" },
      "not json",
    ]) {
      expect(await rejection(await post("/v1/account/delete", body, session.access))).toEqual({ status: 400, error: "bad_request" });
    }
    expect(await rejection(await post("/v1/account/delete", { provider: "apple", ...proof }))).toEqual({ status: 401, error: "invalid_token" });
    expect(await accountExists(session.accountId)).toBe(true);
    // The proof was never spent by the refusals above, so it still deletes once ...
    expect((await post("/v1/account/delete", { provider: "apple", ...proof }, session.access)).status).toBe(200);
    // ... and only once.
    const again = await signIn(who);
    expect(await rejection(await post("/v1/account/delete", { provider: "apple", ...proof }, again.access))).toEqual({ status: 401, error: "nonce_used" });
  });

  it("allows 5 deletion calls per IP a minute", async () => {
    const session = await signIn(appleUser());
    for (let i = 0; i < 5; i++) expect((await post("/v1/account/delete", {}, session.access, "2001:db8:4::ffff")).status).toBe(400);
    expect(await rejection(await post("/v1/account/delete", {}, session.access, "2001:db8:4::ffff"))).toEqual({ status: 429, error: "rate_limited" });
  });

  it("routes POST only", async () => {
    const session = await signIn(appleUser());
    const response = await get("/v1/account/delete", session.access);
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("POST");
  });
});

describe("Apple revoke", () => {
  /** The client secret in a recorded call, with its parts decoded and its ES256 signature checked against the test key. */
  async function checkSecret(call: AppleCall, clientId: string) {
    const [head, body, signature] = call.form.client_secret.split(".");
    expect(decodePart(head)).toEqual({ alg: "ES256", kid: KEY_ID });
    const claims = decodePart(body);
    expect(claims).toEqual({ iss: TEAM_ID, iat: expect.any(Number), exp: (claims.iat as number) + 300, aud: "https://appleid.apple.com", sub: clientId });
    expect(Math.abs((claims.iat as number) - nowSeconds())).toBeLessThanOrEqual(5);
    const raw = fromB64url(signature)!;
    expect(raw.byteLength).toBe(64);
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, siwaPublicKey, raw, utf8(`${head}.${body}`))).toBe(true);
  }

  it("signs a 5-minute ES256 client secret with the Sign in with Apple key", async () => {
    const signer = await appleSigner(env);
    expect(signer).not.toBeNull();
    const secret = await clientSecret(signer!, APPLE_APP, Date.now());
    await checkSecret({ url: APPLE_TOKEN_URL, form: { client_secret: secret } }, APPLE_APP);
    // Not signed by any other key.
    const other = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const [head, body, signature] = secret.split(".");
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, other.publicKey, fromB64url(signature)!, utf8(`${head}.${body}`))).toBe(false);
  });

  it("exchanges the code and revokes its refresh token with the client_id the ID token was issued to", async () => {
    for (const aud of [APPLE_APP, APPLE_WEB]) {
      resetAppleRest();
      const who = appleUser(aud);
      const session = await signIn(who);
      const code = `c${randomB64url(16)}.0.mrrs.${randomB64url(8)}`;
      expect(await (await deleteAccount(session, who, { authorization_code: code })).json()).toEqual({ deleted: true, manual_revoke: false });
      expect(appleRest.calls.map((call) => call.url)).toEqual([APPLE_TOKEN_URL, APPLE_REVOKE_URL]);
      const [exchange, revoke] = appleRest.calls;
      expect(exchange.form).toEqual({
        client_id: aud,
        client_secret: expect.any(String),
        code,
        grant_type: "authorization_code",
        ...(aud === APPLE_WEB ? { redirect_uri: "https://accounts.herdrup.app/v1/auth/web/apple/callback" } : {}),
      });
      expect(revoke.form).toEqual({ client_id: aud, client_secret: expect.any(String), token: `refresh-for-${code}`, token_type_hint: "refresh_token" });
      await checkSecret(exchange, aud);
      await checkSecret(revoke, aud);
      expect(await accountExists(session.accountId)).toBe(false);
    }
  });

  it("still deletes, and answers manual_revoke: true, whenever the revoke doesn't happen", async () => {
    const failures: [string, (call: AppleCall) => Response | Promise<Response>][] = [
      ["revoke refused", (call) => (call.url === APPLE_REVOKE_URL ? Response.json({ error: "invalid_client" }, { status: 400 }) : defaultAppleResponse(call))],
      ["code refused", () => Response.json({ error: "invalid_grant" }, { status: 400 })],
      ["no refresh token", (call) => (call.url === APPLE_TOKEN_URL ? Response.json({ access_token: "a" }) : new Response(null))],
      ["not JSON", (call) => (call.url === APPLE_TOKEN_URL ? new Response("<html>") : new Response(null))],
      [
        "network down",
        () => {
          throw new TypeError("network down");
        },
      ],
    ];
    for (const [label, respond] of failures) {
      resetAppleRest();
      appleRest.respond = respond;
      const who = appleUser();
      const session = await signIn(who);
      const response = await deleteAccount(session, who, { authorization_code: "c0de.0.test" });
      expect({ label, body: await response.json() }).toEqual({ label, body: { deleted: true, manual_revoke: true } });
      expect(await accountExists(session.accountId), label).toBe(false);
    }
  });

  it("answers manual_revoke: true without calling Apple when there is no code or no key", async () => {
    let who = appleUser();
    let session = await signIn(who);
    expect(await (await deleteAccount(session, who)).json()).toEqual({ deleted: true, manual_revoke: true });

    const logSpy = vi.spyOn(console, "log");
    try {
      for (const setup of [() => (env.APPLE_SIWA_P8 = undefined), () => (env.APPLE_SIWA_P8 = "not a key"), () => (env.APPLE_KEY_ID = "")]) {
        env.APPLE_SIWA_P8 = siwaPem;
        env.APPLE_KEY_ID = KEY_ID;
        setup();
        who = appleUser();
        session = await signIn(who);
        expect(await (await deleteAccount(session, who, { authorization_code: "c0de.0.test" })).json()).toEqual({ deleted: true, manual_revoke: true });
        expect(await accountExists(session.accountId)).toBe(false);
      }
      expect(logSpy.mock.calls.map((args) => String(args[0]))).toContain(JSON.stringify({ endpoint: "/v1/account/delete", outcome: "not_configured" }));
    } finally {
      logSpy.mockRestore();
    }
    expect(appleRest.calls).toEqual([]);
  });
});

describe("POST /v1/apple/notifications", () => {
  async function notification(claims: Record<string, unknown>, key = keys.apple, header: Record<string, unknown> = {}): Promise<Response> {
    return post("/v1/apple/notifications", { payload: await signIdToken(key, claims, header) });
  }

  const claimsFor = (sub: string, type: string, extra: Record<string, unknown> = {}, eventTime = Date.now()) => ({
    iss: "https://appleid.apple.com",
    aud: APPLE_APP,
    iat: nowSeconds(),
    jti: randomB64url(8),
    events: JSON.stringify({ type, sub, event_time: eventTime }),
    ...extra,
  });

  it("deletes the account on consent-revoked and on account-deleted, without calling Apple", async () => {
    for (const type of ["consent-revoked", "account-deleted"]) {
      const who = appleUser();
      const { first } = await populate(who);
      const response = await notification(claimsFor(who.sub, type));
      expect(response.status).toBe(204);
      expect(await accountExists(first.accountId), type).toBe(false);
      expect(await rejection(await get("/v1/account", first.access))).toEqual({ status: 401, error: "invalid_token" });
      for (const table of ACCOUNT_TABLES) {
        const left = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE account_id = ?`).bind(first.accountId).first<{ n: number }>();
        expect(left?.n, `${type} ${table}`).toBe(0);
      }
    }
    expect(appleRest.calls).toEqual([]);
  });

  it("takes events as an object too, with event_time in seconds, and the Web client's audience", async () => {
    const who = appleUser(APPLE_WEB);
    const session = await signIn(who);
    const claims = { ...claimsFor(who.sub, "consent-revoked"), aud: APPLE_WEB, iss: "appleid.apple.com", events: { type: "consent-revoked", sub: who.sub, event_time: nowSeconds() + 1 } };
    expect((await notification(claims)).status).toBe(204);
    expect(await accountExists(session.accountId)).toBe(false);
  });

  it("rejects a bad signature, a wrong audience and other bad tokens, and deletes nothing", async () => {
    const who = appleUser();
    const session = await signIn(who);
    const good = claimsFor(who.sub, "consent-revoked");
    const cases: [Promise<Response>, string][] = [
      // Signed by a key Apple doesn't publish, under Apple's kid.
      [notification(good, keys.stranger, { kid: keys.apple.kid }), "bad_signature"],
      [notification(good, keys.stranger), "unknown_kid"],
      [notification({ ...good, aud: "com.example.other" }), "wrong_audience"],
      [notification({ ...good, aud: GOOGLE_IOS }), "wrong_audience"],
      [notification({ ...good, iss: "https://accounts.google.com" }), "wrong_issuer"],
      [notification({ ...good, iat: nowSeconds() + 600 }), "issued_in_future"],
      [notification({ ...good, exp: nowSeconds() - 600 }), "expired"],
      [notification({ ...good, events: "not json" }), "malformed"],
      [notification({ ...good, events: JSON.stringify({ type: "consent-revoked" }) }), "bad_subject"],
      [notification(good, keys.apple, { alg: "HS256" }), "unsupported_alg"],
    ];
    for (const [response, reason] of cases) expect(await rejection(await response)).toEqual({ status: 401, error: "token_invalid", reason });
    // A tampered payload under a good signature.
    const [head, , signature] = (await signIdToken(keys.apple, good)).split(".");
    const forged = `${head}.${b64url(utf8(JSON.stringify({ ...good, sub: who.sub })))}.${signature}`;
    expect(await rejection(await post("/v1/apple/notifications", { payload: forged }))).toEqual({ status: 401, error: "token_invalid", reason: "bad_signature" });
    for (const body of [{}, { payload: 1 }, "not json"]) {
      expect(await rejection(await post("/v1/apple/notifications", body))).toEqual({ status: 400, error: "bad_request" });
    }
    expect(await accountExists(session.accountId)).toBe(true);
  });

  it("ignores email events, unknown subjects and events from before the identity signed in", async () => {
    const who = appleUser();
    const session = await signIn(who);
    const created = (await env.DB.prepare("SELECT created_ms FROM identities WHERE account_id = ?").bind(session.accountId).first<{ created_ms: number }>())!.created_ms;
    for (const claims of [
      claimsFor(who.sub, "email-disabled"),
      claimsFor(who.sub, "email-enabled"),
      claimsFor(freshSub(), "consent-revoked"),
      // A replay of a revoke from before this sign-up: the person signed in again since.
      claimsFor(who.sub, "consent-revoked", {}, created - 60_000),
      claimsFor(who.sub, "account-deleted", {}, Math.floor((created - 60_000) / 1000)),
    ]) {
      expect((await notification(claims)).status).toBe(204);
    }
    expect(await accountExists(session.accountId)).toBe(true);
  });

  it("deletes only for an event strictly after the identity was created, to the millisecond, and never on a same-second tie", async () => {
    const outcome = async (eventTime: (createdMs: number) => number | undefined, iat?: (createdMs: number) => number) => {
      const who = appleUser();
      const session = await signIn(who);
      const created = (await env.DB.prepare("SELECT created_ms FROM identities WHERE account_id = ?").bind(session.accountId).first<{ created_ms: number }>())!.created_ms;
      const time = eventTime(created);
      const claims = {
        ...claimsFor(who.sub, "consent-revoked"),
        events: JSON.stringify({ type: "consent-revoked", sub: who.sub, ...(time === undefined ? {} : { event_time: time }) }),
        ...(iat === undefined ? {} : { iat: iat(created) }),
      };
      expect((await notification(claims)).status).toBe(204);
      return (await accountExists(session.accountId)) ? "kept" : "deleted";
    };
    const cases: [string, () => Promise<string>, string][] = [
      ["ms, 60 s before", () => outcome((created) => created - 60_000), "kept"],
      ["ms, 1 s before", () => outcome((created) => created - 1000), "kept"],
      ["ms, 500 ms before", () => outcome((created) => created - 500), "kept"],
      ["ms, 1 ms before", () => outcome((created) => created - 1), "kept"],
      ["ms, same instant", () => outcome((created) => created), "kept"],
      ["ms, 1 ms after", () => outcome((created) => created + 1), "deleted"],
      ["s, the same second", () => outcome((created) => Math.floor(created / 1000)), "kept"],
      ["s, the next second", () => outcome((created) => Math.floor(created / 1000) + 1), "deleted"],
      ["no event_time, iat in the same second", () => outcome(() => undefined, (created) => Math.floor(created / 1000)), "kept"],
      ["no event_time, iat the next second", () => outcome(() => undefined, (created) => Math.floor(created / 1000) + 1), "deleted"],
    ];
    const results: Record<string, string> = {};
    for (const [label, run] of cases) results[label] = await run();
    expect(results).toEqual(Object.fromEntries(cases.map(([label, , expected]) => [label, expected])));
  });

  it("allows 5 notifications per IP a minute", async () => {
    const send = () => SELF.fetch(`${ORIGIN}/v1/apple/notifications`, { method: "POST", headers: { "CF-Connecting-IP": "2001:db8:4::eeee" }, body: "{}" });
    for (let i = 0; i < 5; i++) expect((await send()).status).toBe(400);
    expect(await rejection(await send())).toEqual({ status: 429, error: "rate_limited" });
  });
});

describe("logging", () => {
  let logSpy: MockInstance<typeof console.log>;

  beforeEach(() => {
    logSpy = vi.spyOn(console, "log");
  });

  afterEach(() => {
    logSpy.mockRestore();
  });

  it("never logs ids, codes, tokens or Apple's answers", async () => {
    const who = appleUser();
    const session = await signIn(who);
    env.APPLE_SIWA_P8 = undefined;
    const code = `c${randomB64url(16)}`;
    await deleteAccount(session, who, { authorization_code: code });
    for (let i = 0; i < 6; i++) await post("/v1/account/delete", {}, session.access, "2001:db8:4::dddd");
    const lines = logSpy.mock.calls.map((args) => String(args[0]));
    expect(lines).toContain(JSON.stringify({ endpoint: "/v1/account/delete", outcome: "rate_limited" }));
    for (const line of lines) {
      expect(Object.keys(JSON.parse(line)).sort()).toEqual(["endpoint", "outcome"]);
      for (const secret of [session.accountId, who.sub, code, session.access.split(".")[1]]) expect(line).not.toContain(secret);
    }
  });
});
