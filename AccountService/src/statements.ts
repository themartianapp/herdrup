// Statements: "device key D belongs to account X", for one host, valid 10 minutes.
//
//   POST /v1/statements  {hosts: [host_id, … ≤ 50]}  → {statements: [{host, jws}], exp}
//   GET  /.well-known/jwks.json                       → {keys, revoked_kids}
//
// A statement is a compact JWS (EdDSA):
//   header  {"alg":"EdDSA","typ":"herdrup-device+jwt","kid":"<kid>"}
//   payload {"v":1,"iss":"https://accounts.herdrup.app","aud":"<host_id>","sub":"<pairwise id>",
//            "dev":"<device public key, base64url>","iat":<unix s>,"exp":<iat + 600>}
// `sub` is the account's id for that host alone: the first 22 base64url characters of
// HMAC-SHA256(pairwise key, account_id "|" host_id), so two hosts can't tell they share a
// guest. Host ids are never stored. `dev` is always the calling session's own device, so a
// stolen access token mints statements only for a key the thief doesn't hold. A key withdrawn
// from the account (a browser with owner access, removed from Devices: src/approvals.ts) gets
// none, even enrolled again, until it is approved again or the withdrawal expires. Hosts verify
// statements against the JWKS (src/signing.ts) and check `aud` against their own host id.
import { b64url, utf8 } from "./bytes";
import { openAccountRequest } from "./auth";
import type { Env } from "./env";
import { errorResponse, json, log, readJsonObject } from "./http";
import { serviceKeys } from "./keys";
import { dayOf } from "./sessions";
import { activeKey, jwks, JWKS_MAX_AGE_SECONDS, signJws, type SigningKey } from "./signing";

export const ISSUER = "https://accounts.herdrup.app";
export const STATEMENT_TTL_SECONDS = 600;
export const MAX_HOSTS = 50;
export const MAX_STATEMENTS_BODY_BYTES = 4096;
const HOST_ID = /^[A-Za-z0-9_-]{22}$/;

/** The account's id as host `hostId` sees it. */
export async function pairwiseSub(key: CryptoKey, accountId: string, hostId: string): Promise<string> {
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, utf8(`${accountId}|${hostId}`)));
  return b64url(mac).slice(0, 22);
}

export interface StatementClaims {
  hostId: string;
  sub: string;
  devicePub: string;
  iatSeconds: number;
}

export function signStatement(key: SigningKey, claims: StatementClaims): Promise<string> {
  return signJws(
    key,
    { alg: "EdDSA", typ: "herdrup-device+jwt", kid: key.kid },
    {
      v: 1,
      iss: ISSUER,
      aud: claims.hostId,
      sub: claims.sub,
      dev: claims.devicePub,
      iat: claims.iatSeconds,
      exp: claims.iatSeconds + STATEMENT_TTL_SECONDS,
    },
  );
}

export async function handleStatements(request: Request, env: Env, nowMs: number): Promise<Response> {
  const endpoint = "/v1/statements";
  const keys = serviceKeys(env.ACCOUNT_HMAC_KEY);
  const signingKey = await activeKey(env);
  if (keys === null || signingKey === null) {
    log({ endpoint, outcome: "not_configured" });
    return errorResponse(500, "not_configured");
  }
  const principal = await openAccountRequest(request, env, endpoint, nowMs, "STATEMENT_LIMIT");
  if (principal instanceof Response) return principal;
  if (principal.deviceId === null) return errorResponse(403, "device_required");
  const body = await readJsonObject(request, MAX_STATEMENTS_BODY_BYTES);
  if (body instanceof Response) return body;
  const { hosts } = body;
  if (!Array.isArray(hosts) || hosts.length === 0 || hosts.length > MAX_HOSTS) return errorResponse(400, "bad_request");
  if (!hosts.every((host): host is string => typeof host === "string" && HOST_ID.test(host))) return errorResponse(400, "bad_request");

  // Read at every issue: a device removed since the session authenticated gets nothing, and
  // neither does a key withdrawn from this account.
  const device = await env.DB.prepare(
    `SELECT d.device_pub, d.last_statement_day,
            EXISTS (SELECT 1 FROM withdrawals w WHERE w.account_id = d.account_id AND w.device_pub = d.device_pub AND w.exp_ms > ?3) AS withdrawn
       FROM devices d WHERE d.id = ?1 AND d.account_id = ?2`,
  )
    .bind(principal.deviceId, principal.accountId, nowMs)
    .first<{ device_pub: string; last_statement_day: number; withdrawn: number }>();
  if (device === null) return errorResponse(403, "device_removed");
  if (device.withdrawn !== 0) return errorResponse(403, "device_withdrawn");
  const today = dayOf(nowMs);
  if (device.last_statement_day < today) {
    await env.DB.prepare("UPDATE devices SET last_statement_day = ? WHERE id = ?").bind(today, principal.deviceId).run();
  }

  const { pairwise } = await keys;
  const iatSeconds = Math.floor(nowMs / 1000);
  const statements = [];
  for (const hostId of new Set(hosts)) {
    const sub = await pairwiseSub(pairwise, principal.accountId, hostId);
    statements.push({ host: hostId, jws: await signStatement(signingKey, { hostId, sub, devicePub: device.device_pub, iatSeconds }) });
  }
  return json(200, { statements, exp: iatSeconds + STATEMENT_TTL_SECONDS });
}

/** Public and cacheable, unlike every other answer: hosts fetch it to verify statements. */
export async function handleJwks(env: Env): Promise<Response> {
  return new Response(JSON.stringify(await jwks(env)), {
    status: 200,
    headers: { "content-type": "application/json", "cache-control": `public, max-age=${JWKS_MAX_AGE_SECONDS}` },
  });
}
