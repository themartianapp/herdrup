// Sign in with Apple's REST side, used only at account deletion (DESIGN.md §6.1, §6.2):
//
// - The client secret: an ES256 JWT the Worker signs for one client_id with the Sign in with
//   Apple key (APPLE_SIWA_P8, the .p8 file as pasted), valid 5 minutes:
//     header  {alg: "ES256", kid: APPLE_KEY_ID}
//     payload {iss: APPLE_TEAM_ID, iat, exp: iat + 300, aud: "https://appleid.apple.com", sub: client_id}
// - The revoke (TN3194): the authorization code from the user's fresh sign-in is exchanged at
//   /auth/token for a refresh token, which is revoked at once at /auth/revoke, both with the
//   client_id the code was issued to (the ID token's `aud`). No Apple token is ever stored.
//
// Nothing here logs or returns Apple's tokens, the code or the secret.
import { b64url, utf8 } from "./bytes";
import type { Env } from "./env";

export const APPLE_AUDIENCE = "https://appleid.apple.com";
export const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
export const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
/** The Services ID's registered return URL (DESIGN.md §10), which Apple wants again when a web code is exchanged. */
export const APPLE_WEB_REDIRECT_URI = "https://accounts.herdrup.app/v1/auth/web/apple/callback";
export const CLIENT_SECRET_TTL_SECONDS = 300;
const FETCH_TIMEOUT_MS = 5000;
/** Apple's Team ID and Key ID: 10 upper-case letters or digits. */
const APPLE_ID = /^[A-Z0-9]{10}$/;

export interface AppleSigner {
  keyId: string;
  teamId: string;
  key: CryptoKey;
}

let cached: { pem: string; key: Promise<CryptoKey | null> } | undefined;

async function importP8(pem: string): Promise<CryptoKey | null> {
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  try {
    const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
    return await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  } catch {
    return null;
  }
}

/** The signing key and its ids, or null while APPLE_SIWA_P8, APPLE_KEY_ID or APPLE_TEAM_ID is missing or unusable. */
export async function appleSigner(env: Env): Promise<AppleSigner | null> {
  const pem = env.APPLE_SIWA_P8?.trim() ?? "";
  const keyId = env.APPLE_KEY_ID ?? "";
  const teamId = env.APPLE_TEAM_ID ?? "";
  if (pem.length === 0 || !APPLE_ID.test(keyId) || !APPLE_ID.test(teamId)) return null;
  if (cached?.pem !== pem) cached = { pem, key: importP8(pem) };
  const key = await cached.key;
  return key === null ? null : { keyId, teamId, key };
}

/** The client secret for `clientId`: a compact JWS, ES256 (the IEEE P1363 r‖s signature WebCrypto makes). */
export async function clientSecret(signer: AppleSigner, clientId: string, nowMs: number): Promise<string> {
  const iat = Math.floor(nowMs / 1000);
  const head = b64url(utf8(JSON.stringify({ alg: "ES256", kid: signer.keyId })));
  const body = b64url(utf8(JSON.stringify({ iss: signer.teamId, iat, exp: iat + CLIENT_SECRET_TTL_SECONDS, aud: APPLE_AUDIENCE, sub: clientId })));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer.key, utf8(`${head}.${body}`));
  return `${head}.${body}.${b64url(new Uint8Array(signature))}`;
}

function postForm(url: string, fields: Record<string, string>): Promise<Response> {
  return fetch(url, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams(fields).toString(),
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
}

/**
 * Exchanges `code` and revokes the refresh token it yields, for the client the code was issued
 * to. True only when Apple confirmed the revoke; any failure (a bad or spent code, a network
 * error, an answer without a refresh token) is false, and the caller tells the user Apple's
 * manual path.
 */
export async function revokeAppleConsent(signer: AppleSigner, env: Env, clientId: string, code: string, nowMs: number): Promise<boolean> {
  try {
    const secret = await clientSecret(signer, clientId, nowMs);
    const exchange = await postForm(APPLE_TOKEN_URL, {
      client_id: clientId,
      client_secret: secret,
      code,
      grant_type: "authorization_code",
      ...(clientId === env.APPLE_WEB_CLIENT_ID ? { redirect_uri: APPLE_WEB_REDIRECT_URI } : {}),
    });
    if (!exchange.ok) return false;
    const tokens: unknown = await exchange.json();
    const refreshToken = typeof tokens === "object" && tokens !== null && "refresh_token" in tokens ? tokens.refresh_token : undefined;
    if (typeof refreshToken !== "string" || refreshToken.length === 0) return false;
    const revoke = await postForm(APPLE_REVOKE_URL, {
      client_id: clientId,
      client_secret: secret,
      token: refreshToken,
      token_type_hint: "refresh_token",
    });
    return revoke.ok;
  } catch {
    return false;
  }
}
