// base64url, hex and SHA-256 helpers.

export const utf8 = (text: string): Uint8Array => new TextEncoder().encode(text);

export function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Unpadded base64url, or null when `text` isn't. */
export function fromB64url(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

/**
 * 32 bytes (a device key, nonce or commit) from canonical unpadded base64url: exactly 43
 * characters whose re-encoding is the input. Base64url has 4 spellings of the same 32 bytes (the
 * last character's two unused bits), so a key is only ever stored and compared in this one.
 */
export function bytes32(value: unknown): Uint8Array | null {
  if (typeof value !== "string" || value.length !== 43) return null;
  const bytes = fromB64url(value);
  return bytes !== null && b64url(bytes) === value ? bytes : null;
}

export function randomB64url(byteLength: number): string {
  return b64url(crypto.getRandomValues(new Uint8Array(byteLength)));
}

export function hex(bytes: ArrayBuffer | Uint8Array): string {
  return Array.from(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", utf8(text)));
}

/** Constant-time equality of two strings of the same length; false for different lengths. */
export function sameString(a: string, b: string): boolean {
  const left = utf8(a);
  const right = utf8(b);
  return left.byteLength === right.byteLength && crypto.subtle.timingSafeEqual(left, right);
}
