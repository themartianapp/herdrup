import { SELF, env } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi, type MockInstance } from "vitest";
import { b64url, randomB64url, utf8 } from "../src/bytes";
import { cleanup } from "../src/cleanup";
import { serviceKeys, subjectHash } from "../src/keys";
import { fakeProviders, signIdToken, type Providers } from "./providers";

// The web sign-in flow, the handoff, the web guest's cookie and CORS, against the real Worker
// and a local D1 in workerd. Apple's and Google's ID-token keys are the test providers'
// (test/providers.ts); Google's token endpoint is stood in for below, and records what the
// Worker posts to it. No real client secret is read: the tests set their own.

const ORIGIN = "https://accounts.herdrup.app";
const GUEST = "https://guest.herdrup.app";
const APPLE_WEB = "com.jerryfane.herdr.signin";
const APPLE_APP = "com.jerryfane.herdr";
const GOOGLE_WEB = "test-web.apps.googleusercontent.com";
const GOOGLE_IOS = "test-ios.apps.googleusercontent.com";
const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GOOGLE_SECRET = "test-google-web-secret";

let keys: Providers;
let ipCounter = 0;
const freshIp = () => `2001:db8:5::${(++ipCounter).toString(16)}`;
const freshSub = () => `001234.${crypto.randomUUID().replace(/-/g, "")}.0500`;
const nowSeconds = () => Math.floor(Date.now() / 1000);
const s256 = async (text: string) => b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(text))));

/** What Google's token endpoint will answer for a code, and what the Worker posted to it. */
interface GoogleGrant {
  sub: string;
  nonce: string;
  challenge: string;
  email?: string;
  aud?: string;
}
const googleGrants = new Map<string, GoogleGrant>();
const googleCalls: Record<string, string>[] = [];
let googleDown = false;
/** Each access token the stand-in hands out: none may ever be stored or logged. */
const accessTokens: string[] = [];

beforeAll(async () => {
  keys = await fakeProviders();
  // Google's token endpoint, in front of the providers' JWKS stand-in.
  const spy = vi.mocked(globalThis.fetch);
  const inner = spy.getMockImplementation();
  spy.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : input.toString();
    if (url !== GOOGLE_TOKEN_URL) return inner!(input, init);
    const request = new Request(url, init);
    const form = Object.fromEntries(new URLSearchParams(new TextDecoder().decode(await request.arrayBuffer())));
    googleCalls.push(form);
    if (googleDown) return Response.json({ error: "internal_failure" }, { status: 500 });
    const grant = googleGrants.get(form.code);
    if (
      grant === undefined ||
      form.client_secret !== GOOGLE_SECRET ||
      form.client_id !== GOOGLE_WEB ||
      form.grant_type !== "authorization_code" ||
      form.redirect_uri !== `${ORIGIN}/v1/auth/web/google/callback` ||
      (await s256(form.code_verifier ?? "")) !== grant.challenge
    ) {
      return Response.json({ error: "invalid_grant" }, { status: 400 });
    }
    googleGrants.delete(form.code);
    const accessToken = `ya29.access-${randomB64url(24)}`;
    accessTokens.push(accessToken);
    const idToken = await signIdToken(keys.google, {
      iss: "https://accounts.google.com",
      aud: grant.aud ?? GOOGLE_WEB,
      sub: grant.sub,
      nonce: grant.nonce,
      iat: nowSeconds(),
      exp: nowSeconds() + 3600,
      ...(grant.email === undefined ? {} : { email: grant.email, email_verified: true }),
    });
    return Response.json({ access_token: accessToken, expires_in: 3599, scope: "openid email", token_type: "Bearer", id_token: idToken });
  });
});

beforeEach(() => {
  env.GOOGLE_WEB_CLIENT_SECRET = GOOGLE_SECRET;
  googleDown = false;
});

interface Started {
  response: Response;
  location: URL;
  state: string;
  nonce: string;
  /** The Cookie header the browser will send back: its __Host-hu_flow. */
  cookie: string;
  verifier: string;
}

