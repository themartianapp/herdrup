// Browser approval for owner access, protocol approve-v1 (DESIGN.md §12), and pairing an app
// device with the owner's machines, pair-v1 (DESIGN.md §13):
//
//   POST /v1/approvals                    requester {commit} | {kind: "pair", commit, ssh_pub} → 201 {id, expires_in}
//   GET  /v1/approvals[?kind=pair]        approver  → {requests: [{id, browser, commit, claimed, expires_in}]}
//                                                   | {requests: [{id, kind: "pair", device, commit, ssh_pub, claimed, expires_in}]}
//   POST /v1/approvals/<id>/claim         approver  {nonce_t} → {state: "claimed"}
//   GET  /v1/approvals/<id>               either    → {state, expires_in, outcome_stored?, approver?, nonce_t?, nonce_b?}
//                                                     (+ {kind: "pair", commit, ssh_pub, device} for a pair request)
//   POST /v1/approvals/<id>/reveal        requester {nonce_b} → {state: "revealed"}
//   POST /v1/approvals/<id>/finish        claimant  {outcome: "approved", scope, expires_ms, seq, sealed}
//                                                   | pair: {outcome: "approved", seq, sealed}
//                                                   | {outcome: "denied"} → {state}
//   PUT  /v1/approvals/<id>/envelope      claimant  pair: {seq, sealed} → {seq}, 10 minutes after the finish
//   PUT  /v1/browsers/<device_id>/envelope approver {scope, expires_ms, seq, sealed} → {seq}
//   GET  /v1/browsers/self                browser   → {access?, envelopes: [{approver_pub, seq, sealed}]}
//   GET  /v1/pairs/self                   app       → {request?, envelopes: [{request_id, ssh_pub, approver_pub, approver_name, seq, sealed}]}
//   GET  /v1/withdrawals                  approver  → {withdrawals: [{device_pub, fingerprint, created_ms}]}
//
// A browser is a device with platform "web"; an approver is any other device of the same
// account. Both are the calling session's own device, never a body field. A pair request
// (kind "pair") is approve-v1 with an app device as the requester and its new SSH key S
// (ssh_pub, 32 raw ed25519 bytes) bound into the commit and the code; the approver is an app
// device other than the requester. Pair requests share the table, the steps, their guards, the
// expiry and the hourly cap with browser requests; what differs is below and in DESIGN.md §13.
//
// Commit, then reveal. B (the browser) commits to nonce_b before it learns nonce_t, and T (the
// approver) sends nonce_t before it learns nonce_b, so neither side, nor this service, can steer
// the 4-digit code both compute over both keys:
//   commit = SHA-256("herdrup-approve-v1|commit" ‖ 0x00 ‖ B ‖ nonce_b)
//   h      = SHA-256("herdrup-approve-v1|sas" ‖ 0x00 ‖ B ‖ T ‖ nonce_b ‖ nonce_t)
//   code   = uint32_be(h[0..4]) mod 10000, 4 digits
// The user types the browser's code on T, and T approves only on a match. This service never
// sees the code. It checks the commit at the reveal (T checks it too) and runs each step once,
// in order, within 10 minutes. Past those, the first read of the request stores outcome =
// 'expired' before answering, and every step requires outcome IS NULL, so a reported 'expired'
// is final: no finish that started earlier commits after it. T then seals the machine list to
// B (X25519 between the two verified keys, HKDF-SHA256, AES-256-GCM with seq in the AAD); the
// envelope is opaque here and goes back only to that browser. Every binary field is unpadded
// base64url.
//
// None of this grants anything: grants exist only on the machines, written over SSH by T.
// browser_access is what T reported, for Devices to show. The first claim of a browser's request
// marks its device row (devices.approval_claimed_ms): from then on T may have written grants for
// its key. Removing a marked browser leaves a withdrawal (35 days): approvers sweep its grants,
// and no statement is issued for its key on this account meanwhile (src/statements.ts). Keys are
// canonical base64url everywhere (src/bytes.ts bytes32), so string equality is key equality.
//
// pair-v1 binds S in both hashes, so this service can't swap the key the approver adds:
//   commit = SHA-256("herdrup-pair-v1|commit" ‖ 0x00 ‖ B ‖ S ‖ nonce_b)
//   h      = SHA-256("herdrup-pair-v1|sas" ‖ 0x00 ‖ B ‖ S ‖ T ‖ nonce_b ‖ nonce_t)
// and the envelope is approve-v1's with the label "herdrup-pair-v1|envelope". A pair request
// writes no browser access, envelope row or claim mark (its grants are SSH keys the owner
// revokes on the machine): the claimant's sealed machine list sits on the request row
// (seq, sealed), the finish writes it, and for 10 minutes after the finish the claimant may
// replace it with a higher seq (retries of failed machines). The requester reads it with
// GET /v1/pairs/self. A new pair request alerts the account's other iOS devices (src/push.ts).
import { b64url, bytes32, fromB64url, hex, randomB64url, utf8 } from "./bytes";
import { openAccountRequest } from "./auth";
import type { Env } from "./env";
import { errorResponse, json, readJsonObject, type Endpoint } from "./http";
import { sendPairRequestPushes } from "./push";
import type { Principal } from "./sessions";

