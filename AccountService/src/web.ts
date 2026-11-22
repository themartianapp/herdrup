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
// Deleting an account from the desktop (DESIGN.md §6.6): POST /v1/account/delete/start (an
// authenticated session, src/deletion.ts) makes a single-use ticket, and the browser opens
//   GET  /v1/auth/web/start?purpose=delete&ticket=<ticket>
// which runs the same flow for the ticket's provider, bound to the ticket's account and session.
// Its callback never makes an account or a session: the identity must already be the account's,
// and the browser goes to herdrup://account#delete_code=<code> (or #delete_error=<code>). The
// code waits in delete_handoffs, 5 minutes, for POST /v1/account/delete {handoff_code,
// handoff_verifier} from the same session; for Apple it keeps the sign-in's authorization code,
// sealed, so the deletion can revoke.
//
// A flow is one web_flows row, 10 minutes, taken (deleted) by the first callback naming its
// state, so a state never works twice. The callback must come from the browser that started
// the flow (its __Host-hu_flow cookie), which stops a page from finishing someone else's flow in
// the victim's browser. That cookie is one secret per browser, shared by every flow pending in
// it: a start reuses it while it lives and only renews its Max-Age, and no callback clears it,
// so starting a second sign-in (or failing one) never breaks another. The ID token must carry
// the flow's nonce (issued and spent like a native sign-in's) and name our web client: the
// Services ID for Apple, the web client for Google.
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
import { AUTHORIZATION_CODE } from "./apple";
import { FLOW_COOKIE, FLOW_TTL_MS, flowCookie, readCookie, refreshCookie, webOrigin } from "./browser";
import { b64url, fromB64url, randomB64url, sameString, sha256Hex, utf8 } from "./bytes";
import type { Env } from "./env";
import { errorResponse, json, log, readCapped, readJsonObject, type Endpoint } from "./http";
import { APPLE_ISSUER, APPLE_JWKS, GOOGLE_ISSUERS, GOOGLE_JWKS, type ProviderConfig } from "./idtoken";
import type { Provider, ServiceKeys } from "./keys";
import { issueNonce } from "./nonce";
import { APPLE_CODE_INFO, HINT_INFO, seal, unseal } from "./sealed";
import { openSession, PLATFORMS, type Platform } from "./sessions";

const SELF_ORIGIN = "https://accounts.herdrup.app";
export const APPLE_CALLBACK = `${SELF_ORIGIN}/v1/auth/web/apple/callback`;
export const GOOGLE_CALLBACK = `${SELF_ORIGIN}/v1/auth/web/google/callback`;
export const APPLE_AUTHORIZE = "https://appleid.apple.com/auth/authorize";
export const GOOGLE_AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
export const APP_REDIRECT = "herdrup://account";
export const HANDOFF_TTL_MS = 2 * 60 * 1000;
/** A deletion's ticket (start URL) and its confirmed code. */
export const DELETE_TICKET_TTL_MS = 5 * 60 * 1000;
export const DELETE_HANDOFF_TTL_MS = 5 * 60 * 1000;
/** Apple's form_post: an ID token (~1 KB), a code, the state, and on first consent a small `user` JSON. */
export const MAX_CALLBACK_BODY_BYTES = 8192;
const FETCH_TIMEOUT_MS = 5000;
/** 32 random bytes in base64url: states, codes, tickets, flow cookies, and S256 challenges. */
export const B64URL_32 = /^[A-Za-z0-9_-]{43}$/;
/** RFC 7636 §4.1. */
export const VERIFIER = /^[A-Za-z0-9._~-]{43,128}$/;

interface FlowRow {
  provider: Provider;
  client: "app" | "web";
  platform: string;
  browser_hash: string;
  nonce: string;
  pkce_verifier: string | null;
  handoff_challenge: string | null;
  exp_ms: number;
  purpose: "sign_in" | "delete";
  /** purpose = "delete" only: the account and session that asked for the deletion. */
  account_id: string | null;
  session_id: string | null;
}

