// Devices: each install's guest key (X25519), bound to an account by proof of possession.
//
//   POST   /v1/devices/challenge  → {challenge_id, server_pub, salt, account_id, expires_in}
//   POST   /v1/devices            {challenge_id, device_pub, mac, name, platform} → {device}
//   GET    /v1/devices            → {devices: [{id, name, platform, device_pub, created_ms, current}]}
//   PATCH  /v1/devices/<id>       {name} → {device}
//   DELETE /v1/devices/<id>       → 204; ends the sessions bound to that device
//
// An X25519 key can't sign, so the device proves it holds the private half with a key
// agreement against a fresh server key E (the challenge, 60 seconds, one use):
//   k   = X25519(d, E)                      (all zero → refused)
//   mk  = HKDF-SHA256(ikm = k, salt, info = "herdrup account enrol v1", 32 bytes)
//   mac = HMAC-SHA256(mk, "herdrup-enrol-v1|" account_id "|" device_pub "|" challenge_id)
// with device_pub, server_pub, salt and mac in unpadded base64url. The Worker computes the same
// k as X25519(e, D). test/vectors/enrol-v1.json pins the algorithm for every client.
//
// A session enrols one device, once: its device is fixed after that, so a stolen access token
// can't bind the thief's own key to the account. A key belongs to one account at a time.
import { b64url, fromB64url, randomB64url, sameString, utf8 } from "./bytes";
import { openAccountRequest } from "./auth";
import type { Env } from "./env";
import { errorResponse, json, readJsonObject, type Endpoint } from "./http";
import { PLATFORMS, type Platform, type Principal } from "./sessions";

export const CHALLENGE_TTL_MS = 60 * 1000;
export const MAX_DEVICES = 20;
export const MAX_DEVICE_BODY_BYTES = 2048;
export const MAX_NAME_LENGTH = 64;
export const ENROL_INFO = "herdrup account enrol v1";
export const ENROL_MESSAGE_PREFIX = "herdrup-enrol-v1|";
const KEY_B64 = /^[A-Za-z0-9_-]{43}$/;
const ID = /^[A-Za-z0-9_-]{22}$/;
const MAC = /^[A-Za-z0-9_-]{43}$/;

interface DeviceRow {
  id: string;
  account_id: string;
  device_pub: string;
  name: string;
  platform: string;
  created_ms: number;
}

const deviceJson = (row: DeviceRow, principal: Principal) => ({
  id: row.id,
  name: row.name,
  platform: row.platform,
  device_pub: row.device_pub,
  created_ms: row.created_ms,
  current: row.id === principal.deviceId,
});

/** A device name with control characters removed and trimmed, or null when empty or too long. */
export function deviceName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const name = value.replace(/\p{Cc}/gu, "").trim();
  const length = Array.from(name).length;
  return length >= 1 && length <= MAX_NAME_LENGTH ? name : null;
}

/** X25519(private, public) as 32 bytes, or null when the public key is a low-order point. */
export async function x25519(privateKey: CryptoKey, publicKey: Uint8Array): Promise<Uint8Array | null> {
  try {
    const peer = await crypto.subtle.importKey("raw", publicKey, { name: "X25519" }, true, []);
    // The runtime reads `public`; workers-types spells that member `$public`, so the object is
    // built apart from the call, where TypeScript doesn't check it for extra properties.
    const algorithm = { name: "X25519", public: peer };
    const shared = new Uint8Array(await crypto.subtle.deriveBits(algorithm, privateKey, 256));
    return shared.some((byte) => byte !== 0) ? shared : null;
  } catch {
    // WebCrypto refuses a shared secret of all zeros: the peer key is a low-order point.
    return null;
  }
}

