// The sign-in endpoints:
//
//   POST /v1/auth/nonce                 → {nonce, expires_unix}
//   POST /v1/auth/apple | /v1/auth/google {id_token, nonce, platform}
//                                       → {account_id, created, access_token, …, display_hint?}
//   POST /v1/auth/refresh               {refresh_token} → a new token pair; from the web guest
//                                       (Origin WEB_ORIGIN), the __Host-hu_refresh cookie instead
//                                       → {account_id, access_token, access_expires_in} + cookie
//   POST /v1/auth/signout               Bearer access token → 204; from the web guest, the
//                                       cookie's session instead, and the cookie is cleared
//   GET  /v1/account                    Bearer access token → {account_id, created_ms}
//
// The app passes the nonce to Apple (ASAuthorizationAppleIDRequest.nonce) or Google (the
// `nonce` parameter) unchanged, and the ID token must carry it back. Each nonce signs in once.
// The unauthenticated endpoints share the per-IP AUTH_IP_LIMIT, checked before the body is
// read; the authenticated ones count against ACCOUNT_LIMIT per account.
import { randomB64url, sameString } from "./bytes";
import type { Env } from "./env";
import { errorResponse, json, log, readJsonObject, type Endpoint } from "./http";
import { APPLE_ISSUER, APPLE_JWKS, GOOGLE_ISSUERS, GOOGLE_JWKS, verifyIdToken, type ProviderConfig, type VerifiedIdToken } from "./idtoken";
import { serviceKeys, subjectHash, type Provider, type ServiceKeys } from "./keys";
import { issueNonce, openNonce, spendNonce } from "./nonce";
import { authenticate, dayOf, endSessionByRefreshToken, openSession, PLATFORMS, refreshSession, type Platform, type Principal } from "./sessions";
import { clearRefreshCookie, fromWebGuest, readCookie, REFRESH_COOKIE, refreshCookie } from "./browser";

/** Largest sign-in or refresh body: an ID token is ~1 KB, and verifyIdToken refuses past 4 KB. */
export const MAX_AUTH_BODY_BYTES = 8192;

export function providerConfig(env: Env, provider: Provider): ProviderConfig | null {
  const audiences = (
    provider === "apple" ? [env.APPLE_APP_CLIENT_ID, env.APPLE_WEB_CLIENT_ID] : [env.GOOGLE_IOS_CLIENT_ID, env.GOOGLE_WEB_CLIENT_ID]
  ).filter((id): id is string => typeof id === "string" && id.length > 0);
  if (audiences.length === 0) return null;
  return provider === "apple"
    ? { provider, issuers: [APPLE_ISSUER], audiences, jwks: APPLE_JWKS }
    : { provider, issuers: GOOGLE_ISSUERS, audiences, jwks: GOOGLE_JWKS };
}

/** The per-IP budget, the derived keys, or the error to answer with. */
export async function openAuthRequest(request: Request, env: Env, endpoint: Endpoint): Promise<ServiceKeys | Response> {
  const keys = serviceKeys(env.ACCOUNT_HMAC_KEY);
  if (env.AUTH_IP_LIMIT === undefined || keys === null) {
    log({ endpoint, outcome: "not_configured" });
    return errorResponse(500, "not_configured");
  }
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (!(await env.AUTH_IP_LIMIT.limit({ key: ip })).success) {
    log({ endpoint, outcome: "rate_limited" });
    return errorResponse(429, "rate_limited");
  }
  return keys;
}

export async function handleNonce(request: Request, env: Env, nowMs: number): Promise<Response> {
  const keys = await openAuthRequest(request, env, "/v1/auth/nonce");
  if (keys instanceof Response) return keys;
  const { nonce, expiresUnix } = await issueNonce(keys.nonce, nowMs);
  return json(200, { nonce, expires_unix: expiresUnix });
}