/** GET /v1/auth/web/start as the browser does, with a fresh handoff verifier for client=app. */
async function start(provider: "apple" | "google", client: "app" | "web", ip = freshIp()): Promise<Started> {
  const verifier = randomB64url(48);
  const query = client === "app" ? `&platform=macos&handoff_challenge=${await s256(verifier)}` : "";
  const response = await SELF.fetch(`${ORIGIN}/v1/auth/web/start?provider=${provider}&client=${client}${query}`, {
    headers: { "CF-Connecting-IP": ip },
    redirect: "manual",
  });
  expect(response.status).toBe(303);
  const location = new URL(response.headers.get("Location")!);
  const flow = /__Host-hu_flow=([^;]+)/.exec(response.headers.get("Set-Cookie") ?? "")?.[1];
  return { response, location, state: location.searchParams.get("state")!, nonce: location.searchParams.get("nonce")!, cookie: `__Host-hu_flow=${flow}`, verifier };
}

async function appleIdToken(sub: string, nonce: string, extra: Record<string, unknown> = {}, key = keys.apple): Promise<string> {
  return signIdToken(key, { iss: "https://appleid.apple.com", aud: APPLE_WEB, sub, nonce, iat: nowSeconds(), exp: nowSeconds() + 600, ...extra });
}

/** Apple's form_post to the callback, from the browser holding `cookie`. */
function appleCallback(fields: Record<string, string>, cookie?: string, ip = freshIp()): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": ip };
  if (cookie !== undefined) headers.Cookie = cookie;
  return SELF.fetch(`${ORIGIN}/v1/auth/web/apple/callback`, { method: "POST", headers, body: new URLSearchParams(fields).toString(), redirect: "manual" });
}

/** Google's redirect back to the callback, after the user consented and `grant` was set up for its code. */
async function googleCallback(started: Started, grant: Omit<GoogleGrant, "nonce" | "challenge"> | null, extra: Record<string, string> = {}): Promise<Response> {
  const code = `4/0A${randomB64url(30)}`;
  if (grant !== null) googleGrants.set(code, { ...grant, nonce: started.nonce, challenge: started.location.searchParams.get("code_challenge")! });
  const query = new URLSearchParams({ state: started.state, code, scope: "openid email", ...extra });
  return SELF.fetch(`${ORIGIN}/v1/auth/web/google/callback?${query}`, { headers: { Cookie: started.cookie, "CF-Connecting-IP": freshIp() }, redirect: "manual" });
}

function handoff(body: unknown): Promise<Response> {
  return SELF.fetch(`${ORIGIN}/v1/auth/handoff`, {
    method: "POST",
    headers: { "content-type": "application/json", "CF-Connecting-IP": freshIp() },
    body: JSON.stringify(body),
  });
}

/** A call from the web guest's page: Origin guest.herdrup.app, with its cookies. */
function fromGuest(path: string, init: { method?: string; cookie?: string; access?: string; origin?: string } = {}): Promise<Response> {
  const headers: Record<string, string> = { Origin: init.origin ?? GUEST, "CF-Connecting-IP": freshIp() };
  if (init.cookie !== undefined) headers.Cookie = init.cookie;
  if (init.access !== undefined) headers.Authorization = `Bearer ${init.access}`;
  return SELF.fetch(`${ORIGIN}${path}`, { method: init.method ?? "POST", headers });
}

async function rejection(response: Response): Promise<Record<string, unknown>> {
  return { status: response.status, ...(await response.json<Record<string, unknown>>()) };
}

const location = (response: Response) => response.headers.get("Location");
const refreshFrom = (response: Response) => /__Host-hu_refresh=([^;]*)/.exec(response.headers.get("Set-Cookie") ?? "")?.[1];

async function identityCount(provider: "apple" | "google", sub: string): Promise<number> {
  const hash = await subjectHash((await serviceKeys(env.ACCOUNT_HMAC_KEY)!).subject, provider, sub);
  return (await env.DB.prepare("SELECT COUNT(*) AS n FROM identities WHERE provider = ? AND subject_hash = ?").bind(provider, hash).first<{ n: number }>())!.n;
}

/** Every value in every table, as text: for checking what is never stored. */
async function databaseText(): Promise<string> {
  const tables = await env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%'").all<{ name: string }>();
  let text = "";
  for (const { name } of tables.results) text += JSON.stringify((await env.DB.prepare(`SELECT * FROM "${name}"`).all()).results);
  return text;
}