export const APPROVE_COMMIT_LABEL = "herdrup-approve-v1|commit";
export const PAIR_COMMIT_LABEL = "herdrup-pair-v1|commit";
export const REQUEST_TTL_MS = 10 * 60 * 1000;
/** How long a finished request stays readable, so both sides learn its outcome. */
export const OUTCOME_KEEP_MS = 10 * 60 * 1000;
export const HOUR_MS = 60 * 60 * 1000;
export const MAX_REQUESTS_PER_HOUR = 10;
export const MAX_ENVELOPES = 20;
export const WITHDRAWAL_TTL_MS = 35 * 24 * HOUR_MS;
/** A grant lasts at most 30 days; the reported expiry may lead this clock by a few minutes. */
export const MAX_ACCESS_MS = 30 * 24 * HOUR_MS + 10 * 60 * 1000;
export const MAX_APPROVAL_BODY_BYTES = 4096;
export const MAX_ENVELOPE_BODY_BYTES = 24 * 1024;
export const MAX_SEALED_LENGTH = 16 * 1024;
/** iv (12) ‖ GCM tag (16): the shortest sealed envelope. */
const MIN_SEALED_BYTES = 28;
const SCOPES = ["chat", "terminal"] as const;
type Scope = (typeof SCOPES)[number];

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.byteLength, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.byteLength;
  }
  return out;
}

/** "label" ‖ 0x00 ‖ parts…, the shape of every approve-v1 hash input and AAD. */
export const labelled = (label: string, ...parts: Uint8Array[]): Uint8Array => concat(utf8(label), new Uint8Array([0]), ...parts);

/** The browser's commitment to nonceB for its key browserPub. */
export async function approveCommit(browserPub: Uint8Array, nonceB: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", labelled(APPROVE_COMMIT_LABEL, browserPub, nonceB)));
}

/** An app device's commitment to nonceB for its key devicePub and the SSH key sshPub it asks to have added (pair-v1). */
export async function pairCommit(devicePub: Uint8Array, sshPub: Uint8Array, nonceB: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", labelled(PAIR_COMMIT_LABEL, devicePub, sshPub, nonceB)));
}

/** herdr's fingerprint of a device key: "SHA256:" and the first 16 hex digits of its SHA-256, in groups of 4 joined by "·". */
export async function fingerprint(devicePub: Uint8Array): Promise<string> {
  const digest = hex(await crypto.subtle.digest("SHA-256", devicePub));
  return `SHA256:${[0, 4, 8, 12].map((at) => digest.slice(at, at + 4)).join("·")}`;
}

interface CallerDevice {
  id: string;
  device_pub: string;
  name: string;
  platform: string;
}

/** "app": any device but a browser, as the requester of a pair request. */
type Role = "browser" | "approver" | "app" | "either";

interface Caller {
  principal: Principal;
  device: CallerDevice;
}

/** The session, its device in the role the route needs, and the APPROVAL_LIMIT budget, or the error to answer with. */
async function openApprovalRequest(request: Request, env: Env, endpoint: Endpoint, nowMs: number, role: Role): Promise<Caller | Response> {
  const principal = await openAccountRequest(request, env, endpoint, nowMs, "APPROVAL_LIMIT");
  if (principal instanceof Response) return principal;
  if (principal.deviceId === null) return errorResponse(403, "device_required");
  const device = await env.DB.prepare("SELECT id, device_pub, name, platform FROM devices WHERE id = ? AND account_id = ?")
    .bind(principal.deviceId, principal.accountId)
    .first<CallerDevice>();
  if (device === null) return errorResponse(403, "device_removed");
  if (role === "browser" && device.platform !== "web") return errorResponse(403, "not_a_browser");
  if (role === "approver" && device.platform === "web") return errorResponse(403, "not_an_approver");
  if (role === "app" && device.platform === "web") return errorResponse(403, "not_native");
  return { principal, device };
}

export interface AccessJson {
  state: "waiting" | "approved" | "expired";
  scope?: Scope;
  expires_ms?: number;
}

/**
 * Stores the expiry of every live request of the account that is past its 10 minutes
 * (outcome = 'expired'). Runs first in each batch that reads approval state, so the service
 * answers from a stored expiry, never from the clock alone. Every step's update requires
 * outcome IS NULL, so once stored, no step that started earlier (a finish whose nowMs is
 * before exp_ms, still running) can commit: an 'expired' the service reported is final.
 */
function storeExpiry(db: D1Database, accountId: string, nowMs: number): D1PreparedStatement {
  return db
    .prepare("UPDATE approval_requests SET outcome = 'expired' WHERE account_id = ? AND outcome IS NULL AND exp_ms <= ?")
    .bind(accountId, nowMs);
}

/**
 * What Devices shows for each of the account's browsers, by device id: approved while the
 * reported expiry is ahead, expired after it, waiting while a request is live and nothing was
 * ever reported. A browser with neither has no entry.
 */