export async function handleSignIn(request: Request, env: Env, provider: Provider, nowMs: number): Promise<Response> {
  const endpoint = provider === "apple" ? "/v1/auth/apple" : "/v1/auth/google";
  const keys = await openAuthRequest(request, env, endpoint);
  if (keys instanceof Response) return keys;
  const config = providerConfig(env, provider);
  if (config === null) {
    log({ endpoint, outcome: "not_configured" });
    return errorResponse(500, "not_configured");
  }
  const body = await readJsonObject(request, MAX_AUTH_BODY_BYTES);
  if (body instanceof Response) return body;
  const { id_token: idToken, nonce, platform } = body;
  if (typeof idToken !== "string" || typeof nonce !== "string" || !PLATFORMS.includes(platform as Platform)) {
    return errorResponse(400, "bad_request");
  }

  const proof = await proveIdentity(env.DB, keys, config, endpoint, idToken, nonce, nowMs);
  if (proof instanceof Response) return proof;
  const { accountId, created } = await findOrCreateAccount(env.DB, provider, proof.subjectHash, nowMs);
  const tokens = await openSession(env.DB, accountId, platform as Platform, nowMs);
  return json(200, {
    ...tokens,
    created,
    ...(proof.token.email === undefined ? {} : { display_hint: proof.token.email }),
  });
}

/**
 * A fresh sign-in with the provider: `nonce` is one this Worker issued and hasn't expired, the
 * ID token verifies and carries it, and the nonce is then spent. Sign-in and account deletion
 * (src/deletion.ts) both take one. The verified token and its identity hash, or the error.
 */
export async function proveIdentity(
  db: D1Database,
  keys: ServiceKeys,
  config: ProviderConfig,
  endpoint: Endpoint,
  idToken: string,
  nonce: string,
  nowMs: number,
): Promise<{ token: VerifiedIdToken; subjectHash: string } | Response> {
  const nonceExpiresMs = await openNonce(keys.nonce, nonce, nowMs);
  if (nonceExpiresMs === null) return errorResponse(401, "nonce_invalid");
  const verified = await verifyIdToken(idToken, config, nowMs);
  if (!verified.ok) {
    if (verified.reason === "keys_unavailable") {
      log({ endpoint, outcome: "keys_unavailable" });
      return errorResponse(503, "provider_unavailable");
    }
    return json(401, { error: "token_invalid", reason: verified.reason });
  }
  if (!sameString(verified.token.nonce, nonce)) return json(401, { error: "token_invalid", reason: "nonce_mismatch" });
  if (!(await spendNonce(db, nonce, nonceExpiresMs))) return errorResponse(401, "nonce_used");
  return { token: verified.token, subjectHash: await subjectHash(keys.subject, config.provider, verified.token.sub) };
}

/**
 * The account for this identity, made on first sign-in. Two first sign-ins racing for the
 * same identity both insert an account, but only one identity row lands; the loser deletes
 * its account and uses the winner's. A new account is seen today from its first statement,
 * so the hourly cleanup can never take it between creation and its first session.
 * Exported for its tests.
 */
export async function findOrCreateAccount(
  db: D1Database,
  provider: Provider,
  hash: string,
  nowMs: number,
): Promise<{ accountId: string; created: boolean }> {
  const lookup = db.prepare("SELECT account_id FROM identities WHERE provider = ? AND subject_hash = ?").bind(provider, hash);
  const existing = await lookup.first<{ account_id: string }>();
  if (existing !== null) return { accountId: existing.account_id, created: false };
  const accountId = randomB64url(16);
  await db.batch([
    db.prepare("INSERT INTO accounts (id, created_ms, last_seen_day) VALUES (?, ?, ?)").bind(accountId, nowMs, dayOf(nowMs)),
    db
      .prepare("INSERT INTO identities (provider, subject_hash, account_id, created_ms) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING")
      .bind(provider, hash, accountId, nowMs),
  ]);
  const owner = await lookup.first<{ account_id: string }>();
  if (owner !== null && owner.account_id === accountId) return { accountId, created: true };
  await db.prepare("DELETE FROM accounts WHERE id = ?").bind(accountId).run();
  if (owner === null) throw new Error("identity vanished during sign-in");
  return { accountId: owner.account_id, created: false };
}

