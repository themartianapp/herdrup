// Account deletion (DESIGN.md §6.1, §6.4):
//
//   POST /v1/account/delete  Bearer access token; {provider, id_token, nonce, authorization_code?}
//                            → {deleted: true, manual_revoke}
//
// The fresh sign-in is the confirmation: its ID token must verify (with a nonce this Worker
// issued, spent here) and name an identity of the caller's own account. Then every row of the
// account goes in one D1 batch, which is a transaction: all of it or none. Sessions go with it,
// so every token of the account fails on its next request, and devices too, so no statement is
// issued again.
//
// Apple: after the batch, the authorization code from the same sign-in is exchanged and its
// refresh token revoked (src/apple.ts). The deletion never waits on or undoes for Apple: when
// there is no code, the key isn't configured, or Apple refuses, the answer says
// manual_revoke: true and the app shows Apple's manual path (TN3194).
import { openAccountRequest, MAX_AUTH_BODY_BYTES, proveIdentity, providerConfig } from "./auth";
import { appleSigner, revokeAppleConsent } from "./apple";
import type { Env } from "./env";
import { errorResponse, json, log, readJsonObject, type Endpoint } from "./http";
import { serviceKeys } from "./keys";

/**
 * Every table with an account_id column, children first. test/deletion.test.ts checks this
 * list against the schema the migrations build, so a new table with account data can't be
 * left out.
 */
export const ACCOUNT_TABLES = ["sync_items", "sync_usage", "enrol_challenges", "sessions", "devices", "identities"] as const;

/** Apple's authorization codes: printable ASCII, a few hundred characters. */
const AUTHORIZATION_CODE = /^[\x21-\x7e]{1,1024}$/;

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

  await deleteAccount(env.DB, principal.accountId);

  let manualRevoke = false;
  if (provider === "apple") {
    const signer = code === undefined ? null : await appleSigner(env);
    if (code !== undefined && signer === null) log({ endpoint, outcome: "not_configured" });
    // The code was issued to the client the ID token names as its audience.
    manualRevoke = code === undefined || signer === null || !(await revokeAppleConsent(signer, env, proof.token.aud, code, nowMs));
  }
  return json(200, { deleted: true, manual_revoke: manualRevoke });
}
