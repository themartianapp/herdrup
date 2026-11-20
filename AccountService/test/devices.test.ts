import { SELF, env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from "vitest";
import { findOrCreateAccount } from "../src/auth";
import { b64url, fromB64url, randomB64url, utf8 } from "../src/bytes";
import { cleanup } from "../src/cleanup";
import { enrolMac, MAX_DEVICES, x25519 } from "../src/devices";
import type { Env } from "../src/env";
import { serviceKeys } from "../src/keys";
import { dayOf, openSession } from "../src/sessions";
import { activeKey, jwks, type Jwks } from "../src/signing";
import { pairwiseSub, signStatement } from "../src/statements";
import enrolVectors from "./vectors/enrol-v1.json";
import statementVectors from "./vectors/statement-v1.json";

// Devices, statements and the JWKS against the real Worker and a local D1 in workerd. Accounts
// and sessions are made directly (sign-in has its own tests); device keys, statement signing
// keys and challenges are generated here. The rate-limit bindings are per-key counters that
// start at zero in each test (test/setup.ts). The vectors in test/vectors were made with
// Node's crypto, independently of the Worker's code, and are shared with the app, desktop and
// herdr test suites.

const ORIGIN = "https://accounts.herdrup.app";

const hexBytes = (hex: string) => Uint8Array.from(hex.match(/../g) ?? [], (pair) => parseInt(pair, 16));
const base64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const X25519_PKCS8_PREFIX = hexBytes("302e020100300506032b656e04220420");
const ED25519_PKCS8_PREFIX = hexBytes("302e020100300506032b657004220420");
const withPrefix = (prefix: Uint8Array, raw: Uint8Array) => Uint8Array.from([...prefix, ...raw]);

/** A fresh Ed25519 signing key as the STATEMENT_KEY_* secrets hold it: PKCS8 DER, standard base64. */
async function newSigningSecret(): Promise<string> {
  // workers-types types generateKey and exportKey as unions; an Ed25519 pair and a pkcs8 export have these shapes.
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  return base64(new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer));
}

interface DeviceKey {
  privateKey: CryptoKey;
  pub: string;
}

async function newDeviceKey(): Promise<DeviceKey> {
  const pair = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  return { privateKey: pair.privateKey, pub: b64url(new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer)) };
}

interface Session {
  accountId: string;
  access: string;
}

async function newSession(accountId?: string): Promise<Session> {
  const account = accountId ?? (await findOrCreateAccount(env.DB, "apple", randomB64url(32), Date.now())).accountId;
  const tokens = await openSession(env.DB, account, "ios", Date.now());
  return { accountId: account, access: tokens.access_token };
}

