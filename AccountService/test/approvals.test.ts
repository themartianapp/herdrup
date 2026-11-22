import { SELF, env } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { findOrCreateAccount } from "../src/auth";
import { approveCommit, fingerprint, handleFinish, MAX_REQUESTS_PER_HOUR, reportStatements } from "../src/approvals";
import { b64url, fromB64url, hex, randomB64url } from "../src/bytes";
import { cleanup } from "../src/cleanup";
import { enrolMac, x25519 } from "../src/devices";
import { openSession, type Platform } from "../src/sessions";
import { approveCode, openEnvelope, sealEnvelope, x25519Key, type X25519Key } from "./approve_v1";
import approveVectorText from "./vectors/approve-v1.json?raw";

// Browser approval (approve-v1) against the real Worker and a local D1 in workerd. Each party is
// a session with an enrolled device; the browser and the approver run the protocol's client side
// (test/approve_v1.ts). test/vectors/approve-v1.json is herdrup-desktop's file
// (internal/account/testdata/approve-v1-local.json, branch accounts/web-approve), unchanged.

const ORIGIN = "https://accounts.herdrup.app";
const DAY_MS = 24 * 60 * 60 * 1000;

// Statements are issued with one signing key in slot A, as in test/devices.test.ts.
beforeAll(async () => {
  // workers-types types generateKey and exportKey as unions; an Ed25519 pair and a pkcs8 export have these shapes.
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  env.STATEMENT_KEY_A = btoa(String.fromCharCode(...new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer)));
  env.STATEMENT_KID_A = "test-a";
  env.STATEMENT_ACTIVE = "A";
});

interface Party {
  accountId: string;
  access: string;
  key: X25519Key;
  pub: string;
  id: string;
}

async function newAccount(): Promise<string> {
  return (await findOrCreateAccount(env.DB, "apple", randomB64url(32), Date.now())).accountId;
}

function call(method: string, path: string, party?: { access: string }, body?: unknown, headers: Record<string, string> = {}): Promise<Response> {
  const all: Record<string, string> = { "content-type": "application/json", ...headers };
  if (party !== undefined) all.Authorization = `Bearer ${party.access}`;
  return SELF.fetch(`${ORIGIN}${path}`, { method, headers: all, body: body === undefined ? undefined : JSON.stringify(body) });
}

async function rejection(response: Response): Promise<{ status: number; error: string }> {
  return { status: response.status, ...(await response.json<{ error: string }>()) };
}

/** Enrols `key` on `session` as the client does, sending `spelling` as device_pub (its canonical one unless given). */
async function enrol(session: { access: string }, platform: Platform, key: X25519Key, spelling = b64url(key.pub)): Promise<Response> {
  const issued = await (await call("POST", "/v1/devices/challenge", session)).json<{
    challenge_id: string;
    server_pub: string;
    salt: string;
    account_id: string;
  }>();
  const shared = await x25519(key.privateKey, fromB64url(issued.server_pub)!);
  const mac = await enrolMac(shared!, fromB64url(issued.salt)!, issued.account_id, spelling, issued.challenge_id);
  const name = platform === "web" ? "Chrome on macOS" : "Jerry's MacBook";
  return call("POST", "/v1/devices", session, { challenge_id: issued.challenge_id, device_pub: spelling, mac, name, platform });
}

/** A new session on `accountId` that enrols `key` (fresh unless given) as a device of `platform`. */
async function party(platform: Platform, accountId?: string, key?: X25519Key): Promise<Party> {
  const account = accountId ?? (await newAccount());
  const tokens = await openSession(env.DB, account, platform, Date.now());
  const deviceKey = key ?? (await x25519Key());
  const response = await enrol({ access: tokens.access_token }, platform, deviceKey);
  expect(response.status).toBe(201);
  const { device } = await response.json<{ device: { id: string } }>();
  return { accountId: account, access: tokens.access_token, key: deviceKey, pub: b64url(deviceKey.pub), id: device.id };
}

const nonce = () => crypto.getRandomValues(new Uint8Array(32));

interface RequestState {
  state: string;
  expires_in: number;
  approver?: { device_pub: string; name: string };
  nonce_t?: string;
  nonce_b?: string;
}

async function getRequest(caller: Party, id: string): Promise<RequestState> {
  const response = await call("GET", `/v1/approvals/${id}`, caller);
  expect(response.status).toBe(200);
  return response.json<RequestState>();
}

interface Pending {
  id: string;
  nonceB: Uint8Array;
  nonceT: Uint8Array;
}

/** Steps 1 and 2: the browser commits, the approver claims with nonce_t. */
async function claimed(browser: Party, approver: Party): Promise<Pending> {
  const nonceB = nonce();
  const created = await call("POST", "/v1/approvals", browser, { commit: b64url(await approveCommit(browser.key.pub, nonceB)) });
  expect(created.status).toBe(201);
  const { id, expires_in } = await created.json<{ id: string; expires_in: number }>();
  expect(expires_in).toBe(600);
  const nonceT = nonce();
  const claim = await call("POST", `/v1/approvals/${id}/claim`, approver, { nonce_t: b64url(nonceT) });
  expect(claim.status).toBe(200);
  return { id, nonceB, nonceT };
}

/** Steps 1 to 3: … then the browser reveals nonce_b. */
async function revealed(browser: Party, approver: Party): Promise<Pending> {
  const pending = await claimed(browser, approver);
  const reveal = await call("POST", `/v1/approvals/${pending.id}/reveal`, browser, { nonce_b: b64url(pending.nonceB) });
  expect(reveal.status).toBe(200);
  return pending;
}

