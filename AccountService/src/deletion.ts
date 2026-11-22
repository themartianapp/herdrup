// Account deletion (DESIGN.md §6.1, §6.4, §6.6):
//
//   POST /v1/account/delete        Bearer access token; {provider, id_token, nonce, authorization_code?}
//                                  or {handoff_code, handoff_verifier} → {deleted: true, manual_revoke}
//   POST /v1/account/delete/start  Bearer access token; {provider, handoff_challenge}
//                                  → {start_url, expires_in}
//
// A fresh sign-in is the confirmation. The apps hold the ID token of a native one: it must
// verify (with a nonce this Worker issued, spent here) and name an identity of the caller's own
// account. herdrup-desktop signs in through the browser and never holds an ID token, so it asks
// for a deletion ticket, opens the start URL, and redeems the delete code its web sign-in hands
// back (src/web.ts). Then every row of the account goes in one D1 batch, which is a transaction:
// all of it or none. Sessions go with it, so every token of the account fails on its next
// request, and devices too, so no statement is issued again.
//
// Apple: after the batch, the authorization code from the same sign-in is exchanged and its
// refresh token revoked (src/apple.ts). The deletion never waits on or undoes for Apple: when
// there is no code, the key isn't configured, or Apple refuses, the answer says
// manual_revoke: true and the app shows Apple's manual path (TN3194).
import { openAccountRequest, MAX_AUTH_BODY_BYTES, proveIdentity, providerConfig } from "./auth";
import { appleSigner, AUTHORIZATION_CODE, revokeAppleConsent } from "./apple";
import { randomB64url, sha256Hex } from "./bytes";
import type { Env } from "./env";
import { errorResponse, json, log, readJsonObject, type Endpoint } from "./http";
import { serviceKeys, type Provider } from "./keys";
import { B64URL_32, DELETE_TICKET_TTL_MS, redeemDeleteCode, VERIFIER, webFlowConfigured } from "./web";

/**
 * Every table with an account_id column, children first. test/deletion.test.ts checks this
 * list against the schema the migrations build, so a new table with account data can't be
 * left out.
 */
export const ACCOUNT_TABLES = [
  "sync_items",
  "sync_usage",
  "enrol_challenges",
  "handoffs",
  "delete_handoffs",
  "delete_tickets",
  "web_flows",
  "sessions",
  "devices",
  "identities",
] as const;

/** Where the desktop's browser starts a deletion's confirmation. */
export const WEB_START_URL = "https://accounts.herdrup.app/v1/auth/web/start";

/**
 * Deletes the account and everything that refers to it, in one batch. A session's spent
 * refresh tokens have no account_id of their own and go by their session. Returns whether the
 * account was still there.
 */
export async function deleteAccount(db: D1Database, accountId: string): Promise<boolean> {
  const results = await db.batch([
    db.prepare("DELETE FROM spent_refresh_tokens WHERE session_id IN (SELECT id FROM sessions WHERE account_id = ?)").bind(accountId),
    ...ACCOUNT_TABLES.map((table) => db.prepare(`DELETE FROM ${table} WHERE account_id = ?`).bind(accountId)),
    db.prepare("DELETE FROM accounts WHERE id = ?").bind(accountId),
  ]);
  return results[results.length - 1].meta.changes > 0;
}

/** The per-IP DELETE_IP_LIMIT, checked before any other work, or the error to answer with. */
export async function deleteIpLimit(request: Request, env: Env, endpoint: Endpoint): Promise<Response | null> {
  if (env.DELETE_IP_LIMIT === undefined) {
    log({ endpoint, outcome: "not_configured" });
    return errorResponse(500, "not_configured");
  }
  if (!(await env.DELETE_IP_LIMIT.limit({ key: request.headers.get("CF-Connecting-IP") ?? "unknown" })).success) {
    log({ endpoint, outcome: "rate_limited" });
    return errorResponse(429, "rate_limited");
  }
  return null;
}