function call(method: string, path: string, session?: Session, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (session !== undefined) headers.Authorization = `Bearer ${session.access}`;
  return SELF.fetch(`${ORIGIN}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
}

async function rejection(response: Response): Promise<{ status: number; error: string }> {
  return { status: response.status, ...(await response.json<{ error: string }>()) };
}

interface Challenge {
  challenge_id: string;
  server_pub: string;
  salt: string;
  account_id: string;
  expires_in: number;
}

async function challenge(session: Session): Promise<Challenge> {
  const response = await call("POST", "/v1/devices/challenge", session);
  expect(response.status).toBe(200);
  return response.json<Challenge>();
}

interface DeviceJson {
  id: string;
  name: string;
  platform: string;
  device_pub: string;
  created_ms: number;
  current: boolean;
}

/** Runs the whole enrolment for `device` as the client does; `change` alters the posted body. */
async function enrol(session: Session, device: DeviceKey, change: Record<string, unknown> = {}): Promise<Response> {
  const issued = await challenge(session);
  const shared = await x25519(device.privateKey, fromB64url(issued.server_pub)!);
  const mac = await enrolMac(shared!, fromB64url(issued.salt)!, issued.account_id, device.pub, issued.challenge_id);
  return call("POST", "/v1/devices", session, {
    challenge_id: issued.challenge_id,
    device_pub: device.pub,
    mac,
    name: "Luca's iPhone",
    platform: "ios",
    ...change,
  });
}

async function enrolled(session?: Session): Promise<{ session: Session; device: DeviceKey; id: string }> {
  const owner = session ?? (await newSession());
  const device = await newDeviceKey();
  const response = await enrol(owner, device);
  expect(response.status).toBe(201);
  return { session: owner, device, id: (await response.json<{ device: DeviceJson }>()).device.id };
}

const newHostId = () => randomB64url(16);

interface StatementsBody {
  statements: { host: string; jws: string }[];
  exp: number;
}

async function statements(session: Session, hosts: string[]): Promise<StatementsBody> {
  const response = await call("POST", "/v1/statements", session, { hosts });
  expect(response.status).toBe(200);
  return response.json<StatementsBody>();
}

function decodePart(part: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(fromB64url(part)!));
}

/** Verifies a statement against a JWKS as a host would (signature and kid only). */
async function verifies(jws: string, keySet: { keys: { kid: string; x: string }[] }): Promise<boolean> {
  const [head, payload, signature] = jws.split(".");
  const jwk = keySet.keys.find((key) => key.kid === decodePart(head).kid);
  if (jwk === undefined) return false;
  const key = await crypto.subtle.importKey("jwk", { kty: "OKP", crv: "Ed25519", x: jwk.x }, { name: "Ed25519" }, false, ["verify"]);
  return crypto.subtle.verify("Ed25519", key, fromB64url(signature)!, utf8(`${head}.${payload}`));
}

async function fetchJwks(): Promise<{ response: Response; body: Jwks }> {
  const response = await SELF.fetch(`${ORIGIN}/.well-known/jwks.json`);
  return { response, body: await response.clone().json<Jwks>() };
}

// Every test starts from one signing key, in slot A.
let slotA: string;
beforeEach(async () => {
  slotA ??= await newSigningSecret();
  env.STATEMENT_KEY_A = slotA;
  env.STATEMENT_KID_A = "test-a";
  env.STATEMENT_KEY_B = undefined;
  env.STATEMENT_KID_B = "";
  env.STATEMENT_ACTIVE = "A";
  env.STATEMENT_REVOKED_KIDS = "";
});

describe("enrolment vectors (test/vectors/enrol-v1.json)", () => {
  const importPrivate = (raw: string) =>
    crypto.subtle.importKey("pkcs8", withPrefix(X25519_PKCS8_PREFIX, fromB64url(raw)!), { name: "X25519" }, false, ["deriveBits"]);

  it.each(enrolVectors.cases)("matches $name from both sides", async (vector) => {
    const fromDevice = await x25519(await importPrivate(vector.device_private), fromB64url(vector.server_pub)!);
    const fromServer = await x25519(await importPrivate(vector.server_private), fromB64url(vector.device_pub)!);
    expect(b64url(fromDevice!)).toBe(vector.shared_secret);
    expect(b64url(fromServer!)).toBe(vector.shared_secret);
    const mac = await enrolMac(fromServer!, fromB64url(vector.salt)!, vector.account_id, vector.device_pub, vector.challenge_id);
    expect(mac).toBe(vector.mac);
  });

  it("uses the RFC 7748 §6.1 shared secret in its first case", () => {
    expect(fromB64url(enrolVectors.cases[0].shared_secret)).toEqual(hexBytes("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"));
  });

  it.each(enrolVectors.low_order_device_pubs)("has no shared secret with low-order point %s", async (point) => {
    const device = await newDeviceKey();
    expect(await x25519(device.privateKey, fromB64url(point)!)).toBeNull();
  });
});

describe("enrol", () => {
  it("binds a device to the account and the session", async () => {
    const session = await newSession();
    const device = await newDeviceKey();
    const issued = await challenge(session);
    expect(issued).toMatchObject({ account_id: session.accountId, expires_in: 60 });
    expect(fromB64url(issued.server_pub)?.byteLength).toBe(32);
    expect(fromB64url(issued.salt)?.byteLength).toBe(32);

    const response = await enrol(session, device, { name: "  Luca's\u0007 iPhone\n" });
    expect(response.status).toBe(201);
    const { device: created } = await response.json<{ device: DeviceJson }>();
    expect(created).toMatchObject({ name: "Luca's iPhone", platform: "ios", device_pub: device.pub, current: true });
    expect(created.id).toMatch(/^[A-Za-z0-9_-]{22}$/);

    const list = await (await call("GET", "/v1/devices", session)).json<{ devices: DeviceJson[] }>();
    expect(list.devices).toEqual([created]);
  });

  it("is idempotent for the same key on the same session", async () => {
    const { session, device, id } = await enrolled();
    const again = await enrol(session, device);
    expect(again.status).toBe(200);
    expect((await again.json<{ device: DeviceJson }>()).device.id).toBe(id);
  });

  it("finds the same device when the key enrols again from a new session of the same account", async () => {
    const { session, device, id } = await enrolled();
    const later = await newSession(session.accountId);
    const response = await enrol(later, device);
    expect(response.status).toBe(200);
    expect((await response.json<{ device: DeviceJson }>()).device).toMatchObject({ id, current: true });
    const list = await (await call("GET", "/v1/devices", session)).json<{ devices: DeviceJson[] }>();
    expect(list.devices).toHaveLength(1);
  });

  it.each(enrolVectors.low_order_device_pubs)("refuses low-order point %s as a device key", async (point) => {
    const session = await newSession();
    const issued = await challenge(session);
    const response = await call("POST", "/v1/devices", session, {
      challenge_id: issued.challenge_id,
      device_pub: point,
      mac: b64url(new Uint8Array(32)),
      name: "x",
      platform: "ios",
    });
    expect(await rejection(response)).toEqual({ status: 400, error: "invalid_device_key" });
  });

  it("answers 409 for a key already on another account", async () => {
    const { device } = await enrolled();
    expect(await rejection(await enrol(await newSession(), device))).toEqual({ status: 409, error: "device_in_other_account" });
  });

  it("keeps a session's device fixed once enrolled", async () => {
    const { session } = await enrolled();
    expect(await rejection(await enrol(session, await newDeviceKey()))).toEqual({ status: 409, error: "session_has_device" });
    const list = await (await call("GET", "/v1/devices", session)).json<{ devices: DeviceJson[] }>();
    expect(list.devices).toHaveLength(1);
  });

  /**
   * Runs `body` with env.DB's next batch() call paused, `when` it runs, until `hook` has
   * finished: the enrolment's transaction, interleaved with other requests at a chosen point.
   * Later batches run untouched.
   */
  async function withBatchHook<T>(when: "before" | "after", hook: () => Promise<void>, body: () => Promise<T>): Promise<T> {
    const real = env.DB;
    let fired = false;
    const pause = async () => {
      if (fired) return;
      fired = true;
      await hook();
    };
    env.DB = new Proxy(real, {
      get(target, property) {
        if (property === "batch") {
          return async (statements: D1PreparedStatement[]) => {
            if (when === "before") await pause();
            const results = await target.batch(statements);
            if (when === "after") await pause();
            return results;
          };
        }
        const value: unknown = Reflect.get(target, property);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    try {
      return await body();
    } finally {
      env.DB = real;
    }
  }

  it("never deletes a device another session adopted while this enrolment was finishing", async () => {
    const first = await newSession();
    const second = await newSession(first.accountId);
    const device = await newDeviceKey();
    let signout: Response | undefined;
    let adopted: Response | undefined;
    // A's transaction inserts the device and binds session A. Before A reads the outcome,
    // session A signs out and session B enrols the same key, adopting A's device.
    const late = await withBatchHook(
      "after",
      async () => {
        signout = await call("POST", "/v1/auth/signout", first);
        adopted = await enrol(second, device);
      },
      () => enrol(first, device),
    );
    expect(signout?.status).toBe(204);
    expect(adopted?.status).toBe(200);
    // Session B and the device it adopted survive A's late finish.
    expect((await call("GET", "/v1/account", second)).status).toBe(200);
    const list = await (await call("GET", "/v1/devices", second)).json<{ devices: DeviceJson[] }>();
    expect(list.devices.map((row) => [row.device_pub, row.current])).toEqual([[device.pub, true]]);
    expect((await call("POST", "/v1/statements", second, { hosts: [newHostId()] })).status).toBe(200);
    // A's own session is gone, so A gets what any signed-out request gets.
    expect(await rejection(late)).toEqual({ status: 401, error: "invalid_token" });
  });

  it("adds no device when another enrolment bound the session first, with another key", async () => {
    const session = await newSession();
    const winner = await newDeviceKey();
    const loser = await newDeviceKey();
    let first: Response | undefined;
    const late = await withBatchHook(
      "before",
      async () => {
        first = await enrol(session, winner);
      },
      () => enrol(session, loser),
    );
    expect(first?.status).toBe(201);
    expect(await rejection(late)).toEqual({ status: 409, error: "session_has_device" });
    const list = await (await call("GET", "/v1/devices", session)).json<{ devices: DeviceJson[] }>();
    expect(list.devices.map((row) => row.device_pub)).toEqual([winner.pub]);
  });

  it(`caps an account at ${MAX_DEVICES} devices`, async () => {
    const session = await newSession();
    const now = Date.now();
    await env.DB.batch(
      Array.from({ length: MAX_DEVICES - 1 }, (_, i) =>
        env.DB.prepare("INSERT INTO devices (id, account_id, device_pub, name, platform, created_ms) VALUES (?, ?, ?, ?, 'ios', ?)").bind(
          randomB64url(16),
          session.accountId,
          randomB64url(32),
          `seeded ${i}`,
          now,
        ),
      ),
    );
    expect((await enrol(session, await newDeviceKey())).status).toBe(201);
    const next = await newSession(session.accountId);
    expect(await rejection(await enrol(next, await newDeviceKey()))).toEqual({ status: 403, error: "too_many_devices" });
  });

  it("refuses a wrong proof and spends the challenge either way", async () => {
    const session = await newSession();
    const device = await newDeviceKey();
    const issued = await challenge(session);
    const body = { challenge_id: issued.challenge_id, device_pub: device.pub, mac: b64url(new Uint8Array(32)), name: "x", platform: "ios" };
    expect(await rejection(await call("POST", "/v1/devices", session, body))).toEqual({ status: 400, error: "proof_invalid" });
    const shared = await x25519(device.privateKey, fromB64url(issued.server_pub)!);
    const good = await enrolMac(shared!, fromB64url(issued.salt)!, issued.account_id, device.pub, issued.challenge_id);
    expect(await rejection(await call("POST", "/v1/devices", session, { ...body, mac: good }))).toEqual({ status: 400, error: "challenge_invalid" });
  });

  it("refuses a proof made for another account id", async () => {
    const session = await newSession();
    const device = await newDeviceKey();
    const issued = await challenge(session);
    const shared = await x25519(device.privateKey, fromB64url(issued.server_pub)!);
    const mac = await enrolMac(shared!, fromB64url(issued.salt)!, randomB64url(16), device.pub, issued.challenge_id);
    const response = await call("POST", "/v1/devices", session, { challenge_id: issued.challenge_id, device_pub: device.pub, mac, name: "x", platform: "ios" });
    expect(await rejection(response)).toEqual({ status: 400, error: "proof_invalid" });
  });

  it("refuses another session's challenge and an expired one", async () => {
    const session = await newSession();
    const device = await newDeviceKey();
    const issued = await challenge(session);
    const shared = await x25519(device.privateKey, fromB64url(issued.server_pub)!);
    const mac = await enrolMac(shared!, fromB64url(issued.salt)!, issued.account_id, device.pub, issued.challenge_id);
    const body = { challenge_id: issued.challenge_id, device_pub: device.pub, mac, name: "x", platform: "ios" };
    const sibling = await newSession(session.accountId);
    expect(await rejection(await call("POST", "/v1/devices", sibling, body))).toEqual({ status: 400, error: "challenge_invalid" });
    await env.DB.prepare("UPDATE enrol_challenges SET exp_ms = ? WHERE id = ?").bind(Date.now() - 1, issued.challenge_id).run();
    expect(await rejection(await call("POST", "/v1/devices", session, body))).toEqual({ status: 400, error: "challenge_invalid" });
  });

  it.each([
    ["a short device key", { device_pub: "abc" }],
    ["an empty name", { name: " \n " }],
    ["a name past 64 characters", { name: "x".repeat(65) }],
    ["an unknown platform", { platform: "amiga" }],
    ["a missing mac", { mac: undefined }],
  ])("answers 400 to %s", async (_name, change) => {
    expect(await rejection(await enrol(await newSession(), await newDeviceKey(), change))).toEqual({ status: 400, error: "bad_request" });
  });

  it("needs a session", async () => {
    expect((await call("POST", "/v1/devices/challenge")).status).toBe(401);
    expect((await call("GET", "/v1/devices")).status).toBe(401);
  });

  it("allows 10 challenges and enrolments per account a minute", async () => {
    const session = await newSession();
    for (let i = 0; i < 10; i++) expect((await call("POST", "/v1/devices/challenge", session)).status).toBe(200);
    expect(await rejection(await call("POST", "/v1/devices/challenge", session))).toEqual({ status: 429, error: "rate_limited" });
    expect((await call("GET", "/v1/devices", session)).status).toBe(200);
  });
});

describe("device list, rename and remove", () => {
  it("renames a device of the account and nobody else's", async () => {
    const { session, id } = await enrolled();
    const renamed = await call("PATCH", `/v1/devices/${id}`, session, { name: "Studio iPad" });
    expect(renamed.status).toBe(200);
    expect((await renamed.json<{ device: DeviceJson }>()).device).toMatchObject({ id, name: "Studio iPad" });
    expect(await rejection(await call("PATCH", `/v1/devices/${id}`, session, { name: "" }))).toEqual({ status: 400, error: "bad_request" });
    const stranger = await newSession();
    expect(await rejection(await call("PATCH", `/v1/devices/${id}`, stranger, { name: "mine" }))).toEqual({ status: 404, error: "not_found" });
    expect(await rejection(await call("DELETE", `/v1/devices/${id}`, stranger))).toEqual({ status: 404, error: "not_found" });
  });

  it("marks only the caller's own device as current", async () => {
    const first = await enrolled();
    const second = await enrolled(await newSession(first.session.accountId));
    const list = await (await call("GET", "/v1/devices", second.session)).json<{ devices: DeviceJson[] }>();
    expect(list.devices.map((device) => [device.id, device.current])).toEqual([
      [first.id, false],
      [second.id, true],
    ]);
  });

  it("removes a device: its sessions end and its statements stop, the other devices keep theirs", async () => {
    const phone = await enrolled();
    const laptop = await enrolled(await newSession(phone.session.accountId));
    const host = newHostId();
    await statements(phone.session, [host]);

    const removed = await call("DELETE", `/v1/devices/${phone.id}`, laptop.session);
    expect(removed.status).toBe(204);
    expect(await rejection(await call("POST", "/v1/statements", phone.session, { hosts: [host] }))).toEqual({ status: 401, error: "invalid_token" });
    expect((await call("GET", "/v1/account", phone.session)).status).toBe(401);
    expect((await statements(laptop.session, [host])).statements).toHaveLength(1);
    expect(await rejection(await call("DELETE", `/v1/devices/${phone.id}`, laptop.session))).toEqual({ status: 404, error: "not_found" });
    // The key can join an account again, from a new sign-in.
    expect((await enrol(await newSession(phone.session.accountId), phone.device)).status).toBe(201);
  });

  it("routes only device ids and the methods each path takes", async () => {
    const session = await newSession();
    expect((await call("DELETE", "/v1/devices/not-an-id", session)).status).toBe(404);
    const wrong = await call("PUT", `/v1/devices/${randomB64url(16)}`, session);
    expect(wrong.status).toBe(405);
    expect(wrong.headers.get("Allow")).toBe("PATCH, DELETE");
  });
});

describe("statements", () => {
  it("needs an enrolled device", async () => {
    expect(await rejection(await call("POST", "/v1/statements", await newSession(), { hosts: [newHostId()] }))).toEqual({
      status: 403,
      error: "device_required",
    });
  });

  it("signs one 10-minute statement per host for the session's own device", async () => {
    const { session, device } = await enrolled();
    const hosts = [newHostId(), newHostId()];
    const before = Math.floor(Date.now() / 1000);
    const body = await statements(session, [...hosts, hosts[0]]);
    expect(body.statements.map((statement) => statement.host)).toEqual(hosts);
    const { body: keySet } = await fetchJwks();
    for (const { host, jws } of body.statements) {
      const [head, payload] = jws.split(".");
      expect(decodePart(head)).toEqual({ alg: "EdDSA", typ: "herdrup-device+jwt", kid: "test-a" });
      const claims = decodePart(payload);
      expect(Object.keys(claims)).toEqual(["v", "iss", "aud", "sub", "dev", "iat", "exp"]);
      expect(claims).toMatchObject({ v: 1, iss: "https://accounts.herdrup.app", aud: host, dev: device.pub });
      expect(claims.iat).toBeGreaterThanOrEqual(before);
      expect(claims.exp).toBe((claims.iat as number) + 600);
      expect(body.exp).toBe(claims.exp);
      expect(await verifies(jws, keySet)).toBe(true);
    }
    const row = await env.DB.prepare("SELECT last_statement_day FROM devices WHERE device_pub = ?").bind(device.pub).first<{ last_statement_day: number }>();
    expect(row?.last_statement_day).toBe(dayOf(Date.now()));
  });

  it("gives an account one stable sub per host, different across hosts and across accounts", async () => {
    const phone = await enrolled();
    const laptop = await enrolled(await newSession(phone.session.accountId));
    const stranger = await enrolled();
    const [hostA, hostB] = [newHostId(), newHostId()];
    const sub = async (session: Session, host: string) =>
      decodePart((await statements(session, [host])).statements[0].jws.split(".")[1]).sub as string;

    const first = await sub(phone.session, hostA);
    expect(first).toMatch(/^[A-Za-z0-9_-]{22}$/);
    expect(await sub(phone.session, hostA)).toBe(first);
    expect(await sub(laptop.session, hostA)).toBe(first);
    expect(await sub(phone.session, hostB)).not.toBe(first);
    expect(await sub(stranger.session, hostA)).not.toBe(first);
    expect(first).not.toContain(phone.session.accountId);
  });

  it.each([
    ["no hosts", []],
    ["51 hosts", Array.from({ length: 51 }, () => randomB64url(16))],
    ["a host id of the wrong length", ["short"]],
    ["a host id that isn't base64url", ["HostIdExample+01234567"]],
    ["a number", [7]],
  ])("answers 400 to %s", async (_name, hosts) => {
    const { session } = await enrolled();
    expect(await rejection(await call("POST", "/v1/statements", session, { hosts }))).toEqual({ status: 400, error: "bad_request" });
  });

  it("allows 50 hosts in one call", async () => {
    const { session } = await enrolled();
    expect((await statements(session, Array.from({ length: 50 }, () => newHostId()))).statements).toHaveLength(50);
  });

  it("allows 30 statement calls per account a minute", async () => {
    const { session } = await enrolled();
    const host = [newHostId()];
    for (let i = 0; i < 30; i++) expect((await call("POST", "/v1/statements", session, { hosts: host })).status).toBe(200);
    expect(await rejection(await call("POST", "/v1/statements", session, { hosts: host }))).toEqual({ status: 429, error: "rate_limited" });
    expect((await call("GET", "/v1/devices", session)).status).toBe(200);
  });

  it("answers 500 not_configured while no slot can sign", async () => {
    const { session } = await enrolled();
    env.STATEMENT_KEY_A = undefined;
    expect(await rejection(await call("POST", "/v1/statements", session, { hosts: [newHostId()] }))).toEqual({ status: 500, error: "not_configured" });
    env.STATEMENT_KEY_A = "bm90IGEga2V5";
    expect(await rejection(await call("POST", "/v1/statements", session, { hosts: [newHostId()] }))).toEqual({ status: 500, error: "not_configured" });
  });
});

describe("JWKS and rotation", () => {
  it("publishes the active key to anyone, cacheable for an hour", async () => {
    const { response, body } = await fetchJwks();
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("public, max-age=3600");
    expect(body.revoked_kids).toEqual([]);
    expect(body.keys).toHaveLength(1);
    expect(body.keys[0]).toMatchObject({ kty: "OKP", crv: "Ed25519", kid: "test-a", use: "sig", alg: "EdDSA" });
    expect(Object.keys(body.keys[0]).sort()).toEqual(["alg", "crv", "kid", "kty", "use", "x"]);
    expect(fromB64url(body.keys[0].x)?.byteLength).toBe(32);
  });

  it("rotates through the idle slot: publish, switch, then retire", async () => {
    const { session } = await enrolled();
    const host = [newHostId()];
    const old = (await statements(session, host)).statements[0].jws;

    // 1. The new key goes into slot B: published at once, not yet signing.
    env.STATEMENT_KEY_B = await newSigningSecret();
    env.STATEMENT_KID_B = "test-b";
    let keySet = (await fetchJwks()).body;
    expect(keySet.keys.map((key) => key.kid)).toEqual(["test-a", "test-b"]);
    expect(decodePart((await statements(session, host)).statements[0].jws.split(".")[0]).kid).toBe("test-a");

    // 2. Switch: B signs, A stays published so statements it signed still verify.
    env.STATEMENT_ACTIVE = "B";
    keySet = (await fetchJwks()).body;
    expect(keySet.keys.map((key) => key.kid)).toEqual(["test-b", "test-a"]);
    const fresh = (await statements(session, host)).statements[0].jws;
    expect(decodePart(fresh.split(".")[0]).kid).toBe("test-b");
    expect(await verifies(fresh, keySet)).toBe(true);
    expect(await verifies(old, keySet)).toBe(true);

    // 3. Retire A once its last statement has expired.
    env.STATEMENT_KEY_A = undefined;
    keySet = (await fetchJwks()).body;
    expect(keySet.keys.map((key) => key.kid)).toEqual(["test-b"]);
    expect(await verifies(old, keySet)).toBe(false);
    expect(await verifies(fresh, keySet)).toBe(true);
  });

  it("drops a revoked kid at once and lists it, after a compromise", async () => {
    const { session } = await enrolled();
    env.STATEMENT_KEY_B = await newSigningSecret();
    env.STATEMENT_KID_B = "test-b";
    env.STATEMENT_ACTIVE = "B";
    env.STATEMENT_REVOKED_KIDS = " test-a , bad kid! ";
    const { body } = await fetchJwks();
    expect(body).toEqual({ keys: [expect.objectContaining({ kid: "test-b" })], revoked_kids: ["test-a"] });

    // A revoked kid never signs, even if it is still the active slot's.
    env.STATEMENT_ACTIVE = "A";
    expect(await rejection(await call("POST", "/v1/statements", session, { hosts: [newHostId()] }))).toEqual({ status: 500, error: "not_configured" });
    expect((await fetchJwks()).body.keys.map((key) => key.kid)).toEqual(["test-b"]);
  });

  it("skips a slot whose key or kid is unusable", async () => {
    env.STATEMENT_KEY_B = "bm90IGEga2V5";
    env.STATEMENT_KID_B = "test-b";
    expect((await fetchJwks()).body.keys.map((key) => key.kid)).toEqual(["test-a"]);
    env.STATEMENT_KEY_B = await newSigningSecret();
    env.STATEMENT_KID_B = "bad kid";
    expect((await fetchJwks()).body.keys.map((key) => key.kid)).toEqual(["test-a"]);
  });
});

describe("golden statements (test/vectors/statement-v1.json)", () => {
  const goldenEnv = {
    STATEMENT_KEY_A: base64(withPrefix(ED25519_PKCS8_PREFIX, fromB64url(statementVectors.signing_key_seed)!)),
    STATEMENT_KID_A: statementVectors.jwks.keys[0].kid,
    STATEMENT_ACTIVE: "A",
  } as Env;

  it("publishes the golden JWKS for the golden key", async () => {
    expect(await jwks(goldenEnv)).toEqual(statementVectors.jwks);
  });

  it("signs the golden statement byte for byte", async () => {
    const { pairwise } = await serviceKeys(statementVectors.account_hmac_key)!;
    const { issued } = statementVectors;
    const sub = await pairwiseSub(pairwise, statementVectors.account_id, issued.host_id);
    expect(sub).toBe(issued.sub);
    const jws = await signStatement((await activeKey(goldenEnv))!, { hostId: issued.host_id, sub, devicePub: issued.dev, iatSeconds: issued.iat });
    expect(jws).toBe(issued.jws);
    expect(await pairwiseSub(pairwise, statementVectors.account_id, statementVectors.cases[4].host_id)).toBe(statementVectors.other_host_sub);
  });

  it.each(statementVectors.cases)("has a signature consistent with its expectation: $name", async (vector) => {
    const valid = await verifies(vector.jws, statementVectors.jwks);
    expect(valid).toBe(vector.expect !== "bad_signature" && vector.expect !== "unknown_kid");
    if (vector.expect === "unknown_kid") {
      expect(statementVectors.jwks.keys.map((key) => key.kid)).not.toContain(decodePart(vector.jws.split(".")[0]).kid);
    }
  });
});

describe("logging and cleanup", () => {
  let logSpy: MockInstance<typeof console.log>;

  beforeEach(() => {
    logSpy = vi.spyOn(console, "log");
  });

  afterEach(() => {
    logSpy.mockRestore();
  });

  it("never logs device ids, device keys or host ids", async () => {
    const { session, device, id } = await enrolled();
    const host = newHostId();
    for (let i = 0; i < 31; i++) await call("POST", "/v1/statements", session, { hosts: [host] });
    const lines = logSpy.mock.calls.map((args) => String(args[0]));
    expect(lines).toContain(JSON.stringify({ endpoint: "/v1/statements", outcome: "rate_limited" }));
    for (const line of lines) {
      expect(Object.keys(JSON.parse(line)).sort()).toEqual(["endpoint", "outcome"]);
      for (const secret of [device.pub, id, host, session.accountId]) expect(line).not.toContain(secret);
    }
  });

  it("drops expired enrolment challenges, and a session's challenges with the session", async () => {
    const session = await newSession();
    const stale = await challenge(session);
    const live = await challenge(session);
    await env.DB.prepare("UPDATE enrol_challenges SET exp_ms = ? WHERE id = ?").bind(Date.now() - 1, stale.challenge_id).run();
    await cleanup(env.DB, Date.now());
    const ids = async () =>
      (await env.DB.prepare("SELECT id FROM enrol_challenges WHERE account_id = ?").bind(session.accountId).all<{ id: string }>()).results.map(
        (row) => row.id,
      );
    expect(await ids()).toEqual([live.challenge_id]);
    await call("POST", "/v1/auth/signout", session);
    expect(await ids()).toEqual([]);
  });

  it("deletes an account's devices with the account", async () => {
    const { session } = await enrolled();
    await env.DB.prepare("DELETE FROM accounts WHERE id = ?").bind(session.accountId).run();
    const left = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices WHERE account_id = ?").bind(session.accountId).first<{ n: number }>();
    expect(left?.n).toBe(0);
  });
});