/** The whole app flow with Apple, to the herdrup:// URL. */
async function appleAppFlow(sub = freshSub()): Promise<{ started: Started; code: string; sub: string }> {
  const started = await start("apple", "app");
  const response = await appleCallback({ state: started.state, code: "c.apple", id_token: await appleIdToken(sub, started.nonce) }, started.cookie);
  expect(response.status).toBe(303);
  const code = /^herdrup:\/\/account#code=([A-Za-z0-9_-]{43})$/.exec(location(response) ?? "")?.[1];
  expect(code, location(response) ?? "").toBeDefined();
  return { started, code: code!, sub };
}

describe("GET /v1/auth/web/start", () => {
  it("sends the browser to Apple with the Services ID, form_post, no scope, a state and a nonce, and binds the flow to the browser", async () => {
    const started = await start("apple", "app");
    expect(`${started.location.origin}${started.location.pathname}`).toBe("https://appleid.apple.com/auth/authorize");
    expect(Object.fromEntries(started.location.searchParams)).toEqual({
      client_id: APPLE_WEB,
      redirect_uri: `${ORIGIN}/v1/auth/web/apple/callback`,
      response_type: "code id_token",
      response_mode: "form_post",
      state: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
      nonce: expect.stringMatching(/^[A-Za-z0-9_-]{54}$/),
    });
    expect(started.response.headers.get("Location")).toContain("response_type=code%20id_token");
    expect(started.response.headers.get("Set-Cookie")).toMatch(/^__Host-hu_flow=[A-Za-z0-9_-]{43}; Max-Age=600; Path=\/; Secure; HttpOnly; SameSite=None$/);
    expect(started.response.headers.get("Referrer-Policy")).toBe("no-referrer");
    expect(started.response.headers.get("cache-control")).toBe("no-store");
    // Only hashes of the state and the browser cookie are kept.
    const text = await databaseText();
    expect(text).not.toContain(started.state);
    expect(text).not.toContain(started.cookie.split("=")[1]);
  });

  it("sends the browser to Google's web client with openid email and an S256 PKCE challenge", async () => {
    const started = await start("google", "web");
    expect(`${started.location.origin}${started.location.pathname}`).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    expect(Object.fromEntries(started.location.searchParams)).toEqual({
      client_id: GOOGLE_WEB,
      redirect_uri: `${ORIGIN}/v1/auth/web/google/callback`,
      response_type: "code",
      scope: "openid email",
      state: expect.any(String),
      nonce: expect.any(String),
      code_challenge: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
      code_challenge_method: "S256",
    });
  });

  it("refuses malformed starts", async () => {
    const challenge = await s256(randomB64url(32));
    for (const query of [
      "",
      "provider=github&client=web",
      "provider=apple&client=desk",
      "provider=apple&client=app&platform=macos",
      `provider=apple&client=app&handoff_challenge=${challenge}`,
      `provider=apple&client=app&platform=web&handoff_challenge=${challenge}`,
      "provider=apple&client=app&platform=macos&handoff_challenge=short",
      `provider=apple&client=web&handoff_challenge=${challenge}`,
      "provider=apple&client=web&platform=linux",
      "provider=apple&client=web&extra=1",
      "provider=apple&provider=google&client=web",
    ]) {
      const response = await SELF.fetch(`${ORIGIN}/v1/auth/web/start?${query}`, { headers: { "CF-Connecting-IP": freshIp() }, redirect: "manual" });
      expect({ query, ...(await rejection(response)) }).toEqual({ query, status: 400, error: "bad_request" });
    }
  });

  it("answers 503 for Google without GOOGLE_WEB_CLIENT_SECRET, while Apple's web flow still works", async () => {
    const logSpy = vi.spyOn(console, "log");
    try {
      env.GOOGLE_WEB_CLIENT_SECRET = undefined;
      for (const client of ["app", "web"]) {
        const query = client === "app" ? `&platform=linux&handoff_challenge=${await s256(randomB64url(32))}` : "";
        const response = await SELF.fetch(`${ORIGIN}/v1/auth/web/start?provider=google&client=${client}${query}`, { headers: { "CF-Connecting-IP": freshIp() } });
        expect(await rejection(response)).toEqual({ status: 503, error: "provider_not_configured" });
      }
      expect(logSpy.mock.calls.map((args) => String(args[0]))).toContain(JSON.stringify({ endpoint: "/v1/auth/web/start", outcome: "not_configured" }));
      const { code, started } = await appleAppFlow();
      expect((await handoff({ code, handoff_verifier: started.verifier })).status).toBe(200);
    } finally {
      logSpy.mockRestore();
    }
  });

  it("returns a Google flow started before the secret was removed to its client with an error, and calls nobody", async () => {
    const started = await start("google", "app");
    env.GOOGLE_WEB_CLIENT_SECRET = "";
    const calls = googleCalls.length;
    const response = await googleCallback(started, { sub: freshSub() });
    expect(location(response)).toBe("herdrup://account#error=provider_not_configured");
    expect(googleCalls.length).toBe(calls);
  });

  it("counts against the per-IP sign-in limit", async () => {
    const ip = freshIp();
    for (let i = 0; i < 20; i++) await start("apple", "web", ip);
    const response = await SELF.fetch(`${ORIGIN}/v1/auth/web/start?provider=apple&client=web`, { headers: { "CF-Connecting-IP": ip } });
    expect(await rejection(response)).toEqual({ status: 429, error: "rate_limited" });
  });
});

