-- herdrup-accounts, migration 0007: a request's expiry is stored (DESIGN.md §12.2). Once the
-- service has seen a live request past its 10 minutes, it writes outcome = 'expired' before it
-- answers. Every step's update requires outcome IS NULL, so a finish that started before the
-- expiry can no longer commit after it, and an 'expired' the service reported is final.
--
-- SQLite can't change a CHECK in place, so the table is rebuilt with the same columns, data and
-- indexes and a CHECK that also allows 'expired'. Nothing references approval_requests.
ALTER TABLE approval_requests RENAME TO approval_requests_0006;

CREATE TABLE approval_requests (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  browser_device_id TEXT NOT NULL UNIQUE REFERENCES devices (id) ON DELETE CASCADE,
  "commit" TEXT NOT NULL,
  approver_device_id TEXT REFERENCES devices (id) ON DELETE CASCADE,
  nonce_t TEXT,
  nonce_b TEXT,
  outcome TEXT CHECK (outcome IN ('approved', 'denied', 'expired')),
  created_ms INTEGER NOT NULL,
  exp_ms INTEGER NOT NULL,
  starts INTEGER NOT NULL,
  starts_ms INTEGER NOT NULL,
  CHECK ((nonce_t IS NULL) = (approver_device_id IS NULL)),
  CHECK (nonce_b IS NULL OR nonce_t IS NOT NULL)
) STRICT;

INSERT INTO approval_requests
  (id, account_id, browser_device_id, "commit", approver_device_id, nonce_t, nonce_b, outcome, created_ms, exp_ms, starts, starts_ms)
SELECT id, account_id, browser_device_id, "commit", approver_device_id, nonce_t, nonce_b, outcome, created_ms, exp_ms, starts, starts_ms
  FROM approval_requests_0006;

-- The old table's indexes go with it; then they are made again on the new one.
DROP TABLE approval_requests_0006;

CREATE INDEX approval_requests_account ON approval_requests (account_id, created_ms);
CREATE INDEX approval_requests_approver ON approval_requests (approver_device_id);
CREATE INDEX approval_requests_exp ON approval_requests (exp_ms);
