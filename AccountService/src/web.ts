// The web sign-in flow for herdrup-desktop (client=app) and the web guest (client=web),
// DESIGN.md §2.3 and §2.6:
//
//   GET  /v1/auth/web/start?provider=apple|google&client=app&platform=…&handoff_challenge=S256(v)
//   GET  /v1/auth/web/start?provider=apple|google&client=web
//        → 303 to Apple or Google, with the __Host-hu_flow cookie
//   POST /v1/auth/web/apple/callback   Apple's form_post {state, code, id_token, user?, error?}
//   GET  /v1/auth/web/google/callback  ?state&code (or ?state&error)
//        → client=app: 303 herdrup://account#code=<code>
//          client=web: 303 https://guest.herdrup.app/web/?account=1, with the refresh cookie
//          a failure once the flow is known: 303 to the same place with error=<code>
//   POST /v1/auth/handoff  {code, handoff_verifier} → the same answer as a native sign-in
//
// A flow is one web_flows row, 10 minutes, taken (deleted) by the first callback naming its
// state, so a state never works twice. The callback must come from the browser that started
// the flow (its __Host-hu_flow cookie), which stops a page from finishing someone else's flow in
// the victim's browser. The ID token must carry the flow's nonce (issued and spent like a
// native sign-in's) and name our web client: the Services ID for Apple, the web client for
// Google.
//
// Apple's ID token arrives in its form_post, so signing in needs no Apple secret. Google's code
// is exchanged at its token endpoint with GOOGLE_WEB_CLIENT_SECRET and the PKCE verifier; only
// the id_token of the answer is read, and the access token is dropped unread. Without the secret
// the Google web flow answers 503 provider_not_configured; Apple's is unaffected.
//
// client=app: the account's session is opened only when the app redeems the code with the
// verifier whose S256 the flow carried, so an app that grabs the herdrup:// URL can't use it.
// A code is spent by its first redemption, whatever the verifier.
//
// Nothing here logs or stores state, codes, verifiers or provider tokens.
import { findOrCreateAccount, MAX_AUTH_BODY_BYTES, openAuthRequest, proveIdentity } from "./auth";
import { clearFlowCookie, FLOW_COOKIE, FLOW_TTL_MS, flowCookie, readCookie, refreshCookie, webOrigin } from "./browser";
import { b64url, fromB64url, randomB64url, sameString, sha256Hex, utf8 } from "./bytes";
import type { Env } from "./env";
import { errorResponse, json, log, readCapped, readJsonObject, type Endpoint } from "./http";
import { APPLE_ISSUER, APPLE_JWKS, GOOGLE_ISSUERS, GOOGLE_JWKS, type ProviderConfig } from "./idtoken";
import type { Provider, ServiceKeys } from "./keys";
import { issueNonce } from "./nonce";
import { openSession, PLATFORMS, type Platform } from "./sessions";

const SELF_ORIGIN = "https://accounts.herdrup.app";
export const APPLE_CALLBACK = `${SELF_ORIGIN}/v1/auth/web/apple/callback`;
export const GOOGLE_CALLBACK = `${SELF_ORIGIN}/v1/auth/web/google/callback`;
export const APPLE_AUTHORIZE = "https://appleid.apple.com/auth/authorize";
export const GOOGLE_AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
export const APP_REDIRECT = "herdrup://account";
export const HANDOFF_TTL_MS = 2 * 60 * 1000;
/** Apple's form_post: an ID token (~1 KB), a code, the state, and on first consent a small `user` JSON. */
export const MAX_CALLBACK_BODY_BYTES = 8192;
const FETCH_TIMEOUT_MS = 5000;
/** 32 random bytes in base64url: states, codes, flow cookies, and S256 challenges. */
const B64URL_32 = /^[A-Za-z0-9_-]{43}$/;
/** RFC 7636 §4.1. */
const VERIFIER = /^[A-Za-z0-9._~-]{43,128}$/;

interface FlowRow {
  provider: Provider;
  client: "app" | "web";
  platform: string;
  browser_hash: string;
  nonce: string;
  pkce_verifier: string | null;
  handoff_challenge: string | null;
  exp_ms: number;
}

interface HandoffRow {
  account_id: string;
  handoff_challenge: string;
  platform: string;
  created: number;
  display_hint: string | null;
  exp_ms: number;
}

const s256 = async (verifier: string): Promise<string> => b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(verifier))));