export async function browserAccess(db: D1Database, accountId: string, nowMs: number): Promise<Map<string, AccessJson>> {
  const [, access, waiting] = await db.batch<{ device_id: string; scope?: Scope; expires_ms?: number }>([
    storeExpiry(db, accountId, nowMs),
    db.prepare("SELECT device_id, scope, expires_ms FROM browser_access WHERE account_id = ?").bind(accountId),
    db
      .prepare(
        "SELECT browser_device_id AS device_id FROM approval_requests WHERE account_id = ? AND kind = 'browser' AND outcome IS NULL AND exp_ms > ?",
      )
      .bind(accountId, nowMs),
  ]);
  const states = new Map<string, AccessJson>();
  for (const row of waiting.results) states.set(row.device_id, { state: "waiting" });
  for (const row of access.results) {
    const expiresMs = row.expires_ms ?? 0;
    states.set(row.device_id, { state: expiresMs > nowMs ? "approved" : "expired", scope: row.scope, expires_ms: expiresMs });
  }
  return states;
}

type Kind = "browser" | "pair";

interface RequestRow {
  id: string;
  kind: Kind;
  /** The requester: a browser for kind "browser", an app device for kind "pair". */
  browser_device_id: string;
  commit: string;
  ssh_pub: string | null;
  approver_device_id: string | null;
  nonce_t: string | null;
  nonce_b: string | null;
  outcome: "approved" | "denied" | "expired" | null;
  exp_ms: number;
  seq: number | null;
}

type RequestState = "waiting" | "claimed" | "revealed" | "denied" | "approved" | "expired";

function requestState(row: Pick<RequestRow, "outcome" | "exp_ms" | "nonce_b" | "approver_device_id">, nowMs: number): RequestState {
  if (row.outcome !== null) return row.outcome;
  if (row.exp_ms <= nowMs) return "expired";
  if (row.nonce_b !== null) return "revealed";
  return row.approver_device_id !== null ? "claimed" : "waiting";
}

const expiresIn = (expMs: number, nowMs: number): number => Math.max(0, Math.ceil((expMs - nowMs) / 1000));

async function findRequest(env: Env, caller: Caller, id: string, nowMs: number): Promise<RequestRow | null> {
  const [, found] = await env.DB.batch<RequestRow>([
    storeExpiry(env.DB, caller.principal.accountId, nowMs),
    env.DB.prepare(
      `SELECT id, kind, browser_device_id, "commit" AS "commit", ssh_pub, approver_device_id, nonce_t, nonce_b, outcome, exp_ms, seq
         FROM approval_requests WHERE id = ? AND account_id = ?`,
    ).bind(id, caller.principal.accountId),
  ]);
  return found.results[0] ?? null;
}

/** Why a step can't run on a request that isn't live: its 10 minutes are up, or it finished. */
function notLive(row: RequestRow, nowMs: number): Response | null {
  if (row.outcome === "expired" || (row.outcome === null && row.exp_ms <= nowMs)) return errorResponse(410, "expired");
  if (row.outcome !== null) return errorResponse(409, "already_finished");
  return null;
}

export async function handleCreateRequest(request: Request, env: Env, ctx: ExecutionContext, nowMs: number): Promise<Response> {
  const caller = await openApprovalRequest(request, env, "/v1/approvals", nowMs, "either");
  if (caller instanceof Response) return caller;
  const body = await readJsonObject(request, MAX_APPROVAL_BODY_BYTES);
  if (body instanceof Response) return body;
  const kind = body.kind ?? "browser";
  if (kind !== "browser" && kind !== "pair") return errorResponse(400, "bad_request");
  // A browser asks for owner access, an app device asks to be paired; never the other way round.
  const isBrowser = caller.device.platform === "web";
  if (kind === "browser" && !isBrowser) return errorResponse(403, "not_a_browser");
  if (kind === "pair" && isBrowser) return errorResponse(403, "not_native");
  if (bytes32(body.commit) === null) return errorResponse(400, "bad_request");
  const sshPub = kind === "pair" ? body.ssh_pub : null;
  if (kind === "pair" && bytes32(sshPub) === null) return errorResponse(400, "bad_request");

  // One live request per requester: a new one replaces it, whatever its state. The hourly cap is
  // checked in the same statement: each requester's row counts its requests in a fixed hour
  // window, and the account's windows that are still open are summed.
  const id = randomB64url(16);
  const hourAgo = nowMs - HOUR_MS;
  const created = await env.DB.prepare(
    `INSERT INTO approval_requests (id, account_id, browser_device_id, "commit", created_ms, exp_ms, starts, starts_ms, kind, ssh_pub)
     SELECT ?1, ?2, ?3, ?4, ?5, ?6, 1, ?5, ?9, ?10
      WHERE (SELECT COALESCE(SUM(starts), 0) FROM approval_requests WHERE account_id = ?2 AND starts_ms > ?7) < ?8
     ON CONFLICT (browser_device_id) DO UPDATE SET
       id = excluded.id, "commit" = excluded."commit", approver_device_id = NULL, nonce_t = NULL, nonce_b = NULL,
       outcome = NULL, created_ms = excluded.created_ms, exp_ms = excluded.exp_ms,
       kind = excluded.kind, ssh_pub = excluded.ssh_pub, seq = NULL, sealed = NULL,
       starts = CASE WHEN approval_requests.starts_ms > ?7 THEN approval_requests.starts + 1 ELSE 1 END,
       starts_ms = CASE WHEN approval_requests.starts_ms > ?7 THEN approval_requests.starts_ms ELSE excluded.starts_ms END
     RETURNING id`,
  )
    .bind(id, caller.principal.accountId, caller.device.id, body.commit, nowMs, nowMs + REQUEST_TTL_MS, hourAgo, MAX_REQUESTS_PER_HOUR, kind, sshPub)
    .first<{ id: string }>();
  if (created === null) return errorResponse(429, "too_many_requests");
  // The approver's iOS devices hear of it now; desktops see it on their next list. Never waited
  // on: a push that fails or is slow doesn't touch the answer.
  if (kind === "pair") ctx.waitUntil(sendPairRequestPushes(env, caller.principal.accountId, caller.device, id, nowMs + REQUEST_TTL_MS));
  return json(201, { id, expires_in: REQUEST_TTL_MS / 1000 });
}