/** The enrolment MAC (base64url) over a shared secret, as every client computes it. */
export async function enrolMac(
  shared: Uint8Array,
  salt: Uint8Array,
  accountId: string,
  devicePub: string,
  challengeId: string,
): Promise<string> {
  const ikm = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveBits"]);
  const mk = await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info: utf8(ENROL_INFO) }, ikm, 256);
  const hmac = await crypto.subtle.importKey("raw", mk, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const message = `${ENROL_MESSAGE_PREFIX}${accountId}|${devicePub}|${challengeId}`;
  return b64url(new Uint8Array(await crypto.subtle.sign("HMAC", hmac, utf8(message))));
}

export async function handleChallenge(request: Request, env: Env, nowMs: number): Promise<Response> {
  const principal = await openAccountRequest(request, env, "/v1/devices/challenge", nowMs, "ENROL_LIMIT");
  if (principal instanceof Response) return principal;
  // workers-types types generateKey and exportKey as unions; an X25519 pair and its exports have these shapes.
  const pair = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const serverPub = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  const serverPkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const challengeId = randomB64url(16);
  const salt = randomB64url(32);
  await env.DB.prepare(
    "INSERT INTO enrol_challenges (id, account_id, session_id, server_pkcs8, salt, exp_ms) VALUES (?, ?, ?, ?, ?, ?)",
  )
    .bind(challengeId, principal.accountId, principal.sessionId, b64url(serverPkcs8), salt, nowMs + CHALLENGE_TTL_MS)
    .run();
  return json(200, {
    challenge_id: challengeId,
    server_pub: b64url(serverPub),
    salt,
    account_id: principal.accountId,
    expires_in: CHALLENGE_TTL_MS / 1000,
  });
}