interface DeleteTicketRow {
  account_id: string;
  session_id: string;
  provider: Provider;
  handoff_challenge: string;
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

/** RFC 7636's S256: base64url(SHA-256(verifier)). */
export const s256 = async (verifier: string): Promise<string> => b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(verifier))));

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

/** Whether the desktop's web flow (client=app) can run for `provider`: what a deletion's confirmation needs. */
export const webFlowConfigured = (env: Env, provider: Provider): boolean => configured(env, provider, "app");

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

/** A start, once its parameters are read: what the flow row will hold. */
interface Start {
  provider: Provider;
  client: FlowRow["client"];
  platform: string;
  handoffChallenge: string | null;
  purpose: FlowRow["purpose"];
  accountId: string | null;
  sessionId: string | null;
}

/** A sign-in's start from its query, or the error to answer with. */
function readSignInStart(query: URLSearchParams, names: string[]): Start | Response {
  const allowed = ["provider", "client", "platform", "handoff_challenge"];
  if (names.some((name) => !allowed.includes(name))) return errorResponse(400, "bad_request");
  const provider = query.get("provider");
  const client = query.get("client");
  if ((provider !== "apple" && provider !== "google") || (client !== "app" && client !== "web")) return errorResponse(400, "bad_request");
  const start: Start = { provider, client, platform: "web", handoffChallenge: null, purpose: "sign_in", accountId: null, sessionId: null };
  if (client === "app") {
    const requested = query.get("platform") ?? "";
    const challenge = query.get("handoff_challenge") ?? "";
    if (!PLATFORMS.includes(requested as Platform) || requested === "web" || !B64URL_32.test(challenge)) return errorResponse(400, "bad_request");
    return { ...start, platform: requested, handoffChallenge: challenge };
  }
  // The web guest's session lands in its cookie: no platform choice, nothing to hand off.
  return names.length === 2 ? start : errorResponse(400, "bad_request");
}

/**
 * A deletion's start: exactly purpose=delete and the ticket, which is taken (deleted) here, so a
 * start URL works once. The ticket carries the provider, the app's handoff challenge, and the
 * account and session that asked. Or the error to answer with.
 */
async function readDeleteStart(env: Env, query: URLSearchParams, names: string[], nowMs: number): Promise<Start | Response> {
  const ticket = query.get("ticket") ?? "";
  if (names.length !== 2 || query.get("purpose") !== "delete" || !B64URL_32.test(ticket)) return errorResponse(400, "bad_request");
  const row = await env.DB.prepare("DELETE FROM delete_tickets WHERE ticket_hash = ? RETURNING *").bind(await sha256Hex(ticket)).first<DeleteTicketRow>();
  if (row === null) return errorResponse(400, "ticket_invalid");
  if (row.exp_ms <= nowMs) return redirect(`${APP_REDIRECT}#delete_error=flow_expired`);
  // A deletion's flow opens no session, so it has no platform.
  return { provider: row.provider, client: "app", platform: "", handoffChallenge: row.handoff_challenge, purpose: "delete", accountId: row.account_id, sessionId: row.session_id };
}

