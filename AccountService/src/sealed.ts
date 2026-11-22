// Values that wait in D1 for a handoff code sealed with AES-GCM under a key derived (HKDF-SHA256)
// from the code itself: Google's email for a sign-in handoff, Apple's authorization code for a
// deletion's revoke. Only the herdrup:// URL carries the code and D1 keeps only its hash, so D1
// and its Time Travel copies never hold these readably. `info` separates the uses.
import { b64url, fromB64url, utf8 } from "./bytes";

export const HINT_INFO = "herdrup handoff hint v1";
export const APPLE_CODE_INFO = "herdrup delete apple code v1";

async function keyFor(code: Uint8Array, info: string): Promise<CryptoKey> {
  const root = await crypto.subtle.importKey("raw", code, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: utf8(info) },
    root,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

export async function seal(code: Uint8Array, info: string, text: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await keyFor(code, info), utf8(text)));
  return b64url(Uint8Array.from([...iv, ...sealed]));
}

/** The sealed text, or null when it doesn't open under this code and use. */
export async function unseal(code: Uint8Array, info: string, sealed: string): Promise<string | null> {
  const bytes = fromB64url(sealed);
  if (bytes === null || bytes.byteLength < 12 + 16) return null;
  try {
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.subarray(0, 12) }, await keyFor(code, info), bytes.subarray(12));
    return new TextDecoder().decode(plain);
  } catch {
    return null;
  }
}
