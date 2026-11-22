// The client side of approve-v1 (src/approvals.ts, DESIGN.md §12), as the browser and the
// approving device run it, for the tests: the service itself never computes the code or touches
// an envelope. herdrup-desktop's Go implementation (internal/account/approve.go) produced
// test/vectors/approve-v1.json; test/approvals.test.ts regenerates that file with this code.
import { b64url, fromB64url, utf8 } from "../src/bytes";
import { labelled } from "../src/approvals";

export const APPROVE_CODE_LABEL = "herdrup-approve-v1|sas";
export const APPROVE_ENVELOPE_LABEL = "herdrup-approve-v1|envelope";
const X25519_PKCS8_PREFIX = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20]);

export interface X25519Key {
  privateKey: CryptoKey;
  /** The raw public key, 32 bytes. */
  pub: Uint8Array;
}

/** An X25519 key from its raw 32-byte private half (the vectors' keys), or a fresh one. */
export async function x25519Key(rawPrivate?: Uint8Array): Promise<X25519Key> {
  // workers-types types generateKey and exportKey as unions; an X25519 pair and its exports have these shapes.
  const privateKey =
    rawPrivate === undefined
      ? ((await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair).privateKey
      : await crypto.subtle.importKey("pkcs8", Uint8Array.from([...X25519_PKCS8_PREFIX, ...rawPrivate]), { name: "X25519" }, true, ["deriveBits"]);
  const jwk = (await crypto.subtle.exportKey("jwk", privateKey)) as JsonWebKey;
  return { privateKey, pub: fromB64url(jwk.x ?? "")! };
}

/** The 4 digits both sides show: uint32_be(h[0..4]) mod 10000, zero-padded. */
export async function approveCode(browserPub: Uint8Array, approverPub: Uint8Array, nonceB: Uint8Array, nonceT: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", labelled(APPROVE_CODE_LABEL, browserPub, approverPub, nonceB, nonceT)));
  return String(new DataView(h.buffer).getUint32(0) % 10000).padStart(4, "0");
}

/** The AES-256-GCM key between the two verified keys; `own` is whichever side holds a private key. */
async function envelopeKey(own: CryptoKey, peerPub: Uint8Array, browserPub: Uint8Array, approverPub: Uint8Array): Promise<CryptoKey> {
  const peer = await crypto.subtle.importKey("raw", peerPub, { name: "X25519" }, true, []);
  // The runtime reads `public`; workers-types spells that member `$public` (src/devices.ts).
  const algorithm = { name: "X25519", public: peer };
  const ikm = new Uint8Array(await crypto.subtle.deriveBits(algorithm, own, 256));
  if (ikm.every((byte) => byte === 0)) throw new Error("approve-v1: all-zero shared secret");
  const hkdf = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: Uint8Array.from([...browserPub, ...approverPub]), info: utf8(APPROVE_ENVELOPE_LABEL) },
    hkdf,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

function envelopeAad(browserPub: Uint8Array, approverPub: Uint8Array, seq: number): Uint8Array {
  const seqBytes = new Uint8Array(8);
  new DataView(seqBytes.buffer).setBigUint64(0, BigInt(seq));
  return labelled(APPROVE_ENVELOPE_LABEL, browserPub, approverPub, seqBytes);
}

/** The approver seals `json` to the browser at `seq`: b64url(iv ‖ AES-256-GCM). */
export async function sealEnvelope(approver: X25519Key, browserPub: Uint8Array, seq: number, json: string, iv?: Uint8Array): Promise<string> {
  const key = await envelopeKey(approver.privateKey, browserPub, browserPub, approver.pub);
  const nonce = iv ?? crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: envelopeAad(browserPub, approver.pub, seq) }, key, utf8(json)),
  );
  return b64url(Uint8Array.from([...nonce, ...sealed]));
}

/** The browser opens an envelope from `approverPub` at `seq`; throws when it doesn't verify. */
export async function openEnvelope(browser: X25519Key, approverPub: Uint8Array, seq: number, sealed: string): Promise<string> {
  const raw = fromB64url(sealed)!;
  const key = await envelopeKey(browser.privateKey, approverPub, browser.pub, approverPub);
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: raw.slice(0, 12), additionalData: envelopeAad(browser.pub, approverPub, seq) },
    key,
    raw.slice(12),
  );
  return new TextDecoder().decode(plain);
}