describe("Apple callback (form_post)", () => {
  it("client=app: hands off a code that only the verifier redeems, for a session on the right account", async () => {
    const { code, started, sub } = await appleAppFlow();
    const response = await handoff({ code, handoff_verifier: started.verifier });
    expect(response.status).toBe(200);
    const tokens = await response.json<{ account_id: string; access_token: string; refresh_token: string; created: boolean; display_hint?: string }>();
    expect(tokens).toMatchObject({ created: true, access_expires_in: 3600, refresh_expires_in: 7776000 });
    expect(tokens.display_hint).toBeUndefined();
    const account = await SELF.fetch(`${ORIGIN}/v1/account`, { headers: { Authorization: `Bearer ${tokens.access_token}` } });
    expect((await account.json<{ account_id: string }>()).account_id).toBe(tokens.account_id);
    const session = await env.DB.prepare("SELECT platform FROM sessions WHERE id = ?").bind(tokens.access_token.split(".")[1]).first<{ platform: string }>();
    expect(session?.platform).toBe("macos");
    // The same person again: the same account, not created.
    const again = await appleAppFlow(sub);
    const second = await (await handoff({ code: again.code, handoff_verifier: again.started.verifier })).json<{ account_id: string; created: boolean }>();
    expect(second).toMatchObject({ account_id: tokens.account_id, created: false });
  });

  it("client=web: sets the refresh cookie (HttpOnly, Secure, SameSite=Strict, Path=/, 90 days) and returns to the web guest", async () => {
    const started = await start("apple", "web");
    const response = await appleCallback({ state: started.state, code: "c", id_token: await appleIdToken(freshSub(), started.nonce) }, started.cookie);
    expect(response.status).toBe(303);
    expect(location(response)).toBe(`${GUEST}/web/?account=1`);
    expect(response.headers.get("Referrer-Policy")).toBe("no-referrer");
    const cookies = response.headers.getSetCookie();
    expect(cookies).toHaveLength(2);
    expect(cookies[0]).toMatch(/^__Host-hu_refresh=r1\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}; Max-Age=7776000; Path=\/; Secure; HttpOnly; SameSite=Strict$/);
    expect(cookies[1]).toBe("__Host-hu_flow=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=None");
    const session = await env.DB.prepare("SELECT platform FROM sessions WHERE id = ?").bind(refreshFrom(response)!.split(".")[1]).first<{ platform: string }>();
    expect(session?.platform).toBe("web");
  });

  it("refuses a state the second time, and a state of the other provider", async () => {
    const started = await start("apple", "app");
    const fields = { state: started.state, code: "c", id_token: await appleIdToken(freshSub(), started.nonce) };
    expect((await appleCallback(fields, started.cookie)).status).toBe(303);
    expect(await rejection(await appleCallback(fields, started.cookie))).toEqual({ status: 400, error: "state_invalid" });
    const google = await start("google", "app");
    expect(await rejection(await appleCallback({ ...fields, state: google.state }, google.cookie))).toEqual({ status: 400, error: "state_invalid" });
    for (const state of [undefined, "", "short", started.state.slice(1)]) {
      const body: Record<string, string> = { code: "c", id_token: "x" };
      if (state !== undefined) body.state = state;
      expect(await rejection(await appleCallback(body, started.cookie))).toEqual({ status: 400, error: "state_invalid" });
    }
  });

  it("refuses an expired flow, and a callback from another browser, and spends the state either way", async () => {
    const sub = freshSub();
    const expired = await start("apple", "web");
    await env.DB.prepare("UPDATE web_flows SET exp_ms = ? WHERE state_hash = ?").bind(Date.now() - 1, await sha256(expired.state)).run();
    const late = await appleCallback({ state: expired.state, id_token: await appleIdToken(sub, expired.nonce) }, expired.cookie);
    expect(location(late)).toBe(`${GUEST}/web/?account_error=flow_expired`);
    expect(late.headers.getSetCookie()).toEqual(["__Host-hu_flow=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=None"]);

    for (const cookie of [undefined, `__Host-hu_flow=${randomB64url(32)}`, "__Host-hu_flow=x"]) {
      const started = await start("apple", "app");
      const fields = { state: started.state, id_token: await appleIdToken(sub, started.nonce) };
      expect(location(await appleCallback(fields, cookie))).toBe("herdrup://account#error=browser_mismatch");
      // The flow is spent: its own browser can't finish it now either.
      expect(await rejection(await appleCallback(fields, started.cookie))).toEqual({ status: 400, error: "state_invalid" });
    }
    expect(await identityCount("apple", sub)).toBe(0);
  });

  it("refuses a bad id_token: another key, a native audience, the wrong nonce, expired, or none", async () => {
    const sub = freshSub();
    const cases: [(nonce: string) => Promise<string | undefined>, string][] = [
      [(nonce) => appleIdToken(sub, nonce, {}, keys.stranger), "token_invalid"],
      [(nonce) => appleIdToken(sub, nonce, { aud: APPLE_APP }), "token_invalid"],
      [async () => appleIdToken(sub, randomB64url(40)), "token_invalid"],
      [(nonce) => appleIdToken(sub, nonce, { iat: nowSeconds() - 3600, exp: nowSeconds() - 1800 }), "token_invalid"],
      [async (nonce) => `${(await appleIdToken(sub, nonce)).slice(0, -4)}AAAA`, "token_invalid"],
      [async () => undefined, "token_invalid"],
    ];
    for (const [token, error] of cases) {
      const started = await start("apple", "app");
      const idToken = await token(started.nonce);
      const fields: Record<string, string> = { state: started.state, code: "c" };
      if (idToken !== undefined) fields.id_token = idToken;
      expect(location(await appleCallback(fields, started.cookie))).toBe(`herdrup://account#error=${error}`);
    }
    expect(await identityCount("apple", sub)).toBe(0);
  });

  it("returns a cancelled sign-in to its client", async () => {
    const started = await start("apple", "web");
    const response = await appleCallback({ state: started.state, error: "user_cancelled_authorize" }, started.cookie);
    expect(location(response)).toBe(`${GUEST}/web/?account_error=cancelled`);
  });
});

