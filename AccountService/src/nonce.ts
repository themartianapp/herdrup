// Sign-in nonces. The app asks for one, hands it to Apple or Google, and the ID token it gets
// back carries it in its `nonce` claim. A nonce is stateless until spent:
// b64url(expiry in Unix seconds, 8 bytes big-endian ‖ 16 random bytes ‖ the first 16 bytes
// of HMAC-SHA256 over those 24 bytes), 54 characters. Spending one records its SHA-256 in
// used_nonces, so each nonce signs in once.
import { b64url, fromB64url, sha256Hex } from "./bytes";

export const NONCE_TTL_MS = 10 * 60 * 1000;
const NONCE = /^[A-Za-z0-9_-]{54}$/;
const HEAD_BYTES = 24;
const TAG_BYTES = 16;

async function tag(key: CryptoKey, head: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, head)).slice(0, TAG_BYTES);
}

export async function issueNonce(key: CryptoKey, nowMs: number): Promise<{ nonce: string; expiresUnix: number }> {
  const expiresUnix = Math.floor((nowMs + NONCE_TTL_MS) / 1000);
  const bytes = new Uint8Array(HEAD_BYTES + TAG_BYTES);
  new DataView(bytes.buffer).setBigUint64(0, BigInt(expiresUnix));
  crypto.getRandomValues(bytes.subarray(8, HEAD_BYTES));
  bytes.set(await tag(key, bytes.subarray(0, HEAD_BYTES)), HEAD_BYTES);
  return { nonce: b64url(bytes), expiresUnix };
}

/** The nonce's expiry in ms when this service issued it and it has not expired, else null. */
export async function openNonce(key: CryptoKey, nonce: string, nowMs: number): Promise<number | null> {
  if (!NONCE.test(nonce)) return null;
  const bytes = fromB64url(nonce);
  if (bytes === null || bytes.byteLength !== HEAD_BYTES + TAG_BYTES) return null;
  const expected = await tag(key, bytes.subarray(0, HEAD_BYTES));
  if (!crypto.subtle.timingSafeEqual(expected, bytes.subarray(HEAD_BYTES))) return null;
  const expiresMs = Number(new DataView(bytes.buffer, bytes.byteOffset).getBigUint64(0)) * 1000;
  return expiresMs > nowMs ? expiresMs : null;
}

/** Records the nonce as spent. False when it already was. */
export async function spendNonce(db: D1Database, nonce: string, expiresMs: number): Promise<boolean> {
  const result = await db
    .prepare("INSERT INTO used_nonces (nonce_hash, exp_ms) VALUES (?, ?) ON CONFLICT DO NOTHING")
    .bind(await sha256Hex(nonce), expiresMs)
    .run();
  return result.meta.changes === 1;
}
