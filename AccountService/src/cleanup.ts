// The hourly cron: deletes spent nonces, spent refresh tokens, enrolment challenges, web
// sign-in flows and handoffs past their own expiry, sessions whose refresh token has expired,
// sync tombstones older than 90 days (src/sync.ts), and accounts not seen for 24 months (owner
// decision, herdrup#698). An account's identities, sessions, devices, handoffs and sync items go
// with it, and a session's spent refresh tokens and challenges with the session (ON DELETE CASCADE).
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
    db.prepare("DELETE FROM sessions WHERE refresh_exp_ms <= ?").bind(nowMs),
    ...pruneTombstones(db, nowMs),
    db.prepare("DELETE FROM accounts WHERE last_seen_day < ?").bind(dayOf(nowMs) - INACTIVE_ACCOUNT_DAYS),
  ]);
}
