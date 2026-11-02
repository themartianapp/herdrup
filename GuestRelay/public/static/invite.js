// The DOM-free part of the invite landing page, imported by i.js and by the tests.

// The Worker serves the page at /i/<payload> only when <payload> is b64url.
var INVITE_PATH = /^\/i\/([^/]+)$/;
// A short link's one path segment: a 12-character id, then a 22-character key.
var SHORT_SEGMENT = /^\/i\/([A-Za-z0-9_-]{12})([A-Za-z0-9_-]{22})$/;
var NONCE_BYTES = 12;
var TAG_BYTES = 16;

/**
 * The invite payload of the page's URL: the path of /i/<payload>, else the fragment of the
 * older /i#<payload> links. Returns "" when the URL carries neither.
 * @param {string} pathname location.pathname
 * @param {string} hash location.hash
 * @returns {string}
 */
export function invitePayload(pathname, hash) {
  var match = INVITE_PATH.exec(pathname);
  return match !== null ? match[1] : hash.replace(/^#/, "");
}

/**
 * The id and key of a short link /i/<id><key>: a path segment of exactly 34 b64url
 * characters. Anything else is a long v1 link, whose payload is always hundreds of
 * characters. Returns null for a long link.
 * @param {string} pathname location.pathname
 * @returns {{ id: string, key: string } | null}
 */
export function shortInvite(pathname) {
  var match = SHORT_SEGMENT.exec(pathname);
  return match !== null ? { id: match[1], key: match[2] } : null;
}

/**
 * Decrypts a short invite's blob, nonce (12) || ciphertext || tag (16), with AES-128-GCM
 * under the link's key and the id as additional data. Returns the b64url of the v1 invite
 * JSON: the same payload a long link carries. Throws when the blob doesn't decrypt, or when
 * the invite's relay isn't `origin`, the relay the blob came from.
 * @param {{ id: string, key: string }} short
 * @param {ArrayBuffer} blob
 * @param {string} origin location.origin
 * @returns {Promise<string>}
 */
export async function openShortInvite(short, blob, origin) {
  var bytes = new Uint8Array(blob);
  if (bytes.length <= NONCE_BYTES + TAG_BYTES) throw new Error("short blob");
  var key = await crypto.subtle.importKey("raw", b64urlBytes(short.key), "AES-GCM", false, ["decrypt"]);
  var plain = new Uint8Array(await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: bytes.subarray(0, NONCE_BYTES), additionalData: new TextEncoder().encode(short.id) },
    key,
    bytes.subarray(NONCE_BYTES),
  ));
  var invite = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plain));
  if (invite === null || typeof invite !== "object" || !isRelay(invite.relay, origin)) {
    throw new Error("relay mismatch");
  }
  var binary = "";
  for (var i = 0; i < plain.length; i++) binary += String.fromCharCode(plain[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * Whether an invite's relay URL names this page's relay: same scheme, host and port as
 * `origin`, at its root. A trailing slash is the same relay, as the app treats it
 * (GuestInvite.Web.isOnRelay).
 * @param {unknown} relay
 * @param {string} origin
 */
export function isRelay(relay, origin) {
  if (typeof relay !== "string") return false;
  var url;
  try { url = new URL(relay); } catch (_) { return false; }
  if (url.username || url.password || url.search || url.hash) return false;
  return url.origin === origin && url.pathname.replace(/\/+$/, "") === "";
}

function b64urlBytes(text) {
  var base64 = text.replace(/-/g, "+").replace(/_/g, "/");
  var binary = atob(base64 + "===".slice((base64.length + 3) % 4));
  var bytes = new Uint8Array(binary.length);
  for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
