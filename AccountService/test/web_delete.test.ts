import { SELF, env } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { b64url, randomB64url, utf8 } from "../src/bytes";
import { cleanup } from "../src/cleanup";
import { APPLE_REVOKE_URL, APPLE_TOKEN_URL, appleRest, fakeProviders, resetAppleRest, signIdToken, type Providers } from "./providers";

// Deleting an account from the desktop through the web flow (DESIGN.md §6.6), against the real
// Worker and a local D1 in workerd. Accounts are made by native sign-ins; the confirmation is a
// web sign-in (Apple form_post, or Google with its token endpoint stood in for below). Apple's
// /auth/token and /auth/revoke are test/providers.ts's stand-in. The Sign in with Apple key is a
// P-256 key generated here; no real secret is read.

const ORIGIN = "https://accounts.herdrup.app";
const APPLE_APP = "com.jerryfane.herdr";
const APPLE_WEB = "com.jerryfane.herdr.signin";
const GOOGLE_IOS = "test-ios.apps.googleusercontent.com";
const GOOGLE_WEB = "test-web.apps.googleusercontent.com";
const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GOOGLE_SECRET = "test-google-web-secret";
const KEY_ID = "TESTKEY123";

let keys: Providers;
let siwaPem: string;
let ipCounter = 0;
const freshIp = () => `2001:db8:6::${(++ipCounter).toString(16)}`;
const nowSeconds = () => Math.floor(Date.now() / 1000);
const s256 = async (text: string) => b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(text))));
const sha256 = async (text: string) =>
  Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(text))), (b) => b.toString(16).padStart(2, "0")).join("");

/** What Google's token endpoint answers for each code: an ID token for this sub and nonce. */
const googleGrants = new Map<string, { sub: string; nonce: string }>();