const ENVELOPE = JSON.stringify({ v: 1, seq: 1, machines: [{ host_item_id: "h1", label: "dev2306", host_id: "AAAAAAAAAAAAAAAAAAAAAA" }] });

async function report(browser: Party, approver: Party, seq: number, expiresMs = Date.now() + 30 * DAY_MS) {
  return { scope: "terminal", expires_ms: expiresMs, seq, sealed: await sealEnvelope(approver.key, browser.key.pub, seq, ENVELOPE) };
}

/** The whole flow, approved with seq 1. */
async function approved(browser: Party, approver: Party): Promise<{ id: string; sealed: string }> {
  const pending = await revealed(browser, approver);
  const body = await report(browser, approver, 1);
  const finish = await call("POST", `/v1/approvals/${pending.id}/finish`, approver, { outcome: "approved", ...body });
  expect(finish.status).toBe(200);
  return { id: pending.id, sealed: body.sealed };
}

async function deviceAccess(caller: Party, deviceId: string): Promise<unknown> {
  const { devices } = await (await call("GET", "/v1/devices", caller)).json<{ devices: { id: string; access?: unknown }[] }>();
  return devices.find((device) => device.id === deviceId)?.access;
}

async function statementStatus(caller: Party): Promise<number> {
  return (await call("POST", "/v1/statements", caller, { hosts: [randomB64url(16)] })).status;
}

describe("approve-v1 vector", () => {
  it("reproduces herdrup-desktop's approve-v1-local.json byte for byte from the same inputs", async () => {
    const vector = JSON.parse(approveVectorText) as Record<string, string | number>;
    const browser = await x25519Key(fromB64url(vector.browser_priv as string)!);
    const approver = await x25519Key(fromB64url(vector.approver_priv as string)!);
    const nonceB = fromB64url(vector.nonce_b as string)!;
    const nonceT = fromB64url(vector.nonce_t as string)!;
    const seq = 7;
    const envelopeJson = JSON.stringify({ v: 1, seq, machines: [{ label: "dev2306" }] });
    // desk's deterministic reader fills the IV with 0x33.
    const sealed = await sealEnvelope(approver, browser.pub, seq, envelopeJson, new Uint8Array(12).fill(0x33));
    const generated = {
      source: "node:crypto, WIRE-PLAN approve-v1 (RFC 7748 6.1 keys)",
      browser_priv: vector.browser_priv,
      approver_priv: vector.approver_priv,
      browser_pub: b64url(browser.pub),
      approver_pub: b64url(approver.pub),
      nonce_b: b64url(nonceB),
      nonce_t: b64url(nonceT),
      commit: b64url(await approveCommit(browser.pub, nonceB)),
      code: await approveCode(browser.pub, approver.pub, nonceB, nonceT),
      seq,
      envelope_json: envelopeJson,
      sealed,
    };
    expect(`${JSON.stringify(generated, null, 1)}\n`).toBe(approveVectorText);
    expect(generated.commit).toBe("lX5iWjshMvp96y1vhYBUzOu6x8K6Tr3fLSCEOT4xekk");
    expect(generated.code).toBe("7218");
    expect(await openEnvelope(browser, approver.pub, seq, sealed)).toBe(envelopeJson);
    // seq is in the AAD: the same envelope doesn't open at another seq.
    await expect(openEnvelope(browser, approver.pub, seq + 1, sealed)).rejects.toThrow();
  });
});

