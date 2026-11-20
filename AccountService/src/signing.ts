// The statement signing keys and the JWKS hosts verify statements with.
//
// Two slots, A and B, so a key can be rotated without ever leaving Cloudflare:
//   STATEMENT_KEY_A / STATEMENT_KEY_B   secrets: Ed25519 private keys, PKCS8 DER in standard
//                                       base64 (`openssl genpkey -algorithm ed25519 -outform DER | base64`);
//   STATEMENT_KID_A / STATEMENT_KID_B   vars: each slot's kid;
//   STATEMENT_ACTIVE                    var: "A" or "B", the slot that signs;
//   STATEMENT_REVOKED_KIDS              var: comma-separated kids never used or published again.
// Every slot with a key and a kid that isn't revoked is published, so a new key can sit in the
// idle slot (published, not signing) until hosts have cached it, and the old key stays
// published after the switch until its last statement has expired (README "Rotate the
// statement key"). The JWKS also lists the revoked kids, so hosts drop them for good.
import { b64url, fromB64url, utf8 } from "./bytes";
import type { Env } from "./env";

export const JWKS_MAX_AGE_SECONDS = 3600;
const KID = /^[A-Za-z0-9._-]{1,32}$/;
const SECRET = /^[A-Za-z0-9+/]+={0,2}$/;

export interface PublicJwk {
  kty: "OKP";
  crv: "Ed25519";
  x: string;
  kid: string;
  use: "sig";
  alg: "EdDSA";
}

export interface Jwks {
  keys: PublicJwk[];
  revoked_kids: string[];
}

export interface SigningKey {
  kid: string;
  privateKey: CryptoKey;
  jwk: PublicJwk;
}

const imported = new Map<string, Promise<{ privateKey: CryptoKey; x: string } | null>>();

/** The key in a PKCS8 secret and its public half, or null when the secret isn't an Ed25519 key. */
function importSecret(secret: string): Promise<{ privateKey: CryptoKey; x: string } | null> {
  let entry = imported.get(secret);
  if (entry === undefined) {
    entry = (async () => {
      const der = SECRET.test(secret) ? Uint8Array.from(atob(secret), (c) => c.charCodeAt(0)) : null;
      if (der === null) return null;
      try {
        const exportable = await crypto.subtle.importKey("pkcs8", der, { name: "Ed25519" }, true, ["sign"]);
        // workers-types types the "jwk" export as a union; an Ed25519 private key exports as a JWK.
        const { x } = (await crypto.subtle.exportKey("jwk", exportable)) as JsonWebKey;
        if (typeof x !== "string" || fromB64url(x)?.byteLength !== 32) return null;
        const privateKey = await crypto.subtle.importKey("pkcs8", der, { name: "Ed25519" }, false, ["sign"]);
        return { privateKey, x };
      } catch {
        return null;
      }
    })();
    imported.set(secret, entry);
  }
  return entry;
}

function revokedKids(env: Env): string[] {
  return (env.STATEMENT_REVOKED_KIDS ?? "")
    .split(",")
    .map((kid) => kid.trim())
    .filter((kid) => KID.test(kid));
}

async function slot(env: Env, name: "A" | "B", revoked: string[]): Promise<SigningKey | null> {
  const secret = (name === "A" ? env.STATEMENT_KEY_A : env.STATEMENT_KEY_B)?.trim() ?? "";
  const kid = (name === "A" ? env.STATEMENT_KID_A : env.STATEMENT_KID_B)?.trim() ?? "";
  if (secret.length === 0 || !KID.test(kid) || revoked.includes(kid)) return null;
  const key = await importSecret(secret);
  if (key === null) return null;
  return { kid, privateKey: key.privateKey, jwk: { kty: "OKP", crv: "Ed25519", x: key.x, kid, use: "sig", alg: "EdDSA" } };
}

/** The key that signs statements, or null when the active slot has no usable key. */
export async function activeKey(env: Env): Promise<SigningKey | null> {
  const active = env.STATEMENT_ACTIVE?.trim();
  if (active !== "A" && active !== "B") return null;
  return slot(env, active, revokedKids(env));
}

/** Every published key, the active one first, and the revoked kids. */
export async function jwks(env: Env): Promise<Jwks> {
  const revoked = revokedKids(env);
  const active = env.STATEMENT_ACTIVE?.trim() === "B" ? "B" : "A";
  const keys: PublicJwk[] = [];
  for (const name of active === "A" ? (["A", "B"] as const) : (["B", "A"] as const)) {
    const key = await slot(env, name, revoked);
    if (key !== null && !keys.some((known) => known.kid === key.kid)) keys.push(key.jwk);
  }
  return { keys, revoked_kids: revoked };
}

/** A compact JWS (EdDSA) over `header` and `payload`, serialized in their key order. */
export async function signJws(key: SigningKey, header: Record<string, unknown>, payload: Record<string, unknown>): Promise<string> {
  const signingInput = `${b64url(utf8(JSON.stringify(header)))}.${b64url(utf8(JSON.stringify(payload)))}`;
  const signature = await crypto.subtle.sign("Ed25519", key.privateKey, utf8(signingInput));
  return `${signingInput}.${b64url(new Uint8Array(signature))}`;
}