beforeAll(async () => {
  keys = await fakeProviders();
  const spy = vi.mocked(globalThis.fetch);
  const inner = spy.getMockImplementation();
  spy.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : input.toString();
    if (url !== GOOGLE_TOKEN_URL) return inner!(input, init);
    const form = Object.fromEntries(new URLSearchParams(new TextDecoder().decode(await new Request(url, init).arrayBuffer())));
    const grant = googleGrants.get(form.code);
    if (grant === undefined || form.client_secret !== GOOGLE_SECRET) return Response.json({ error: "invalid_grant" }, { status: 400 });
    googleGrants.delete(form.code);
    const idToken = await signIdToken(keys.google, { iss: "https://accounts.google.com", aud: GOOGLE_WEB, sub: grant.sub, nonce: grant.nonce, iat: nowSeconds(), exp: nowSeconds() + 3600 });
    return Response.json({ access_token: `ya29.${randomB64url(24)}`, token_type: "Bearer", expires_in: 3599, id_token: idToken });
  });
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  siwaPem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der)).match(/.{1,64}/g)?.join("\n")}\n-----END PRIVATE KEY-----\n`;
});

beforeEach(() => {
  resetAppleRest();
  env.GOOGLE_WEB_CLIENT_SECRET = GOOGLE_SECRET;
  env.APPLE_SIWA_P8 = siwaPem;
  env.APPLE_KEY_ID = KEY_ID;
});

type Provider = "apple" | "google";

interface Identity {
  provider: Provider;
  sub: string;
}

const person = (provider: Provider): Identity => ({ provider, sub: `${provider}.${crypto.randomUUID().replace(/-/g, "")}` });

interface Session {
  accountId: string;
  access: string;
}

function post(path: string, body: unknown, access?: string): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json", "CF-Connecting-IP": freshIp() };
  if (access !== undefined) headers.Authorization = `Bearer ${access}`;
  return SELF.fetch(`${ORIGIN}${path}`, { method: "POST", headers, body: JSON.stringify(body) });
}

async function rejection(response: Response): Promise<Record<string, unknown>> {
  return { status: response.status, ...(await response.json<Record<string, unknown>>()) };
}

/** A native sign-in as `who` (the iOS app's audience): the account and a session. */
async function signIn(who: Identity): Promise<Session> {
  const nonce = (await (await post("/v1/auth/nonce", {})).json<{ nonce: string }>()).nonce;
  const claims =
    who.provider === "apple"
      ? { iss: "https://appleid.apple.com", aud: APPLE_APP, sub: who.sub, nonce, iat: nowSeconds(), exp: nowSeconds() + 600 }
      : { iss: "https://accounts.google.com", aud: GOOGLE_IOS, sub: who.sub, nonce, iat: nowSeconds(), exp: nowSeconds() + 600 };
  const response = await post(`/v1/auth/${who.provider}`, { id_token: await signIdToken(keys[who.provider], claims), nonce, platform: "macos" });
  expect(response.status).toBe(200);
  const body = await response.json<{ account_id: string; access_token: string }>();
  return { accountId: body.account_id, access: body.access_token };
}

async function accountExists(accountId: string): Promise<boolean> {
  return (await env.DB.prepare("SELECT 1 FROM accounts WHERE id = ?").bind(accountId).first()) !== null;
}

/** POST /v1/account/delete/start for `session`: the start URL and the verifier behind its challenge. */
async function deleteStart(session: Session, provider: Provider): Promise<{ startUrl: string; verifier: string }> {
  const verifier = randomB64url(48);
  const response = await post("/v1/account/delete/start", { provider, handoff_challenge: await s256(verifier) }, session.access);
  expect(response.status).toBe(200);
  const body = await response.json<{ start_url: string; expires_in: number }>();
  expect(body.expires_in).toBe(300);
  return { startUrl: body.start_url, verifier };
}

interface BrowserFlow {
  state: string;
  nonce: string;
  cookie: string;
  location: URL;
}

/** The browser opens a start URL: the flow it gets, with its flow cookie. */
async function open(startUrl: string): Promise<BrowserFlow> {
  const response = await SELF.fetch(startUrl, { headers: { "CF-Connecting-IP": freshIp() }, redirect: "manual" });
  expect(response.status, await response.clone().text()).toBe(303);
  const location = new URL(response.headers.get("Location")!);
  const flow = /__Host-hu_flow=([^;]+)/.exec(response.headers.get("Set-Cookie") ?? "")?.[1];
  return { state: location.searchParams.get("state")!, nonce: location.searchParams.get("nonce")!, cookie: `__Host-hu_flow=${flow}`, location };
}

/** The provider's callback after the browser signed in as `who`: where it sends the browser. */
async function callback(flow: BrowserFlow, who: Identity, appleCode = `c${randomB64url(16)}.0.web`): Promise<string> {
  if (who.provider === "apple") {
    const idToken = await signIdToken(keys.apple, { iss: "https://appleid.apple.com", aud: APPLE_WEB, sub: who.sub, nonce: flow.nonce, iat: nowSeconds(), exp: nowSeconds() + 600 });
    const response = await SELF.fetch(`${ORIGIN}/v1/auth/web/apple/callback`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", Cookie: flow.cookie, "CF-Connecting-IP": freshIp() },
      body: new URLSearchParams({ state: flow.state, code: appleCode, id_token: idToken }).toString(),
      redirect: "manual",
    });
    return response.headers.get("Location") ?? `status ${response.status}`;
  }
  const code = `4/0A${randomB64url(30)}`;
  googleGrants.set(code, { sub: who.sub, nonce: flow.nonce });
  const response = await SELF.fetch(`${ORIGIN}/v1/auth/web/google/callback?${new URLSearchParams({ state: flow.state, code })}`, {
    headers: { Cookie: flow.cookie, "CF-Connecting-IP": freshIp() },
    redirect: "manual",
  });
  return response.headers.get("Location") ?? `status ${response.status}`;
}

const deleteCodeIn = (location: string) => /^herdrup:\/\/account#delete_code=([A-Za-z0-9_-]{43})$/.exec(location)?.[1];

/** The whole confirmation for `session`, signing in as `who` in the browser: the delete code and its verifier. */
async function confirm(session: Session, who: Identity, appleCode?: string): Promise<{ code: string; verifier: string }> {
  const { startUrl, verifier } = await deleteStart(session, who.provider);
  const location = await callback(await open(startUrl), who, appleCode);
  const code = deleteCodeIn(location);
  expect(code, location).toBeDefined();
  return { code: code!, verifier };
}

/** Every value in every table, as text: for checking what is never stored. */
async function databaseText(): Promise<string> {
  const tables = await env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%'").all<{ name: string }>();
  let text = "";
  for (const { name } of tables.results) text += JSON.stringify((await env.DB.prepare(`SELECT * FROM "${name}"`).all()).results);
  return text;
}

describe("POST /v1/account/delete/start", () => {
  it("gives a single-use start URL bound to the session, for a provider whose web flow runs", async () => {
    const session = await signIn(person("google"));
    const { startUrl } = await deleteStart(session, "google");
    expect(startUrl).toMatch(/^https:\/\/accounts\.herdrup\.app\/v1\/auth\/web\/start\?purpose=delete&ticket=[A-Za-z0-9_-]{43}$/);
    const flow = await open(startUrl);
    // The same web flow as a sign-in: Google's web client, PKCE, the flow cookie.
    expect(`${flow.location.origin}${flow.location.pathname}`).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    expect(flow.location.searchParams.get("client_id")).toBe(GOOGLE_WEB);
    expect(flow.location.searchParams.get("code_challenge_method")).toBe("S256");
    // The ticket is spent by its first start; only its hash was kept.
    expect(await rejection(await SELF.fetch(startUrl, { headers: { "CF-Connecting-IP": freshIp() }, redirect: "manual" }))).toEqual({ status: 400, error: "ticket_invalid" });
    expect(await databaseText()).not.toContain(new URL(startUrl).searchParams.get("ticket")!);
  });

  it("needs a session and a well-formed body, and refuses a provider whose web flow can't run", async () => {
    const session = await signIn(person("apple"));
    const challenge = await s256(randomB64url(48));
    expect(await rejection(await post("/v1/account/delete/start", { provider: "apple", handoff_challenge: challenge }))).toEqual({ status: 401, error: "invalid_token" });
    for (const body of [{}, { provider: "github", handoff_challenge: challenge }, { provider: "apple", handoff_challenge: "short" }, { provider: "apple", handoff_challenge: challenge, extra: 1 }]) {
      expect(await rejection(await post("/v1/account/delete/start", body, session.access))).toEqual({ status: 400, error: "bad_request" });
    }
    env.GOOGLE_WEB_CLIENT_SECRET = undefined;
    expect(await rejection(await post("/v1/account/delete/start", { provider: "google", handoff_challenge: challenge }, session.access))).toEqual({
      status: 503,
      error: "provider_not_configured",
    });
  });

  it("refuses malformed delete starts, and sends an expired ticket back to the app", async () => {
    const session = await signIn(person("apple"));
    const { startUrl } = await deleteStart(session, "apple");
    const ticket = new URL(startUrl).searchParams.get("ticket")!;
    for (const query of [`purpose=delete`, `purpose=remove&ticket=${ticket}`, `purpose=delete&ticket=${ticket}&provider=apple`, `purpose=delete&ticket=short`]) {
      const response = await SELF.fetch(`${ORIGIN}/v1/auth/web/start?${query}`, { headers: { "CF-Connecting-IP": freshIp() }, redirect: "manual" });
      expect({ query, ...(await rejection(response)) }).toEqual({ query, status: 400, error: "bad_request" });
    }
    await env.DB.prepare("UPDATE delete_tickets SET exp_ms = ? WHERE ticket_hash = ?").bind(Date.now() - 1, await sha256(ticket)).run();
    const late = await SELF.fetch(startUrl, { headers: { "CF-Connecting-IP": freshIp() }, redirect: "manual" });
    expect(late.headers.get("Location")).toBe("herdrup://account#delete_error=flow_expired");
  });
});

describe("deleting through the web flow", () => {
  it("Google: the confirmation's code deletes the account, with no Apple call", async () => {
    const who = person("google");
    const session = await signIn(who);
    const { code, verifier } = await confirm(session, who);
    expect(await accountExists(session.accountId)).toBe(true);
    expect(await (await post("/v1/account/delete", { handoff_code: code, handoff_verifier: verifier }, session.access)).json()).toEqual({ deleted: true, manual_revoke: false });
    expect(await accountExists(session.accountId)).toBe(false);
    expect(appleRest.calls).toEqual([]);
    expect(await rejection(await SELF.fetch(`${ORIGIN}/v1/account`, { headers: { Authorization: `Bearer ${session.access}` } }))).toEqual({ status: 401, error: "invalid_token" });
  });

  it("Apple: the confirmation keeps its authorization code (sealed) and the deletion revokes with the Services ID", async () => {
    const who = person("apple");
    const session = await signIn(who);
    const appleCode = `c${randomB64url(16)}.0.mrrs.${randomB64url(8)}`;
    const { code, verifier } = await confirm(session, who, appleCode);
    expect(await databaseText()).not.toContain(appleCode);
    expect(await (await post("/v1/account/delete", { handoff_code: code, handoff_verifier: verifier }, session.access)).json()).toEqual({ deleted: true, manual_revoke: false });
    expect(await accountExists(session.accountId)).toBe(false);
    expect(appleRest.calls.map((call) => call.url)).toEqual([APPLE_TOKEN_URL, APPLE_REVOKE_URL]);
    const [exchange, revoke] = appleRest.calls;
    expect(exchange.form).toMatchObject({ client_id: APPLE_WEB, code: appleCode, grant_type: "authorization_code", redirect_uri: `${ORIGIN}/v1/auth/web/apple/callback` });
    expect(revoke.form).toMatchObject({ client_id: APPLE_WEB, token: `refresh-for-${appleCode}`, token_type_hint: "refresh_token" });
  });

  it("Apple: still deletes when the revoke can't run, and says manual_revoke", async () => {
    const who = person("apple");
    const session = await signIn(who);
    const { code, verifier } = await confirm(session, who);
    env.APPLE_SIWA_P8 = undefined;
    expect(await (await post("/v1/account/delete", { handoff_code: code, handoff_verifier: verifier }, session.access)).json()).toEqual({ deleted: true, manual_revoke: true });
    expect(await accountExists(session.accountId)).toBe(false);
    expect(appleRest.calls).toEqual([]);
  });

  it("refuses a confirmation as an identity that isn't the account's, and makes no account for it", async () => {
    const who = person("apple");
    const session = await signIn(who);
    const otherAccount = person("apple");
    await signIn(otherAccount);
    const stranger = person("google");
    for (const as of [otherAccount, stranger]) {
      const { startUrl } = await deleteStart(session, as.provider);
      expect(await callback(await open(startUrl), as)).toBe("herdrup://account#delete_error=wrong_account");
    }
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM delete_handoffs WHERE account_id = ?").bind(session.accountId).first<{ n: number }>()).toEqual({ n: 0 });
    expect(await accountExists(session.accountId)).toBe(true);
    // The stranger got no account out of it: their first sign-in now makes one.
    const nonce = (await (await post("/v1/auth/nonce", {})).json<{ nonce: string }>()).nonce;
    const idToken = await signIdToken(keys.google, { iss: "https://accounts.google.com", aud: GOOGLE_IOS, sub: stranger.sub, nonce, iat: nowSeconds(), exp: nowSeconds() + 600 });
    expect((await (await post("/v1/auth/google", { id_token: idToken, nonce, platform: "macos" })).json<{ created: boolean }>()).created).toBe(true);
    expect(appleRest.calls).toEqual([]);
  });

  it("spends a code on any failure: wrong verifier, then the right one; expired; reused", async () => {
    const who = person("google");
    const session = await signIn(who);
    const first = await confirm(session, who);
    expect(await rejection(await post("/v1/account/delete", { handoff_code: first.code, handoff_verifier: randomB64url(48) }, session.access))).toEqual({
      status: 401,
      error: "invalid_verifier",
    });
    expect(await rejection(await post("/v1/account/delete", { handoff_code: first.code, handoff_verifier: first.verifier }, session.access))).toEqual({
      status: 401,
      error: "invalid_code",
    });

    const second = await confirm(session, who);
    await env.DB.prepare("UPDATE delete_handoffs SET exp_ms = ? WHERE code_hash = ?").bind(Date.now() - 1, await sha256(second.code)).run();
    expect(await rejection(await post("/v1/account/delete", { handoff_code: second.code, handoff_verifier: second.verifier }, session.access))).toEqual({
      status: 401,
      error: "code_expired",
    });
    expect(await rejection(await post("/v1/account/delete", { handoff_code: second.code, handoff_verifier: second.verifier }, session.access))).toEqual({
      status: 401,
      error: "invalid_code",
    });
    expect(await accountExists(session.accountId)).toBe(true);

    // A used code: the deletion went through, and the code is gone with the account.
    const third = await confirm(session, who);
    expect((await post("/v1/account/delete", { handoff_code: third.code, handoff_verifier: third.verifier }, session.access)).status).toBe(200);
    const again = await signIn(who);
    expect(await rejection(await post("/v1/account/delete", { handoff_code: third.code, handoff_verifier: third.verifier }, again.access))).toEqual({
      status: 401,
      error: "invalid_code",
    });
  });

  it("binds a code to the session that asked: another session, even of the same account, is refused and spends it", async () => {
    const who = person("google");
    const session = await signIn(who);
    const sameAccount = await signIn(who);
    expect(sameAccount.accountId).toBe(session.accountId);
    const { code, verifier } = await confirm(session, who);
    expect(await rejection(await post("/v1/account/delete", { handoff_code: code, handoff_verifier: verifier }, sameAccount.access))).toEqual({ status: 403, error: "wrong_account" });
    expect(await rejection(await post("/v1/account/delete", { handoff_code: code, handoff_verifier: verifier }, session.access))).toEqual({ status: 401, error: "invalid_code" });
    const other = await signIn(person("google"));
    const second = await confirm(session, who);
    expect(await rejection(await post("/v1/account/delete", { handoff_code: second.code, handoff_verifier: second.verifier }, other.access))).toEqual({ status: 403, error: "wrong_account" });
    expect(await accountExists(session.accountId)).toBe(true);
    expect(await accountExists(other.accountId)).toBe(true);
  });

  it("refuses malformed bodies and mixed proofs without spending the code", async () => {
    const who = person("google");
    const session = await signIn(who);
    const { code, verifier } = await confirm(session, who);
    for (const body of [
      { handoff_code: code },
      { handoff_verifier: verifier },
      { handoff_code: code, handoff_verifier: "short" },
      { handoff_code: "short", handoff_verifier: verifier },
      { handoff_code: code, handoff_verifier: verifier, provider: "google" },
      { handoff_code: code, handoff_verifier: verifier, id_token: "x", nonce: "y" },
    ]) {
      expect(await rejection(await post("/v1/account/delete", body, session.access))).toEqual({ status: 400, error: "bad_request" });
    }
    expect((await post("/v1/account/delete", { handoff_code: code, handoff_verifier: verifier }, session.access)).status).toBe(200);
  });
});

describe("sign-in and delete codes never stand in for each other", () => {
  /** A desktop sign-in through the web flow: its handoff code and verifier. */
  async function signInCode(who: Identity): Promise<{ code: string; verifier: string }> {
    const verifier = randomB64url(48);
    const start = `${ORIGIN}/v1/auth/web/start?provider=${who.provider}&client=app&platform=macos&handoff_challenge=${await s256(verifier)}`;
    const location = await callback(await open(start), who);
    const code = /^herdrup:\/\/account#code=([A-Za-z0-9_-]{43})$/.exec(location)?.[1];
    expect(code, location).toBeDefined();
    return { code: code!, verifier };
  }

  it("refuses a sign-in code for a deletion, and leaves it working for its sign-in", async () => {
    const who = person("google");
    const session = await signIn(who);
    const signin = await signInCode(who);
    expect(await rejection(await post("/v1/account/delete", { handoff_code: signin.code, handoff_verifier: signin.verifier }, session.access))).toEqual({
      status: 401,
      error: "invalid_code",
    });
    expect(await accountExists(session.accountId)).toBe(true);
    const redeemed = await post("/v1/auth/handoff", { code: signin.code, handoff_verifier: signin.verifier });
    expect(redeemed.status).toBe(200);
    expect((await redeemed.json<{ account_id: string }>()).account_id).toBe(session.accountId);
  });

  it("refuses a delete code at the sign-in handoff, and leaves it working for its deletion", async () => {
    const who = person("apple");
    const session = await signIn(who);
    const { code, verifier } = await confirm(session, who);
    expect(await rejection(await post("/v1/auth/handoff", { code, handoff_verifier: verifier }))).toEqual({ status: 401, error: "invalid_code" });
    // No session was opened by it.
    const sessions = await env.DB.prepare("SELECT COUNT(*) AS n FROM sessions WHERE account_id = ?").bind(session.accountId).first<{ n: number }>();
    expect(sessions?.n).toBe(1);
    expect((await post("/v1/account/delete", { handoff_code: code, handoff_verifier: verifier }, session.access)).status).toBe(200);
  });

  it("never signs anyone in from a deletion's flow, and never confirms a deletion from a sign-in's", async () => {
    const who = person("google");
    const session = await signIn(who);
    // A deletion's flow ends in delete_code, never code; a sign-in's in code, never delete_code.
    const { startUrl } = await deleteStart(session, "google");
    expect(await callback(await open(startUrl), who)).toMatch(/^herdrup:\/\/account#delete_code=/);
    const verifier = randomB64url(48);
    const start = `${ORIGIN}/v1/auth/web/start?provider=google&client=app&platform=macos&handoff_challenge=${await s256(verifier)}`;
    expect(await callback(await open(start), who)).toMatch(/^herdrup:\/\/account#code=/);
  });
});

describe("cleanup and deletion", () => {
  it("drops expired tickets and codes hourly, and a session's with the session", async () => {
    const who = person("google");
    const session = await signIn(who);
    const { startUrl } = await deleteStart(session, "google");
    const { code } = await confirm(session, who);
    const ticket = new URL(startUrl).searchParams.get("ticket")!;
    await env.DB.batch([
      env.DB.prepare("UPDATE delete_tickets SET exp_ms = ? WHERE ticket_hash = ?").bind(Date.now() - 1, await sha256(ticket)),
      env.DB.prepare("UPDATE delete_handoffs SET exp_ms = ? WHERE code_hash = ?").bind(Date.now() - 1, await sha256(code)),
    ]);
    await cleanup(env.DB, Date.now());
    expect(await env.DB.prepare("SELECT 1 FROM delete_tickets WHERE ticket_hash = ?").bind(await sha256(ticket)).first()).toBeNull();
    expect(await env.DB.prepare("SELECT 1 FROM delete_handoffs WHERE code_hash = ?").bind(await sha256(code)).first()).toBeNull();

    await deleteStart(session, "google");
    await confirm(session, who);
    await post("/v1/auth/signout", {}, session.access);
    for (const table of ["delete_tickets", "delete_handoffs", "web_flows"]) {
      const left = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE account_id = ?`).bind(session.accountId).first<{ n: number }>();
      expect(left?.n, table).toBe(0);
    }
  });
});
