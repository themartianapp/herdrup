import { SELF, env } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { findOrCreateAccount } from "../src/auth";
import { handleFinish, pairCommit } from "../src/approvals";
import { b64url, fromB64url, randomB64url } from "../src/bytes";
import { enrolMac, x25519 } from "../src/devices";
import { openSession, type Platform } from "../src/sessions";
import { openEnvelopeAs, pairCode, PAIR_ENVELOPE_LABEL, sealEnvelopeAs, x25519Key, type X25519Key } from "./approve_v1";
import pairVectorText from "./vectors/pair-v1.json?raw";

// pair-v1 (DESIGN.md §13) against the real Worker and a local D1 in workerd. Each party is a
// session with an enrolled device; the new device and the approver run the protocol's client
// side (test/approve_v1.ts). PushRelay is a fetch spy: nothing reaches the network.

const ORIGIN = "https://accounts.herdrup.app";
const RELAY_SEND = "https://push.herdrup.app/v1/send";

interface Party {
  accountId: string;
  access: string;
  key: X25519Key;
  pub: string;
  id: string;
  name: string;
}

function call(method: string, path: string, party?: { access: string }, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (party !== undefined) headers.Authorization = `Bearer ${party.access}`;
  return SELF.fetch(`${ORIGIN}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
}

async function rejection(response: Response): Promise<{ status: number; error: string }> {
  return { status: response.status, ...(await response.json<{ error: string }>()) };
}

/** A new session on `accountId` (a new account unless given) that enrols a fresh key as a device of `platform`. */
async function party(platform: Platform, accountId?: string, name = `${platform} ${randomB64url(3)}`): Promise<Party> {
  const account = accountId ?? (await findOrCreateAccount(env.DB, "apple", randomB64url(32), Date.now())).accountId;
  const access = (await openSession(env.DB, account, platform, Date.now())).access_token;
  const key = await x25519Key();
  const pub = b64url(key.pub);
  const issued = await (await call("POST", "/v1/devices/challenge", { access })).json<{
    challenge_id: string;
    server_pub: string;
    salt: string;
    account_id: string;
  }>();
  const shared = await x25519(key.privateKey, fromB64url(issued.server_pub)!);
  const mac = await enrolMac(shared!, fromB64url(issued.salt)!, issued.account_id, pub, issued.challenge_id);
  const response = await call("POST", "/v1/devices", { access }, { challenge_id: issued.challenge_id, device_pub: pub, mac, name, platform });
  expect(response.status).toBe(201);
  const { device } = await response.json<{ device: { id: string } }>();
  return { accountId: account, access, key, pub, id: device.id, name };
}

const random32 = () => crypto.getRandomValues(new Uint8Array(32));

interface Pending {
  id: string;
  sshPub: Uint8Array;
  nonceB: Uint8Array;
  nonceT: Uint8Array;
}

/** N makes S and nonce_b and posts its pair request. */
async function ask(requester: Party, sshPub = random32()): Promise<Pending> {
  const nonceB = random32();
  const commit = b64url(await pairCommit(requester.key.pub, sshPub, nonceB));
  const created = await call("POST", "/v1/approvals", requester, { kind: "pair", commit, ssh_pub: b64url(sshPub) });
  expect(created.status).toBe(201);
  const { id, expires_in } = await created.json<{ id: string; expires_in: number }>();
  expect(expires_in).toBe(600);
  return { id, sshPub, nonceB, nonceT: random32() };
}

/** … A claims it, and N reveals. */
async function revealed(requester: Party, approver: Party): Promise<Pending> {
  const pending = await ask(requester);
  expect((await call("POST", `/v1/approvals/${pending.id}/claim`, approver, { nonce_t: b64url(pending.nonceT) })).status).toBe(200);
  expect((await call("POST", `/v1/approvals/${pending.id}/reveal`, requester, { nonce_b: b64url(pending.nonceB) })).status).toBe(200);
  return pending;
}

const machines = (status: string) =>
  JSON.stringify({ v: 1, machines: [{ nickname: "dev2306", host: "100.64.0.7", port: 22, user: "jerry", host_key: HOST_KEY, status }] });
const HOST_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID1AF8PoQ4lakrcKp00bfrycmCzPLsSWjMDNVfEq9GYM";

async function envelope(approver: Party, requester: Party, seq: number, status = "added") {
  return { seq, sealed: await sealEnvelopeAs(PAIR_ENVELOPE_LABEL, approver.key, requester.key.pub, seq, machines(status)) };
}

async function approved(requester: Party, approver: Party): Promise<Pending> {
  const pending = await revealed(requester, approver);
  const finish = await call("POST", `/v1/approvals/${pending.id}/finish`, approver, { outcome: "approved", ...(await envelope(approver, requester, 1)) });
  expect(finish.status).toBe(200);
  return pending;
}

interface PairSelf {
  request?: { id: string; state: string; expires_in: number; outcome_stored?: true };
  envelopes: { request_id: string; ssh_pub: string; approver_pub: string; approver_name: string; seq: number; sealed: string }[];
}

const pairSelf = async (caller: Party) => (await call("GET", "/v1/pairs/self", caller)).json<PairSelf>();

describe("pair-v1 vector", () => {
  it("generates test/vectors/pair-v1.json byte for byte from fixed keys", async () => {
    const vector = JSON.parse(pairVectorText) as Record<string, string | number>;
    // RFC 7748 §6.1's keys, as in approve-v1.json: B is Alice's, T is Bob's.
    const requester = await x25519Key(fromB64url("dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo")!);
    const approver = await x25519Key(fromB64url("XasIfmJKikt54X-Lg4AO5m87sSkmGLb9HC-LJ_-I4Os")!);
    // S: RFC 8032 §7.1 test 1's public key.
    const sshPub = Uint8Array.from(atob("11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="), (c) => c.charCodeAt(0));
    const nonceB = new Uint8Array(32).fill(0x11);
    const nonceT = new Uint8Array(32).fill(0x22);
    const seq = 7;
    const envelopeJson = machines("added");
    const sealed = await sealEnvelopeAs(PAIR_ENVELOPE_LABEL, approver, requester.pub, seq, envelopeJson, new Uint8Array(12).fill(0x33));
    const generated = {
      source: "AccountService test/pairs.test.ts, pair-v1 (RFC 7748 6.1 keys, S = RFC 8032 7.1 test 1 public key)",
      requester_priv: "dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo",
      approver_priv: "XasIfmJKikt54X-Lg4AO5m87sSkmGLb9HC-LJ_-I4Os",
      requester_pub: b64url(requester.pub),
      approver_pub: b64url(approver.pub),
      ssh_pub: b64url(sshPub),
      nonce_b: b64url(nonceB),
      nonce_t: b64url(nonceT),
      commit: b64url(await pairCommit(requester.pub, sshPub, nonceB)),
      code: await pairCode(requester.pub, sshPub, approver.pub, nonceB, nonceT),
      seq,
      envelope_json: envelopeJson,
      sealed,
    };
    expect(`${JSON.stringify(generated, null, 1)}\n`).toBe(pairVectorText);
    expect(await openEnvelopeAs(PAIR_ENVELOPE_LABEL, requester, approver.pub, seq, vector.sealed as string)).toBe(envelopeJson);
    // seq is in the AAD, and the label is pair-v1's: approve-v1's key doesn't open it.
    await expect(openEnvelopeAs(PAIR_ENVELOPE_LABEL, requester, approver.pub, seq + 1, sealed)).rejects.toThrow();
    await expect(openEnvelopeAs("herdrup-approve-v1|envelope", requester, approver.pub, seq, sealed)).rejects.toThrow();
  });

  it("binds S: another key gives another commit and another code", async () => {
    const vector = JSON.parse(pairVectorText) as Record<string, string>;
    const [b, s, t, nb, nt] = [vector.requester_pub, vector.ssh_pub, vector.approver_pub, vector.nonce_b, vector.nonce_t].map((v) => fromB64url(v)!);
    const other = Uint8Array.from(s, (byte, i) => (i === 31 ? byte ^ 1 : byte));
    expect(await pairCode(b, s, t, nb, nt)).toBe(vector.code);
    expect(await pairCode(b, other, t, nb, nt)).not.toBe(vector.code);
    expect(b64url(await pairCommit(b, other, nb))).not.toBe(vector.commit);
  });
});

describe("pair requests", () => {
  it("runs commit, claim, reveal, code and finish, and the new device gets its sealed machine list", async () => {
    const health = await (await call("GET", "/v1/health")).json<{ features: string[] }>();
    expect(health.features).toContain("pair_v1");

    const approver = await party("macos", undefined, "Jerry's MacBook");
    const requester = await party("ios", approver.accountId, "Jerry's iPhone");
    const browser = await party("web", approver.accountId);
    expect(await pairSelf(requester)).toEqual({ envelopes: [] });

    // 1. N commits over B and S.
    const sshPub = random32();
    const nonceB = random32();
    const commit = b64url(await pairCommit(requester.key.pub, sshPub, nonceB));
    const created = await call("POST", "/v1/approvals", requester, { kind: "pair", commit, ssh_pub: b64url(sshPub) });
    expect(created.status).toBe(201);
    const { id } = await created.json<{ id: string }>();
    expect(await pairSelf(requester)).toEqual({ request: { id, state: "waiting", expires_in: expect.any(Number) }, envelopes: [] });

    // 2. A finds it in the pair list only: an app from before pair-v1 never sees it as a browser's.
    expect((await (await call("GET", "/v1/approvals", approver)).json<{ requests: unknown[] }>()).requests).toEqual([]);
    const listed = await (await call("GET", "/v1/approvals?kind=pair", approver)).json<{ requests: unknown[] }>();
    const device = { device_id: requester.id, device_pub: requester.pub, name: "Jerry's iPhone", platform: "ios" };
    expect(listed.requests).toEqual([
      { id, kind: "pair", device: { ...device, created_ms: expect.any(Number) }, commit, ssh_pub: b64url(sshPub), claimed: "no", expires_in: expect.any(Number) },
    ]);
    // N doesn't list its own request, and Devices shows no access state for it.
    expect((await (await call("GET", "/v1/approvals?kind=pair", requester)).json<{ requests: unknown[] }>()).requests).toEqual([]);
    const devices = await (await call("GET", "/v1/devices", approver)).json<{ devices: { id: string; access?: unknown }[] }>();
    expect(devices.devices.find((d) => d.id === requester.id)?.access).toBeUndefined();

    const nonceT = random32();
    expect(await (await call("POST", `/v1/approvals/${id}/claim`, approver, { nonce_t: b64url(nonceT) })).json()).toEqual({ state: "claimed" });
    // No claim mark: removing N leaves no withdrawal of its device key.
    expect(await env.DB.prepare("SELECT approval_claimed_ms FROM devices WHERE id = ?").bind(requester.id).first("approval_claimed_ms")).toBeNull();

    // 3. N reads T and nonce_t, then reveals.
    const forN = await (await call("GET", `/v1/approvals/${id}`, requester)).json<{ approver: { device_pub: string; name: string } }>();
    expect(forN).toEqual({
      state: "claimed",
      expires_in: expect.any(Number),
      approver: { device_pub: approver.pub, name: "Jerry's MacBook" },
      kind: "pair",
      commit,
      ssh_pub: b64url(sshPub),
      device,
      nonce_t: b64url(nonceT),
    });
    expect(await (await call("POST", `/v1/approvals/${id}/reveal`, requester, { nonce_b: b64url(nonceB) })).json()).toEqual({ state: "revealed" });

    // 4. A reads nonce_b, checks the commit over B and S, and both compute the same code.
    const forA = await (await call("GET", `/v1/approvals/${id}`, approver)).json<{ nonce_b: string; ssh_pub: string; device: { device_pub: string } }>();
    const b = fromB64url(forA.device.device_pub)!;
    const s = fromB64url(forA.ssh_pub)!;
    expect(b64url(await pairCommit(b, s, fromB64url(forA.nonce_b)!))).toBe(commit);
    const codeOnA = await pairCode(b, s, approver.key.pub, fromB64url(forA.nonce_b)!, nonceT);
    expect(codeOnA).toBe(await pairCode(requester.key.pub, sshPub, fromB64url(forN.approver.device_pub)!, nonceB, nonceT));
    // A browser of the account sees none of it.
    expect((await call("GET", `/v1/approvals/${id}`, browser)).status).toBe(404);

    // 5. A finishes with the sealed machine list.
    const sealed = await envelope(approver, requester, 1);
    expect(await (await call("POST", `/v1/approvals/${id}/finish`, approver, { outcome: "approved", ...sealed })).json()).toEqual({ state: "approved" });
    expect(await (await call("GET", `/v1/approvals/${id}`, requester)).json()).toMatchObject({ state: "approved", outcome_stored: true });

    // 6. N reads and opens it.
    const self = await pairSelf(requester);
    expect(self).toEqual({
      request: { id, state: "approved", expires_in: expect.any(Number), outcome_stored: true },
      envelopes: [{ request_id: id, ssh_pub: b64url(sshPub), approver_pub: approver.pub, approver_name: "Jerry's MacBook", seq: 1, sealed: sealed.sealed }],
    });
    expect(JSON.parse(await openEnvelopeAs(PAIR_ENVELOPE_LABEL, requester.key, approver.key.pub, 1, self.envelopes[0].sealed))).toMatchObject({
      v: 1,
      machines: [{ nickname: "dev2306", host_key: HOST_KEY, status: "added" }],
    });
    // Only N gets it.
    for (const caller of [approver, await party("ios", approver.accountId)]) {
      for (const path of ["/v1/approvals?kind=pair", `/v1/approvals/${id}`, "/v1/devices", "/v1/pairs/self"]) {
        expect(await (await call("GET", path, caller)).text(), path).not.toContain(sealed.sealed);
      }
    }
    // Nothing of approve-v1's browser state was written.
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM browser_envelopes WHERE device_id = ?").bind(requester.id).first("n")).toBe(0);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM browser_access WHERE device_id = ?").bind(requester.id).first("n")).toBe(0);
  });

  it("ends the request when the reveal doesn't open the commit over the stored S", async () => {
    const approver = await party("macos");
    const requester = await party("ios", approver.accountId);
    const pending = await ask(requester);
    expect((await call("POST", `/v1/approvals/${pending.id}/claim`, approver, { nonce_t: b64url(pending.nonceT) })).status).toBe(200);
    // A service that swapped S for its own key: N's nonce_b no longer opens the commit.
    await env.DB.prepare("UPDATE approval_requests SET ssh_pub = ? WHERE id = ?").bind(b64url(random32()), pending.id).run();
    expect(await rejection(await call("POST", `/v1/approvals/${pending.id}/reveal`, requester, { nonce_b: b64url(pending.nonceB) }))).toEqual({
      status: 400,
      error: "reveal_mismatch",
    });
    expect(await (await call("GET", `/v1/approvals/${pending.id}`, approver)).json()).toMatchObject({ state: "denied", outcome_stored: true });
    // So is an approve-v1 commit over B alone: S must be in it.
    const again = await ask(requester);
    const approveStyle = b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("x"))));
    await env.DB.prepare('UPDATE approval_requests SET "commit" = ? WHERE id = ?').bind(approveStyle, again.id).run();
    expect((await call("POST", `/v1/approvals/${again.id}/claim`, approver, { nonce_t: b64url(again.nonceT) })).status).toBe(200);
    expect((await call("POST", `/v1/approvals/${again.id}/reveal`, requester, { nonce_b: b64url(again.nonceB) })).status).toBe(400);
  });

  it("refuses a browser as requester or approver, and keeps browser requests to browsers", async () => {
    const approver = await party("macos");
    const browser = await party("web", approver.accountId);
    const requester = await party("windows", approver.accountId);
    const body = { kind: "pair", commit: b64url(random32()), ssh_pub: b64url(random32()) };
    expect(await rejection(await call("POST", "/v1/approvals", browser, body))).toEqual({ status: 403, error: "not_native" });
    expect(await rejection(await call("GET", "/v1/pairs/self", browser))).toEqual({ status: 403, error: "not_native" });
    // An app device without kind still asks approve-v1, which is a browser's.
    expect(await rejection(await call("POST", "/v1/approvals", requester, { commit: body.commit }))).toEqual({ status: 403, error: "not_a_browser" });
    for (const bad of [{ ...body, kind: "owner" }, { ...body, ssh_pub: undefined }, { ...body, ssh_pub: `${body.ssh_pub}=` }]) {
      expect((await call("POST", "/v1/approvals", requester, bad)).status).toBe(400);
    }
    expect((await call("GET", "/v1/approvals?kind=owner", approver)).status).toBe(400);

    const pending = await ask(requester);
    expect(await rejection(await call("POST", `/v1/approvals/${pending.id}/claim`, browser, { nonce_t: b64url(random32()) }))).toEqual({
      status: 403,
      error: "not_an_approver",
    });
    expect(await rejection(await call("GET", "/v1/approvals?kind=pair", browser))).toEqual({ status: 403, error: "not_an_approver" });
    // An app device can't reveal a browser's request.
    const browserRequest = await call("POST", "/v1/approvals", browser, { commit: b64url(random32()) });
    const { id: browserId } = await browserRequest.json<{ id: string }>();
    expect(await rejection(await call("POST", `/v1/approvals/${browserId}/reveal`, requester, { nonce_b: b64url(random32()) }))).toEqual({
      status: 403,
      error: "not_a_browser",
    });
    // Nor a device another device's pair request.
    expect((await call("POST", `/v1/approvals/${pending.id}/reveal`, approver, { nonce_b: b64url(pending.nonceB) })).status).toBe(404);
  });

  it("refuses the requester approving its own request", async () => {
    const requester = await party("ios");
    const approver = await party("macos", requester.accountId);
    const pending = await ask(requester);
    expect(await rejection(await call("POST", `/v1/approvals/${pending.id}/claim`, requester, { nonce_t: b64url(pending.nonceT) }))).toEqual({
      status: 403,
      error: "own_request",
    });
    expect(await (await call("GET", `/v1/approvals/${pending.id}`, requester)).json()).toMatchObject({ state: "waiting" });
    expect((await call("POST", `/v1/approvals/${pending.id}/finish`, requester, { outcome: "denied" })).status).toBe(404);
    // The request is untouched: another device still claims it.
    expect((await call("POST", `/v1/approvals/${pending.id}/claim`, approver, { nonce_t: b64url(pending.nonceT) })).status).toBe(200);
  });

  it("makes a reported expiry final: a finish that started earlier writes no envelope", async () => {
    const approver = await party("macos");
    const requester = await party("ios", approver.accountId);
    const pending = await revealed(requester, approver);
    const startedMs = Date.now();
    await env.DB.prepare("UPDATE approval_requests SET exp_ms = ? WHERE id = ?").bind(startedMs - 1, pending.id).run();
    expect(await pairSelf(requester)).toEqual({ request: { id: pending.id, state: "expired", expires_in: 0, outcome_stored: true }, envelopes: [] });

    // A slow finish whose clock read was before the expiry.
    const late = await handleFinish(
      new Request(`${ORIGIN}/v1/approvals/${pending.id}/finish`, {
        method: "POST",
        headers: { "content-type": "application/json", Authorization: `Bearer ${approver.access}` },
        body: JSON.stringify({ outcome: "approved", ...(await envelope(approver, requester, 1)) }),
      }),
      env,
      pending.id,
      startedMs - 1000,
    );
    expect(await rejection(late)).toEqual({ status: 410, error: "expired" });
    expect(await env.DB.prepare("SELECT outcome, seq, sealed FROM approval_requests WHERE id = ?").bind(pending.id).first()).toEqual({
      outcome: "expired",
      seq: null,
      sealed: null,
    });
    expect(await rejection(await call("PUT", `/v1/approvals/${pending.id}/envelope`, approver, await envelope(approver, requester, 2)))).toEqual({
      status: 410,
      error: "expired",
    });
    expect((await pairSelf(requester)).envelopes).toEqual([]);
  });

  it("lets the claimant retry with a higher seq for 10 minutes after the finish", async () => {
    const approver = await party("macos");
    const other = await party("ios", approver.accountId);
    const requester = await party("linux", approver.accountId);

    // Before the finish there is nothing to replace.
    const early = await revealed(requester, approver);
    expect(await rejection(await call("PUT", `/v1/approvals/${early.id}/envelope`, approver, await envelope(approver, requester, 2)))).toEqual({
      status: 409,
      error: "not_approved",
    });
    expect((await call("POST", `/v1/approvals/${early.id}/finish`, approver, { outcome: "approved", ...(await envelope(approver, requester, 0)) })).status).toBe(400);

    const { id } = await approved(requester, approver);
    const put = async (caller: Party, seq: number) => call("PUT", `/v1/approvals/${id}/envelope`, caller, await envelope(approver, requester, seq, "added"));
    expect(await rejection(await put(approver, 1))).toEqual({ status: 409, error: "stale_seq" });
    expect(await (await put(approver, 3)).json()).toEqual({ seq: 3 });
    expect(await rejection(await put(approver, 2))).toEqual({ status: 409, error: "stale_seq" });
    // Only the claimant.
    expect((await put(other, 4)).status).toBe(404);
    expect((await call("POST", `/v1/approvals/${id}/finish`, approver, { outcome: "approved", ...(await envelope(approver, requester, 5)) })).status).toBe(409);

    const self = await pairSelf(requester);
    expect(self.envelopes.map(({ seq }) => seq)).toEqual([3]);
    expect(await openEnvelopeAs(PAIR_ENVELOPE_LABEL, requester.key, approver.key.pub, 3, self.envelopes[0].sealed)).toBe(machines("added"));

    // 10 minutes after the finish, the envelope is fixed.
    await env.DB.prepare("UPDATE approval_requests SET exp_ms = ? WHERE id = ?").bind(Date.now() - 1, id).run();
    expect(await rejection(await put(approver, 6))).toEqual({ status: 410, error: "expired" });
    expect((await pairSelf(requester)).envelopes.map(({ seq }) => seq)).toEqual([3]);

    // A new request replaces the old one and its envelope.
    await ask(requester);
    expect((await pairSelf(requester)).envelopes).toEqual([]);
  });

  it("shows another account's devices nothing", async () => {
    const approver = await party("macos");
    const requester = await party("ios", approver.accountId);
    const stranger = await party("macos");
    const strangerPhone = await party("ios", stranger.accountId);
    const pending = await approved(requester, approver);
    const fresh = await ask(await party("windows", approver.accountId));

    expect((await (await call("GET", "/v1/approvals?kind=pair", stranger)).json<{ requests: unknown[] }>()).requests).toEqual([]);
    for (const id of [pending.id, fresh.id]) {
      expect((await call("GET", `/v1/approvals/${id}`, stranger)).status).toBe(404);
      expect(await rejection(await call("POST", `/v1/approvals/${id}/claim`, stranger, { nonce_t: b64url(random32()) }))).toEqual({
        status: 404,
        error: "not_found",
      });
      expect((await call("POST", `/v1/approvals/${id}/reveal`, strangerPhone, { nonce_b: b64url(random32()) })).status).toBe(404);
      expect((await call("POST", `/v1/approvals/${id}/finish`, stranger, { outcome: "denied" })).status).toBe(404);
      expect((await call("PUT", `/v1/approvals/${id}/envelope`, stranger, await envelope(stranger, requester, 9))).status).toBe(404);
    }
    expect(await pairSelf(strangerPhone)).toEqual({ envelopes: [] });
    expect((await call("GET", `/v1/approvals/${fresh.id}`, approver)).status).toBe(200);
  });
});

describe("pair-request pushes", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  /** PushRelay's /v1/send, answering each capability with `status`; every call is recorded. */
  function relay(statusFor: (capability: string) => number) {
    const sends: {
      capability: string;
      push_type: string;
      priority: number;
      expiration: number;
      payload: { aps: { alert: { body: string } }; request_id: string };
    }[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      if (request.url !== RELAY_SEND || request.method !== "POST") throw new Error(`unexpected fetch in a test: ${request.url}`);
      const body = await request.json<(typeof sends)[number]>();
      sends.push(body);
      const status = statusFor(body.capability);
      if (status === 0) throw new Error("relay unreachable");
      return new Response(JSON.stringify({ status }), { status });
    });
    return sends;
  }

  const capabilityOf = (device: Party) =>
    env.DB.prepare("SELECT capability FROM push_capabilities WHERE device_id = ?").bind(device.id).first<string>("capability");

  it("stores one capability per iOS device and clears it", async () => {
    const phone = await party("ios");
    const mac = await party("macos", phone.accountId);
    const browser = await party("web", phone.accountId);
    const capability = `hpr1.${randomB64url(80)}`;
    expect((await call("PUT", "/v1/devices/self/push", phone, { capability })).status).toBe(204);
    expect(await capabilityOf(phone)).toBe(capability);
    const next = `hpr1.${randomB64url(80)}`;
    expect((await call("PUT", "/v1/devices/self/push", phone, { capability: next })).status).toBe(204);
    expect(await capabilityOf(phone)).toBe(next);
    for (const bad of [`hpr2.${randomB64url(80)}`, "hpr1.", `hpr1.${randomB64url(80)}=`, `hpr1.${"A".repeat(508)}`, 7]) {
      expect((await call("PUT", "/v1/devices/self/push", phone, { capability: bad })).status, String(bad).slice(0, 8)).toBe(400);
    }
    for (const other of [mac, browser]) {
      expect(await rejection(await call("PUT", "/v1/devices/self/push", other, { capability }))).toEqual({ status: 403, error: "not_ios" });
    }
    expect((await call("DELETE", "/v1/devices/self/push", phone)).status).toBe(204);
    expect(await capabilityOf(phone)).toBeNull();
  });

  it("alerts the account's other iOS devices through PushRelay, and a 410 clears that capability", async () => {
    const requester = await party("ios", undefined, "Jerry's iPhone");
    const iphone = await party("ios", requester.accountId);
    const ipad = await party("ipados", requester.accountId);
    const gone = await party("ios", requester.accountId);
    const mac = await party("macos", requester.accountId, "Jerry's MacBook");
    const stranger = await party("ios");
    const capabilities = new Map<string, Party>();
    for (const device of [requester, iphone, ipad, gone, stranger]) {
      const capability = `hpr1.${randomB64url(80)}`;
      capabilities.set(capability, device);
      expect((await call("PUT", "/v1/devices/self/push", device, { capability })).status).toBe(204);
    }
    // A capability can only be stored by an iOS device; one in the table for a Mac is still never used.
    await env.DB.prepare("INSERT INTO push_capabilities (device_id, account_id, capability, updated_ms) VALUES (?, ?, ?, ?)")
      .bind(mac.id, mac.accountId, `hpr1.${randomB64url(80)}`, Date.now())
      .run();
    const sends = relay((capability) => (capabilities.get(capability) === gone ? 410 : 200));

    const pending = await ask(requester);
    await vi.waitFor(() => expect(sends).toHaveLength(3));
    expect(sends.map((send) => capabilities.get(send.capability)?.id).sort()).toEqual([iphone.id, ipad.id, gone.id].sort());
    for (const send of sends) {
      expect(send).toEqual({
        capability: expect.any(String),
        push_type: "alert",
        priority: 10,
        expiration: expect.any(Number),
        payload: { aps: { alert: { body: "Jerry's iPhone wants to pair with your machines" }, sound: "default", category: "pair_request" }, request_id: pending.id },
      });
      expect(send.expiration * 1000).toBeGreaterThan(Date.now() + 9 * 60 * 1000);
    }
    await vi.waitFor(async () => expect(await capabilityOf(gone)).toBeNull());
    for (const kept of [iphone, ipad, requester, stranger]) expect(await capabilityOf(kept)).not.toBeNull();

    // The Mac asking next alerts the iOS devices left: the first requester now among them, and
    // not the cleared capability.
    await ask(mac);
    await vi.waitFor(() => expect(sends).toHaveLength(6));
    expect(sends.slice(3).map((send) => capabilities.get(send.capability)?.id).sort()).toEqual([requester.id, iphone.id, ipad.id].sort());
    expect(sends.slice(3).map((send) => send.payload.aps.alert.body)).toEqual(Array(3).fill("Jerry's MacBook wants to pair with your machines"));
  });

  it("never fails or holds the request when the relay fails", async () => {
    const requester = await party("macos");
    const down = await party("ios", requester.accountId);
    const erroring = await party("ios", requester.accountId);
    const capabilities = new Map<string, Party>();
    for (const device of [down, erroring]) {
      const capability = `hpr1.${randomB64url(80)}`;
      capabilities.set(capability, device);
      expect((await call("PUT", "/v1/devices/self/push", device, { capability })).status).toBe(204);
    }
    const sends = relay((capability) => (capabilities.get(capability) === down ? 0 : 502));
    const pending = await ask(requester);
    await vi.waitFor(() => expect(sends).toHaveLength(2));
    // Neither failure is a 410: both capabilities stay, and the request goes on.
    expect(await capabilityOf(down)).not.toBeNull();
    expect(await capabilityOf(erroring)).not.toBeNull();
    expect((await call("GET", `/v1/approvals/${pending.id}`, requester)).status).toBe(200);
  });
});