export async function handleAccountDelete(request: Request, env: Env, nowMs: number): Promise<Response> {
  const endpoint = "/v1/account/delete";
  const keys = serviceKeys(env.ACCOUNT_HMAC_KEY);
  if (keys === null) {
    log({ endpoint, outcome: "not_configured" });
    return errorResponse(500, "not_configured");
  }
  const limited = await deleteIpLimit(request, env, endpoint);
  if (limited !== null) return limited;
  const principal = await openAccountRequest(request, env, endpoint, nowMs);
  if (principal instanceof Response) return principal;
  const body = await readJsonObject(request, MAX_AUTH_BODY_BYTES);
  if (body instanceof Response) return body;

  if ("handoff_code" in body || "handoff_verifier" in body) {
    // The desktop's confirmation (§6.6): exactly these two fields. A well-formed code is spent by
    // this attempt whatever happens next.
    const { handoff_code: code, handoff_verifier: verifier } = body;
    if (Object.keys(body).some((key) => key !== "handoff_code" && key !== "handoff_verifier")) return errorResponse(400, "bad_request");
    if (typeof code !== "string" || !B64URL_32.test(code) || typeof verifier !== "string" || !VERIFIER.test(verifier)) {
      return errorResponse(400, "bad_request");
    }
    const confirmed = await redeemDeleteCode(env, principal, code, verifier, nowMs);
    if (confirmed instanceof Response) return confirmed;
    return completeDeletion(env, endpoint, principal.accountId, confirmed.provider, confirmed.clientId, confirmed.appleCode ?? undefined, nowMs);
  }

  const { provider, id_token: idToken, nonce, authorization_code: code } = body;
  if ((provider !== "apple" && provider !== "google") || typeof idToken !== "string" || typeof nonce !== "string") {
    return errorResponse(400, "bad_request");
  }
  // Only Apple issues a code to revoke with.
  if (code !== undefined && (provider !== "apple" || typeof code !== "string" || !AUTHORIZATION_CODE.test(code))) {
    return errorResponse(400, "bad_request");
  }
  const config = providerConfig(env, provider);
  if (config === null) {
    log({ endpoint, outcome: "not_configured" });
    return errorResponse(500, "not_configured");
  }

  const proof = await proveIdentity(env.DB, await keys, config, endpoint, idToken, nonce, nowMs);
  if (proof instanceof Response) return proof;
  const own = await env.DB.prepare("SELECT 1 FROM identities WHERE provider = ? AND subject_hash = ? AND account_id = ?")
    .bind(provider, proof.subjectHash, principal.accountId)
    .first();
  if (own === null) return errorResponse(403, "wrong_account");
  // The code was issued to the client the ID token names as its audience.
  return completeDeletion(env, endpoint, principal.accountId, provider, proof.token.aud, code, nowMs);
}

/** Deletes the account, then for Apple revokes with `appleCode` for `clientId`; the answer says whether that happened. */
async function completeDeletion(
  env: Env,
  endpoint: Endpoint,
  accountId: string,
  provider: Provider,
  clientId: string,
  appleCode: string | undefined,
  nowMs: number,
): Promise<Response> {
  await deleteAccount(env.DB, accountId);
  let manualRevoke = false;
  if (provider === "apple") {
    const signer = appleCode === undefined ? null : await appleSigner(env);
    if (appleCode !== undefined && signer === null) log({ endpoint, outcome: "not_configured" });
    manualRevoke = appleCode === undefined || signer === null || !(await revokeAppleConsent(signer, env, clientId, appleCode, nowMs));
  }
  return json(200, { deleted: true, manual_revoke: manualRevoke });
}

/**
 * POST /v1/account/delete/start: a single-use ticket for the desktop's deletion confirmation,
 * bound to the calling session, its account and the chosen provider, valid 5 minutes. The answer
 * is the URL the desktop opens in the browser; the ticket rides in it, never an access token.
 */
export async function handleDeleteStart(request: Request, env: Env, nowMs: number): Promise<Response> {
  const endpoint = "/v1/account/delete/start";
  const limited = await deleteIpLimit(request, env, endpoint);
  if (limited !== null) return limited;
  const principal = await openAccountRequest(request, env, endpoint, nowMs);
  if (principal instanceof Response) return principal;
  const body = await readJsonObject(request, MAX_AUTH_BODY_BYTES);
  if (body instanceof Response) return body;
  const { provider, handoff_challenge: challenge } = body;
  if (Object.keys(body).some((key) => key !== "provider" && key !== "handoff_challenge")) return errorResponse(400, "bad_request");
  if ((provider !== "apple" && provider !== "google") || typeof challenge !== "string" || !B64URL_32.test(challenge)) return errorResponse(400, "bad_request");
  if (!webFlowConfigured(env, provider)) {
    log({ endpoint, outcome: "not_configured" });
    return errorResponse(503, "provider_not_configured");
  }
  const ticket = randomB64url(32);
  await env.DB.prepare("INSERT INTO delete_tickets (ticket_hash, account_id, session_id, provider, handoff_challenge, exp_ms) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(await sha256Hex(ticket), principal.accountId, principal.sessionId, provider, challenge, nowMs + DELETE_TICKET_TTL_MS)
    .run();
  return json(200, { start_url: `${WEB_START_URL}?purpose=delete&ticket=${ticket}`, expires_in: DELETE_TICKET_TTL_MS / 1000 });
}
