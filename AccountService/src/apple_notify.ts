// Sign in with Apple's server-to-server notifications (DESIGN.md §6.3):
//
//   POST /v1/apple/notifications  {payload: <JWS>}  → 204
//
// The payload is an RS256 JWS from Apple's own keys (the same JWKS as ID tokens), checked
// before anything in it is used: iss Apple, aud one of our Apple client ids, iat not in the
// future, exp (when present) not passed. Its `events` claim (a JSON string, or an object as in
// Apple's samples) carries {type, sub, event_time}.
//
// consent-revoked and account-deleted delete the account that identity belongs to, as
// /v1/account/delete does, without revoking at Apple: the user already did. An event from
// before the identity signed in (a replay, or a retry that lost a race with a new sign-up)
// deletes nothing. email-* and unknown types are acknowledged and ignored: we hold no email.
// The answer is 204 whether or not an account matched, so it says nothing about who has one.
import { providerConfig } from "./auth";
import { deleteAccount, deleteIpLimit } from "./deletion";
import type { Env } from "./env";
import { errorResponse, isRecord, json, log, readJsonObject } from "./http";
import { APPLE_JWKS, SKEW_MS, verifyRs256Jws } from "./idtoken";
import { serviceKeys, subjectHash } from "./keys";

export const MAX_NOTIFICATION_BODY_BYTES = 8192;
/** Apple's samples use the URL; deliveries have been seen with the bare host. */
const ISSUERS = ["https://appleid.apple.com", "appleid.apple.com"];
const DELETING_EVENTS = ["consent-revoked", "account-deleted"];

const noContent = () => new Response(null, { status: 204, headers: { "cache-control": "no-store" } });

function parseEvents(value: unknown): Record<string, unknown> | null {
  if (isRecord(value)) return value;
  if (typeof value !== "string") return null;
  try {
    const parsed: unknown = JSON.parse(value);
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

export async function handleAppleNotification(request: Request, env: Env, nowMs: number): Promise<Response> {
  const endpoint = "/v1/apple/notifications";
  const keys = serviceKeys(env.ACCOUNT_HMAC_KEY);
  const config = providerConfig(env, "apple");
  if (keys === null || config === null) {
    log({ endpoint, outcome: "not_configured" });
    return errorResponse(500, "not_configured");
  }
  const limited = await deleteIpLimit(request, env, endpoint);
  if (limited !== null) return limited;
  const body = await readJsonObject(request, MAX_NOTIFICATION_BODY_BYTES);
  if (body instanceof Response) return body;
  if (typeof body.payload !== "string") return errorResponse(400, "bad_request");

  const jws = await verifyRs256Jws(body.payload, APPLE_JWKS, nowMs);
  if (!jws.ok) {
    if (jws.reason === "keys_unavailable") {
      log({ endpoint, outcome: "keys_unavailable" });
      return errorResponse(503, "provider_unavailable");
    }
    return json(401, { error: "token_invalid", reason: jws.reason });
  }
  const { iss, aud, iat, exp, events } = jws.payload;
  const refuse = (reason: string) => json(401, { error: "token_invalid", reason });
  if (typeof iss !== "string" || !ISSUERS.includes(iss)) return refuse("wrong_issuer");
  if (typeof aud !== "string" || !config.audiences.includes(aud)) return refuse("wrong_audience");
  if (typeof iat !== "number") return refuse("malformed");
  if (iat * 1000 > nowMs + SKEW_MS) return refuse("issued_in_future");
  if (exp !== undefined && (typeof exp !== "number" || exp * 1000 <= nowMs - SKEW_MS)) return refuse("expired");
  const event = parseEvents(events);
  if (event === null || typeof event.type !== "string") return refuse("malformed");
  if (!DELETING_EVENTS.includes(event.type)) return noContent();
  const { sub, event_time: eventTime } = event;
  if (typeof sub !== "string" || sub.length === 0 || sub.length > 255) return refuse("bad_subject");

  const identity = await env.DB.prepare("SELECT account_id, created_ms FROM identities WHERE provider = 'apple' AND subject_hash = ?")
    .bind(await subjectHash((await keys).subject, "apple", sub))
    .first<{ account_id: string; created_ms: number }>();
  if (identity === null) return noContent();
  // event_time is in milliseconds in Apple's deliveries and in seconds in its samples; iat stands in when it is missing.
  const eventMs = typeof eventTime === "number" ? (eventTime < 1e12 ? eventTime * 1000 : eventTime) : iat * 1000;
  // A second of slack for seconds-precision times.
  if (eventMs + 1000 <= identity.created_ms) return noContent();
  await deleteAccount(env.DB, identity.account_id);
  return noContent();
}