export async function handleListRequests(request: Request, env: Env, nowMs: number): Promise<Response> {
  const caller = await openApprovalRequest(request, env, "/v1/approvals", nowMs, "approver");
  if (caller instanceof Response) return caller;
  // Browser requests unless the caller asks for pair requests: an app from before pair-v1 lists
  // without the parameter and must never offer a pair request as a browser's.
  const kind = new URL(request.url).searchParams.get("kind") ?? "browser";
  if (kind !== "browser" && kind !== "pair") return errorResponse(400, "bad_request");
  const [, { results }] = await env.DB.batch<{
    id: string;
    commit: string;
    ssh_pub: string | null;
    approver_device_id: string | null;
    exp_ms: number;
    device_id: string;
    device_pub: string;
    name: string;
    platform: string;
    created_ms: number;
  }>([
    storeExpiry(env.DB, caller.principal.accountId, nowMs),
    env.DB.prepare(
      `SELECT r.id, r."commit" AS "commit", r.ssh_pub, r.approver_device_id, r.exp_ms,
              d.id AS device_id, d.device_pub, d.name, d.platform, d.created_ms
         FROM approval_requests r JOIN devices d ON d.id = r.browser_device_id
        WHERE r.account_id = ?1 AND r.kind = ?3 AND r.browser_device_id <> ?4 AND r.outcome IS NULL AND r.exp_ms > ?2
        ORDER BY r.created_ms, r.id`,
    ).bind(caller.principal.accountId, nowMs, kind, caller.device.id),
  ]);
  return json(200, {
    requests: results.map((row) => {
      const requester = { device_id: row.device_id, device_pub: row.device_pub, name: row.name, platform: row.platform, created_ms: row.created_ms };
      const claimed = row.approver_device_id === null ? "no" : row.approver_device_id === caller.device.id ? "you" : "other";
      const expires = expiresIn(row.exp_ms, nowMs);
      return kind === "browser"
        ? { id: row.id, browser: requester, commit: row.commit, claimed, expires_in: expires }
        : { id: row.id, kind, device: requester, commit: row.commit, ssh_pub: row.ssh_pub, claimed, expires_in: expires };
    }),
  });
}

export async function handleGetRequest(request: Request, env: Env, id: string, nowMs: number): Promise<Response> {
  const caller = await openApprovalRequest(request, env, "/v1/approvals/:id", nowMs, "either");
  if (caller instanceof Response) return caller;
  const row = await findRequest(env, caller, id, nowMs);
  const isRequester = row !== null && row.browser_device_id === caller.device.id;
  // A browser sees only its own request; any app device of the account sees every request's
  // state (an app device's own pair request included).
  if (row === null || (caller.device.platform === "web" && !isRequester)) return errorResponse(404, "not_found");
  const state = requestState(row, nowMs);
  const live = state === "claimed" || state === "revealed";
  const isClaimant = row.approver_device_id === caller.device.id;
  const approver =
    row.approver_device_id === null
      ? null
      : await env.DB.prepare("SELECT device_pub, name FROM devices WHERE id = ?")
          .bind(row.approver_device_id)
          .first<{ device_pub: string; name: string }>();
  // A pair request also names its requester and S, so an approver opening it from a push needs
  // no list: it checks the commit over B and S itself.
  const requester =
    row.kind === "pair"
      ? await env.DB.prepare("SELECT id AS device_id, device_pub, name, platform FROM devices WHERE id = ?")
          .bind(row.browser_device_id)
          .first<{ device_id: string; device_pub: string; name: string; platform: string }>()
      : null;
  return json(200, {
    state,
    expires_in: expiresIn(row.exp_ms, nowMs),
    // Read after storeExpiry: true only when the outcome is in the row, so this Worker vouches
    // that the state is final. A Worker without storeExpiry reports an expiry from the clock and
    // never sends it, so a client can't be fooled by health and this read hitting two versions.
    ...(row.outcome === null ? {} : { outcome_stored: true }),
    ...(approver === null ? {} : { approver: { device_pub: approver.device_pub, name: approver.name } }),
    ...(requester === null ? {} : { kind: row.kind, commit: row.commit, ssh_pub: row.ssh_pub, device: requester }),
    // nonce_t goes to the two parties; nonce_b only to the claimant, and only while live.
    ...(live && (isRequester || isClaimant) ? { nonce_t: row.nonce_t } : {}),
    ...(live && isClaimant && row.nonce_b !== null ? { nonce_b: row.nonce_b } : {}),
  });
}

