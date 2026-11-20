// Sessions: an opaque access token (1 hour) and a refresh token (90 days, sliding) per session.
//
//   access   a1.<session id>.<secret>     refresh   r1.<session id>.<secret>
//
// The session id is 16 random bytes and each secret 32, all base64url. A sessions row keeps
// only the SHA-256 (hex) of each secret, so a copy of the database holds no usable token.
//
// One row is one session family. Refreshing rotates both tokens, records the old refresh
// token in spent_refresh_tokens and marks the account seen, all in one D1 batch, which is a
// transaction: if any statement fails, none of them happened and the presented token still
// works. D1 runs one batch at a time, so it decides every race: of two refreshes with the
// same token, the first rotates it and the second finds it spent. Any refresh token the
// session ever rotated away (and that has not expired on its own) is treated as stolen when
// presented again: the session row is deleted, which ends every token of the family. There
// is no grace window, so clients refresh one at a time.
import { randomB64url, sameString, sha256Hex } from "./bytes";

export const ACCESS_TTL_MS = 60 * 60 * 1000;
export const REFRESH_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

const ACCESS_TOKEN = /^a1\.([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{43})$/;
const REFRESH_TOKEN = /^r1\.([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{43})$/;

export const PLATFORMS = ["ios", "ipados", "macos", "windows", "linux", "web"] as const;
export type Platform = (typeof PLATFORMS)[number];

export interface TokenPair {
  account_id: string;
  access_token: string;
  access_expires_in: number;
  refresh_token: string;
  refresh_expires_in: number;
}

interface Minted {
  accessToken: string;
  accessHash: string;
  refreshToken: string;
  refreshHash: string;
}

async function mint(sessionId: string): Promise<Minted> {
  const access = randomB64url(32);
  const refresh = randomB64url(32);
  return {
    accessToken: `a1.${sessionId}.${access}`,
    accessHash: await sha256Hex(access),
    refreshToken: `r1.${sessionId}.${refresh}`,
    refreshHash: await sha256Hex(refresh),
  };
}

function pair(accountId: string, minted: Minted): TokenPair {
  return {
    account_id: accountId,
    access_token: minted.accessToken,
    access_expires_in: ACCESS_TTL_MS / 1000,
    refresh_token: minted.refreshToken,
    refresh_expires_in: REFRESH_TTL_MS / 1000,
  };
}

/** The UTC day number accounts.last_seen_day holds. */
export const dayOf = (ms: number): number => Math.floor(ms / DAY_MS);

/** Marks the account seen today, writing only when the stored day is older. */
function touchAccount(db: D1Database, accountId: string, nowMs: number): D1PreparedStatement {
  return db
    .prepare("UPDATE accounts SET last_seen_day = ?1 WHERE id = ?2 AND last_seen_day < ?1")
    .bind(dayOf(nowMs), accountId);
}

export async function openSession(db: D1Database, accountId: string, platform: Platform, nowMs: number): Promise<TokenPair> {
  const sessionId = randomB64url(16);
  const minted = await mint(sessionId);
  await db.batch([
    db
      .prepare(
        `INSERT INTO sessions (id, account_id, access_hash, access_exp_ms, refresh_hash, refresh_exp_ms, platform, created_ms)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(sessionId, accountId, minted.accessHash, nowMs + ACCESS_TTL_MS, minted.refreshHash, nowMs + REFRESH_TTL_MS, platform, nowMs),
    touchAccount(db, accountId, nowMs),
  ]);
  return pair(accountId, minted);
}

export type RefreshResult = { ok: true; tokens: TokenPair } | { ok: false; error: "invalid_token" | "session_revoked" };

export async function refreshSession(db: D1Database, refreshToken: string, nowMs: number): Promise<RefreshResult> {
  const match = REFRESH_TOKEN.exec(refreshToken);
  if (match === null) return { ok: false, error: "invalid_token" };
  const [, sessionId, secret] = match;
  const presented = await sha256Hex(secret);
  const minted = await mint(sessionId);
  // The three statements share one condition: the presented token is the session's current,
  // unexpired one. The spent row is written first, while the row still holds the old expiry;
  // the account touch runs last and finds the session by its new hash.
  const [, rotation] = await db.batch<{ account_id: string }>([
    db
      .prepare(
        `INSERT INTO spent_refresh_tokens (session_id, token_hash, exp_ms)
         SELECT id, refresh_hash, refresh_exp_ms FROM sessions WHERE id = ?1 AND refresh_hash = ?2 AND refresh_exp_ms > ?3`,
      )
      .bind(sessionId, presented, nowMs),
    db
      .prepare(
        `UPDATE sessions
            SET access_hash = ?1, access_exp_ms = ?2, refresh_hash = ?3, refresh_exp_ms = ?4
          WHERE id = ?5 AND refresh_hash = ?6 AND refresh_exp_ms > ?7
        RETURNING account_id`,
      )
      .bind(minted.accessHash, nowMs + ACCESS_TTL_MS, minted.refreshHash, nowMs + REFRESH_TTL_MS, sessionId, presented, nowMs),
    db
      .prepare(
        `UPDATE accounts SET last_seen_day = ?1
          WHERE id = (SELECT account_id FROM sessions WHERE id = ?2 AND refresh_hash = ?3) AND last_seen_day < ?1`,
      )
      .bind(dayOf(nowMs), sessionId, minted.refreshHash),
  ]);
  const rotated = rotation.results[0];
  if (rotated !== undefined) return { ok: true, tokens: pair(rotated.account_id, minted) };
  // Not the current token. If the session ever rotated it away, someone else holds the
  // family's current token: end the whole session.
  const revoked = await db
    .prepare(
      "DELETE FROM sessions WHERE id = ?1 AND EXISTS (SELECT 1 FROM spent_refresh_tokens WHERE session_id = ?1 AND token_hash = ?2)",
    )
    .bind(sessionId, presented)
    .run();
  return { ok: false, error: revoked.meta.changes > 0 ? "session_revoked" : "invalid_token" };
}

export interface Principal {
  accountId: string;
  sessionId: string;
  /** The device this session enrolled (src/devices.ts), or null before enrolment. */
  deviceId: string | null;
}

export type AuthResult = { ok: true; principal: Principal } | { ok: false; error: "invalid_token" | "token_expired" };

/** The session an `Authorization: Bearer a1.…` header names, when its access token is current. */
export async function authenticate(db: D1Database, authorization: string | null, nowMs: number): Promise<AuthResult> {
  const match = ACCESS_TOKEN.exec(/^Bearer (\S+)$/.exec(authorization ?? "")?.[1] ?? "");
  if (match === null) return { ok: false, error: "invalid_token" };
  const [, sessionId, secret] = match;
  const row = await db
    .prepare("SELECT account_id, device_id, access_hash, access_exp_ms FROM sessions WHERE id = ?")
    .bind(sessionId)
    .first<{ account_id: string; device_id: string | null; access_hash: string; access_exp_ms: number }>();
  if (row === null || !sameString(await sha256Hex(secret), row.access_hash)) return { ok: false, error: "invalid_token" };
  if (row.access_exp_ms <= nowMs) return { ok: false, error: "token_expired" };
  return { ok: true, principal: { accountId: row.account_id, sessionId, deviceId: row.device_id } };
}