describe("browser approval", () => {
  it("runs commit, claim, reveal, code and finish, and the browser gets its sealed machine list", async () => {
    const health = await (await call("GET", "/v1/health")).json<{ features: string[] }>();
    expect(health.features).toContain("web_approve");

    const approver = await party("macos");
    const browser = await party("web", approver.accountId);
    const other = await party("ios", approver.accountId);
    expect(await deviceAccess(approver, browser.id)).toBeUndefined();

    // 1. B commits and shows no code yet.
    const nonceB = nonce();
    const commit = b64url(await approveCommit(browser.key.pub, nonceB));
    const created = await call("POST", "/v1/approvals", browser, { commit });
    expect(created.status).toBe(201);
    const { id } = await created.json<{ id: string }>();
    expect(await getRequest(browser, id)).toEqual({ state: "waiting", expires_in: expect.any(Number) });
    expect(await deviceAccess(approver, browser.id)).toEqual({ state: "waiting" });

    // 2. T fetches the request and claims it with nonce_t; the approver is its session's device.
    const list = await (await call("GET", "/v1/approvals", approver)).json<{ requests: unknown[] }>();
    expect(list.requests).toEqual([
      {
        id,
        browser: { device_id: browser.id, device_pub: browser.pub, name: "Chrome on macOS", platform: "web", created_ms: expect.any(Number) },
        commit,
        claimed: "no",
        expires_in: expect.any(Number),
      },
    ]);
    const nonceT = nonce();
    expect((await call("POST", `/v1/approvals/${id}/claim`, approver, { nonce_t: b64url(nonceT), approver: other.id })).status).toBe(200);
    const listed = async (caller: Party) => (await (await call("GET", "/v1/approvals", caller)).json<{ requests: { claimed: string }[] }>()).requests[0].claimed;
    expect(await listed(approver)).toBe("you");
    expect(await listed(other)).toBe("other");

    // 3. B learns T's key and nonce_t, then reveals nonce_b and shows its code.
    const seen = await getRequest(browser, id);
    expect(seen).toEqual({
      state: "claimed",
      expires_in: expect.any(Number),
      approver: { device_pub: approver.pub, name: "Jerry's MacBook" },
      nonce_t: b64url(nonceT),
    });
    expect((await call("POST", `/v1/approvals/${id}/reveal`, browser, { nonce_b: b64url(nonceB) })).status).toBe(200);
    const browserCode = await approveCode(browser.key.pub, fromB64url(seen.approver!.device_pub)!, nonceB, fromB64url(seen.nonce_t!)!);

    // 4. T gets nonce_b (only the claimant does), checks it opens the commit, computes the code.
    const atApprover = await getRequest(approver, id);
    expect(atApprover.state).toBe("revealed");
    expect((await getRequest(other, id)).nonce_b).toBeUndefined();
    expect((await getRequest(browser, id)).nonce_b).toBeUndefined();
    const revealedNonce = fromB64url(atApprover.nonce_b!)!;
    expect(b64url(await approveCommit(browser.key.pub, revealedNonce))).toBe(commit);
    const approverCode = await approveCode(browser.key.pub, approver.key.pub, revealedNonce, nonceT);

    // 5. The user types the browser's code on T; it matches, so T approves and seals.
    expect(approverCode).toBe(browserCode);
    expect(approverCode).toMatch(/^\d{4}$/);
    const expiresMs = Date.now() + 30 * DAY_MS;
    const sealed = await sealEnvelope(approver.key, browser.key.pub, 1, ENVELOPE);
    const finish = await call("POST", `/v1/approvals/${id}/finish`, approver, { outcome: "approved", scope: "terminal", expires_ms: expiresMs, seq: 1, sealed });
    expect(finish.status).toBe(200);
    expect(await finish.json()).toEqual({ state: "approved" });

    expect((await getRequest(browser, id)).state).toBe("approved");
    expect(await deviceAccess(other, browser.id)).toEqual({ state: "approved", scope: "terminal", expires_ms: expiresMs });
    const self = await (await call("GET", "/v1/browsers/self", browser)).json<{ access: unknown; envelopes: { approver_pub: string; seq: number; sealed: string }[] }>();
    expect(self).toEqual({ access: { state: "approved", scope: "terminal", expires_ms: expiresMs }, envelopes: [{ approver_pub: approver.pub, seq: 1, sealed }] });
    // The browser accepts it only from the key it verified with the code.
    expect(await openEnvelope(browser.key, fromB64url(self.envelopes[0].approver_pub)!, 1, self.envelopes[0].sealed)).toBe(ENVELOPE);
    // Nothing is listed for approvers any more, and the browser still gets statements.
    expect((await (await call("GET", "/v1/approvals", approver)).json<{ requests: unknown[] }>()).requests).toEqual([]);
    expect(await statementStatus(browser)).toBe(200);

    // Renewal from the same approver: a new envelope at seq + 1, no code.
    const renewal = await report(browser, approver, 2, Date.now() + 7 * DAY_MS);
    expect((await call("PUT", `/v1/browsers/${browser.id}/envelope`, approver, { ...renewal, scope: "chat" })).status).toBe(200);
    expect(await deviceAccess(browser, browser.id)).toEqual({ state: "approved", scope: "chat", expires_ms: renewal.expires_ms });
    // An approver the browser never verified can't post one.
    expect(await rejection(await call("PUT", `/v1/browsers/${browser.id}/envelope`, other, await report(browser, other, 9)))).toEqual({
      status: 403,
      error: "not_approver",
    });
  });

  it("refuses a tampered reveal and ends the request", async () => {
    const approver = await party("linux");
    const browser = await party("web", approver.accountId);
    const nonceB = nonce();
    const { id } = await (await call("POST", "/v1/approvals", browser, { commit: b64url(await approveCommit(browser.key.pub, nonceB)) })).json<{ id: string }>();
    // B never reveals before T has sent nonce_t.
    expect(await rejection(await call("POST", `/v1/approvals/${id}/reveal`, browser, { nonce_b: b64url(nonceB) }))).toEqual({ status: 409, error: "not_claimed" });
    expect((await call("POST", `/v1/approvals/${id}/claim`, approver, { nonce_t: b64url(nonce()) })).status).toBe(200);

    // A nonce_b chosen after seeing nonce_t doesn't open the commit: refused, and the request is over.
    expect(await rejection(await call("POST", `/v1/approvals/${id}/reveal`, browser, { nonce_b: b64url(nonce()) }))).toEqual({
      status: 400,
      error: "reveal_mismatch",
    });
    expect((await getRequest(approver, id)).state).toBe("denied");
    expect(await rejection(await call("POST", `/v1/approvals/${id}/reveal`, browser, { nonce_b: b64url(nonceB) }))).toEqual({
      status: 409,
      error: "already_finished",
    });
    expect(await rejection(await call("POST", `/v1/approvals/${id}/finish`, approver, { outcome: "approved", ...(await report(browser, approver, 1)) }))).toEqual({
      status: 409,
      error: "already_finished",
    });
    expect(await deviceAccess(approver, browser.id)).toBeUndefined();

    // T's own check: a nonce_b that doesn't open the commit it saw is "tampered".
    const commit = await approveCommit(browser.key.pub, nonceB);
    expect(b64url(await approveCommit(browser.key.pub, nonce()))).not.toBe(b64url(commit));
  });

  it("gives no approval for a wrong code", async () => {
    const approver = await party("macos");
    const browser = await party("web", approver.accountId);
    const pending = await revealed(browser, approver);
    const code = await approveCode(browser.key.pub, approver.key.pub, pending.nonceB, pending.nonceT);

    // A key the service substituted gives T a different code from the one the browser shows.
    const attacker = await x25519Key();
    expect(await approveCode(attacker.pub, approver.key.pub, pending.nonceB, pending.nonceT)).not.toBe(code);
    // And B, shown a fake approver key, computes a different code from T's.
    expect(await approveCode(browser.key.pub, attacker.pub, pending.nonceB, pending.nonceT)).not.toBe(code);

    // The user types a code that doesn't match: T denies, and the request can't be approved after.
    const typed = String((Number(code) + 1) % 10000).padStart(4, "0");
    expect(typed).not.toBe(code);
    const deny = await call("POST", `/v1/approvals/${pending.id}/finish`, approver, { outcome: "denied" });
    expect(await deny.json()).toEqual({ state: "denied" });
    expect(await getRequest(browser, pending.id)).toEqual({
      state: "denied",
      expires_in: expect.any(Number),
      approver: { device_pub: approver.pub, name: "Jerry's MacBook" },
    });
    expect((await call("POST", `/v1/approvals/${pending.id}/finish`, approver, { outcome: "approved", ...(await report(browser, approver, 1)) })).status).toBe(409);
    expect(await deviceAccess(approver, browser.id)).toBeUndefined();
    expect(await (await call("GET", "/v1/browsers/self", browser)).json()).toEqual({ envelopes: [] });

    // Approval needs the reveal: without nonce_b, T can't have checked a code.
    const unrevealed = await claimed(browser, approver);
    expect(
      await rejection(await call("POST", `/v1/approvals/${unrevealed.id}/finish`, approver, { outcome: "approved", ...(await report(browser, approver, 1)) })),
    ).toEqual({ status: 409, error: "not_revealed" });
  });

  it("refuses replays of every step and of an envelope", async () => {
    const approver = await party("macos");
    const second = await party("windows", approver.accountId);
    const browser = await party("web", approver.accountId);
    const pending = await claimed(browser, approver);
    for (const claimant of [approver, second]) {
      expect(await rejection(await call("POST", `/v1/approvals/${pending.id}/claim`, claimant, { nonce_t: b64url(nonce()) }))).toEqual({
        status: 409,
        error: "already_claimed",
      });
    }
    const reveal = { nonce_b: b64url(pending.nonceB) };
    expect((await call("POST", `/v1/approvals/${pending.id}/reveal`, browser, reveal)).status).toBe(200);
    expect(await rejection(await call("POST", `/v1/approvals/${pending.id}/reveal`, browser, reveal))).toEqual({ status: 409, error: "already_revealed" });
    // Only the claimant finishes.
    const body = { outcome: "approved", ...(await report(browser, approver, 5)) };
    expect((await call("POST", `/v1/approvals/${pending.id}/finish`, second, body)).status).toBe(404);
    expect((await call("POST", `/v1/approvals/${pending.id}/finish`, approver, body)).status).toBe(200);
    expect(await rejection(await call("POST", `/v1/approvals/${pending.id}/finish`, approver, body))).toEqual({ status: 409, error: "already_finished" });
    expect(await rejection(await call("POST", `/v1/approvals/${pending.id}/claim`, second, { nonce_t: b64url(nonce()) }))).toEqual({
      status: 409,
      error: "already_finished",
    });

    // Envelopes only move forward per approver.
    const put = (seq: number, sealed?: string) =>
      report(browser, approver, seq).then((next) => call("PUT", `/v1/browsers/${browser.id}/envelope`, approver, { ...next, ...(sealed === undefined ? {} : { sealed }) }));
    expect(await rejection(await put(5, body.sealed))).toEqual({ status: 409, error: "stale_seq" });
    expect(await rejection(await put(4))).toEqual({ status: 409, error: "stale_seq" });
    expect((await put(6)).status).toBe(200);
    expect(await rejection(await put(6))).toEqual({ status: 409, error: "stale_seq" });

    // A new request replaces the browser's live one: the old id is gone.
    const first = await claimed(browser, approver);
    const replacement = await call("POST", "/v1/approvals", browser, { commit: b64url(await approveCommit(browser.key.pub, nonce())) });
    expect(replacement.status).toBe(201);
    expect((await call("POST", `/v1/approvals/${first.id}/reveal`, browser, { nonce_b: b64url(first.nonceB) })).status).toBe(404);
  });

  it("expires a request after 10 minutes, and the cron removes it", async () => {
    const approver = await party("macos");
    const browser = await party("web", approver.accountId);
    const pending = await claimed(browser, approver);
    await env.DB.prepare("UPDATE approval_requests SET exp_ms = ? WHERE id = ?").bind(Date.now() - 1, pending.id).run();
    expect(await getRequest(browser, pending.id)).toMatchObject({ state: "expired", expires_in: 0 });
    expect((await getRequest(browser, pending.id)).nonce_t).toBeUndefined();
    expect(await rejection(await call("POST", `/v1/approvals/${pending.id}/reveal`, browser, { nonce_b: b64url(pending.nonceB) }))).toEqual({
      status: 410,
      error: "expired",
    });
    expect(await rejection(await call("POST", `/v1/approvals/${pending.id}/finish`, approver, { outcome: "denied" }))).toEqual({ status: 410, error: "expired" });
    expect((await (await call("GET", "/v1/approvals", approver)).json<{ requests: unknown[] }>()).requests).toEqual([]);
    expect(await deviceAccess(approver, browser.id)).toBeUndefined();

    // Kept while its hour window counts towards the cap, then deleted.
    await cleanup(env.DB, Date.now());
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM approval_requests WHERE id = ?").bind(pending.id).first("n")).toBe(1);
    await cleanup(env.DB, Date.now() + 61 * 60 * 1000);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM approval_requests WHERE id = ?").bind(pending.id).first("n")).toBe(0);

    // Reported access shows as expired once its expiry passes.
    await approved(browser, approver);
    await env.DB.prepare("UPDATE browser_access SET expires_ms = ? WHERE device_id = ?").bind(Date.now() - 1, browser.id).run();
    expect(await deviceAccess(approver, browser.id)).toMatchObject({ state: "expired", scope: "terminal" });
  });

  describe("a reported expiry is final", () => {
    const outcome = (id: string) => env.DB.prepare("SELECT outcome FROM approval_requests WHERE id = ?").bind(id).first("outcome");
    const expire = async (id: string) => {
      const expMs = Date.now() - 1;
      await env.DB.prepare("UPDATE approval_requests SET exp_ms = ? WHERE id = ?").bind(expMs, id).run();
      return expMs;
    };
    /** A finish that started before the expiry (its nowMs), running only now: a slow Worker run. */
    const lateFinish = (approver: Party, id: string, body: unknown, nowMs: number) =>
      handleFinish(
        new Request(`${ORIGIN}/v1/approvals/${id}/finish`, {
          method: "POST",
          headers: { "content-type": "application/json", Authorization: `Bearer ${approver.access}` },
          body: JSON.stringify(body),
        }),
        env,
        id,
        nowMs,
      );

    it("lists approval_expiry_final in health", async () => {
      const health = await (await call("GET", "/v1/health")).json<{ features: string[] }>();
      expect(health.features).toContain("approval_expiry_final");
    });

    it("stores the expiry the first time the request is read after it", async () => {
      const approver = await party("macos");
      const browser = await party("web", approver.accountId);
      const pending = await claimed(browser, approver);
      await expire(pending.id);
      expect(await outcome(pending.id)).toBeNull();
      expect(await getRequest(browser, pending.id)).toMatchObject({ state: "expired", expires_in: 0 });
      expect(await outcome(pending.id)).toBe("expired");
      expect(await getRequest(approver, pending.id)).toMatchObject({ state: "expired" });

      // The browser's polling path (Devices, self) and the approver's list store it too.
      for (const path of ["/v1/browsers/self", "/v1/devices", "/v1/approvals"]) {
        const other = await claimed(await party("web", approver.accountId), approver);
        await expire(other.id);
        const caller = path === "/v1/browsers/self" ? browser : approver;
        expect((await call("GET", path, caller)).status, path).toBe(200);
        expect(await outcome(other.id), path).toBe("expired");
      }
    });

    it("refuses a finish that started before the expiry once a read has stored it, and writes nothing", async () => {
      const approver = await party("macos");
      const browser = await party("web", approver.accountId);
      const pending = await revealed(browser, approver);
      const body = { outcome: "approved", ...(await report(browser, approver, 1)) };
      const expMs = await expire(pending.id);
      expect((await getRequest(browser, pending.id)).state).toBe("expired");

      const late = await lateFinish(approver, pending.id, body, expMs - 1000);
      expect(await rejection(late)).toEqual({ status: 410, error: "expired" });
      expect(await outcome(pending.id)).toBe("expired");
      expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM browser_envelopes WHERE device_id = ?").bind(browser.id).first("n")).toBe(0);
      expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM browser_access WHERE device_id = ?").bind(browser.id).first("n")).toBe(0);
      expect((await getRequest(browser, pending.id)).state).toBe("expired");
    });

    it("refuses a deny that started before the expiry once a read has stored it", async () => {
      const approver = await party("macos");
      const browser = await party("web", approver.accountId);
      const pending = await claimed(browser, approver);
      const expMs = await expire(pending.id);
      expect((await getRequest(approver, pending.id)).state).toBe("expired");

      const late = await lateFinish(approver, pending.id, { outcome: "denied" }, expMs - 1000);
      expect(await rejection(late)).toEqual({ status: 410, error: "expired" });
      expect(await outcome(pending.id)).toBe("expired");
      expect((await getRequest(browser, pending.id)).state).toBe("expired");
    });
  });

  it("refuses another account's approver and keeps each role to its side", async () => {
    const approver = await party("macos");
    const browser = await party("web", approver.accountId);
    const stranger = await party("macos");
    const strangerBrowser = await party("web", stranger.accountId);
    const nonceB = nonce();
    const { id } = await (await call("POST", "/v1/approvals", browser, { commit: b64url(await approveCommit(browser.key.pub, nonceB)) })).json<{ id: string }>();

    expect((await (await call("GET", "/v1/approvals", stranger)).json<{ requests: unknown[] }>()).requests).toEqual([]);
    expect((await call("GET", `/v1/approvals/${id}`, stranger)).status).toBe(404);
    expect((await call("GET", `/v1/approvals/${id}`, strangerBrowser)).status).toBe(404);
    expect(await rejection(await call("POST", `/v1/approvals/${id}/claim`, stranger, { nonce_t: b64url(nonce()) }))).toEqual({ status: 404, error: "not_found" });
    expect(await rejection(await call("POST", `/v1/approvals/${id}/finish`, stranger, { outcome: "denied" }))).toEqual({ status: 404, error: "not_found" });
    expect((await call("PUT", `/v1/browsers/${browser.id}/envelope`, stranger, await report(browser, stranger, 1))).status).toBe(404);

    // Browsers can't approve, and approvers can't ask.
    const sibling = await party("web", approver.accountId);
    expect(await rejection(await call("POST", `/v1/approvals/${id}/claim`, sibling, { nonce_t: b64url(nonce()) }))).toEqual({ status: 403, error: "not_an_approver" });
    expect((await call("GET", `/v1/approvals/${id}`, sibling)).status).toBe(404);
    expect(await rejection(await call("POST", "/v1/approvals", approver, { commit: b64url(nonce()) }))).toEqual({ status: 403, error: "not_a_browser" });
    expect(await rejection(await call("GET", "/v1/withdrawals", browser))).toEqual({ status: 403, error: "not_an_approver" });
    // A session without a device has no role at all.
    const bare = { access: (await openSession(env.DB, approver.accountId, "macos", Date.now())).access_token };
    expect(await rejection(await call("GET", "/v1/approvals", bare))).toEqual({ status: 403, error: "device_required" });

    // The request is untouched: the account's own approver can still claim it.
    expect((await call("POST", `/v1/approvals/${id}/claim`, approver, { nonce_t: b64url(nonce()) })).status).toBe(200);
  });

  it("stores the sealed envelope as sent and returns it only to that browser", async () => {
    const approver = await party("macos");
    const browser = await party("web", approver.accountId);
    const otherBrowser = await party("web", approver.accountId);
    const { id, sealed } = await approved(browser, approver);

    const stored = await env.DB.prepare("SELECT sealed, seq FROM browser_envelopes WHERE device_id = ?").bind(browser.id).first<{ sealed: string; seq: number }>();
    expect(stored).toEqual({ sealed, seq: 1 });
    // Ciphertext only: the machine list isn't in the row in any form.
    expect(stored!.sealed).not.toContain("dev2306");
    expect(new TextDecoder().decode(fromB64url(stored!.sealed)!)).not.toContain("dev2306");

    for (const caller of [approver, otherBrowser]) {
      for (const path of ["/v1/devices", "/v1/withdrawals", `/v1/approvals/${id}`, "/v1/approvals"]) {
        const response = await call("GET", path, caller);
        expect(await response.text()).not.toContain(sealed);
      }
    }
    expect(await rejection(await call("GET", "/v1/browsers/self", approver))).toEqual({ status: 403, error: "not_a_browser" });
    expect(await (await call("GET", "/v1/browsers/self", otherBrowser)).json()).toEqual({ envelopes: [] });
    const self = await (await call("GET", "/v1/browsers/self", browser)).json<{ envelopes: { sealed: string }[] }>();
    expect(self.envelopes.map((envelope) => envelope.sealed)).toEqual([sealed]);

    // Malformed envelopes are refused: padding, too short, too long.
    const pending = await revealed(otherBrowser, approver);
    const good = await report(otherBrowser, approver, 1);
    for (const bad of [`${good.sealed}=`, b64url(new Uint8Array(27)), "A".repeat(16 * 1024 + 4)]) {
      const response = await call("POST", `/v1/approvals/${pending.id}/finish`, approver, { outcome: "approved", ...good, sealed: bad });
      expect(response.status, bad.slice(0, 8)).not.toBe(200);
    }
    expect((await call("POST", `/v1/approvals/${pending.id}/finish`, approver, { outcome: "approved", ...good, scope: "admin" })).status).toBe(400);
    expect((await call("POST", `/v1/approvals/${pending.id}/finish`, approver, { outcome: "approved", ...good, expires_ms: Date.now() + 31 * DAY_MS })).status).toBe(400);
  });

  it("issues no statement for a removed browser, even enrolled again, until it is approved again", async () => {
    const approver = await party("macos");
    const browserKey = await x25519Key();
    const browser = await party("web", approver.accountId, browserKey);
    await approved(browser, approver);
    expect(await statementStatus(browser)).toBe(200);

    expect((await call("DELETE", `/v1/devices/${browser.id}`, approver)).status).toBe(204);
    // Its sessions ended with it, and its access, envelopes and request went too.
    expect(await statementStatus(browser)).toBe(401);
    for (const table of ["browser_access", "browser_envelopes"]) {
      expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE device_id = ?`).bind(browser.id).first("n")).toBe(0);
    }
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM approval_requests WHERE browser_device_id = ?").bind(browser.id).first("n")).toBe(0);
    const digest = hex(await crypto.subtle.digest("SHA-256", browserKey.pub));
    const print = `SHA256:${digest.slice(0, 4)}·${digest.slice(4, 8)}·${digest.slice(8, 12)}·${digest.slice(12, 16)}`;
    expect(await fingerprint(browserKey.pub)).toBe(print);
    const { withdrawals } = await (await call("GET", "/v1/withdrawals", approver)).json<{ withdrawals: unknown[] }>();
    expect(withdrawals).toEqual([{ device_pub: browser.pub, fingerprint: print, created_ms: expect.any(Number) }]);

    // The same browser signs in and enrols its key again: still no statement for that key.
    const again = await party("web", approver.accountId, browserKey);
    expect(await rejection(await call("POST", "/v1/statements", again, { hosts: [randomB64url(16)] }))).toEqual({ status: 403, error: "device_withdrawn" });
    // Approved again by code: statements again, and the withdrawal is gone.
    await approved(again, approver);
    expect(await statementStatus(again)).toBe(200);
    expect((await (await call("GET", "/v1/withdrawals", approver)).json<{ withdrawals: unknown[] }>()).withdrawals).toEqual([]);

    // A withdrawal lasts 35 days, then statements come back on their own.
    expect((await call("DELETE", `/v1/devices/${again.id}`, approver)).status).toBe(204);
    const third = await party("web", approver.accountId, browserKey);
    expect(await statementStatus(third)).toBe(403);
    await env.DB.prepare("UPDATE withdrawals SET exp_ms = ? WHERE device_pub = ?").bind(Date.now() - 1, browser.pub).run();
    expect(await statementStatus(third)).toBe(200);
    await cleanup(env.DB, Date.now());
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM withdrawals WHERE device_pub = ?").bind(browser.pub).first("n")).toBe(0);

    // A browser that never had access leaves no withdrawal; and any device, a browser included,
    // still removes any other device.
    const plain = await party("web", approver.accountId);
    expect((await call("DELETE", `/v1/devices/${plain.id}`, third)).status).toBe(204);
    expect((await (await call("GET", "/v1/withdrawals", approver)).json<{ withdrawals: unknown[] }>()).withdrawals).toEqual([]);
    expect((await call("DELETE", `/v1/devices/${approver.id}`, third)).status).toBe(204);
  });

  it("withdraws a browser removed with a claimed request: its approver may already have written grants", async () => {
    const approver = await party("macos");
    const browser = await party("web", approver.accountId);
    await claimed(browser, approver);
    expect((await call("DELETE", `/v1/devices/${browser.id}`, approver)).status).toBe(204);
    expect((await (await call("GET", "/v1/withdrawals", approver)).json<{ withdrawals: { device_pub: string }[] }>()).withdrawals.map((w) => w.device_pub)).toEqual([
      browser.pub,
    ]);
  });

  it("withdraws a browser whose claimed request was replaced, or whose approver was removed, before it went", async () => {
    const withdrawn = async (caller: Party) =>
      (await (await call("GET", "/v1/withdrawals", caller)).json<{ withdrawals: { device_pub: string }[] }>()).withdrawals.map((w) => w.device_pub);

    // Claimed, then the browser asks again: the new request has no approver, the claim still counts.
    const approver = await party("macos");
    const replaced = await party("web", approver.accountId);
    await claimed(replaced, approver);
    expect((await call("POST", "/v1/approvals", replaced, { commit: b64url(nonce()) })).status).toBe(201);
    expect((await call("DELETE", `/v1/devices/${replaced.id}`, approver)).status).toBe(204);
    expect(await withdrawn(approver)).toEqual([replaced.pub]);
    const again = await party("web", approver.accountId, replaced.key);
    expect(await rejection(await call("POST", "/v1/statements", again, { hosts: [randomB64url(16)] }))).toEqual({ status: 403, error: "device_withdrawn" });

    // Claimed, then the approver is removed (by the browser itself: any device removes any
    // other), which deletes the request; then the browser is removed.
    const first = await party("linux");
    const keeper = await party("ios", first.accountId);
    const orphaned = await party("web", first.accountId);
    await claimed(orphaned, first);
    expect((await call("DELETE", `/v1/devices/${first.id}`, orphaned)).status).toBe(204);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM approval_requests WHERE browser_device_id = ?").bind(orphaned.id).first("n")).toBe(0);
    expect((await call("DELETE", `/v1/devices/${orphaned.id}`, keeper)).status).toBe(204);
    expect(await withdrawn(keeper)).toEqual([orphaned.pub]);
    const back = await party("web", first.accountId, orphaned.key);
    expect(await statementStatus(back)).toBe(403);
  });

  it("refuses a non-canonical spelling of a device key, so the withdrawal block can't be dodged", async () => {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    // The last of 43 characters carries 4 bits and 2 unused ones: the next letter spells the same 32 bytes.
    const respell = (pub: string) => pub.slice(0, 42) + alphabet[alphabet.indexOf(pub[42]) + 1];
    const approver = await party("macos");
    const browser = await party("web", approver.accountId);
    const flipped = respell(browser.pub);
    expect(flipped).not.toBe(browser.pub);
    expect(fromB64url(flipped)).toEqual(fromB64url(browser.pub));

    await approved(browser, approver);
    expect((await call("DELETE", `/v1/devices/${browser.id}`, approver)).status).toBe(204);
    const session = { access: (await openSession(env.DB, approver.accountId, "web", Date.now())).access_token };
    expect(await rejection(await enrol(session, "web", browser.key, flipped))).toEqual({ status: 400, error: "bad_request" });
    expect(await rejection(await call("POST", "/v1/statements", session, { hosts: [randomB64url(16)] }))).toEqual({ status: 403, error: "device_required" });
    // The canonical spelling enrols, and is still withdrawn.
    expect((await enrol(session, "web", browser.key)).status).toBe(201);
    expect(await rejection(await call("POST", "/v1/statements", session, { hosts: [randomB64url(16)] }))).toEqual({ status: 403, error: "device_withdrawn" });

    // Any key, withdrawn or not: one spelling only.
    const fresh = await x25519Key();
    const other = { access: (await openSession(env.DB, approver.accountId, "ios", Date.now())).access_token };
    expect((await enrol(other, "ios", fresh, respell(b64url(fresh.pub)))).status).toBe(400);
  });

  it("rolls a failed finish back whole, so the approver can retry it", async () => {
    const approver = await party("macos");
    const browser = await party("web", approver.accountId);
    const pending = await revealed(browser, approver);
    const body = { outcome: "approved", ...(await report(browser, approver, 1)) };
    // The access write fails after the envelope write, inside the batch.
    await env.DB.prepare("CREATE TRIGGER fail_access BEFORE INSERT ON browser_access BEGIN SELECT RAISE(ABORT, 'injected'); END").run();
    try {
      expect(await rejection(await call("POST", `/v1/approvals/${pending.id}/finish`, approver, body))).toEqual({ status: 500, error: "internal_error" });
    } finally {
      await env.DB.prepare("DROP TRIGGER fail_access").run();
    }
    expect((await getRequest(approver, pending.id)).state).toBe("revealed");
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM browser_envelopes WHERE device_id = ?").bind(browser.id).first("n")).toBe(0);
    expect((await call("POST", `/v1/approvals/${pending.id}/finish`, approver, body)).status).toBe(200);
    expect((await getRequest(browser, pending.id)).state).toBe("approved");
    expect(await deviceAccess(approver, browser.id)).toMatchObject({ state: "approved", scope: "terminal" });
  });

  it("writes the reported access only when the envelope advances", async () => {
    const approver = await party("macos");
    const browser = await party("web", approver.accountId);
    await approved(browser, approver);
    const before = await deviceAccess(approver, browser.id);
    // A report that loses the seq race after the handler's own check: the batch runs, the
    // envelope doesn't move, and neither does the access Devices shows.
    const gate = env.DB.prepare("UPDATE browser_envelopes SET seq = seq WHERE device_id = ? AND approver_pub = ?").bind(browser.id, approver.pub);
    const stale = { scope: "chat" as const, expiresMs: Date.now() + DAY_MS, seq: 1, sealed: await sealEnvelope(approver.key, browser.key.pub, 1, ENVELOPE) };
    const results = await env.DB.batch(reportStatements(env.DB, gate, approver.accountId, browser.id, approver.pub, stale, Date.now()));
    expect(results.map((result) => result.meta.changes)).toEqual([1, 0, 0]);
    expect(await deviceAccess(approver, browser.id)).toEqual(before);
    // And a gate that doesn't hold writes nothing at all.
    const closed = env.DB.prepare("UPDATE browser_envelopes SET seq = seq WHERE device_id = ? AND approver_pub = ?").bind(browser.id, randomB64url(32));
    const ahead = { ...stale, seq: 2 };
    expect((await env.DB.batch(reportStatements(env.DB, closed, approver.accountId, browser.id, approver.pub, ahead, Date.now()))).map((r) => r.meta.changes)).toEqual([0, 0, 0]);
    expect(await env.DB.prepare("SELECT seq FROM browser_envelopes WHERE device_id = ?").bind(browser.id).first("seq")).toBe(1);
  });

  it("rate-limits every approval route per account (APPROVAL_LIMIT) and caps requests per hour", async () => {
    const approver = await party("macos");
    const browser = await party("web", approver.accountId);
    for (let i = 0; i < 15; i++) expect((await call("GET", "/v1/browsers/self", browser)).status).toBe(200);
    for (let i = 0; i < 15; i++) expect((await call("GET", "/v1/approvals", approver)).status).toBe(200);
    expect(await rejection(await call("GET", "/v1/withdrawals", approver))).toEqual({ status: 429, error: "rate_limited" });
    expect(await rejection(await call("POST", "/v1/approvals", browser, { commit: b64url(nonce()) }))).toEqual({ status: 429, error: "rate_limited" });
    // Other routes only count against ACCOUNT_LIMIT.
    expect((await call("GET", "/v1/devices", approver)).status).toBe(200);
  });

  it(`caps an account at ${MAX_REQUESTS_PER_HOUR} requests an hour across its browsers`, async () => {
    const first = await party("web");
    const second = await party("web", first.accountId);
    const ask = (browser: Party) => call("POST", "/v1/approvals", browser, { commit: b64url(nonce()) });
    for (let i = 0; i < 6; i++) expect((await ask(first)).status).toBe(201);
    for (let i = 0; i < 4; i++) expect((await ask(second)).status).toBe(201);
    expect(await rejection(await ask(first))).toEqual({ status: 429, error: "too_many_requests" });
    expect(await rejection(await ask(second))).toEqual({ status: 429, error: "too_many_requests" });
    // The browser's live request is still the last one it made.
    expect(await env.DB.prepare("SELECT starts FROM approval_requests WHERE browser_device_id = ?").bind(first.id).first("starts")).toBe(6);
    // Once the hour is over, it can ask again.
    await env.DB.prepare("UPDATE approval_requests SET starts_ms = starts_ms - ? WHERE account_id = ?").bind(61 * 60 * 1000, first.accountId).run();
    expect((await ask(first)).status).toBe(201);
    expect(await env.DB.prepare("SELECT starts FROM approval_requests WHERE browser_device_id = ?").bind(first.id).first("starts")).toBe(1);
  });

  it("allows the browser's calls from the web guest (CORS) and not the approver's", async () => {
    const preflight = (path: string, method: string) =>
      SELF.fetch(`${ORIGIN}${path}`, {
        method: "OPTIONS",
        headers: { Origin: env.WEB_ORIGIN, "Access-Control-Request-Method": method, "Access-Control-Request-Headers": "authorization, content-type" },
      });
    const id = randomB64url(16);
    for (const [path, method] of [
      ["/v1/approvals", "POST"],
      [`/v1/approvals/${id}`, "GET"],
      [`/v1/approvals/${id}/reveal`, "POST"],
      ["/v1/browsers/self", "GET"],
    ]) {
      const response = await preflight(path, method);
      expect(response.status, path).toBe(204);
      expect(response.headers.get("Access-Control-Allow-Origin")).toBe(env.WEB_ORIGIN);
    }
    for (const [path, method] of [
      ["/v1/approvals", "GET"],
      [`/v1/approvals/${id}/claim`, "POST"],
      [`/v1/approvals/${id}/finish`, "POST"],
      [`/v1/browsers/${id}/envelope`, "PUT"],
      ["/v1/withdrawals", "GET"],
    ]) {
      expect((await preflight(path, method)).headers.get("Access-Control-Allow-Origin"), `${method} ${path}`).toBeNull();
    }
    // The approver list answers the web guest's origin without CORS headers.
    const approver = await party("macos");
    const listed = await call("GET", "/v1/approvals", approver, undefined, { Origin: env.WEB_ORIGIN });
    expect(listed.status).toBe(200);
    expect(listed.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });
});