export async function handleRefresh(request: Request, env: Env, nowMs: number): Promise<Response> {
  const keys = await openAuthRequest(request, env, "/v1/auth/refresh");
  if (keys instanceof Response) return keys;
  if (fromWebGuest(request, env)) {
    // The web guest's refresh token never reaches its page: it lives in the HttpOnly cookie,
    // which rotates with it. A refused token clears the cookie.
    const cookie = readCookie(request, REFRESH_COOKIE);
    if (cookie === null) return errorResponse(401, "invalid_token");
    const result = await refreshSession(env.DB, cookie, nowMs);
    if (!result.ok) return errorResponse(401, result.error, { "Set-Cookie": clearRefreshCookie() });
    const { account_id, access_token, access_expires_in, refresh_token } = result.tokens;
    return json(200, { account_id, access_token, access_expires_in }, { "Set-Cookie": refreshCookie(refresh_token) });
  }
  const body = await readJsonObject(request, MAX_AUTH_BODY_BYTES);
  if (body instanceof Response) return body;
  if (typeof body.refresh_token !== "string") return errorResponse(400, "bad_request");
  const result = await refreshSession(env.DB, body.refresh_token, nowMs);
  return result.ok ? json(200, result.tokens) : errorResponse(401, result.error);
}

/**
 * The caller's session after ACCOUNT_LIMIT and, when given, a second per-account limit
 * (`extraLimit`), or the error to answer with. Both are checked before the body is read.
 */
export async function openAccountRequest(
  request: Request,
  env: Env,
  endpoint: Endpoint,
  nowMs: number,
  extraLimit?: "STATEMENT_LIMIT" | "ENROL_LIMIT" | "SYNC_WRITE_LIMIT" | "APPROVAL_LIMIT",
): Promise<Principal | Response> {
  const extra = extraLimit === undefined ? null : env[extraLimit];
  if (env.ACCOUNT_LIMIT === undefined || extra === undefined) {
    log({ endpoint, outcome: "not_configured" });
    return errorResponse(500, "not_configured");
  }
  const auth = await authenticate(env.DB, request.headers.get("Authorization"), nowMs);
  if (!auth.ok) return errorResponse(401, auth.error, { "WWW-Authenticate": "Bearer" });
  for (const limiter of extra === null ? [env.ACCOUNT_LIMIT] : [env.ACCOUNT_LIMIT, extra]) {
    if (!(await limiter.limit({ key: auth.principal.accountId })).success) {
      log({ endpoint, outcome: "rate_limited" });
      return errorResponse(429, "rate_limited");
    }
  }
  return auth.principal;
}

export async function handleSignOut(request: Request, env: Env, nowMs: number): Promise<Response> {
  if (fromWebGuest(request, env)) {
    // The web guest signs out by its cookie, so it can even after its access token expired.
    // Always 204 with the cookie cleared: a stale or missing cookie has no session to end.
    const keys = await openAuthRequest(request, env, "/v1/auth/signout");
    if (keys instanceof Response) return keys;
    const cookie = readCookie(request, REFRESH_COOKIE);
    if (cookie !== null) await endSessionByRefreshToken(env.DB, cookie);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store", "Set-Cookie": clearRefreshCookie() } });
  }
  const principal = await openAccountRequest(request, env, "/v1/auth/signout", nowMs);
  if (principal instanceof Response) return principal;
  await env.DB.prepare("DELETE FROM sessions WHERE id = ?").bind(principal.sessionId).run();
  return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
}

export async function handleAccount(request: Request, env: Env, nowMs: number): Promise<Response> {
  const principal = await openAccountRequest(request, env, "/v1/account", nowMs);
  if (principal instanceof Response) return principal;
  const account = await env.DB.prepare("SELECT id, created_ms FROM accounts WHERE id = ?")
    .bind(principal.accountId)
    .first<{ id: string; created_ms: number }>();
  if (account === null) return errorResponse(401, "invalid_token", { "WWW-Authenticate": "Bearer" });
  return json(200, { account_id: account.id, created_ms: account.created_ms });
}