async function sha256(text: string): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(text))), (b) => b.toString(16).padStart(2, "0")).join("");
}

describe("POST /v1/auth/handoff", () => {
  it("refuses a missing or malformed verifier without spending the code", async () => {
    const { code, started } = await appleAppFlow();
    for (const body of [{ code }, { code, handoff_verifier: "" }, { code, handoff_verifier: "short" }, { code, handoff_verifier: 42 }, { handoff_verifier: started.verifier }]) {
      expect(await rejection(await handoff(body))).toEqual({ status: 400, error: "bad_request" });
    }
    expect((await handoff({ code, handoff_verifier: started.verifier })).status).toBe(200);
  });

  it("refuses the wrong verifier and spends the code, so the right one can't follow", async () => {
    const { code, started } = await appleAppFlow();
    expect(await rejection(await handoff({ code, handoff_verifier: randomB64url(48) }))).toEqual({ status: 401, error: "invalid_verifier" });
    expect(await rejection(await handoff({ code, handoff_verifier: started.verifier }))).toEqual({ status: 401, error: "invalid_code" });
  });

  it("redeems a code once", async () => {
    const { code, started } = await appleAppFlow();
    expect((await handoff({ code, handoff_verifier: started.verifier })).status).toBe(200);
    expect(await rejection(await handoff({ code, handoff_verifier: started.verifier }))).toEqual({ status: 401, error: "invalid_code" });
    expect(await rejection(await handoff({ code: randomB64url(32), handoff_verifier: started.verifier }))).toEqual({ status: 401, error: "invalid_code" });
  });

  it("refuses a code past its 2 minutes", async () => {
    const { code, started } = await appleAppFlow();
    await env.DB.prepare("UPDATE handoffs SET exp_ms = ? WHERE code_hash = ?").bind(Date.now() - 1, await sha256(code)).run();
    expect(await rejection(await handoff({ code, handoff_verifier: started.verifier }))).toEqual({ status: 401, error: "code_expired" });
  });
});