export async function handleEnrol(request: Request, env: Env, nowMs: number): Promise<Response> {
  const principal = await openAccountRequest(request, env, "/v1/devices", nowMs, "ENROL_LIMIT");
  if (principal instanceof Response) return principal;
  const body = await readJsonObject(request, MAX_DEVICE_BODY_BYTES);
  if (body instanceof Response) return body;
  const { challenge_id: challengeId, device_pub: devicePub, mac, platform } = body;
  const name = deviceName(body.name);
  if (
    typeof challengeId !== "string" ||
    !ID.test(challengeId) ||
    typeof devicePub !== "string" ||
    !KEY_B64.test(devicePub) ||
    typeof mac !== "string" ||
    !MAC.test(mac) ||
    name === null ||
    !PLATFORMS.includes(platform as Platform)
  ) {
    return errorResponse(400, "bad_request");
  }

  // Taken whatever happens next: one proof per challenge.
  const challenge = await env.DB.prepare(
    "DELETE FROM enrol_challenges WHERE id = ? AND session_id = ? AND exp_ms > ? RETURNING server_pkcs8, salt",
  )
    .bind(challengeId, principal.sessionId, nowMs)
    .first<{ server_pkcs8: string; salt: string }>();
  if (challenge === null) return errorResponse(400, "challenge_invalid");
  const devicePubBytes = fromB64url(devicePub);
  const serverPkcs8 = fromB64url(challenge.server_pkcs8);
  const salt = fromB64url(challenge.salt);
  if (devicePubBytes === null || serverPkcs8 === null || salt === null) return errorResponse(400, "bad_request");
  const serverKey = await crypto.subtle.importKey("pkcs8", serverPkcs8, { name: "X25519" }, false, ["deriveBits"]);
  const shared = await x25519(serverKey, devicePubBytes);
  if (shared === null) return errorResponse(400, "invalid_device_key");
  if (!sameString(await enrolMac(shared, salt, principal.accountId, devicePub, challengeId), mac)) {
    return errorResponse(400, "proof_invalid");
  }

  // A session's device is fixed once set; enrolling the same key again is a no-op.
  if (principal.deviceId !== null) {
    const bound = await env.DB.prepare("SELECT * FROM devices WHERE id = ?").bind(principal.deviceId).first<DeviceRow>();
    if (bound === null || bound.device_pub !== devicePub) return errorResponse(409, "session_has_device");
    return json(200, { device: deviceJson(bound, principal) });
  }

  // One D1 batch, which is a transaction: insert the device only while this session still
  // exists without a device, the key is free and the account is under its cap (all in the
  // inserting statement, so two enrolments can't both pass the count); then bind the session
  // to the account's device for this key, if any. Nothing is ever undone afterwards: once
  // committed, the device may already belong to another session of the account (a new
  // sign-in on the same install adopts it), so the outcome is only read back.
  const deviceId = randomB64url(16);
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO devices (id, account_id, device_pub, name, platform, created_ms)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6
        WHERE (SELECT COUNT(*) FROM devices WHERE account_id = ?2) < ?7
          AND EXISTS (SELECT 1 FROM sessions WHERE id = ?8 AND device_id IS NULL)
       ON CONFLICT (device_pub) DO NOTHING`,
    ).bind(deviceId, principal.accountId, devicePub, name, platform, nowMs, MAX_DEVICES, principal.sessionId),
    env.DB.prepare(
      `UPDATE sessions SET device_id = (SELECT id FROM devices WHERE device_pub = ?1 AND account_id = ?2)
        WHERE id = ?3 AND device_id IS NULL`,
    ).bind(devicePub, principal.accountId, principal.sessionId),
  ]);
  const session = await env.DB.prepare("SELECT device_id FROM sessions WHERE id = ?")
    .bind(principal.sessionId)
    .first<{ device_id: string | null }>();
  // Signed out (or the session's device removed) meanwhile: as for any request without a session.
  if (session === null) return errorResponse(401, "invalid_token", { "WWW-Authenticate": "Bearer" });
  const row = await env.DB.prepare("SELECT * FROM devices WHERE device_pub = ?").bind(devicePub).first<DeviceRow>();
  if (row !== null && row.account_id !== principal.accountId) return errorResponse(409, "device_in_other_account");
  // Another enrolment bound this session first, with another key; this one inserted nothing.
  if (session.device_id !== null && session.device_id !== row?.id) return errorResponse(409, "session_has_device");
  if (row === null || session.device_id === null) return errorResponse(403, "too_many_devices");
  return json(row.id === deviceId ? 201 : 200, { device: deviceJson(row, { ...principal, deviceId: row.id }) });
}

export async function handleListDevices(request: Request, env: Env, nowMs: number): Promise<Response> {
  const principal = await openAccountRequest(request, env, "/v1/devices", nowMs);
  if (principal instanceof Response) return principal;
  const { results } = await env.DB.prepare("SELECT * FROM devices WHERE account_id = ? ORDER BY created_ms, id")
    .bind(principal.accountId)
    .all<DeviceRow>();
  return json(200, { devices: results.map((row) => deviceJson(row, principal)) });
}

export async function handleDevice(request: Request, env: Env, deviceId: string, nowMs: number): Promise<Response> {
  const endpoint: Endpoint = "/v1/devices/:id";
  const principal = await openAccountRequest(request, env, endpoint, nowMs);
  if (principal instanceof Response) return principal;
  if (request.method === "DELETE") {
    // The sessions bound to the device go with it (ON DELETE CASCADE): that device is signed out.
    const removed = await env.DB.prepare("DELETE FROM devices WHERE id = ? AND account_id = ?").bind(deviceId, principal.accountId).run();
    return removed.meta.changes > 0
      ? new Response(null, { status: 204, headers: { "cache-control": "no-store" } })
      : errorResponse(404, "not_found");
  }
  const body = await readJsonObject(request, MAX_DEVICE_BODY_BYTES);
  if (body instanceof Response) return body;
  const name = deviceName(body.name);
  if (name === null) return errorResponse(400, "bad_request");
  const row = await env.DB.prepare("UPDATE devices SET name = ? WHERE id = ? AND account_id = ? RETURNING *")
    .bind(name, deviceId, principal.accountId)
    .first<DeviceRow>();
  return row === null ? errorResponse(404, "not_found") : json(200, { device: deviceJson(row, principal) });
}