export async function handleClaim(request: Request, env: Env, id: string, nowMs: number): Promise<Response> {
  const caller = await openApprovalRequest(request, env, "/v1/approvals/:id/claim", nowMs, "approver");
  if (caller instanceof Response) return caller;
  const body = await readJsonObject(request, MAX_APPROVAL_BODY_BYTES);
  if (body instanceof Response) return body;
  if (bytes32(body.nonce_t) === null) return errorResponse(400, "bad_request");
  // One batch: the claim, and a browser's mark that an approver may now write grants for its
  // key. The mark lives on the browser's device row, so neither a replacement request nor the
  // approver's removal clears it; only removing the browser does, turning it into a withdrawal.
  // A pair request leaves no mark: what its approver adds is an SSH key, revoked on the machine.
  // The requester never claims its own request.
  const [claimed] = await env.DB.batch([
    env.DB.prepare(
      `UPDATE approval_requests SET approver_device_id = ?1, nonce_t = ?2
        WHERE id = ?3 AND account_id = ?4 AND browser_device_id <> ?1 AND approver_device_id IS NULL AND outcome IS NULL AND exp_ms > ?5
       RETURNING id`,
    ).bind(caller.device.id, body.nonce_t, id, caller.principal.accountId, nowMs),
    env.DB.prepare(
      `UPDATE devices SET approval_claimed_ms = COALESCE(approval_claimed_ms, ?4)
        WHERE id = (SELECT browser_device_id FROM approval_requests WHERE id = ?1 AND approver_device_id = ?2 AND nonce_t = ?3 AND kind = 'browser')`,
    ).bind(id, caller.device.id, body.nonce_t, nowMs),
  ]);
  if (claimed.results.length > 0) return json(200, { state: "claimed" });
  const row = await findRequest(env, caller, id, nowMs);
  if (row === null) return errorResponse(404, "not_found");
  if (row.browser_device_id === caller.device.id) return errorResponse(403, "own_request");
  return notLive(row, nowMs) ?? errorResponse(409, "already_claimed");
}

export async function handleReveal(request: Request, env: Env, id: string, nowMs: number): Promise<Response> {
  const caller = await openApprovalRequest(request, env, "/v1/approvals/:id/reveal", nowMs, "either");
  if (caller instanceof Response) return caller;
  const row = await findRequest(env, caller, id, nowMs);
  // A browser's request is revealed by that browser only; an app device reveals its own pair request.
  if (caller.device.platform !== "web" && row?.kind === "browser") return errorResponse(403, "not_a_browser");
  const body = await readJsonObject(request, MAX_APPROVAL_BODY_BYTES);
  if (body instanceof Response) return body;
  const nonceB = bytes32(body.nonce_b);
  if (nonceB === null) return errorResponse(400, "bad_request");
  if (row === null || row.browser_device_id !== caller.device.id) return errorResponse(404, "not_found");
  const stale = notLive(row, nowMs);
  if (stale !== null) return stale;
  // B reveals only once it holds nonce_t; a second reveal is refused.
  if (row.approver_device_id === null) return errorResponse(409, "not_claimed");
  if (row.nonce_b !== null) return errorResponse(409, "already_revealed");
  const requesterPub = fromB64url(caller.device.device_pub);
  const sshPub = row.kind === "pair" ? fromB64url(row.ssh_pub ?? "") : null;
  const opened =
    requesterPub === null
      ? null
      : row.kind === "browser"
        ? await approveCommit(requesterPub, nonceB)
        : sshPub === null
          ? null
          : await pairCommit(requesterPub, sshPub, nonceB);
  if (opened === null || b64url(opened) !== row.commit) {
    // A reveal that doesn't open the commit ends the request: no second try with another nonce.
    await env.DB.prepare("UPDATE approval_requests SET outcome = 'denied', exp_ms = ? WHERE id = ? AND outcome IS NULL")
      .bind(nowMs + OUTCOME_KEEP_MS, id)
      .run();
    return errorResponse(400, "reveal_mismatch");
  }
  const revealed = await env.DB.prepare(
    `UPDATE approval_requests SET nonce_b = ?1
      WHERE id = ?2 AND browser_device_id = ?3 AND approver_device_id IS NOT NULL AND nonce_b IS NULL
        AND outcome IS NULL AND exp_ms > ?4
     RETURNING id`,
  )
    .bind(body.nonce_b, id, caller.device.id, nowMs)
    .first();
  return revealed === null ? errorResponse(409, "already_revealed") : json(200, { state: "revealed" });
}

interface Sealed {
  seq: number;
  sealed: string;
}

interface Report extends Sealed {
  scope: Scope;
  expiresMs: number;
}

/** An envelope's seq (at least `minSeq`) and its sealed bytes as sent, or null when either is malformed. */
function readSealed(body: Record<string, unknown>, minSeq: number): Sealed | null {
  const { seq, sealed } = body;
  if (typeof seq !== "number" || !Number.isSafeInteger(seq) || seq < minSeq) return null;
  if (typeof sealed !== "string" || sealed.length > MAX_SEALED_LENGTH) return null;
  const bytes = fromB64url(sealed);
  if (bytes === null || bytes.byteLength < MIN_SEALED_BYTES || b64url(bytes) !== sealed) return null;
  return { seq, sealed };
}