/** The provider's web client only: a token minted for a native client has no business in this flow. */
function webClient(env: Env, provider: Provider): ProviderConfig | null {
  const audience = provider === "apple" ? env.APPLE_WEB_CLIENT_ID : env.GOOGLE_WEB_CLIENT_ID;
  if (audience === undefined || audience.length === 0) return null;
  return provider === "apple"
    ? { provider, issuers: [APPLE_ISSUER], audiences: [audience], jwks: APPLE_JWKS }
    : { provider, issuers: GOOGLE_ISSUERS, audiences: [audience], jwks: GOOGLE_JWKS };
}

const googleSecret = (env: Env): string | null => {
  const secret = env.GOOGLE_WEB_CLIENT_SECRET?.trim() ?? "";
  return secret.length > 0 ? secret : null;
};

/** Whether the flow for `provider` and `client` can run: its client id, Google's secret, and for the web guest its origin. */
function configured(env: Env, provider: Provider, client: FlowRow["client"]): boolean {
  return webClient(env, provider) !== null && (provider === "apple" || googleSecret(env) !== null) && (client === "app" || webOrigin(env) !== null);
}

function redirect(location: string, cookies: string[] = []): Response {
  // no-referrer: the callback URL carries the state and code, and the start URL the challenge.
  const headers = new Headers({ Location: location, "cache-control": "no-store", "Referrer-Policy": "no-referrer" });
  for (const cookie of cookies) headers.append("Set-Cookie", cookie);
  return new Response(null, { status: 303, headers });
}

function notConfigured(endpoint: Endpoint): Response {
  log({ endpoint, outcome: "not_configured" });
  return errorResponse(503, "provider_not_configured");
}