describe("Google callback", () => {
  let logSpy: MockInstance<typeof console.log>;

  beforeEach(() => {
    logSpy = vi.spyOn(console, "log");
  });

  afterEach(() => {
    logSpy.mockRestore();
  });

  it("exchanges the code with the secret and PKCE verifier, keeps only the id_token, and never stores or logs the access token", async () => {
    const started = await start("google", "app");
    const callsBefore = googleCalls.length;
    const response = await googleCallback(started, { sub: freshSub(), email: "luca@example.com" });
    const code = /^herdrup:\/\/account#code=(.+)$/.exec(location(response) ?? "")?.[1];
    expect(code, location(response) ?? "").toBeDefined();
    expect(googleCalls.length).toBe(callsBefore + 1);
    expect(googleCalls[googleCalls.length - 1]).toEqual({
      code: expect.any(String),
      client_id: GOOGLE_WEB,
      client_secret: GOOGLE_SECRET,
      redirect_uri: `${ORIGIN}/v1/auth/web/google/callback`,
      grant_type: "authorization_code",
      code_verifier: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
    });
    const accessToken = accessTokens[accessTokens.length - 1];
    // Neither the access token nor the email waits in D1 readably.
    const stored = await databaseText();
    expect(stored).not.toContain(accessToken);
    expect(stored).not.toContain("luca@example.com");
    expect(stored).not.toContain(GOOGLE_SECRET);

    const redeemed = await (await handoff({ code, handoff_verifier: started.verifier })).json<Record<string, unknown>>();
    expect(redeemed).toMatchObject({ created: true, display_hint: "luca@example.com" });
    expect(JSON.stringify(redeemed)).not.toContain(accessToken);
    expect(await databaseText()).not.toContain(accessToken);
    for (const args of logSpy.mock.calls) {
      const line = String(args[0]);
      for (const secret of [accessToken, GOOGLE_SECRET, started.state, code!, "luca@example.com"]) expect(line).not.toContain(secret);
    }
  });

  it("client=web: sets the refresh cookie", async () => {
    const started = await start("google", "web");
    const response = await googleCallback(started, { sub: freshSub() });
    expect(location(response)).toBe(`${GUEST}/web/?account=1`);
    expect(refreshFrom(response)).toMatch(/^r1\./);
  });

  it("returns a failed exchange, a refusal and a token for another client to the client with an error", async () => {
    const sub = freshSub();
    let started = await start("google", "app");
    googleDown = true;
    expect(location(await googleCallback(started, { sub }))).toBe("herdrup://account#error=exchange_failed");
    googleDown = false;
    started = await start("google", "app");
    // Google refuses the code (here: no grant for it).
    expect(location(await googleCallback(started, null))).toBe("herdrup://account#error=exchange_failed");
    started = await start("google", "app");
    expect(location(await googleCallback(started, { sub, aud: GOOGLE_IOS }))).toBe("herdrup://account#error=token_invalid");
    started = await start("google", "web");
    expect(location(await googleCallback(started, null, { error: "access_denied" }))).toBe(`${GUEST}/web/?account_error=cancelled`);
    expect(await identityCount("google", sub)).toBe(0);
  });
});