/** The access and envelope an approver reports, or null when any field is malformed. */
function readReport(body: Record<string, unknown>, nowMs: number): Report | null {
  const { scope, expires_ms: expiresMs } = body;
  if (!SCOPES.includes(scope as Scope)) return null;
  if (typeof expiresMs !== "number" || !Number.isSafeInteger(expiresMs) || expiresMs <= nowMs || expiresMs > nowMs + MAX_ACCESS_MS) return null;
  const envelope = readSealed(body, 0);
  return envelope === null ? null : { scope: scope as Scope, expiresMs, ...envelope };
}

/** The envelope this approver last stored for the browser, if any, and how many others the browser holds. */
async function envelopeSlot(env: Env, browserId: string, approverPub: string): Promise<{ seq: number | null; others: number }> {
  const row = await env.DB.prepare(
    `SELECT (SELECT seq FROM browser_envelopes WHERE device_id = ?1 AND approver_pub = ?2) AS seq,
            (SELECT COUNT(*) FROM browser_envelopes WHERE device_id = ?1 AND approver_pub <> ?2) AS others`,
  )
    .bind(browserId, approverPub)
    .first<{ seq: number | null; others: number }>();
  return row ?? { seq: null, others: 0 };
}

/**
 * The statements that store an approver's report, for one batch that starts with `gate`: the
 * envelope (only over a lower seq, and under the per-browser cap), then the reported access. D1
 * runs a batch as one transaction, in order. Each statement after `gate` runs only when the one
 * just before it changed a row (`changes() = 1`), so there is no envelope unless the gate held,
 * and no access unless the envelope advanced. Statements a caller appends follow the same rule.
 */
export function reportStatements(
  db: D1Database,
  gate: D1PreparedStatement,
  accountId: string,
  browserId: string,
  approverPub: string,
  report: Report,
  nowMs: number,
): D1PreparedStatement[] {
  return [
    gate,
    db
      .prepare(
        `INSERT INTO browser_envelopes (device_id, approver_pub, account_id, seq, sealed, updated_ms)
         SELECT ?1, ?2, ?3, ?4, ?5, ?6
          WHERE changes() = 1
            AND EXISTS (SELECT 1 FROM devices WHERE id = ?1 AND account_id = ?3)
            AND (SELECT COUNT(*) FROM browser_envelopes WHERE device_id = ?1 AND approver_pub <> ?2) < ?7
         ON CONFLICT (device_id, approver_pub) DO UPDATE SET seq = excluded.seq, sealed = excluded.sealed, updated_ms = excluded.updated_ms
          WHERE excluded.seq > browser_envelopes.seq`,
      )
      .bind(browserId, approverPub, accountId, report.seq, report.sealed, nowMs, MAX_ENVELOPES),
    db
      .prepare(
        `INSERT INTO browser_access (device_id, account_id, scope, expires_ms, approved_ms, updated_ms)
         SELECT ?1, ?2, ?3, ?4, ?5, ?5 WHERE changes() = 1
         ON CONFLICT (device_id) DO UPDATE SET scope = excluded.scope, expires_ms = excluded.expires_ms, updated_ms = excluded.updated_ms`,
      )
      .bind(browserId, accountId, report.scope, report.expiresMs, nowMs),
  ];
}

