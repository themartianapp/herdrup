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
 * The "Open in browser" link: the browser guest on this relay, with the payload the app link
 * carries (a short link's decrypted payload) in the fragment, so it never reaches a server.
 * @param {string} payload b64url invite payload
 * @returns {string}
 */
export function browserLink(payload) {
  return "/web/#" + payload;
}

/**
 * Which HerdrUp this browser's device installs: "ios" on an iPhone or iPad (iPadOS Safari
 * reports a Mac, told apart by its touch screen), "desktop" on a Windows, Mac or Linux
 * computer (HerdrUp Desktop), "" anywhere else, such as Android, which has no HerdrUp.
 * @param {string} userAgent navigator.userAgent
 * @param {number} maxTouchPoints navigator.maxTouchPoints
 * @returns {"ios" | "desktop" | ""}
 */
export function installTarget(userAgent, maxTouchPoints) {
  if (/iPhone|iPad|iPod/.test(userAgent)) return "ios";
  if (/Macintosh/.test(userAgent)) return maxTouchPoints > 1 ? "ios" : "desktop";
  if (/Android|Mobile/.test(userAgent)) return "";
  if (/Windows|Linux|X11/.test(userAgent)) return "desktop";
  return "";
}

/**
 * Whether an invite's relay names this page's relay: the page origin exactly, with or without
 * one trailing slash, as the app accepts (GuestInvite.Web.isOnRelay). Compared as strings, not
 * parsed: the payload is handed to the app unchanged, and a parser-ambiguous spelling (a
 * backslash, dot segments, credentials) can mean this relay to the browser's URL parser and
 * another host to the app's (review of #608).
 * @param {unknown} relay
 * @param {string} origin
 */
export function isRelay(relay, origin) {
  return typeof relay === "string" && (relay === origin || relay === origin + "/");
}

function b64urlBytes(text) {
  var base64 = text.replace(/-/g, "+").replace(/_/g, "/");
  var binary = atob(base64 + "===".slice((base64.length + 3) % 4));
  var bytes = new Uint8Array(binary.length);
  for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
