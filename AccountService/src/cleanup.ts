// The hourly cron: deletes spent nonces past their expiry, sessions whose refresh token has
// expired, and accounts not seen for 24 months (owner decision, herdrup#698). An account's
// identities and sessions go with it (ON DELETE CASCADE).
import { dayOf } from "./sessions";

export const INACTIVE_ACCOUNT_DAYS = 730;

export async function cleanup(db: D1Database, nowMs: number): Promise<void> {
  await db.batch([
    db.prepare("DELETE FROM used_nonces WHERE exp_ms <= ?").bind(nowMs),
    db.prepare("DELETE FROM sessions WHERE refresh_exp_ms <= ?").bind(nowMs),
    db.prepare("DELETE FROM accounts WHERE last_seen_day < ?").bind(dayOf(nowMs) - INACTIVE_ACCOUNT_DAYS),
  ]);
}