export async function handleFinish(request: Request, env: Env, id: string, nowMs: number): Promise<Response> {
  const caller = await openApprovalRequest(request, env, "/v1/approvals/:id/finish", nowMs, "approver");
  if (caller instanceof Response) return caller;
  const body = await readJsonObject(request, MAX_ENVELOPE_BODY_BYTES);
  if (body instanceof Response) return body;
  const approving = body.outcome === "approved";
  if (!approving && body.outcome !== "denied") return errorResponse(400, "bad_request");
  // A browser's approval reports access and an envelope; a pair request's only an envelope (seq from 1).
  const report = approving ? readReport(body, nowMs) : null;
  const pairEnvelope = approving ? readSealed(body, 1) : null;
  if (approving && report === null && pairEnvelope === null) return errorResponse(400, "bad_request");
  const row = await findRequest(env, caller, id, nowMs);
  // Only the claimant finishes; to anyone else the request doesn't exist.
  if (row === null || row.approver_device_id !== caller.device.id) return errorResponse(404, "not_found");
  const stale = notLive(row, nowMs);
  if (stale !== null) return stale;
  if (approving && (row.kind === "pair" ? pairEnvelope : report) === null) return errorResponse(400, "bad_request");

  const { accountId } = caller.principal;
  if (!approving) {
    // T may deny at any point after its claim (a code that didn't match, a reveal that didn't open the commit).
    const denied = await env.DB.prepare(
      `UPDATE approval_requests SET outcome = 'denied', exp_ms = ?1
        WHERE id = ?2 AND approver_device_id = ?3 AND outcome IS NULL AND exp_ms > ?4 RETURNING id`,
    )
      .bind(nowMs + OUTCOME_KEEP_MS, id, caller.device.id, nowMs)
      .first();
    if (denied !== null) return json(200, { state: "denied" });
    // Lost to another finish or to a stored expiry: answer from the row as it is now.
    const now = await findRequest(env, caller, id, nowMs);
    return (now === null ? null : notLive(now, nowMs)) ?? errorResponse(409, "already_finished");
  }

  // Approval needs the reveal: T checked nonce_b against the commit and the user typed the code.
  if (row.nonce_b === null) return errorResponse(409, "not_revealed");
  if (row.kind === "pair") {
    // One statement is the single-use gate and the write: the envelope, and the approved mark
    // that opens the 10 minutes in which the claimant may replace it (PUT …/envelope).
    const done = await env.DB.prepare(
      `UPDATE approval_requests SET outcome = 'approved', exp_ms = ?4, seq = ?5, sealed = ?6
        WHERE id = ?1 AND approver_device_id = ?2 AND nonce_b IS NOT NULL AND outcome IS NULL AND exp_ms > ?3 RETURNING id`,
    )
      .bind(id, caller.device.id, nowMs, nowMs + OUTCOME_KEEP_MS, pairEnvelope!.seq, pairEnvelope!.sealed)
      .first();
    if (done !== null) return json(200, { state: "approved" });
    const now = await findRequest(env, caller, id, nowMs);
    return (now === null ? null : notLive(now, nowMs)) ?? errorResponse(409, "already_finished");
  }
  if (report === null) return errorResponse(400, "bad_request");
  const slot = await envelopeSlot(env, row.browser_device_id, caller.device.device_pub);
  if (slot.seq !== null && report.seq <= slot.seq) return errorResponse(409, "stale_seq");
  if (slot.seq === null && slot.others >= MAX_ENVELOPES) return errorResponse(403, "too_many_envelopes");
  // One batch, so a failure anywhere leaves the request revealed and a retry works. The gate is
  // the single-use check (of two finishes, one passes it), the envelope and access follow it, and
  // the request is marked approved only once both are written.
  const live = `id = ?1 AND approver_device_id = ?2 AND nonce_b IS NOT NULL AND outcome IS NULL AND exp_ms > ?3`;
  const results = await env.DB.batch([
    ...reportStatements(
      env.DB,
      env.DB.prepare(`UPDATE approval_requests SET exp_ms = exp_ms WHERE ${live}`).bind(id, caller.device.id, nowMs),
      accountId,
      row.browser_device_id,
      caller.device.device_pub,
      report,
      nowMs,
    ),
    env.DB.prepare(`UPDATE approval_requests SET outcome = 'approved', exp_ms = ?4 WHERE changes() = 1 AND ${live}`).bind(
      id,
      caller.device.id,
      nowMs,
      nowMs + OUTCOME_KEEP_MS,
    ),
    // Approved again by code: a withdrawal of this key from an earlier removal no longer holds.
    env.DB.prepare(
      "DELETE FROM withdrawals WHERE changes() = 1 AND account_id = ? AND device_pub = (SELECT device_pub FROM devices WHERE id = ?)",
    ).bind(accountId, row.browser_device_id),
  ]);
  if (results[3].meta.changes === 1) return json(200, { state: "approved" });
  // Lost a race: another finish took the request, it expired, or another envelope got there first.
  const now = await findRequest(env, caller, id, nowMs);
  return (now === null ? null : notLive(now, nowMs)) ?? errorResponse(409, "stale_seq");
}

export async function handlePutEnvelope(request: Request, env: Env, browserId: string, nowMs: number): Promise<Response> {
  const caller = await openApprovalRequest(request, env, "/v1/browsers/:id/envelope", nowMs, "approver");
  if (caller instanceof Response) return caller;
  const body = await readJsonObject(request, MAX_ENVELOPE_BODY_BYTES);
  if (body instanceof Response) return body;
  const report = readReport(body, nowMs);
  if (report === null) return errorResponse(400, "bad_request");
  const { accountId } = caller.principal;
  const browser = await env.DB.prepare("SELECT platform FROM devices WHERE id = ? AND account_id = ?")
    .bind(browserId, accountId)
    .first<{ platform: string }>();
  if (browser === null || browser.platform !== "web") return errorResponse(404, "not_found");
  // Renewals and machine changes come only from an approver the browser verified by code: one
  // whose envelope it already holds. Any other device runs the code flow first.
  const slot = await envelopeSlot(env, browserId, caller.device.device_pub);
  if (slot.seq === null) return errorResponse(403, "not_approver");
  if (report.seq <= slot.seq) return errorResponse(409, "stale_seq");
  // The gate repeats the approver check inside the batch.
  const gate = env.DB.prepare("UPDATE browser_envelopes SET seq = seq WHERE device_id = ? AND approver_pub = ?").bind(browserId, caller.device.device_pub);
  const [, envelope] = await env.DB.batch(reportStatements(env.DB, gate, accountId, browserId, caller.device.device_pub, report, nowMs));
  return envelope.meta.changes === 1 ? json(200, { seq: report.seq }) : errorResponse(409, "stale_seq");
}

export async function handleBrowserSelf(request: Request, env: Env, nowMs: number): Promise<Response> {
  const caller = await openApprovalRequest(request, env, "/v1/browsers/self", nowMs, "browser");
  if (caller instanceof Response) return caller;
  const access = (await browserAccess(env.DB, caller.principal.accountId, nowMs)).get(caller.device.id);
  const { results } = await env.DB.prepare("SELECT approver_pub, seq, sealed FROM browser_envelopes WHERE device_id = ? ORDER BY approver_pub")
    .bind(caller.device.id)
    .all<{ approver_pub: string; seq: number; sealed: string }>();
  return json(200, { ...(access === undefined ? {} : { access }), envelopes: results });
}