export async function handleWebStart(request: Request, env: Env, nowMs: number): Promise<Response> {
  const endpoint = "/v1/auth/web/start";
  const keys = await openAuthRequest(request, env, endpoint);
  if (keys instanceof Response) return keys;
  const query = new URL(request.url).searchParams;
  const names = [...query.keys()];
  if (new Set(names).size !== names.length) return errorResponse(400, "bad_request");
  const start = names.includes("purpose") ? await readDeleteStart(env, query, names, nowMs) : readSignInStart(query, names);
  if (start instanceof Response) return start;
  const { provider, client } = start;
  const config = webClient(env, provider);
  if (config === null || !configured(env, provider, client)) return notConfigured(endpoint);

  const state = randomB64url(32);
  // The browser's flow secret: the one it already holds, so its other pending flows stay valid,
  // or a new one. Only this Worker can set a __Host- cookie for its host, so a value presented
  // here is one we issued to this browser.
  const held = readCookie(request, FLOW_COOKIE);
  const browser = held !== null && B64URL_32.test(held) ? held : randomB64url(32);
  const { nonce } = await issueNonce(keys.nonce, nowMs);
  const pkceVerifier = provider === "google" ? randomB64url(32) : null;
  await env.DB.prepare(
    `INSERT INTO web_flows (state_hash, provider, client, platform, browser_hash, nonce, pkce_verifier, handoff_challenge, exp_ms, purpose, account_id, session_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      await sha256Hex(state),
      provider,
      client,
      start.platform,
      await sha256Hex(browser),
      nonce,
      pkceVerifier,
      start.handoffChallenge,
      nowMs + FLOW_TTL_MS,
      start.purpose,
      start.accountId,
      start.sessionId,
    )
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

/** Back to the client that started the flow, with `error`: the app (a deletion's errors have their own key), or the web guest. */
function back(env: Env, flow: FlowRow, error: string): Response {
  if (flow.purpose === "delete") return redirect(`${APP_REDIRECT}#delete_error=${error}`);
  const location = flow.client === "app" ? `${APP_REDIRECT}#error=${error}` : `${webOrigin(env) ?? ""}/web/?account_error=${error}`;
  return redirect(location);
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

/**
 * Finishes the flow with the provider's ID token, verified against the flow's nonce: a sign-in's
 * account and session or handoff, or a deletion's confirmation. `appleCode` is the authorization
 * code of Apple's form_post (null for Google), kept only for a deletion's revoke.
 */
async function finish(env: Env, keys: ServiceKeys, flow: FlowRow, idToken: string, endpoint: Endpoint, nowMs: number, appleCode: string | null): Promise<Response> {
  const config = webClient(env, flow.provider);
  if (config === null) return back(env, flow, "provider_not_configured");
  const proof = await proveIdentity(env.DB, keys, config, endpoint, idToken, flow.nonce, nowMs);
  if (proof instanceof Response) {
    const { error } = await proof.json<{ error: string }>();
    return back(env, flow, error);
  }
  if (flow.purpose === "delete") return confirmDelete(env, flow, proof.subjectHash, proof.token.aud, appleCode, nowMs);
  const { accountId, created } = await findOrCreateAccount(env.DB, flow.provider, proof.subjectHash, nowMs);

  if (flow.client === "web") {
    const tokens = await openSession(env.DB, accountId, "web", nowMs);
    return redirect(`${webOrigin(env) ?? ""}/web/?account=1`, [refreshCookie(tokens.refresh_token)]);
  }
  const code = crypto.getRandomValues(new Uint8Array(32));
  const codeText = b64url(code);
  const hint = proof.token.email === undefined ? null : await seal(code, HINT_INFO, proof.token.email);
  await env.DB.prepare(
    "INSERT INTO handoffs (code_hash, account_id, handoff_challenge, platform, created, display_hint, exp_ms) VALUES (?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(await sha256Hex(codeText), accountId, flow.handoff_challenge, flow.platform, created ? 1 : 0, hint, nowMs + HANDOFF_TTL_MS)
    .run();
  return redirect(`${APP_REDIRECT}#code=${codeText}`);
}

/**
 * A deletion's confirmation: the identity that just signed in must already belong to the account
 * that asked (wrong_account otherwise; no account is ever made here). Then a delete code for that
 * account, session and identity, with Apple's authorization code sealed under it.
 */
async function confirmDelete(env: Env, flow: FlowRow, subjectHash: string, clientId: string, appleCode: string | null, nowMs: number): Promise<Response> {
  const own = await env.DB.prepare("SELECT 1 FROM identities WHERE provider = ? AND subject_hash = ? AND account_id = ?")
    .bind(flow.provider, subjectHash, flow.account_id)
    .first();
  if (own === null || flow.session_id === null) return back(env, flow, "wrong_account");
  const code = crypto.getRandomValues(new Uint8Array(32));
  const codeText = b64url(code);
  const keep = flow.provider === "apple" && appleCode !== null && AUTHORIZATION_CODE.test(appleCode);
  await env.DB.prepare(
    `INSERT INTO delete_handoffs (code_hash, account_id, session_id, provider, subject_hash, client_id, handoff_challenge, apple_code, exp_ms)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      await sha256Hex(codeText),
      flow.account_id,
      flow.session_id,
      flow.provider,
      subjectHash,
      clientId,
      flow.handoff_challenge,
      keep ? await seal(code, APPLE_CODE_INFO, appleCode) : null,
      nowMs + DELETE_HANDOFF_TTL_MS,
    )
    .run();
  return redirect(`${APP_REDIRECT}#delete_code=${codeText}`);
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
  return finish(env, keys, flow, idToken, endpoint, nowMs, form.get("code"));
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
  return finish(env, keys, flow, idToken, endpoint, nowMs, null);
}

export async function handleHandoff(request: Request, env: Env, nowMs: number): Promise<Response> {
  const keys = await openAuthRequest(request, env, "/v1/auth/handoff");
  if (keys instanceof Response) return keys;
  const body = await readJsonObject(request, MAX_AUTH_BODY_BYTES);
  if (body instanceof Response) return body;
  // Exactly these two fields. The session's platform was fixed at start, and devices are named
  // when they enrol (POST /v1/devices), so a platform or device_name here is a client bug: 400.
  if (Object.keys(body).some((key) => key !== "code" && key !== "handoff_verifier")) return errorResponse(400, "bad_request");
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
  const hint = handoff.display_hint === null ? null : await unseal(fromB64url(code) ?? new Uint8Array(0), HINT_INFO, handoff.display_hint);
  return json(200, { ...tokens, created: handoff.created === 1, ...(hint === null ? {} : { display_hint: hint }) });
}

interface DeleteHandoffRow {
  account_id: string;
  session_id: string;
  provider: Provider;
  subject_hash: string;
  client_id: string;
  handoff_challenge: string;
  apple_code: string | null;
  exp_ms: number;
}

/** A redeemed deletion confirmation: who confirmed, and Apple's authorization code for the revoke. */
export interface DeleteConfirmation {
  provider: Provider;
  /** The client Apple issued `appleCode` to (the confirmation's ID-token audience). */
  clientId: string;
  appleCode: string | null;
}

/**
 * Redeems a delete code (POST /v1/account/delete {handoff_code, handoff_verifier}) for the session
 * `principal`. The code is taken (deleted) first, so any failure after that spends it. It must
 * be in date, match the verifier, belong to this account and session, and its identity must still
 * be the account's. Only delete_handoffs is read: a sign-in code is unknown here, and a delete
 * code is unknown to POST /v1/auth/handoff. Or the error to answer with.
 */
export async function redeemDeleteCode(
  env: Env,
  principal: { accountId: string; sessionId: string },
  code: string,
  verifier: string,
  nowMs: number,
): Promise<DeleteConfirmation | Response> {
  const row = await env.DB.prepare("DELETE FROM delete_handoffs WHERE code_hash = ? RETURNING *").bind(await sha256Hex(code)).first<DeleteHandoffRow>();
  if (row === null) return errorResponse(401, "invalid_code");
  if (row.exp_ms <= nowMs) return errorResponse(401, "code_expired");
  if (!sameString(await s256(verifier), row.handoff_challenge)) return errorResponse(401, "invalid_verifier");
  if (row.account_id !== principal.accountId || row.session_id !== principal.sessionId) return errorResponse(403, "wrong_account");
  const own = await env.DB.prepare("SELECT 1 FROM identities WHERE provider = ? AND subject_hash = ? AND account_id = ?")
    .bind(row.provider, row.subject_hash, row.account_id)
    .first();
  if (own === null) return errorResponse(403, "wrong_account");
  const appleCode = row.apple_code === null ? null : await unseal(fromB64url(code) ?? new Uint8Array(0), APPLE_CODE_INFO, row.apple_code);
  return { provider: row.provider, clientId: row.client_id, appleCode };
}
