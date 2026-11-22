// The hourly cron: deletes spent nonces, spent refresh tokens, enrolment challenges, web
// sign-in flows, handoffs and deletion tickets and codes past their own expiry, approval
// requests once both their 10 minutes and their hourly-cap window are over, withdrawals after
// their 35 days, sessions whose refresh token has expired, sync tombstones older than 90 days
// (src/sync.ts), and accounts not seen for 24 months (owner decision, herdrup#698). An
// account's identities, sessions, devices, handoffs and sync items go with it, a device's
// approval request, browser access and envelopes with the device, and a session's spent refresh
// tokens, challenges and deletion tickets and codes with the session (ON DELETE CASCADE).
import { HOUR_MS } from "./approvals";
import { dayOf } from "./sessions";
import { pruneTombstones } from "./sync";

export const INACTIVE_ACCOUNT_DAYS = 730;

export async function cleanup(db: D1Database, nowMs: number): Promise<void> {
  await db.batch([
    db.prepare("DELETE FROM used_nonces WHERE exp_ms <= ?").bind(nowMs),
    db.prepare("DELETE FROM spent_refresh_tokens WHERE exp_ms <= ?").bind(nowMs),
    db.prepare("DELETE FROM enrol_challenges WHERE exp_ms <= ?").bind(nowMs),
    db.prepare("DELETE FROM web_flows WHERE exp_ms <= ?").bind(nowMs),
    db.prepare("DELETE FROM handoffs WHERE exp_ms <= ?").bind(nowMs),
    db.prepare("DELETE FROM delete_tickets WHERE exp_ms <= ?").bind(nowMs),
    db.prepare("DELETE FROM delete_handoffs WHERE exp_ms <= ?").bind(nowMs),
    db.prepare("DELETE FROM approval_requests WHERE exp_ms <= ?1 AND starts_ms <= ?2").bind(nowMs, nowMs - HOUR_MS),
    db.prepare("DELETE FROM withdrawals WHERE exp_ms <= ?").bind(nowMs),
    db.prepare("DELETE FROM sessions WHERE refresh_exp_ms <= ?").bind(nowMs),
    ...pruneTombstones(db, nowMs),
    db.prepare("DELETE FROM accounts WHERE last_seen_day < ?").bind(dayOf(nowMs) - INACTIVE_ACCOUNT_DAYS),
  ]);
}