/**
 * A pair request's claimant replaces the envelope with a higher seq, for 10 minutes after its
 * finish: the machines that failed the first time, tried again. Nothing else changes.
 */
export async function handlePutPairEnvelope(request: Request, env: Env, id: string, nowMs: number): Promise<Response> {
  const caller = await openApprovalRequest(request, env, "/v1/approvals/:id/envelope", nowMs, "approver");
  if (caller instanceof Response) return caller;
  const body = await readJsonObject(request, MAX_ENVELOPE_BODY_BYTES);
  if (body instanceof Response) return body;
  const envelope = readSealed(body, 1);
  if (envelope === null) return errorResponse(400, "bad_request");
  const row = await findRequest(env, caller, id, nowMs);
  if (row === null || row.kind !== "pair" || row.approver_device_id !== caller.device.id) return errorResponse(404, "not_found");
  if (row.outcome === "expired" || row.exp_ms <= nowMs) return errorResponse(410, "expired");
  if (row.outcome !== "approved") return errorResponse(409, "not_approved");
  if (row.seq !== null && envelope.seq <= row.seq) return errorResponse(409, "stale_seq");
  const stored = await env.DB.prepare(
    `UPDATE approval_requests SET seq = ?1, sealed = ?2
      WHERE id = ?3 AND approver_device_id = ?4 AND outcome = 'approved' AND exp_ms > ?5 AND seq < ?1 RETURNING id`,
  )
    .bind(envelope.seq, envelope.sealed, id, caller.device.id, nowMs)
    .first();
  return stored === null ? errorResponse(409, "stale_seq") : json(200, { seq: envelope.seq });
}

/**
 * The requester's pair request and the envelope its claimant sealed, if any: at most one, the
 * latest seq. A new request replaces both, so the app saves the machines before it asks again.
 */
export async function handlePairSelf(request: Request, env: Env, nowMs: number): Promise<Response> {
  const caller = await openApprovalRequest(request, env, "/v1/pairs/self", nowMs, "app");
  if (caller instanceof Response) return caller;
  const [, found] = await env.DB.batch<{
    id: string;
    ssh_pub: string;
    approver_device_id: string | null;
    nonce_b: string | null;
    outcome: RequestRow["outcome"];
    exp_ms: number;
    seq: number | null;
    sealed: string | null;
    approver_pub: string | null;
    approver_name: string | null;
  }>([
    storeExpiry(env.DB, caller.principal.accountId, nowMs),
    env.DB.prepare(
      `SELECT r.id, r.ssh_pub, r.approver_device_id, r.nonce_b, r.outcome, r.exp_ms, r.seq, r.sealed,
              a.device_pub AS approver_pub, a.name AS approver_name
         FROM approval_requests r LEFT JOIN devices a ON a.id = r.approver_device_id
        WHERE r.browser_device_id = ? AND r.account_id = ? AND r.kind = 'pair'`,
    ).bind(caller.device.id, caller.principal.accountId),
  ]);
  const row = found.results[0];
  if (row === undefined) return json(200, { envelopes: [] });
  return json(200, {
    request: {
      id: row.id,
      state: requestState(row, nowMs),
      expires_in: expiresIn(row.exp_ms, nowMs),
      ...(row.outcome === null ? {} : { outcome_stored: true }),
    },
    envelopes:
      row.sealed === null || row.approver_pub === null
        ? []
        : [{ request_id: row.id, ssh_pub: row.ssh_pub, approver_pub: row.approver_pub, approver_name: row.approver_name, seq: row.seq, sealed: row.sealed }],
  });
}

export async function handleWithdrawals(request: Request, env: Env, nowMs: number): Promise<Response> {
  const caller = await openApprovalRequest(request, env, "/v1/withdrawals", nowMs, "approver");
  if (caller instanceof Response) return caller;
  const { results } = await env.DB.prepare(
    "SELECT device_pub, fingerprint, created_ms FROM withdrawals WHERE account_id = ? AND exp_ms > ? ORDER BY created_ms, device_pub",
  )
    .bind(caller.principal.accountId, nowMs)
    .all<{ device_pub: string; fingerprint: string; created_ms: number }>();
  return json(200, { withdrawals: results });
}

/**
 * The statement that records a withdrawal when browser `deviceId` is removed, if a request of it
 * was ever claimed (devices.approval_claimed_ms): its approver may already have written grants.
 * Runs in the removal's batch, before the device row goes.
 */
export async function withdrawal(db: D1Database, accountId: string, deviceId: string, devicePub: string, nowMs: number): Promise<D1PreparedStatement | null> {
  const pub = fromB64url(devicePub);
  if (pub === null) return null;
  return db
    .prepare(
      `INSERT INTO withdrawals (account_id, device_pub, fingerprint, created_ms, exp_ms)
       SELECT ?1, ?2, ?3, ?4, ?5
        WHERE EXISTS (SELECT 1 FROM devices WHERE id = ?6 AND account_id = ?1 AND approval_claimed_ms IS NOT NULL)
       ON CONFLICT (account_id, device_pub) DO UPDATE SET created_ms = excluded.created_ms, exp_ms = excluded.exp_ms`,
    )
    .bind(accountId, devicePub, await fingerprint(pub), nowMs, nowMs + WITHDRAWAL_TTL_MS, deviceId);
}