describe("the web guest's cookie", () => {
  async function signedInCookie(): Promise<string> {
    const started = await start("apple", "web");
    const response = await appleCallback({ state: started.state, id_token: await appleIdToken(freshSub(), started.nonce) }, started.cookie);
    return refreshFrom(response)!;
  }

  it("refreshes from the cookie, rotates it, and never shows the page a refresh token", async () => {
    const first = await signedInCookie();
    const response = await fromGuest("/v1/auth/refresh", { cookie: `__Host-hu_refresh=${first}` });
    expect(response.status).toBe(200);
    const body = await response.json<Record<string, unknown>>();
    expect(Object.keys(body).sort()).toEqual(["access_expires_in", "access_token", "account_id"]);
    const second = refreshFrom(response)!;
    expect(second).not.toBe(first);
    expect(response.headers.get("Set-Cookie")).toBe(`__Host-hu_refresh=${second}; Max-Age=7776000; Path=/; Secure; HttpOnly; SameSite=Strict`);
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe(GUEST);
    const account = await fromGuest("/v1/account", { method: "GET", access: body.access_token as string });
    expect(account.status).toBe(200);
    // The rotated-away cookie is theft: the session ends and the cookie is cleared.
    const replay = await fromGuest("/v1/auth/refresh", { cookie: `__Host-hu_refresh=${first}` });
    expect(await rejection(replay)).toEqual({ status: 401, error: "session_revoked" });
    expect(replay.headers.get("Set-Cookie")).toBe("__Host-hu_refresh=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Strict");
    expect(await rejection(await fromGuest("/v1/auth/refresh"))).toEqual({ status: 401, error: "invalid_token" });
  });

  it("uses the cookie only from the web guest's origin", async () => {
    const cookie = await signedInCookie();
    for (const origin of ["https://evil.example", "https://herdrup.app", "https://other.herdrup.app", "null"]) {
      const response = await fromGuest("/v1/auth/refresh", { cookie: `__Host-hu_refresh=${cookie}`, origin });
      expect({ origin, ...(await rejection(response)) }).toEqual({ origin, status: 400, error: "bad_request" });
      expect(response.headers.get("Set-Cookie")).toBeNull();
    }
    expect((await fromGuest("/v1/auth/refresh", { cookie: `__Host-hu_refresh=${cookie}` })).status).toBe(200);
  });

  it("signs out by the cookie and clears it, even without a session", async () => {
    const cookie = await signedInCookie();
    const response = await fromGuest("/v1/auth/signout", { cookie: `__Host-hu_refresh=${cookie}` });
    expect(response.status).toBe(204);
    expect(response.headers.get("Set-Cookie")).toBe("__Host-hu_refresh=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Strict");
    expect(await rejection(await fromGuest("/v1/auth/refresh", { cookie: `__Host-hu_refresh=${cookie}` }))).toEqual({ status: 401, error: "invalid_token" });
    expect((await fromGuest("/v1/auth/signout")).status).toBe(204);
  });
});

