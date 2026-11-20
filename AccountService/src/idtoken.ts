// Verifies an Apple or Google ID token: a compact JWS, RS256 only, signed by a key in the
// provider's JWKS. The signature is checked before any claim is trusted. Then:
//   iss  the provider's issuer;
//   aud  one of our client ids (a single string, never an array);
//   azp  when present, also one of our client ids, checked on its own: Google's cross-client
//        flow gives aud = the web client and azp = the iOS client that asked;
//   exp  in the future, iat not in the future and at most 10 minutes old (60 s skew each way);
//   nonce present (the caller compares it with the nonce it issued);
//   sub  1..255 characters.
import { fromB64url, utf8 } from "./bytes";
import { isRecord } from "./http";
import { JwksCache } from "./jwks";
import type { Provider } from "./keys";

export const SKEW_MS = 60 * 1000;
export const MAX_TOKEN_AGE_MS = 10 * 60 * 1000;
export const MAX_TOKEN_LENGTH = 4096;

export interface ProviderConfig {
  provider: Provider;
  issuers: readonly string[];
  audiences: readonly string[];
  jwks: JwksCache;
}

const ONE_HOUR_MS = 60 * 60 * 1000;
export const APPLE_ISSUER = "https://appleid.apple.com";
export const GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"] as const;
export const APPLE_JWKS = new JwksCache("https://appleid.apple.com/auth/keys", ONE_HOUR_MS);
export const GOOGLE_JWKS = new JwksCache("https://www.googleapis.com/oauth2/v3/certs", ONE_HOUR_MS);

export interface VerifiedIdToken {
  sub: string;
  aud: string;
  nonce: string;
  /** Google's `email` claim, only to show the user which account they used. Never stored or logged. */
  email?: string;
}

export type IdTokenFailure =
  | "malformed"
  | "unsupported_alg"
  | "unknown_kid"
  | "bad_signature"
  | "wrong_issuer"
  | "wrong_audience"
  | "wrong_presenter"
  | "expired"
  | "issued_in_future"
  | "too_old"
  | "missing_nonce"
  | "bad_subject";

export type IdTokenResult =
  | { ok: true; token: VerifiedIdToken }
  | { ok: false; reason: IdTokenFailure }
  | { ok: false; reason: "keys_unavailable" };

function decodeJson(part: string): Record<string, unknown> | null {
  const bytes = fromB64url(part);
  if (bytes === null) return null;
  try {
    const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
    return isRecord(value) ? value : null;
  } catch {
    return null;
  }
}

export type JwsFailure = "malformed" | "unsupported_alg" | "unknown_kid" | "bad_signature";

export type JwsResult = { ok: true; payload: Record<string, unknown> } | { ok: false; reason: JwsFailure | "keys_unavailable" };

/**
 * The payload of a compact JWS signed RS256 by a key in `jwks`, checked before any of it is
 * trusted. Claims are the caller's to check. Shared by ID tokens and Apple's notifications.
 */
export async function verifyRs256Jws(token: string, jwks: JwksCache, nowMs: number): Promise<JwsResult> {
  const fail = (reason: JwsFailure): JwsResult => ({ ok: false, reason });
  if (token.length > MAX_TOKEN_LENGTH) return fail("malformed");
  const parts = token.split(".");
  if (parts.length !== 3) return fail("malformed");
  const [headerPart, payloadPart, signaturePart] = parts;
  const header = decodeJson(headerPart);
  const payload = decodeJson(payloadPart);
  const signature = fromB64url(signaturePart);
  if (header === null || payload === null || signature === null) return fail("malformed");
  // Only RS256: never `none`, never an HMAC keyed with a public key, and nothing that asks
  // the verifier to understand extensions.
  if (header.alg !== "RS256" || header.crit !== undefined) return fail("unsupported_alg");
  if (typeof header.kid !== "string" || header.kid.length === 0) return fail("malformed");

  const key = await jwks.key(header.kid, nowMs);
  if (key === "unavailable") return { ok: false, reason: "keys_unavailable" };
  if (key === "unknown_kid") return fail("unknown_kid");
  const signed = utf8(`${headerPart}.${payloadPart}`);
  if (!(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signed))) return fail("bad_signature");
  return { ok: true, payload };
}

export async function verifyIdToken(token: string, config: ProviderConfig, nowMs: number): Promise<IdTokenResult> {
  const fail = (reason: IdTokenFailure): IdTokenResult => ({ ok: false, reason });
  const jws = await verifyRs256Jws(token, config.jwks, nowMs);
  if (!jws.ok) return jws;
  const { payload } = jws;

  const { iss, aud, azp, exp, iat, nonce, sub, email } = payload;
  if (typeof iss !== "string" || !config.issuers.includes(iss)) return fail("wrong_issuer");
  if (typeof aud !== "string" || !config.audiences.includes(aud)) return fail("wrong_audience");
  // The presenters we accept are our own client ids, the same list as the audiences, but azp
  // need not equal aud (https://developers.google.com/identity/openid-connect/openid-connect#obtainuserinfo).
  if (azp !== undefined && (typeof azp !== "string" || !config.audiences.includes(azp))) return fail("wrong_presenter");
  if (typeof exp !== "number" || typeof iat !== "number") return fail("malformed");
  if (exp * 1000 <= nowMs - SKEW_MS) return fail("expired");
  if (iat * 1000 > nowMs + SKEW_MS) return fail("issued_in_future");
  if (iat * 1000 < nowMs - MAX_TOKEN_AGE_MS) return fail("too_old");
  if (typeof nonce !== "string" || nonce.length === 0) return fail("missing_nonce");
  if (typeof sub !== "string" || sub.length === 0 || sub.length > 255) return fail("bad_subject");
  const verified: VerifiedIdToken = { sub, aud, nonce };
  if (config.provider === "google" && typeof email === "string" && email.length <= 320) verified.email = email;
  return { ok: true, token: verified };
}