export async function handleWebStart(request: Request, env: Env, nowMs: number): Promise<Response> {
  const endpoint = "/v1/auth/web/start";
  const keys = await openAuthRequest(request, env, endpoint);
  if (keys instanceof Response) return keys;
  const query = new URL(request.url).searchParams;
  const names = [...query.keys()];
  const allowed = ["provider", "client", "platform", "handoff_challenge"];
  if (names.some((name) => !allowed.includes(name)) || new Set(names).size !== names.length) return errorResponse(400, "bad_request");
  const provider = query.get("provider");
  const client = query.get("client");
  if ((provider !== "apple" && provider !== "google") || (client !== "app" && client !== "web")) return errorResponse(400, "bad_request");
  let platform: Platform = "web";
  let handoffChallenge: string | null = null;
  if (client === "app") {
    const requested = query.get("platform") ?? "";
    const challenge = query.get("handoff_challenge") ?? "";
    if (!PLATFORMS.includes(requested as Platform) || requested === "web" || !B64URL_32.test(challenge)) return errorResponse(400, "bad_request");
    platform = requested as Platform;
    handoffChallenge = challenge;
  } else if (names.length !== 2) {
    // The web guest's session lands in its cookie: no platform choice, nothing to hand off.
    return errorResponse(400, "bad_request");
  }
  const config = webClient(env, provider);
  if (config === null || !configured(env, provider, client)) return notConfigured(endpoint);

  const state = randomB64url(32);
  const browser = randomB64url(32);
  const { nonce } = await issueNonce(keys.nonce, nowMs);
  const pkceVerifier = provider === "google" ? randomB64url(32) : null;
  await env.DB.prepare(
    `INSERT INTO web_flows (state_hash, provider, client, platform, browser_hash, nonce, pkce_verifier, handoff_challenge, exp_ms)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(await sha256Hex(state), provider, client, platform, await sha256Hex(browser), nonce, pkceVerifier, handoffChallenge, nowMs + FLOW_TTL_MS)
    .run();

  const params: Record<string, string> =
    provider === "apple"
      ? // No scope: Apple then sends neither name nor email, and the ID token comes in the form_post.
        { client_id: config.audiences[0], redirect_uri: APPLE_CALLBACK, response_type: "code id_token", response_mode: "form_post", state, nonce }
      : {
          client_id: config.audiences[0],
          redirect_uri: GOOGLE_CALLBACK,
          response_type: "code",
          scope: "openid email",
          state,
          nonce,
          code_challenge: await s256(pkceVerifier ?? ""),
          code_challenge_method: "S256",
        };
  // URLSearchParams writes a space as "+"; the providers' documentation writes %20.
  const search = new URLSearchParams(params).toString().replace(/\+/g, "%20");
  return redirect(`${provider === "apple" ? APPLE_AUTHORIZE : GOOGLE_AUTHORIZE}?${search}`, [flowCookie(browser)]);
}

/** Takes (deletes) the flow `state` names for `provider`, or the error to answer with. A state works once. */
async function takeFlow(env: Env, provider: Provider, state: string | null): Promise<FlowRow | Response> {
  if (state === null || !B64URL_32.test(state)) return errorResponse(400, "state_invalid");
  const flow = await env.DB.prepare("DELETE FROM web_flows WHERE state_hash = ? AND provider = ? RETURNING *")
    .bind(await sha256Hex(state), provider)
    .first<FlowRow>();
  return flow ?? errorResponse(400, "state_invalid");
}

/** Back to the client that started the flow, with `error`. */
function back(env: Env, flow: FlowRow, error: string): Response {
  const location = flow.client === "app" ? `${APP_REDIRECT}#error=${error}` : `${webOrigin(env) ?? ""}/web/?account_error=${error}`;
  return redirect(location, [clearFlowCookie()]);
}

/** The flow's own checks once taken: not expired, from the browser that started it, still configured. Null when it may go on. */
async function refuseFlow(request: Request, env: Env, flow: FlowRow, endpoint: Endpoint, nowMs: number): Promise<Response | null> {
  if (flow.client === "web" && webOrigin(env) === null) return notConfigured(endpoint);
  if (flow.exp_ms <= nowMs) return back(env, flow, "flow_expired");
  const browser = readCookie(request, FLOW_COOKIE);
  if (browser === null || !B64URL_32.test(browser) || !sameString(await sha256Hex(browser), flow.browser_hash)) return back(env, flow, "browser_mismatch");
  if (!configured(env, flow.provider, flow.client)) {
    log({ endpoint, outcome: "not_configured" });
    return back(env, flow, "provider_not_configured");
  }
  return null;
}

/** Finishes the flow with the provider's ID token: verified against the flow's nonce, then the account and its session or handoff. */
async function finish(env: Env, keys: ServiceKeys, flow: FlowRow, idToken: string, endpoint: Endpoint, nowMs: number): Promise<Response> {
  const config = webClient(env, flow.provider);
  if (config === null) return back(env, flow, "provider_not_configured");
  const proof = await proveIdentity(env.DB, keys, config, endpoint, idToken, flow.nonce, nowMs);
  if (proof instanceof Response) {
    const { error } = await proof.json<{ error: string }>();
    return back(env, flow, error);
  }
  const { accountId, created } = await findOrCreateAccount(env.DB, flow.provider, proof.subjectHash, nowMs);

  if (flow.client === "web") {
    const tokens = await openSession(env.DB, accountId, "web", nowMs);
    return redirect(`${webOrigin(env) ?? ""}/web/?account=1`, [refreshCookie(tokens.refresh_token), clearFlowCookie()]);
  }
  const code = crypto.getRandomValues(new Uint8Array(32));
  const codeText = b64url(code);
  const hint = proof.token.email === undefined ? null : await sealHint(code, proof.token.email);
  await env.DB.prepare(
    "INSERT INTO handoffs (code_hash, account_id, handoff_challenge, platform, created, display_hint, exp_ms) VALUES (?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(await sha256Hex(codeText), accountId, flow.handoff_challenge, flow.platform, created ? 1 : 0, hint, nowMs + HANDOFF_TTL_MS)
    .run();
  return redirect(`${APP_REDIRECT}#code=${codeText}`, [clearFlowCookie()]);
}

export async function handleAppleCallback(request: Request, env: Env, nowMs: number): Promise<Response> {
  const endpoint = "/v1/auth/web/apple/callback";
  const keys = await openAuthRequest(request, env, endpoint);
  if (keys instanceof Response) return keys;
  const raw = await readCapped(request, MAX_CALLBACK_BODY_BYTES);
  if (raw === null) return errorResponse(413, "too_large");
  let form: URLSearchParams;
  try {
    form = new URLSearchParams(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(raw));
  } catch {
    return errorResponse(400, "bad_request");
  }
  const flow = await takeFlow(env, "apple", form.get("state"));
  if (flow instanceof Response) return flow;
  const refused = await refuseFlow(request, env, flow, endpoint, nowMs);
  if (refused !== null) return refused;
  const error = form.get("error");
  if (error !== null) return back(env, flow, error === "user_cancelled_authorize" ? "cancelled" : "provider_error");
  const idToken = form.get("id_token");
  if (idToken === null || idToken.length === 0) return back(env, flow, "token_invalid");
  return finish(env, keys, flow, idToken, endpoint, nowMs);
}

/** The id_token from exchanging `code` at Google, or null. Nothing else in Google's answer is read or kept. */
async function exchangeGoogleCode(env: Env, secret: string, code: string, verifier: string): Promise<string | null> {
  try {
    const response = await fetch(GOOGLE_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: new URLSearchParams({
        code,
        client_id: env.GOOGLE_WEB_CLIENT_ID ?? "",
        client_secret: secret,
        redirect_uri: GOOGLE_CALLBACK,
        grant_type: "authorization_code",
        code_verifier: verifier,
      }).toString(),
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!response.ok) return null;
    const answer: unknown = await response.json();
    const idToken = typeof answer === "object" && answer !== null && "id_token" in answer ? answer.id_token : undefined;
    return typeof idToken === "string" && idToken.length > 0 ? idToken : null;
  } catch {
    return null;
  }
}

export async function handleGoogleCallback(request: Request, env: Env, nowMs: number): Promise<Response> {
  const endpoint = "/v1/auth/web/google/callback";
  const keys = await openAuthRequest(request, env, endpoint);
  if (keys instanceof Response) return keys;
  const query = new URL(request.url).searchParams;
  const flow = await takeFlow(env, "google", query.get("state"));
  if (flow instanceof Response) return flow;
  const refused = await refuseFlow(request, env, flow, endpoint, nowMs);
  if (refused !== null) return refused;
  const error = query.get("error");
  if (error !== null) return back(env, flow, error === "access_denied" ? "cancelled" : "provider_error");
  const code = query.get("code");
  const secret = googleSecret(env);
  if (code === null || code.length === 0 || code.length > 2048 || secret === null || flow.pkce_verifier === null) return back(env, flow, "provider_error");
  const idToken = await exchangeGoogleCode(env, secret, code, flow.pkce_verifier);
  if (idToken === null) return back(env, flow, "exchange_failed");
  return finish(env, keys, flow, idToken, endpoint, nowMs);
}

export async function handleHandoff(request: Request, env: Env, nowMs: number): Promise<Response> {
  const keys = await openAuthRequest(request, env, "/v1/auth/handoff");
  if (keys instanceof Response) return keys;
  const body = await readJsonObject(request, MAX_AUTH_BODY_BYTES);
  if (body instanceof Response) return body;
  const { code, handoff_verifier: verifier } = body;
  if (typeof code !== "string" || !B64URL_32.test(code) || typeof verifier !== "string" || !VERIFIER.test(verifier)) {
    return errorResponse(400, "bad_request");
  }
  // Spent by this attempt, whatever the verifier: a grabbed code can't be tried twice.
  const handoff = await env.DB.prepare("DELETE FROM handoffs WHERE code_hash = ? RETURNING *").bind(await sha256Hex(code)).first<HandoffRow>();
  if (handoff === null) return errorResponse(401, "invalid_code");
  if (handoff.exp_ms <= nowMs) return errorResponse(401, "code_expired");
  if (!sameString(await s256(verifier), handoff.handoff_challenge)) return errorResponse(401, "invalid_verifier");
  const tokens = await openSession(env.DB, handoff.account_id, handoff.platform as Platform, nowMs);
  const hint = handoff.display_hint === null ? null : await openHint(fromB64url(code) ?? new Uint8Array(0), handoff.display_hint);
  return json(200, { ...tokens, created: handoff.created === 1, ...(hint === null ? {} : { display_hint: hint }) });
}

// The display hint (Google's email) waits in handoffs sealed with AES-GCM under a key derived
// from the code, which only the herdrup:// URL carries: D1, and its Time Travel copies, never
// hold it readably.

async function hintKey(code: Uint8Array): Promise<CryptoKey> {
  const root = await crypto.subtle.importKey("raw", code, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: utf8("herdrup handoff hint v1") },
    root,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

async function sealHint(code: Uint8Array, hint: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await hintKey(code), utf8(hint)));
  return b64url(Uint8Array.from([...iv, ...sealed]));
}

async function openHint(code: Uint8Array, sealed: string): Promise<string | null> {
  const bytes = fromB64url(sealed);
  if (bytes === null || bytes.byteLength < 12 + 16) return null;
  try {
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.subarray(0, 12) }, await hintKey(code), bytes.subarray(12));
    return new TextDecoder().decode(plain);
  } catch {
    return null;
  }
}
