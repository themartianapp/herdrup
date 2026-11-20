// The keys derived from the ACCOUNT_HMAC_KEY secret (32 random bytes, standard base64): one
// HMAC key for sign-in nonces, one for the stored hash of each provider's user id, and one for
// the pairwise account id each host sees in statements (src/statements.ts). HKDF-SHA256 with
// an empty salt and a distinct info string per key, so adding a key never changes the others.
import { hex, utf8 } from "./bytes";

export interface ServiceKeys {
  nonce: CryptoKey;
  subject: CryptoKey;
  pairwise: CryptoKey;
}

const SECRET = /^[A-Za-z0-9+/]{43}=$/;

let cached: { secret: string; keys: Promise<ServiceKeys> } | undefined;

/** The derived keys, or null when the secret is missing or not 32 bytes of base64. */
export function serviceKeys(secret: string | undefined): Promise<ServiceKeys> | null {
  const trimmed = secret?.trim() ?? "";
  if (!SECRET.test(trimmed)) return null;
  if (cached?.secret !== trimmed) cached = { secret: trimmed, keys: derive(trimmed) };
  return cached.keys;
}

async function derive(secret: string): Promise<ServiceKeys> {
  const raw = Uint8Array.from(atob(secret), (c) => c.charCodeAt(0));
  const root = await crypto.subtle.importKey("raw", raw, "HKDF", false, ["deriveBits"]);
  const subkey = async (info: string) => {
    const bits = await crypto.subtle.deriveBits(
      { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: utf8(info) },
      root,
      256,
    );
    return crypto.subtle.importKey("raw", bits, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  };
  return {
    nonce: await subkey("herdrup-accounts nonce v1"),
    subject: await subkey("herdrup-accounts subject v1"),
    pairwise: await subkey("herdrup-accounts pairwise v1"),
  };
}

export type Provider = "apple" | "google";

/** What identities.subject_hash holds for a provider's `sub`. */
export async function subjectHash(key: CryptoKey, provider: Provider, sub: string): Promise<string> {
  return hex(await crypto.subtle.sign("HMAC", key, utf8(`${provider}|${sub}`)));
}