describe("CORS", () => {
  it("answers preflights from guest.herdrup.app only, with credentials, for the web guest's endpoints", async () => {
    const preflight = (path: string, origin: string | null, method = "POST") => {
      const headers: Record<string, string> = { "Access-Control-Request-Method": method, "Access-Control-Request-Headers": "authorization, content-type" };
      if (origin !== null) headers.Origin = origin;
      return SELF.fetch(`${ORIGIN}${path}`, { method: "OPTIONS", headers });
    };
    const allowed = await preflight("/v1/sync", GUEST, "GET");
    expect(allowed.status).toBe(204);
    expect(Object.fromEntries([...allowed.headers].filter(([name]) => name.startsWith("access-control") || name === "vary"))).toEqual({
      "access-control-allow-origin": GUEST,
      "access-control-allow-credentials": "true",
      "access-control-allow-methods": "GET, POST",
      "access-control-allow-headers": "authorization, content-type",
      "access-control-max-age": "600",
      vary: "Origin",
    });
    expect((await preflight(`/v1/devices/${randomB64url(16)}`, GUEST, "DELETE")).status).toBe(204);
    for (const path of ["/v1/auth/refresh", "/v1/auth/signout", "/v1/account", "/v1/devices", "/v1/devices/challenge", "/v1/statements"]) {
      expect((await preflight(path, GUEST, path === "/v1/account" ? "GET" : "POST")).status, path).toBe(204);
    }
    for (const [path, origin, method] of [
      ["/v1/sync", "https://evil.example", "GET"],
      ["/v1/sync", "https://herdrup.app", "GET"],
      ["/v1/sync", "http://guest.herdrup.app", "GET"],
      ["/v1/sync", null, "GET"],
      ["/v1/sync", GUEST, "DELETE"],
    ] as const) {
      const refused = await preflight(path, origin, method);
      expect(refused.status).toBe(403);
      expect(refused.headers.get("Access-Control-Allow-Origin")).toBeNull();
      expect(refused.headers.get("Access-Control-Allow-Credentials")).toBeNull();
    }
    // Endpoints the page never calls have no CORS at all.
    for (const path of ["/v1/auth/nonce", "/v1/auth/handoff", "/v1/auth/apple", "/v1/auth/web/start", "/.well-known/jwks.json"]) {
      const response = await preflight(path, GUEST);
      expect(response.status, path).toBe(405);
      expect(response.headers.get("Access-Control-Allow-Origin"), path).toBeNull();
    }
  });

  it("lets only guest.herdrup.app read answers, errors included, and never says *", async () => {
    const forGuest = await fromGuest("/v1/account", { method: "GET" });
    expect(forGuest.status).toBe(401);
    expect(forGuest.headers.get("Access-Control-Allow-Origin")).toBe(GUEST);
    expect(forGuest.headers.get("Access-Control-Allow-Credentials")).toBe("true");
    expect(forGuest.headers.get("Vary")).toBe("Origin");
    for (const origin of ["https://evil.example", "https://herdrup.app"]) {
      const other = await fromGuest("/v1/account", { method: "GET", origin });
      expect(other.headers.get("Access-Control-Allow-Origin")).toBeNull();
      expect(other.headers.get("Access-Control-Allow-Credentials")).toBeNull();
    }
    const native = await SELF.fetch(`${ORIGIN}/v1/account`);
    expect(native.headers.get("Access-Control-Allow-Origin")).toBeNull();
    const start = await SELF.fetch(`${ORIGIN}/v1/auth/web/start?provider=apple&client=web`, { headers: { Origin: GUEST, "CF-Connecting-IP": freshIp() }, redirect: "manual" });
    expect(start.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });
});

describe("cleanup", () => {
  it("drops expired flows and handoffs, and an account's handoffs with the account", async () => {
    const pending = await start("apple", "app");
    const { code } = await appleAppFlow();
    await env.DB.batch([
      env.DB.prepare("UPDATE web_flows SET exp_ms = ? WHERE state_hash = ?").bind(Date.now() - 1, await sha256(pending.state)),
      env.DB.prepare("UPDATE handoffs SET exp_ms = ? WHERE code_hash = ?").bind(Date.now() - 1, await sha256(code)),
    ]);
    await cleanup(env.DB, Date.now());
    expect(await env.DB.prepare("SELECT 1 FROM web_flows WHERE state_hash = ?").bind(await sha256(pending.state)).first()).toBeNull();
    expect(await env.DB.prepare("SELECT 1 FROM handoffs WHERE code_hash = ?").bind(await sha256(code)).first()).toBeNull();

    const live = await appleAppFlow();
    const owner = await env.DB.prepare("SELECT account_id FROM handoffs WHERE code_hash = ?").bind(await sha256(live.code)).first<{ account_id: string }>();
    await env.DB.prepare("DELETE FROM accounts WHERE id = ?").bind(owner!.account_id).run();
    expect(await rejection(await handoff({ code: live.code, handoff_verifier: live.started.verifier }))).toEqual({ status: 401, error: "invalid_code" });
  });
});
